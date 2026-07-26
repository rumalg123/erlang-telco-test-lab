-module(telco_stp_mtp3).

-export([encode/2, decode/2]).

-type variant() :: itu | ansi.
-type message() :: #{
    opc := non_neg_integer(),
    dpc := non_neg_integer(),
    si := 0..15,
    ni := 0..3,
    mp := 0..3,
    sls := non_neg_integer(),
    payload := binary()
}.

-export_type([variant/0, message/0]).

-spec encode(variant(), message()) -> {ok, binary()} | {error, term()}.
encode(itu, Message) ->
    try
        Dpc = uint(maps:get(dpc, Message), 14, dpc),
        Opc = uint(maps:get(opc, Message), 14, opc),
        Sls = uint(maps:get(sls, Message), 4, sls),
        Sio = sio(Message),
        Payload = payload(Message),
        Label = Dpc bor (Opc bsl 14) bor (Sls bsl 28),
        {ok, <<Sio:8, Label:32/little, Payload/binary>>}
    catch
        error:Reason -> {error, Reason}
    end;
encode(ansi, Message) ->
    try
        Dpc = uint(maps:get(dpc, Message), 24, dpc),
        Opc = uint(maps:get(opc, Message), 24, opc),
        Sls = uint(maps:get(sls, Message), 8, sls),
        Sio = sio(Message),
        Payload = payload(Message),
        {ok, <<Sio:8, Dpc:24/little, Opc:24/little, Sls:8, Payload/binary>>}
    catch
        error:Reason -> {error, Reason}
    end;
encode(Variant, _Message) ->
    {error, {unsupported_mtp3_variant, Variant}}.

-spec decode(variant(), binary()) -> {ok, message()} | {error, term()}.
decode(itu, <<Sio:8, Label:32/little, Payload/binary>>) ->
    {Ni, Mp, Si} = decode_sio(Sio),
    {ok, #{
        dpc => Label band 16#3fff,
        opc => (Label bsr 14) band 16#3fff,
        sls => (Label bsr 28) band 16#0f,
        si => Si,
        ni => Ni,
        mp => Mp,
        payload => Payload
    }};
decode(ansi, <<
    Sio:8, Dpc:24/little, Opc:24/little, Sls:8, Payload/binary
>>) ->
    {Ni, Mp, Si} = decode_sio(Sio),
    {ok, #{
        dpc => Dpc,
        opc => Opc,
        sls => Sls,
        si => Si,
        ni => Ni,
        mp => Mp,
        payload => Payload
    }};
decode(Variant, Binary) when Variant =:= itu; Variant =:= ansi ->
    {error, {truncated_mtp3_message, Variant, byte_size(Binary)}};
decode(Variant, _Binary) ->
    {error, {unsupported_mtp3_variant, Variant}}.

sio(Message) ->
    Ni = uint(maps:get(ni, Message), 2, ni),
    Mp = uint(maps:get(mp, Message), 2, mp),
    Si = uint(maps:get(si, Message), 4, si),
    (Ni bsl 6) bor (Mp bsl 4) bor Si.

decode_sio(Sio) ->
    {(Sio bsr 6) band 3, (Sio bsr 4) band 3, Sio band 16#0f}.

payload(Message) ->
    Value = maps:get(payload, Message),
    true = is_binary(Value) orelse error({invalid_payload, Value}),
    Value.

uint(Value, Bits, _Name)
        when is_integer(Value), Value >= 0, Value < (1 bsl Bits) ->
    Value;
uint(Value, _Bits, Name) ->
    error({invalid_unsigned_integer, Name, Value}).

