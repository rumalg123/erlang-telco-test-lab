-module(telco_stp_slt_tests).

-include_lib("eunit/include/eunit.hrl").

sltm_known_vector_test() ->
    {ok, Binary} = telco_stp_slt:encode(#{
        type => sltm,
        test_pattern => <<"TEST">>
    }),
    ?assertEqual(<<16#11, 16#04, "TEST">>, Binary),
    ?assertEqual(
        {ok, #{type => sltm, test_pattern => <<"TEST">>}},
        telco_stp_slt:decode(Binary)
    ).

slta_roundtrip_test() ->
    Message = #{type => slta, test_pattern => <<1, 2, 3>>},
    {ok, Binary} = telco_stp_slt:encode(Message),
    ?assertEqual(<<16#21, 16#03, 1, 2, 3>>, Binary),
    ?assertEqual({ok, Message}, telco_stp_slt:decode(Binary)).

strict_pattern_length_test() ->
    ?assertMatch(
        {error, {invalid_slt_pattern_length, 0}},
        telco_stp_slt:encode(#{
            type => sltm, test_pattern => <<>>
        })
    ),
    ?assertMatch(
        {error, {invalid_slt_payload_length, 4, 3}},
        telco_stp_slt:decode(<<16#11, 16#04, 1, 2, 3>>)
    ).
