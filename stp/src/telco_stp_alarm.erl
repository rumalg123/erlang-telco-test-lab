-module(telco_stp_alarm).
-behaviour(gen_server).

-include("telco_stp.hrl").

-export([
    start_link/0,
    raise/3,
    clear/2,
    acknowledge/2,
    active/0,
    history/0,
    subscribe/1
]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

raise(Id, Severity, Details) ->
    gen_server:cast(?MODULE, {raise, Id, Severity, Details}).

clear(Id, Details) ->
    gen_server:cast(?MODULE, {clear, Id, Details}).

acknowledge(Id, Operator) ->
    gen_server:call(?MODULE, {acknowledge, Id, Operator}).

active() ->
    gen_server:call(?MODULE, active).

history() ->
    gen_server:call(?MODULE, history).

subscribe(Pid) when is_pid(Pid) ->
    gen_server:call(?MODULE, {subscribe, Pid}).

init([]) ->
    {ok, #{
        active => #{},
        history => [],
        subscribers => #{},
        history_limit => application:get_env(
            ?STP_APP, ?STP_ENV_ALARM_HISTORY_LIMIT,
            ?STP_DEFAULT_ALARM_LIMIT
        ),
        active_limit => application:get_env(
            ?STP_APP, ?STP_ENV_ACTIVE_ALARM_LIMIT,
            ?STP_DEFAULT_ALARM_LIMIT
        )
    }}.

handle_call(active, _From, State) ->
    {reply, sort_alarms(maps:values(maps:get(active, State))), State};
handle_call(history, _From, State) ->
    {reply, lists:reverse(maps:get(history, State)), State};
handle_call({acknowledge, Id, Operator}, _From, State) ->
    Active = maps:get(active, State),
    case maps:find(Id, Active) of
        {ok, Alarm} ->
            Updated = Alarm#{
                acknowledged_by => Operator,
                acknowledged_at => erlang:system_time(millisecond)
            },
            Event = event(acknowledged, Updated, #{}),
            NewState = record_event(
                Event, State#{active => Active#{Id => Updated}}
            ),
            notify(Event, NewState),
            {reply, ok, NewState};
        error ->
            {reply, {error, {alarm_not_found, Id}}, State}
    end;
handle_call({subscribe, Pid}, _From, State) ->
    Ref = erlang:monitor(process, Pid),
    Subscribers = maps:get(subscribers, State),
    {reply, {ok, Ref}, State#{
        subscribers => Subscribers#{Ref => Pid}
    }};
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported}, State}.

handle_cast({raise, Id, Severity, Details}, State) ->
    case valid_severity(Severity) andalso is_map(Details) of
        true ->
            Now = erlang:system_time(millisecond),
            Active = maps:get(active, State),
            Alarm =
                case maps:find(Id, Active) of
                    {ok, Existing} ->
                        Existing#{
                            severity => Severity,
                            details => Details,
                            last_seen => Now,
                            occurrences => maps:get(
                                occurrences, Existing, 1
                            ) + 1
                        };
                    error ->
                        #{
                            id => Id,
                            severity => Severity,
                            details => Details,
                            raised_at => Now,
                            last_seen => Now,
                            occurrences => 1,
                            acknowledged_by => undefined
                        }
                end,
            LimitedActive = limit_active(
                Active#{Id => Alarm}, maps:get(active_limit, State)
            ),
            Event = event(raised, Alarm, Details),
            NewState = record_event(
                Event, State#{active => LimitedActive}
            ),
            notify(Event, NewState),
            {noreply, NewState};
        false ->
            {noreply, State}
    end;
handle_cast({clear, Id, Details}, State) when is_map(Details) ->
    Active = maps:get(active, State),
    case maps:take(Id, Active) of
        {Alarm, Remaining} ->
            Event = event(cleared, Alarm, Details),
            NewState = record_event(
                Event, State#{active => Remaining}
            ),
            notify(Event, NewState),
            {noreply, NewState};
        error ->
            {noreply, State}
    end;
handle_cast(_Request, State) ->
    {noreply, State}.

handle_info({'DOWN', Ref, process, _Pid, _Reason}, State) ->
    Subscribers = maps:get(subscribers, State),
    {noreply, State#{subscribers => maps:remove(Ref, Subscribers)}};
handle_info(_Info, State) ->
    {noreply, State}.

event(Action, Alarm, Details) ->
    #{
        action => Action,
        alarm => Alarm,
        details => Details,
        timestamp => erlang:system_time(millisecond)
    }.

record_event(Event, State) ->
    History0 = [Event | maps:get(history, State)],
    Limit = maps:get(history_limit, State),
    History = lists:sublist(History0, min(Limit, length(History0))),
    State#{history => History}.

notify(Event, State) ->
    lists:foreach(
        fun(Pid) -> Pid ! {stp_alarm, Event} end,
        maps:values(maps:get(subscribers, State))
    ).

limit_active(Active, Limit) when map_size(Active) =< Limit ->
    Active;
limit_active(Active, Limit) ->
    Sorted = lists:sort(
        fun(A, B) -> maps:get(last_seen, A) > maps:get(last_seen, B) end,
        maps:values(Active)
    ),
    maps:from_list([
        {maps:get(id, Alarm), Alarm}
        || Alarm <- lists:sublist(Sorted, Limit)
    ]).

sort_alarms(Alarms) ->
    lists:sort(
        fun(A, B) ->
            {severity_rank(maps:get(severity, A)), maps:get(raised_at, A)}
            =<
            {severity_rank(maps:get(severity, B)), maps:get(raised_at, B)}
        end,
        Alarms
    ).

valid_severity(critical) -> true;
valid_severity(major) -> true;
valid_severity(minor) -> true;
valid_severity(warning) -> true;
valid_severity(info) -> true;
valid_severity(_Severity) -> false.

severity_rank(critical) -> 0;
severity_rank(major) -> 1;
severity_rank(minor) -> 2;
severity_rank(warning) -> 3;
severity_rank(info) -> 4.

