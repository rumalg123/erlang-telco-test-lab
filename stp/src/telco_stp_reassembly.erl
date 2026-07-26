-module(telco_stp_reassembly).
-behaviour(gen_server).

-export([start_link/0, process/3, status/0, reset/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

process(SourceLink, MtpMessage, SccpMessage) ->
    gen_server:call(
        ?MODULE,
        {process, SourceLink, MtpMessage, SccpMessage},
        10000
    ).

status() ->
    gen_server:call(?MODULE, status).

reset() ->
    gen_server:call(?MODULE, reset).

init([]) ->
    Limits = application:get_env(
        telco_stp, sccp_reassembly_limits, #{}
    ),
    {ok, #{
        contexts => #{},
        total_bytes => 0,
        max_contexts => positive(
            maps:get(max_contexts, Limits, 10000), max_contexts
        ),
        max_context_bytes => positive(
            maps:get(max_context_bytes, Limits, 65536),
            max_context_bytes
        ),
        max_total_bytes => positive(
            maps:get(max_total_bytes, Limits, 67108864),
            max_total_bytes
        ),
        timeout_ms => positive(
            maps:get(timeout_ms, Limits, 10000), timeout_ms
        )
    }}.

handle_call(
    {process, SourceLink, MtpMessage, SccpMessage},
    _From,
    State
) ->
    case segmentation(SccpMessage) of
        none ->
            {reply, {complete, SccpMessage}, State};
        {ok, Segmentation} ->
            process_segment(
                SourceLink, MtpMessage, SccpMessage,
                Segmentation, State
            );
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end;
handle_call(status, _From, State) ->
    {reply, status_map(State), State};
handle_call(reset, _From, State) ->
    cancel_context_timers(maps:get(contexts, State)),
    {reply, ok, State#{contexts => #{}, total_bytes => 0}};
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported}, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(
    {reassembly_timeout, Key, Generation},
    #{contexts := Contexts} = State
) ->
    case maps:find(Key, Contexts) of
        {ok, #{generation := Generation} = Context} ->
            Bytes = maps:get(bytes, Context),
            telco_stp_metrics:increment({sccp, reassembly_timeout}),
            telco_stp_alarm:raise(
                {sccp, reassembly, context_id(Key)},
                warning,
                #{
                    reason => reassembly_timeout,
                    received_segments => map_size(
                        maps:get(segments, Context)
                    ),
                    bytes => Bytes
                }
            ),
            {noreply, State#{
                contexts => maps:remove(Key, Contexts),
                total_bytes => maps:get(total_bytes, State) - Bytes
            }};
        _ ->
            {noreply, State}
    end;
handle_info(_Info, State) ->
    {noreply, State}.

process_segment(
    SourceLink,
    MtpMessage,
    SccpMessage,
    Segmentation,
    #{contexts := Contexts} = State
) ->
    Key = context_key(
        SourceLink, MtpMessage, SccpMessage, Segmentation
    ),
    case maps:find(Key, Contexts) of
        error ->
            start_context(
                Key, SccpMessage, Segmentation, State
            );
        {ok, Context} ->
            update_context(
                Key, Context, SccpMessage, Segmentation, State
            )
    end.

start_context(Key, SccpMessage, Segmentation, State) ->
    Data = maps:get(data, SccpMessage),
    Size = byte_size(Data),
    case capacity_available(Size, State) of
        true ->
            Remaining = maps:get(remaining_segments, Segmentation),
            First = maps:get(first_segment, Segmentation),
            Generation = make_ref(),
            TimerRef = start_timeout(Key, Generation, State),
            Context = #{
                key => Key,
                first_remaining =>
                    case First of true -> Remaining; false -> undefined end,
                template =>
                    case First of true -> SccpMessage; false -> undefined end,
                segments => #{Remaining => Data},
                bytes => Size,
                generation => Generation,
                timer_ref => TimerRef,
                created_at => erlang:system_time(millisecond),
                updated_at => erlang:system_time(millisecond)
            },
            finish_or_store(Key, Context, State);
        false ->
            telco_stp_metrics:increment({sccp, reassembly_overload}),
            telco_stp_alarm:raise(
                {sccp, reassembly, capacity},
                major,
                #{
                    reason => reassembly_capacity_exceeded,
                    contexts => map_size(maps:get(contexts, State)),
                    total_bytes => maps:get(total_bytes, State)
                }
            ),
            {reply, {error, reassembly_capacity_exceeded}, State}
    end.

update_context(Key, Context0, SccpMessage, Segmentation, State) ->
    Remaining = maps:get(remaining_segments, Segmentation),
    Data = maps:get(data, SccpMessage),
    Segments = maps:get(segments, Context0),
    case maps:find(Remaining, Segments) of
        {ok, Data} ->
            finish_or_store(Key, Context0, State);
        {ok, _DifferentData} ->
            discard_context(
                Key, conflicting_duplicate_segment, Context0, State
            );
        error ->
            add_new_segment(
                Key, Context0, SccpMessage, Segmentation, State
            )
    end.

add_new_segment(
    Key, Context0, SccpMessage, Segmentation, State
) ->
    Remaining = maps:get(remaining_segments, Segmentation),
    First = maps:get(first_segment, Segmentation),
    Data = maps:get(data, SccpMessage),
    Size = byte_size(Data),
    ExistingFirst = maps:get(first_remaining, Context0),
    case valid_first_segment(First, Remaining, ExistingFirst) of
        false ->
            discard_context(
                Key, conflicting_first_segment, Context0, State
            );
        true ->
            NewFirst =
                case First of
                    true -> Remaining;
                    false -> ExistingFirst
                end,
            Segments = maps:get(segments, Context0),
            case valid_remaining_numbers(NewFirst, maps:keys(Segments), Remaining) of
                false ->
                    discard_context(
                        Key, invalid_remaining_segment_sequence,
                        Context0, State
                    );
                true ->
                    NewBytes = maps:get(bytes, Context0) + Size,
                    AddedTotal = maps:get(total_bytes, State) + Size,
                    case NewBytes =< maps:get(max_context_bytes, State)
                         andalso AddedTotal =< maps:get(max_total_bytes, State) of
                        false ->
                            discard_context(
                                Key, reassembly_size_limit,
                                Context0, State
                            );
                        true ->
                            cancel_timer(maps:get(timer_ref, Context0)),
                            Generation = make_ref(),
                            TimerRef = start_timeout(
                                Key, Generation, State
                            ),
                            Template =
                                case First of
                                    true -> SccpMessage;
                                    false -> maps:get(template, Context0)
                                end,
                            Context = Context0#{
                                first_remaining => NewFirst,
                                template => Template,
                                segments => Segments#{Remaining => Data},
                                bytes => NewBytes,
                                generation => Generation,
                                timer_ref => TimerRef,
                                updated_at => erlang:system_time(millisecond)
                            },
                            finish_or_store(
                                Key, Context, State
                            )
                    end
            end
    end.

finish_or_store(Key, Context, State0) ->
    FirstRemaining = maps:get(first_remaining, Context),
    Segments = maps:get(segments, Context),
    case complete(FirstRemaining, Segments) of
        true ->
            cancel_timer(maps:get(timer_ref, Context)),
            Data = iolist_to_binary([
                maps:get(Index, Segments)
                || Index <- lists:seq(FirstRemaining, 0, -1)
            ]),
            Template = maps:get(template, Context),
            Reassembled = normalize_reassembled(
                remove_segmentation(Template#{data => Data})
            ),
            Contexts = maps:get(contexts, State0),
            StoredBytes =
                case maps:find(Key, Contexts) of
                    {ok, Existing} -> maps:get(bytes, Existing);
                    error -> 0
                end,
            TotalBytes = maps:get(total_bytes, State0) - StoredBytes,
            telco_stp_metrics:increment({sccp, reassembled}),
            telco_stp_alarm:clear(
                {sccp, reassembly, context_id(Key)},
                #{
                    reason => reassembly_completed,
                    segments => FirstRemaining + 1,
                    bytes => byte_size(Data)
                }
            ),
            {reply, {complete, Reassembled}, State0#{
                contexts => maps:remove(Key, Contexts),
                total_bytes => TotalBytes
            }};
        false ->
            Contexts = maps:get(contexts, State0),
            ExistingBytes =
                case maps:find(Key, Contexts) of
                    {ok, Existing} -> maps:get(bytes, Existing);
                    error -> 0
                end,
            NewTotal = maps:get(total_bytes, State0) -
                ExistingBytes + maps:get(bytes, Context),
            UpdatedState = State0#{
                contexts => Contexts#{Key => Context},
                total_bytes => NewTotal
            },
            {reply, {pending, context_summary(Context)}, UpdatedState}
    end.

discard_context(Key, Reason, Context, State) ->
    cancel_timer(maps:get(timer_ref, Context)),
    Contexts = maps:get(contexts, State),
    Bytes =
        case maps:find(Key, Contexts) of
            {ok, Stored} -> maps:get(bytes, Stored);
            error -> 0
        end,
    telco_stp_metrics:increment({sccp, reassembly_error}),
    telco_stp_alarm:raise(
        {sccp, reassembly, context_id(Key)},
        warning,
        #{reason => Reason}
    ),
    {reply, {error, Reason}, State#{
        contexts => maps:remove(Key, Contexts),
        total_bytes => maps:get(total_bytes, State) - Bytes
    }}.

segmentation(#{options := Options}) when is_list(Options) ->
    case [
        Value || {segmentation, Value} <- Options
    ] of
        [] -> none;
        [Value] when is_map(Value) -> {ok, Value};
        [_Value] -> {error, unstructured_segmentation_parameter};
        _ -> {error, duplicate_segmentation_parameter}
    end;
segmentation(_SccpMessage) ->
    none.

context_key(SourceLink, MtpMessage, SccpMessage, Segmentation) ->
    {
        SourceLink,
        maps:get(opc, MtpMessage),
        maps:get(sccp_variant, MtpMessage, itu),
        maps:get(local_reference, Segmentation),
        term_to_binary(maps:get(calling_party, SccpMessage)),
        term_to_binary(maps:get(called_party, SccpMessage))
    }.

capacity_available(Size, State) ->
    map_size(maps:get(contexts, State)) < maps:get(max_contexts, State) andalso
    Size =< maps:get(max_context_bytes, State) andalso
    maps:get(total_bytes, State) + Size =< maps:get(max_total_bytes, State).

valid_first_segment(true, Remaining, undefined) ->
    Remaining >= 0;
valid_first_segment(true, Remaining, Remaining) ->
    true;
valid_first_segment(true, _Remaining, _Existing) ->
    false;
valid_first_segment(false, _Remaining, _Existing) ->
    true.

valid_remaining_numbers(undefined, _Existing, _New) ->
    true;
valid_remaining_numbers(First, Existing, New) ->
    New =< First andalso lists:all(
        fun(Value) -> Value =< First end, Existing
    ).

complete(undefined, _Segments) ->
    false;
complete(FirstRemaining, Segments) ->
    lists:all(
        fun(Index) -> maps:is_key(Index, Segments) end,
        lists:seq(0, FirstRemaining)
    ).

remove_segmentation(#{options := Options} = Message) ->
    RemainingOptions = [
        Option || {Name, _Value} = Option <- Options,
                  Name =/= segmentation
    ],
    Message#{options => RemainingOptions};
remove_segmentation(Message) ->
    Message.

normalize_reassembled(#{type := xudt, data := Data} = Message)
        when byte_size(Data) > 255 ->
    Message#{type => ludt};
normalize_reassembled(#{type := xudts, data := Data} = Message)
        when byte_size(Data) > 255 ->
    Message#{type => ludts};
normalize_reassembled(Message) ->
    Message.

start_timeout(Key, Generation, State) ->
    erlang:send_after(
        maps:get(timeout_ms, State),
        self(),
        {reassembly_timeout, Key, Generation}
    ).

status_map(State) ->
    #{
        context_count => map_size(maps:get(contexts, State)),
        total_bytes => maps:get(total_bytes, State),
        limits => maps:with(
            [
                max_contexts,
                max_context_bytes,
                max_total_bytes,
                timeout_ms
            ],
            State
        ),
        contexts => [
            context_summary(Context)
            || Context <- maps:values(maps:get(contexts, State))
        ]
    }.

context_summary(Context) ->
    FirstRemaining = maps:get(first_remaining, Context),
    #{
        id => context_id(maps:get(key, Context)),
        received_segments => map_size(maps:get(segments, Context)),
        expected_segments =>
            case FirstRemaining of
                undefined -> undefined;
                Value -> Value + 1
            end,
        bytes => maps:get(bytes, Context),
        created_at => maps:get(created_at, Context),
        updated_at => maps:get(updated_at, Context)
    }.

context_id(Key) ->
    erlang:phash2(Key, 16#ffffffff).

cancel_context_timers(Contexts) ->
    lists:foreach(
        fun(Context) -> cancel_timer(maps:get(timer_ref, Context)) end,
        maps:values(Contexts)
    ).

cancel_timer(Ref) when is_reference(Ref) ->
    _ = erlang:cancel_timer(Ref),
    ok;
cancel_timer(_Ref) ->
    ok.

positive(Value, _Name) when is_integer(Value), Value > 0 ->
    Value;
positive(Value, Name) ->
    error({invalid_positive_limit, Name, Value}).
