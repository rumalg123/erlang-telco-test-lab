-module(telco_stp_link_manager).
-behaviour(gen_server).

-include("telco_stp.hrl").

-export([
    start_link/0,
    add/1,
    remove/1,
    set_admin/2,
    force_state/2,
    set_congestion/2,
    inject/2,
    inject/3,
    send/2,
    send_transfer/2,
    retrieve_m2pa/2,
    select/4,
    select/5,
    select_all/3,
    list/0,
    configs/0
]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

add(Config) ->
    gen_server:call(?MODULE, {add, Config}).

remove(Name) ->
    gen_server:call(?MODULE, {remove, Name}).

set_admin(Name, Admin) ->
    with_link(Name, fun(Pid) -> telco_stp_link:set_admin(Pid, Admin) end).

force_state(Name, State) ->
    with_link(Name, fun(Pid) -> telco_stp_link:force_state(Pid, State) end).

set_congestion(Name, Level) ->
    with_link(Name, fun(Pid) -> telco_stp_link:set_congestion(Pid, Level) end).

inject(Name, Binary) when is_binary(Binary) ->
    inject(Name, Binary, #{}).

inject(Name, Binary, Metadata)
        when is_binary(Binary), is_map(Metadata) ->
    with_link(Name, fun(Pid) ->
        telco_stp_link:inject(Pid, Binary, Metadata),
        ok
    end);
inject(_Name, Value, Metadata) ->
    {error, {invalid_link_payload, Value, Metadata}}.

send(Name, Binary) ->
    with_link(Name, fun(Pid) -> telco_stp_link:send(Pid, Binary) end).

send_transfer(Name, Message) when is_map(Message) ->
    with_link(
        Name,
        fun(Pid) -> telco_stp_link:send_transfer(Pid, Message) end
    );
send_transfer(_Name, Message) ->
    {error, {invalid_transfer, Message}}.

retrieve_m2pa(Name, AfterFsn) ->
    with_link(
        Name,
        fun(Pid) -> telco_stp_link:retrieve_m2pa(Pid, AfterFsn) end
    ).

select(Linksets, Sls, Dpc, Exclude) ->
    select(Linksets, Sls, Dpc, Exclude, #{}).

select(Linksets, Sls, Dpc, Exclude, DestinationCongestion) ->
    gen_server:call(
        ?MODULE,
        {select, Linksets, Sls, Dpc, Exclude, DestinationCongestion}
    ).

select_all(Linksets, Exclude, DestinationCongestion) ->
    gen_server:call(
        ?MODULE,
        {select_all, Linksets, Exclude, DestinationCongestion}
    ).

list() ->
    gen_server:call(?MODULE, list).

configs() ->
    gen_server:call(?MODULE, configs).

init([]) ->
    {ok, #{links => #{}}}.

handle_call({add, Config0}, _From, #{links := Links} = State) ->
    case validate_config(Config0) of
        {ok, Config} ->
            Name = maps:get(name, Config),
            case maps:is_key(Name, Links) of
                true ->
                    {reply, {error, {already_exists, Name}}, State};
                false ->
                    case telco_stp_link_sup:start_link_instance(Name, Config) of
                        {ok, Pid} ->
                            Ref = erlang:monitor(process, Pid),
                            Entry = #{pid => Pid, monitor => Ref, config => Config},
                            {reply, {ok, Pid}, State#{
                                links => Links#{Name => Entry}
                            }};
                        Error ->
                            {reply, Error, State}
                    end
            end;
        Error ->
            {reply, Error, State}
    end;
handle_call({remove, Name}, _From, #{links := Links} = State) ->
    case maps:take(Name, Links) of
        error ->
            {reply, {error, {not_found, Name}}, State};
        {#{monitor := Ref}, Remaining} ->
            maybe_demonitor(Ref),
            _ = telco_stp_rkm:remove_link(Name),
            Reply =
                case telco_stp_link_sup:stop_link_instance(Name) of
                    {error, not_found} -> ok;
                    StopReply -> StopReply
                end,
            {reply, Reply, State#{links => Remaining}}
    end;
handle_call({resolve, Name}, _From, #{links := Links} = State) ->
    Reply =
        case maps:find(Name, Links) of
            {ok, #{pid := Pid}} when is_pid(Pid) ->
                {ok, Pid};
            {ok, _Entry} ->
                {error, {link_unavailable, Name}};
            error ->
                {error, {not_found, Name}}
        end,
    {reply, Reply, State};
handle_call(
    {select, Linksets, Sls, Dpc, Exclude, DestinationCongestion}, _From,
            #{links := Links} = State) ->
    Reply = select_linkset(
        Linksets, Sls, Dpc, Exclude, DestinationCongestion, Links
    ),
    {reply, Reply, State};
handle_call(
    {select_all, Linksets, Exclude, DestinationCongestion}, _From,
    #{links := Links} = State
) ->
    Reply = select_all_linkset(
        Linksets, Exclude, DestinationCongestion, Links
    ),
    {reply, Reply, State};
handle_call(list, _From, #{links := Links} = State) ->
    Statuses = [
        safe_status(Name, Entry) || {Name, Entry} <- maps:to_list(Links)
    ],
    {reply, Statuses, State};
handle_call(configs, _From, #{links := Links} = State) ->
    Configs = [
        Config
        || #{config := Config} <- maps:values(Links),
           maps:get(ephemeral, Config, false) =:= false
    ],
    {reply, Configs, State};
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported}, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info({'DOWN', Ref, process, Pid, Reason}, #{links := Links} = State) ->
    case find_by_monitor(Ref, Pid, maps:to_list(Links)) of
        {ok, Name} ->
            logger:warning("STP link ~p exited: ~p", [Name, Reason]),
            Entry = maps:get(Name, Links),
            _ = erlang:send_after(100, self(), {restart_link, Name}),
            {noreply, State#{links => Links#{Name => Entry#{
                pid => undefined,
                monitor => undefined
            }}}};
        error ->
            {noreply, State}
    end;
handle_info({restart_link, Name}, #{links := Links} = State) ->
    case maps:find(Name, Links) of
        {ok, #{pid := undefined, config := Config} = Entry} ->
            case telco_stp_link_sup:start_link_instance(Name, Config) of
                {ok, Pid} ->
                    Ref = erlang:monitor(process, Pid),
                    {noreply, State#{links => Links#{Name => Entry#{
                        pid => Pid,
                        monitor => Ref
                    }}}};
                {error, {already_started, Pid}} when is_pid(Pid) ->
                    Ref = erlang:monitor(process, Pid),
                    {noreply, State#{links => Links#{Name => Entry#{
                        pid => Pid,
                        monitor => Ref
                    }}}};
                {error, _Reason} ->
                    _ = erlang:send_after(
                        ?STP_LINK_RESTART_RETRY_MS,
                        self(),
                        {restart_link, Name}
                    ),
                    {noreply, State}
            end;
        _ ->
            {noreply, State}
    end;
handle_info(_Info, State) ->
    {noreply, State}.

with_link(Name, Function) ->
    case gen_server:call(?MODULE, {resolve, Name}) of
        {ok, Pid} ->
            try Function(Pid)
            catch
                exit:Reason -> {error, {link_call_failed, Name, Reason}}
            end;
        Error ->
            Error
    end.

validate_config(Config) when is_map(Config) ->
    case {maps:find(name, Config), maps:find(linkset, Config)} of
        {{ok, Name}, {ok, Linkset}} ->
            Module = maps:get(transport, Config, telco_stp_transport_loopback),
            Weight = maps:get(weight, Config, 1),
            HeartbeatInterval = maps:get(
                heartbeat_interval_ms, Config, 0
            ),
            HeartbeatTimeout = maps:get(
                heartbeat_timeout_ms, Config,
                ?STP_DEFAULT_HEARTBEAT_TIMEOUT_MS
            ),
            HeartbeatAction = maps:get(
                heartbeat_failure_action, Config, inactive
            ),
            SccpVariant = maps:get(sccp_variant, Config, itu),
            SccpReassembly = maps:get(
                sccp_reassembly, Config, false
            ),
            Adaptation = maps:get(adaptation, Config, m3ua),
            PointCodeVariant = maps:get(
                point_code_variant, Config, SccpVariant
            ),
            Rkm = maps:get(rkm, Config, undefined),
            case valid_transport(Module) andalso
                 valid_weight(Weight) andalso
                 valid_heartbeat_interval(HeartbeatInterval) andalso
                 valid_heartbeat_timeout(HeartbeatTimeout) andalso
                 valid_heartbeat_action(HeartbeatAction) andalso
                 valid_point_code_variant(SccpVariant) andalso
                 valid_point_code_variant(PointCodeVariant) andalso
                 is_boolean(SccpReassembly) andalso
                 valid_adaptation(Adaptation) andalso
                 valid_rkm_config(Rkm) andalso
                 valid_adaptation_config(Adaptation, Rkm, Config) of
                true ->
                    {ok, Config#{
                        name => Name,
                        linkset => Linkset,
                        transport => Module,
                        adaptation => Adaptation,
                        weight => Weight
                    }};
                false ->
                    {error, {invalid_link_config, Config}}
            end;
        _ ->
            {error, {missing_link_name_or_linkset, Config}}
    end;
validate_config(Config) ->
    {error, {invalid_link_config, Config}}.

valid_weight(Value) ->
    telco_stp_codec:in_range(Value, 1, ?STP_PERCENT_SCALE).

valid_heartbeat_interval(Value) ->
    telco_stp_codec:in_range(Value, 0, ?STP_MAX_MILLISECONDS).

valid_heartbeat_timeout(Value) ->
    telco_stp_codec:in_range(Value, 1, ?STP_MAX_MILLISECONDS).

valid_heartbeat_action(inactive) -> true;
valid_heartbeat_action(reconnect) -> true;
valid_heartbeat_action(_Action) -> false.

valid_point_code_variant(itu) -> true;
valid_point_code_variant(ansi) -> true;
valid_point_code_variant(_Variant) -> false.

valid_adaptation(m3ua) -> true;
valid_adaptation(m2pa) -> true;
valid_adaptation(_Adaptation) -> false.

valid_rkm_config(undefined) ->
    true;
valid_rkm_config(#{mode := Mode})
        when Mode =:= dynamic; Mode =:= provisioned_only ->
    true;
valid_rkm_config(_Rkm) ->
    false.

valid_adaptation_config(m3ua, _Rkm, _Config) ->
    true;
valid_adaptation_config(m2pa, undefined, Config) ->
    Proving = maps:get(
        m2pa_proving_ms, Config, ?STP_DEFAULT_M2PA_PROVING_MS
    ),
    Alignment = maps:get(
        m2pa_alignment_timeout_ms, Config,
        ?STP_DEFAULT_M2PA_ALIGNMENT_TIMEOUT_MS
    ),
    T7 = maps:get(m2pa_t7_ms, Config, ?STP_DEFAULT_M2PA_T7_MS),
    Maximum = maps:get(
        m2pa_max_unacked, Config, ?STP_DEFAULT_M2PA_MAX_UNACKED
    ),
    Filler = maps:get(m2pa_proving_filler_bytes, Config, 0),
    valid_m2pa_positive_values([Proving, Alignment, T7, Maximum]) andalso
    valid_m2pa_filler_bytes(Filler);
valid_adaptation_config(m2pa, _Rkm, _Config) ->
    false.

valid_m2pa_positive_values(Values) ->
    lists:all(fun valid_positive_integer/1, Values).

valid_positive_integer(Value) ->
    is_integer(Value) andalso Value > 0.

valid_m2pa_filler_bytes(Value) ->
    telco_stp_codec:in_range(Value, 0, ?STP_MAX_SHORT_BYTES).

valid_transport(Module) when is_atom(Module) ->
    case code:ensure_loaded(Module) of
        {module, Module} ->
            lists:all(
                fun({Function, Arity}) ->
                    erlang:function_exported(Module, Function, Arity)
                end,
                [{open, 2}, {send, 2}, {handle_info, 2}, {close, 1}]
            );
        _ ->
            false
    end;
valid_transport(_Module) ->
    false.

select_linkset(
    [], _Sls, _Dpc, _Exclude, _DestinationCongestion, _Links
) ->
    {error, no_available_link};
select_linkset(
    [Linkset | Rest], Sls, Dpc, Exclude, DestinationCongestion, Links
) ->
    Eligible = eligible(
        Linkset, Exclude, DestinationCongestion, maps:to_list(Links)
    ),
    case Eligible of
        [] ->
            select_linkset(
                Rest, Sls, Dpc, Exclude, DestinationCongestion, Links
            );
        _ ->
            LowestCongestion = lists:min([
                maps:get(congestion, Status) || {_Name, _Entry, Status} <- Eligible
            ]),
            Best = [
                Item || {_Name, _Entry, Status} = Item <- Eligible,
                        maps:get(congestion, Status) =:= LowestCongestion
            ],
            Sorted = lists:sort(
                fun({NameA, _, _}, {NameB, _, _}) -> NameA =< NameB end,
                Best
            ),
            TotalWeight = lists:sum([
                maps:get(weight, maps:get(config, Entry), 1)
                || {_Name, Entry, _Status} <- Sorted
            ]),
            Position = erlang:phash2({Sls, Dpc}, TotalWeight),
            {Name, Entry, Status} = weighted_pick(Position, Sorted),
            {ok, #{
                name => Name,
                pid => maps:get(pid, Entry),
                linkset => Linkset,
                congestion => maps:get(congestion, Status)
            }}
    end.

select_all_linkset(
    [], _Exclude, _DestinationCongestion, _Links
) ->
    {error, no_available_link};
select_all_linkset(
    [Linkset | Rest], Exclude, DestinationCongestion, Links
) ->
    case eligible(
        Linkset, Exclude, DestinationCongestion, maps:to_list(Links)
    ) of
        [] ->
            select_all_linkset(
                Rest, Exclude, DestinationCongestion, Links
            );
        Eligible ->
            Sorted = lists:sort(
                fun({NameA, _, _}, {NameB, _, _}) -> NameA =< NameB end,
                Eligible
            ),
            {ok, [
                #{
                    name => Name,
                    pid => maps:get(pid, Entry),
                    linkset => Linkset,
                    congestion => maps:get(congestion, Status)
                }
                || {Name, Entry, Status} <- Sorted
            ]}
    end.

eligible(Linkset, Exclude, DestinationCongestion, Links) ->
    lists:filtermap(
        fun({Name, #{pid := Pid, config := Config} = Entry}) ->
            case is_pid(Pid) andalso
                 maps:get(linkset, Config) =:= Linkset andalso
                 not lists:member(Name, Exclude) of
                true ->
                    case read_link_status(Pid) of
                        {ok, #{
                            state := active,
                            admin := up,
                            congestion := Level
                        } = Status}
                                when Level < 3 ->
                            DestinationLevel = maps:get(
                                Name, DestinationCongestion, 0
                            ),
                            EffectiveLevel = max(Level, DestinationLevel),
                            case EffectiveLevel < 3 of
                                true ->
                                    {true, {
                                        Name, Entry,
                                        Status#{
                                            congestion => EffectiveLevel
                                        }
                                    }};
                                false ->
                                    false
                            end;
                        _ ->
                            false
                    end;
                false ->
                    false
            end
        end,
        Links
    ).

weighted_pick(Position, [{_Name, Entry, _Status} = Item | Rest]) ->
    Weight = maps:get(weight, maps:get(config, Entry), 1),
    case Position < Weight of
        true -> Item;
        false -> weighted_pick(Position - Weight, Rest)
    end.

safe_status(Name, #{pid := Pid, config := Config}) ->
    case is_pid(Pid) andalso read_link_status(Pid) of
        {ok, Status} ->
            Status#{weight => maps:get(weight, Config, 1)};
        Error ->
            #{
                name => Name,
                state => unavailable,
                linkset => maps:get(linkset, Config),
                last_error => Error
            }
    end.

read_link_status(Pid) ->
    try telco_stp_link:status(Pid) of
        Status when is_map(Status) -> {ok, Status};
        Other -> {error, {unexpected_status, Other}}
    catch
        exit:Reason -> {error, Reason}
    end.

find_by_monitor(_Ref, _Pid, []) ->
    error;
find_by_monitor(Ref, Pid, [
    {Name, #{monitor := Ref, pid := Pid}} | _Rest
]) ->
    {ok, Name};
find_by_monitor(Ref, Pid, [_ | Rest]) ->
    find_by_monitor(Ref, Pid, Rest).

maybe_demonitor(Ref) when is_reference(Ref) ->
    erlang:demonitor(Ref, [flush]);
maybe_demonitor(_Ref) ->
    ok.
