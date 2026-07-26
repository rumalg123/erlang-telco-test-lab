-module(telco_stp_mtp3_tests).

-include_lib("eunit/include/eunit.hrl").

itu_roundtrip_test() ->
    Message = #{
        opc => 16#1234,
        dpc => 16#2345,
        si => 5,
        ni => 2,
        mp => 1,
        sls => 13,
        payload => <<"ISUP">>
    },
    {ok, Binary} = telco_stp_mtp3:encode(itu, Message),
    ?assertEqual({ok, Message}, telco_stp_mtp3:decode(itu, Binary)).

ansi_roundtrip_test() ->
    Message = #{
        opc => 16#123456,
        dpc => 16#abcdef,
        si => 3,
        ni => 1,
        mp => 2,
        sls => 201,
        payload => <<"SCCP">>
    },
    {ok, Binary} = telco_stp_mtp3:encode(ansi, Message),
    ?assertEqual({ok, Message}, telco_stp_mtp3:decode(ansi, Binary)).

itu_range_check_test() ->
    Message = #{
        opc => 16#4000,
        dpc => 1,
        si => 3,
        ni => 2,
        mp => 0,
        sls => 0,
        payload => <<>>
    },
    ?assertEqual(
        {error, {invalid_unsigned_integer, opc, 16#4000}},
        telco_stp_mtp3:encode(itu, Message)
    ).

