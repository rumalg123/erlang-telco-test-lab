-module(telco_stp_route_table).
-behaviour(gen_server).

-include("telco_stp.hrl").

-export([
    start_link/0,
    add/1,
    remove/1,
    lookup/1,
    list/0,
    update_ssnm/3,
    set_destination_state/4,
    destination_states/0,
    path_constraints/1
]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

add(Route) ->
    gen_server:call(?MODULE, {add, Route}).

remove(Id) ->
    gen_server:call(?MODULE, {remove, Id}).

lookup(Message) ->
    gen_server:call(?MODULE, {lookup, Message}).

list() ->
    gen_server:call(?MODULE, list).

update_ssnm(SourceLink, Type, Params) ->
    gen_server:call(?MODULE, {update_ssnm, SourceLink, Type, Params}).

set_destination_state(SourceLink, Status, Affected, Metadata) ->
    gen_server:call(
        ?MODULE,
        {set_destination_state, SourceLink, Status, Affected, Metadata}
    ).

destination_states() ->
    gen_server:call(?MODULE, destination_states).

path_constraints(Message) ->
    gen_server:call(?MODULE, {path_constraints, Message}).

init([]) ->
    {ok, #{routes => #{}, destination_states => #{}}}.

handle_call({add, Route0}, _From, #{routes := Routes} = State) ->
    case normalize(Route0) of
        {ok, #{id := Id} = Route} ->
            case maps:is_key(Id, Routes) of
                true ->
                    {reply, {error, {already_exists, Id}}, State};
                false ->
                    {reply, ok, State#{routes => Routes#{Id => Route}}}
            end;
        Error ->
            {reply, Error, State}
    end;
handle_call({remove, Id}, _From, #{routes := Routes} = State) ->
    {reply, ok, State#{routes => maps:remove(Id, Routes)}};
handle_call({lookup, Message}, _From, #{routes := Routes} = State) ->
    Reply =
        case validate_lookup(Message) of
            ok ->
                Matches = [
                    Route
                    || Route <- maps:values(Routes),
                       route_matches(Route, Message)
                ],
                lists:sort(fun route_before/2, Matches);
            Error ->
                Error
        end,
    {reply, Reply, State};
handle_call(list, _From, #{routes := Routes} = State) ->
    {reply, lists:sort(fun route_before/2, maps:values(Routes)), State};
handle_call(
    {update_ssnm, SourceLink, Type, Params}, _From,
    #{destination_states := Destinations} = State
) ->
    case normalize_ssnm(Type, Params) of
        {ok, Status, Affected, Metadata} ->
            Updated = apply_destination_update(
                SourceLink, Status, Affected, Metadata, Destinations
            ),
            emit_destination_alarms(
                SourceLink, Status, Affected, Metadata
            ),
            {reply, ok, State#{destination_states => Updated}};
        Error ->
            {reply, Error, State}
    end;
handle_call(
    {set_destination_state, SourceLink, Status, Affected, Metadata}, _From,
    #{destination_states := Destinations} = State
) ->
    case validate_destination_update(Status, Affected, Metadata) of
        ok ->
            Updated = apply_destination_update(
                SourceLink, Status, Affected, Metadata, Destinations
            ),
            emit_destination_alarms(
                SourceLink, Status, Affected, Metadata
            ),
            {reply, ok, State#{destination_states => Updated}};
        Error ->
            {reply, Error, State}
    end;
handle_call(
    destination_states, _From,
    #{destination_states := Destinations} = State
) ->
    {reply, maps:values(Destinations), State};
handle_call(
    {path_constraints, Message}, _From,
    #{destination_states := Destinations} = State
) ->
    Reply =
        case validate_lookup(Message) of
            ok -> constraints(Message, maps:values(Destinations));
            Error -> Error
        end,
    {reply, Reply, State};
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported}, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

normalize(Route) when is_map(Route) ->
    Required = [id, dpc, linksets],
    case [Key || Key <- Required, not maps:is_key(Key, Route)] of
        [] ->
            Dpc = maps:get(dpc, Route),
            Mask = maps:get(mask, Route, ?STP_POINT_CODE_MASK_24),
            Linksets = maps:get(linksets, Route),
            Priority = maps:get(priority, Route, 100),
            Ni = maps:get(ni, Route, any),
            Si = maps:get(si, Route, any),
            OpcPatterns = maps:get(opc_patterns, Route, any),
            NetworkAppearance = maps:get(
                network_appearance, Route, any
            ),
            RoutingContext = maps:get(
                routing_context, Route, undefined
            ),
            TrafficMode = maps:get(traffic_mode, Route, loadshare),
            Enabled = maps:get(enabled, Route, true),
            case valid_uint24(Dpc) andalso valid_uint24(Mask) andalso
                 is_list(Linksets) andalso Linksets =/= [] andalso
                 is_integer(Priority) andalso Priority >= 0 andalso
                 valid_selector(Ni, 3) andalso valid_selector(Si, 15) andalso
                 valid_pc_patterns(OpcPatterns) andalso
                 valid_selector(NetworkAppearance, ?STP_UINT32_MAX) andalso
                 valid_routing_context(RoutingContext) andalso
                 valid_traffic_mode(TrafficMode) andalso
                 is_boolean(Enabled) of
                true ->
                    {ok, Route#{
                        mask => Mask,
                        priority => Priority,
                        ni => Ni,
                        si => Si,
                        opc_patterns => OpcPatterns,
                        network_appearance => NetworkAppearance,
                        routing_context => RoutingContext,
                        traffic_mode => TrafficMode,
                        enabled => Enabled,
                        specificity => popcount(Mask)
                    }};
                false ->
                    {error, {invalid_route, Route}}
            end;
        Missing ->
            {error, {missing_route_fields, Missing}}
    end;
normalize(Route) ->
    {error, {invalid_route, Route}}.

validate_lookup(#{dpc := Dpc, ni := Ni, si := Si})
        when is_integer(Dpc), Dpc >= 0,
             Dpc =< ?STP_POINT_CODE_MASK_24,
             is_integer(Ni), Ni >= 0, Ni =< 3,
             is_integer(Si), Si >= 0, Si =< 15 ->
    ok;
validate_lookup(Message) ->
    {error, {invalid_route_lookup, Message}}.

route_matches(
    #{
        dpc := RouteDpc,
        mask := Mask,
        ni := RouteNi,
        si := RouteSi,
        opc_patterns := OpcPatterns,
        network_appearance := RouteNa,
        enabled := true
    },
    #{dpc := Dpc, ni := Ni, si := Si} = Message
) ->
    Opc = maps:get(opc, Message, any),
    (Dpc band Mask) =:= (RouteDpc band Mask) andalso
    selector_matches(RouteNi, Ni) andalso
    selector_matches(RouteSi, Si) andalso
    pc_patterns_match(OpcPatterns, Opc) andalso
    selector_matches(
        RouteNa, maps:get(network_appearance, Message, any)
    );
route_matches(_Route, _Message) ->
    false.

selector_matches(any, _Value) -> true;
selector_matches(Value, Value) -> true;
selector_matches(Values, Value) when is_list(Values) ->
    lists:member(Value, Values);
selector_matches(_Selector, _Value) -> false.

route_before(A, B) ->
    SpecificityA = maps:get(specificity, A),
    SpecificityB = maps:get(specificity, B),
    PriorityA = maps:get(priority, A),
    PriorityB = maps:get(priority, B),
    case SpecificityA =:= SpecificityB of
        true ->
            case PriorityA =:= PriorityB of
                true -> maps:get(id, A) =< maps:get(id, B);
                false -> PriorityA < PriorityB
            end;
        false ->
            SpecificityA > SpecificityB
    end.

valid_uint24(Value) ->
    is_integer(Value) andalso Value >= 0 andalso
        Value =< ?STP_POINT_CODE_MASK_24.

valid_selector(any, _Max) ->
    true;
valid_selector(Value, Max) when is_integer(Value) ->
    Value >= 0 andalso Value =< Max;
valid_selector(Values, Max) when is_list(Values), Values =/= [] ->
    lists:all(
        fun(Value) ->
            is_integer(Value) andalso Value >= 0 andalso Value =< Max
        end,
        Values
    );
valid_selector(_Value, _Max) ->
    false.

valid_pc_patterns(any) ->
    true;
valid_pc_patterns(Patterns) when is_list(Patterns), Patterns =/= [] ->
    lists:all(
        fun({Mask, PointCode}) ->
            valid_uint24(Mask) andalso valid_uint24(PointCode)
        end,
        Patterns
    );
valid_pc_patterns(_Patterns) ->
    false.

pc_patterns_match(any, _PointCode) ->
    true;
pc_patterns_match(_Patterns, any) ->
    false;
pc_patterns_match(Patterns, PointCode) ->
    lists:any(
        fun({Mask, PatternPointCode}) ->
            (PointCode band Mask) =:= (PatternPointCode band Mask)
        end,
        Patterns
    ).

valid_routing_context(undefined) ->
    true;
valid_routing_context(Value) ->
    is_integer(Value) andalso Value >= 0 andalso Value =< ?STP_UINT32_MAX.

valid_traffic_mode(override) -> true;
valid_traffic_mode(loadshare) -> true;
valid_traffic_mode(broadcast) -> true;
valid_traffic_mode(_Mode) -> false.

popcount(Value) ->
    popcount(Value, 0).

popcount(0, Count) ->
    Count;
popcount(Value, Count) ->
    popcount(Value band (Value - 1), Count + 1).

normalize_ssnm(Type, Params)
        when Type =:= duna; Type =:= dava; Type =:= drst;
             Type =:= scon; Type =:= dupu ->
    case maps:find(affected_point_code, Params) of
        {ok, Affected} ->
            Metadata0 = maps:with(
                [
                    network_appearance,
                    routing_context,
                    congestion_indications,
                    concerned_destination,
                    user_cause,
                    info_string
                ],
                Params
            ),
            case ssnm_status(Type, Params, Metadata0) of
                {ok, Status, Metadata} ->
                    case validate_destination_update(
                        Status, Affected, Metadata
                    ) of
                        ok -> {ok, Status, Affected, Metadata};
                        Error -> Error
                    end;
                Error ->
                    Error
            end;
        error ->
            {error, {missing_ssnm_parameter, affected_point_code}}
    end;
normalize_ssnm(Type, _Params) ->
    {error, {unsupported_ssnm_update, Type}}.

ssnm_status(duna, _Params, Metadata) ->
    {ok, unavailable, Metadata};
ssnm_status(dava, _Params, Metadata) ->
    {ok, available, Metadata};
ssnm_status(drst, _Params, Metadata) ->
    {ok, restricted, Metadata};
ssnm_status(scon, Params, Metadata) ->
    Level = maps:get(congestion_indications, Params, 1),
    case Level of
        0 -> {ok, available, Metadata};
        Value when is_integer(Value), Value >= 1, Value =< 3 ->
            {ok, congested, Metadata#{congestion => Value}};
        Value ->
            {error, {invalid_congestion_indications, Value}}
    end;
ssnm_status(dupu, Params, Metadata) ->
    case maps:find(user_cause, Params) of
        {ok, {Cause, User}}
                when is_integer(Cause), Cause >= 0, Cause =< 16#ffff,
                     is_integer(User), User >= 0, User =< 16#ffff ->
            {ok, user_unavailable, Metadata#{
                cause => Cause, user_part => User
            }};
        _ ->
            {error, {missing_or_invalid_ssnm_parameter, user_cause}}
    end.

validate_destination_update(Status, Affected, Metadata)
        when Status =:= unavailable; Status =:= available;
             Status =:= restricted; Status =:= congested;
             Status =:= user_unavailable ->
    ValidAffected = is_list(Affected) andalso Affected =/= [] andalso
        lists:all(
            fun({Mask, Dpc}) ->
                is_integer(Mask) andalso Mask >= 0 andalso Mask =< 255 andalso
                valid_uint24(Dpc)
            end,
            Affected
        ),
    case ValidAffected andalso is_map(Metadata) of
        true -> ok;
        false ->
            {error, {invalid_destination_update, Status, Affected, Metadata}}
    end;
validate_destination_update(Status, Affected, Metadata) ->
    {error, {invalid_destination_update, Status, Affected, Metadata}}.

apply_destination_update(Source, available, Affected, Metadata, Destinations) ->
    lists:foldl(
        fun({Mask, Dpc}, Acc) ->
            remove_destination_entries(Source, Mask, Dpc, Metadata, Acc)
        end,
        Destinations,
        Affected
    );
apply_destination_update(Source, Status, Affected, Metadata, Destinations) ->
    lists:foldl(
        fun({Mask, Dpc}, Acc) ->
            NetworkAppearance = maps:get(
                network_appearance, Metadata, any
            ),
            UserPart = maps:get(user_part, Metadata, any),
            Key = {Source, NetworkAppearance, Mask, Dpc, UserPart},
            Entry = Metadata#{
                source_link => Source,
                status => Status,
                mask => Mask,
                dpc => Dpc,
                network_appearance => NetworkAppearance,
                user_part => UserPart,
                updated_at => erlang:system_time(millisecond)
            },
            Acc#{Key => Entry}
        end,
        Destinations,
        Affected
    ).

remove_destination_entries(Source, Mask, Dpc, Metadata, Destinations) ->
    NetworkAppearance = maps:get(network_appearance, Metadata, any),
    maps:filter(
        fun(
            {EntrySource, EntryNa, EntryMask, EntryDpc, _UserPart},
            _Entry
        ) ->
            not (
                EntrySource =:= Source andalso
                EntryMask =:= Mask andalso
                EntryDpc =:= Dpc andalso
                network_appearance_matches(NetworkAppearance, EntryNa)
            )
        end,
        Destinations
    ).

constraints(Message, Entries) ->
    Matching = [
        Entry || Entry <- Entries, destination_matches(Entry, Message)
    ],
    #{
        unavailable => lists:usort([
            maps:get(source_link, Entry)
            || Entry <- Matching,
               lists:member(
                   maps:get(status, Entry),
                   [unavailable, user_unavailable]
               )
        ]),
        restricted => lists:usort([
            maps:get(source_link, Entry)
            || Entry <- Matching,
               maps:get(status, Entry) =:= restricted
        ]),
        congestion => maps:from_list([
            {
                maps:get(source_link, Entry),
                maps:get(congestion, Entry, 1)
            }
            || Entry <- Matching,
               maps:get(status, Entry) =:= congested
        ])
    }.

destination_matches(
    #{
        dpc := AffectedDpc,
        mask := WildcardBits,
        network_appearance := EntryNa,
        user_part := UserPart
    },
    Message
) ->
    Dpc = maps:get(dpc, Message),
    Na = maps:get(network_appearance, Message, any),
    Si = maps:get(si, Message),
    point_code_matches(Dpc, AffectedDpc, WildcardBits) andalso
    network_appearance_matches(Na, EntryNa) andalso
    (UserPart =:= any orelse UserPart =:= Si).

point_code_matches(_Dpc, _Affected, WildcardBits)
        when WildcardBits >= 24 ->
    true;
point_code_matches(Dpc, Affected, WildcardBits) ->
    (Dpc bsr WildcardBits) =:= (Affected bsr WildcardBits).

network_appearance_matches(any, _Value) -> true;
network_appearance_matches(_Value, any) -> true;
network_appearance_matches(Value, Value) -> true;
network_appearance_matches(_A, _B) -> false.

emit_destination_alarms(Source, Status, Affected, Metadata) ->
    lists:foreach(
        fun({Mask, Dpc}) ->
            Id = {destination, Source, Mask, Dpc},
            Details = Metadata#{
                source_link => Source,
                status => Status,
                mask => Mask,
                dpc => Dpc
            },
            case Status of
                available ->
                    telco_stp_alarm:clear(Id, Details);
                unavailable ->
                    telco_stp_alarm:raise(Id, major, Details);
                user_unavailable ->
                    telco_stp_alarm:raise(Id, major, Details);
                restricted ->
                    telco_stp_alarm:raise(Id, minor, Details);
                congested ->
                    telco_stp_alarm:raise(
                        Id, congestion_severity(
                            maps:get(congestion, Metadata, 1)
                        ), Details
                    )
            end
        end,
        Affected
    ).

congestion_severity(3) -> major;
congestion_severity(2) -> minor;
congestion_severity(_Level) -> warning.
