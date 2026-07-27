-module(telco_stp_m3ua_tests).

-include("telco_stp.hrl").
-include_lib("eunit/include/eunit.hrl").

data_roundtrip_test() ->
    Transfer = #{
        opc => 1234,
        dpc => 5678,
        si => 3,
        ni => 2,
        mp => 1,
        sls => 9,
        payload => <<1, 2, 3, 4>>,
        routing_context => [10, 20],
        network_appearance => 7
    },
    {ok, Binary} = telco_stp_m3ua:encode_data(Transfer),
    ?assertMatch(<<1, 0, 1, 1, _Length:32/big, _/binary>>, Binary),
    {ok, Message} = telco_stp_m3ua:decode(Binary),
    ?assertEqual(transfer, maps:get(class, Message)),
    ?assertEqual(data, maps:get(type, Message)),
    Params = maps:get(params, Message),
    ?assertEqual([10, 20], maps:get(routing_context, Params)),
    ?assertEqual(7, maps:get(network_appearance, Params)),
    ?assertEqual(
        maps:without([routing_context, network_appearance], Transfer),
        maps:get(protocol_data, Params)
    ).

padding_roundtrip_test() ->
    {ok, Binary} = telco_stp_m3ua:encode(#{
        class => aspsm,
        type => heartbeat,
        params => #{heartbeat_data => <<"abc">>}
    }),
    ?assertEqual(16, byte_size(Binary)),
    {ok, Message} = telco_stp_m3ua:decode(Binary),
    ?assertEqual(
        <<"abc">>,
        maps:get(heartbeat_data, maps:get(params, Message))
    ).

known_asp_up_header_test() ->
    {ok, Binary} = telco_stp_m3ua:encode(#{
        class => aspsm,
        type => asp_up
    }),
    ?assertEqual(<<1, 0, 3, 1, 0, 0, 0, 8>>, Binary).

known_classes_roundtrip_test() ->
    lists:foreach(
        fun({Class, ClassId}) ->
            {ok, Binary} = telco_stp_m3ua:encode(#{
                class => Class,
                type => 1
            }),
            ?assertMatch(<<1, 0, ClassId:8, 1, 0, 0, 0, 8>>, Binary),
            {ok, Message} = telco_stp_m3ua:decode(Binary),
            ?assertEqual(Class, maps:get(class, Message)),
            ?assertEqual(ClassId, maps:get(raw_class, Message))
        end,
        [
            {management, 0},
            {transfer, 1},
            {ssnm, 2},
            {aspsm, 3},
            {asptm, 4},
            {rkm, 9}
        ]
    ).

known_message_types_roundtrip_test() ->
    lists:foreach(
        fun({Class, Type, ClassId, TypeId}) ->
            {ok, Binary} = telco_stp_m3ua:encode(#{
                class => Class,
                type => Type
            }),
            ?assertMatch(
                <<1, 0, ClassId:8, TypeId:8, 0, 0, 0, 8>>,
                Binary
            ),
            {ok, Message} = telco_stp_m3ua:decode(Binary),
            ?assertEqual(Class, maps:get(class, Message)),
            ?assertEqual(Type, maps:get(type, Message)),
            ?assertEqual(TypeId, maps:get(raw_type, Message))
        end,
        [
            {management, error, 0, 0},
            {management, notify, 0, 1},
            {transfer, data, 1, 1},
            {ssnm, duna, 2, 1},
            {ssnm, dava, 2, 2},
            {ssnm, daud, 2, 3},
            {ssnm, scon, 2, 4},
            {ssnm, dupu, 2, 5},
            {ssnm, drst, 2, 6},
            {aspsm, asp_up, 3, 1},
            {aspsm, asp_down, 3, 2},
            {aspsm, heartbeat, 3, 3},
            {aspsm, asp_up_ack, 3, 4},
            {aspsm, asp_down_ack, 3, 5},
            {aspsm, heartbeat_ack, 3, 6},
            {asptm, asp_active, 4, 1},
            {asptm, asp_inactive, 4, 2},
            {asptm, asp_active_ack, 4, 3},
            {asptm, asp_inactive_ack, 4, 4},
            {rkm, registration_request, 9, 1},
            {rkm, registration_response, 9, 2},
            {rkm, deregistration_request, 9, 3},
            {rkm, deregistration_response, 9, 4}
        ]
    ).

unknown_parameter_preserved_test() ->
    {ok, Binary} = telco_stp_m3ua:encode(#{
        class => 200,
        type => 9,
        params => #{unknown => [{16#f001, <<10, 11>>}]}
    }),
    {ok, Message} = telco_stp_m3ua:decode(Binary),
    ?assertEqual(200, maps:get(class, Message)),
    ?assertEqual([{16#f001, <<10, 11>>}],
                 maps:get(unknown, maps:get(params, Message))).

length_validation_test() ->
    ?assertEqual(
        {error, {invalid_message_length, 12, 8}},
        telco_stp_m3ua:decode(<<1, 0, 3, 1, 0, 0, 0, 12>>)
    ).

ssnm_parameters_roundtrip_test() ->
    Params = #{
        affected_point_code => [{0, 16#123456}, {8, 16#abcdef}],
        concerned_destination => 16#010203,
        congestion_indications => 2,
        user_cause => {4, 3},
        network_appearance => 10,
        routing_context => [100, 101]
    },
    {ok, Binary} = telco_stp_m3ua:encode(#{
        class => ssnm, type => scon, params => Params
    }),
    {ok, Message} = telco_stp_m3ua:decode(Binary),
    ?assertEqual(scon, maps:get(type, Message)),
    ?assertEqual(Params, maps:get(params, Message)).

management_parameters_roundtrip_test() ->
    Params = #{
        error_code => 16#0d,
        status => {1, 2},
        diagnostic_information => <<1, 2, 3>>
    },
    {ok, Binary} = telco_stp_m3ua:encode(#{
        class => management, type => error, params => Params
    }),
    {ok, Message} = telco_stp_m3ua:decode(Binary),
    ?assertEqual(Params, maps:get(params, Message)).

malformed_tlv_length_test() ->
    ?assertEqual(
        {error, {invalid_m3ua_parameter_length, 16#0004, 3}},
        telco_stp_m3ua:decode(
            <<1, 0, 3, 1, 0, 0, 0, 12, 0, 4, 0, 3>>
        )
    ).

routing_key_management_roundtrip_test() ->
    Key1 = #{
        local_rk_identifier => 1001,
        traffic_mode_type => loadshare,
        network_appearance => 7,
        destinations => [
            #{
                dpc => {0, 16#010203},
                service_indicators => [3, 5],
                originating_point_codes => [
                    {0, 16#040506}, {8, 16#070000}
                ]
            },
            #{
                dpc => {8, 16#020000},
                service_indicators => any,
                originating_point_codes => any
            }
        ]
    },
    Key2 = #{
        local_rk_identifier => 1002,
        destinations => [#{
            dpc => {0, 16#111213},
            service_indicators => any,
            originating_point_codes => any
        }]
    },
    {ok, RequestBinary} = telco_stp_m3ua:encode(#{
        class => rkm,
        type => registration_request,
        params => #{routing_keys => [Key1, Key2]}
    }),
    {ok, Request} = telco_stp_m3ua:decode(RequestBinary),
    ?assertEqual(
        [Key1, Key2],
        maps:get(routing_keys, maps:get(params, Request))
    ),
    RegistrationResults = [
        #{
            local_rk_identifier => 1001,
            registration_status => successfully_registered,
            routing_context => 2001
        },
        #{
            local_rk_identifier => 1002,
            registration_status => permission_denied,
            routing_context => 0
        }
    ],
    {ok, ResponseBinary} = telco_stp_m3ua:encode(#{
        class => rkm,
        type => registration_response,
        params => #{registration_results => RegistrationResults}
    }),
    {ok, Response} = telco_stp_m3ua:decode(ResponseBinary),
    ?assertEqual(
        RegistrationResults,
        maps:get(registration_results, maps:get(params, Response))
    ).

deregistration_results_roundtrip_test() ->
    Results = [
        #{
            routing_context => 2001,
            deregistration_status => successfully_deregistered
        },
        #{
            routing_context => 2002,
            deregistration_status => asp_currently_active
        }
    ],
    {ok, Binary} = telco_stp_m3ua:encode(#{
        class => rkm,
        type => deregistration_response,
        params => #{deregistration_results => Results}
    }),
    {ok, Message} = telco_stp_m3ua:decode(Binary),
    ?assertEqual(
        Results,
        maps:get(deregistration_results, maps:get(params, Message))
    ).

malformed_nested_routing_key_test() ->
    RoutingKey = <<
        ?STP_M3UA_PARAM_ROUTING_KEY:16/big, 11:16/big,
        ?STP_M3UA_PARAM_LOCAL_RK_IDENTIFIER:16/big, 7:16/big, 1:24,
        0:8
    >>,
    Length = 8 + byte_size(RoutingKey),
    ?assertMatch(
        {
            error,
            {
                truncated_nested_parameter,
                ?STP_M3UA_PARAM_LOCAL_RK_IDENTIFIER,
                7
            }
        },
        telco_stp_m3ua:decode(
            <<1, 0, 9, 1, Length:32/big, RoutingKey/binary>>
        )
    ).

duplicate_nested_routing_key_parameter_test() ->
    RoutingKey = <<
        ?STP_M3UA_PARAM_LOCAL_RK_IDENTIFIER:16/big, 8:16/big, 1:32/big,
        ?STP_M3UA_PARAM_LOCAL_RK_IDENTIFIER:16/big, 8:16/big, 2:32/big,
        ?STP_M3UA_PARAM_DESTINATION_POINT_CODE:16/big, 8:16/big,
        0:8, 16#010203:24/big
    >>,
    Parameter = m3ua_tlv(?STP_M3UA_PARAM_ROUTING_KEY, RoutingKey),
    Length = 8 + byte_size(Parameter),
    ?assertEqual(
        {error, {duplicate_nested_parameter, local_rk_identifier}},
        telco_stp_m3ua:decode(
            <<1, 0, 9, 1, Length:32/big, Parameter/binary>>
        )
    ).

unsupported_registration_result_parameter_test() ->
    RegistrationResult = <<
        ?STP_M3UA_PARAM_LOCAL_RK_IDENTIFIER:16/big, 8:16/big, 1:32/big,
        16#9999:16/big, 8:16/big, 2:32/big,
        ?STP_M3UA_PARAM_ROUTING_CONTEXT:16/big, 8:16/big, 3:32/big
    >>,
    Parameter = m3ua_tlv(
        ?STP_M3UA_PARAM_REGISTRATION_RESULT, RegistrationResult
    ),
    Length = 8 + byte_size(Parameter),
    ?assertEqual(
        {error, {unsupported_nested_parameter, 16#9999}},
        telco_stp_m3ua:decode(
            <<1, 0, 9, 2, Length:32/big, Parameter/binary>>
        )
    ).

invalid_registration_result_parameter_shape_test() ->
    RegistrationResult = <<
        ?STP_M3UA_PARAM_LOCAL_RK_IDENTIFIER:16/big, 7:16/big, 1:24,
        0:8
    >>,
    Parameter = m3ua_tlv(
        ?STP_M3UA_PARAM_REGISTRATION_RESULT, RegistrationResult
    ),
    Length = 8 + byte_size(Parameter),
    ?assertEqual(
        {
            error,
            {
                invalid_nested_parameter,
                ?STP_M3UA_PARAM_LOCAL_RK_IDENTIFIER,
                <<0, 0, 1>>
            }
        },
        telco_stp_m3ua:decode(
            <<1, 0, 9, 2, Length:32/big, Parameter/binary>>
        )
    ).

m3ua_tlv(Tag, Value) ->
    Length = 4 + byte_size(Value),
    PadLength = (4 - (Length rem 4)) rem 4,
    <<Tag:16/big, Length:16/big, Value/binary, 0:(PadLength * 8)>>.
