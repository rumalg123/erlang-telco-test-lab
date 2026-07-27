-module(telco_stp_snmm).

-include("telco_stp.hrl").

-export([encode/2, decode/2, heading/1]).

-type variant() :: itu | ansi.
-type message_type() ::
    coo | coa | xco | xca | cbd | cba | eco | eca |
    rct | tfc | tfp | tfr | tfa | rst | rsr |
    lin | lun | lia | lua | lid | lfu | llt | lrt |
    tra | dlc | css | cns | cnp | upu.
-type message() :: #{
    type := message_type(),
    fsn => 0..?STP_M2PA_MAX_SEQUENCE,
    changeback_code => 0..255,
    affected_destination => non_neg_integer(),
    congestion_status => 0..255,
    user_part => 0..15,
    unavailability_cause => 0..15
}.

-export_type([message/0, message_type/0]).

-spec encode(variant(), message()) -> {ok, binary()} | {error, term()}.
encode(Variant, #{type := Type} = Message)
        when Variant =:= itu; Variant =:= ansi ->
    try
        {H0, H1} = heading(Type),
        Body = encode_body(Type, Variant, Message),
        {ok, <<H1:4, H0:4, Body/binary>>}
    catch
        error:Reason -> {error, Reason}
    end;
encode(Variant, Message) when Variant =:= itu; Variant =:= ansi ->
    {error, {invalid_snmm_message, Message}};
encode(Variant, _Message) ->
    {error, {unsupported_snmm_variant, Variant}}.

-spec decode(variant(), binary()) -> {ok, message()} | {error, term()}.
decode(Variant, <<H1:4, H0:4, Body/binary>>)
        when Variant =:= itu; Variant =:= ansi ->
    case type_name(H0, H1) of
        {ok, Type} ->
            decode_body(Type, Variant, Body);
        {error, Reason} ->
            {error, Reason}
    end;
decode(Variant, Binary)
        when is_binary(Binary), (Variant =:= itu orelse Variant =:= ansi) ->
    {error, {truncated_snmm_message, byte_size(Binary)}};
decode(Variant, _Binary) ->
    {error, {unsupported_snmm_variant, Variant}}.

-spec heading(message_type()) -> {1..15, 1..15}.
heading(Type) ->
    case lists:keyfind(Type, 1, snmm_headings()) of
        {Type, H0, H1} -> {H0, H1};
        false -> error({unsupported_snmm_type, Type})
    end.

type_name(H0, H1) ->
    case lists:filter(
        fun({_Type, CandidateH0, CandidateH1}) ->
            CandidateH0 =:= H0 andalso CandidateH1 =:= H1
        end,
        snmm_headings()
    ) of
        [{Type, H0, H1}] -> {ok, Type};
        [] -> {error, {unsupported_snmm_heading, H0, H1}}
    end.

snmm_headings() ->
    [
        {coo, ?STP_SNMM_H0_CHM, 1},
        {coa, ?STP_SNMM_H0_CHM, 2},
        {xco, ?STP_SNMM_H0_CHM, 3},
        {xca, ?STP_SNMM_H0_CHM, 4},
        {cbd, ?STP_SNMM_H0_CHM, 5},
        {cba, ?STP_SNMM_H0_CHM, 6},
        {eco, ?STP_SNMM_H0_ECM, 1},
        {eca, ?STP_SNMM_H0_ECM, 2},
        {rct, ?STP_SNMM_H0_FCM, 1},
        {tfc, ?STP_SNMM_H0_FCM, 2},
        {tfp, ?STP_SNMM_H0_TFM, 1},
        {tfr, ?STP_SNMM_H0_TFM, 3},
        {tfa, ?STP_SNMM_H0_TFM, 5},
        {rst, ?STP_SNMM_H0_RSM, 1},
        {rsr, ?STP_SNMM_H0_RSM, 2},
        {lin, ?STP_SNMM_H0_MIM, 1},
        {lun, ?STP_SNMM_H0_MIM, 2},
        {lia, ?STP_SNMM_H0_MIM, 3},
        {lua, ?STP_SNMM_H0_MIM, 4},
        {lid, ?STP_SNMM_H0_MIM, 5},
        {lfu, ?STP_SNMM_H0_MIM, 6},
        {llt, ?STP_SNMM_H0_MIM, 7},
        {lrt, ?STP_SNMM_H0_MIM, 8},
        {tra, ?STP_SNMM_H0_TRM, 1},
        {dlc, ?STP_SNMM_H0_DLM, 1},
        {css, ?STP_SNMM_H0_DLM, 2},
        {cns, ?STP_SNMM_H0_DLM, 3},
        {cnp, ?STP_SNMM_H0_DLM, 4},
        {upu, ?STP_SNMM_H0_UPU, 1}
    ].

encode_body(Type, _Variant, Message) when Type =:= coo; Type =:= coa ->
    <<(uint(maps:get(fsn, Message), 8, fsn)):8>>;
encode_body(Type, _Variant, Message) when Type =:= xco; Type =:= xca ->
    <<(uint(maps:get(fsn, Message), 24, fsn)):24/little>>;
encode_body(Type, _Variant, Message) when Type =:= cbd; Type =:= cba ->
    <<(uint(maps:get(changeback_code, Message), 8, changeback_code)):8>>;
encode_body(Type, _Variant, _Message)
        when Type =:= eco; Type =:= eca;
             Type =:= lin; Type =:= lun; Type =:= lia; Type =:= lua;
             Type =:= lid; Type =:= lfu; Type =:= llt; Type =:= lrt;
             Type =:= tra; Type =:= dlc; Type =:= css;
             Type =:= cns; Type =:= cnp ->
    <<>>;
encode_body(Type, Variant, Message)
        when Type =:= rct; Type =:= tfp; Type =:= tfr;
             Type =:= tfa; Type =:= rst; Type =:= rsr ->
    encode_point_code(Variant, maps:get(affected_destination, Message));
encode_body(tfc, Variant, Message) ->
    Destination = encode_point_code(
        Variant, maps:get(affected_destination, Message)
    ),
    Status = uint(maps:get(congestion_status, Message), 8, congestion_status),
    <<Destination/binary, Status:8>>;
encode_body(upu, Variant, Message) ->
    Destination = encode_point_code(
        Variant, maps:get(affected_destination, Message)
    ),
    UserPart = uint(maps:get(user_part, Message), 4, user_part),
    Cause = uint(
        maps:get(unavailability_cause, Message), 4, unavailability_cause
    ),
    <<Destination/binary, Cause:4, UserPart:4>>.

decode_body(Type, _Variant, <<Fsn:8>>)
        when Type =:= coo; Type =:= coa ->
    {ok, #{type => Type, fsn => Fsn}};
decode_body(Type, _Variant, <<Fsn:24/little>>)
        when Type =:= xco; Type =:= xca ->
    {ok, #{type => Type, fsn => Fsn}};
decode_body(Type, _Variant, <<Code:8>>)
        when Type =:= cbd; Type =:= cba ->
    {ok, #{type => Type, changeback_code => Code}};
decode_body(Type, _Variant, <<>>)
        when Type =:= eco; Type =:= eca;
             Type =:= lin; Type =:= lun; Type =:= lia; Type =:= lua;
             Type =:= lid; Type =:= lfu; Type =:= llt; Type =:= lrt;
             Type =:= tra; Type =:= dlc; Type =:= css;
             Type =:= cns; Type =:= cnp ->
    {ok, #{type => Type}};
decode_body(Type, Variant, Body)
        when Type =:= rct; Type =:= tfp; Type =:= tfr;
             Type =:= tfa; Type =:= rst; Type =:= rsr ->
    case decode_point_code(Variant, Body) of
        {ok, Destination, <<>>} ->
            {ok, #{type => Type, affected_destination => Destination}};
        {ok, _Destination, Rest} ->
            {error, {trailing_snmm_octets, Type, Rest}};
        Error ->
            Error
    end;
decode_body(tfc, Variant, Body) ->
    case decode_point_code(Variant, Body) of
        {ok, Destination, <<Status:8>>} ->
            {ok, #{
                type => tfc,
                affected_destination => Destination,
                congestion_status => Status
            }};
        {ok, _Destination, Rest} ->
            {error, {invalid_snmm_body, tfc, Rest}};
        Error ->
            Error
    end;
decode_body(upu, Variant, Body) ->
    case decode_point_code(Variant, Body) of
        {ok, Destination, <<Cause:4, UserPart:4>>} ->
            {ok, #{
                type => upu,
                affected_destination => Destination,
                user_part => UserPart,
                unavailability_cause => Cause
            }};
        {ok, _Destination, Rest} ->
            {error, {invalid_snmm_body, upu, Rest}};
        Error ->
            Error
    end;
decode_body(Type, _Variant, Body) ->
    {error, {invalid_snmm_body, Type, Body}}.

encode_point_code(itu, PointCode) ->
    <<(uint(PointCode, 14, affected_destination)):16/little>>;
encode_point_code(ansi, PointCode) ->
    <<(uint(PointCode, 24, affected_destination)):24/little>>.

decode_point_code(itu, <<PointCode:16/little, Rest/binary>>)
        when PointCode =< ?STP_ITU_POINT_CODE_MAX ->
    {ok, PointCode, Rest};
decode_point_code(itu, <<PointCode:16/little, _Rest/binary>>) ->
    {error, {invalid_snmm_itu_point_code, PointCode}};
decode_point_code(itu, Binary) ->
    {error, {truncated_snmm_point_code, itu, byte_size(Binary)}};
decode_point_code(ansi, <<PointCode:24/little, Rest/binary>>) ->
    {ok, PointCode, Rest};
decode_point_code(ansi, Binary) ->
    {error, {truncated_snmm_point_code, ansi, byte_size(Binary)}}.

uint(Value, Bits, _Name)
        when is_integer(Value), Value >= 0, Value < (1 bsl Bits) ->
    Value;
uint(Value, _Bits, Name) ->
    error({invalid_unsigned_integer, Name, Value}).
