-module(telco_stp_match).

-export([network_appearance/2]).

network_appearance(any, _Value) -> true;
network_appearance(_Value, any) -> true;
network_appearance(Value, Value) -> true;
network_appearance(_A, _B) -> false.
