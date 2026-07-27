-module(telco_stp_trace).
-behaviour(gen_server).

-include("telco_stp.hrl").

-export([
    start_link/0,
    configure/1,
    record/5,
    status/0,
    packets/0,
    clear/0,
    export_pcapng/1
]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

configure(Config) ->
    gen_server:call(?MODULE, {configure, Config}).

record(Direction, Link, Adaptation, Stream, Binary)
        when is_binary(Binary) ->
    gen_server:cast(
        ?MODULE,
        {record, Direction, Link, Adaptation, Stream, Binary}
    ).

status() ->
    gen_server:call(?MODULE, status).

packets() ->
    gen_server:call(?MODULE, packets).

clear() ->
    gen_server:call(?MODULE, clear).

export_pcapng(Path) ->
    gen_server:call(
        ?MODULE, {export_pcapng, Path}, ?STP_DEFAULT_OPERATION_TIMEOUT_MS
    ).

init([]) ->
    Config0 = application:get_env(?STP_APP, ?STP_ENV_TRACE, #{}),
    {ok, Config} = normalize(Config0),
    {ok, #{
        config => Config,
        packets => queue:new(),
        packet_count => 0,
        bytes => 0,
        dropped => 0
    }}.

handle_call({configure, Config0}, _From, State) ->
    case normalize(Config0) of
        {ok, Config} ->
            {reply, ok, enforce_limits(State#{config => Config})};
        Error ->
            {reply, Error, State}
    end;
handle_call(status, _From, State) ->
    {reply, #{
        enabled => maps:get(enabled, maps:get(config, State)),
        packet_count => maps:get(packet_count, State),
        bytes => maps:get(bytes, State),
        dropped => maps:get(dropped, State),
        limits => maps:without(
            [enabled], maps:get(config, State)
        )
    }, State};
handle_call(packets, _From, State) ->
    {reply, queue:to_list(maps:get(packets, State)), State};
handle_call(clear, _From, State) ->
    {reply, ok, State#{
        packets => queue:new(),
        packet_count => 0,
        bytes => 0
    }};
handle_call({export_pcapng, Path0}, _From, State) ->
    Reply = export_file(
        Path0, queue:to_list(maps:get(packets, State))
    ),
    {reply, Reply, State};
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported}, State}.

handle_cast(
    {record, Direction, Link, Adaptation, Stream, Binary},
    State
) ->
    Config = maps:get(config, State),
    case maps:get(enabled, Config) andalso
         valid_packet(Direction, Adaptation, Stream) of
        true ->
            Payload =
                case maps:get(capture_payload, Config) of
                    true -> Binary;
                    false -> first_octets(
                        Binary, maps:get(header_bytes, Config)
                    )
                end,
            Packet = #{
                timestamp_us => erlang:system_time(microsecond),
                direction => Direction,
                link => Link,
                adaptation => Adaptation,
                stream => Stream,
                original_length => byte_size(Binary),
                payload => Payload
            },
            Queue = queue:in(Packet, maps:get(packets, State)),
            NewState = State#{
                packets => Queue,
                packet_count => maps:get(packet_count, State) + 1,
                bytes => maps:get(bytes, State) + byte_size(Payload)
            },
            {noreply, enforce_limits(NewState)};
        false ->
            {noreply, State}
    end;
handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

normalize(Config) when is_map(Config) ->
    Normalized = #{
        enabled => maps:get(enabled, Config, false),
        max_packets => maps:get(
            max_packets, Config, ?STP_DEFAULT_TRACE_MAX_PACKETS
        ),
        max_bytes => maps:get(
            max_bytes, Config, ?STP_DEFAULT_TRACE_MAX_BYTES
        ),
        capture_payload => maps:get(capture_payload, Config, true),
        header_bytes => maps:get(
            header_bytes, Config, ?STP_DEFAULT_TRACE_HEADER_BYTES
        )
    },
    case Normalized of
        #{
            enabled := Enabled,
            max_packets := MaxPackets,
            max_bytes := MaxBytes,
            capture_payload := Capture,
            header_bytes := HeaderBytes
        } when is_boolean(Enabled), is_boolean(Capture) ->
            case valid_trace_limits(MaxPackets, MaxBytes, HeaderBytes) of
                true -> {ok, Normalized};
                false -> {error, {invalid_trace_config, Config}}
            end;
        _ ->
            {error, {invalid_trace_config, Config}}
    end;
normalize(Config) ->
    {error, {invalid_trace_config, Config}}.

valid_packet(Direction, Adaptation, Stream) ->
    valid_direction(Direction) andalso
    valid_adaptation(Adaptation) andalso
    valid_stream(Stream).

valid_positive(Value) ->
    is_integer(Value) andalso Value > 0.

valid_trace_limits(MaxPackets, MaxBytes, HeaderBytes) ->
    valid_positive(MaxPackets) andalso
    valid_positive(MaxBytes) andalso
    valid_positive(HeaderBytes).

valid_direction(rx) -> true;
valid_direction(tx) -> true;
valid_direction(_Direction) -> false.

valid_adaptation(m3ua) -> true;
valid_adaptation(m2pa) -> true;
valid_adaptation(_Adaptation) -> false.

valid_stream(Value) ->
    telco_stp_codec:in_range(Value, 0, ?STP_MAX_SHORT_BYTES).

enforce_limits(State) ->
    Config = maps:get(config, State),
    case maps:get(packet_count, State) =<
             maps:get(max_packets, Config) andalso
         maps:get(bytes, State) =< maps:get(max_bytes, Config) of
        true ->
            State;
        false ->
            {{value, Packet}, Remaining} =
                queue:out(maps:get(packets, State)),
            enforce_limits(State#{
                packets => Remaining,
                packet_count => maps:get(packet_count, State) - 1,
                bytes => maps:get(bytes, State) -
                    byte_size(maps:get(payload, Packet)),
                dropped => maps:get(dropped, State) + 1
            })
    end.

export_file(Path0, Packets) ->
    try
        Path = normalize_path(Path0),
        ok = filelib:ensure_dir(Path),
        Binary = iolist_to_binary([
            section_header_block(),
            interface_description_block(),
            [enhanced_packet_block(Packet) || Packet <- Packets]
        ]),
        Temporary = telco_stp_file:temporary_path(Path),
        ok = file:write_file(Temporary, Binary, [binary, sync]),
        ok = replace_file(Temporary, Path),
        {ok, #{
            path => Path,
            packets => length(Packets),
            bytes => byte_size(Binary)
        }}
    catch
        error:Reason -> {error, {pcapng_export_failed, Reason}}
    end.

section_header_block() ->
    block(?STP_PCAPNG_SHB_TYPE, <<
        ?STP_PCAPNG_BYTE_ORDER_MAGIC:32/little,
        ?STP_PCAPNG_MAJOR_VERSION:16/little,
        ?STP_PCAPNG_MINOR_VERSION:16/little,
        ?STP_PCAPNG_UNSPECIFIED_SECTION_LENGTH:64/little
    >>).

interface_description_block() ->
    block(?STP_PCAPNG_IDB_TYPE, <<
        ?STP_PCAPNG_DLT_USER0:16/little, 0:16,
        ?STP_PCAPNG_DEFAULT_SNAPLEN:32/little
    >>).

enhanced_packet_block(Packet) ->
    Timestamp = maps:get(timestamp_us, Packet),
    High = (Timestamp bsr 32) band ?STP_UINT32_MAX,
    Low = Timestamp band ?STP_UINT32_MAX,
    Captured = trace_payload(Packet),
    CapturedLength = byte_size(Captured),
    OriginalLength = maps:get(original_length, Packet) +
        CapturedLength - byte_size(maps:get(payload, Packet)),
    PaddingLength = padding_length(CapturedLength),
    Body = <<
        0:32/little,
        High:32/little, Low:32/little,
        CapturedLength:32/little, OriginalLength:32/little,
        Captured/binary, 0:(PaddingLength * 8)
    >>,
    block(?STP_PCAPNG_EPB_TYPE, Body).

trace_payload(Packet) ->
    Direction =
        case maps:get(direction, Packet) of
            rx -> ?STP_TRACE_DIRECTION_RX;
            tx -> ?STP_TRACE_DIRECTION_TX
        end,
    Adaptation =
        case maps:get(adaptation, Packet) of
            m3ua -> ?STP_M3UA_PPID;
            m2pa -> ?STP_M2PA_PPID
        end,
    Stream = maps:get(stream, Packet),
    Link = iolist_to_binary(io_lib:format("~0p", [
        maps:get(link, Packet)
    ])),
    Payload = maps:get(payload, Packet),
    <<?STP_TRACE_PAYLOAD_MAGIC/binary,
      Direction:8, Adaptation:8, Stream:16/big,
      (byte_size(Link)):16/big, Link/binary, Payload/binary>>.

block(Type, Body) ->
    Length = ?STP_PCAPNG_BLOCK_OVERHEAD_BYTES + byte_size(Body),
    <<Type:32/little, Length:32/little, Body/binary, Length:32/little>>.

padding_length(Size) ->
    (?STP_PCAPNG_ALIGNMENT_BYTES -
        (Size rem ?STP_PCAPNG_ALIGNMENT_BYTES)) rem
        ?STP_PCAPNG_ALIGNMENT_BYTES.

first_octets(Binary, Maximum) ->
    binary:part(Binary, 0, min(byte_size(Binary), Maximum)).

normalize_path(Path) ->
    telco_stp_path:normalize(Path, invalid_pcapng_path).

replace_file(Temporary, Path) ->
    case telco_stp_file:replace_deleted_strict(Temporary, Path) of
        ok ->
            ok;
        {error, Reason} ->
            error({pcapng_rename_failed, Reason})
    end.
