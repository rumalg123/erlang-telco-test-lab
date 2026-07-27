-module(telco_stp_codec).

-export([binary/2, integer_range/5, uint/3]).

binary(Value, _ErrorTag) when is_binary(Value) ->
    Value;
binary(Value, ErrorTag) ->
    error({ErrorTag, Value}).

uint(Value, Bits, _Name)
        when is_integer(Value), Value >= 0, Value < (1 bsl Bits) ->
    Value;
uint(Value, _Bits, Name) ->
    error({invalid_unsigned_integer, Name, Value}).

integer_range(Value, Min, Max, _Name, _ErrorTag)
        when is_integer(Value), Value >= Min, Value =< Max ->
    Value;
integer_range(Value, _Min, _Max, Name, ErrorTag) ->
    error({ErrorTag, Name, Value}).
