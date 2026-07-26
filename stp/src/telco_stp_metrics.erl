-module(telco_stp_metrics).
-behaviour(gen_server).

-export([start_link/0, increment/1, add/2, snapshot/0, reset/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(TABLE, telco_stp_metrics_table).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

increment(Key) ->
    add(Key, 1).

add(Key, Value) when is_integer(Value) ->
    try
        _ = ets:update_counter(?TABLE, Key, {2, Value}, {Key, 0}),
        ok
    catch
        error:badarg ->
            {error, metrics_not_started}
    end.

snapshot() ->
    maps:from_list(ets:tab2list(?TABLE)).

reset() ->
    gen_server:call(?MODULE, reset).

init([]) ->
    _ = ets:new(?TABLE, [
        named_table,
        public,
        set,
        {read_concurrency, true},
        {write_concurrency, true}
    ]),
    {ok, #{started_at => erlang:system_time(millisecond)}}.

handle_call(reset, _From, State) ->
    true = ets:delete_all_objects(?TABLE),
    {reply, ok, State};
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported}, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

