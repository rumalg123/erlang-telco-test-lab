-module(telco_stp_integration_tests).

-include_lib("eunit/include/eunit.hrl").

stp_integration_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     [
        fun active_standby_failover/0,
        fun ingress_excludes_source_link/0,
        fun asp_server_state_machine/0,
        fun supervised_link_restart/0,
        fun load_generator_smoke/0,
        fun deterministic_fault_drop/0
     ]}.

setup() ->
    ok = application:load(telco_stp),
    ok = application:set_env(telco_stp, links, []),
    ok = application:set_env(telco_stp, routes, []),
    ok = application:set_env(telco_stp, fault_profile, #{}),
    {ok, _} = application:ensure_all_started(telco_stp),
    ok.

cleanup(_State) ->
    ok = application:stop(telco_stp),
    ok = application:unload(telco_stp).

active_standby_failover() ->
    add_loopback(primary_link, primary_set),
    add_loopback(secondary_link, secondary_set),
    ok = telco_stp:add_route(#{
        id => failover_route,
        dpc => 4242,
        mask => 16#ffffff,
        priority => 10,
        linksets => [primary_set, secondary_set]
    }),
    Transfer = sample_transfer(4242, <<"first">>),
    ?assertMatch(
        {ok, #{link := primary_link, route := failover_route}},
        telco_stp:transfer(Transfer)
    ),
    receive_data(primary_link, <<"first">>),
    ok = telco_stp:set_link_state(primary_link, inactive),
    ?assertMatch(
        {ok, #{link := secondary_link, route := failover_route}},
        telco_stp:transfer(Transfer#{payload => <<"failover">>})
    ),
    receive_data(secondary_link, <<"failover">>).

ingress_excludes_source_link() ->
    add_loopback(ingress_link, ingress_set),
    add_loopback(egress_link, egress_set),
    ok = telco_stp:add_route(#{
        id => ingress_route,
        dpc => 5252,
        mask => 16#ffffff,
        linksets => [ingress_set, egress_set]
    }),
    {ok, Binary} = telco_stp_m3ua:encode_data(
        sample_transfer(5252, <<"from-peer">>)
    ),
    ok = telco_stp:inject_m3ua(ingress_link, Binary),
    receive_data(egress_link, <<"from-peer">>).

asp_server_state_machine() ->
    {ok, _Pid} = telco_stp:add_link(#{
        name => managed_asp,
        linkset => managed_set,
        transport => telco_stp_transport_loopback,
        peer => self(),
        role => sg,
        auto_activate => false
    }),
    await_state(managed_asp, down, 50),
    {ok, AspUp} = telco_stp_m3ua:encode(#{
        class => aspsm, type => asp_up
    }),
    ok = telco_stp:inject_m3ua(managed_asp, AspUp),
    receive
        {m3ua, managed_asp, AspUpAck} ->
            {ok, #{type := asp_up_ack}} =
                telco_stp_m3ua:decode(AspUpAck)
    after 1000 ->
        error(asp_up_ack_timeout)
    end,
    await_state(managed_asp, inactive, 50),
    {ok, AspActive} = telco_stp_m3ua:encode(#{
        class => asptm,
        type => asp_active,
        params => #{traffic_mode_type => loadshare}
    }),
    ok = telco_stp:inject_m3ua(managed_asp, AspActive),
    receive
        {m3ua, managed_asp, AspActiveAck} ->
            {ok, #{type := asp_active_ack}} =
                telco_stp_m3ua:decode(AspActiveAck)
    after 1000 ->
        error(asp_active_ack_timeout)
    end,
    await_state(managed_asp, active, 50).

supervised_link_restart() ->
    {ok, Pid} = telco_stp:add_link(#{
        name => restartable_link,
        linkset => restartable_set,
        transport => telco_stp_transport_loopback,
        peer => self(),
        auto_activate => true
    }),
    await_state(restartable_link, active, 50),
    exit(Pid, kill),
    await_process_exit(Pid, 50),
    await_state(restartable_link, active, 100).

load_generator_smoke() ->
    {ok, _Pid} = telco_stp:add_link(#{
        name => load_link,
        linkset => load_set,
        transport => telco_stp_transport_loopback,
        auto_activate => true
    }),
    await_state(load_link, active, 50),
    ok = telco_stp:add_route(#{
        id => load_route,
        dpc => 6262,
        mask => 16#ffffff,
        linksets => [load_set]
    }),
    {ok, Report} = telco_stp:load(
        sample_transfer(6262, <<"load">>), 40, 4
    ),
    ?assertEqual(40, maps:get(requested, Report)),
    ?assertEqual(40, maps:get(succeeded, Report)),
    ?assertEqual(0, maps:get(failed, Report)),
    ?assert(maps:get(throughput_per_second, Report) > 0).

deterministic_fault_drop() ->
    ok = telco_stp:set_fault_profile(#{
        drop_percent => 100,
        duplicate_percent => 0,
        delay_ms => 0
    }),
    ?assertEqual(
        {ok, #{disposition => dropped_by_fault_profile}},
        telco_stp:transfer(sample_transfer(4242, <<"drop-me">>))
    ),
    receive
        {m3ua, _Link, _Binary} ->
            error(unexpected_message_under_total_drop)
    after 50 ->
        ok
    end,
    ok = telco_stp:set_fault_profile(#{}).

add_loopback(Name, Linkset) ->
    {ok, _Pid} = telco_stp:add_link(#{
        name => Name,
        linkset => Linkset,
        transport => telco_stp_transport_loopback,
        peer => self(),
        auto_activate => true
    }),
    await_state(Name, active, 50).

sample_transfer(Dpc, Payload) ->
    #{
        opc => 100,
        dpc => Dpc,
        si => 3,
        ni => 2,
        mp => 0,
        sls => 7,
        payload => Payload
    }.

receive_data(Link, ExpectedPayload) ->
    receive
        {m3ua, Link, Binary} ->
            {ok, Message} = telco_stp_m3ua:decode(Binary),
            Params = maps:get(params, Message),
            ProtocolData = maps:get(protocol_data, Params),
            ?assertEqual(ExpectedPayload, maps:get(payload, ProtocolData))
    after 1000 ->
        error({m3ua_receive_timeout, Link})
    end.

await_state(Name, Expected, Attempts) when Attempts > 0 ->
    case [
        maps:get(state, Link)
        || Link <- telco_stp:links(),
           maps:get(name, Link) =:= Name
    ] of
        [Expected] ->
            ok;
        _ ->
            receive after 10 -> ok end,
            await_state(Name, Expected, Attempts - 1)
    end;
await_state(Name, Expected, 0) ->
    error({link_state_timeout, Name, Expected, telco_stp:links()}).

await_process_exit(Pid, Attempts) when Attempts > 0 ->
    case is_process_alive(Pid) of
        false ->
            ok;
        true ->
            receive after 10 -> ok end,
            await_process_exit(Pid, Attempts - 1)
    end;
await_process_exit(Pid, 0) ->
    error({process_exit_timeout, Pid}).
