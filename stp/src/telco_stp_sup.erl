-module(telco_stp_sup).
-behaviour(supervisor).

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
        #{
            id => telco_stp_metrics,
            start => {telco_stp_metrics, start_link, []},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [telco_stp_metrics]
        },
        #{
            id => telco_stp_alarm,
            start => {telco_stp_alarm, start_link, []},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [telco_stp_alarm]
        },
        #{
            id => telco_stp_audit,
            start => {telco_stp_audit, start_link, []},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [telco_stp_audit]
        },
        #{
            id => telco_stp_mgmt,
            start => {telco_stp_mgmt, start_link, []},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [telco_stp_mgmt]
        },
        #{
            id => telco_stp_trace,
            start => {telco_stp_trace, start_link, []},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [telco_stp_trace]
        },
        #{
            id => telco_stp_link_sup,
            start => {telco_stp_link_sup, start_link, []},
            restart => permanent,
            shutdown => infinity,
            type => supervisor,
            modules => [telco_stp_link_sup]
        },
        #{
            id => telco_stp_link_manager,
            start => {telco_stp_link_manager, start_link, []},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [telco_stp_link_manager]
        },
        #{
            id => telco_stp_route_table,
            start => {telco_stp_route_table, start_link, []},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [telco_stp_route_table]
        },
        #{
            id => telco_stp_rkm,
            start => {telco_stp_rkm, start_link, []},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [telco_stp_rkm]
        },
        #{
            id => telco_stp_gtt,
            start => {telco_stp_gtt, start_link, []},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [telco_stp_gtt]
        },
        #{
            id => telco_stp_reassembly,
            start => {telco_stp_reassembly, start_link, []},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [telco_stp_reassembly]
        },
        #{
            id => telco_stp_scmg,
            start => {telco_stp_scmg, start_link, []},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [telco_stp_scmg]
        },
        #{
            id => telco_stp_listener_manager,
            start => {telco_stp_listener_manager, start_link, []},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [telco_stp_listener_manager]
        },
        #{
            id => telco_stp_dispatcher,
            start => {telco_stp_dispatcher, start_link, []},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [telco_stp_dispatcher]
        },
        #{
            id => telco_stp_ha,
            start => {telco_stp_ha, start_link, []},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [telco_stp_ha]
        },
        #{
            id => telco_stp_bootstrap,
            start => {telco_stp_bootstrap, start_link, []},
            restart => transient,
            shutdown => 5000,
            type => worker,
            modules => [telco_stp_bootstrap]
        }
    ],
    {ok, {SupFlags, Children}}.
