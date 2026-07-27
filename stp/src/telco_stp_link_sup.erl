-module(telco_stp_link_sup).
-behaviour(supervisor).

-include("telco_stp.hrl").

-export([start_link/0, start_link_instance/2, stop_link_instance/1]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

start_link_instance(Name, Config) ->
    ChildSpec = #{
        id => {stp_link, Name},
        start => {telco_stp_link, start_link, [Name, Config]},
        restart => temporary,
        shutdown => ?STP_DEFAULT_SUPERVISOR_SHUTDOWN_MS,
        type => worker,
        modules => [telco_stp_link]
    },
    supervisor:start_child(?MODULE, ChildSpec).

stop_link_instance(Name) ->
    ChildId = {stp_link, Name},
    case supervisor:terminate_child(?MODULE, ChildId) of
        ok ->
            supervisor:delete_child(?MODULE, ChildId);
        {error, not_found} ->
            {error, not_found};
        Error ->
            Error
    end.

init([]) ->
    {ok, {#{
        strategy => one_for_one,
        intensity => 20,
        period => 30
    }, []}}.
