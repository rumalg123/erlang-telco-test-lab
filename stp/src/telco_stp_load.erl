-module(telco_stp_load).

-include("telco_stp.hrl").

-export([run/3]).

-spec run(map(), pos_integer(), pos_integer()) ->
    {ok, map()} | {error, term()}.
run(Template, Count, Concurrency)
        when is_map(Template), is_integer(Count), Count > 0,
             is_integer(Concurrency), Concurrency > 0,
             Concurrency =< ?STP_MAX_LOAD_CONCURRENCY ->
    Workers = min(Count, Concurrency),
    Ref = make_ref(),
    Parent = self(),
    Started = erlang:monotonic_time(microsecond),
    Assignments = assignments(Count, Workers),
    _Pids = [
        spawn(fun() ->
            Result =
                try
                    {ok, worker(Template, Offset, WorkerCount)}
                catch
                    Class:Reason:Stacktrace ->
                        {error, {Class, Reason, Stacktrace}}
                end,
            Parent ! {load_result, Ref, Result}
        end)
        || {Offset, WorkerCount} <- Assignments
    ],
    case collect(Ref, Workers, empty_stats()) of
        {ok, Stats} ->
            DurationUs = max(
                1, erlang:monotonic_time(microsecond) - Started
            ),
            {ok, report(Count, Workers, DurationUs, Stats)};
        Error ->
            Error
    end;
run(_Template, Count, Concurrency) ->
    {error, {invalid_load_arguments, Count, Concurrency}}.

assignments(Count, Workers) ->
    Base = Count div Workers,
    Extra = Count rem Workers,
    assignment_loop(1, Workers, Base, Extra, 0, []).

assignment_loop(Index, Workers, _Base, _Extra, _Offset, Acc)
        when Index > Workers ->
    lists:reverse(Acc);
assignment_loop(Index, Workers, Base, Extra, Offset, Acc) ->
    WorkerCount = Base +
        case Index =< Extra of true -> 1; false -> 0 end,
    assignment_loop(
        Index + 1, Workers, Base, Extra, Offset + WorkerCount,
        [{Offset, WorkerCount} | Acc]
    ).

worker(Template, Offset, Count) ->
    lists:foldl(
        fun(Index, Stats) ->
            Message = vary_message(Template, Offset + Index),
            Started = erlang:monotonic_time(microsecond),
            Result = telco_stp:transfer(Message),
            Latency = max(
                1, erlang:monotonic_time(microsecond) - Started
            ),
            record_result(Result, Latency, Stats)
        end,
        empty_stats(),
        lists:seq(1, Count)
    ).

vary_message(Template, Sequence) ->
    BaseSls = maps:get(sls, Template, 0),
    Template#{sls => (BaseSls + Sequence) band ?STP_UINT8_MAX}.

empty_stats() ->
    #{
        succeeded => 0,
        failed => 0,
        latency_histogram => #{},
        latency_min_us => undefined,
        latency_max_us => 0,
        errors => #{}
    }.

record_result({ok, _Info}, Latency, Stats) ->
    Bucket = latency_bucket(Latency),
    Histogram = maps:get(latency_histogram, Stats),
    Min =
        case maps:get(latency_min_us, Stats) of
            undefined -> Latency;
            CurrentMin -> min(CurrentMin, Latency)
        end,
    Stats#{
        succeeded => maps:get(succeeded, Stats) + 1,
        latency_histogram => increment_counter(Bucket, Histogram),
        latency_min_us => Min,
        latency_max_us => max(maps:get(latency_max_us, Stats), Latency)
    };
record_result({error, Reason}, _Latency, Stats) ->
    Errors = maps:get(errors, Stats),
    Stats#{
        failed => maps:get(failed, Stats) + 1,
        errors => increment_counter(Reason, Errors)
    }.

latency_bucket(Value) ->
    latency_bucket(Value, 1).

latency_bucket(Value, Upper) when Value =< Upper ->
    Upper;
latency_bucket(Value, Upper) ->
    latency_bucket(Value, Upper bsl 1).

collect(_Ref, 0, Stats) ->
    {ok, Stats};
collect(Ref, Remaining, Stats) ->
    receive
        {load_result, Ref, {ok, WorkerStats}} ->
            collect(Ref, Remaining - 1, merge_stats(Stats, WorkerStats));
        {load_result, Ref, {error, Reason}} ->
            {error, {load_worker_failed, Reason}}
    end.

merge_stats(A, B) ->
    #{
        succeeded => maps:get(succeeded, A) + maps:get(succeeded, B),
        failed => maps:get(failed, A) + maps:get(failed, B),
        latency_histogram => maps:fold(
            fun(Bucket, Count, Acc) ->
                add_counter(Bucket, Count, Acc)
            end,
            maps:get(latency_histogram, A),
            maps:get(latency_histogram, B)
        ),
        latency_min_us => min_defined(
            maps:get(latency_min_us, A), maps:get(latency_min_us, B)
        ),
        latency_max_us => max(
            maps:get(latency_max_us, A), maps:get(latency_max_us, B)
        ),
        errors => maps:fold(
            fun(Reason, Count, Acc) ->
                add_counter(Reason, Count, Acc)
            end,
            maps:get(errors, A),
            maps:get(errors, B)
        )
    }.

report(Count, Workers, DurationUs, Stats) ->
    Succeeded = maps:get(succeeded, Stats),
    Histogram = maps:get(latency_histogram, Stats),
    #{
        requested => Count,
        concurrency => Workers,
        succeeded => Succeeded,
        failed => maps:get(failed, Stats),
        duration_ms => DurationUs / ?STP_MICROSECONDS_PER_MILLISECOND,
        throughput_per_second =>
            (Count * ?STP_MICROSECONDS_PER_SECOND) / DurationUs,
        latency_us => #{
            min => maps:get(latency_min_us, Stats),
            p50_upper_bound => percentile(Histogram, Succeeded, 50),
            p95_upper_bound => percentile(Histogram, Succeeded, 95),
            p99_upper_bound => percentile(Histogram, Succeeded, 99),
            max => maps:get(latency_max_us, Stats)
        },
        errors => maps:get(errors, Stats)
    }.

percentile(_Histogram, 0, _Percent) ->
    undefined;
percentile(Histogram, Total, Percent) ->
    Target =
        (Total * Percent + (?STP_PERCENT_SCALE - 1)) div ?STP_PERCENT_SCALE,
    percentile_walk(lists:sort(maps:to_list(Histogram)), Target, 0).

percentile_walk([{Upper, Count} | _Rest], Target, Seen)
        when Seen + Count >= Target ->
    Upper;
percentile_walk([{_Upper, Count} | Rest], Target, Seen) ->
    percentile_walk(Rest, Target, Seen + Count).

min_defined(undefined, Value) -> Value;
min_defined(Value, undefined) -> Value;
min_defined(A, B) -> min(A, B).

increment_counter(Key, Counters) ->
    add_counter(Key, 1, Counters).

add_counter(Key, Count, Counters) ->
    maps:update_with(Key, fun(Value) -> Value + Count end, Count, Counters).
