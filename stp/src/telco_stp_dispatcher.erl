-module(telco_stp_dispatcher).
-behaviour(gen_server).

-include("telco_stp.hrl").

-export([
    start_link/0,
    transfer/1,
    ingress/2,
    set_fault_profile/1,
    fault_profile/0,
    set_overload_limits/1,
    overload_limits/0,
    overload_status/0
]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(DEFAULT_FAULTS, #{
    drop_percent => 0,
    duplicate_percent => 0,
    delay_ms => 0
}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

transfer(Message) ->
    gen_server:call(
        ?MODULE, {transfer, Message}, ?STP_DEFAULT_LONG_CALL_TIMEOUT_MS
    ).

ingress(SourceLink, Message) ->
    gen_server:cast(?MODULE, {ingress, SourceLink, Message}).

set_fault_profile(Profile) ->
    gen_server:call(?MODULE, {set_fault_profile, Profile}).

fault_profile() ->
    gen_server:call(?MODULE, fault_profile).

set_overload_limits(Limits) ->
    gen_server:call(?MODULE, {set_overload_limits, Limits}).

overload_limits() ->
    gen_server:call(?MODULE, overload_limits).

overload_status() ->
    gen_server:call(?MODULE, overload_status).

init([]) ->
    Seed = {
        erlang:phash2(node()),
        erlang:monotonic_time() band ?STP_UINT32_MAX,
        erlang:unique_integer([positive]) band ?STP_UINT32_MAX
    },
    {ok, OverloadLimits} = normalize_overload_limits(
        application:get_env(
            ?STP_APP, ?STP_ENV_OVERLOAD_LIMITS,
            #{
                high_watermark => ?STP_DEFAULT_OVERLOAD_HIGH_WATERMARK,
                low_watermark => ?STP_DEFAULT_OVERLOAD_LOW_WATERMARK
            }
        )
    ),
    {ok, #{
        fault_profile => ?DEFAULT_FAULTS,
        random_state => rand:seed_s(exsss, Seed),
        overload => OverloadLimits#{active => false, shed => 0}
    }}.

handle_call({transfer, Message}, _From, State) ->
    case overload_decision(State) of
        {shed, OverloadedState} ->
            telco_stp_metrics:increment({traffic, overload_shed}),
            {reply, {error, stp_overloaded}, OverloadedState};
        {accept, AvailableState} ->
            process_transfer(Message, AvailableState)
    end;
handle_call({set_overload_limits, Limits0}, _From, State) ->
    case normalize_overload_limits(Limits0) of
        {ok, Limits} ->
            Current = maps:get(overload, State),
            {reply, ok, State#{overload => Limits#{
                active => maps:get(active, Current),
                shed => maps:get(shed, Current)
            }}};
        Error ->
            {reply, Error, State}
    end;
handle_call(overload_limits, _From, State) ->
    {reply, maps:with(
        [high_watermark, low_watermark],
        maps:get(overload, State)
    ), State};
handle_call(overload_status, _From, State) ->
    {reply, overload_status_map(State), State};
handle_call({set_fault_profile, Profile0}, _From, State) ->
    case normalize_fault_profile(Profile0) of
        {ok, Profile} ->
            {reply, ok, State#{fault_profile => Profile}};
        Error ->
            {reply, Error, State}
    end;
handle_call(fault_profile, _From, State) ->
    {reply, maps:get(fault_profile, State), State};
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported}, State}.

process_transfer(Message, State) ->
    telco_stp_metrics:increment({traffic, submitted}),
    case validate_message(Message) of
        ok ->
            case prepare_for_routing(local, Message) of
                {ok, Prepared} ->
                    {Reply, NewState} =
                        dispatch_with_faults(Prepared, [], State),
                    {reply, Reply, NewState};
                {error, Reason} = Error ->
                    telco_stp_metrics:increment({traffic, sccp_rejected}),
                    telco_stp_alarm:raise(
                        {sccp, rejected}, warning, #{reason => Reason}
                    ),
                    {reply, Error, State}
                ;
                {pending, Reassembly} ->
                    telco_stp_metrics:increment(
                        {traffic, sccp_reassembly_pending}
                    ),
                    {reply, {ok, #{
                        disposition => awaiting_sccp_segments,
                        reassembly => Reassembly
                    }}, State}
                ;
                {consumed, Disposition} ->
                    {reply, {ok, #{
                        disposition => Disposition
                    }}, State}
            end;
        Error ->
            telco_stp_metrics:increment({traffic, invalid}),
            {reply, Error, State}
    end.

handle_cast({ingress, SourceLink, Message}, State) ->
    case overload_decision(State) of
        {shed, OverloadedState} ->
            telco_stp_metrics:increment({traffic, overload_ingress_shed}),
            {noreply, OverloadedState};
        {accept, AvailableState} ->
            process_ingress(SourceLink, Message, AvailableState)
    end;
handle_cast(_Request, State) ->
    {noreply, State}.

process_ingress(SourceLink, Message, State) ->
    telco_stp_metrics:increment({traffic, ingress}),
    case validate_message(Message) of
        ok ->
            case prepare_for_routing(SourceLink, Message) of
                {ok, Prepared} ->
                    {_Reply, NewState} =
                        dispatch_with_faults(Prepared, [SourceLink], State),
                    {noreply, NewState};
                {error, Reason} ->
                    telco_stp_metrics:increment({traffic, sccp_rejected}),
                    telco_stp_alarm:raise(
                        {sccp, rejected}, warning,
                        #{reason => Reason, source_link => SourceLink}
                    ),
                    {noreply, State}
                ;
                {pending, _Reassembly} ->
                    telco_stp_metrics:increment(
                        {traffic, sccp_reassembly_pending}
                    ),
                    {noreply, State}
                ;
                {consumed, _Disposition} ->
                    {noreply, State}
            end;
        {error, _Reason} ->
            telco_stp_metrics:increment({traffic, invalid_ingress}),
            {noreply, State}
    end.

handle_info({delayed_dispatch, Message, Exclude, Copies}, State) ->
    case overload_decision(State) of
        {shed, OverloadedState} ->
            telco_stp_metrics:increment({traffic, overload_delayed_shed}),
            {noreply, OverloadedState};
        {accept, AvailableState} ->
            _ = route_and_send(Message, Exclude, Copies),
            {noreply, AvailableState}
    end;
handle_info(_Info, State) ->
    {noreply, State}.

dispatch_with_faults(Message, Exclude, State) ->
    Profile = maps:get(fault_profile, State),
    Random0 = maps:get(random_state, State),
    {Drop, Random1} = chance(maps:get(drop_percent, Profile), Random0),
    {Duplicate, Random2} =
        chance(maps:get(duplicate_percent, Profile), Random1),
    NewState = State#{random_state => Random2},
    case Drop of
        true ->
            telco_stp_metrics:increment({traffic, fault_dropped}),
            {{ok, #{disposition => dropped_by_fault_profile}}, NewState};
        false ->
            Copies =
                case Duplicate of
                    true -> 2;
                    false -> 1
                end,
            Delay = maps:get(delay_ms, Profile),
            case Delay > 0 of
                true ->
                    _ = erlang:send_after(
                        Delay, self(),
                        {delayed_dispatch, Message, Exclude, Copies}
                    ),
                    telco_stp_metrics:increment({traffic, fault_delayed}),
                    {{ok, #{
                        disposition => queued,
                        delay_ms => Delay,
                        copies => Copies
                    }}, NewState};
                false ->
                    {route_and_send(Message, Exclude, Copies), NewState}
            end
    end.

route_and_send(Message, Exclude, Copies) ->
    case combined_path_constraints(Message) of
        #{unavailable := Unavailable, restricted := Restricted,
          congestion := Congestion} ->
            HardExclude = lists:usort(Exclude ++ Unavailable),
            PreferredExclude = lists:usort(HardExclude ++ Restricted),
            case lookup_and_send(
                Message, PreferredExclude, Congestion, Copies
            ) of
                {error, {no_available_route, _}} when Restricted =/= [] ->
                    telco_stp_metrics:increment(
                        {traffic, restricted_fallback}
                    ),
                    lookup_and_send(
                        Message, HardExclude, Congestion, Copies
                    );
                Reply ->
                    Reply
            end;
        {error, _Reason} = Error ->
            Error
    end.

lookup_and_send(Message, Exclude, Congestion, Copies) ->
    case telco_stp_route_table:lookup(Message) of
        [] ->
            telco_stp_metrics:increment({traffic, no_route}),
            telco_stp_alarm:raise(
                {routing, maps:get(dpc, Message)}, major,
                #{reason => no_route, message => route_alarm_details(Message)}
            ),
            {error, {no_route, maps:get(dpc, Message)}};
        {error, _Reason} = Error ->
            Error;
        Routes ->
            try_routes(Routes, Message, Exclude, Congestion, Copies)
    end.

try_routes([], Message, _Exclude, _Congestion, _Copies) ->
    telco_stp_metrics:increment({traffic, no_available_link}),
    telco_stp_alarm:raise(
        {routing, maps:get(dpc, Message)}, minor,
        #{
            reason => no_available_link,
            message => route_alarm_details(Message)
        }
    ),
    {error, {no_available_route, maps:get(dpc, Message)}};
try_routes([Route | Rest], Message, Exclude, Congestion, Copies) ->
    case maps:get(traffic_mode, Route, loadshare) of
        broadcast ->
            try_broadcast_route(
                Route, Rest, Message, Exclude, Congestion, Copies
            );
        _Mode ->
            try_single_route(
                Route, Rest, Message, Exclude, Congestion, Copies
            )
    end.

try_single_route(Route, Rest, Message, Exclude, Congestion, Copies) ->
    Linksets = maps:get(linksets, Route),
    Sls = maps:get(sls, Message),
    Dpc = maps:get(dpc, Message),
    case telco_stp_link_manager:select(
        Linksets, Sls, Dpc, Exclude, Congestion
    ) of
        {ok, Link} ->
            RoutedMessage = apply_route_context(Route, Message),
            case send_copies(
                maps:get(name, Link), RoutedMessage, Copies
            ) of
                ok ->
                            telco_stp_metrics:increment({traffic, forwarded}),
                            telco_stp_alarm:clear(
                                {routing, Dpc},
                                #{reason => route_restored,
                                  link => maps:get(name, Link)}
                            ),
                            case Copies of
                                2 ->
                                    telco_stp_metrics:increment(
                                        {traffic, fault_duplicated}
                                    );
                                _ ->
                                    ok
                            end,
                            {ok, #{
                                disposition => forwarded,
                                route => maps:get(id, Route),
                                link => maps:get(name, Link),
                                linkset => maps:get(linkset, Link),
                                copies => Copies
                            }};
                {error, _Reason} ->
                    try_routes(
                        Rest, Message, Exclude, Congestion, Copies
                    )
            end;
        {error, no_available_link} ->
            try_routes(Rest, Message, Exclude, Congestion, Copies)
    end.

try_broadcast_route(
    Route, Rest, Message, Exclude, Congestion, Copies
) ->
    Linksets = maps:get(linksets, Route),
    Dpc = maps:get(dpc, Message),
    case telco_stp_link_manager:select_all(
        Linksets, Exclude, Congestion
    ) of
        {ok, Links} ->
            RoutedMessage = apply_route_context(Route, Message),
            {Successful, Failed} = send_to_links(
                Links, RoutedMessage, Copies, [], []
            ),
                    case Successful of
                        [] ->
                            try_routes(
                                Rest, Message, Exclude, Congestion, Copies
                            );
                        _ ->
                            Names = [
                                maps:get(name, Link)
                                || Link <- Successful
                            ],
                            telco_stp_metrics:add(
                                {traffic, forwarded},
                                length(Successful) * Copies
                            ),
                            broadcast_alarm(Dpc, Failed, Names),
                            {ok, #{
                                disposition =>
                                    case Failed of
                                        [] -> broadcast;
                                        _ -> broadcast_partial
                                    end,
                                route => maps:get(id, Route),
                                link => hd(Names),
                                links => Names,
                                failed_links => Failed,
                                linkset => maps:get(
                                    linkset, hd(Successful)
                                ),
                                copies => Copies
                            }}
                    end;
        {error, no_available_link} ->
            try_routes(Rest, Message, Exclude, Congestion, Copies)
    end.

apply_route_context(Route, Message) ->
    case maps:get(routing_context, Route, undefined) of
        undefined ->
            Message;
        RoutingContext ->
            Message#{routing_context => [RoutingContext]}
    end.

send_to_links([], _Message, _Copies, Successful, Failed) ->
    {lists:reverse(Successful), lists:reverse(Failed)};
send_to_links([Link | Rest], Message, Copies, Successful, Failed) ->
    case send_copies(maps:get(name, Link), Message, Copies) of
        ok ->
            send_to_links(
                Rest, Message, Copies, [Link | Successful], Failed
            );
        {error, Reason} ->
            send_to_links(
                Rest, Message, Copies, Successful,
                [{maps:get(name, Link), Reason} | Failed]
            )
    end.

broadcast_alarm(Dpc, [], Names) ->
    telco_stp_alarm:clear(
        {routing, broadcast, Dpc},
        #{reason => all_broadcast_links_available, links => Names}
    );
broadcast_alarm(Dpc, Failed, Names) ->
    telco_stp_alarm:raise(
        {routing, broadcast, Dpc}, minor,
        #{
            reason => partial_broadcast_failure,
            successful_links => Names,
            failed_links => Failed
        }
    ).

send_copies(_Link, _Message, 0) ->
    ok;
send_copies(Link, Message, Count) ->
    case telco_stp_link_manager:send_transfer(Link, Message) of
        ok -> send_copies(Link, Message, Count - 1);
        Error -> Error
    end.

validate_message(Message) when is_map(Message) ->
    try
        _ = telco_stp_m3ua:protocol_data(Message),
        validate_m3ua_optional(Message)
    catch
        error:Reason -> {error, Reason}
    end;
validate_message(Message) ->
    {error, {invalid_transfer, Message}}.

validate_m3ua_optional(Message) ->
    case maps:find(routing_context, Message) of
        {ok, RcValues} when is_list(RcValues), RcValues =/= [] ->
            true = lists:all(fun is_uint32/1, RcValues) orelse
                error({invalid_routing_context, RcValues});
        {ok, RcValue} ->
            error({invalid_routing_context, RcValue});
        error ->
            ok
    end,
    case maps:find(network_appearance, Message) of
        {ok, NetworkAppearance} ->
            true = is_uint32(NetworkAppearance) orelse
                error({invalid_network_appearance, NetworkAppearance});
        error ->
            ok
    end,
    case maps:get(sccp_variant, Message, itu) of
        Variant when Variant =:= itu; Variant =:= ansi ->
            ok;
        Variant ->
            error({invalid_sccp_variant, Variant})
    end,
    case maps:get(sccp_reassembly, Message, false) of
        Reassembly when is_boolean(Reassembly) ->
            ok;
        Reassembly ->
            error({invalid_sccp_reassembly, Reassembly})
    end,
    ok.

normalize_fault_profile(Profile) when is_map(Profile) ->
    Merged = maps:merge(?DEFAULT_FAULTS, Profile),
    Drop = maps:get(drop_percent, Merged),
    Duplicate = maps:get(duplicate_percent, Merged),
    Delay = maps:get(delay_ms, Merged),
    KnownKeys = maps:keys(?DEFAULT_FAULTS),
    Unknown = [Key || Key <- maps:keys(Profile), not lists:member(Key, KnownKeys)],
    case valid_percent(Drop) andalso valid_percent(Duplicate) andalso
         is_integer(Delay) andalso Delay >= 0 andalso
         Delay =< ?STP_DEFAULT_PROMOTION_TIMEOUT_MS andalso
         Unknown =:= [] of
        true -> {ok, Merged};
        false -> {error, {invalid_fault_profile, Profile}}
    end;
normalize_fault_profile(Profile) ->
    {error, {invalid_fault_profile, Profile}}.

chance(0, Random) ->
    {false, Random};
chance(100, Random) ->
    {true, Random};
chance(Percent, Random0) ->
    {Value, Random1} = rand:uniform_s(100, Random0),
    {Value =< Percent, Random1}.

valid_percent(Value) ->
    is_integer(Value) andalso Value >= 0 andalso Value =< 100.

is_uint32(Value) ->
    is_integer(Value) andalso Value >= 0 andalso Value < (1 bsl 32).

prepare_for_routing(
    SourceLink, #{si := 3, payload := Payload} = Message
) ->
    Variant = maps:get(sccp_variant, Message, itu),
    case telco_stp_sccp:decode(Payload, Variant) of
        {ok, Sccp0} ->
            prepare_decoded_sccp(
                SourceLink, Message, Sccp0
            );
        {error, {unsupported_sccp_message_type, _Type}} ->
            {ok, Message};
        {error, Reason} ->
            {error, {malformed_sccp, Reason}}
    end;
prepare_for_routing(
    SourceLink,
    #{
        si := 1,
        point_code_variant := itu,
        payload := Payload
    } = Message
) when SourceLink =/= local ->
    process_signalling_link_test(SourceLink, Message, Payload);
prepare_for_routing(_SourceLink, Message) ->
    {ok, Message}.

process_signalling_link_test(SourceLink, Message, Payload) ->
    case telco_stp_slt:decode(Payload) of
        {ok, #{type := sltm, test_pattern := Pattern}} ->
            {ok, Acknowledgement} = telco_stp_slt:encode(#{
                type => slta, test_pattern => Pattern
            }),
            Reply = Message#{
                opc => maps:get(dpc, Message),
                dpc => maps:get(opc, Message),
                payload => Acknowledgement
            },
            case telco_stp_link_manager:send_transfer(
                SourceLink, Reply
            ) of
                ok ->
                    telco_stp_metrics:increment({slt, sltm_received}),
                    telco_stp_metrics:increment({slt, slta_sent}),
                    {consumed, sltm_acknowledged};
                {error, Reason} ->
                    {error, {slt_acknowledgement_failed, Reason}}
            end;
        {ok, #{type := slta}} ->
            telco_stp_metrics:increment({slt, slta_received}),
            {consumed, slta_received};
        {error, Reason} ->
            {error, {malformed_slt, Reason}}
    end.

prepare_decoded_sccp(SourceLink, Message, Sccp0) ->
    case maybe_reassemble(SourceLink, Message, Sccp0) of
        {complete, Sccp1} ->
            case telco_stp_sccp:prepare_relay(Sccp1) of
                {ok, Sccp2} ->
                    case process_scmg(
                        SourceLink, Message, Sccp2
                    ) of
                        ok -> translate_sccp(Message, Sccp2);
                        {error, Reason} ->
                            {error, Reason}
                    end;
                {error, Reason} ->
                    {error, {sccp_relay_failed, Reason}}
            end;
        {pending, _Info} = Pending ->
            Pending;
        {error, Reason} ->
            {error, {sccp_reassembly_failed, Reason}}
    end.

maybe_reassemble(SourceLink, Message, Sccp) ->
    case maps:get(sccp_reassembly, Message, false) of
        true ->
            telco_stp_reassembly:process(
                SourceLink, Message, Sccp
            );
        false ->
            {complete, Sccp}
    end.

translate_sccp(Message, #{called_party := #{
    routing_indicator := gt
} = Called} = Sccp) ->
    case telco_stp_gtt:translate(Called) of
        {ok, #{rule := Rule, address := TranslatedCalled}} ->
            UpdatedSccp = Sccp#{called_party => TranslatedCalled},
            Variant = maps:get(sccp_variant, Message, itu),
            case telco_stp_sccp:encode(UpdatedSccp, Variant) of
                {ok, Payload} ->
                    telco_stp_metrics:increment({gtt, translated}),
                    telco_stp_alarm:clear(
                        {gtt, no_translation},
                        #{reason => translation_succeeded, rule => Rule}
                    ),
                    RoutedMessage = add_sccp_route_metadata(
                        Message, UpdatedSccp
                    ),
                    {ok, RoutedMessage#{
                        dpc => maps:get(point_code, TranslatedCalled),
                        payload => Payload,
                        gtt_rule => Rule
                    }};
                {error, Reason} ->
                    {error, {sccp_reencode_failed, Reason}}
            end;
        {error, Reason} ->
            telco_stp_metrics:increment({gtt, no_translation}),
            telco_stp_alarm:raise(
                {gtt, no_translation}, warning,
                #{reason => Reason, called_party => Called}
            ),
            {error, Reason}
    end;
translate_sccp(Message, Sccp) ->
    Variant = maps:get(sccp_variant, Message, itu),
    case telco_stp_sccp:encode(Sccp, Variant) of
        {ok, Payload} ->
            RoutedMessage = add_sccp_route_metadata(
                Message, Sccp
            ),
            {ok, RoutedMessage#{payload => Payload}};
        {error, Reason} -> {error, {sccp_reencode_failed, Reason}}
    end.

route_alarm_details(Message) ->
    maps:with([dpc, opc, si, ni, network_appearance], Message).

combined_path_constraints(Message) ->
    case telco_stp_route_table:path_constraints(Message) of
        #{unavailable := MtpUnavailable,
          restricted := Restricted,
          congestion := MtpCongestion} ->
            #{
                unavailable := SccpUnavailable,
                congestion := SccpCongestion
            } = telco_stp_scmg:path_constraints(Message),
            #{
                unavailable => lists:usort(
                    MtpUnavailable ++ SccpUnavailable
                ),
                restricted => Restricted,
                congestion => maps:merge_with(
                    fun(_Link, A, B) -> max(A, B) end,
                    MtpCongestion,
                    SccpCongestion
                )
            };
        Error ->
            Error
    end.

add_sccp_route_metadata(Message, Sccp) ->
    Called = maps:get(called_party, Sccp, #{}),
    Message0 =
        case maps:find(point_code, Called) of
            {ok, PointCode} ->
                Message#{sccp_called_point_code => PointCode};
            error ->
                maps:remove(sccp_called_point_code, Message)
        end,
    case maps:find(ssn, Called) of
        {ok, Ssn} -> Message0#{sccp_called_ssn => Ssn};
        error -> maps:remove(sccp_called_ssn, Message0)
    end.

process_scmg(SourceLink, Message, Sccp) ->
    case telco_stp_scmg:ingest(SourceLink, Message, Sccp) of
        not_management ->
            ok;
        {ok, _Scmg, none} ->
            telco_stp_metrics:increment({scmg, received}),
            ok;
        {ok, _Scmg, {reply, ReplyScmg}} ->
            telco_stp_metrics:increment({scmg, status_test}),
            send_scmg_reply(SourceLink, Message, Sccp, ReplyScmg);
        {error, Reason} ->
            {error, Reason}
    end.

send_scmg_reply(local, _Message, _Sccp, _ReplyScmg) ->
    ok;
send_scmg_reply(SourceLink, Message, Sccp, ReplyScmg) ->
    Variant = maps:get(sccp_variant, Message, itu),
    case telco_stp_scmg:encode(ReplyScmg, Variant) of
        {ok, ManagementPayload} ->
            ReplySccp = #{
                type => udt,
                protocol_class => 0,
                called_party => maps:get(calling_party, Sccp),
                calling_party => maps:get(called_party, Sccp),
                data => ManagementPayload
            },
            case telco_stp_sccp:encode(ReplySccp, Variant) of
                {ok, SccpPayload} ->
                    ReplyMessage = Message#{
                        opc => maps:get(dpc, Message),
                        dpc => maps:get(opc, Message),
                        payload => SccpPayload
                    },
                    case telco_stp_link_manager:send_transfer(
                        SourceLink, ReplyMessage
                    ) of
                                ok ->
                                    telco_stp_metrics:increment(
                                        {scmg, status_reply}
                                    ),
                                    ok;
                        {error, Reason} ->
                                    {error, {
                                        scmg_reply_send_failed, Reason
                                    }}
                    end;
                {error, Reason} ->
                    {error, {scmg_sccp_encode_failed, Reason}}
            end;
        {error, Reason} ->
            {error, {scmg_encode_failed, Reason}}
    end.

normalize_overload_limits(#{
    high_watermark := High,
    low_watermark := Low
} = Limits) ->
    Unknown = [
        Key || Key <- maps:keys(Limits),
               not lists:member(Key, [high_watermark, low_watermark])
    ],
    case is_integer(High) andalso High >= 0 andalso
         is_integer(Low) andalso Low >= 0 andalso Low =< High andalso
         Unknown =:= [] of
        true ->
            {ok, #{high_watermark => High, low_watermark => Low}};
        false ->
            {error, {invalid_overload_limits, Limits}}
    end;
normalize_overload_limits(Limits) ->
    {error, {invalid_overload_limits, Limits}}.

overload_decision(State) ->
    QueueDepth = message_queue_depth(),
    Overload = maps:get(overload, State),
    High = maps:get(high_watermark, Overload),
    Low = maps:get(low_watermark, Overload),
    Active = maps:get(active, Overload),
    case {QueueDepth >= High, Active, QueueDepth =< Low} of
        {true, _, _} ->
            mark_overloaded(QueueDepth, State);
        {false, true, false} ->
            mark_overloaded(QueueDepth, State);
        {false, true, true} ->
            telco_stp_alarm:clear(
                {dispatcher, overload},
                #{reason => queue_recovered, queue_depth => QueueDepth}
            ),
            {accept, State#{overload => Overload#{active => false}}};
        {false, false, _} ->
            {accept, State}
    end.

mark_overloaded(QueueDepth, State) ->
    Overload = maps:get(overload, State),
    Shed = maps:get(shed, Overload) + 1,
    telco_stp_alarm:raise(
        {dispatcher, overload}, major,
        #{
            queue_depth => QueueDepth,
            high_watermark => maps:get(high_watermark, Overload),
            shed => Shed
        }
    ),
    {shed, State#{overload => Overload#{
        active => true,
        shed => Shed
    }}}.

overload_status_map(State) ->
    (maps:get(overload, State))#{
        queue_depth => message_queue_depth()
    }.

message_queue_depth() ->
    {message_queue_len, QueueDepth} =
        process_info(self(), message_queue_len),
    QueueDepth.
