-module(telco_stp_audit).
-behaviour(gen_server).

-include("telco_stp.hrl").

-export([
    start_link/0,
    record/5,
    events/0,
    verify/0,
    subscribe/1
]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

record(Actor, Action, Target, Result, Details) ->
    gen_server:call(
        ?MODULE, {record, Actor, Action, Target, Result, Details},
        ?STP_DEFAULT_CALL_TIMEOUT_MS
    ).

events() ->
    gen_server:call(?MODULE, events).

verify() ->
    gen_server:call(?MODULE, verify).

subscribe(Pid) when is_pid(Pid) ->
    gen_server:call(?MODULE, {subscribe, Pid}).

init([]) ->
    Limit = application:get_env(
        ?STP_APP, ?STP_ENV_AUDIT_HISTORY_LIMIT,
        ?STP_DEFAULT_AUDIT_HISTORY_LIMIT
    ),
    Path = application:get_env(
        ?STP_APP, ?STP_ENV_AUDIT_LOG_PATH, undefined
    ),
    case valid_limit(Limit) andalso telco_stp_path:configured(Path) of
        false ->
            {stop, {invalid_audit_configuration, Limit, Path}};
        true ->
            case load_persisted(Path, Limit) of
                {ok, Sequence, PreviousHash, Events} ->
                    {ok, #{
                        sequence => Sequence,
                        previous_hash => PreviousHash,
                        events => Events,
                        limit => Limit,
                        path => Path,
                        subscribers => #{}
                    }};
                {error, Reason} ->
                    {stop, {audit_log_invalid, Reason}}
            end
    end.

handle_call(
    {record, Actor, Action, Target, Result, Details}, _From, State
) ->
    case valid_event(Details) of
        true ->
            Sequence = maps:get(sequence, State) + 1,
            PreviousHash = maps:get(previous_hash, State),
            Base = #{
                sequence => Sequence,
                timestamp => erlang:system_time(millisecond),
                monotonic_timestamp =>
                    erlang:monotonic_time(microsecond),
                node => node(),
                actor => Actor,
                action => Action,
                target => Target,
                result => Result,
                details => Details,
                previous_hash => PreviousHash
            },
            Hash = event_hash(Base),
            Event = Base#{hash => Hash},
            case persist(Event, maps:get(path, State)) of
                ok ->
                    Events0 = [Event | maps:get(events, State)],
                    Limit = maps:get(limit, State),
                    Events = lists:sublist(
                        Events0, min(Limit, length(Events0))
                    ),
                    NewState = State#{
                        sequence => Sequence,
                        previous_hash => Hash,
                        events => Events
                    },
                    notify(Event, NewState),
                    {reply, {ok, Event}, NewState};
                {error, Reason} ->
                    telco_stp_alarm:raise(
                        {management, audit_persistence}, major,
                        #{reason => Reason}
                    ),
                    {reply, {error, {audit_persistence_failed, Reason}}, State}
            end;
        false ->
            {reply, {error, invalid_audit_event}, State}
    end;
handle_call(events, _From, State) ->
    {reply, lists:reverse(maps:get(events, State)), State};
handle_call(verify, _From, State) ->
    {reply, verify_events(lists:reverse(maps:get(events, State))), State};
handle_call({subscribe, Pid}, _From, State) ->
    Ref = erlang:monitor(process, Pid),
    Subscribers = maps:get(subscribers, State),
    {reply, {ok, Ref}, State#{
        subscribers => Subscribers#{Ref => Pid}
    }};
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported}, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info({'DOWN', Ref, process, _Pid, _Reason}, State) ->
    Subscribers = maps:get(subscribers, State),
    {noreply, State#{subscribers => maps:remove(Ref, Subscribers)}};
handle_info(_Info, State) ->
    {noreply, State}.

valid_event(Details) ->
    is_map(Details).

event_hash(Base) ->
    telco_stp_term:sha256(Base).

persist(_Event, undefined) ->
    ok;
persist(Event, Path0) ->
    try
        Path = telco_stp_path:normalize(
            Path0, invalid_audit_log_path
        ),
        ok = filelib:ensure_dir(Path),
        Payload = telco_stp_term:compressed_binary(Event),
        Frame = <<(byte_size(Payload)):32/big, Payload/binary>>,
        file:write_file(Path, Frame, [append, binary, sync])
    catch
        error:CatchReason -> {error, CatchReason}
    end.

verify_events([]) ->
    ok;
verify_events(Events) ->
    First = hd(Events),
    verify_events(
        Events,
        maps:get(previous_hash, First),
        maps:get(sequence, First)
    ).

verify_events([], _ExpectedPrevious, _ExpectedSequence) ->
    ok;
verify_events([Event | Rest], ExpectedPrevious, ExpectedSequence) ->
    Base = maps:remove(hash, Event),
    case {
        maps:get(sequence, Event) =:= ExpectedSequence,
        maps:get(previous_hash, Event) =:= ExpectedPrevious,
        event_hash(Base) =:= maps:get(hash, Event)
    } of
        {true, true, true} ->
            verify_events(
                Rest, maps:get(hash, Event), ExpectedSequence + 1
            );
        _ ->
            {error, {audit_chain_invalid, maps:get(sequence, Event)}}
    end.

load_persisted(undefined, _Limit) ->
    {ok, 0, ?STP_ZERO_HASH, []};
load_persisted(Path0, Limit) ->
    try
        Path = telco_stp_path:normalize(
            Path0, invalid_audit_log_path
        ),
        case file:read_file(Path) of
            {ok, Binary} ->
                case decode_frames(Binary, []) of
                    {ok, Chronological} ->
                        case verify_disk_chain(Chronological) of
                            ok ->
                                {Sequence, PreviousHash} =
                                    audit_tail(Chronological),
                                {ok, Sequence, PreviousHash,
                                    retain_latest(Chronological, Limit)};
                            Error ->
                                Error
                        end;
                    Error ->
                        Error
                end;
            {error, enoent} ->
                {ok, 0, ?STP_ZERO_HASH, []};
            {error, Reason} ->
                {error, {audit_log_read_failed, Reason}}
        end
    catch
        error:LoadReason -> {error, LoadReason}
    end.

decode_frames(<<>>, Acc) ->
    {ok, lists:reverse(Acc)};
decode_frames(<<Length:32/big, Rest/binary>>, Acc)
        when Length > 0, Length =< ?STP_AUDIT_MAX_FRAME_BYTES,
             byte_size(Rest) >= Length ->
    <<Payload:Length/binary, Tail/binary>> = Rest,
    try binary_to_term(Payload, [safe]) of
        Event when is_map(Event) ->
            case valid_persisted_event(Event) of
                true -> decode_frames(Tail, [Event | Acc]);
                false -> {error, invalid_audit_log_event}
            end;
        _ ->
            {error, invalid_audit_log_event}
    catch
        error:Reason ->
            {error, {audit_log_decode_failed, Reason}}
    end;
decode_frames(<<Length:32/big, Rest/binary>>, _Acc) ->
    {error, {
        invalid_audit_log_frame, Length, byte_size(Rest)
    }};
decode_frames(Binary, _Acc) ->
    {error, {truncated_audit_log_frame, byte_size(Binary)}}.

valid_persisted_event(Event) ->
    case Event of
        #{
            sequence := Sequence,
            previous_hash := PreviousHash,
            hash := Hash,
            details := Details
        } ->
            is_integer(Sequence) andalso Sequence > 0 andalso
            is_binary(PreviousHash) andalso
            byte_size(PreviousHash) =:= ?STP_SHA256_BYTES andalso
            is_binary(Hash) andalso
            byte_size(Hash) =:= ?STP_SHA256_BYTES andalso
            is_map(Details);
        _ ->
            false
    end.

verify_disk_chain([]) ->
    ok;
verify_disk_chain([First | _] = Events) ->
    case {
        maps:get(sequence, First),
        maps:get(previous_hash, First)
    } of
        {1, ?STP_ZERO_HASH} ->
            verify_events(Events, ?STP_ZERO_HASH, 1);
        _ ->
            {error, audit_log_chain_origin_invalid}
    end.

audit_tail([]) ->
    {0, ?STP_ZERO_HASH};
audit_tail(Events) ->
    Last = lists:last(Events),
    {maps:get(sequence, Last), maps:get(hash, Last)}.

retain_latest(Events, Limit) ->
    Count = length(Events),
    Drop = max(0, Count - Limit),
    lists:reverse(lists:nthtail(Drop, Events)).

valid_limit(Limit) ->
    is_integer(Limit) andalso Limit > 0 andalso
        Limit =< ?STP_MAX_AUDIT_HISTORY_LIMIT.

notify(Event, State) ->
    lists:foreach(
        fun(Pid) -> Pid ! {stp_audit, Event} end,
        maps:values(maps:get(subscribers, State))
    ).
