-module(telco_stp_slt).

-export([encode/1, decode/1]).

%% ITU-T Q.707 signalling network testing and maintenance messages.
%% The MTP3 routing label and SIO are handled by telco_stp_mtp3; this
%% module handles the SIF following that label.

-spec encode(map()) -> {ok, binary()} | {error, term()}.
encode(#{type := Type, test_pattern := Pattern})
        when is_binary(Pattern) ->
    try
        H1 = type_code(Type),
        Length = byte_size(Pattern),
        true = Length >= 1 andalso Length =< 15 orelse
            error({invalid_slt_pattern_length, Length}),
        %% H0 occupies bits 1..4 and H1 bits 5..8. In the following
        %% octet the Q.707 length indicator occupies bits 1..4.
        {ok, <<
            H1:4, 1:4,
            0:4, Length:4,
            Pattern/binary
        >>}
    catch
        error:Reason -> {error, Reason}
    end;
encode(Message) ->
    {error, {invalid_slt_message, Message}}.

-spec decode(binary()) -> {ok, map()} | {error, term()}.
decode(<<H1:4, 1:4, _Spare:4, Length:4, Rest/binary>>)
        when Length >= 1, Length =< 15 ->
    case Rest of
        <<Pattern:Length/binary>> ->
            try
                {ok, #{
                    type => type_name(H1),
                    test_pattern => Pattern
                }}
            catch
                error:Reason -> {error, Reason}
            end;
        _ ->
            {error, {
                invalid_slt_payload_length, Length, byte_size(Rest)
            }}
    end;
decode(<<_H1:4, H0:4, _/binary>>) ->
    {error, {unsupported_slt_heading_group, H0}};
decode(Binary) when is_binary(Binary) ->
    {error, {truncated_slt_message, byte_size(Binary)}};
decode(Value) ->
    {error, {invalid_slt_binary, Value}}.

type_code(sltm) -> 1;
type_code(slta) -> 2;
type_code(Type) -> error({invalid_slt_type, Type}).

type_name(1) -> sltm;
type_name(2) -> slta;
type_name(Type) -> error({invalid_slt_type, Type}).
