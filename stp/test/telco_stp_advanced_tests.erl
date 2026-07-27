-module(telco_stp_advanced_tests).

-include_lib("eunit/include/eunit.hrl").

-import(telco_stp_test_support, [
    add_loopback/3,
    add_loopback/4,
    await_link_state/3,
    receive_m2pa_binary/1,
    receive_m3ua_message/1,
    receive_protocol_data/1,
    sample_transfer/2
]).

advanced_stp_test_() ->
    {foreach,
     fun setup/0,
     fun cleanup/1,
     [
        fun gtt_routes_sccp_to_translated_destination/0,
        fun chained_gtt_changes_tt_and_applies_screening/0,
        fun segmented_sccp_is_bounded_and_reassembled/0,
        fun scmg_subsystem_state_controls_route_selection/0,
        fun scmg_status_test_returns_local_state/0,
        fun broadcast_traffic_mode_reaches_every_active_asp/0,
        fun active_heartbeat_is_correlated_and_supervised/0,
        fun ssnm_duna_dava_controls_failover/0,
        fun daud_returns_per_destination_state/0,
        fun rkm_dynamic_registration_controls_live_routes/0,
        fun m3ua_management_errors_and_notifications/0,
        fun m2pa_alignment_sequence_ack_and_retrieval/0,
        fun m2pa_snmm_transfer_management_controls_routes/0,
        fun m2pa_changeover_changeback_acknowledgements/0,
        fun m2pa_changeover_retrieves_and_reroutes_unacked_msus/0,
        fun m2pa_changeback_restores_primary_traffic/0,
        fun m2pa_emergency_changeover_reroutes_all_unacked_msus/0,
        fun m2pa_link_inhibit_uninhibit_controls_route_selection/0,
        fun m2pa_force_uninhibit_restores_route_selection/0,
        fun itu_signalling_link_test_is_acknowledged_on_source_link/0,
        fun authenticated_rbac_management_is_hash_chained/0,
        fun durable_audit_chain_resumes_after_restart/0,
        fun observability_trace_and_pcapng_export/0,
        fun standalone_ha_snapshot_is_integrity_protected/0,
        fun listener_peer_profiles_are_closed_by_default/0,
        fun overload_guard_sheds_and_recovers/0,
        fun alarms_acknowledge_and_clear_on_recovery/0,
        fun configuration_replace_restores_runtime/0
     ]}.

setup() ->
    ok = application:load(telco_stp),
    ok = application:set_env(telco_stp, links, []),
    ok = application:set_env(telco_stp, listeners, []),
    ok = application:set_env(telco_stp, routes, []),
    ok = application:set_env(telco_stp, gtt_rules, []),
    ok = application:set_env(telco_stp, fault_profile, #{}),
    {ok, _} = application:ensure_all_started(telco_stp),
    ok.

cleanup(_State) ->
    flush_mailbox(),
    ok = application:stop(telco_stp),
    ok = application:unload(telco_stp).

gtt_routes_sccp_to_translated_destination() ->
    add_loopback(gtt_link, gtt_set, self()),
    ok = telco_stp:add_route(#{
        id => gtt_route,
        dpc => 777,
        mask => 16#ffffff,
        ni => 2,
        si => 3,
        linksets => [gtt_set]
    }),
    ok = telco_stp:add_gtt_rule(#{
        id => sri_sm_numbers,
        prefix => <<"9477">>,
        dpc => 777,
        ssn => 6,
        translation_type => 0,
        numbering_plan => 1,
        nature_of_address => 4,
        strip_digits => 2,
        rewrite_prefix => <<"0">>
    }),
    {ok, Sccp} = telco_stp_sccp:encode(#{
        type => udt,
        protocol_class => 16#80,
        called_party => gt_address(<<"94771234567">>),
        calling_party => #{
            routing_indicator => ssn,
            point_code => 100,
            ssn => 8
        },
        data => <<"TCAP-MAP">>
    }),
    ?assertMatch(
        {ok, #{link := gtt_link, route := gtt_route}},
        telco_stp:transfer(sample_transfer(1, Sccp))
    ),
    ProtocolData = receive_protocol_data(gtt_link),
    ?assertEqual(777, maps:get(dpc, ProtocolData)),
    {ok, DecodedSccp} =
        telco_stp_sccp:decode(maps:get(payload, ProtocolData)),
    Called = maps:get(called_party, DecodedSccp),
    ?assertEqual(ssn, maps:get(routing_indicator, Called)),
    ?assertEqual(777, maps:get(point_code, Called)),
    ?assertEqual(6, maps:get(ssn, Called)),
    ?assertEqual(
        <<"0771234567">>,
        maps:get(digits, maps:get(global_title, Called))
    ).

chained_gtt_changes_tt_and_applies_screening() ->
    ok = telco_stp:add_gtt_rule(#{
        id => normalize_country_code,
        priority => 10,
        match => #{
            prefix => <<"9477">>,
            translation_type => 0,
            numbering_plan => 1,
            nature_of_address => 4
        },
        set => #{
            replace_prefix => {<<"9477">>, <<"077">>},
            translation_type => 1
        },
        continue => true
    }),
    ok = telco_stp:add_gtt_rule(#{
        id => route_normalized_mobile,
        priority => 20,
        match => #{
            prefix => <<"077">>,
            translation_type => 1
        },
        set => #{
            translation_type => 2,
            numbering_plan => 1,
            nature_of_address => 4,
            point_code => 888,
            ssn => 6,
            routing_indicator => ssn
        }
    }),
    {ok, Result} = telco_stp:translate_global_title(
        gt_address(<<"94771234567">>)
    ),
    ?assertEqual(
        [normalize_country_code, route_normalized_mobile],
        maps:get(rules, Result)
    ),
    Translated = maps:get(address, Result),
    TranslatedGt = maps:get(global_title, Translated),
    ?assertEqual(<<"0771234567">>, maps:get(digits, TranslatedGt)),
    ?assertEqual(2, maps:get(translation_type, TranslatedGt)),
    ?assertEqual(888, maps:get(point_code, Translated)),
    ?assertEqual(ssn, maps:get(routing_indicator, Translated)),
    ok = telco_stp:add_gtt_rule(#{
        id => block_premium_range,
        priority => 1,
        action => deny,
        screening_reason => premium_range_blocked,
        match => #{prefix => <<"999">>}
    }),
    ?assertMatch(
        {error, {
            gtt_screening_denied,
            block_premium_range,
            premium_range_blocked,
            _Summary,
            []
        }},
        telco_stp:translate_global_title(gt_address(<<"999123">>))
    ),
    ok = telco_stp:add_gtt_rule(#{
        id => loop_a,
        match => #{exact_digits => <<"1">>},
        set => #{digits => <<"2">>},
        continue => true
    }),
    ok = telco_stp:add_gtt_rule(#{
        id => loop_b,
        match => #{exact_digits => <<"2">>},
        set => #{digits => <<"1">>},
        continue => true
    }),
    ?assertMatch(
        {error, {gtt_loop_detected, [loop_a, loop_b], _}},
        telco_stp:translate_global_title(gt_address(<<"1">>))
    ).

segmented_sccp_is_bounded_and_reassembled() ->
    add_loopback(reassembly_link, reassembly_set, self()),
    ok = telco_stp:add_route(#{
        id => reassembly_route,
        dpc => 700,
        mask => 16#ffffff,
        linksets => [reassembly_set]
    }),
    First = segmented_sccp(true, 2, <<"AA">>),
    Middle = segmented_sccp(false, 1, <<"BB">>),
    Last = segmented_sccp(false, 0, <<"CC">>),
    ?assertMatch(
        {ok, #{disposition := awaiting_sccp_segments}},
        telco_stp:transfer(
            (sample_transfer(700, First))#{sccp_reassembly => true}
        )
    ),
    ?assertMatch(
        {ok, #{disposition := awaiting_sccp_segments}},
        telco_stp:transfer(
            (sample_transfer(700, Middle))#{sccp_reassembly => true}
        )
    ),
    ?assertMatch(
        {ok, #{disposition := forwarded, link := reassembly_link}},
        telco_stp:transfer(
            (sample_transfer(700, Last))#{sccp_reassembly => true}
        )
    ),
    ProtocolData = receive_protocol_data(reassembly_link),
    {ok, Reassembled} = telco_stp_sccp:decode(
        maps:get(payload, ProtocolData)
    ),
    ?assertEqual(<<"AABBCC">>, maps:get(data, Reassembled)),
    ?assertEqual([], [
        Value || {segmentation, Value} <-
                     maps:get(options, Reassembled, [])
    ]),
    ?assertEqual(
        0,
        maps:get(context_count, telco_stp:reassembly_status())
    ).

scmg_subsystem_state_controls_route_selection() ->
    add_loopback(scmg_primary, scmg_primary_set, self()),
    add_loopback(scmg_secondary, scmg_secondary_set, self()),
    ok = telco_stp:add_route(#{
        id => scmg_route,
        dpc => 4243,
        mask => 16#ffffff,
        linksets => [scmg_primary_set, scmg_secondary_set]
    }),
    inject_scmg(scmg_primary, ssp, 4243, 6, 200),
    await_subsystem_status(
        scmg_primary, 4243, 6, prohibited, 100
    ),
    AppPayload = ssn_sccp(4243, 6, <<"MAP">>),
    ?assertMatch(
        {ok, #{link := scmg_secondary}},
        telco_stp:transfer(sample_transfer(4243, AppPayload))
    ),
    _ = receive_protocol_data(scmg_secondary),
    inject_scmg(scmg_primary, ssa, 4243, 6, 200),
    await_subsystem_status(
        scmg_primary, 4243, 6, available, 100
    ),
    ?assertMatch(
        {ok, #{link := scmg_primary}},
        telco_stp:transfer(sample_transfer(4243, AppPayload))
    ),
    _ = receive_protocol_data(scmg_primary).

scmg_status_test_returns_local_state() ->
    add_loopback(scmg_test_peer, scmg_test_set, self()),
    ok = telco_stp:set_subsystem_state(
        local, 200, 6, available, #{}
    ),
    inject_scmg(scmg_test_peer, sst, 200, 6, 200),
    Response = receive_protocol_data(scmg_test_peer),
    {ok, ResponseSccp} = telco_stp_sccp:decode(
        maps:get(payload, Response)
    ),
    {ok, ResponseScmg} = telco_stp_scmg:decode(
        maps:get(data, ResponseSccp), itu
    ),
    ?assertEqual(ssa, maps:get(type, ResponseScmg)),
    ?assertEqual(6, maps:get(affected_ssn, ResponseScmg)),
    ?assertEqual(200, maps:get(affected_point_code, ResponseScmg)).

broadcast_traffic_mode_reaches_every_active_asp() ->
    add_loopback(broadcast_a, broadcast_set, self()),
    add_loopback(broadcast_b, broadcast_set, self()),
    ok = telco_stp:add_route(#{
        id => broadcast_route,
        dpc => 778,
        mask => 16#ffffff,
        linksets => [broadcast_set],
        traffic_mode => broadcast
    }),
    ?assertMatch(
        {ok, #{
            disposition := broadcast,
            links := [broadcast_a, broadcast_b]
        }},
        telco_stp:transfer(sample_transfer(778, <<"broadcast">>))
    ),
    ?assertEqual(
        <<"broadcast">>,
        maps:get(payload, receive_protocol_data(broadcast_a))
    ),
    ?assertEqual(
        <<"broadcast">>,
        maps:get(payload, receive_protocol_data(broadcast_b))
    ).

active_heartbeat_is_correlated_and_supervised() ->
    {ok, _Pid} = telco_stp:add_link(#{
        name => heartbeat_link,
        linkset => heartbeat_set,
        transport => telco_stp_transport_loopback,
        peer => self(),
        auto_activate => true,
        heartbeat_interval_ms => 30,
        heartbeat_timeout_ms => 500,
        heartbeat_failure_action => inactive
    }),
    await_link_state(heartbeat_link, active, 100),
    Token =
        receive
            {m3ua, heartbeat_link, Binary} ->
                {ok, Message} = telco_stp_m3ua:decode(Binary),
                ?assertEqual(heartbeat, maps:get(type, Message)),
                maps:get(heartbeat_data, maps:get(params, Message))
        after 1000 ->
            error(heartbeat_receive_timeout)
        end,
    {ok, Ack} = telco_stp_m3ua:encode(#{
        class => aspsm,
        type => heartbeat_ack,
        params => #{heartbeat_data => Token}
    }),
    ok = telco_stp:inject_m3ua(heartbeat_link, Ack),
    await_heartbeat_ack(heartbeat_link, 100),
    ?assertEqual([], [
        Alarm || Alarm <- telco_stp:alarms(),
                 maps:get(id, Alarm) =:=
                     {link, heartbeat_link, heartbeat}
    ]).

ssnm_duna_dava_controls_failover() ->
    add_loopback(ssnm_primary, ssnm_primary_set, self()),
    add_loopback(ssnm_secondary, ssnm_secondary_set, self()),
    ok = telco_stp:add_route(#{
        id => ssnm_route,
        dpc => 4242,
        mask => 16#ffffff,
        linksets => [ssnm_primary_set, ssnm_secondary_set]
    }),
    inject_ssnm(ssnm_primary, duna, #{
        affected_point_code => [{0, 4242}]
    }),
    await_destination_status(ssnm_primary, 4242, unavailable, 100),
    ?assertMatch(
        {ok, #{link := ssnm_secondary}},
        telco_stp:transfer(sample_transfer(4242, <<"DUNA">>))
    ),
    ?assertEqual(<<"DUNA">>, maps:get(
        payload, receive_protocol_data(ssnm_secondary)
    )),
    inject_ssnm(ssnm_primary, dava, #{
        affected_point_code => [{0, 4242}]
    }),
    await_no_destination_status(ssnm_primary, 4242, 100),
    ?assertMatch(
        {ok, #{link := ssnm_primary}},
        telco_stp:transfer(sample_transfer(4242, <<"DAVA">>))
    ),
    ?assertEqual(<<"DAVA">>, maps:get(
        payload, receive_protocol_data(ssnm_primary)
    )).

daud_returns_per_destination_state() ->
    add_loopback(audit_egress, audit_egress_set, undefined),
    ok = telco_stp:add_route(#{
        id => audit_reachable,
        dpc => 9000,
        mask => 16#ffffff,
        linksets => [audit_egress_set]
    }),
    add_loopback(audit_source, audit_source_set, self(), false),
    ok = telco_stp:set_link_state(audit_source, active),
    inject_ssnm(audit_source, daud, #{
        affected_point_code => [{0, 9000}, {0, 9999}]
    }),
    Responses = collect_ssnm(audit_source, 2, []),
    ?assert(lists:member({dava, [{0, 9000}]}, Responses)),
    ?assert(lists:member({duna, [{0, 9999}]}, Responses)).

rkm_dynamic_registration_controls_live_routes() ->
    {ok, _Pid} = telco_stp:add_link(#{
        name => rkm_peer,
        linkset => rkm_set,
        transport => telco_stp_transport_loopback,
        peer => self(),
        role => sg,
        auto_activate => false,
        sccp_variant => itu,
        rkm => #{mode => dynamic}
    }),
    await_link_state(rkm_peer, down, 100),
    inject_control(rkm_peer, aspsm, asp_up, #{}),
    ?assertMatch(
        #{class := aspsm, type := asp_up_ack},
        receive_m3ua_message(rkm_peer)
    ),
    await_link_state(rkm_peer, inactive, 100),
    Key = #{
        local_rk_identifier => 77,
        traffic_mode_type => loadshare,
        destinations => [#{
            dpc => {0, 5000},
            service_indicators => [3],
            originating_point_codes => any
        }]
    },
    inject_control(
        rkm_peer, rkm, registration_request,
        #{routing_keys => [Key]}
    ),
    RegistrationResponse = receive_m3ua_message(rkm_peer),
    [RegistrationResult] = maps:get(
        registration_results, maps:get(params, RegistrationResponse)
    ),
    ?assertEqual(
        successfully_registered,
        maps:get(registration_status, RegistrationResult)
    ),
    Rc = maps:get(routing_context, RegistrationResult),
    ?assert(Rc > 0),
    ?assertMatch(
        [#{routing_context := Rc, source_link := rkm_peer}],
        telco_stp:rkm_registrations()
    ),
    inject_control(rkm_peer, asptm, asp_active, #{}),
    ?assertMatch(
        #{class := asptm, type := asp_active_ack},
        receive_m3ua_message(rkm_peer)
    ),
    await_link_state(rkm_peer, active, 100),
    ?assertMatch(
        {ok, #{link := rkm_peer}},
        telco_stp:transfer(sample_transfer(5000, <<"RKM-DATA">>))
    ),
    Routed = receive_m3ua_message(rkm_peer),
    RoutedParams = maps:get(params, Routed),
    ?assertEqual([Rc], maps:get(routing_context, RoutedParams)),
    ?assertEqual(
        <<"RKM-DATA">>,
        maps:get(payload, maps:get(protocol_data, RoutedParams))
    ),
    inject_control(
        rkm_peer, rkm, deregistration_request,
        #{routing_context => [Rc]}
    ),
    ActiveDereg = receive_m3ua_message(rkm_peer),
    [ActiveResult] = maps:get(
        deregistration_results, maps:get(params, ActiveDereg)
    ),
    ?assertEqual(
        asp_currently_active,
        maps:get(deregistration_status, ActiveResult)
    ),
    inject_control(rkm_peer, asptm, asp_inactive, #{}),
    ?assertMatch(
        #{class := asptm, type := asp_inactive_ack},
        receive_m3ua_message(rkm_peer)
    ),
    await_link_state(rkm_peer, inactive, 100),
    inject_control(
        rkm_peer, rkm, deregistration_request,
        #{routing_context => [Rc]}
    ),
    Dereg = receive_m3ua_message(rkm_peer),
    [DeregResult] = maps:get(
        deregistration_results, maps:get(params, Dereg)
    ),
    ?assertEqual(
        successfully_deregistered,
        maps:get(deregistration_status, DeregResult)
    ),
    ?assertEqual([], telco_stp:rkm_registrations()),
    ?assertNot(lists:any(
        fun(Route) ->
            maps:get(routing_context, Route, undefined) =:= Rc
        end,
        telco_stp:routes()
    )).

m3ua_management_errors_and_notifications() ->
    add_loopback(management_peer, management_set, self(), false),
    ok = telco_stp:inject_m3ua(
        management_peer, <<2, 0, 3, 1, 0, 0, 0, 8>>
    ),
    VersionError = receive_m3ua_message(management_peer),
    ?assertEqual(management, maps:get(class, VersionError)),
    ?assertEqual(error, maps:get(type, VersionError)),
    ?assertEqual(
        16#01,
        maps:get(error_code, maps:get(params, VersionError))
    ),
    {ok, Unsupported} = telco_stp_m3ua:encode(#{
        class => 200, type => 9
    }),
    ok = telco_stp:inject_m3ua(management_peer, Unsupported),
    ClassError = receive_m3ua_message(management_peer),
    ?assertEqual(
        16#03,
        maps:get(error_code, maps:get(params, ClassError))
    ),
    inject_control(
        management_peer, management, notify,
        #{
            status => {2, 1},
            routing_context => [999],
            info_string => <<"capacity warning">>
        }
    ),
    await_notification(
        management_peer, insufficient_asp_resources, 100
    ),
    ?assert(lists:any(
        fun(Alarm) ->
            maps:get(id, Alarm) =:=
                {link, management_peer, m3ua_notify}
        end,
        telco_stp:alarms()
    )).

m2pa_alignment_sequence_ack_and_retrieval() ->
    {ok, _Pid} = telco_stp:add_link(#{
        name => m2pa_peer,
        linkset => m2pa_set,
        adaptation => m2pa,
        point_code_variant => itu,
        sccp_variant => itu,
        transport => telco_stp_transport_loopback,
        peer => self(),
        m2pa_proving_ms => 1,
        m2pa_alignment_timeout_ms => 1000,
        m2pa_t7_ms => 1000
    }),
    {0, LocalAlignment} = receive_m2pa_binary(m2pa_peer),
    {ok, #{status := alignment}} =
        telco_stp_m2pa:decode(LocalAlignment),
    inject_m2pa_status(m2pa_peer, alignment, 0),
    {0, LocalProving} = receive_m2pa_binary(m2pa_peer),
    {ok, #{status := proving_normal}} =
        telco_stp_m2pa:decode(LocalProving),
    inject_m2pa_status(m2pa_peer, proving_normal, 0),
    {0, LocalReady} = receive_m2pa_binary(m2pa_peer),
    {ok, #{status := ready}} = telco_stp_m2pa:decode(LocalReady),
    inject_m2pa_status(m2pa_peer, ready, 0),
    {0, ReadyReply} = receive_m2pa_binary(m2pa_peer),
    {ok, #{status := ready}} = telco_stp_m2pa:decode(ReadyReply),
    await_link_state(m2pa_peer, active, 100),
    ok = telco_stp:add_route(#{
        id => m2pa_outbound,
        dpc => 6000,
        mask => 16#ffffff,
        linksets => [m2pa_set]
    }),
    ?assertMatch(
        {ok, #{link := m2pa_peer}},
        telco_stp:transfer(sample_transfer(6000, <<"M2PA-OUT">>))
    ),
    {1, UserBinary} = receive_m2pa_binary(m2pa_peer),
    {ok, #{
        type := user_data,
        fsn := 0,
        mtp3 := EncodedMtp3
    }} = telco_stp_m2pa:decode(UserBinary),
    {ok, OutboundTransfer} =
        telco_stp_mtp3:decode(itu, EncodedMtp3),
    ?assertEqual(<<"M2PA-OUT">>, maps:get(payload, OutboundTransfer)),
    {ok, _} = telco_stp:transfer(
        sample_transfer(6000, <<"M2PA-RETRIEVE">>)
    ),
    {1, _SecondUser} = receive_m2pa_binary(m2pa_peer),
    {ok, [#{fsn := 0}, #{fsn := 1}]} =
        telco_stp:retrieve_m2pa(m2pa_peer, undefined),
    ?assertEqual(
        0,
        maps:get(
            unacked,
            maps:get(
                m2pa,
                hd([
                    Link
                    || Link <- telco_stp:links(),
                       maps:get(name, Link) =:= m2pa_peer
                ])
            )
        )
    ),
    ok = telco_stp:remove_route(m2pa_outbound),
    add_loopback(m2pa_egress, m2pa_egress_set, self()),
    ok = telco_stp:add_route(#{
        id => m2pa_inbound,
        dpc => 7000,
        mask => 16#ffffff,
        linksets => [m2pa_egress_set]
    }),
    InboundTransfer = sample_transfer(7000, <<"M2PA-IN">>),
    {ok, InboundMtp3} = telco_stp_mtp3:encode(
        itu, InboundTransfer
    ),
    {ok, InboundM2pa} = telco_stp_m2pa:encode(#{
        type => user_data,
        bsn => 1,
        fsn => 0,
        priority => 0,
        mtp3 => InboundMtp3
    }),
    ok = telco_stp:inject_m2pa(m2pa_peer, 1, InboundM2pa),
    {1, AckBinary} = receive_m2pa_binary(m2pa_peer),
    {ok, #{type := user_data, bsn := 0, mtp3 := <<>>}} =
        telco_stp_m2pa:decode(AckBinary),
    ?assertEqual(
        <<"M2PA-IN">>,
        maps:get(payload, receive_protocol_data(m2pa_egress))
    ).

m2pa_snmm_transfer_management_controls_routes() ->
    {ok, _Pid} = telco_stp:add_link(#{
        name => snmm_m2pa_primary,
        linkset => snmm_primary_set,
        adaptation => m2pa,
        transport => telco_stp_transport_loopback,
        peer => self(),
        m2pa_proving_ms => 1,
        m2pa_alignment_timeout_ms => 1000,
        m2pa_t7_ms => 1000
    }),
    establish_m2pa(snmm_m2pa_primary),
    add_loopback(snmm_secondary, snmm_secondary_set, self()),
    ok = telco_stp:add_route(#{
        id => snmm_route,
        dpc => 7100,
        mask => 16#ffffff,
        linksets => [snmm_primary_set, snmm_secondary_set]
    }),
    inject_m2pa_snmm(
        snmm_m2pa_primary, 0,
        #{type => tfp, affected_destination => 7100}
    ),
    _ = receive_m2pa_binary(snmm_m2pa_primary),
    await_destination_status(snmm_m2pa_primary, 7100, unavailable, 100),
    ?assertMatch(
        {ok, #{link := snmm_secondary}},
        telco_stp:transfer(sample_transfer(7100, <<"SNMM-TFP">>))
    ),
    ?assertEqual(
        <<"SNMM-TFP">>,
        maps:get(payload, receive_protocol_data(snmm_secondary))
    ),
    inject_m2pa_snmm(
        snmm_m2pa_primary, 1,
        #{type => tfa, affected_destination => 7100}
    ),
    _ = receive_m2pa_binary(snmm_m2pa_primary),
    await_no_destination_status(snmm_m2pa_primary, 7100, 100),
    ?assertMatch(
        {ok, #{link := snmm_m2pa_primary}},
        telco_stp:transfer(sample_transfer(7100, <<"SNMM-TFA">>))
    ),
    {1, UserBinary} = receive_m2pa_binary(snmm_m2pa_primary),
    {ok, #{type := user_data, mtp3 := EncodedMtp3}} =
        telco_stp_m2pa:decode(UserBinary),
    {ok, RestoredTransfer} = telco_stp_mtp3:decode(itu, EncodedMtp3),
    ?assertEqual(<<"SNMM-TFA">>, maps:get(payload, RestoredTransfer)).

m2pa_changeover_changeback_acknowledgements() ->
    {ok, _Pid} = telco_stp:add_link(#{
        name => chm_m2pa,
        linkset => chm_set,
        adaptation => m2pa,
        transport => telco_stp_transport_loopback,
        peer => self(),
        m2pa_proving_ms => 1,
        m2pa_alignment_timeout_ms => 1000,
        m2pa_t7_ms => 1000
    }),
    establish_m2pa(chm_m2pa),
    inject_m2pa_snmm(chm_m2pa, 0, #{type => coo, fsn => 16#55}),
    ?assertEqual(
        #{type => coa, fsn => 16#55},
        receive_m2pa_snmm(chm_m2pa)
    ),
    inject_m2pa_snmm(
        chm_m2pa, 1, #{type => cbd, changeback_code => 16#44}
    ),
    ?assertEqual(
        #{type => cba, changeback_code => 16#44},
        receive_m2pa_snmm(chm_m2pa)
    ),
    [Link] = [
        Item || Item <- telco_stp:links(),
                maps:get(name, Item) =:= chm_m2pa
    ],
    NetworkManagement = maps:get(
        network_management, maps:get(m2pa, Link)
    ),
    ?assertMatch(
        #{type := cbd, changeback_code := 16#44},
        maps:get(last_changeover, NetworkManagement)
    ),
    ?assertMatch(
        #{type := cba, changeback_code := 16#44},
        maps:get(last_changeover_ack_sent, NetworkManagement)
    ).

m2pa_changeover_retrieves_and_reroutes_unacked_msus() ->
    {ok, _Pid} = telco_stp:add_link(#{
        name => chm_primary,
        linkset => chm_primary_set,
        adaptation => m2pa,
        transport => telco_stp_transport_loopback,
        peer => self(),
        m2pa_proving_ms => 1,
        m2pa_alignment_timeout_ms => 1000,
        m2pa_t7_ms => 1000
    }),
    establish_m2pa(chm_primary),
    add_loopback(chm_secondary, chm_secondary_set, self()),
    ok = telco_stp:add_route(#{
        id => chm_retrieval_route,
        dpc => 7200,
        mask => 16#ffffff,
        linksets => [chm_primary_set, chm_secondary_set]
    }),
    ?assertMatch(
        {ok, #{link := chm_primary}},
        telco_stp:transfer(sample_transfer(7200, <<"CO-FIRST">>))
    ),
    {1, FirstBinary} = receive_m2pa_binary(chm_primary),
    {ok, #{type := user_data, fsn := 0}} =
        telco_stp_m2pa:decode(FirstBinary),
    ?assertMatch(
        {ok, #{link := chm_primary}},
        telco_stp:transfer(sample_transfer(7200, <<"CO-SECOND">>))
    ),
    {1, SecondBinary} = receive_m2pa_binary(chm_primary),
    {ok, #{type := user_data, fsn := 1}} =
        telco_stp_m2pa:decode(SecondBinary),
    inject_m2pa_snmm(chm_primary, 0, #{type => xco, fsn => 0}),
    ?assertEqual(#{type => xca, fsn => 0}, receive_m2pa_snmm(chm_primary)),
    ?assertEqual(
        <<"CO-SECOND">>,
        maps:get(payload, receive_protocol_data(chm_secondary))
    ),
    ?assertMatch(
        {ok, #{link := chm_secondary}},
        telco_stp:transfer(sample_transfer(7200, <<"CO-FUTURE">>))
    ),
    ?assertEqual(
        <<"CO-FUTURE">>,
        maps:get(payload, receive_protocol_data(chm_secondary))
    ),
    [Link] = [
        Item || Item <- telco_stp:links(),
                maps:get(name, Item) =:= chm_primary
    ],
    M2pa = maps:get(m2pa, Link),
    NetworkManagement = maps:get(network_management, M2pa),
    ?assertEqual(1, maps:get(unacked, M2pa)),
    ?assertMatch(
        #{type := xco, retrieved := 1, retrieved_fsns := [1]},
        maps:get(last_changeover, NetworkManagement)
    ),
    ?assertEqual(
        changeover, maps:get(changeover_state, NetworkManagement)
    ).

m2pa_changeback_restores_primary_traffic() ->
    {ok, _Pid} = telco_stp:add_link(#{
        name => cba_primary,
        linkset => cba_primary_set,
        adaptation => m2pa,
        transport => telco_stp_transport_loopback,
        peer => self(),
        m2pa_proving_ms => 1,
        m2pa_alignment_timeout_ms => 1000,
        m2pa_t7_ms => 1000
    }),
    establish_m2pa(cba_primary),
    add_loopback(cba_secondary, cba_secondary_set, self()),
    ok = telco_stp:add_route(#{
        id => cba_route,
        dpc => 7300,
        mask => 16#ffffff,
        linksets => [cba_primary_set, cba_secondary_set]
    }),
    inject_m2pa_snmm(cba_primary, 0, #{type => xco, fsn => 0}),
    ?assertEqual(#{type => xca, fsn => 0}, receive_m2pa_snmm(cba_primary)),
    ?assertMatch(
        {ok, #{link := cba_secondary}},
        telco_stp:transfer(sample_transfer(7300, <<"DURING-CHANGEOVER">>))
    ),
    ?assertEqual(
        <<"DURING-CHANGEOVER">>,
        maps:get(payload, receive_protocol_data(cba_secondary))
    ),
    inject_m2pa_snmm(
        cba_primary, 1, #{type => cbd, changeback_code => 16#31}
    ),
    ?assertEqual(
        #{type => cba, changeback_code => 16#31},
        receive_m2pa_snmm(cba_primary)
    ),
    ?assertMatch(
        {ok, #{link := cba_primary}},
        telco_stp:transfer(sample_transfer(7300, <<"AFTER-CHANGEBACK">>))
    ),
    RestoredTransfer = receive_m2pa_transfer(cba_primary),
    ?assertEqual(
        <<"AFTER-CHANGEBACK">>, maps:get(payload, RestoredTransfer)
    ),
    [Link] = [
        Item || Item <- telco_stp:links(),
                maps:get(name, Item) =:= cba_primary
    ],
    NetworkManagement = maps:get(
        network_management, maps:get(m2pa, Link)
    ),
    ?assertEqual(normal, maps:get(changeover_state, NetworkManagement)).

m2pa_emergency_changeover_reroutes_all_unacked_msus() ->
    {ok, _Pid} = telco_stp:add_link(#{
        name => eco_primary,
        linkset => eco_primary_set,
        adaptation => m2pa,
        transport => telco_stp_transport_loopback,
        peer => self(),
        m2pa_proving_ms => 1,
        m2pa_alignment_timeout_ms => 1000,
        m2pa_t7_ms => 1000
    }),
    establish_m2pa(eco_primary),
    add_loopback(eco_secondary, eco_secondary_set, self()),
    ok = telco_stp:add_route(#{
        id => eco_route,
        dpc => 7400,
        mask => 16#ffffff,
        linksets => [eco_primary_set, eco_secondary_set]
    }),
    ?assertMatch(
        {ok, #{link := eco_primary}},
        telco_stp:transfer(sample_transfer(7400, <<"ECO-FIRST">>))
    ),
    {1, FirstBinary} = receive_m2pa_binary(eco_primary),
    {ok, #{type := user_data, fsn := 0}} =
        telco_stp_m2pa:decode(FirstBinary),
    ?assertMatch(
        {ok, #{link := eco_primary}},
        telco_stp:transfer(sample_transfer(7400, <<"ECO-SECOND">>))
    ),
    {1, SecondBinary} = receive_m2pa_binary(eco_primary),
    {ok, #{type := user_data, fsn := 1}} =
        telco_stp_m2pa:decode(SecondBinary),
    inject_m2pa_snmm(eco_primary, 0, #{type => eco}),
    ?assertEqual(#{type => eca}, receive_m2pa_snmm(eco_primary)),
    Rerouted = lists:sort([
        maps:get(payload, receive_protocol_data(eco_secondary)),
        maps:get(payload, receive_protocol_data(eco_secondary))
    ]),
    ?assertEqual([<<"ECO-FIRST">>, <<"ECO-SECOND">>], Rerouted),
    ?assertMatch(
        {ok, #{link := eco_secondary}},
        telco_stp:transfer(sample_transfer(7400, <<"ECO-FUTURE">>))
    ),
    ?assertEqual(
        <<"ECO-FUTURE">>,
        maps:get(payload, receive_protocol_data(eco_secondary))
    ),
    [Link] = [
        Item || Item <- telco_stp:links(),
                maps:get(name, Item) =:= eco_primary
    ],
    M2pa = maps:get(m2pa, Link),
    NetworkManagement = maps:get(network_management, M2pa),
    ?assertEqual(1, maps:get(unacked, M2pa)),
    ?assertMatch(
        #{type := eco, retrieved := 2, retrieved_fsns := [0, 1]},
        maps:get(last_changeover, NetworkManagement)
    ),
    ?assertEqual(
        emergency_changeover,
        maps:get(changeover_state, NetworkManagement)
    ).

m2pa_link_inhibit_uninhibit_controls_route_selection() ->
    {ok, _Pid} = telco_stp:add_link(#{
        name => lim_primary,
        linkset => lim_primary_set,
        adaptation => m2pa,
        transport => telco_stp_transport_loopback,
        peer => self(),
        m2pa_proving_ms => 1,
        m2pa_alignment_timeout_ms => 1000,
        m2pa_t7_ms => 1000
    }),
    establish_m2pa(lim_primary),
    add_loopback(lim_secondary, lim_secondary_set, self()),
    ok = telco_stp:add_route(#{
        id => lim_route,
        dpc => 7500,
        mask => 16#ffffff,
        linksets => [lim_primary_set, lim_secondary_set]
    }),
    inject_m2pa_snmm(lim_primary, 0, #{type => lin}),
    ?assertEqual(#{type => lia}, receive_m2pa_snmm(lim_primary)),
    ?assertMatch(
        {ok, #{link := lim_secondary}},
        telco_stp:transfer(sample_transfer(7500, <<"INHIBITED">>))
    ),
    ?assertEqual(
        <<"INHIBITED">>,
        maps:get(payload, receive_protocol_data(lim_secondary))
    ),
    inject_m2pa_snmm(lim_primary, 1, #{type => lun}),
    ?assertEqual(#{type => lua}, receive_m2pa_snmm(lim_primary)),
    ?assertMatch(
        {ok, #{link := lim_primary}},
        telco_stp:transfer(sample_transfer(7500, <<"UNINHIBITED">>))
    ),
    RestoredTransfer = receive_m2pa_transfer(lim_primary),
    ?assertEqual(<<"UNINHIBITED">>, maps:get(payload, RestoredTransfer)),
    [Link] = [
        Item || Item <- telco_stp:links(),
                maps:get(name, Item) =:= lim_primary
    ],
    NetworkManagement = maps:get(
        network_management, maps:get(m2pa, Link)
    ),
    ?assertEqual(normal, maps:get(link_inhibit_state, NetworkManagement)).

m2pa_force_uninhibit_restores_route_selection() ->
    {ok, _Pid} = telco_stp:add_link(#{
        name => lfu_primary,
        linkset => lfu_primary_set,
        adaptation => m2pa,
        transport => telco_stp_transport_loopback,
        peer => self(),
        m2pa_proving_ms => 1,
        m2pa_alignment_timeout_ms => 1000,
        m2pa_t7_ms => 1000
    }),
    establish_m2pa(lfu_primary),
    add_loopback(lfu_secondary, lfu_secondary_set, self()),
    ok = telco_stp:add_route(#{
        id => lfu_route,
        dpc => 7600,
        mask => 16#ffffff,
        linksets => [lfu_primary_set, lfu_secondary_set]
    }),
    inject_m2pa_snmm(lfu_primary, 0, #{type => lin}),
    ?assertEqual(#{type => lia}, receive_m2pa_snmm(lfu_primary)),
    ?assertMatch(
        {ok, #{link := lfu_secondary}},
        telco_stp:transfer(sample_transfer(7600, <<"FORCED-AWAY">>))
    ),
    ?assertEqual(
        <<"FORCED-AWAY">>,
        maps:get(payload, receive_protocol_data(lfu_secondary))
    ),
    inject_m2pa_snmm(lfu_primary, 1, #{type => lfu}),
    ?assertMatch(
        {ok, #{link := lfu_primary}},
        telco_stp:transfer(sample_transfer(7600, <<"FORCED-BACK">>))
    ),
    RestoredTransfer = receive_m2pa_transfer(lfu_primary),
    ?assertEqual(<<"FORCED-BACK">>, maps:get(payload, RestoredTransfer)),
    [Link] = [
        Item || Item <- telco_stp:links(),
                maps:get(name, Item) =:= lfu_primary
    ],
    NetworkManagement = maps:get(
        network_management, maps:get(m2pa, Link)
    ),
    ?assertEqual(normal, maps:get(link_inhibit_state, NetworkManagement)).

itu_signalling_link_test_is_acknowledged_on_source_link() ->
    add_loopback(slt_peer, slt_set, self()),
    {ok, Sltm} = telco_stp_slt:encode(#{
        type => sltm,
        test_pattern => <<"operator-slt">>
    }),
    Request = (sample_transfer(222, Sltm))#{
        opc => 111,
        si => 1,
        sls => 9
    },
    {ok, M3ua} = telco_stp_m3ua:encode_data(Request),
    ok = telco_stp:inject_m3ua(slt_peer, M3ua),
    Response = receive_protocol_data(slt_peer),
    ?assertEqual(111, maps:get(dpc, Response)),
    ?assertEqual(222, maps:get(opc, Response)),
    ?assertEqual(1, maps:get(si, Response)),
    ?assertEqual(9, maps:get(sls, Response)),
    ?assertEqual(
        {ok, #{type => slta, test_pattern => <<"operator-slt">>}},
        telco_stp_slt:decode(maps:get(payload, Response))
    ).

authenticated_rbac_management_is_hash_chained() ->
    ViewerToken = <<"viewer-token-0123456789abcdef">>,
    EngineerToken = <<"engineer-token-0123456789abc">>,
    ok = application:set_env(
        telco_stp, management_credentials,
        [
            #{
                id => noc_viewer,
                token_sha256 => telco_stp_mgmt:hash_token(ViewerToken),
                roles => [viewer]
            },
            #{
                id => lab_engineer,
                token_sha256 =>
                    telco_stp_mgmt:hash_token(EngineerToken),
                roles => [engineer]
            }
        ]
    ),
    ok = telco_stp_mgmt:reload_credentials(),
    ?assertEqual(
        {error, unauthorized},
        telco_stp:management(
            <<"wrong-token-0123456789abcdef">>, status
        )
    ),
    ?assertMatch(
        #{application := telco_stp},
        telco_stp:management(ViewerToken, status)
    ),
    Route = #{
        id => rbac_route,
        dpc => 8888,
        mask => 16#ffffff,
        linksets => [rbac_set]
    },
    ?assertEqual(
        {error, forbidden},
        telco_stp:management(ViewerToken, {add_route, Route})
    ),
    ?assertEqual(
        ok,
        telco_stp:management(EngineerToken, {add_route, Route})
    ),
    ?assertEqual(
        ok,
        telco_stp:management(
            EngineerToken, {remove_route, rbac_route}
        )
    ),
    ?assertEqual(ok, telco_stp:verify_audit()),
    Events = telco_stp:audit_events(),
    ?assert(length(Events) >= 5),
    ?assert(lists:any(
        fun(Event) ->
            maps:get(actor, Event) =:= noc_viewer andalso
            maps:get(result, Event) =:= denied
        end,
        Events
    )).

durable_audit_chain_resumes_after_restart() ->
    Path = filename:join([
        "stp", "_build", "test", "durable-audit.bin"
    ]),
    _ = file:delete(Path),
    ok = application:set_env(telco_stp, audit_log_path, Path),
    Initial = whereis(telco_stp_audit),
    exit(Initial, kill),
    First = await_restarted_process(
        telco_stp_audit, Initial, 100
    ),
    {ok, #{sequence := 1}} = telco_stp_audit:record(
        test_operator, configure, route_a, success, #{}
    ),
    {ok, #{sequence := 2}} = telco_stp_audit:record(
        test_operator, operate, link_a, success, #{}
    ),
    exit(First, kill),
    _Second = await_restarted_process(
        telco_stp_audit, First, 100
    ),
    ?assertEqual(
        [1, 2],
        [
            maps:get(sequence, Event)
            || Event <- telco_stp:audit_events()
        ]
    ),
    ?assertEqual(ok, telco_stp:verify_audit()),
    {ok, #{sequence := 3}} = telco_stp_audit:record(
        test_operator, verify, audit_chain, success, #{}
    ),
    ok = application:set_env(
        telco_stp, audit_log_path, undefined
    ),
    ok = file:delete(Path).

observability_trace_and_pcapng_export() ->
    ok = telco_stp:set_trace(#{
        enabled => true,
        max_packets => 2,
        max_bytes => 1048576,
        capture_payload => true,
        header_bytes => 128
    }),
    add_loopback(trace_link, trace_set, self()),
    ok = telco_stp:add_route(#{
        id => trace_route,
        dpc => 8181,
        mask => 16#ffffff,
        linksets => [trace_set]
    }),
    ?assertMatch(
        {ok, #{link := trace_link}},
        telco_stp:transfer(sample_transfer(8181, <<"trace-one">>))
    ),
    _ = receive_protocol_data(trace_link),
    ?assertMatch(
        {ok, #{link := trace_link}},
        telco_stp:transfer(sample_transfer(8181, <<"trace-two">>))
    ),
    _ = receive_protocol_data(trace_link),
    ?assertMatch(
        {ok, #{link := trace_link}},
        telco_stp:transfer(sample_transfer(8181, <<"trace-three">>))
    ),
    _ = receive_protocol_data(trace_link),
    await_trace_packets(2, 100),
    TraceStatus = telco_stp:trace_status(),
    ?assertEqual(2, maps:get(packet_count, TraceStatus)),
    ?assert(maps:get(dropped, TraceStatus) >= 1),
    Prometheus = telco_stp:prometheus(),
    ?assertNotEqual(
        nomatch,
        binary:match(Prometheus, <<"telco_stp_build_info">>)
    ),
    ?assertNotEqual(
        nomatch,
        binary:match(Prometheus, <<"telco_stp_link_state">>)
    ),
    Health = telco_stp:health(),
    ?assertEqual(ok, maps:get(audit_chain, Health)),
    Path = filename:join([
        "stp", "_build", "test", "trace-export.pcapng"
    ]),
    _ = file:delete(Path),
    {ok, #{packets := 2}} = telco_stp:export_pcapng(Path),
    {ok, <<16#0a, 16#0d, 16#0d, 16#0a, _/binary>>} =
        file:read_file(Path),
    ok = file:delete(Path).

standalone_ha_snapshot_is_integrity_protected() ->
    ?assertMatch(
        #{mode := standalone, generation := 0},
        telco_stp:ha_status()
    ),
    {ok, #{
        snapshot := #{
            schema_version := 1,
            source_node := _,
            generation := 1,
            configuration := _
        },
        hmac_sha256 := Integrity
    }} = telco_stp:ha_snapshot(),
    ?assertEqual(32, byte_size(Integrity)),
    ?assertEqual(
        {error, {invalid_ha_mode, standalone}},
        telco_stp:promote_standby(
            <<"valid-length-fencing-token">>
        )
    ).

listener_peer_profiles_are_closed_by_default() ->
    Exact = #{
        id => exact_peer,
        remote_ip => {192, 0, 2, 10},
        remote_port => 2905,
        linkset => north
    },
    Fallback = #{
        id => lab_fallback,
        remote_ips => [{192, 0, 2, 20}, {192, 0, 2, 21}],
        linkset => lab
    },
    ?assertEqual(
        {ok, Exact},
        telco_stp_listener_manager:profile_for_peer(
            [Exact, Fallback], {192, 0, 2, 10}, 2905
        )
    ),
    ?assertEqual(
        {ok, Fallback},
        telco_stp_listener_manager:profile_for_peer(
            [Exact, Fallback], {192, 0, 2, 21}, 40000
        )
    ),
    ?assertEqual(
        {error, no_matching_peer_profile},
        telco_stp_listener_manager:profile_for_peer(
            [Exact, Fallback], {198, 51, 100, 1}, 2905
        )
    ).

overload_guard_sheds_and_recovers() ->
    ok = telco_stp:set_overload_limits(#{
        high_watermark => 0,
        low_watermark => 0
    }),
    ?assertEqual(
        {error, stp_overloaded},
        telco_stp:transfer(sample_transfer(60000, <<"shed">>))
    ),
    ?assert(lists:any(
        fun(Alarm) ->
            maps:get(id, Alarm) =:= {dispatcher, overload}
        end,
        telco_stp:alarms()
    )),
    ok = telco_stp:set_overload_limits(#{
        high_watermark => 100,
        low_watermark => 50
    }),
    ?assertEqual(
        {error, {no_route, 60000}},
        telco_stp:transfer(sample_transfer(60000, <<"accepted">>))
    ),
    ?assertEqual([], [
        Alarm || Alarm <- telco_stp:alarms(),
                 maps:get(id, Alarm) =:= {dispatcher, overload}
    ]).

alarms_acknowledge_and_clear_on_recovery() ->
    Dpc = 123321,
    ?assertEqual(
        {error, {no_route, Dpc}},
        telco_stp:transfer(sample_transfer(Dpc, <<"unrouted">>))
    ),
    AlarmId = {routing, Dpc},
    [Alarm] = [
        Item || Item <- telco_stp:alarms(),
                maps:get(id, Item) =:= AlarmId
    ],
    ?assertEqual(major, maps:get(severity, Alarm)),
    ok = telco_stp:acknowledge_alarm(AlarmId, <<"noc-operator">>),
    [Acknowledged] = [
        Item || Item <- telco_stp:alarms(),
                maps:get(id, Item) =:= AlarmId
    ],
    ?assertEqual(
        <<"noc-operator">>, maps:get(acknowledged_by, Acknowledged)
    ),
    add_loopback(alarm_link, alarm_set, self()),
    ok = telco_stp:add_route(#{
        id => alarm_route,
        dpc => Dpc,
        mask => 16#ffffff,
        linksets => [alarm_set]
    }),
    ?assertMatch(
        {ok, #{link := alarm_link}},
        telco_stp:transfer(sample_transfer(Dpc, <<"restored">>))
    ),
    _ = receive_protocol_data(alarm_link),
    ?assertEqual(
        [], [
            Item || Item <- telco_stp:alarms(),
                    maps:get(id, Item) =:= AlarmId
        ]
    ),
    ?assert(lists:any(
        fun(#{action := Action, alarm := Item}) ->
            Action =:= cleared andalso maps:get(id, Item) =:= AlarmId
        end,
        telco_stp:alarm_history()
    )).

configuration_replace_restores_runtime() ->
    add_loopback(persisted_link, persisted_set, undefined),
    ok = telco_stp:add_route(#{
        id => persisted_route,
        dpc => 31337,
        mask => 16#ffffff,
        linksets => [persisted_set]
    }),
    ok = telco_stp:add_gtt_rule(#{
        id => persisted_gtt,
        prefix => <<"441">>,
        dpc => 31337,
        ssn => 6
    }),
    Path = filename:join([
        "stp", "_build", "test", "operator-configuration.bin"
    ]),
    _ = file:delete(Path),
    {ok, Saved} = telco_stp:save_configuration(Path),
    ?assertEqual(1, maps:get(schema_version, Saved)),
    {ok, OriginalFile} = file:read_file(Path),
    PrefixLength = byte_size(OriginalFile) - 1,
    <<Prefix:PrefixLength/binary, Last:8>> = OriginalFile,
    ok = file:write_file(Path, <<Prefix/binary, (Last bxor 1):8>>),
    ?assertEqual(
        {error, configuration_checksum_mismatch},
        telco_stp:load_configuration(Path, merge)
    ),
    ok = file:write_file(Path, OriginalFile),
    ok = telco_stp:remove_link(persisted_link),
    ok = telco_stp:remove_route(persisted_route),
    ok = telco_stp:remove_gtt_rule(persisted_gtt),
    ok = telco_stp:add_route(#{
        id => unwanted_route,
        dpc => 1,
        mask => 16#ffffff,
        linksets => [unwanted_set]
    }),
    {ok, _Restored} = telco_stp:load_configuration(Path, replace),
    ?assert(lists:any(
        fun(#{name := Name}) -> Name =:= persisted_link end,
        telco_stp:links()
    )),
    ?assert(lists:any(
        fun(#{id := Id}) -> Id =:= persisted_route end,
        telco_stp:routes()
    )),
    ?assert(lists:any(
        fun(#{id := Id}) -> Id =:= persisted_gtt end,
        telco_stp:gtt_rules()
    )),
    ?assertNot(lists:any(
        fun(#{id := Id}) -> Id =:= unwanted_route end,
        telco_stp:routes()
    )),
    ok = file:delete(Path).

inject_ssnm(Link, Type, Params) ->
    {ok, Binary} = telco_stp_m3ua:encode(#{
        class => ssnm, type => Type, params => Params
    }),
    ok = telco_stp:inject_m3ua(Link, Binary).

inject_control(Link, Class, Type, Params) ->
    {ok, Binary} = telco_stp_m3ua:encode(#{
        class => Class, type => Type, params => Params
    }),
    ok = telco_stp:inject_m3ua(Link, Binary).

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

segmented_sccp(First, Remaining, Data) ->
    {ok, Binary} = telco_stp_sccp:encode(#{
        type => xudt,
        protocol_class => 1,
        hop_counter => 10,
        called_party => #{
            routing_indicator => ssn,
            point_code => 700,
            ssn => 6
        },
        calling_party => #{
            routing_indicator => ssn,
            point_code => 100,
            ssn => 8
        },
        data => Data,
        options => [{segmentation, #{
            first_segment => First,
            class => 1,
            remaining_segments => Remaining,
            local_reference => 16#123456
        }}]
    }),
    Binary.

ssn_sccp(PointCode, Ssn, Data) ->
    {ok, Binary} = telco_stp_sccp:encode(#{
        type => udt,
        protocol_class => 0,
        called_party => #{
            routing_indicator => ssn,
            point_code => PointCode,
            ssn => Ssn
        },
        calling_party => #{
            routing_indicator => ssn,
            point_code => 100,
            ssn => 8
        },
        data => Data
    }),
    Binary.

inject_scmg(Link, Type, AffectedPc, AffectedSsn, LocalPc) ->
    {ok, Management} = telco_stp_scmg:encode(#{
        type => Type,
        affected_ssn => AffectedSsn,
        affected_point_code => AffectedPc,
        multiplicity => 0
    }, itu),
    {ok, Sccp} = telco_stp_sccp:encode(#{
        type => udt,
        protocol_class => 0,
        called_party => #{
            routing_indicator => ssn,
            point_code => LocalPc,
            ssn => 1
        },
        calling_party => #{
            routing_indicator => ssn,
            point_code => AffectedPc,
            ssn => 1
        },
        data => Management
    }),
    {ok, M3ua} = telco_stp_m3ua:encode_data(
        (sample_transfer(LocalPc, Sccp))#{opc => AffectedPc}
    ),
    ok = telco_stp:inject_m3ua(Link, M3ua).

inject_m2pa_status(Link, Status, Stream) ->
    {ok, Binary} = telco_stp_m2pa:encode(#{
        type => link_status,
        bsn => 16#ffffff,
        fsn => 16#ffffff,
        status => Status,
        filler => <<>>
    }),
    ok = telco_stp:inject_m2pa(Link, Stream, Binary).

establish_m2pa(Link) ->
    {0, LocalAlignment} = receive_m2pa_binary(Link),
    {ok, #{status := alignment}} =
        telco_stp_m2pa:decode(LocalAlignment),
    inject_m2pa_status(Link, alignment, 0),
    {0, LocalProving} = receive_m2pa_binary(Link),
    {ok, #{status := proving_normal}} =
        telco_stp_m2pa:decode(LocalProving),
    inject_m2pa_status(Link, proving_normal, 0),
    {0, LocalReady} = receive_m2pa_binary(Link),
    {ok, #{status := ready}} = telco_stp_m2pa:decode(LocalReady),
    inject_m2pa_status(Link, ready, 0),
    {0, ReadyReply} = receive_m2pa_binary(Link),
    {ok, #{status := ready}} = telco_stp_m2pa:decode(ReadyReply),
    await_link_state(Link, active, 100).

inject_m2pa_snmm(Link, Fsn, Snmm) ->
    {ok, SnmmPayload} = telco_stp_snmm:encode(itu, Snmm),
    {ok, Mtp3} = telco_stp_mtp3:encode(
        itu,
        (sample_transfer(1, SnmmPayload))#{si => 0}
    ),
    {ok, M2pa} = telco_stp_m2pa:encode(#{
        type => user_data,
        bsn => 16#ffffff,
        fsn => Fsn,
        priority => 0,
        mtp3 => Mtp3
    }),
    ok = telco_stp:inject_m2pa(Link, 1, M2pa).

receive_m2pa_snmm(Link) ->
    receive_m2pa_snmm(Link, 5).

receive_m2pa_transfer(Link) ->
    receive_m2pa_transfer(Link, 5).

receive_m2pa_transfer(Link, Attempts) when Attempts > 0 ->
    {1, Binary} = receive_m2pa_binary(Link),
    {ok, #{type := user_data, mtp3 := Mtp3}} =
        telco_stp_m2pa:decode(Binary),
    case Mtp3 of
        <<>> ->
            receive_m2pa_transfer(Link, Attempts - 1);
        _ ->
            {ok, Transfer} = telco_stp_mtp3:decode(itu, Mtp3),
            Transfer
    end;
receive_m2pa_transfer(Link, 0) ->
    error({m2pa_transfer_receive_timeout, Link}).

receive_m2pa_snmm(Link, Attempts) when Attempts > 0 ->
    {1, Binary} = receive_m2pa_binary(Link),
    {ok, #{type := user_data, mtp3 := Mtp3}} =
        telco_stp_m2pa:decode(Binary),
    case Mtp3 of
        <<>> ->
            receive_m2pa_snmm(Link, Attempts - 1);
        _ ->
            {ok, Transfer} = telco_stp_mtp3:decode(itu, Mtp3),
            ?assertEqual(0, maps:get(si, Transfer)),
            {ok, Snmm} = telco_stp_snmm:decode(
                itu, maps:get(payload, Transfer)
            ),
            Snmm
    end;
receive_m2pa_snmm(Link, 0) ->
    error({m2pa_snmm_receive_timeout, Link}).

collect_ssnm(_Link, 0, Acc) ->
    lists:reverse(Acc);
collect_ssnm(Link, Count, Acc) ->
    receive
        {m3ua, Link, Binary} ->
            {ok, Message} = telco_stp_m3ua:decode(Binary),
            Type = maps:get(type, Message),
            Affected = maps:get(
                affected_point_code, maps:get(params, Message)
            ),
            collect_ssnm(Link, Count - 1, [{Type, Affected} | Acc])
    after 1000 ->
        error({ssnm_receive_timeout, Link, Count})
    end.

await_notification(Name, Meaning, Attempts) when Attempts > 0 ->
    case [
        maps:get(management_notification, Link)
        || Link <- telco_stp:links(),
           maps:get(name, Link) =:= Name
    ] of
        [#{meaning := Meaning}] ->
            ok;
        _ ->
            receive after 10 -> ok end,
            await_notification(Name, Meaning, Attempts - 1)
    end;
await_notification(Name, Meaning, 0) ->
    error({notification_timeout, Name, Meaning}).

await_destination_status(Link, Dpc, Status, Attempts)
        when Attempts > 0 ->
    case lists:any(
        fun(State) ->
            maps:get(source_link, State) =:= Link andalso
            maps:get(dpc, State) =:= Dpc andalso
            maps:get(status, State) =:= Status
        end,
        telco_stp:destination_states()
    ) of
        true ->
            ok;
        false ->
            receive after 10 -> ok end,
            await_destination_status(Link, Dpc, Status, Attempts - 1)
    end;
await_destination_status(Link, Dpc, Status, 0) ->
    error({destination_state_timeout, Link, Dpc, Status}).

await_no_destination_status(Link, Dpc, Attempts) when Attempts > 0 ->
    case lists:any(
        fun(State) ->
            maps:get(source_link, State) =:= Link andalso
            maps:get(dpc, State) =:= Dpc
        end,
        telco_stp:destination_states()
    ) of
        false ->
            ok;
        true ->
            receive after 10 -> ok end,
            await_no_destination_status(Link, Dpc, Attempts - 1)
    end;
await_no_destination_status(Link, Dpc, 0) ->
    error({destination_state_clear_timeout, Link, Dpc}).

await_heartbeat_ack(Name, Attempts) when Attempts > 0 ->
    case [
        maps:get(heartbeat, Link)
        || Link <- telco_stp:links(),
           maps:get(name, Link) =:= Name
    ] of
        [#{pending := false, last_acknowledged_at := Timestamp}]
                when is_integer(Timestamp) ->
            ok;
        _ ->
            receive after 10 -> ok end,
            await_heartbeat_ack(Name, Attempts - 1)
    end;
await_heartbeat_ack(Name, 0) ->
    error({heartbeat_ack_timeout, Name, telco_stp:links()}).

await_subsystem_status(Link, Pc, Ssn, Status, Attempts)
        when Attempts > 0 ->
    case lists:any(
        fun(State) ->
            maps:get(source_link, State) =:= Link andalso
            maps:get(point_code, State) =:= Pc andalso
            maps:get(ssn, State) =:= Ssn andalso
            maps:get(status, State) =:= Status
        end,
        telco_stp:subsystem_states()
    ) of
        true ->
            ok;
        false ->
            receive after 10 -> ok end,
            await_subsystem_status(
                Link, Pc, Ssn, Status, Attempts - 1
            )
    end;
await_subsystem_status(Link, Pc, Ssn, Status, 0) ->
    error({subsystem_state_timeout, Link, Pc, Ssn, Status}).

await_trace_packets(Expected, Attempts) when Attempts > 0 ->
    case maps:get(packet_count, telco_stp:trace_status()) of
        Expected ->
            ok;
        _ ->
            receive after 10 -> ok end,
            await_trace_packets(Expected, Attempts - 1)
    end;
await_trace_packets(Expected, 0) ->
    error({
        trace_packet_timeout, Expected, telco_stp:trace_status()
    }).

await_restarted_process(Name, Previous, Attempts)
        when Attempts > 0 ->
    case whereis(Name) of
        Pid when is_pid(Pid), Pid =/= Previous ->
            Pid;
        _ ->
            receive after 10 -> ok end,
            await_restarted_process(Name, Previous, Attempts - 1)
    end;
await_restarted_process(Name, Previous, 0) ->
    error({process_restart_timeout, Name, Previous}).

flush_mailbox() ->
    receive
        _ -> flush_mailbox()
    after 0 ->
        ok
    end.
