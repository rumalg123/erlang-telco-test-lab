-module(telco_stp_m2pa).

-include("telco_stp.hrl").

-export([encode/1, decode/1, next_sequence/1]).

-type link_status() ::
    alignment | proving_normal | proving_emergency | ready |
    processor_outage | processor_recovered | busy | busy_ended |
    out_of_service.
-type message() :: #{
    type := user_data | link_status,
    bsn := 0..?STP_M2PA_MAX_SEQUENCE,
    fsn := 0..?STP_M2PA_MAX_SEQUENCE,
    priority => 0..3,
    mtp3 => binary(),
    status => link_status() | non_neg_integer(),
    filler => binary()
}.

-export_type([message/0, link_status/0]).

-spec encode(message()) -> {ok, binary()} | {error, term()}.
encode(#{type := Type, bsn := Bsn0, fsn := Fsn0} = Message) ->
    try
        Bsn = sequence(Bsn0, bsn),
        Fsn = sequence(Fsn0, fsn),
        {TypeId, Body} = encode_body(Type, Message),
        Length = 16 + byte_size(Body),
        {ok, <<
            ?STP_M2PA_VERSION:8, 0:8, ?STP_M2PA_CLASS:8,
            TypeId:8, Length:32/big,
            0:8, Bsn:24/big, 0:8, Fsn:24/big, Body/binary
        >>}
    catch
        error:Reason -> {error, Reason}
    end;
encode(Message) ->
    {error, {invalid_m2pa_message, Message}}.

-spec decode(binary()) -> {ok, message()} | {error, term()}.
decode(<<?STP_M2PA_VERSION:8, _Spare:8, ?STP_M2PA_CLASS:8,
         TypeId:8, Length:32/big,
         _UnusedBsn:8, Bsn:24/big, _UnusedFsn:8, Fsn:24/big,
         Body/binary>> = Binary)
        when Length >= 16 ->
    case byte_size(Binary) of
        Length ->
            decode_body(TypeId, Bsn, Fsn, Body);
        Actual ->
            {error, {invalid_m2pa_length, Length, Actual}}
    end;
decode(<<Version:8, _/binary>>) when Version =/= ?STP_M2PA_VERSION ->
    {error, {unsupported_m2pa_version, Version}};
decode(<<_Version:8, _Spare:8, Class:8, _/binary>>)
        when Class =/= ?STP_M2PA_CLASS ->
    {error, {invalid_m2pa_class, Class}};
decode(Binary) when is_binary(Binary) ->
    {error, {truncated_m2pa_message, byte_size(Binary)}};
decode(Value) ->
    {error, {not_binary, Value}}.

-spec next_sequence(0..?STP_M2PA_MAX_SEQUENCE) -> 0..?STP_M2PA_MAX_SEQUENCE.
next_sequence(?STP_M2PA_MAX_SEQUENCE) -> 0;
next_sequence(Value)
        when is_integer(Value), Value >= 0, Value < ?STP_M2PA_MAX_SEQUENCE ->
    Value + 1.

encode_body(user_data, Message) ->
    Priority = uint(maps:get(priority, Message, 0), 2, priority),
    Mtp3 = maps:get(mtp3, Message, <<>>),
    true = is_binary(Mtp3) orelse error({invalid_mtp3_payload, Mtp3}),
    {1, <<Priority:2, 0:6, Mtp3/binary>>};
encode_body(link_status, Message) ->
    Status = status_id(maps:get(status, Message)),
    Filler = maps:get(filler, Message, <<>>),
    true = is_binary(Filler) orelse error({invalid_m2pa_filler, Filler}),
    {2, <<Status:32/big, Filler/binary>>};
encode_body(Type, _Message) ->
    error({invalid_m2pa_type, Type}).

decode_body(1, Bsn, Fsn, <<Priority:2, _Spare:6, Mtp3/binary>>) ->
    {ok, #{
        type => user_data,
        bsn => Bsn,
        fsn => Fsn,
        priority => Priority,
        mtp3 => Mtp3
    }};
decode_body(1, _Bsn, _Fsn, <<>>) ->
    {error, missing_m2pa_priority_octet};
decode_body(2, Bsn, Fsn, <<Status:32/big, Filler/binary>>) ->
    {ok, #{
        type => link_status,
        bsn => Bsn,
        fsn => Fsn,
        status => status_name(Status),
        filler => Filler
    }};
decode_body(2, _Bsn, _Fsn, Body) ->
    {error, {truncated_m2pa_link_status, byte_size(Body)}};
decode_body(Type, _Bsn, _Fsn, _Body) ->
    {error, {unsupported_m2pa_type, Type}}.

status_id(alignment) -> 1;
status_id(proving_normal) -> 2;
status_id(proving_emergency) -> 3;
status_id(ready) -> 4;
status_id(processor_outage) -> 5;
status_id(processor_recovered) -> 6;
status_id(busy) -> 7;
status_id(busy_ended) -> 8;
status_id(out_of_service) -> 9;
status_id(Value) -> uint(Value, 32, status).

status_name(1) -> alignment;
status_name(2) -> proving_normal;
status_name(3) -> proving_emergency;
status_name(4) -> ready;
status_name(5) -> processor_outage;
status_name(6) -> processor_recovered;
status_name(7) -> busy;
status_name(8) -> busy_ended;
status_name(9) -> out_of_service;
status_name(Value) -> Value.

sequence(Value, _Name)
        when is_integer(Value), Value >= 0,
             Value =< ?STP_M2PA_MAX_SEQUENCE ->
    Value;
sequence(Value, Name) ->
    error({invalid_m2pa_sequence, Name, Value}).

uint(Value, Bits, Name) ->
    telco_stp_codec:uint(Value, Bits, Name).
