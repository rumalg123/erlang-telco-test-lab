-module(telco_stp_listener_manager).
-behaviour(gen_server).

-include_lib("kernel/include/inet_sctp.hrl").

-export([
    start_link/0,
    add/1,
    remove/1,
    list/0,
    configs/0,
    send/4,
    send/5,
    profile_for_peer/3
]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(M3UA_PORT, 2905).
-define(M3UA_PPID, 3).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

add(Config) ->
    gen_server:call(?MODULE, {add, Config}, 10000).

remove(Name) ->
    gen_server:call(?MODULE, {remove, Name}, 10000).

list() ->
    gen_server:call(?MODULE, list).

configs() ->
    gen_server:call(?MODULE, configs).

send(ListenerName, AssocId, Stream, Data) ->
    send(ListenerName, AssocId, Stream, ?M3UA_PPID, Data).

send(ListenerName, AssocId, Stream, Ppid, Data) ->
    gen_server:call(
        ?MODULE,
        {send, ListenerName, AssocId, Stream, Ppid, Data},
        5000
    ).

profile_for_peer(Profiles, RemoteIp, RemotePort) when is_list(Profiles) ->
    case [
        Profile
        || Profile <- Profiles,
           profile_matches(Profile, RemoteIp, RemotePort)
    ] of
        [Profile | _] -> {ok, Profile};
        [] -> {error, no_matching_peer_profile}
    end.

init([]) ->
    {ok, #{listeners => #{}, sockets => #{}}}.

handle_call(
    {add, Config0}, _From,
    #{listeners := Listeners, sockets := Sockets} = State
) ->
    case validate_config(Config0) of
        {ok, #{name := Name} = Config} ->
            case maps:is_key(Name, Listeners) of
                true ->
                    {reply, {error, {already_exists, Name}}, State};
                false ->
                    case open_listener(Config) of
                        {ok, Socket, BoundPort} ->
                            Entry = #{
                                config => Config,
                                socket => Socket,
                                port => BoundPort,
                                associations => #{}
                            },
                            telco_stp_alarm:clear(
                                {listener, Name, transport},
                                #{reason => listener_opened,
                                  port => BoundPort}
                            ),
                            {reply, {ok, #{
                                name => Name, port => BoundPort
                            }}, State#{
                                listeners => Listeners#{Name => Entry},
                                sockets => Sockets#{Socket => Name}
                            }};
                        {error, Reason} = Error ->
                            telco_stp_alarm:raise(
                                {listener, Name, transport}, major,
                                #{listener => Name, reason => Reason}
                            ),
                            {reply, Error, State}
                    end
            end;
        Error ->
            {reply, Error, State}
    end;
handle_call(
    {remove, Name}, _From,
    #{listeners := Listeners, sockets := Sockets} = State
) ->
    case maps:take(Name, Listeners) of
        error ->
            {reply, {error, {not_found, Name}}, State};
        {Entry, Remaining} ->
            remove_association_links(Entry),
            Socket = maps:get(socket, Entry),
            _ = gen_sctp:close(Socket),
            {reply, ok, State#{
                listeners => Remaining,
                sockets => maps:remove(Socket, Sockets)
            }}
    end;
handle_call(
    {send, Name, AssocId, Stream, Ppid, Data}, _From,
    #{listeners := Listeners} = State
) when is_binary(Data), is_integer(Stream), Stream >= 0,
       is_integer(Ppid), Ppid >= 0 ->
    Reply =
        case maps:find(Name, Listeners) of
            {ok, #{socket := Socket, associations := Associations}} ->
                case maps:is_key(AssocId, Associations) of
                    true ->
                        SendInfo = #sctp_sndrcvinfo{
                            assoc_id = AssocId,
                            stream = Stream,
                            ppid = Ppid
                        },
                        gen_sctp:send(Socket, SendInfo, Data);
                    false ->
                        {error, {association_not_found, AssocId}}
                end;
            error ->
                {error, {listener_not_found, Name}}
        end,
    {reply, Reply, State};
handle_call(list, _From, #{listeners := Listeners} = State) ->
    Reply = [
        listener_status(Name, Entry)
        || {Name, Entry} <- maps:to_list(Listeners)
    ],
    {reply, Reply, State};
handle_call(configs, _From, #{listeners := Listeners} = State) ->
    {reply, [
        maps:get(config, Entry) || Entry <- maps:values(Listeners)
    ], State};
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported}, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(
    {sctp, Socket, RemoteIp, RemotePort,
     {_Ancillary, #sctp_assoc_change{
         state = StateName, assoc_id = AssocId
     }}},
    State
) when StateName =:= comm_up; StateName =:= restart ->
    {noreply, association_up(
        Socket, RemoteIp, RemotePort, AssocId, State
    )};
handle_info(
    {sctp, Socket, _RemoteIp, _RemotePort,
     {_Ancillary, #sctp_assoc_change{
         state = StateName, assoc_id = AssocId
     }}},
    State
) when StateName =:= comm_lost; StateName =:= shutdown_comp;
       StateName =:= cant_assoc ->
    {noreply, association_down(Socket, AssocId, StateName, State)};
handle_info(
    {sctp, Socket, _RemoteIp, _RemotePort, {Ancillary, Data}},
    State
) when is_binary(Data) ->
    {noreply, inbound_data(Socket, Ancillary, Data, State)};
handle_info(
    {sctp, Socket, _RemoteIp, _RemotePort,
     {_Ancillary, #sctp_paddr_change{
         state = StateName,
         addr = Address,
         error = Error,
         assoc_id = AssocId
     }}},
    State
) ->
    {noreply, inbound_path_event(
        Socket, AssocId, StateName, Address, Error, State
    )};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #{listeners := Listeners}) ->
    lists:foreach(
        fun(Entry) ->
            _ = gen_sctp:close(maps:get(socket, Entry))
        end,
        maps:values(Listeners)
    ),
    ok.

validate_config(Config) when is_map(Config) ->
    case {maps:find(name, Config), maps:get(profiles, Config, [])} of
        {{ok, Name}, Profiles} when is_list(Profiles), Profiles =/= [] ->
            case lists:all(fun valid_profile/1, Profiles) of
                true ->
                    {ok, Config#{
                        name => Name,
                        port => maps:get(port, Config, ?M3UA_PORT),
                        local_ips => maps:get(local_ips, Config, [any]),
                        backlog => maps:get(backlog, Config, 128),
                        profiles => Profiles
                    }};
                false ->
                    {error, {invalid_listener_profiles, Profiles}}
            end;
        _ ->
            {error, {invalid_listener_config, Config}}
    end;
validate_config(Config) ->
    {error, {invalid_listener_config, Config}}.

valid_profile(Profile) when is_map(Profile) ->
    maps:is_key(linkset, Profile) andalso
    (
        maps:is_key(remote_ip, Profile) orelse
        maps:is_key(remote_ips, Profile) orelse
        maps:get(accept_any, Profile, false) =:= true
    );
valid_profile(_Profile) ->
    false.

open_listener(Config) ->
    Port = maps:get(port, Config),
    LocalIps = maps:get(local_ips, Config),
    Options = [
        binary,
        {active, true},
        {reuseaddr, true},
        {port, Port}
        | [{ip, Ip} || Ip <- LocalIps]
    ],
    case gen_sctp:open(Options) of
        {ok, Socket} ->
            case gen_sctp:listen(Socket, maps:get(backlog, Config)) of
                ok ->
                    case inet:port(Socket) of
                        {ok, BoundPort} -> {ok, Socket, BoundPort};
                        {error, Reason} ->
                            _ = gen_sctp:close(Socket),
                            {error, {sctp_listener_port_failed, Reason}}
                    end;
                {error, Reason} ->
                    _ = gen_sctp:close(Socket),
                    {error, {sctp_listen_failed, Reason}}
            end;
        {error, Reason} ->
            {error, {sctp_listener_open_failed, Reason}}
    end.

association_up(
    Socket, RemoteIp, RemotePort, AssocId,
    #{listeners := Listeners, sockets := Sockets} = State
) ->
    case maps:find(Socket, Sockets) of
        {ok, ListenerName} ->
            Entry = maps:get(ListenerName, Listeners),
            Config = maps:get(config, Entry),
            case profile_for_peer(
                maps:get(profiles, Config), RemoteIp, RemotePort
            ) of
                {ok, Profile} ->
                    LinkConfig = inbound_link_config(
                        ListenerName, AssocId, RemoteIp, RemotePort, Profile
                    ),
                    case telco_stp_link_manager:add(LinkConfig) of
                        {ok, _Pid} ->
                            Association = #{
                                assoc_id => AssocId,
                                remote_ip => RemoteIp,
                                remote_port => RemotePort,
                                link_name => maps:get(name, LinkConfig),
                                profile => maps:get(id, Profile, undefined),
                                profile_config => Profile,
                                state => up
                            },
                            Associations = maps:get(associations, Entry),
                            UpdatedEntry = Entry#{
                                associations =>
                                    Associations#{AssocId => Association}
                            },
                            telco_stp_metrics:increment(
                                {listener, ListenerName, association_up}
                            ),
                            telco_stp_alarm:clear(
                                {listener, ListenerName, transport},
                                #{reason => association_up}
                            ),
                            telco_stp_alarm:clear(
                                {listener, ListenerName, rejected_peer},
                                #{reason => configured_peer_connected}
                            ),
                            telco_stp_alarm:clear(
                                {listener, ListenerName, association, AssocId},
                                #{reason => association_recovered}
                            ),
                            State#{listeners =>
                                Listeners#{ListenerName => UpdatedEntry}
                            };
                        {error, Reason} ->
                            logger:error(
                                "Failed to create inbound M3UA link: ~p",
                                [Reason]
                            ),
                            telco_stp_alarm:raise(
                                {listener, ListenerName, association, AssocId},
                                major,
                                #{
                                    reason => {link_creation_failed, Reason},
                                    remote_ip => RemoteIp,
                                    remote_port => RemotePort
                                }
                            ),
                            _ = gen_sctp:abort(Socket, AssocId),
                            State
                    end;
                {error, no_matching_peer_profile} ->
                    logger:warning(
                        "Rejected unconfigured SCTP peer ~p:~p on ~p",
                        [RemoteIp, RemotePort, ListenerName]
                    ),
                    telco_stp_metrics:increment(
                        {listener, ListenerName, rejected_peer}
                    ),
                    telco_stp_alarm:raise(
                        {listener, ListenerName, rejected_peer}, warning,
                        #{
                            reason => no_matching_peer_profile,
                            remote_ip => RemoteIp,
                            remote_port => RemotePort
                        }
                    ),
                    _ = gen_sctp:abort(Socket, AssocId),
                    State
            end;
        error ->
            State
    end.

association_down(
    Socket, AssocId, Reason,
    #{listeners := Listeners, sockets := Sockets} = State
) ->
    case maps:find(Socket, Sockets) of
        {ok, ListenerName} ->
            Entry = maps:get(ListenerName, Listeners),
            Associations = maps:get(associations, Entry),
            case maps:take(AssocId, Associations) of
                {#{link_name := LinkName}, Remaining} ->
                    _ = telco_stp_link_manager:remove(LinkName),
                    telco_stp_metrics:increment(
                        {listener, ListenerName, association_down}
                    ),
                    logger:notice(
                        "Inbound SCTP association ~p down: ~p",
                        [AssocId, Reason]
                    ),
                    telco_stp_alarm:raise(
                        {listener, ListenerName, association, AssocId}, major,
                        #{reason => Reason, link_name => LinkName}
                    ),
                    Updated = Entry#{associations => Remaining},
                    State#{listeners => Listeners#{ListenerName => Updated}};
                error ->
                    State
            end;
        error ->
            State
    end.

inbound_data(Socket, Ancillary, Data,
             #{listeners := Listeners, sockets := Sockets} = State) ->
    case {maps:find(Socket, Sockets), ancillary_info(Ancillary)} of
        {{ok, ListenerName}, {ok, AssocId, Ppid, Stream}} ->
            Entry = maps:get(ListenerName, Listeners),
            Associations = maps:get(associations, Entry),
            case maps:find(AssocId, Associations) of
                {ok, #{
                    link_name := LinkName,
                    profile_config := Profile
                }} ->
                    Adaptation = maps:get(adaptation, Profile, m3ua),
                    case valid_ppid(Adaptation, Ppid) of
                        true ->
                    telco_stp_alarm:clear(
                        {listener, ListenerName, invalid_ppid},
                                #{reason => valid_ppid,
                                  adaptation => Adaptation}
                    ),
                            _ = telco_stp_link_manager:inject(
                                LinkName, Data,
                                #{stream => Stream, ppid => Ppid}
                            ),
                            State;
                        false ->
                    telco_stp_metrics:increment(
                        {listener, ListenerName, invalid_ppid}
                    ),
                    telco_stp_alarm:raise(
                        {listener, ListenerName, invalid_ppid}, warning,
                                #{
                                    ppid => Ppid,
                                    expected_adaptation => Adaptation,
                                    assoc_id => AssocId
                                }
                    ),
                            State
                    end;
                error ->
                    telco_stp_metrics:increment(
                        {listener, ListenerName, unknown_association}
                    ),
                    telco_stp_alarm:raise(
                        {listener, ListenerName, unknown_association}, warning,
                        #{assoc_id => AssocId}
                    ),
                    State
            end;
        _ ->
            State
    end.

ancillary_info(Ancillary) when is_list(Ancillary) ->
    case [
        Info
        || #sctp_sndrcvinfo{} = Info <- Ancillary
    ] of
        [#sctp_sndrcvinfo{
            assoc_id = AssocId, ppid = Ppid, stream = Stream
        } | _] ->
            {ok, AssocId, Ppid, Stream};
        [] ->
            {error, missing_sctp_sndrcvinfo}
    end;
ancillary_info(#sctp_sndrcvinfo{
    assoc_id = AssocId, ppid = Ppid, stream = Stream
}) ->
    {ok, AssocId, Ppid, Stream};
ancillary_info(_Ancillary) ->
    {error, missing_sctp_sndrcvinfo}.

valid_ppid(_Adaptation, 0) -> true;
valid_ppid(m3ua, ?M3UA_PPID) -> true;
valid_ppid(m3ua, 16#03000000) -> true;
valid_ppid(m2pa, 5) -> true;
valid_ppid(m2pa, 16#05000000) -> true;
valid_ppid(_Adaptation, _Ppid) -> false.

inbound_link_config(
    ListenerName, AssocId, RemoteIp, RemotePort, Profile
) ->
    LinkName =
        case maps:find(link_name, Profile) of
            {ok, Name} -> Name;
            error ->
                case maps:find(link_name_prefix, Profile) of
                    {ok, Prefix} -> {Prefix, AssocId};
                    error -> {inbound, ListenerName, AssocId}
                end
        end,
    (maps:without(
        [
            remote_ip,
            remote_ips,
            remote_port,
            accept_any,
            link_name,
            link_name_prefix
        ],
        Profile
    ))#{
        name => LinkName,
        transport => telco_stp_transport_sctp_inbound,
        listener_name => ListenerName,
        assoc_id => AssocId,
        role => sg,
        auto_activate => false,
        ephemeral => true,
        remote_ip => RemoteIp,
        remote_port => RemotePort
    }.

profile_matches(Profile, RemoteIp, RemotePort) ->
    IpMatches =
        case {
            maps:find(remote_ip, Profile),
            maps:find(remote_ips, Profile),
            maps:get(accept_any, Profile, false)
        } of
            {{ok, RemoteIp}, _, _} -> true;
            {_, {ok, Ips}, _} when is_list(Ips) ->
                lists:member(RemoteIp, Ips);
            {_, _, true} -> true;
            _ -> false
        end,
    PortMatches =
        case maps:find(remote_port, Profile) of
            {ok, RemotePort} -> true;
            {ok, _OtherPort} -> false;
            error -> true
        end,
    IpMatches andalso PortMatches.

listener_status(Name, Entry) ->
    #{
        name => Name,
        port => maps:get(port, Entry),
        local_ips => maps:get(local_ips, maps:get(config, Entry)),
        associations => maps:values(maps:get(associations, Entry))
    }.

remove_association_links(Entry) ->
    lists:foreach(
        fun(#{link_name := LinkName}) ->
            _ = telco_stp_link_manager:remove(LinkName)
        end,
        maps:values(maps:get(associations, Entry))
    ).

inbound_path_event(
    Socket, AssocId, StateName, Address, Error,
    #{listeners := Listeners, sockets := Sockets} = State
) ->
    case maps:find(Socket, Sockets) of
        {ok, ListenerName} ->
            Id = {
                listener, ListenerName, association, AssocId,
                path, Address
            },
            Details = #{
                association => AssocId,
                address => Address,
                state => StateName,
                error => Error
            },
            case StateName of
                addr_available ->
                    telco_stp_alarm:clear(Id, Details);
                addr_added ->
                    telco_stp_alarm:clear(Id, Details);
                addr_made_prim ->
                    telco_stp_alarm:clear(Id, Details);
                addr_unreachable ->
                    telco_stp_alarm:raise(Id, warning, Details);
                addr_removed ->
                    telco_stp_alarm:raise(Id, warning, Details);
                _ ->
                    ok
            end,
            telco_stp_metrics:increment(
                {listener, ListenerName, sctp_path_event}
            ),
            State#{listeners => Listeners};
        error ->
            State
    end.
