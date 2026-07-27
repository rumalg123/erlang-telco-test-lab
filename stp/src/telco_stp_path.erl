-module(telco_stp_path).

-export([configured/1, normalize/2]).

configured(undefined) -> true;
configured(Path) when is_binary(Path), byte_size(Path) > 0 -> true;
configured(Path) when is_list(Path), Path =/= [] -> true;
configured(_Path) -> false.

normalize(Path, _ErrorTag) when is_binary(Path) ->
    binary_to_list(Path);
normalize(Path, _ErrorTag) when is_list(Path), Path =/= [] ->
    Path;
normalize(Path, ErrorTag) ->
    error({ErrorTag, Path}).
