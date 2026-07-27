-module(telco_stp_config).

-include("telco_stp.hrl").

-export([export/0, save/1, load/2, apply/2, validate/1]).

export() ->
    #{
        schema_version => ?STP_CONFIG_SCHEMA_VERSION,
        generated_at => erlang:system_time(millisecond),
        otp_release => erlang:system_info(otp_release),
        links => telco_stp_link_manager:configs(),
        listeners => telco_stp_listener_manager:configs(),
        routes => [
            maps:remove(specificity, Route)
            || Route <- telco_stp_route_table:list(),
               maps:get(dynamic, Route, false) =:= false
        ],
        gtt_rules => [
            maps:filter(
                fun(_Key, Value) -> Value =/= undefined end,
                maps:remove(specificity, Rule)
            )
            || Rule <- telco_stp_gtt:list()
        ],
        fault_profile => telco_stp_dispatcher:fault_profile(),
        overload_limits => telco_stp_dispatcher:overload_limits()
    }.

save(Path0) ->
    try
        Path = normalize_path(Path0),
        Configuration = export(),
        Payload = term_to_binary(Configuration, [
            compressed, {minor_version, 2}
        ]),
        Digest = crypto:hash(sha256, Payload),
        Binary = <<
            ?STP_CONFIG_MAGIC/binary,
            (byte_size(Payload)):32/big,
            Digest:32/binary,
            Payload/binary
        >>,
        ok = filelib:ensure_dir(Path),
        Temporary = temporary_path(Path),
        ok = file:write_file(Temporary, Binary, [binary, sync]),
        case replace_file(Temporary, Path) of
            ok -> {ok, Configuration};
            {error, Reason} ->
                _ = file:delete(Temporary),
                {error, {configuration_save_failed, Reason}}
        end
    catch
        error:CatchReason ->
            {error, {configuration_save_failed, CatchReason}}
    end.

load(Path0, Mode) when Mode =:= merge; Mode =:= replace ->
    try
        Path = normalize_path(Path0),
        case file:read_file(Path) of
            {ok, Binary} ->
                case decode(Binary) of
                    {ok, Configuration} ->
                        case validate(Configuration) of
                            ok -> apply_configuration(Configuration, Mode);
                            Error -> Error
                        end;
                    Error ->
                        Error
                end;
            {error, Reason} ->
                {error, {configuration_read_failed, Reason}}
        end
    catch
        error:CatchReason ->
            {error, {configuration_load_failed, CatchReason}}
    end;
load(_Path, Mode) ->
    {error, {invalid_configuration_load_mode, Mode}}.

apply(Configuration, Mode) when Mode =:= merge; Mode =:= replace ->
    case validate(Configuration) of
        ok -> apply_configuration(Configuration, Mode);
        Error -> Error
    end;
apply(_Configuration, Mode) ->
    {error, {invalid_configuration_load_mode, Mode}}.

validate(#{
    schema_version := ?STP_CONFIG_SCHEMA_VERSION,
    links := Links,
    listeners := Listeners,
    routes := Routes,
    gtt_rules := GttRules,
    fault_profile := Faults
}) when is_list(Links), is_list(Listeners), is_list(Routes),
        is_list(GttRules), is_map(Faults) ->
    case lists:all(
        fun erlang:is_map/1, Links ++ Listeners ++ Routes ++ GttRules
    ) of
        true -> ok;
        false -> {error, invalid_configuration_entries}
    end;
validate(#{schema_version := Version}) ->
    {error, {unsupported_configuration_schema, Version}};
validate(Configuration) ->
    {error, {invalid_configuration, Configuration}}.

decode(<<
    "TSTPCFG", 1, Length:32/big, Digest:32/binary,
    Payload:Length/binary
>>) ->
    case crypto:hash(sha256, Payload) of
        Digest ->
            try
                {ok, binary_to_term(Payload, [safe])}
            catch
                error:Reason ->
                    {error, {configuration_decode_failed, Reason}}
            end;
        _Other ->
            {error, configuration_checksum_mismatch}
    end;
decode(<<
    "TSTPCFG", 1, Length:32/big, _Digest:32/binary, Payload/binary
>>) ->
    {error, {configuration_length_mismatch, Length, byte_size(Payload)}};
decode(_Binary) ->
    {error, invalid_configuration_magic}.

apply_configuration(Configuration, merge) ->
    apply_entries(Configuration);
apply_configuration(Configuration, replace) ->
    Previous = export(),
    case clear_current() of
        ok ->
            case apply_entries(Configuration) of
                {ok, _} = Success ->
                    Success;
                {error, Reason} ->
                    _ = clear_current(),
                    Rollback = apply_entries(Previous),
                    {error, {
                        configuration_apply_failed, Reason,
                        rollback, Rollback
                    }}
            end;
        Error ->
            Error
    end.

apply_entries(Configuration) ->
    Steps = [
        {listeners, fun telco_stp_listener_manager:add/1},
        {links, fun telco_stp_link_manager:add/1},
        {routes, fun telco_stp_route_table:add/1},
        {gtt_rules, fun telco_stp_gtt:add/1}
    ],
    case apply_steps(Steps, Configuration) of
        ok ->
            case telco_stp_dispatcher:set_fault_profile(
                maps:get(fault_profile, Configuration)
            ) of
                ok ->
                    case telco_stp_dispatcher:set_overload_limits(
                        maps:get(
                            overload_limits, Configuration,
                            telco_stp_dispatcher:overload_limits()
                        )
                    ) of
                        ok -> {ok, export()};
                        {error, Reason} ->
                            {error, {overload_limits, Reason}}
                    end;
                {error, Reason} ->
                    {error, {fault_profile, Reason}}
            end;
        Error ->
            Error
    end.

apply_steps([], _Configuration) ->
    ok;
apply_steps([{Key, Function} | Rest], Configuration) ->
    case apply_list(maps:get(Key, Configuration), Function) of
        ok -> apply_steps(Rest, Configuration);
        {error, Reason} -> {error, {Key, Reason}}
    end.

apply_list([], _Function) ->
    ok;
apply_list([Entry | Rest], Function) ->
    case Function(Entry) of
        ok -> apply_list(Rest, Function);
        {ok, _Value} -> apply_list(Rest, Function);
        {error, {already_exists, _}} -> apply_list(Rest, Function);
        {error, Reason} -> {error, Reason}
    end.

clear_current() ->
    lists:foreach(
        fun(#{name := Name}) ->
            _ = telco_stp_listener_manager:remove(Name)
        end,
        telco_stp_listener_manager:list()
    ),
    lists:foreach(
        fun(Config) ->
            _ = telco_stp_link_manager:remove(maps:get(name, Config))
        end,
        telco_stp_link_manager:configs()
    ),
    lists:foreach(
        fun(Route) ->
            _ = telco_stp_route_table:remove(maps:get(id, Route))
        end,
        telco_stp_route_table:list()
    ),
    lists:foreach(
        fun(Rule) ->
            _ = telco_stp_gtt:remove(maps:get(id, Rule))
        end,
        telco_stp_gtt:list()
    ),
    ok.

replace_file(Temporary, Path) ->
    case file:rename(Temporary, Path) of
        ok ->
            ok;
        {error, eexist} ->
            replace_existing_file(Temporary, Path);
        {error, eacces} ->
            replace_existing_file(Temporary, Path);
        Error ->
            Error
    end.

replace_existing_file(Temporary, Path) ->
    Backup = Path ++ ".bak",
    _ = file:delete(Backup),
    case file:rename(Path, Backup) of
        ok ->
            case file:rename(Temporary, Path) of
                ok ->
                    _ = file:delete(Backup),
                    ok;
                Error ->
                    _ = file:rename(Backup, Path),
                    Error
            end;
        {error, enoent} ->
            file:rename(Temporary, Path);
        Error ->
            Error
    end.

normalize_path(Path) when is_binary(Path) ->
    binary_to_list(Path);
normalize_path(Path) when is_list(Path), Path =/= [] ->
    Path;
normalize_path(Path) ->
    error({invalid_configuration_path, Path}).

temporary_path(Path) ->
    Path ++ ".tmp." ++ integer_to_list(
        erlang:unique_integer([positive, monotonic])
    ).
