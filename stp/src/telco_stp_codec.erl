-module(telco_stp_codec).

-export([binary/2, uint/3]).

binary(Value, _ErrorTag) when is_binary(Value) ->
    Value;
binary(Value, ErrorTag) ->
    error({ErrorTag, Value}).

uint(Value, Bits, _Name)
        when is_integer(Value), Value >= 0, Value < (1 bsl Bits) ->
    Value;
uint(Value, _Bits, Name) ->
    error({invalid_unsigned_integer, Name, Value}).
