-module(telco_stp_sccp_tests).

-include_lib("eunit/include/eunit.hrl").

address_gti4_roundtrip_test() ->
    Address = #{
        routing_indicator => gt,
        point_code => 1234,
        ssn => 6,
        global_title => #{
            gti => 4,
            translation_type => 0,
            numbering_plan => 1,
            encoding_scheme => 1,
            nature_of_address => 4,
            digits => <<"94771234567">>
        }
    },
    {ok, Binary} = telco_stp_sccp:encode_address(Address),
    {ok, Decoded} = telco_stp_sccp:decode_address(Binary),
    ?assertEqual(Address#{national_use => false}, Decoded).

ansi_point_code_address_roundtrip_test() ->
    Address = #{
        routing_indicator => ssn,
        point_code => 16#abcdef,
        ssn => 8
    },
    {ok, Binary} = telco_stp_sccp:encode_address(Address, ansi),
    ?assertEqual(5, byte_size(Binary)),
    {ok, Decoded} = telco_stp_sccp:decode_address(Binary, ansi),
    ?assertEqual(Address#{national_use => false}, Decoded).

ansi_udt_roundtrip_test() ->
    Message = #{
        type => udt,
        protocol_class => 0,
        called_party => #{
            routing_indicator => ssn,
            point_code => 16#010203,
            ssn => 6
        },
        calling_party => #{
            routing_indicator => ssn,
            point_code => 16#a0b0c0,
            ssn => 8
        },
        data => <<"ANSI-SCCP">>
    },
    {ok, Binary} = telco_stp_sccp:encode(Message, ansi),
    {ok, Decoded} = telco_stp_sccp:decode(Binary, ansi),
    ?assertEqual(ansi, maps:get(point_code_variant, Decoded)),
    ?assertEqual(
        16#010203,
        maps:get(point_code, maps:get(called_party, Decoded))
    ),
    ?assertEqual(<<"ANSI-SCCP">>, maps:get(data, Decoded)).

udt_roundtrip_test() ->
    Message = #{
        type => udt,
        protocol_class => 16#80,
        called_party => gt_address(<<"94770000001">>),
        calling_party => #{
            routing_indicator => ssn,
            point_code => 100,
            ssn => 8
        },
        data => <<"TCAP">>
    },
    {ok, Binary} = telco_stp_sccp:encode(Message),
    ?assertMatch(<<16#09, 16#80, 3, _/binary>>, Binary),
    {ok, Decoded} = telco_stp_sccp:decode(Binary),
    ?assertEqual(<<"TCAP">>, maps:get(data, Decoded)),
    ?assertEqual(
        <<"94770000001">>,
        maps:get(digits, maps:get(
            global_title, maps:get(called_party, Decoded)
        ))
    ).

xudt_options_and_hop_test() ->
    Message = #{
        type => xudt,
        protocol_class => 0,
        hop_counter => 10,
        called_party => gt_address(<<"123456">>),
        calling_party => gt_address(<<"654321">>),
        data => <<1, 2, 3>>,
        options => [{importance, <<5>>}]
    },
    {ok, Binary} = telco_stp_sccp:encode(Message),
    {ok, Decoded} = telco_stp_sccp:decode(Binary),
    ?assertEqual([{importance, <<5>>}], maps:get(options, Decoded)),
    {ok, Relayed} = telco_stp_sccp:prepare_relay(Decoded),
    ?assertEqual(9, maps:get(hop_counter, Relayed)).

xudt_unknown_option_roundtrip_test() ->
    Message = #{
        type => xudt,
        protocol_class => 0,
        hop_counter => 10,
        called_party => gt_address(<<"123456">>),
        calling_party => gt_address(<<"654321">>),
        data => <<1, 2, 3>>,
        options => [{16#33, <<7>>}]
    },
    {ok, Binary} = telco_stp_sccp:encode(Message),
    {ok, Decoded} = telco_stp_sccp:decode(Binary),
    ?assertEqual([{16#33, <<7>>}], maps:get(options, Decoded)).

structured_segmentation_parameter_test() ->
    Segmentation = #{
        first_segment => true,
        class => 1,
        remaining_segments => 2,
        local_reference => 16#010203
    },
    {ok, <<16#c2, 1, 2, 3>>} =
        telco_stp_sccp:encode_segmentation(Segmentation),
    {ok, Segmentation} =
        telco_stp_sccp:decode_segmentation(<<16#c2, 1, 2, 3>>),
    Message = #{
        type => xudt,
        protocol_class => 1,
        hop_counter => 10,
        called_party => gt_address(<<"123456">>),
        calling_party => gt_address(<<"654321">>),
        data => <<"segment">>,
        options => [{segmentation, Segmentation}]
    },
    {ok, Binary} = telco_stp_sccp:encode(Message),
    {ok, Decoded} = telco_stp_sccp:decode(Binary),
    ?assertEqual(
        [{segmentation, Segmentation}], maps:get(options, Decoded)
    ).

hop_violation_test() ->
    ?assertEqual(
        {error, hop_counter_violation},
        telco_stp_sccp:prepare_relay(#{
            type => xudt,
            hop_counter => 1
        })
    ).

malformed_pointer_test() ->
    ?assertMatch(
        {error, {sccp_pointer_out_of_range, _, _, _}},
        telco_stp_sccp:decode(<<16#09, 0, 255, 1, 1>>)
    ).

ludt_long_payload_roundtrip_test() ->
    Data = binary:copy(<<16#aa>>, 300),
    Message = #{
        type => ludt,
        protocol_class => 1,
        hop_counter => 15,
        called_party => gt_address(<<"441234567890">>),
        calling_party => gt_address(<<"94771234567">>),
        data => Data,
        options => [
            {segmentation, <<16#81, 1, 2, 3>>},
            {importance, <<6>>}
        ]
    },
    {ok, Binary} = telco_stp_sccp:encode(Message),
    {ok, Decoded} = telco_stp_sccp:decode(Binary),
    ?assertEqual(Data, maps:get(data, Decoded)),
    ?assertEqual(15, maps:get(hop_counter, Decoded)),
    ?assertEqual(
        [
            {segmentation, #{
                first_segment => true,
                class => 0,
                remaining_segments => 1,
                local_reference => 16#010203
            }},
            {importance, <<6>>}
        ],
        maps:get(options, Decoded)
    ).

udts_return_cause_roundtrip_test() ->
    Message = #{
        type => udts,
        return_cause => 1,
        called_party => gt_address(<<"1234">>),
        calling_party => gt_address(<<"5678">>),
        data => <<"returned">>
    },
    {ok, Binary} = telco_stp_sccp:encode(Message),
    {ok, Decoded} = telco_stp_sccp:decode(Binary),
    ?assertEqual(1, maps:get(return_cause, Decoded)),
    ?assertEqual(<<"returned">>, maps:get(data, Decoded)).

gt_address(Digits) ->
    #{
        routing_indicator => gt,
        ssn => 6,
        global_title => #{
            gti => 4,
            translation_type => 0,
            numbering_plan => 1,
            nature_of_address => 4,
            digits => Digits
        }
    }.
