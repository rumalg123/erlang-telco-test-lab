-module(telco_stp_m3ua_tests).

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
        16#0207:16/big, 11:16/big,
        16#020a:16/big, 7:16/big, 1:24,
        0:8
    >>,
    Length = 8 + byte_size(RoutingKey),
    ?assertMatch(
        {error, {truncated_nested_parameter, 16#020a, 7}},
        telco_stp_m3ua:decode(
            <<1, 0, 9, 1, Length:32/big, RoutingKey/binary>>
        )
    ).
