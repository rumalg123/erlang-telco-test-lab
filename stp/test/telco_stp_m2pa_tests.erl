-module(telco_stp_m2pa_tests).

-include_lib("eunit/include/eunit.hrl").

user_data_roundtrip_test() ->
    Message = #{
        type => user_data,
        bsn => 16#123456,
        fsn => 16#abcdef,
        priority => 2,
        mtp3 => <<16#83, 1, 2, 3, 4>>
    },
    {ok, Binary} = telco_stp_m2pa:encode(Message),
    ?assertMatch(
        <<1, 0, 11, 1, 0, 0, 0, 22, 0, 16#123456:24/big,
          0, 16#abcdef:24/big, _/binary>>,
        Binary
    ),
    ?assertEqual({ok, Message}, telco_stp_m2pa:decode(Binary)).

empty_ack_roundtrip_test() ->
    Message = #{
        type => user_data,
        bsn => 10,
        fsn => 20,
        priority => 0,
        mtp3 => <<>>
    },
    {ok, Binary} = telco_stp_m2pa:encode(Message),
    ?assertEqual(17, byte_size(Binary)),
    ?assertEqual({ok, Message}, telco_stp_m2pa:decode(Binary)).

link_status_and_filler_roundtrip_test() ->
    Message = #{
        type => link_status,
        bsn => 1,
        fsn => 2,
        status => proving_normal,
        filler => <<16#aa, 16#55>>
    },
    {ok, Binary} = telco_stp_m2pa:encode(Message),
    ?assertEqual({ok, Message}, telco_stp_m2pa:decode(Binary)).

sequence_wrap_test() ->
    ?assertEqual(0, telco_stp_m2pa:next_sequence(16#ffffff)),
    ?assertEqual(100, telco_stp_m2pa:next_sequence(99)).

m2pa_state_acknowledgement_trims_unacked_test() ->
    State = (telco_stp_m2pa_state:initial())#{
        unacked => [
            #{fsn => 1, message => first},
            #{fsn => 2, message => second},
            #{fsn => 3, message => third}
        ]
    },
    ?assertMatch(
        #{peer_bsn := 2, unacked := [#{fsn := 3}]},
        telco_stp_m2pa_state:acknowledge(2, State)
    ),
    ?assertMatch(
        #{peer_bsn := 9, unacked := [_, _, _]},
        telco_stp_m2pa_state:acknowledge(9, State)
    ).

m2pa_state_retrieval_selects_after_fsn_test() ->
    State = (telco_stp_m2pa_state:initial())#{
        unacked => [
            #{fsn => 1, message => first},
            #{fsn => 2, message => second},
            #{fsn => 3, message => third}
        ]
    },
    {ok, Messages, NewState} = telco_stp_m2pa_state:retrieve(1, State),
    ?assertEqual(
        [#{fsn => 2, transfer => second}, #{fsn => 3, transfer => third}],
        Messages
    ),
    ?assertMatch(#{unacked := [#{fsn := 1}]}, NewState),
    ?assertEqual(
        {error, {invalid_m2pa_retrieval_sequence, -1}},
        telco_stp_m2pa_state:retrieve(-1, State)
    ).

m2pa_state_status_projects_public_fields_test() ->
    State = (telco_stp_m2pa_state:initial())#{
        tx_fsn => 10,
        rx_fsn => 11,
        peer_bsn => 12,
        unacked => [#{fsn => 10}, #{fsn => 11}],
        network_management => #{changeover_state => changeover},
        local_status => ready,
        remote_status => busy,
        last_error => remote_busy
    },
    ?assertEqual(
        #{
            enabled => true,
            tx_fsn => 10,
            rx_fsn => 11,
            peer_bsn => 12,
            unacked => 2,
            network_management => #{changeover_state => changeover},
            local_status => ready,
            remote_status => busy,
            last_error => remote_busy
        },
        telco_stp_m2pa_state:status(State)
    ).

invalid_header_test() ->
    ?assertEqual(
        {error, {invalid_m2pa_class, 9}},
        telco_stp_m2pa:decode(
            <<1, 0, 9, 1, 0, 0, 0, 16, 0:64>>
        )
    ).
