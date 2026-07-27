-module(telco_stp_mtp3).

-include("telco_stp.hrl").

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
        Label = Dpc
            bor (Opc bsl ?STP_MTP3_ITU_OPC_SHIFT)
            bor (Sls bsl ?STP_MTP3_ITU_SLS_SHIFT),
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
        dpc => Label band ?STP_ITU_POINT_CODE_MAX,
        opc => (Label bsr ?STP_MTP3_ITU_OPC_SHIFT)
            band ?STP_ITU_POINT_CODE_MAX,
        sls => (Label bsr ?STP_MTP3_ITU_SLS_SHIFT) band ?STP_MTP3_SLS_MASK,
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
    {(Sio bsr 6) band 3, (Sio bsr 4) band 3, Sio band ?STP_MTP3_SLS_MASK}.

payload(Message) ->
    telco_stp_codec:binary(maps:get(payload, Message), invalid_payload).

uint(Value, Bits, Name) ->
    telco_stp_codec:uint(Value, Bits, Name).

