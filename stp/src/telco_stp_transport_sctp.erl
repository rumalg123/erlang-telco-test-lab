-module(telco_stp_transport_sctp).
-behaviour(telco_stp_transport).

-include("telco_stp.hrl").
-include_lib("kernel/include/inet_sctp.hrl").

-export([open/2, send/2, handle_info/2, close/1]).

open(Owner, Config) ->
    case remote_endpoint(Config) of
        {ok, Endpoint} ->
            Adaptation = maps:get(adaptation, Config, m3ua),
            RemotePort = maps:get(
                remote_port, Config, default_port(Adaptation)
            ),
            LocalPort = maps:get(local_port, Config, 0),
            LocalIps = maps:get(local_ips, Config, [any]),
            Options = [
                binary,
                {active, true},
                {reuseaddr, true},
                {port, LocalPort}
                | [{ip, Ip} || Ip <- LocalIps]
            ],
            case gen_sctp:open(Options) of
                {ok, Socket} ->
                    ConnectTimeout = maps:get(
                        connect_timeout_ms, Config,
                        ?STP_DEFAULT_CONNECT_TIMEOUT_MS
                    ),
                    case connect(
                        Socket, Endpoint, RemotePort, ConnectTimeout
                    ) of
                        {ok, #sctp_assoc_change{assoc_id = AssocId}} ->
                            ok = gen_sctp:controlling_process(Socket, Owner),
                            {ok, #{
                                socket => Socket,
                                assoc_id => AssocId,
                                stream => maps:get(stream, Config, 0),
                                adaptation => Adaptation,
                                ppid => adaptation_ppid(Adaptation),
                                remote_endpoint => Endpoint
                            }};
                        {error, Reason} ->
                            _ = gen_sctp:close(Socket),
                            {error, {sctp_connect_failed, Reason}}
                    end;
                {error, Reason} ->
                    {error, {sctp_open_failed, Reason}}
            end;
        Error ->
            Error
    end.

send({stream, Stream, Data}, State)
        when is_integer(Stream), Stream >= 0, is_binary(Data) ->
    send_on_stream(Stream, Data, State);
send(Data, #{stream := Stream} = State) when is_binary(Data) ->
    send_on_stream(Stream, Data, State).

send_on_stream(Stream, Data, #{
    socket := Socket, assoc_id := AssocId, ppid := Ppid
} = State) ->
    SendInfo = #sctp_sndrcvinfo{
        assoc_id = AssocId,
        stream = Stream,
        ppid = Ppid
    },
    case gen_sctp:send(Socket, SendInfo, Data) of
        ok -> {ok, State};
        {error, Reason} -> {error, {sctp_send_failed, Reason}, State}
    end.

handle_info(
    {sctp, Socket, _RemoteIp, _RemotePort, {Ancillary, Data}},
    #{socket := Socket, assoc_id := AssocId} = State
) when is_binary(Data) ->
    case ancillary_info(Ancillary) of
        {ok, AssocId, Ppid, Stream} ->
            Adaptation = maps:get(adaptation, State),
            case valid_ppid(Adaptation, Ppid) of
                true ->
                    {data, Data, #{stream => Stream, ppid => Ppid}, State};
                false ->
                    {event, {invalid_ppid, Adaptation, Ppid}, State}
            end;
        {ok, OtherAssocId, _Ppid, _Stream} ->
            {event, {unexpected_sctp_association, OtherAssocId}, State};
        {error, Reason} ->
            {event, Reason, State}
    end;
handle_info(
    {sctp, Socket, _RemoteIp, _RemotePort,
     {_Ancillary, #sctp_paddr_change{
         state = StateName,
         addr = Address,
         error = Error,
         assoc_id = AssocId
     }}},
    #{socket := Socket, assoc_id := AssocId} = State
) ->
    {event, {sctp_path, StateName, Address, Error}, State};
handle_info(
    {sctp, Socket, _RemoteIp, _RemotePort,
     {_Ancillary, #sctp_assoc_change{state = StateName}}},
    #{socket := Socket} = State
) when StateName =:= comm_lost; StateName =:= shutdown_comp;
       StateName =:= cant_assoc ->
    {down, {sctp_association, StateName}, State};
handle_info({sctp_error, Socket, Reason}, #{socket := Socket} = State) ->
    {down, {sctp_error, Reason}, State};
handle_info({sctp_closed, Socket}, #{socket := Socket} = State) ->
    {down, sctp_closed, State};
handle_info(_Info, State) ->
    {ignore, State}.

close(#{socket := Socket}) ->
    _ = gen_sctp:close(Socket),
    ok;
close(_State) ->
    ok.

remote_endpoint(Config) ->
    case {
        maps:find(remote_host, Config),
        maps:find(remote_hosts, Config)
    } of
        {{ok, Host}, error} ->
            {ok, {single, Host}};
        {error, {ok, Hosts}} when is_list(Hosts), Hosts =/= [] ->
            {ok, {multiple, Hosts}};
        {error, error} ->
            {error, {missing_transport_option, remote_host}};
        _ ->
            {error, conflicting_remote_host_options}
    end.

connect(Socket, {single, RemoteHost}, RemotePort, ConnectTimeout) ->
    gen_sctp:connect(
        Socket, RemoteHost, RemotePort, [], ConnectTimeout
    );
connect(Socket, {multiple, RemoteHosts}, RemotePort, ConnectTimeout) ->
    try gen_sctp:connectx_init(
        Socket, RemoteHosts, RemotePort, [], ConnectTimeout
    ) of
        {ok, AssocId} ->
            await_connectx(Socket, AssocId, ConnectTimeout);
        {error, _Reason} = Error ->
            Error
    catch
        error:Reason -> {error, Reason}
    end.

await_connectx(Socket, AssocId, Timeout) ->
    receive
        {sctp, Socket, _RemoteIp, _RemotePort,
         {_Ancillary, #sctp_assoc_change{
             state = comm_up, assoc_id = AssocId
         } = Association}} ->
            {ok, Association};
        {sctp, Socket, _RemoteIp, _RemotePort,
         {_Ancillary, #sctp_assoc_change{
             state = StateName, assoc_id = AssocId
         }}} when StateName =:= comm_lost; StateName =:= cant_assoc;
                  StateName =:= shutdown_comp ->
            {error, {association_failed, StateName}}
    after Timeout ->
        {error, connect_timeout}
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

default_port(m3ua) -> ?STP_M3UA_PORT;
default_port(m2pa) -> ?STP_M2PA_PORT.

adaptation_ppid(m3ua) -> ?STP_M3UA_PPID;
adaptation_ppid(m2pa) -> ?STP_M2PA_PPID.

valid_ppid(_Adaptation, 0) -> true;
valid_ppid(m3ua, ?STP_M3UA_PPID) -> true;
valid_ppid(m3ua, ?STP_M3UA_NETWORK_PPID) -> true;
valid_ppid(m2pa, ?STP_M2PA_PPID) -> true;
valid_ppid(m2pa, ?STP_M2PA_NETWORK_PPID) -> true;
valid_ppid(_Adaptation, _Ppid) -> false.
