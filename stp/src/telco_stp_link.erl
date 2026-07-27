-module(telco_stp_link).
-behaviour(gen_statem).

-include("telco_stp.hrl").

-export([
    start_link/2,
    status/1,
    send/2,
    send_transfer/2,
    inject/2,
    inject/3,
    retrieve_m2pa/2,
    set_admin/2,
    force_state/2,
    set_congestion/2
]).
-export([init/1, callback_mode/0, handle_event/4, terminate/3]).

start_link(Name, Config) ->
    gen_statem:start_link(?MODULE, [Name, Config], []).

status(Pid) ->
    gen_statem:call(Pid, status).

send(Pid, Binary) ->
    gen_statem:call(Pid, {send, Binary}, ?STP_DEFAULT_CALL_TIMEOUT_MS).

send_transfer(Pid, Message) ->
    gen_statem:call(
        Pid, {send_transfer, Message}, ?STP_DEFAULT_CALL_TIMEOUT_MS
    ).

inject(Pid, Binary) ->
    inject(Pid, Binary, #{}).

inject(Pid, Binary, Metadata) ->
    gen_statem:cast(Pid, {inject, Binary, Metadata}).

retrieve_m2pa(Pid, AfterFsn) ->
    gen_statem:call(
        Pid, {retrieve_m2pa, AfterFsn}, ?STP_DEFAULT_CALL_TIMEOUT_MS
    ).

set_admin(Pid, Admin) ->
    gen_statem:call(Pid, {set_admin, Admin}).

force_state(Pid, State) ->
    gen_statem:call(Pid, {force_state, State}).

set_congestion(Pid, Level) ->
    gen_statem:call(Pid, {set_congestion, Level}).

init([Name, Config]) ->
    process_flag(trap_exit, true),
    Data = #{
        name => Name,
        config => Config,
        transport_module => maps:get(
            transport, Config, telco_stp_transport_loopback
        ),
        transport_state => undefined,
        connected => false,
        admin => maps:get(admin, Config, up),
        congestion => 0,
        last_error => undefined,
        reconnect_ref => undefined,
        heartbeat_ref => undefined,
        heartbeat_timeout_ref => undefined,
        heartbeat_token => undefined,
        last_heartbeat_ack => undefined,
        last_rkm_results => undefined,
        last_management_notification => undefined,
        m2pa => telco_stp_m2pa_state:initial()
    },
    Actions =
        case maps:get(admin, Config, up) of
            up -> [{next_event, internal, connect}];
            down -> []
        end,
    {ok, down, Data, Actions}.

callback_mode() ->
    handle_event_function.

handle_event({call, From}, status, State, Data) ->
    Reply = #{
        name => maps:get(name, Data),
        linkset => maps:get(linkset, maps:get(config, Data)),
        state => State,
        admin => maps:get(admin, Data),
        connected => maps:get(connected, Data),
        congestion => maps:get(congestion, Data),
        transport => maps:get(transport_module, Data),
        last_error => maps:get(last_error, Data),
        heartbeat => heartbeat_status(Data),
        rkm => maps:get(last_rkm_results, Data),
        management_notification =>
            maps:get(last_management_notification, Data),
        adaptation => maps:get(
            adaptation, maps:get(config, Data), m3ua
        ),
        m2pa => m2pa_status(Data)
    },
    {keep_state_and_data, [{reply, From, Reply}]};

handle_event({call, From}, {send, Binary}, active, Data)
        when is_binary(Binary) ->
    case transport_send(Binary, Data) of
        {ok, NewData} ->
            telco_stp_metrics:increment({link, maps:get(name, Data), tx}),
            {keep_state, NewData, [{reply, From, ok}]};
        {error, Reason, NewData} ->
            telco_stp_metrics:increment({link, maps:get(name, Data), tx_error}),
            {keep_state, NewData#{last_error => Reason},
             [{reply, From, {error, Reason}}]}
    end;
handle_event({call, From}, {send, _Binary}, State, _Data) ->
    {keep_state_and_data, [{reply, From, {error, {link_not_active, State}}}]};

handle_event({call, From}, {send_transfer, Message}, active, Data)
        when is_map(Message) ->
    case send_transfer_message(Message, Data) of
        {ok, NewData} ->
            telco_stp_metrics:increment(
                {link, maps:get(name, Data), tx}
            ),
            {keep_state, NewData, [{reply, From, ok}]};
        {error, Reason, NewData} ->
            telco_stp_metrics:increment(
                {link, maps:get(name, Data), tx_error}
            ),
            {keep_state, NewData#{last_error => Reason}, [
                {reply, From, {error, Reason}}
            ]}
    end;
handle_event({call, From}, {send_transfer, _Message}, State, _Data) ->
    {keep_state_and_data, [
        {reply, From, {error, {link_not_active, State}}}
    ]};

handle_event({call, From}, {retrieve_m2pa, AfterFsn}, _State, Data) ->
    case retrieve_m2pa_messages(AfterFsn, Data) of
        {ok, Messages, NewData} ->
            {keep_state, NewData, [{reply, From, {ok, Messages}}]};
        {error, Reason} ->
            {keep_state_and_data, [{reply, From, {error, Reason}}]}
    end;

handle_event({call, From}, {set_admin, down}, _State, Data) ->
    clear_link_alarm(transport, #{reason => administratively_down}, Data),
    NewData = close_transport(Data#{admin => down}),
    {next_state, down, NewData, [{reply, From, ok}]};
handle_event({call, From}, {set_admin, up}, State, #{admin := up}) ->
    {keep_state_and_data, [{reply, From, {ok, State}}]};
handle_event({call, From}, {set_admin, up}, _State, Data) ->
    NewData = Data#{admin => up},
    {next_state, down, NewData, [
        {reply, From, ok},
        {next_event, internal, connect}
    ]};
handle_event({call, From}, {set_admin, Admin}, _State, _Data) ->
    {keep_state_and_data, [{reply, From, {error, {invalid_admin, Admin}}}]};

handle_event({call, From}, {force_state, active}, _Current, Data)
        when map_get(connected, Data) =:= true ->
    {next_state, active, activate_heartbeat(Data), [{reply, From, ok}]};
handle_event({call, From}, {force_state, inactive}, _Current, Data)
        when map_get(connected, Data) =:= true ->
    {next_state, inactive, cancel_heartbeat(Data), [{reply, From, ok}]};
handle_event({call, From}, {force_state, State}, _Current, _Data)
        when State =:= active; State =:= inactive ->
    {keep_state_and_data, [
        {reply, From, {error, transport_not_connected}}
    ]};
handle_event({call, From}, {force_state, State}, _Current, _Data) ->
    {keep_state_and_data, [
        {reply, From, {error, {invalid_forced_state, State}}}
    ]};

handle_event({call, From}, {set_congestion, Level}, _State, Data)
        when is_integer(Level), Level >= 0, Level =< 3 ->
    {keep_state, Data#{congestion => Level}, [{reply, From, ok}]};
handle_event({call, From}, {set_congestion, Level}, _State, _Data) ->
    {keep_state_and_data, [
        {reply, From, {error, {invalid_congestion_level, Level}}}
    ]};

handle_event(internal, connect, down, #{admin := up, connected := false} = Data) ->
    Module = maps:get(transport_module, Data),
    Config = maps:get(config, Data),
    case Module:open(self(), Config) of
        {ok, TransportState} ->
            ConnectedData = Data#{
                transport_state => TransportState,
                connected => true,
                last_error => undefined,
                reconnect_ref => undefined
            },
            clear_link_alarm(transport, #{state => connected}, ConnectedData),
            on_transport_connected(ConnectedData);
        {error, Reason} ->
            raise_link_alarm(
                transport, major, #{reason => Reason, state => down}, Data
            ),
            schedule_reconnect(Data#{last_error => Reason})
    end;
handle_event(internal, connect, _State, _Data) ->
    keep_state_and_data;

handle_event(info, reconnect, down, Data) ->
    {keep_state, Data#{reconnect_ref => undefined}, [
        {next_event, internal, connect}
    ]};

handle_event(cast, {inject, Binary, Metadata}, State, Data)
        when is_binary(Binary), is_map(Metadata) ->
    handle_adaptation_data(Binary, Metadata, State, Data);

handle_event(info, heartbeat_tick, active, Data) ->
    send_heartbeat(Data#{heartbeat_ref => undefined});
handle_event(info, heartbeat_tick, _State, Data) ->
    {keep_state, Data#{heartbeat_ref => undefined}};
handle_event(info, {m2pa_proving_complete, Token}, proving, Data) ->
    handle_m2pa_proving_complete(Token, Data);
handle_event(info, {m2pa_alignment_timeout, Token}, State, Data)
        when State =:= aligning; State =:= proving; State =:= ready ->
    handle_m2pa_alignment_timeout(Token, Data);
handle_event(info, {m2pa_t7, Fsn}, active, Data) ->
    handle_m2pa_t7(Fsn, Data);
handle_event(info, {m2pa_t7, _Fsn}, _State, Data) ->
    {keep_state, Data};
handle_event(
    info, {heartbeat_timeout, Token}, active,
    #{heartbeat_token := Token} = Data
) ->
    heartbeat_timed_out(Data);
handle_event(info, {heartbeat_timeout, _Token}, _State, Data) ->
    {keep_state, Data};

handle_event(info, Info, State, #{connected := true} = Data) ->
    Module = maps:get(transport_module, Data),
    TransportState = maps:get(transport_state, Data),
    case Module:handle_info(Info, TransportState) of
        {data, Binary, NewTransportState} ->
            handle_adaptation_data(
                Binary, #{}, State,
                Data#{transport_state => NewTransportState}
            );
        {data, Binary, Metadata, NewTransportState} ->
            handle_adaptation_data(
                Binary, Metadata, State,
                Data#{transport_state => NewTransportState}
            );
        {down, Reason, NewTransportState} ->
            telco_stp_metrics:increment({link, maps:get(name, Data), down}),
            raise_link_alarm(
                transport, major,
                #{reason => Reason, state => disconnected}, Data
            ),
            Closed = close_transport(Data#{
                transport_state => NewTransportState,
                last_error => Reason
            }),
            schedule_reconnect(Closed);
        {event, Event, NewTransportState} ->
            handle_transport_event(
                Event, State,
                Data#{transport_state => NewTransportState}
            );
        {ignore, NewTransportState} ->
            {keep_state, Data#{transport_state => NewTransportState}}
    end;
handle_event(info, _Info, _State, _Data) ->
    keep_state_and_data;

handle_event(_EventType, _EventContent, _State, _Data) ->
    keep_state_and_data.

terminate(_Reason, _State, Data) ->
    _ = close_transport(Data),
    ok.

on_transport_connected(Data) ->
    Config = maps:get(config, Data),
    case maps:get(adaptation, Config, m3ua) of
        m2pa ->
            start_m2pa_alignment(Data);
        m3ua ->
            on_m3ua_transport_connected(Config, Data)
    end.

on_m3ua_transport_connected(Config, Data) ->
    case maps:get(auto_activate, Config, false) of
        true ->
            {next_state, active, activate_heartbeat(Data)};
        false ->
            case maps:get(role, Config, sg) of
                asp ->
                    case send_control(aspsm, asp_up, #{}, Data) of
                        {ok, NewData} -> {next_state, down, NewData};
                        {error, Reason, NewData} ->
                            schedule_reconnect(close_transport(
                                NewData#{last_error => Reason}
                            ))
                    end;
                _ ->
                    {next_state, down, Data}
            end
    end.

handle_adaptation_data(Binary, Metadata, State, Data) ->
    Config = maps:get(config, Data),
    Adaptation = maps:get(adaptation, Config, m3ua),
    Stream = maps:get(
        stream, Metadata, maps:get(stream, Config, 0)
    ),
    telco_stp_trace:record(
        rx, maps:get(name, Data), Adaptation, Stream, Binary
    ),
    case Adaptation of
        m3ua -> handle_m3ua(Binary, State, Data);
        m2pa -> handle_m2pa(Binary, Metadata, State, Data)
    end.

handle_m3ua(Binary, State, Data) ->
    Name = maps:get(name, Data),
    telco_stp_metrics:increment({link, Name, rx}),
    case telco_stp_m3ua:decode(Binary) of
        {ok, Message} ->
            clear_link_alarm(m3ua_decode, #{state => valid_traffic}, Data),
            handle_m3ua_message(Message, State, Data);
        {error, Reason} ->
            telco_stp_metrics:increment({link, Name, decode_error}),
            raise_link_alarm(
                m3ua_decode, warning, #{reason => Reason}, Data
            ),
            NewData = maybe_send_decode_error(Binary, Reason, Data),
            {keep_state, NewData#{
                last_error => {m3ua_decode, Reason}
            }}
    end.

handle_m3ua_message(
    #{class := aspsm, type := heartbeat, params := Params}, State, Data
) ->
    AckParams =
        case maps:find(heartbeat_data, Params) of
            {ok, HeartbeatData} -> #{heartbeat_data => HeartbeatData};
            error -> #{}
        end,
    keep_after_control(aspsm, heartbeat_ack, AckParams, State, Data);
handle_m3ua_message(
    #{class := aspsm, type := heartbeat_ack, params := Params}, State, Data
) ->
    handle_heartbeat_ack(Params, State, Data);
handle_m3ua_message(
    #{class := aspsm, type := asp_up}, _State, Data
) ->
    next_after_control(aspsm, asp_up_ack, #{}, inactive, Data);
handle_m3ua_message(
    #{class := aspsm, type := asp_up_ack}, _State, Data
) ->
    Params = active_params(maps:get(config, Data)),
    next_after_control(asptm, asp_active, Params, inactive, Data);
handle_m3ua_message(
    #{class := aspsm, type := asp_down}, _State, Data
) ->
    next_after_control(aspsm, asp_down_ack, #{}, down, Data);
handle_m3ua_message(
    #{class := aspsm, type := asp_down_ack}, _State, Data
) ->
    {next_state, down, cancel_heartbeat(Data)};
handle_m3ua_message(
    #{class := asptm, type := asp_active, params := Params},
    inactive, Data
) ->
    handle_asp_active(Params, Data);
handle_m3ua_message(
    #{class := asptm, type := asp_active_ack}, _State, Data
) ->
    {next_state, active, activate_heartbeat(Data)};
handle_m3ua_message(
    #{class := asptm, type := asp_inactive, params := Params},
    active, Data
) ->
    next_after_control(
        asptm, asp_inactive_ack,
        maps:with([routing_context], Params), inactive, Data
    );
handle_m3ua_message(
    #{class := asptm, type := asp_inactive_ack}, _State, Data
) ->
    {next_state, inactive, cancel_heartbeat(Data)};
handle_m3ua_message(
    #{class := ssnm, type := daud, params := Params}, active, Data
) ->
    handle_destination_audit(Params, Data);
handle_m3ua_message(
    #{class := ssnm, type := Type, params := Params}, active, Data
) when Type =:= duna; Type =:= dava; Type =:= drst;
       Type =:= scon; Type =:= dupu ->
    Name = maps:get(name, Data),
    case telco_stp_route_table:update_ssnm(Name, Type, Params) of
        ok ->
            telco_stp_metrics:increment({ssnm, Type}),
            {keep_state, Data};
        {error, Reason} ->
            telco_stp_metrics:increment({ssnm, invalid}),
            {keep_state, Data#{last_error => {invalid_ssnm, Type, Reason}}}
    end;
handle_m3ua_message(
    #{class := rkm, type := registration_request, params := Params},
    State, Data
) ->
    handle_registration_request(Params, State, Data);
handle_m3ua_message(
    #{class := rkm, type := deregistration_request, params := Params},
    State, Data
) ->
    handle_deregistration_request(Params, State, Data);
handle_m3ua_message(
    #{class := rkm, type := registration_response, params := Params},
    _State, Data
) ->
    Results = maps:get(registration_results, Params, []),
    telco_stp_rkm:record_peer_results(
        maps:get(name, Data), registration, Results
    ),
    {keep_state, Data#{last_rkm_results => #{
        type => registration, results => Results
    }}};
handle_m3ua_message(
    #{class := rkm, type := deregistration_response, params := Params},
    _State, Data
) ->
    Results = maps:get(deregistration_results, Params, []),
    telco_stp_rkm:record_peer_results(
        maps:get(name, Data), deregistration, Results
    ),
    {keep_state, Data#{last_rkm_results => #{
        type => deregistration, results => Results
    }}};
handle_m3ua_message(
    #{class := management, type := error, params := Params},
    _State, Data
) ->
    handle_management_error(Params, Data);
handle_m3ua_message(
    #{class := management, type := notify, params := Params},
    _State, Data
) ->
    handle_management_notify(Params, Data);
handle_m3ua_message(
    #{class := transfer, type := data, params := Params}, active, Data
) ->
    case maps:find(protocol_data, Params) of
        {ok, ProtocolData} ->
            Envelope = maybe_copy_param(
                routing_context, Params,
                maybe_copy_param(network_appearance, Params, ProtocolData)
            ),
            Config = maps:get(config, Data),
            WithVariant = Envelope#{
                point_code_variant => point_code_variant(Config),
                sccp_variant => maps:get(sccp_variant, Config, itu),
                sccp_reassembly => maps:get(
                    sccp_reassembly, Config, false
                )
            },
            telco_stp_dispatcher:ingress(
                maps:get(name, Data), WithVariant
            ),
            {keep_state, Data};
        error ->
            {keep_state, Data#{last_error => missing_protocol_data}}
    end;
handle_m3ua_message(
    #{class := transfer, type := data}, State, Data
) ->
    telco_stp_metrics:increment(
        {link, maps:get(name, Data), data_while_not_active}
    ),
    send_protocol_error(
        unexpected_message, #{}, undefined,
        Data#{last_error => {data_while_not_active, State}}
    );
handle_m3ua_message(
    #{class := Class, raw_class := RawClass} = Message, _State, Data
) when is_integer(Class) ->
    _ = RawClass,
    send_protocol_error(
        unsupported_message_class, #{}, Message, Data
    );
handle_m3ua_message(
    #{type := Type} = Message, _State, Data
) when is_integer(Type) ->
    send_protocol_error(
        unsupported_message_type, #{}, Message, Data
    );
handle_m3ua_message(Message, _State, Data) ->
    send_protocol_error(
        unexpected_message, #{}, Message, Data
    ).

handle_registration_request(Params, State, Data) ->
    case maps:get(routing_keys, Params, []) of
        [_ | _] = Keys ->
            Name = maps:get(name, Data),
            Config = maps:get(config, Data),
            case telco_stp_rkm:register(
                Name, State, Config, Keys
            ) of
                {ok, Results} ->
                    case send_control(
                        rkm, registration_response,
                        #{registration_results => Results}, Data
                    ) of
                        {ok, NewData} ->
                            telco_stp_metrics:increment(
                                {rkm, registration_response, sent}
                            ),
                            {keep_state, NewData#{
                                last_rkm_results => #{
                                    type => registration,
                                    results => Results
                                }
                            }};
                        {error, Reason, NewData} ->
                            {keep_state, NewData#{
                                last_error => {
                                    rkm_registration_response_failed,
                                    Reason
                                }
                            }}
                    end;
                {error, Reason} ->
                    {keep_state, Data#{last_error => {
                        rkm_registration_failed, Reason
                    }}}
            end;
        _ ->
            send_protocol_error(
                missing_parameter, #{}, undefined,
                Data#{last_error =>
                    {missing_rkm_parameter, routing_keys}}
            )
    end.

handle_deregistration_request(Params, State, Data) ->
    case maps:get(routing_context, Params, []) of
        [_ | _] = Contexts ->
            Name = maps:get(name, Data),
            Config = maps:get(config, Data),
            case telco_stp_rkm:deregister(
                Name, State, Config, Contexts
            ) of
                {ok, Results} ->
                    case send_control(
                        rkm, deregistration_response,
                        #{deregistration_results => Results}, Data
                    ) of
                        {ok, NewData} ->
                            telco_stp_metrics:increment(
                                {rkm, deregistration_response, sent}
                            ),
                            {keep_state, NewData#{
                                last_rkm_results => #{
                                    type => deregistration,
                                    results => Results
                                }
                            }};
                        {error, Reason, NewData} ->
                            {keep_state, NewData#{
                                last_error => {
                                    rkm_deregistration_response_failed,
                                    Reason
                                }
                            }}
                    end;
                {error, Reason} ->
                    {keep_state, Data#{last_error => {
                        rkm_deregistration_failed, Reason
                    }}}
            end;
        _ ->
            send_protocol_error(
                missing_parameter, #{}, undefined,
                Data#{last_error =>
                    {missing_rkm_parameter, routing_context}}
            )
    end.

handle_asp_active(Params, Data) ->
    Config = maps:get(config, Data),
    case validate_asp_active(Params, Config, maps:get(name, Data)) of
        ok ->
            AckParams = maps:with(
                [traffic_mode_type, routing_context], Params
            ),
            next_after_control(
                asptm, asp_active_ack, AckParams, active, Data
            );
        {error, unsupported_traffic_mode} ->
            ErrorParams = maps:with([routing_context], Params),
            send_protocol_error(
                unsupported_traffic_mode, ErrorParams, undefined, Data
            );
        {error, invalid_routing_context} ->
            ErrorParams = maps:with([routing_context], Params),
            send_protocol_error(
                invalid_routing_context, ErrorParams, undefined, Data
            )
    end.

validate_asp_active(Params, Config, Link) ->
    RequestedMode = maps:get(traffic_mode_type, Params, undefined),
    SupportedModes = maps:get(
        allowed_traffic_modes, Config,
        [maps:get(traffic_mode, Config, loadshare)]
    ),
    case RequestedMode =:= undefined orelse
         lists:member(RequestedMode, SupportedModes) of
        false ->
            {error, unsupported_traffic_mode};
        true ->
            validate_active_contexts(Params, Config, Link)
    end.

validate_active_contexts(Params, Config, Link) ->
    case maps:find(routing_context, Params) of
        error ->
            ok;
        {ok, Contexts} when is_list(Contexts), Contexts =/= [] ->
            Static = maps:get(routing_context, Config, []),
            Dynamic = telco_stp_rkm:contexts_for_link(Link),
            Allowed = lists:usort(Static ++ Dynamic),
            case lists:all(
                fun(Context) -> lists:member(Context, Allowed) end,
                Contexts
            ) of
                true -> ok;
                false -> {error, invalid_routing_context}
            end;
        _ ->
            {error, invalid_routing_context}
    end.

handle_management_error(Params, Data) ->
    Name = maps:get(name, Data),
    Code = maps:get(error_code, Params, missing),
    telco_stp_metrics:increment({m3ua, management_error, Code}),
    telco_stp_alarm:raise(
        {link, Name, m3ua_management_error}, warning,
        #{error_code => Code, parameters => Params}
    ),
    {keep_state, Data#{
        last_error => {peer_m3ua_error, Code, Params}
    }}.

handle_management_notify(Params, Data) ->
    case maps:find(status, Params) of
        {ok, {Type, Information} = Status} ->
            Name = maps:get(name, Data),
            Notification = #{
                status => Status,
                meaning => notify_meaning(Type, Information),
                routing_context => maps:get(
                    routing_context, Params, []
                ),
                asp_identifier => maps:get(
                    asp_identifier, Params, undefined
                ),
                info_string => maps:get(
                    info_string, Params, undefined
                ),
                received_at => erlang:system_time(millisecond)
            },
            telco_stp_metrics:increment(
                {m3ua, notify, Type, Information}
            ),
            maybe_alarm_notify(Name, Notification),
            {keep_state, Data#{
                last_management_notification => Notification
            }};
        error ->
            send_protocol_error(
                missing_parameter, #{}, undefined, Data
            )
    end.

notify_meaning(1, 2) -> as_inactive;
notify_meaning(1, 3) -> as_active;
notify_meaning(1, 4) -> as_pending;
notify_meaning(2, 1) -> insufficient_asp_resources;
notify_meaning(2, 2) -> alternate_asp_active;
notify_meaning(2, 3) -> asp_failure;
notify_meaning(Type, Information) -> {unknown, Type, Information}.

maybe_alarm_notify(Name, #{meaning := Meaning} = Notification)
        when Meaning =:= insufficient_asp_resources;
             Meaning =:= asp_failure ->
    telco_stp_alarm:raise(
        {link, Name, m3ua_notify}, major, Notification
    );
maybe_alarm_notify(Name, Notification) ->
    telco_stp_alarm:clear(
        {link, Name, m3ua_notify},
        Notification#{reason => peer_state_notification}
    ).

maybe_send_decode_error(Binary, Reason, Data) ->
    ErrorCode =
        case Reason of
            {unsupported_version, _} -> invalid_version;
            {invalid_m3ua_parameter_length, _, _} ->
                parameter_field_error;
            {truncated_m3ua_parameter, _, _} ->
                parameter_field_error;
            {truncated_m3ua_parameter_header, _} ->
                parameter_field_error;
            _ ->
                protocol_error
        end,
    Diagnostic = first_octets(Binary, 40),
    case send_control(
        management, error,
        #{
            error_code => ErrorCode,
            diagnostic_information => Diagnostic
        },
        Data
    ) of
        {ok, NewData} -> NewData;
        {error, _SendReason, NewData} -> NewData
    end.

send_protocol_error(ErrorCode, ExtraParams, Message, Data) ->
    Params0 = ExtraParams#{error_code => ErrorCode},
    Params =
        case Message of
            #{raw_message := Raw} ->
                Params0#{
                    diagnostic_information => first_octets(Raw, 40)
                };
            _ ->
                Params0
        end,
    case send_control(management, error, Params, Data) of
        {ok, NewData} ->
            telco_stp_metrics:increment(
                {m3ua, error_sent, ErrorCode}
            ),
            {keep_state, NewData};
        {error, Reason, NewData} ->
            {keep_state, NewData#{
                last_error => {m3ua_error_send_failed, Reason}
            }}
    end.

first_octets(Binary, Maximum) ->
    binary:part(Binary, 0, min(byte_size(Binary), Maximum)).

keep_after_control(Class, Type, Params, _State, Data) ->
    case send_control(Class, Type, Params, Data) of
        {ok, NewData} -> {keep_state, NewData};
        {error, Reason, NewData} ->
            {keep_state, NewData#{last_error => Reason}}
    end.

next_after_control(Class, Type, Params, NextState, Data) ->
    case send_control(Class, Type, Params, Data) of
        {ok, NewData} ->
            {next_state, NextState, data_for_state(NextState, NewData)};
        {error, Reason, NewData} ->
            {keep_state, NewData#{last_error => Reason}}
    end.

send_control(Class, Type, Params, Data) ->
    case telco_stp_m3ua:encode(#{
        class => Class, type => Type, params => Params
    }) of
        {ok, Binary} -> transport_send(Binary, Data);
        {error, Reason} -> {error, Reason, Data}
    end.

active_params(Config) ->
    Base = #{traffic_mode_type => maps:get(traffic_mode, Config, loadshare)},
    case maps:find(routing_context, Config) of
        {ok, Values} -> Base#{routing_context => Values};
        error -> Base
    end.

transport_send(Binary, Data) ->
    Module = maps:get(transport_module, Data),
    TransportState = maps:get(transport_state, Data),
    case Module:send(Binary, TransportState) of
        {ok, NewTransportState} ->
            trace_transmitted(Binary, Data),
            {ok, Data#{transport_state => NewTransportState}};
        {error, Reason, NewTransportState} ->
            {error, Reason, Data#{transport_state => NewTransportState}}
    end.

trace_transmitted({stream, Stream, Payload}, Data) ->
    telco_stp_trace:record(
        tx, maps:get(name, Data), m2pa, Stream, Payload
    );
trace_transmitted(Payload, Data) ->
    Config = maps:get(config, Data),
    telco_stp_trace:record(
        tx, maps:get(name, Data),
        maps:get(adaptation, Config, m3ua),
        maps:get(stream, Config, 0),
        Payload
    ).

send_transfer_message(Message, Data) ->
    Config = maps:get(config, Data),
    case maps:get(adaptation, Config, m3ua) of
        m3ua ->
            case telco_stp_m3ua:encode_data(Message) of
                {ok, Binary} -> transport_send(Binary, Data);
                {error, Reason} -> {error, Reason, Data}
            end;
        m2pa ->
            send_m2pa_transfer(Message, Data)
    end.

start_m2pa_alignment(Data0) ->
    Config = maps:get(config, Data0),
    M2pa = (telco_stp_m2pa_state:initial())#{
        local_status => alignment
    },
    Data = Data0#{m2pa => M2pa, congestion => 0},
    case send_m2pa_status(alignment, 0, Data) of
        {ok, SentData} ->
            Token = make_ref(),
            Timeout = maps:get(
                m2pa_alignment_timeout_ms, Config,
                ?STP_DEFAULT_M2PA_ALIGNMENT_TIMEOUT_MS
            ),
            _ = erlang:send_after(
                Timeout, self(), {m2pa_alignment_timeout, Token}
            ),
            UpdatedM2pa = (maps:get(m2pa, SentData))#{
                alignment_token => Token
            },
            {next_state, aligning, SentData#{m2pa => UpdatedM2pa}};
        {error, Reason, FailedData} ->
            schedule_reconnect(close_transport(
                FailedData#{last_error => {m2pa_alignment_failed, Reason}}
            ))
    end.

handle_m2pa(Binary, Metadata, State, Data) ->
    Name = maps:get(name, Data),
    telco_stp_metrics:increment({link, Name, rx}),
    case telco_stp_m2pa:decode(Binary) of
        {ok, #{type := link_status} = Message} ->
            Stream = maps:get(
                stream, Metadata, telco_stp_m2pa_state:status_stream(Message)
            ),
            handle_m2pa_link_status(Message, Stream, State, Data);
        {ok, #{type := user_data} = Message} ->
            Stream = maps:get(stream, Metadata, 1),
            handle_m2pa_user_data(Message, Stream, State, Data);
        {error, Reason} ->
            telco_stp_metrics:increment({m2pa, decode_error}),
            raise_link_alarm(
                m2pa_decode, warning, #{reason => Reason}, Data
            ),
            {keep_state, Data#{
                last_error => {m2pa_decode, Reason},
                m2pa => (maps:get(m2pa, Data))#{last_error => Reason}
            }}
    end.

handle_m2pa_link_status(Message, Stream, State, Data) ->
    Status = maps:get(status, Message),
    ExpectedStream = telco_stp_m2pa_state:status_stream(Message),
    case Stream =:= ExpectedStream orelse
         (Status =:= ready andalso (Stream =:= 0 orelse Stream =:= 1)) of
        false ->
            m2pa_protocol_violation(
                {invalid_status_stream, Status, Stream}, Data
            );
        true ->
            M2pa0 = telco_stp_m2pa_state:acknowledge(
                maps:get(bsn, Message), maps:get(m2pa, Data)
            ),
            M2pa = M2pa0#{remote_status => Status},
            handle_m2pa_status(
                Status, State, Data#{m2pa => M2pa}
            )
    end.

handle_m2pa_status(alignment, _State, Data) ->
    send_m2pa_status_transition(
        proving_normal, 0, proving, Data, fun start_m2pa_proving/1,
        proving_send_failed
    );
handle_m2pa_status(Status, _State, Data)
        when Status =:= proving_normal;
             Status =:= proving_emergency ->
    {next_state, proving, start_m2pa_proving(Data)};
handle_m2pa_status(ready, active, Data) ->
    {keep_state, m2pa_in_service(Data)};
handle_m2pa_status(ready, _State, Data) ->
    send_m2pa_status_transition(
        ready, 0, active, Data, fun m2pa_in_service/1, ready_send_failed
    );
handle_m2pa_status(busy, State, Data) ->
    raise_link_alarm(
        m2pa_busy, warning, #{reason => remote_busy}, Data
    ),
    {next_state, State, Data#{congestion => 3}};
handle_m2pa_status(busy_ended, State, Data) ->
    clear_link_alarm(
        m2pa_busy, #{reason => remote_busy_ended}, Data
    ),
    {next_state, State, Data#{congestion => 0}};
handle_m2pa_status(processor_outage, _State, Data) ->
    raise_link_alarm(
        m2pa_processor, major, #{reason => remote_processor_outage}, Data
    ),
    {next_state, inactive, Data#{congestion => 3}};
handle_m2pa_status(processor_recovered, _State, Data) ->
    clear_link_alarm(
        m2pa_processor, #{reason => remote_processor_recovered}, Data
    ),
    send_m2pa_status_transition(
        ready, 1, ready, Data#{congestion => 0}, fun identity/1,
        processor_ready_send_failed
    );
handle_m2pa_status(out_of_service, _State, Data) ->
    raise_link_alarm(
        m2pa_status, major, #{reason => remote_out_of_service}, Data
    ),
    {next_state, inactive, Data#{congestion => 3}};
handle_m2pa_status(Status, State, Data) ->
    raise_link_alarm(
        m2pa_status, warning, #{reason => {unknown_status, Status}}, Data
    ),
    {next_state, State, Data}.

start_m2pa_proving(Data) ->
    M2pa = maps:get(m2pa, Data),
    case maps:get(proving_token, M2pa) of
        Token when is_reference(Token) ->
            Data;
        undefined ->
            Token = make_ref(),
            Config = maps:get(config, Data),
            ProvingMs = maps:get(
                m2pa_proving_ms, Config, ?STP_DEFAULT_M2PA_PROVING_MS
            ),
            _ = erlang:send_after(
                ProvingMs, self(), {m2pa_proving_complete, Token}
            ),
            Data#{m2pa => M2pa#{
                proving_token => Token,
                local_status => proving_normal
            }}
    end.

handle_m2pa_proving_complete(Token, Data) ->
    M2pa = maps:get(m2pa, Data),
    case maps:get(proving_token, M2pa) of
        Token ->
            Cleared = Data#{m2pa => M2pa#{
                proving_token => undefined,
                local_status => ready
            }},
            send_m2pa_status_transition(
                ready, 0, ready, Cleared, fun identity/1, ready_send_failed
            );
        _ ->
            {keep_state, Data}
    end.

handle_m2pa_alignment_timeout(Token, Data) ->
    M2pa = maps:get(m2pa, Data),
    case maps:get(alignment_token, M2pa) of
        Token ->
            raise_link_alarm(
                m2pa_alignment, major,
                #{reason => alignment_timeout}, Data
            ),
            Failed = Data#{
                congestion => 3,
                m2pa => M2pa#{
                    alignment_token => undefined,
                    local_status => out_of_service,
                    last_error => alignment_timeout
                }
            },
            case send_m2pa_status(out_of_service, 0, Failed) of
                {ok, SentData} -> {next_state, inactive, SentData};
                {error, _Reason, FailedData} ->
                    {next_state, inactive, FailedData}
            end;
        _ ->
            {keep_state, Data}
    end.

m2pa_in_service(Data) ->
    M2pa = maps:get(m2pa, Data),
    clear_link_alarm(
        m2pa_alignment, #{reason => link_in_service}, Data
    ),
    clear_link_alarm(
        m2pa_status, #{reason => link_in_service}, Data
    ),
    Data#{
        congestion => 0,
        m2pa => M2pa#{
            alignment_token => undefined,
            proving_token => undefined,
            local_status => ready,
            remote_status => ready,
            last_error => undefined
        }
    }.

handle_m2pa_user_data(Message, Stream, State, Data) ->
    case Stream of
        1 ->
            M2pa0 = telco_stp_m2pa_state:acknowledge(
                maps:get(bsn, Message), maps:get(m2pa, Data)
            ),
            Updated = Data#{m2pa => M2pa0},
            case maps:get(mtp3, Message) of
                <<>> ->
                    {keep_state, Updated};
                _Mtp3 when State =/= active ->
                    m2pa_protocol_violation(
                        {user_data_while_not_in_service, State}, Updated
                    );
                Mtp3 ->
                    receive_m2pa_mtp3(
                        maps:get(fsn, Message), Mtp3, Updated
                    )
            end;
        _ ->
            m2pa_protocol_violation(
                {invalid_user_data_stream, Stream}, Data
            )
    end.

receive_m2pa_mtp3(Fsn, Binary, Data) ->
    M2pa = maps:get(m2pa, Data),
    Expected = telco_stp_m2pa:next_sequence(
        maps:get(rx_fsn, M2pa)
    ),
    case Fsn of
        Expected ->
            Config = maps:get(config, Data),
            Variant = point_code_variant(Config),
            case telco_stp_mtp3:decode(Variant, Binary) of
                {ok, Transfer0} ->
                    Transfer = Transfer0#{
                        point_code_variant => Variant,
                        sccp_variant =>
                            maps:get(sccp_variant, Config, Variant),
                        sccp_reassembly => maps:get(
                            sccp_reassembly, Config, false
                        )
                    },
                    ReceivedM2pa = M2pa#{rx_fsn => Fsn},
                    ReceivedData = Data#{m2pa => ReceivedM2pa},
                    TransferData = m2pa_transfer_data(
                        handle_m2pa_mtp3_transfer(Transfer, ReceivedData),
                        ReceivedData
                    ),
                    case send_m2pa_ack(TransferData) of
                        {ok, AckedData} ->
                            {keep_state, AckedData};
                        {error, Reason, FailedData} ->
                            {keep_state, FailedData#{
                                last_error => {m2pa_ack_failed, Reason}
                            }}
                    end;
                {error, Reason} ->
                    m2pa_protocol_violation(
                        {mtp3_decode_failed, Reason}, Data
                    )
            end;
        _ ->
            telco_stp_metrics:increment(
                {m2pa, out_of_sequence}
            ),
            raise_link_alarm(
                m2pa_sequence, major,
                #{expected => Expected, received => Fsn}, Data
            ),
            case send_m2pa_ack(Data) of
                {ok, AckedData} -> {keep_state, AckedData};
                {error, _Reason, FailedData} ->
                    {keep_state, FailedData}
            end
    end.

m2pa_transfer_data({ok, NewData}, _Data) when is_map(NewData) ->
    NewData;
m2pa_transfer_data(_Result, Data) ->
    Data.

handle_m2pa_mtp3_transfer(
    #{si := ?STP_MTP3_SI_SNMM, payload := Payload} = Transfer,
    Data
) ->
    Variant = maps:get(point_code_variant, Transfer),
    case telco_stp_snmm:decode(Variant, Payload) of
        {ok, Snmm} ->
            handle_m2pa_snmm(Snmm, Transfer, Data);
        {error, Reason} ->
            telco_stp_metrics:increment({snmm, decode_error}),
            raise_link_alarm(
                snmm_decode, warning,
                #{reason => Reason, variant => Variant}, Data
            ),
            {error, Reason}
    end;
handle_m2pa_mtp3_transfer(Transfer, Data) ->
    telco_stp_dispatcher:ingress(maps:get(name, Data), Transfer),
    telco_stp_metrics:increment({m2pa, user_data, received}),
    ok.

handle_m2pa_snmm(#{type := Type} = Snmm, Transfer, Data)
        when Type =:= coo; Type =:= xco; Type =:= eco; Type =:= cbd ->
    handle_m2pa_changeover_snmm(Snmm, Transfer, Data);
handle_m2pa_snmm(#{type := Type} = Snmm, Transfer, Data)
        when Type =:= lin; Type =:= lun; Type =:= lfu ->
    handle_m2pa_inhibit_snmm(Snmm, Transfer, Data);
handle_m2pa_snmm(#{type := Type} = Snmm, _Transfer, Data)
        when Type =:= coa; Type =:= xca; Type =:= eca; Type =:= cba ->
    M2pa = maps:get(m2pa, Data),
    NetworkManagement = maps:get(network_management, M2pa, #{}),
    Updated = NetworkManagement#{
        last_acknowledgement => Snmm#{
            received_at => erlang:monotonic_time(millisecond)
        }
    },
    telco_stp_metrics:increment({snmm, Type}),
    {ok, Data#{m2pa => M2pa#{network_management => Updated}}};
handle_m2pa_snmm(#{type := Type} = Snmm, Transfer, Data)
        when Type =:= tfp; Type =:= tfr; Type =:= tfa;
             Type =:= tfc; Type =:= upu ->
    Status = snmm_destination_status(Snmm),
    Destination = maps:get(affected_destination, Snmm),
    Metadata = snmm_destination_metadata(Snmm, Transfer),
    Result = telco_stp_route_table:set_destination_state(
        maps:get(name, Data), Status, [{0, Destination}], Metadata
    ),
    case Result of
        ok ->
            telco_stp_metrics:increment({snmm, Type}),
            clear_link_alarm(snmm_decode, #{reason => valid_snmm}, Data),
            ok;
        {error, Reason} ->
            telco_stp_metrics:increment({snmm, invalid}),
            raise_link_alarm(
                snmm_update, warning, #{reason => Reason, type => Type}, Data
            ),
            {error, Reason}
    end;
handle_m2pa_snmm(#{type := Type}, _Transfer, _Data)
        when Type =:= rst; Type =:= rsr ->
    telco_stp_metrics:increment({snmm, Type}),
    ok;
handle_m2pa_snmm(#{type := Type}, _Transfer, _Data) ->
    telco_stp_metrics:increment({snmm, ignored, Type}),
    ok.

handle_m2pa_inhibit_snmm(#{type := Type} = Snmm, Transfer, Data) ->
    M2pa = maps:get(m2pa, Data),
    NetworkManagement0 = maps:get(network_management, M2pa, #{}),
    Event = snmm_event(Snmm, Transfer),
    case maybe_send_inhibit_acknowledgement(Snmm, Transfer, Data) of
        {ok, SentData, AckSent} ->
            SentM2pa = maps:get(m2pa, SentData),
            NetworkManagement = NetworkManagement0#{
                link_inhibit_state => inhibit_state(Type),
                last_link_inhibit => Event,
                last_link_inhibit_ack_sent => AckSent
            },
            telco_stp_metrics:increment({snmm, Type}),
            {ok, SentData#{m2pa => SentM2pa#{
                network_management => NetworkManagement
            }, congestion => inhibit_congestion(Type)}};
        {error, Reason, FailedData} ->
            telco_stp_metrics:increment({snmm, inhibit_ack_failed}),
            raise_link_alarm(
                snmm_inhibit, warning,
                #{reason => Reason, type => Type}, Data
            ),
            {error, FailedData#{last_error => {snmm_ack_failed, Reason}}}
    end.

maybe_send_inhibit_acknowledgement(#{type := lfu}, _Transfer, Data) ->
    {ok, Data, undefined};
maybe_send_inhibit_acknowledgement(Snmm, Transfer, Data) ->
    Ack = inhibit_acknowledgement(Snmm),
    case send_m2pa_snmm(Ack, Transfer, Data) of
        {ok, SentData} ->
            {ok, SentData, Ack#{
                sent_at => erlang:monotonic_time(millisecond)
            }};
        Error ->
            Error
    end.

inhibit_acknowledgement(#{type := lin}) ->
    #{type => lia};
inhibit_acknowledgement(#{type := lun}) ->
    #{type => lua}.

inhibit_state(lin) ->
    inhibited;
inhibit_state(_Type) ->
    normal.

inhibit_congestion(lin) ->
    3;
inhibit_congestion(_Type) ->
    0.

handle_m2pa_changeover_snmm(#{type := Type} = Snmm, Transfer, Data) ->
    M2pa = maps:get(m2pa, Data),
    NetworkManagement0 = maps:get(network_management, M2pa, #{}),
    Event = snmm_event(Snmm, Transfer),
    {Retrieved, RetrievedData} = retrieve_for_changeover(Snmm, Data),
    Ack = changeover_acknowledgement(Snmm),
    case send_m2pa_snmm(Ack, Transfer, RetrievedData) of
        {ok, SentData} ->
            SentM2pa = maps:get(m2pa, SentData),
            RerouteResults = reroute_retrieved_changeover(
                maps:get(name, Data), Retrieved
            ),
            NetworkManagement = NetworkManagement0#{
                changeover_state => changeover_state(Type),
                last_changeover => Event#{
                    retrieved => length(Retrieved),
                    retrieved_fsns => [
                        maps:get(fsn, Item) || Item <- Retrieved
                    ],
                    reroute_results => RerouteResults
                },
                last_changeover_ack_sent => Ack#{
                    sent_at => erlang:monotonic_time(millisecond)
                }
            },
            telco_stp_metrics:increment({snmm, Type}),
            telco_stp_metrics:add(
                {snmm, changeover_retrieved}, length(Retrieved)
            ),
            {ok, SentData#{m2pa => SentM2pa#{
                network_management => NetworkManagement
            }, congestion => changeover_congestion(Type)}};
        {error, Reason, FailedData} ->
            telco_stp_metrics:increment({snmm, changeover_ack_failed}),
            raise_link_alarm(
                snmm_changeover, warning,
                #{reason => Reason, type => Type}, Data
            ),
            {error, FailedData#{last_error => {snmm_ack_failed, Reason}}}
    end.

snmm_event(Snmm, Transfer) ->
    Snmm#{
        received_at => erlang:monotonic_time(millisecond),
        opc => maps:get(opc, Transfer),
        dpc => maps:get(dpc, Transfer)
    }.

retrieve_for_changeover(#{type := cbd}, Data) ->
    {[], Data};
retrieve_for_changeover(#{type := eco}, Data) ->
    case retrieve_m2pa_messages(undefined, Data) of
        {ok, Messages, NewData} ->
            {Messages, NewData};
        {error, Reason} ->
            M2pa = maps:get(m2pa, Data),
            NetworkManagement = maps:get(network_management, M2pa, #{}),
            {[], Data#{m2pa => M2pa#{
                network_management => NetworkManagement#{
                    last_changeover_retrieval_error => Reason
                }
            }}}
    end;
retrieve_for_changeover(#{fsn := Fsn}, Data) ->
    M2pa = maps:get(m2pa, Data),
    AcknowledgedData = Data#{
        m2pa => telco_stp_m2pa_state:acknowledge(Fsn, M2pa)
    },
    case retrieve_m2pa_messages(Fsn, AcknowledgedData) of
        {ok, Messages, NewData} ->
            {Messages, NewData};
        {error, Reason} ->
            CurrentM2pa = maps:get(m2pa, AcknowledgedData),
            NetworkManagement = maps:get(
                network_management, CurrentM2pa, #{}
            ),
            {[], AcknowledgedData#{m2pa => CurrentM2pa#{
                network_management => NetworkManagement#{
                    last_changeover_retrieval_error => Reason
                }
            }}}
    end.

reroute_retrieved_changeover(SourceLink, Retrieved) ->
    [
        reroute_retrieved_message(SourceLink, Item)
        || Item <- Retrieved
    ].

reroute_retrieved_message(SourceLink, #{fsn := Fsn, transfer := Transfer}) ->
    Result = telco_stp_dispatcher:reroute(SourceLink, Transfer),
    case Result of
        {ok, #{link := Link} = Details} ->
            telco_stp_metrics:increment({snmm, changeover_rerouted}),
            #{fsn => Fsn, result => ok, link => Link, details => Details};
        {error, Reason} ->
            telco_stp_metrics:increment(
                {snmm, changeover_reroute_failed}
            ),
            #{fsn => Fsn, result => {error, Reason}}
    end.

changeover_state(cbd) ->
    normal;
changeover_state(eco) ->
    emergency_changeover;
changeover_state(_Type) ->
    changeover.

changeover_congestion(cbd) ->
    0;
changeover_congestion(_Type) ->
    3.

changeover_acknowledgement(#{type := coo, fsn := Fsn}) ->
    #{type => coa, fsn => Fsn};
changeover_acknowledgement(#{type := xco, fsn := Fsn}) ->
    #{type => xca, fsn => Fsn};
changeover_acknowledgement(#{type := eco}) ->
    #{type => eca};
changeover_acknowledgement(#{type := cbd, changeback_code := Code}) ->
    #{type => cba, changeback_code => Code}.

send_m2pa_snmm(Snmm, Transfer, Data) ->
    Variant = maps:get(point_code_variant, Transfer),
    case telco_stp_snmm:encode(Variant, Snmm) of
        {ok, Payload} ->
            Reply = #{
                opc => maps:get(dpc, Transfer),
                dpc => maps:get(opc, Transfer),
                si => ?STP_MTP3_SI_SNMM,
                ni => maps:get(ni, Transfer),
                mp => maps:get(mp, Transfer),
                sls => maps:get(sls, Transfer),
                payload => Payload
            },
            send_m2pa_transfer(Reply, Data);
        {error, Reason} ->
            {error, {snmm_encode_failed, Reason}, Data}
    end.

snmm_destination_status(#{type := tfp}) -> unavailable;
snmm_destination_status(#{type := tfr}) -> restricted;
snmm_destination_status(#{type := tfa}) -> available;
snmm_destination_status(#{type := tfc, congestion_status := 0}) -> available;
snmm_destination_status(#{type := tfc}) -> congested;
snmm_destination_status(#{type := upu}) -> user_unavailable.

snmm_destination_metadata(#{type := Type} = Snmm, Transfer) ->
    Base = #{
        source => q704_snmm,
        snmm_type => Type,
        opc => maps:get(opc, Transfer),
        network_indicator => maps:get(ni, Transfer),
        point_code_variant => maps:get(point_code_variant, Transfer)
    },
    WithCongestion =
        case maps:find(congestion_status, Snmm) of
            {ok, 0} -> Base;
            {ok, Level} -> Base#{congestion => min(3, max(1, Level))};
            error -> Base
        end,
    case maps:find(user_part, Snmm) of
        {ok, UserPart} ->
            WithCongestion#{
                user_part => UserPart,
                cause => maps:get(unavailability_cause, Snmm)
            };
        error ->
            WithCongestion
    end.

send_m2pa_transfer(Message, Data) ->
    Config = maps:get(config, Data),
    M2pa = maps:get(m2pa, Data),
    Unacked = maps:get(unacked, M2pa),
    Maximum = maps:get(
        m2pa_max_unacked, Config, ?STP_DEFAULT_M2PA_MAX_UNACKED
    ),
    case length(Unacked) >= Maximum of
        true ->
            {error, m2pa_retransmit_buffer_full, Data};
        false ->
            Variant = point_code_variant(Config),
            case telco_stp_mtp3:encode(Variant, Message) of
                {ok, Mtp3} ->
                    Fsn = telco_stp_m2pa:next_sequence(
                        maps:get(tx_fsn, M2pa)
                    ),
                    Packet = #{
                        type => user_data,
                        bsn => maps:get(rx_fsn, M2pa),
                        fsn => Fsn,
                        priority => maps:get(
                            m2pa_priority, Config, 0
                        ),
                        mtp3 => Mtp3
                    },
                    case send_m2pa_packet(1, Packet, Data) of
                        {ok, SentData} ->
                            Entry = #{
                                fsn => Fsn,
                                message => Message,
                                mtp3 => Mtp3,
                                sent_at =>
                                    erlang:monotonic_time(millisecond)
                            },
                            SentM2pa = maps:get(m2pa, SentData),
                            T7 = maps:get(
                                m2pa_t7_ms, Config,
                                ?STP_DEFAULT_M2PA_T7_MS
                            ),
                            _ = erlang:send_after(
                                T7, self(), {m2pa_t7, Fsn}
                            ),
                            {ok, SentData#{m2pa => SentM2pa#{
                                tx_fsn => Fsn,
                                unacked => Unacked ++ [Entry]
                            }}};
                        Error ->
                            Error
                    end;
                {error, Reason} ->
                    {error, {mtp3_encode_failed, Reason}, Data}
            end
    end.

send_m2pa_ack(Data) ->
    M2pa = maps:get(m2pa, Data),
    Packet = #{
        type => user_data,
        bsn => maps:get(rx_fsn, M2pa),
        fsn => maps:get(tx_fsn, M2pa),
        priority => 0,
        mtp3 => <<>>
    },
    send_m2pa_packet(1, Packet, Data).

send_m2pa_status(Status, Stream, Data) ->
    M2pa = maps:get(m2pa, Data),
    Config = maps:get(config, Data),
    Filler =
        case Status of
            proving_normal ->
                proving_filler(Config);
            proving_emergency ->
                proving_filler(Config);
            _ ->
                <<>>
        end,
    Packet = #{
        type => link_status,
        bsn => maps:get(rx_fsn, M2pa),
        fsn => maps:get(tx_fsn, M2pa),
        status => Status,
        filler => Filler
    },
    case send_m2pa_packet(Stream, Packet, Data) of
        {ok, SentData} ->
            SentM2pa = maps:get(m2pa, SentData),
            {ok, SentData#{m2pa => SentM2pa#{
                local_status => Status
            }}};
        Error ->
            Error
    end.

send_m2pa_status_transition(
    Status, Stream, NextState, Data, UpdateFun, FailureTag
) ->
    case send_m2pa_status(Status, Stream, Data) of
        {ok, SentData} ->
            {next_state, NextState, UpdateFun(SentData)};
        {error, Reason, FailedData} ->
            m2pa_protocol_violation({FailureTag, Reason}, FailedData)
    end.

identity(Value) ->
    Value.

send_m2pa_packet(Stream, Packet, Data) ->
    case telco_stp_m2pa:encode(Packet) of
        {ok, Binary} ->
            transport_send({stream, Stream, Binary}, Data);
        {error, Reason} ->
            {error, Reason, Data}
    end.

proving_filler(Config) ->
    Length = maps:get(m2pa_proving_filler_bytes, Config, 0),
    case Length of
        0 -> <<>>;
        Value when is_integer(Value), Value > 0,
                   Value =< ?STP_MAX_SHORT_BYTES ->
            crypto:strong_rand_bytes(Value)
    end.

handle_m2pa_t7(Fsn, Data) ->
    M2pa = maps:get(m2pa, Data),
    case lists:any(
        fun(Entry) -> maps:get(fsn, Entry) =:= Fsn end,
        maps:get(unacked, M2pa)
    ) of
        false ->
            {keep_state, Data};
        true ->
            raise_link_alarm(
                m2pa_t7, major,
                #{reason => excessive_acknowledgement_delay, fsn => Fsn},
                Data
            ),
            Failed = Data#{
                congestion => 3,
                last_error => {m2pa_t7_expired, Fsn},
                m2pa => M2pa#{
                    local_status => out_of_service,
                    last_error => {t7_expired, Fsn}
                }
            },
            case send_m2pa_status(out_of_service, 0, Failed) of
                {ok, SentData} -> {next_state, inactive, SentData};
                {error, _Reason, FailedData} ->
                    {next_state, inactive, FailedData}
            end
    end.

m2pa_protocol_violation(Reason, Data) ->
    telco_stp_metrics:increment({m2pa, protocol_violation}),
    raise_link_alarm(
        m2pa_protocol, warning, #{reason => Reason}, Data
    ),
    M2pa = maps:get(m2pa, Data),
    {keep_state, Data#{
        last_error => {m2pa_protocol, Reason},
        m2pa => M2pa#{last_error => Reason}
    }}.

retrieve_m2pa_messages(AfterFsn, Data) ->
    Config = maps:get(config, Data),
    case maps:get(adaptation, Config, m3ua) of
        m3ua ->
            {error, not_m2pa_link};
        m2pa ->
            case telco_stp_m2pa_state:retrieve(
                AfterFsn, maps:get(m2pa, Data)
            ) of
                {ok, Messages, M2pa} ->
                    {ok, Messages, Data#{m2pa => M2pa}};
                Error ->
                    Error
            end
    end.

point_code_variant(Config) ->
    maps:get(
        point_code_variant, Config,
        maps:get(sccp_variant, Config, itu)
    ).

m2pa_status(Data) ->
    Config = maps:get(config, Data),
    case maps:get(adaptation, Config, m3ua) of
        m3ua ->
            #{enabled => false};
        m2pa ->
            telco_stp_m2pa_state:status(maps:get(m2pa, Data))
    end.

close_transport(#{connected := false} = Data) ->
    cancel_heartbeat(Data);
close_transport(Data) ->
    Module = maps:get(transport_module, Data),
    _ = Module:close(maps:get(transport_state, Data)),
    cancel_heartbeat(
        Data#{transport_state => undefined, connected => false}
    ).

schedule_reconnect(#{admin := down} = Data) ->
    {next_state, down, Data};
schedule_reconnect(#{reconnect_ref := Ref} = Data) when is_reference(Ref) ->
    {next_state, down, Data};
schedule_reconnect(Data) ->
    Config = maps:get(config, Data),
    Delay = maps:get(reconnect_ms, Config, ?STP_DEFAULT_RECONNECT_MS),
    Ref = erlang:send_after(Delay, self(), reconnect),
    {next_state, down, Data#{reconnect_ref => Ref}}.

maybe_copy_param(Key, Source, Destination) ->
    case maps:find(Key, Source) of
        {ok, Value} -> Destination#{Key => Value};
        error -> Destination
    end.

handle_destination_audit(Params, Data) ->
    case maps:find(affected_point_code, Params) of
        {ok, Affected} when is_list(Affected), Affected =/= [] ->
            BaseParams = maps:with(
                [network_appearance, routing_context], Params
            ),
            case send_audit_responses(Affected, BaseParams, Data) of
                {ok, NewData} ->
                    telco_stp_metrics:increment({ssnm, daud}),
                    {keep_state, NewData};
                {error, Reason, NewData} ->
                    {keep_state, NewData#{
                        last_error => {daud_response_failed, Reason}
                    }}
            end;
        _ ->
            {keep_state, Data#{last_error => invalid_daud}}
    end.

send_audit_responses([], _BaseParams, Data) ->
    {ok, Data};
send_audit_responses([{Mask, Dpc} = Affected | Rest], BaseParams, Data) ->
    Type =
        case Mask =:= 0 andalso route_available(Dpc, Data) of
            true -> dava;
            false -> duna
        end,
    Params = BaseParams#{affected_point_code => [Affected]},
    case send_control(ssnm, Type, Params, Data) of
        {ok, NewData} ->
            send_audit_responses(Rest, BaseParams, NewData);
        {error, Reason, NewData} ->
            {error, Reason, NewData}
    end.

route_available(Dpc, Data) ->
    Config = maps:get(config, Data),
    Message = #{
        dpc => Dpc,
        ni => maps:get(network_indicator, Config, 2),
        si => maps:get(audit_service_indicator, Config, 3),
        network_appearance => maps:get(network_appearance, Config, any)
    },
    case telco_stp_route_table:lookup(Message) of
        Routes when is_list(Routes) ->
            Name = maps:get(name, Data),
            Constraints = telco_stp_route_table:path_constraints(Message),
            Exclude = lists:usort(
                [Name | maps:get(unavailable, Constraints, [])]
            ),
            lists:any(
                fun(Route) ->
                    Linksets = maps:get(linksets, Route),
                    case telco_stp_link_manager:select(
                        Linksets, 0, Dpc, Exclude,
                        maps:get(congestion, Constraints, #{})
                    ) of
                        {ok, _Link} -> true;
                        _ -> false
                    end
                end,
                Routes
            );
        _ ->
            false
    end.

raise_link_alarm(Kind, Severity, Details, Data) ->
    telco_stp_alarm:raise(
        {link, maps:get(name, Data), Kind},
        Severity,
        Details#{link => maps:get(name, Data)}
    ).

clear_link_alarm(Kind, Details, Data) ->
    telco_stp_alarm:clear(
        {link, maps:get(name, Data), Kind},
        Details#{link => maps:get(name, Data)}
    ).

data_for_state(active, Data) ->
    case maps:get(adaptation, maps:get(config, Data), m3ua) of
        m3ua -> activate_heartbeat(Data);
        m2pa -> cancel_heartbeat(Data)
    end;
data_for_state(_State, Data) ->
    cancel_heartbeat(Data).

activate_heartbeat(Data) ->
    schedule_heartbeat(cancel_heartbeat(Data)).

schedule_heartbeat(Data) ->
    Config = maps:get(config, Data),
    case maps:get(heartbeat_interval_ms, Config, 0) of
        Interval when is_integer(Interval), Interval > 0 ->
            Ref = erlang:send_after(Interval, self(), heartbeat_tick),
            Data#{heartbeat_ref => Ref};
        _ ->
            Data
    end.

send_heartbeat(Data0) ->
    Data = schedule_heartbeat(Data0),
    case maps:get(heartbeat_timeout_ref, Data) of
        Ref when is_reference(Ref) ->
            {keep_state, Data};
        undefined ->
            Token = <<(erlang:unique_integer(
                [positive, monotonic]
            )):64/big>>,
            case send_control(
                aspsm, heartbeat, #{heartbeat_data => Token}, Data
            ) of
                {ok, NewData} ->
                    Timeout = maps:get(
                        heartbeat_timeout_ms,
                        maps:get(config, Data),
                        ?STP_DEFAULT_LONG_CALL_TIMEOUT_MS
                    ),
                    TimeoutRef = erlang:send_after(
                        Timeout, self(), {heartbeat_timeout, Token}
                    ),
                    telco_stp_metrics:increment(
                        {link, maps:get(name, Data), heartbeat_tx}
                    ),
                    {keep_state, NewData#{
                        heartbeat_timeout_ref => TimeoutRef,
                        heartbeat_token => Token
                    }};
                {error, Reason, NewData} ->
                    raise_link_alarm(
                        heartbeat, warning,
                        #{reason => {heartbeat_send_failed, Reason}},
                        NewData
                    ),
                    {keep_state, NewData#{
                        last_error => {heartbeat_send_failed, Reason}
                    }}
            end
    end.

handle_heartbeat_ack(Params, _State, #{
    heartbeat_token := Token,
    heartbeat_timeout_ref := TimeoutRef
} = Data) when is_binary(Token), is_reference(TimeoutRef) ->
    case maps:find(heartbeat_data, Params) of
        {ok, Token} ->
            _ = erlang:cancel_timer(TimeoutRef),
            clear_link_alarm(
                heartbeat, #{reason => heartbeat_acknowledged}, Data
            ),
            telco_stp_metrics:increment(
                {link, maps:get(name, Data), heartbeat_ack}
            ),
            {keep_state, Data#{
                heartbeat_timeout_ref => undefined,
                heartbeat_token => undefined,
                last_heartbeat_ack => erlang:system_time(millisecond)
            }};
        Other ->
            raise_link_alarm(
                heartbeat, warning,
                #{reason => {heartbeat_data_mismatch, Other}}, Data
            ),
            {keep_state, Data#{
                last_error => {heartbeat_data_mismatch, Other}
            }}
    end;
handle_heartbeat_ack(_Params, _State, Data) ->
    {keep_state, Data}.

heartbeat_timed_out(Data) ->
    Name = maps:get(name, Data),
    telco_stp_metrics:increment({link, Name, heartbeat_timeout}),
    raise_link_alarm(
        heartbeat, major, #{reason => heartbeat_timeout}, Data
    ),
    TimedOut = Data#{
        heartbeat_timeout_ref => undefined,
        heartbeat_token => undefined,
        last_error => heartbeat_timeout
    },
    case maps:get(
        heartbeat_failure_action, maps:get(config, Data), inactive
    ) of
        reconnect ->
            schedule_reconnect(close_transport(TimedOut));
        inactive ->
            {next_state, inactive, cancel_heartbeat(TimedOut)}
    end.

cancel_heartbeat(Data) ->
    cancel_timer(maps:get(heartbeat_ref, Data, undefined)),
    cancel_timer(maps:get(heartbeat_timeout_ref, Data, undefined)),
    Data#{
        heartbeat_ref => undefined,
        heartbeat_timeout_ref => undefined,
        heartbeat_token => undefined
    }.

cancel_timer(Ref) when is_reference(Ref) ->
    _ = erlang:cancel_timer(Ref),
    ok;
cancel_timer(_Ref) ->
    ok.

heartbeat_status(Data) ->
    Config = maps:get(config, Data),
    #{
        enabled => maps:get(heartbeat_interval_ms, Config, 0) > 0,
        interval_ms => maps:get(heartbeat_interval_ms, Config, 0),
        timeout_ms => maps:get(
            heartbeat_timeout_ms, Config,
            ?STP_DEFAULT_HEARTBEAT_TIMEOUT_MS
        ),
        pending => is_reference(
            maps:get(heartbeat_timeout_ref, Data, undefined)
        ),
        last_acknowledged_at => maps:get(last_heartbeat_ack, Data, undefined)
    }.

handle_transport_event(
    {sctp_path, StateName, Address, Error}, _State, Data
) when StateName =:= addr_available; StateName =:= addr_added;
       StateName =:= addr_made_prim ->
    telco_stp_metrics:increment(
        {link, maps:get(name, Data), sctp_path_available}
    ),
    telco_stp_alarm:clear(
        {link, maps:get(name, Data), sctp_path, Address},
        #{state => StateName, error => Error}
    ),
    {keep_state, Data};
handle_transport_event(
    {sctp_path, StateName, Address, Error}, _State, Data
) when StateName =:= addr_unreachable; StateName =:= addr_removed ->
    telco_stp_metrics:increment(
        {link, maps:get(name, Data), sctp_path_unavailable}
    ),
    telco_stp_alarm:raise(
        {link, maps:get(name, Data), sctp_path, Address},
        warning,
        #{state => StateName, error => Error}
    ),
    {keep_state, Data#{
        last_error => {sctp_path, StateName, Address, Error}
    }};
handle_transport_event(Event, _State, Data) ->
    telco_stp_metrics:increment(
        {link, maps:get(name, Data), transport_warning}
    ),
    telco_stp_alarm:raise(
        {link, maps:get(name, Data), transport_warning},
        warning,
        #{event => Event}
    ),
    {keep_state, Data#{last_error => {transport_warning, Event}}}.
