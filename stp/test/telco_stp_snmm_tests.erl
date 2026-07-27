-module(telco_stp_snmm_tests).

-include_lib("eunit/include/eunit.hrl").

heading_allocation_test() ->
    ?assertEqual({1, 1}, telco_stp_snmm:heading(coo)),
    ?assertEqual({1, 2}, telco_stp_snmm:heading(coa)),
    ?assertEqual({4, 1}, telco_stp_snmm:heading(tfp)),
    ?assertEqual({4, 3}, telco_stp_snmm:heading(tfr)),
    ?assertEqual({4, 5}, telco_stp_snmm:heading(tfa)),
    ?assertEqual({6, 1}, telco_stp_snmm:heading(lin)),
    ?assertEqual({7, 1}, telco_stp_snmm:heading(tra)),
    ?assertEqual({11, 1}, telco_stp_snmm:heading(upu)).

all_known_types_roundtrip_test() ->
    lists:foreach(
        fun(Message) ->
            {ok, Binary} = telco_stp_snmm:encode(itu, Message),
            ?assertEqual({ok, Message}, telco_stp_snmm:decode(itu, Binary))
        end,
        [
            #{type => coo, fsn => 1},
            #{type => coa, fsn => 1},
            #{type => xco, fsn => 1},
            #{type => xca, fsn => 1},
            #{type => cbd, changeback_code => 1},
            #{type => cba, changeback_code => 1},
            #{type => eco},
            #{type => eca},
            #{type => rct, affected_destination => 1},
            #{type => tfc, affected_destination => 1, congestion_status => 1},
            #{type => tfp, affected_destination => 1},
            #{type => tfr, affected_destination => 1},
            #{type => tfa, affected_destination => 1},
            #{type => rst, affected_destination => 1},
            #{type => rsr, affected_destination => 1},
            #{type => lin},
            #{type => lun},
            #{type => lia},
            #{type => lua},
            #{type => lid},
            #{type => lfu},
            #{type => llt},
            #{type => lrt},
            #{type => tra},
            #{type => dlc},
            #{type => css},
            #{type => cns},
            #{type => cnp},
            #{
                type => upu,
                affected_destination => 1,
                user_part => 1,
                unavailability_cause => 1
            }
        ]
    ).

changeover_roundtrip_test() ->
    Message = #{type => coo, fsn => 16#aa},
    {ok, Binary} = telco_stp_snmm:encode(itu, Message),
    ?assertEqual(<<16#11, 16#aa>>, Binary),
    ?assertEqual({ok, Message}, telco_stp_snmm:decode(itu, Binary)).

extended_changeover_roundtrip_test() ->
    Message = #{type => xca, fsn => 16#abcdef},
    {ok, Binary} = telco_stp_snmm:encode(itu, Message),
    ?assertEqual(<<16#41, 16#ef, 16#cd, 16#ab>>, Binary),
    ?assertEqual({ok, Message}, telco_stp_snmm:decode(itu, Binary)).

transfer_management_itu_roundtrip_test() ->
    Message = #{type => tfp, affected_destination => 16#1234},
    {ok, Binary} = telco_stp_snmm:encode(itu, Message),
    ?assertEqual(<<16#14, 16#34, 16#12>>, Binary),
    ?assertEqual({ok, Message}, telco_stp_snmm:decode(itu, Binary)).

transfer_management_ansi_roundtrip_test() ->
    Message = #{type => tfa, affected_destination => 16#abcdef},
    {ok, Binary} = telco_stp_snmm:encode(ansi, Message),
    ?assertEqual(<<16#54, 16#ef, 16#cd, 16#ab>>, Binary),
    ?assertEqual({ok, Message}, telco_stp_snmm:decode(ansi, Binary)).

transfer_control_roundtrip_test() ->
    Message = #{
        type => tfc,
        affected_destination => 16#1234,
        congestion_status => 2
    },
    {ok, Binary} = telco_stp_snmm:encode(itu, Message),
    ?assertEqual(<<16#23, 16#34, 16#12, 2>>, Binary),
    ?assertEqual({ok, Message}, telco_stp_snmm:decode(itu, Binary)).

user_part_unavailable_roundtrip_test() ->
    Message = #{
        type => upu,
        affected_destination => 16#1234,
        user_part => 3,
        unavailability_cause => 4
    },
    {ok, Binary} = telco_stp_snmm:encode(itu, Message),
    ?assertEqual(<<16#1b, 16#34, 16#12, 16#43>>, Binary),
    ?assertEqual({ok, Message}, telco_stp_snmm:decode(itu, Binary)).

bodyless_messages_roundtrip_test() ->
    lists:foreach(
        fun(Type) ->
            Message = #{type => Type},
            {ok, Binary} = telco_stp_snmm:encode(itu, Message),
            ?assertEqual({ok, Message}, telco_stp_snmm:decode(itu, Binary))
        end,
        [eco, eca, lin, lun, lia, lua, lid, lfu, llt, lrt, tra]
    ).

malformed_vectors_test() ->
    ?assertEqual(
        {error, {unsupported_snmm_heading, 15, 15}},
        telco_stp_snmm:decode(itu, <<16#ff>>)
    ),
    ?assertEqual(
        {error, {invalid_snmm_itu_point_code, 16#c000}},
        telco_stp_snmm:decode(itu, <<16#14, 0, 16#c0>>)
    ),
    ?assertEqual(
        {error, {truncated_snmm_point_code, ansi, 2}},
        telco_stp_snmm:decode(ansi, <<16#14, 1, 2>>)
    ),
    ?assertEqual(
        {error, {invalid_unsigned_integer, affected_destination, 16#4000}},
        telco_stp_snmm:encode(
            itu, #{type => tfa, affected_destination => 16#4000}
        )
    ).
