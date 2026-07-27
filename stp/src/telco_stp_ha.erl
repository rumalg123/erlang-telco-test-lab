-module(telco_stp_ha).
-behaviour(gen_server).

-include("telco_stp.hrl").

-export([
    start_link/0,
    status/0,
    snapshot_now/0,
    receive_snapshot/2,
    receive_snapshot_sync/2,
    promote/1,
    demote/0
]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

status() ->
    gen_server:call(?MODULE, status).

snapshot_now() ->
    gen_server:call(?MODULE, snapshot_now, 30000).

receive_snapshot(SourceNode, Envelope) ->
    gen_server:cast(?MODULE, {replica, SourceNode, Envelope}).

receive_snapshot_sync(SourceNode, Envelope) ->
    gen_server:call(
        ?MODULE, {replica, SourceNode, Envelope}, 30000
    ).

promote(FencingToken) ->
    gen_server:call(
        ?MODULE, {promote, FencingToken},
        ?STP_DEFAULT_PROMOTION_TIMEOUT_MS
    ).

demote() ->
    gen_server:call(?MODULE, demote).

init([]) ->
    Config0 = application:get_env(?STP_APP, ?STP_ENV_HA, #{}),
    Config = normalize_config(Config0),
    case load_persisted_replica(Config) of
        {ok, Replica} ->
            State = #{
                config => Config,
                mode => maps:get(mode, Config),
                generation => 0,
                latest_replica => Replica,
                last_replication => undefined,
                replication_failures => #{},
                timer => undefined
            },
            {ok, schedule_replication(State)};
        {error, Reason} ->
            {stop, {ha_replica_invalid, Reason}}
    end.

handle_call(status, _From, State) ->
    ReplicaSummary =
        case maps:get(latest_replica, State) of
            undefined -> undefined;
            #{snapshot := Snapshot} ->
                maps:with(
                    [
                        source_node,
                        generation,
                        created_at,
                        schema_version
                    ],
                    Snapshot
                )
        end,
    {reply, #{
        mode => maps:get(mode, State),
        peers => maps:get(peers, maps:get(config, State)),
        generation => maps:get(generation, State),
        latest_replica => ReplicaSummary,
        last_replication => maps:get(last_replication, State),
        replication_failures => maps:get(replication_failures, State),
        fencing_configured =>
            maps:get(
                fencing_token_sha256, maps:get(config, State)
            ) =/= undefined
    }, State};
handle_call(snapshot_now, _From, State) ->
    {Envelope, NewState} = create_envelope(State),
    {reply, {ok, Envelope}, NewState};
handle_call({replica, SourceNode, Envelope}, _From, State) ->
    {Reply, NewState} =
        accept_replica(SourceNode, Envelope, State),
    {reply, Reply, NewState};
handle_call({promote, Token}, _From, State) ->
    case promote_standby(Token, State) of
        {ok, Result, NewState} ->
            {reply, {ok, Result}, schedule_replication(NewState)};
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end;
handle_call(demote, _From, State) ->
    case maps:get(mode, State) of
        primary ->
            _ = telco_stp_audit:record(
                trusted_local, ha_demote, node(), success, #{}
            ),
            {reply, ok, cancel_replication(State#{mode => standby})};
        Mode ->
            {reply, {error, {invalid_ha_mode, Mode}}, State}
    end;
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported}, State}.

handle_cast({replica, SourceNode, Envelope}, State) ->
    {_Reply, NewState} =
        accept_replica(SourceNode, Envelope, State),
    {noreply, NewState};
handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(replicate, #{mode := primary} = State0) ->
    State = State0#{timer => undefined},
    {Envelope, GeneratedState} = create_envelope(State),
    ReplicatedState = replicate_to_peers(Envelope, GeneratedState),
    {noreply, schedule_replication(ReplicatedState)};
handle_info(replicate, State) ->
    {noreply, State#{timer => undefined}};
handle_info(_Info, State) ->
    {noreply, State}.

normalize_config(Config) when is_map(Config) ->
    Mode = maps:get(mode, Config, standalone),
    Peers = maps:get(peers, Config, []),
    Interval = maps:get(interval_ms, Config, ?STP_DEFAULT_HA_INTERVAL_MS),
    MaxStaleness = maps:get(
        max_staleness_ms, Config, ?STP_DEFAULT_HA_MAX_STALENESS_MS
    ),
    MaxClockSkew = maps:get(
        max_clock_skew_ms, Config, ?STP_DEFAULT_HA_MAX_CLOCK_SKEW_MS
    ),
    ReplicationTimeout = maps:get(
        replication_timeout_ms, Config,
        ?STP_DEFAULT_HA_REPLICATION_TIMEOUT_MS
    ),
    Secret = maps:get(shared_secret, Config, undefined),
    Fence = maps:get(fencing_token_sha256, Config, undefined),
    Path = maps:get(snapshot_path, Config, undefined),
    true = lists:member(Mode, [standalone, primary, standby]) orelse
        error({invalid_ha_mode, Mode}),
    true = is_list(Peers) andalso
        lists:all(fun is_atom/1, Peers) orelse
        error({invalid_ha_peers, Peers}),
    true = is_integer(Interval) andalso
        Interval >= ?STP_MIN_HA_INTERVAL_MS orelse
        error({invalid_ha_interval, Interval}),
    true = is_integer(MaxStaleness) andalso MaxStaleness > 0 orelse
        error({invalid_ha_staleness, MaxStaleness}),
    true = is_integer(MaxClockSkew) andalso MaxClockSkew >= 0 andalso
        MaxClockSkew =< ?STP_MAX_HA_CLOCK_SKEW_MS orelse
        error({invalid_ha_clock_skew, MaxClockSkew}),
    true = is_integer(ReplicationTimeout) andalso
        ReplicationTimeout >= ?STP_MIN_HA_REPLICATION_TIMEOUT_MS andalso
        ReplicationTimeout =< ?STP_MAX_HA_REPLICATION_TIMEOUT_MS orelse
        error({invalid_ha_replication_timeout, ReplicationTimeout}),
    true = valid_secret(Mode, Secret) orelse
        error(invalid_ha_shared_secret),
    true = valid_fence(Mode, Fence) orelse
        error(invalid_ha_fencing_token),
    true = valid_path(Path) orelse error(invalid_ha_snapshot_path),
    #{
        mode => Mode,
        peers => lists:usort(Peers),
        interval_ms => Interval,
        max_staleness_ms => MaxStaleness,
        max_clock_skew_ms => MaxClockSkew,
        replication_timeout_ms => ReplicationTimeout,
        shared_secret => Secret,
        fencing_token_sha256 => Fence,
        snapshot_path => Path
    };
normalize_config(Config) ->
    error({invalid_ha_config, Config}).

valid_secret(standalone, undefined) -> true;
valid_secret(_Mode, Secret) ->
    is_binary(Secret) andalso byte_size(Secret) >= 32.

valid_fence(standalone, undefined) -> true;
valid_fence(primary, undefined) -> true;
valid_fence(standby, Fence) ->
    is_binary(Fence) andalso byte_size(Fence) =:= 32;
valid_fence(_Mode, Fence) ->
    Fence =:= undefined orelse
    (is_binary(Fence) andalso byte_size(Fence) =:= 32).

valid_path(undefined) -> true;
valid_path(Path) when is_binary(Path), byte_size(Path) > 0 -> true;
valid_path(Path) when is_list(Path), Path =/= [] -> true;
valid_path(_Path) -> false.

create_envelope(State) ->
    Generation = maps:get(generation, State) + 1,
    Snapshot = #{
        schema_version => ?STP_HA_SCHEMA_VERSION,
        source_node => node(),
        generation => Generation,
        created_at => erlang:system_time(millisecond),
        configuration => telco_stp_config:export(),
        destination_states =>
            telco_stp_route_table:destination_states(),
        subsystem_states => telco_stp_scmg:states(),
        rkm_registrations => telco_stp_rkm:registrations()
    },
    Secret = maps:get(shared_secret, maps:get(config, State)),
    Mac = snapshot_mac(Snapshot, Secret),
    {
        #{snapshot => Snapshot, hmac_sha256 => Mac},
        State#{generation => Generation}
    }.

snapshot_mac(Snapshot, undefined) ->
    crypto:hash(
        sha256,
        term_to_binary(Snapshot, [{minor_version, 2}, deterministic])
    );
snapshot_mac(Snapshot, Secret) ->
    crypto:mac(
        hmac, sha256, Secret,
        term_to_binary(Snapshot, [{minor_version, 2}, deterministic])
    ).

replicate_to_peers(Envelope, State) ->
    Config = maps:get(config, State),
    Peers = maps:get(peers, Config),
    Timeout = maps:get(replication_timeout_ms, Config),
    Failures = lists:foldl(
        fun(Peer, Acc) ->
            try
                case erpc:call(
                    Peer, ?MODULE, receive_snapshot_sync,
                    [node(), Envelope], Timeout
                ) of
                    {ok, _Acknowledgement} ->
                        telco_stp_alarm:clear(
                            {ha, replication, Peer},
                            #{reason => replica_acknowledged}
                        ),
                        maps:remove(Peer, Acc);
                    {error, Reason} ->
                        replication_failed(Peer, Reason, Acc);
                    Other ->
                        replication_failed(
                            Peer, {invalid_acknowledgement, Other}, Acc
                        )
                end
            catch
                Class:CallReason ->
                    replication_failed(
                        Peer, {Class, CallReason}, Acc
                    )
            end
        end,
        maps:get(replication_failures, State),
        Peers
    ),
    State#{
        last_replication => erlang:system_time(millisecond),
        replication_failures => Failures
    }.

replication_failed(Peer, Reason, Failures) ->
    telco_stp_metrics:increment({ha, replication_failed}),
    telco_stp_alarm:raise(
        {ha, replication, Peer}, major,
        #{reason => Reason, peer => Peer}
    ),
    Failures#{Peer => #{
        reason => Reason,
        updated_at => erlang:system_time(millisecond)
    }}.

accept_replica(SourceNode, Envelope, #{mode := standby} = State) ->
    Config = maps:get(config, State),
    case lists:member(SourceNode, maps:get(peers, Config)) of
        false ->
            {
                {error, unconfigured_source},
                replica_rejected(unconfigured_source, SourceNode, State)
            };
        true ->
            case verify_envelope(Envelope, Config, SourceNode) of
                {ok, Snapshot} ->
                    case snapshot_time_valid(Snapshot, Config) of
                        ok ->
                            accept_newer_replica(
                                SourceNode, Envelope, Snapshot, State
                            );
                        {error, Reason} ->
                            {
                                {error, Reason},
                                replica_rejected(
                                    Reason, SourceNode, State
                                )
                            }
                    end;
                {error, Reason} ->
                    {
                        {error, Reason},
                        replica_rejected(Reason, SourceNode, State)
                    }
            end
    end;
accept_replica(SourceNode, _Envelope, State) ->
    {
        {error, not_standby},
        replica_rejected(not_standby, SourceNode, State)
    }.

accept_newer_replica(SourceNode, Envelope, Snapshot, State) ->
    case newer_snapshot(
        Snapshot, maps:get(latest_replica, State)
    ) of
        true ->
            Config = maps:get(config, State),
            case persist_replica(
                Envelope, maps:get(snapshot_path, Config)
            ) of
                ok ->
                    telco_stp_alarm:clear(
                        {ha, replication},
                        #{reason => valid_snapshot_received,
                          source_node => SourceNode}
                    ),
                    {
                        {ok, maps:get(generation, Snapshot)},
                        State#{
                            latest_replica => Envelope,
                            last_replication =>
                                erlang:system_time(millisecond)
                        }
                    };
                {error, Reason} ->
                    {
                        {error, {persistence_failed, Reason}},
                        replica_rejected(
                            {persistence_failed, Reason},
                            SourceNode, State
                        )
                    }
            end;
        false ->
            {{ok, ignored_stale_snapshot}, State}
    end.

verify_envelope(#{
    snapshot := #{
        schema_version := ?STP_HA_SCHEMA_VERSION,
        source_node := SourceNode,
        generation := Generation,
        created_at := CreatedAt,
        configuration := Configuration,
        destination_states := DestinationStates,
        subsystem_states := SubsystemStates,
        rkm_registrations := RkmRegistrations
    } = Snapshot,
    hmac_sha256 := Mac
}, Config, SourceNode) when is_atom(SourceNode),
                           is_integer(Generation), Generation > 0,
                           is_integer(CreatedAt),
                           is_list(DestinationStates),
                           is_list(SubsystemStates),
                           is_list(RkmRegistrations) ->
    Expected = snapshot_mac(Snapshot, maps:get(shared_secret, Config)),
    case {
        secure_equal(Mac, Expected),
        telco_stp_config:validate(Configuration)
    } of
        {true, ok} -> {ok, Snapshot};
        {false, _} -> {error, invalid_snapshot_hmac};
        {true, {error, Reason}} ->
            {error, {invalid_snapshot_configuration, Reason}}
    end;
verify_envelope(
    #{snapshot := #{source_node := SnapshotSource}},
    _Config,
    SourceNode
) when SnapshotSource =/= SourceNode ->
    {error, {snapshot_source_mismatch, SnapshotSource, SourceNode}};
verify_envelope(_Envelope, _Config, _SourceNode) ->
    {error, invalid_ha_snapshot}.

snapshot_time_valid(Snapshot, Config) ->
    Age = erlang:system_time(millisecond) -
        maps:get(created_at, Snapshot),
    MaxClockSkew = maps:get(max_clock_skew_ms, Config),
    case Age >= -MaxClockSkew of
        true -> ok;
        false -> {error, {snapshot_from_future, -Age}}
    end.

newer_snapshot(_Snapshot, undefined) ->
    true;
newer_snapshot(Snapshot, #{snapshot := Existing}) ->
    {
        maps:get(created_at, Snapshot),
        maps:get(generation, Snapshot)
    } >
    {
        maps:get(created_at, Existing),
        maps:get(generation, Existing)
    }.

replica_rejected(Reason, SourceNode, State) ->
    telco_stp_metrics:increment({ha, replica_rejected}),
    telco_stp_alarm:raise(
        {ha, replication}, major,
        #{reason => Reason, source_node => SourceNode}
    ),
    State.

promote_standby(Token, #{mode := standby} = State) ->
    Config = maps:get(config, State),
    case valid_fencing_token(Token, Config) of
        false ->
            {error, invalid_fencing_token};
        true ->
            case maps:get(latest_replica, State) of
                undefined ->
                    {error, no_replica_available};
                #{snapshot := Snapshot} ->
                    Age = erlang:system_time(millisecond) -
                        maps:get(created_at, Snapshot),
                    MaxClockSkew = maps:get(
                        max_clock_skew_ms, Config
                    ),
                    case {
                        Age >= -MaxClockSkew,
                        Age =< maps:get(max_staleness_ms, Config)
                    } of
                        {false, _} ->
                            {error, {replica_timestamp_in_future, -Age}};
                        {_, false} ->
                            {error, {replica_too_stale, Age}};
                        {true, true} ->
                            apply_promotion(Snapshot, State)
                    end
            end
    end;
promote_standby(_Token, State) ->
    {error, {invalid_ha_mode, maps:get(mode, State)}}.

valid_fencing_token(Token, Config) ->
    try
        Expected = maps:get(fencing_token_sha256, Config),
        Actual = crypto:hash(sha256, token_binary(Token)),
        secure_equal(Actual, Expected)
    catch
        error:_ -> false
    end.

apply_promotion(Snapshot, State) ->
    case telco_stp_config:apply(
        maps:get(configuration, Snapshot), replace
    ) of
        {ok, _Configuration} ->
            restore_destination_states(
                maps:get(destination_states, Snapshot, [])
            ),
            restore_subsystem_states(
                maps:get(subsystem_states, Snapshot, [])
            ),
            Dynamic = maps:get(rkm_registrations, Snapshot, []),
            Warnings =
                case Dynamic of
                    [] -> [];
                    _ -> [dynamic_rkm_requires_peer_reregistration]
                end,
            _ = telco_stp_audit:record(
                trusted_local, ha_promote, node(), success,
                #{
                    source_node => maps:get(source_node, Snapshot),
                    generation => maps:get(generation, Snapshot),
                    warnings => Warnings
                }
            ),
            {ok, #{
                source_node => maps:get(source_node, Snapshot),
                generation => maps:get(generation, Snapshot),
                warnings => Warnings
            }, State#{
                mode => primary,
                generation => maps:get(generation, Snapshot)
            }};
        {error, Reason} ->
            {error, {ha_configuration_apply_failed, Reason}}
    end.

restore_destination_states(States) ->
    lists:foreach(
        fun(State) ->
            Metadata = maps:without(
                [
                    source_link, status, mask, dpc, updated_at,
                    network_appearance, user_part
                ],
                State
            ),
            _ = telco_stp_route_table:set_destination_state(
                maps:get(source_link, State),
                maps:get(status, State),
                [{maps:get(mask, State), maps:get(dpc, State)}],
                maybe_put(
                    user_part, maps:get(user_part, State, any),
                    maybe_put(
                        network_appearance,
                        maps:get(network_appearance, State, any),
                        Metadata
                    )
                )
            )
        end,
        States
    ).

restore_subsystem_states(States) ->
    lists:foreach(
        fun(State) ->
            Metadata = maps:without(
                [
                    source_link, status, point_code, ssn,
                    updated_at
                ],
                State
            ),
            _ = telco_stp_scmg:set_state(
                maps:get(source_link, State),
                maps:get(point_code, State),
                maps:get(ssn, State),
                maps:get(status, State),
                Metadata
            )
        end,
        States
    ).

maybe_put(_Key, any, Map) -> Map;
maybe_put(Key, Value, Map) -> Map#{Key => Value}.

schedule_replication(#{mode := primary, timer := undefined} = State) ->
    Interval = maps:get(interval_ms, maps:get(config, State)),
    Ref = erlang:send_after(Interval, self(), replicate),
    State#{timer => Ref};
schedule_replication(State) ->
    State.

cancel_replication(State) ->
    case maps:get(timer, State) of
        Ref when is_reference(Ref) ->
            _ = erlang:cancel_timer(Ref);
        _ ->
            ok
    end,
    State#{timer => undefined}.

persist_replica(_Envelope, undefined) ->
    ok;
persist_replica(Envelope, Path0) ->
    try
        Path = normalize_path(Path0),
        ok = filelib:ensure_dir(Path),
        Binary = term_to_binary(Envelope, [
            compressed, {minor_version, 2}, deterministic
        ]),
        Temporary = Path ++ ".tmp." ++ integer_to_list(
            erlang:unique_integer([positive, monotonic])
        ),
        ok = file:write_file(Temporary, Binary, [binary, sync]),
        replace_file(Temporary, Path)
    catch
        error:Reason -> {error, Reason}
    end.

replace_file(Temporary, Path) ->
    case file:rename(Temporary, Path) of
        ok -> ok;
        {error, eexist} ->
            _ = file:delete(Path),
            file:rename(Temporary, Path);
        {error, eacces} ->
            _ = file:delete(Path),
            file:rename(Temporary, Path);
        Error -> Error
    end.

normalize_path(Path) when is_binary(Path) -> binary_to_list(Path);
normalize_path(Path) when is_list(Path), Path =/= [] -> Path.

load_persisted_replica(#{mode := standby, snapshot_path := Path} = Config)
        when Path =/= undefined ->
    try
        NormalizedPath = normalize_path(Path),
        case file:read_file(NormalizedPath) of
            {ok, Binary} ->
                Envelope = binary_to_term(Binary, [safe]),
                Snapshot = maps:get(snapshot, Envelope),
                SourceNode = maps:get(source_node, Snapshot),
                case lists:member(
                    SourceNode, maps:get(peers, Config)
                ) of
                    false ->
                        {error, {
                            persisted_replica_source_not_configured,
                            SourceNode
                        }};
                    true ->
                        case verify_envelope(
                            Envelope, Config, SourceNode
                        ) of
                            {ok, _} -> {ok, Envelope};
                            Error -> Error
                        end
                end;
            {error, enoent} ->
                {ok, undefined};
            {error, Reason} ->
                {error, {replica_read_failed, Reason}}
        end
    catch
        error:DecodeReason ->
            {error, {replica_decode_failed, DecodeReason}}
    end;
load_persisted_replica(_Config) ->
    {ok, undefined}.

token_binary(Token) when is_binary(Token), byte_size(Token) >= 16 ->
    Token;
token_binary(Token) when is_list(Token), length(Token) >= 16 ->
    unicode:characters_to_binary(Token);
token_binary(_Token) ->
    error(invalid_fencing_token).

secure_equal(A, B)
        when is_binary(A), is_binary(B), byte_size(A) =:= byte_size(B) ->
    crypto:hash_equals(A, B);
secure_equal(_A, _B) ->
    false.
