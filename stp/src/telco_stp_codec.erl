-module(telco_stp_codec).

-export([binary/2, in_range/3, integer_range/5, uint/3]).

binary(Value, _ErrorTag) when is_binary(Value) ->
    Value;
binary(Value, ErrorTag) ->
    error({ErrorTag, Value}).

uint(Value, Bits, _Name)
        when is_integer(Value), Value >= 0, Value < (1 bsl Bits) ->
    Value;
uint(Value, _Bits, Name) ->
    error({invalid_unsigned_integer, Name, Value}).

in_range(Value, Min, Max)
        when is_integer(Value), Value >= Min, Value =< Max ->
    true;
in_range(_Value, _Min, _Max) ->
    false.

integer_range(Value, Min, Max, Name, ErrorTag) ->
    case in_range(Value, Min, Max) of
        true -> Value;
        false -> error({ErrorTag, Name, Value})
    end.
