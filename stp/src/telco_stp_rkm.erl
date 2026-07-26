-module(telco_stp_rkm).
-behaviour(gen_server).

-export([
    start_link/0,
    register/4,
    deregister/4,
    record_peer_results/3,
    remove_link/1,
    contexts_for_link/1,
    registrations/0,
    status/0
]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(UINT32_MAX, 16#ffffffff).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

register(Link, LinkState, Config, RoutingKeys) ->
    gen_server:call(
        ?MODULE, {register, Link, LinkState, Config, RoutingKeys}, 10000
    ).

deregister(Link, LinkState, Config, RoutingContexts) ->
    gen_server:call(
        ?MODULE,
        {deregister, Link, LinkState, Config, RoutingContexts},
        10000
    ).

record_peer_results(Link, Type, Results) ->
    gen_server:cast(?MODULE, {peer_results, Link, Type, Results}).

remove_link(Link) ->
    gen_server:call(?MODULE, {remove_link, Link}).

contexts_for_link(Link) ->
    gen_server:call(?MODULE, {contexts_for_link, Link}).

registrations() ->
    gen_server:call(?MODULE, registrations).

status() ->
    gen_server:call(?MODULE, status).

init([]) ->
    Policy0 = application:get_env(telco_stp, rkm_policy, #{}),
    Policy = normalize_global_policy(Policy0),
    {ok, #{
        registrations => #{},
        next_rc => maps:get(rc_start, Policy),
        policy => Policy,
        peer_results => #{}
    }}.

handle_call(
    {register, Link, LinkState, Config, RoutingKeys}, _From, State
) ->
    case registration_request_allowed(LinkState, Config, State) of
        {ok, Policy} ->
            {Results, NewState} = register_keys(
                RoutingKeys, Link, Config, Policy, State
            ),
            {reply, {ok, Results}, NewState};
        {error, Status} ->
            Results = registration_failures(RoutingKeys, Status),
            {reply, {ok, Results}, State}
    end;
handle_call(
    {deregister, Link, LinkState, Config, RoutingContexts}, _From, State
) ->
    case peer_policy(Config, maps:get(policy, State)) of
        {ok, _Policy} ->
            {Results, NewState} = deregister_contexts(
                RoutingContexts, Link, LinkState, State
            ),
            {reply, {ok, Results}, NewState};
        {error, _Reason} ->
            Results = [
                #{
                    routing_context => Rc,
                    deregistration_status => permission_denied
                }
                || Rc <- valid_context_list(RoutingContexts)
            ],
            {reply, {ok, Results}, State}
    end;
handle_call({remove_link, Link}, _From, State) ->
    {Removed, NewState} = remove_link_registrations(Link, State),
    {reply, {ok, Removed}, NewState};
handle_call({contexts_for_link, Link}, _From, State) ->
    Contexts = [
        Rc
        || {Rc, Entry} <- maps:to_list(maps:get(registrations, State)),
           maps:get(source_link, Entry) =:= Link
    ],
    {reply, lists:sort(Contexts), State};
handle_call(registrations, _From, State) ->
    Entries = lists:sort(
        fun(A, B) ->
            maps:get(routing_context, A) =<
                maps:get(routing_context, B)
        end,
        maps:values(maps:get(registrations, State))
    ),
    {reply, Entries, State};
handle_call(status, _From, State) ->
    Registrations = maps:get(registrations, State),
    {reply, #{
        registration_count => map_size(Registrations),
        max_registrations => maps:get(
            max_registrations, maps:get(policy, State)
        ),
        next_routing_context => maps:get(next_rc, State),
        registrations => maps:values(Registrations),
        peer_results => maps:get(peer_results, State)
    }, State};
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported}, State}.

handle_cast({peer_results, Link, Type, Results}, State) ->
    PeerResults = maps:get(peer_results, State),
    Entry = #{
        type => Type,
        results => Results,
        received_at => erlang:system_time(millisecond)
    },
    telco_stp_metrics:increment({rkm, peer_response, Type}),
    {noreply, State#{peer_results => PeerResults#{Link => Entry}}};
handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

normalize_global_policy(Policy) when is_map(Policy) ->
    Max = maps:get(max_registrations, Policy, 4096),
    RcStart = maps:get(rc_start, Policy, 10000),
    RcEnd = maps:get(rc_end, Policy, ?UINT32_MAX),
    true = is_integer(Max) andalso Max > 0 andalso Max =< 1000000 orelse
        error({invalid_rkm_max_registrations, Max}),
    true = is_integer(RcStart) andalso RcStart > 0 andalso
        RcStart =< ?UINT32_MAX orelse
        error({invalid_rkm_rc_start, RcStart}),
    true = is_integer(RcEnd) andalso RcEnd >= RcStart andalso
        RcEnd =< ?UINT32_MAX orelse
        error({invalid_rkm_rc_end, RcEnd}),
    Policy#{
        max_registrations => Max,
        rc_start => RcStart,
        rc_end => RcEnd,
        default_mode => maps:get(default_mode, Policy, disabled)
    };
normalize_global_policy(Policy) ->
    error({invalid_rkm_policy, Policy}).

registration_request_allowed(LinkState, Config, State)
        when LinkState =:= inactive; LinkState =:= active ->
    peer_policy(Config, maps:get(policy, State));
registration_request_allowed(_LinkState, _Config, _State) ->
    {error, permission_denied}.

peer_policy(Config, Global) ->
    case maps:get(rkm, Config, undefined) of
        Peer when is_map(Peer) ->
            Mode = maps:get(
                mode, Peer, maps:get(default_mode, Global, disabled)
            ),
            case Mode =:= dynamic orelse Mode =:= provisioned_only of
                true -> {ok, maps:merge(Global, Peer#{mode => Mode})};
                false -> {error, disabled}
            end;
        _ ->
            {error, disabled}
    end.

register_keys(Keys, Link, Config, Policy, State)
        when is_list(Keys), Keys =/= [] ->
    register_keys(Keys, Link, Config, Policy, State, [], #{});
register_keys(_Keys, _Link, _Config, _Policy, State) ->
    {[], State}.

register_keys([], _Link, _Config, _Policy, State, Results, _LocalIds) ->
    {lists:reverse(Results), State};
register_keys([Key | Rest], Link, Config, Policy, State, Results, LocalIds) ->
    LocalId = local_id(Key),
    case maps:is_key(LocalId, LocalIds) of
        true ->
            Result = registration_result(
                LocalId, invalid_routing_key, 0
            ),
            register_keys(
                Rest, Link, Config, Policy, State,
                [Result | Results], LocalIds
            );
        false ->
            {Result, NewState} = register_one(
                Key, Link, Config, Policy, State
            ),
            register_keys(
                Rest, Link, Config, Policy, NewState,
                [Result | Results], LocalIds#{LocalId => true}
            )
    end.

register_one(Key, Link, Config, Policy, State) ->
    LocalId = local_id(Key),
    case validate_key(Key, Config, Policy) of
        ok ->
            Canonical = canonical_key(Key),
            Registrations = maps:get(registrations, State),
            case exact_registration(Link, Canonical, Registrations) of
                {ok, ExistingRc} ->
                    telco_stp_metrics:increment(
                        {rkm, registration, already_registered}
                    ),
                    {
                        registration_result(
                            LocalId,
                            routing_key_already_registered,
                            ExistingRc
                        ),
                        State
                    };
                error ->
                    case overlaps_existing(Canonical, Registrations) of
                        true ->
                            registration_failure(
                                LocalId,
                                cannot_support_unique_routing,
                                Link,
                                State
                            );
                        false ->
                            create_registration(
                                Key, Canonical, Link, Config, Policy, State
                            )
                    end
            end;
        {error, Status} ->
            registration_failure(LocalId, Status, Link, State)
    end.

registration_failure(LocalId, Status, Link, State) ->
    telco_stp_metrics:increment({rkm, registration, Status}),
    telco_stp_alarm:raise(
        {rkm, Link, registration}, warning,
        #{reason => Status, local_rk_identifier => LocalId}
    ),
    {registration_result(LocalId, Status, 0), State}.

create_registration(Key, Canonical, Link, Config, Policy, State) ->
    Registrations = maps:get(registrations, State),
    LocalId = local_id(Key),
    case map_size(Registrations) >= maps:get(max_registrations, Policy) of
        true ->
            registration_failure(
                LocalId, insufficient_resources, Link, State
            );
        false ->
            case allocate_rc(State) of
                {error, exhausted} ->
                    registration_failure(
                        LocalId, insufficient_resources, Link, State
                    );
                {ok, Rc, AllocatedState} ->
                    case install_routes(
                        Rc, Link, Config, Canonical
                    ) of
                        {ok, RouteIds} ->
                            Entry = #{
                                routing_context => Rc,
                                source_link => Link,
                                local_rk_identifier => LocalId,
                                routing_key => Canonical,
                                route_ids => RouteIds,
                                registered_at =>
                                    erlang:system_time(millisecond)
                            },
                            Updated = Registrations#{Rc => Entry},
                            telco_stp_metrics:increment(
                                {rkm, registration, success}
                            ),
                            telco_stp_alarm:clear(
                                {rkm, Link, registration},
                                #{reason => registration_succeeded}
                            ),
                            {
                                registration_result(
                                    LocalId, successfully_registered, Rc
                                ),
                                AllocatedState#{registrations => Updated}
                            };
                        {error, Reason} ->
                            telco_stp_alarm:raise(
                                {rkm, Link, route_install}, major,
                                #{reason => Reason, routing_context => Rc}
                            ),
                            registration_failure(
                                LocalId, insufficient_resources, Link, State
                            )
                    end
            end
    end.

allocate_rc(State) ->
    Policy = maps:get(policy, State),
    Start = maps:get(next_rc, State),
    End = maps:get(rc_end, Policy),
    Floor = maps:get(rc_start, Policy),
    Registrations = maps:get(registrations, State),
    allocate_rc(Start, Start, Floor, End, Registrations, State).

allocate_rc(Candidate, Start, Floor, End, Registrations, State) ->
    case maps:is_key(Candidate, Registrations) of
        false ->
            Next =
                case Candidate >= End of
                    true -> Floor;
                    false -> Candidate + 1
                end,
            {ok, Candidate, State#{next_rc => Next}};
        true ->
            Next =
                case Candidate >= End of
                    true -> Floor;
                    false -> Candidate + 1
                end,
            case Next =:= Start of
                true -> {error, exhausted};
                false ->
                    allocate_rc(
                        Next, Start, Floor, End, Registrations, State
                    )
            end
    end.

install_routes(Rc, Link, Config, Key) ->
    Destinations = maps:get(destinations, Key),
    Routes = lists:zipwith(
        fun(Group, Index) ->
            dynamic_route(Rc, Link, Config, Key, Group, Index)
        end,
        Destinations,
        lists:seq(1, length(Destinations))
    ),
    install_routes(Routes, []).

install_routes([], Installed) ->
    {ok, lists:reverse(Installed)};
install_routes([Route | Rest], Installed) ->
    case telco_stp_route_table:add(Route) of
        ok ->
            install_routes(Rest, [maps:get(id, Route) | Installed]);
        {error, Reason} ->
            lists:foreach(
                fun telco_stp_route_table:remove/1, Installed
            ),
            {error, {dynamic_route_install_failed, Reason}}
    end.

dynamic_route(Rc, Link, Config, Key, Group, Index) ->
    {WildcardBits, Dpc} = maps:get(dpc, Group),
    PointCodeBits = point_code_bits(Config),
    Opcs =
        case maps:get(originating_point_codes, Group, any) of
            any -> any;
            Patterns -> [
                {significant_mask(point_code_bits(Config), Mask), Pc}
                || {Mask, Pc} <- Patterns
            ]
        end,
    #{
        id => {rkm, Link, Rc, Index},
        dpc => Dpc,
        mask => significant_mask(PointCodeBits, WildcardBits),
        linksets => [maps:get(linkset, Config)],
        priority => maps:get(rkm_route_priority, Config, 10),
        ni => maps:get(rkm_network_indicator, Config, any),
        si => maps:get(service_indicators, Group, any),
        opc_patterns => Opcs,
        network_appearance => maps:get(
            network_appearance, Key, any
        ),
        routing_context => Rc,
        traffic_mode => maps:get(
            traffic_mode_type, Key,
            maps:get(traffic_mode, Config, loadshare)
        ),
        dynamic => true
    }.

deregister_contexts(Contexts, Link, LinkState, State)
        when is_list(Contexts), Contexts =/= [] ->
    lists:foldl(
        fun(Rc, {Results, CurrentState}) ->
            {Result, NewState} = deregister_one(
                Rc, Link, LinkState, CurrentState
            ),
            {Results ++ [Result], NewState}
        end,
        {[], State},
        Contexts
    );
deregister_contexts(_Contexts, _Link, _LinkState, State) ->
    {[], State}.

deregister_one(Rc, Link, active, State) ->
    Registrations = maps:get(registrations, State),
    Status =
        case maps:find(Rc, Registrations) of
            {ok, #{source_link := Link}} -> asp_currently_active;
            {ok, _Other} -> permission_denied;
            error -> not_registered
        end,
    {
        #{
            routing_context => Rc,
            deregistration_status => Status
        },
        State
    };
deregister_one(Rc, Link, _LinkState, State) ->
    Registrations = maps:get(registrations, State),
    case maps:find(Rc, Registrations) of
        {ok, #{source_link := Link} = Entry} ->
            remove_routes(Entry),
            telco_stp_metrics:increment(
                {rkm, deregistration, success}
            ),
            {
                #{
                    routing_context => Rc,
                    deregistration_status => successfully_deregistered
                },
                State#{registrations => maps:remove(Rc, Registrations)}
            };
        {ok, _Other} ->
            {
                #{
                    routing_context => Rc,
                    deregistration_status => permission_denied
                },
                State
            };
        error ->
            {
                #{
                    routing_context => Rc,
                    deregistration_status => not_registered
                },
                State
            }
    end.

remove_link_registrations(Link, State) ->
    Registrations = maps:get(registrations, State),
    {Remove, Keep} = maps:fold(
        fun(Rc, Entry, {RemoveAcc, KeepAcc}) ->
            case maps:get(source_link, Entry) =:= Link of
                true ->
                    {RemoveAcc#{Rc => Entry}, KeepAcc};
                false ->
                    {RemoveAcc, KeepAcc#{Rc => Entry}}
            end
        end,
        {#{}, #{}},
        Registrations
    ),
    lists:foreach(fun remove_routes/1, maps:values(Remove)),
    {
        map_size(Remove),
        State#{
            registrations => Keep,
            peer_results => maps:remove(
                Link, maps:get(peer_results, State)
            )
        }
    }.

remove_routes(Entry) ->
    lists:foreach(
        fun telco_stp_route_table:remove/1,
        maps:get(route_ids, Entry, [])
    ).

validate_key(Key, Config, Policy) when is_map(Key) ->
    Bits = point_code_bits(Config),
    Mode = maps:get(traffic_mode_type, Key, loadshare),
    Destinations = maps:get(destinations, Key, []),
    case valid_uint32(local_id(Key)) of
        false -> {error, invalid_routing_key};
        true when Mode =/= override, Mode =/= loadshare,
                  Mode =/= broadcast ->
            {error, invalid_traffic_mode};
        true ->
            case valid_network_appearance(Key, Policy) of
                false ->
                    {error, invalid_network_appearance};
                true ->
                    case valid_destinations(
                        Destinations, Bits, Policy
                    ) of
                        false -> {error, invalid_dpc};
                        true -> provisioned(Key, Policy)
                    end
            end
    end;
validate_key(_Key, _Config, _Policy) ->
    {error, invalid_routing_key}.

valid_network_appearance(Key, Policy) ->
    case {
        maps:get(network_appearance, Key, any),
        maps:get(allowed_network_appearances, Policy, any)
    } of
        {_Na, any} -> true;
        {any, _Allowed} -> false;
        {Na, Allowed} when is_list(Allowed) -> lists:member(Na, Allowed);
        _ -> false
    end.

valid_destinations(Destinations, Bits, Policy)
        when is_list(Destinations), Destinations =/= [] ->
    lists:all(
        fun(#{dpc := {Mask, Pc}} = Group) ->
            is_integer(Mask) andalso Mask >= 0 andalso Mask =< Bits andalso
            is_integer(Pc) andalso Pc >= 0 andalso Pc < (1 bsl Bits) andalso
            valid_sis(maps:get(service_indicators, Group, any)) andalso
            valid_pc_list(
                maps:get(originating_point_codes, Group, any), Bits
            ) andalso
            dpc_allowed(
                {Mask, Pc}, maps:get(allowed_dpcs, Policy, any), Bits
            );
           (_) ->
            false
        end,
        Destinations
    );
valid_destinations(_Destinations, _Bits, _Policy) ->
    false.

valid_sis(any) -> true;
valid_sis(Sis) when is_list(Sis), Sis =/= [] ->
    lists:all(
        fun(Si) ->
            is_integer(Si) andalso Si >= 0 andalso Si =< 15
        end,
        Sis
    );
valid_sis(_Sis) -> false.

valid_pc_list(any, _Bits) -> true;
valid_pc_list(Patterns, Bits)
        when is_list(Patterns), Patterns =/= [] ->
    lists:all(
        fun({Mask, Pc}) ->
            is_integer(Mask) andalso Mask >= 0 andalso Mask =< Bits andalso
            is_integer(Pc) andalso Pc >= 0 andalso Pc < (1 bsl Bits)
        end,
        Patterns
    );
valid_pc_list(_Patterns, _Bits) -> false.

dpc_allowed(_Requested, any, _Bits) ->
    true;
dpc_allowed({RequestedMask, RequestedPc}, Allowed, Bits)
        when is_list(Allowed) ->
    lists:any(
        fun({AllowedMask, AllowedPc}) ->
            RequestedMask =< AllowedMask andalso
            patterns_overlap(
                {RequestedMask, RequestedPc},
                {AllowedMask, AllowedPc},
                Bits
            )
        end,
        Allowed
    );
dpc_allowed(_Requested, _Allowed, _Bits) ->
    false.

provisioned(Key, #{mode := dynamic}) ->
    _ = Key,
    ok;
provisioned(Key, #{mode := provisioned_only} = Policy) ->
    Requested = canonical_key(Key),
    Provisioned = [
        canonical_key(Item)
        || Item <- maps:get(provisioned_keys, Policy, []),
           is_map(Item)
    ],
    case lists:member(Requested, Provisioned) of
        true -> ok;
        false -> {error, routing_key_not_provisioned}
    end.

canonical_key(Key) ->
    maps:without(
        [local_rk_identifier, routing_context],
        Key#{
            traffic_mode_type => maps:get(
                traffic_mode_type, Key, loadshare
            ),
            destinations => [
                Group#{
                    service_indicators => maps:get(
                        service_indicators, Group, any
                    ),
                    originating_point_codes => maps:get(
                        originating_point_codes, Group, any
                    )
                }
                || Group <- maps:get(destinations, Key, [])
            ]
        }
    ).

exact_registration(Link, Canonical, Registrations) ->
    case [
        Rc
        || {Rc, Entry} <- maps:to_list(Registrations),
           maps:get(source_link, Entry) =:= Link,
           maps:get(routing_key, Entry) =:= Canonical
    ] of
        [Rc | _] -> {ok, Rc};
        [] -> error
    end.

overlaps_existing(Canonical, Registrations) ->
    lists:any(
        fun(Entry) ->
            routing_keys_overlap(
                Canonical, maps:get(routing_key, Entry)
            )
        end,
        maps:values(Registrations)
    ).

routing_keys_overlap(A, B) ->
    na_overlap(
        maps:get(network_appearance, A, any),
        maps:get(network_appearance, B, any)
    ) andalso
    lists:any(
        fun(GroupA) ->
            lists:any(
                fun(GroupB) -> groups_overlap(GroupA, GroupB) end,
                maps:get(destinations, B)
            )
        end,
        maps:get(destinations, A)
    ).

groups_overlap(A, B) ->
    patterns_overlap(maps:get(dpc, A), maps:get(dpc, B), 24) andalso
    selector_overlap(
        maps:get(service_indicators, A, any),
        maps:get(service_indicators, B, any)
    ) andalso
    pc_selector_overlap(
        maps:get(originating_point_codes, A, any),
        maps:get(originating_point_codes, B, any)
    ).

patterns_overlap({MaskA, PcA}, {MaskB, PcB}, Bits) ->
    SignificantA = significant_mask(Bits, MaskA),
    SignificantB = significant_mask(Bits, MaskB),
    Common = SignificantA band SignificantB,
    (PcA band Common) =:= (PcB band Common).

pc_selector_overlap(any, _B) -> true;
pc_selector_overlap(_A, any) -> true;
pc_selector_overlap(A, B) ->
    lists:any(
        fun(PatternA) ->
            lists:any(
                fun(PatternB) ->
                    patterns_overlap(PatternA, PatternB, 24)
                end,
                B
            )
        end,
        A
    ).

selector_overlap(any, _B) -> true;
selector_overlap(_A, any) -> true;
selector_overlap(A, B) ->
    lists:any(fun(Value) -> lists:member(Value, B) end, A).

na_overlap(any, _B) -> true;
na_overlap(_A, any) -> true;
na_overlap(A, B) -> A =:= B.

significant_mask(Bits, WildcardBits)
        when WildcardBits >= Bits ->
    0;
significant_mask(Bits, WildcardBits) ->
    (((1 bsl Bits) - 1) bsl WildcardBits) band ((1 bsl Bits) - 1).

point_code_bits(Config) ->
    case maps:get(
        point_code_variant, Config,
        maps:get(sccp_variant, Config, ansi)
    ) of
        itu -> 14;
        ansi -> 24
    end.

registration_result(LocalId, Status, Rc) ->
    #{
        local_rk_identifier => LocalId,
        registration_status => Status,
        routing_context => Rc
    }.

registration_failures(Keys, Status) when is_list(Keys), Keys =/= [] ->
    [
        registration_result(local_id(Key), Status, 0)
        || Key <- Keys
    ];
registration_failures(_Keys, _Status) ->
    [].

local_id(Key) when is_map(Key) ->
    maps:get(local_rk_identifier, Key, 0);
local_id(_Key) ->
    0.

valid_context_list(Contexts) when is_list(Contexts) ->
    [Rc || Rc <- Contexts, valid_uint32(Rc)];
valid_context_list(_Contexts) ->
    [].

valid_uint32(Value) ->
    is_integer(Value) andalso Value >= 0 andalso Value =< ?UINT32_MAX.
