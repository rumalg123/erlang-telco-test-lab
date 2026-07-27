-module(telco_stp_bootstrap).
-behaviour(gen_server).

-include("telco_stp.hrl").

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

start_link() ->
    gen_server:start_link(?MODULE, [], []).

init([]) ->
    Links = application:get_env(?STP_APP, ?STP_ENV_LINKS, []),
    Routes = application:get_env(?STP_APP, ?STP_ENV_ROUTES, []),
    GttRules = application:get_env(?STP_APP, ?STP_ENV_GTT_RULES, []),
    Listeners = application:get_env(?STP_APP, ?STP_ENV_LISTENERS, []),
    Faults = application:get_env(?STP_APP, ?STP_ENV_FAULT_PROFILE, #{}),
    ok = load_links(Links),
    ok = load_routes(Routes),
    ok = load_gtt_rules(GttRules),
    ok = load_listeners(Listeners),
    ok = load_faults(Faults),
    {ok, #{loaded => true}}.

handle_call(_Request, _From, State) ->
    {reply, {error, unsupported}, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

load_links(Links) ->
    lists:foreach(
        fun(Link) ->
            case telco_stp_link_manager:add(Link) of
                {ok, _Pid} -> ok;
                {error, {already_exists, _}} -> ok;
                {error, Reason} -> error({invalid_bootstrap_link, Link, Reason})
            end
        end,
        Links
    ).

load_routes(Routes) ->
    lists:foreach(
        fun(Route) ->
            case telco_stp_route_table:add(Route) of
                ok -> ok;
                {error, Reason} -> error({invalid_bootstrap_route, Route, Reason})
            end
        end,
        Routes
    ).

load_gtt_rules(Rules) ->
    lists:foreach(
        fun(Rule) ->
            case telco_stp_gtt:add(Rule) of
                ok -> ok;
                {error, {already_exists, _}} -> ok;
                {error, Reason} -> error({invalid_bootstrap_gtt_rule, Rule, Reason})
            end
        end,
        Rules
    ).

load_listeners(Listeners) ->
    lists:foreach(
        fun(Listener) ->
            case telco_stp_listener_manager:add(Listener) of
                {ok, _Status} -> ok;
                {error, {already_exists, _}} -> ok;
                {error, Reason} ->
                    error({invalid_bootstrap_listener, Listener, Reason})
            end
        end,
        Listeners
    ).

load_faults(Faults) ->
    case telco_stp_dispatcher:set_fault_profile(Faults) of
        ok -> ok;
        {error, Reason} -> error({invalid_bootstrap_fault_profile, Faults, Reason})
    end.
