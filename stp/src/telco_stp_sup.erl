-module(telco_stp_sup).
-behaviour(supervisor).

-include("telco_stp.hrl").

-export([start_link/0]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    SupFlags = #{
        strategy => rest_for_one,
        intensity => 10,
        period => 30
    },
    Children = [
        worker(telco_stp_metrics),
        worker(telco_stp_alarm),
        worker(telco_stp_audit),
        worker(telco_stp_mgmt),
        worker(telco_stp_trace),
        #{
            id => telco_stp_link_sup,
            start => {telco_stp_link_sup, start_link, []},
            restart => permanent,
            shutdown => infinity,
            type => supervisor,
            modules => [telco_stp_link_sup]
        },
        worker(telco_stp_link_manager),
        worker(telco_stp_route_table),
        worker(telco_stp_rkm),
        worker(telco_stp_gtt),
        worker(telco_stp_reassembly),
        worker(telco_stp_scmg),
        worker(telco_stp_listener_manager),
        worker(telco_stp_dispatcher),
        worker(telco_stp_ha),
        worker(telco_stp_bootstrap, transient)
    ],
    {ok, {SupFlags, Children}}.

worker(Module) ->
    worker(Module, permanent).

worker(Module, Restart) ->
    #{
        id => Module,
        start => {Module, start_link, []},
        restart => Restart,
        shutdown => ?STP_DEFAULT_SUPERVISOR_SHUTDOWN_MS,
        type => worker,
        modules => [Module]
    }.
