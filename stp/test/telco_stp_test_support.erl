-module(telco_stp_test_support).

-include("telco_stp.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([
    add_m2pa_loopback/2,
    add_m2pa_loopback/3,
    add_static_route/3,
    add_static_route/4,
    add_loopback/2,
    add_loopback/3,
    add_loopback/4,
    await_link_state/3,
    await_process_exit/2,
    receive_data/2,
    receive_m2pa_binary/1,
    receive_m3ua_message/1,
    receive_protocol_data/1,
    sample_transfer/2
]).

add_m2pa_loopback(Name, Linkset) ->
    add_m2pa_loopback(Name, Linkset, #{}).

add_m2pa_loopback(Name, Linkset, ExtraConfig) ->
    Config = maps:merge(#{
        name => Name,
        linkset => Linkset,
        adaptation => m2pa,
        transport => telco_stp_transport_loopback,
        peer => self(),
        m2pa_proving_ms => 1,
        m2pa_alignment_timeout_ms => 1000,
        m2pa_t7_ms => 1000
    }, ExtraConfig),
    telco_stp:add_link(Config).

add_static_route(Id, Dpc, Linksets) ->
    add_static_route(Id, Dpc, Linksets, #{}).

add_static_route(Id, Dpc, Linksets, ExtraRoute) ->
    telco_stp:add_route(maps:merge(#{
        id => Id,
        dpc => Dpc,
        mask => ?STP_POINT_CODE_MASK_24,
        linksets => Linksets
    }, ExtraRoute)).

add_loopback(Name, Linkset) ->
    add_loopback(Name, Linkset, self(), true, 50).

add_loopback(Name, Linkset, Peer) ->
    add_loopback(Name, Linkset, Peer, true).

add_loopback(Name, Linkset, Peer, AutoActivate) ->
    add_loopback(Name, Linkset, Peer, AutoActivate, 100).

add_loopback(Name, Linkset, Peer, AutoActivate, StateAttempts) ->
    Base = #{
        name => Name,
        linkset => Linkset,
        transport => telco_stp_transport_loopback,
        auto_activate => AutoActivate
    },
    Config =
        case Peer of
            undefined -> Base;
            _ -> Base#{peer => Peer}
    end,
    {ok, _Pid} = telco_stp:add_link(Config),
    await_link_state(
        Name, expected_link_state(AutoActivate), StateAttempts
    ).

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
    ProtocolData = receive_protocol_data(Link),
    ?assertEqual(ExpectedPayload, maps:get(payload, ProtocolData)).

receive_protocol_data(Link) ->
    Message = receive_m3ua_message(Link),
    maps:get(protocol_data, maps:get(params, Message)).

receive_m3ua_message(Link) ->
    receive
        {m3ua, Link, Binary} ->
            {ok, Message} = telco_stp_m3ua:decode(Binary),
            Message
    after 1000 ->
        error({m3ua_receive_timeout, Link})
    end.

receive_m2pa_binary(Link) ->
    receive
        {m2pa, Link, Stream, Binary} ->
            {Stream, Binary}
    after 1000 ->
        error({m2pa_receive_timeout, Link})
    end.

await_link_state(Name, Expected, Attempts) when Attempts > 0 ->
    case [
        maps:get(state, Link)
        || Link <- telco_stp:links(),
           maps:get(name, Link) =:= Name
    ] of
        [Expected] ->
            ok;
        _ ->
            receive after 10 -> ok end,
            await_link_state(Name, Expected, Attempts - 1)
    end;
await_link_state(Name, Expected, 0) ->
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

expected_link_state(true) ->
    active;
expected_link_state(false) ->
    down.
