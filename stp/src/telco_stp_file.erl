-module(telco_stp_file).

-export([replace_deleted/2, replace_deleted_strict/2, temporary_path/1]).

temporary_path(Path) ->
    Path ++ ".tmp." ++ integer_to_list(
        erlang:unique_integer([positive, monotonic])
    ).

replace_deleted(Temporary, Path) ->
    case file:rename(Temporary, Path) of
        ok -> ok;
        {error, eexist} ->
            replace_after_delete(Temporary, Path);
        {error, eacces} ->
            replace_after_delete(Temporary, Path);
        Error ->
            Error
    end.

replace_after_delete(Temporary, Path) ->
    _ = file:delete(Path),
    file:rename(Temporary, Path).

replace_deleted_strict(Temporary, Path) ->
    case file:rename(Temporary, Path) of
        ok -> ok;
        {error, eexist} ->
            replace_after_delete_strict(Temporary, Path);
        {error, eacces} ->
            replace_after_delete_strict(Temporary, Path);
        {error, enoent} ->
            file:rename(Temporary, Path);
        Error ->
            Error
    end.

replace_after_delete_strict(Temporary, Path) ->
    ok = file:delete(Path),
    file:rename(Temporary, Path).
