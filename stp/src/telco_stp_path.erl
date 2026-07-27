-module(telco_stp_path).

-export([normalize/2]).

normalize(Path, _ErrorTag) when is_binary(Path) ->
    binary_to_list(Path);
normalize(Path, _ErrorTag) when is_list(Path), Path =/= [] ->
    Path;
normalize(Path, ErrorTag) ->
    error({ErrorTag, Path}).
