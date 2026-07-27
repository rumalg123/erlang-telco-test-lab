-module(telco_stp_scmg_tests).

-include_lib("eunit/include/eunit.hrl").

itu_ssa_roundtrip_test() ->
    Message = #{
        type => ssa,
        affected_ssn => 6,
        affected_point_code => 16#1234,
        multiplicity => 0
    },
    {ok, Binary} = telco_stp_scmg:encode(Message, itu),
    ?assertEqual(<<1, 6, 16#34, 16#12, 0>>, Binary),
    ?assertEqual({ok, Message}, telco_stp_scmg:decode(Binary, itu)).

ansi_ssp_roundtrip_test() ->
    Message = #{
        type => ssp,
        affected_ssn => 146,
        affected_point_code => 16#abcdef,
        multiplicity => 1
    },
    {ok, Binary} = telco_stp_scmg:encode(Message, ansi),
    ?assertEqual(
        <<2, 146, 16#ef, 16#cd, 16#ab, 1>>, Binary
    ),
    ?assertEqual({ok, Message}, telco_stp_scmg:decode(Binary, ansi)).

ssc_congestion_roundtrip_test() ->
    Message = #{
        type => ssc,
        affected_ssn => 6,
        affected_point_code => 100,
        multiplicity => 0,
        congestion_level => 7
    },
    {ok, Binary} = telco_stp_scmg:encode(Message, itu),
    ?assertEqual({ok, Message}, telco_stp_scmg:decode(Binary, itu)).

known_scmg_types_roundtrip_test() ->
    lists:foreach(
        fun({Type, Code}) ->
            Message = #{
                type => Type,
                affected_ssn => 6,
                affected_point_code => 100,
                multiplicity => 0
            },
            {ok, Binary} = telco_stp_scmg:encode(Message, itu),
            ?assertMatch(<<Code:8, 6, 100:16/little, 0>>, Binary),
            ?assertEqual({ok, Message}, telco_stp_scmg:decode(Binary, itu))
        end,
        [
            {ssa, 1},
            {ssp, 2},
            {sst, 3},
            {sor, 4},
            {sog, 5}
        ]
    ).

invalid_itu_point_code_test() ->
    ?assertMatch(
        {error, {invalid_scmg_length, itu, 5}},
        telco_stp_scmg:decode(<<1, 6, 16#ff, 16#ff, 0>>, itu)
    ).
