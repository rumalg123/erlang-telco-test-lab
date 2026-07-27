#!/usr/bin/env escript
%%! -noshell
-mode(compile).

main(Arguments) ->
    try
        build(Arguments)
    catch
        Class:Reason:Stacktrace ->
            io:format(
                standard_error,
                "Release build failed (~p): ~p~n~p~n",
                [Class, Reason, Stacktrace]
            ),
            halt(1)
    end.

build([
    AppEbin0,
    SysConfig0,
    VmArgs0,
    Launcher0,
    OutputRoot0,
    ReleaseVsn,
    AppVsn
]) ->
    true = safe_version(ReleaseVsn),
    true = safe_version(AppVsn),
    AppEbin = filename:absname(AppEbin0),
    SysConfig = filename:absname(SysConfig0),
    VmArgs = filename:absname(VmArgs0),
    Launcher = filename:absname(Launcher0),
    OutputRoot = filename:absname(OutputRoot0),
    ok = require_file(filename:join(AppEbin, "telco_stp.app")),
    ok = require_file(SysConfig),
    ok = require_file(VmArgs),
    ok = require_file(Launcher),
    ok = require_empty_output(OutputRoot),
    ok = verify_application_modules(AppEbin),
    {ok, AppVsn} = application_version(
        filename:join(AppEbin, "telco_stp.app")
    ),
    Work = OutputRoot ++ ".release-work",
    ok = require_absent(Work),
    try
        build_target(
            AppEbin,
            SysConfig,
            VmArgs,
            Launcher,
            OutputRoot,
            Work,
            ReleaseVsn,
            AppVsn
        )
    after
        _ = file:del_dir_r(Work)
    end;
build(_Arguments) ->
    io:format(
        standard_error,
        "Usage: build_release.escript APP_EBIN SYS_CONFIG VM_ARGS "
        "LAUNCHER OUTPUT_ROOT RELEASE_VSN APP_VSN~n",
        []
    ),
    halt(2).

build_target(
    AppEbin,
    SysConfig,
    VmArgs,
    Launcher,
    OutputRoot,
    Work,
    ReleaseVsn,
    AppVsn
) ->
    WorkEbin = filename:join([
        Work, "lib", "telco_stp-" ++ AppVsn, "ebin"
    ]),
    ok = ensure_directory(WorkEbin),
    ok = copy_ebin(AppEbin, WorkEbin),
    ReleaseApps = [
        application_entry(kernel),
        application_entry(stdlib),
        application_entry(sasl),
        application_entry(crypto),
        {telco_stp, AppVsn}
    ],
    ErtsVsn = erlang:system_info(version),
    RelTerm = {
        release,
        {"telco_stp", ReleaseVsn},
        {erts, ErtsVsn},
        ReleaseApps
    },
    RelBase = filename:join(Work, "telco_stp"),
    RelFile = RelBase ++ ".rel",
    ok = write_term(RelFile, RelTerm),
    CleanRelBase = filename:join(Work, "telco_stp_clean"),
    ok = write_term(
        CleanRelBase ++ ".rel",
        {
            release,
            {"telco_stp_clean", ReleaseVsn},
            {erts, ErtsVsn},
            lists:sublist(ReleaseApps, 2)
        }
    ),
    ok = copy_file(SysConfig, filename:join(Work, "sys.config")),
    ok = make_boot(RelBase, WorkEbin),
    ok = make_clean_boot(CleanRelBase, Work),
    ok = make_package(RelBase, WorkEbin, Work),
    TarFile = filename:join(Work, "telco_stp.tar.gz"),
    ok = require_file(TarFile),
    ok = ensure_directory(OutputRoot),
    ok = extract_package(TarFile, OutputRoot),
    ReleaseDir = filename:join([
        OutputRoot, "releases", ReleaseVsn
    ]),
    ReleasesDir = filename:join(OutputRoot, "releases"),
    InstalledRel = filename:join(ReleaseDir, "telco_stp.rel"),
    ok = require_file(InstalledRel),
    ok = copy_file(
        TarFile,
        filename:join(
            ReleasesDir,
            "telco_stp-" ++ ReleaseVsn ++ ".tar.gz"
        )
    ),
    ok = copy_files([
        {
            filename:join(Work, "telco_stp.script"),
            filename:join(ReleaseDir, "start.script")
        },
        {
            filename:join(Work, "start_clean.boot"),
            filename:join(ReleaseDir, "start_clean.boot")
        },
        {
            filename:join(Work, "start_clean.script"),
            filename:join(ReleaseDir, "start_clean.script")
        },
        {VmArgs, filename:join(ReleaseDir, "vm.args")},
        {Launcher, filename:join([OutputRoot, "bin", "telco_stp"])}
    ]),
    ok = make_executable(
        filename:join([OutputRoot, "bin", "telco_stp"])
    ),
    ok = file:write_file(
        filename:join(ReleasesDir, "start_erl.data"),
        [ErtsVsn, " ", ReleaseVsn, "\n"]
    ),
    ok = release_handler:create_RELEASES(
        ReleasesDir, InstalledRel, []
    ),
    ok = write_term(
        filename:join(ReleaseDir, "BUILD_INFO"),
        #{
            release_name => telco_stp,
            release_version => ReleaseVsn,
            application_version => AppVsn,
            erts_version => ErtsVsn,
            otp_release => erlang:system_info(otp_release),
            applications => ReleaseApps
        }
    ),
    ok = verify_target(OutputRoot, ReleaseVsn, AppVsn, ErtsVsn),
    io:format(
        "Built complete OTP release telco_stp-~s at ~s~n",
        [ReleaseVsn, OutputRoot]
    ),
    ok.

application_entry(Application) ->
    case application:load(Application) of
        ok -> ok;
        {error, {already_loaded, Application}} -> ok
    end,
    {ok, Vsn} = application:get_key(Application, vsn),
    {Application, Vsn}.

application_version(AppFile) ->
    case file:consult(AppFile) of
        {ok, [{application, telco_stp, Properties}]} ->
            {ok, proplists:get_value(vsn, Properties)};
        Error ->
            error({invalid_application_resource, AppFile, Error})
    end.

verify_application_modules(AppEbin) ->
    AppFile = filename:join(AppEbin, "telco_stp.app"),
    {ok, [{application, telco_stp, Properties}]} = file:consult(AppFile),
    ListedModules = [
        atom_to_list(Module)
        || Module <- proplists:get_value(modules, Properties, [])
    ],
    {ok, Entries} = file:list_dir(AppEbin),
    BeamModules = [
        filename:basename(Name, ".beam")
        || Name <- Entries,
           filename:extension(Name) =:= ".beam"
    ],
    MissingFromApp = lists:sort(BeamModules -- ListedModules),
    MissingBeam = lists:sort(ListedModules -- BeamModules),
    case {MissingFromApp, MissingBeam} of
        {[], []} ->
            ok;
        _ ->
            error({
                application_modules_mismatch,
                [
                    {missing_from_app, MissingFromApp},
                    {missing_beam, MissingBeam}
                ]
            })
    end.

make_boot(RelBase, AppEbin) ->
    case systools:make_script(
        RelBase,
        [
            {path, [AppEbin]},
            silent,
            no_dot_erlang,
            warnings_as_errors
        ]
    ) of
        {ok, _Module, []} -> ok;
        {ok, Module, Warnings} ->
            error({boot_script_warnings, Module, Warnings});
        {error, Module, Reason} ->
            error({boot_script_error, Module, Reason})
    end.

make_clean_boot(RelBase, Work) ->
    case systools:make_script(
        RelBase,
        [
            {script_name, "start_clean"},
            {outdir, Work},
            silent,
            no_dot_erlang,
            no_warn_sasl,
            warnings_as_errors
        ]
    ) of
        {ok, _Module, []} -> ok;
        {ok, Module, Warnings} ->
            error({clean_boot_script_warnings, Module, Warnings});
        {error, Module, Reason} ->
            error({clean_boot_script_error, Module, Reason})
    end.

make_package(RelBase, AppEbin, Work) ->
    case systools:make_tar(
        RelBase,
        [
            {path, [AppEbin]},
            {erts, code:root_dir()},
            erts_all,
            silent,
            warnings_as_errors,
            {outdir, Work}
        ]
    ) of
        {ok, _Module, []} -> ok;
        {ok, Module, Warnings} ->
            error({release_package_warnings, Module, Warnings});
        {error, Module, Reason} ->
            error({release_package_error, Module, Reason})
    end.

extract_package(TarFile, OutputRoot) ->
    case erl_tar:extract(
        TarFile, [compressed, {cwd, OutputRoot}]
    ) of
        ok -> ok;
        {error, Reason} -> error({release_extract_failed, Reason})
    end.

copy_ebin(Source, Destination) ->
    {ok, Entries} = file:list_dir(Source),
    Files = [
        Name
        || Name <- Entries,
           lists:member(
               filename:extension(Name),
               [".app", ".appup", ".beam"]
           )
    ],
    true = Files =/= [],
    lists:foreach(
        fun(Name) ->
            ok = copy_file(
                filename:join(Source, Name),
                filename:join(Destination, Name)
            )
        end,
        Files
    ),
    ok.

copy_file(Source, Destination) ->
    ok = filelib:ensure_dir(Destination),
    case file:copy(Source, Destination) of
        {ok, _Bytes} -> ok;
        {error, Reason} ->
            error({copy_failed, Source, Destination, Reason})
    end.

copy_files(Files) ->
    lists:foreach(
        fun({Source, Destination}) ->
            ok = copy_file(Source, Destination)
        end,
        Files
    ).

write_term(Path, Term) ->
    ok = filelib:ensure_dir(Path),
    file:write_file(Path, io_lib:format("~p.~n", [Term])).

make_executable(Path) ->
    case os:type() of
        {unix, _} -> file:change_mode(Path, 8#755);
        {win32, _} -> ok
    end.

verify_target(Root, ReleaseVsn, AppVsn, ErtsVsn) ->
    Required = [
        filename:join([Root, "bin", "telco_stp"]),
        filename:join([Root, "erts-" ++ ErtsVsn, "bin"]),
        filename:join([Root, "lib", "telco_stp-" ++ AppVsn, "ebin",
                       "telco_stp.app"]),
        filename:join([Root, "releases", "RELEASES"]),
        filename:join([Root, "releases", "start_erl.data"]),
        filename:join([Root, "releases", ReleaseVsn, "telco_stp.rel"]),
        filename:join([Root, "releases", ReleaseVsn, "start.boot"]),
        filename:join([Root, "releases", ReleaseVsn, "start.script"]),
        filename:join([Root, "releases", ReleaseVsn, "start_clean.boot"]),
        filename:join([Root, "releases", ReleaseVsn, "start_clean.script"]),
        filename:join([Root, "releases", ReleaseVsn, "sys.config"]),
        filename:join([Root, "releases", ReleaseVsn, "vm.args"]),
        filename:join([
            Root, "releases", "telco_stp-" ++ ReleaseVsn ++ ".tar.gz"
        ])
    ],
    lists:foreach(fun require_file_or_directory/1, Required),
    ok.

require_file_or_directory(Path) ->
    case filelib:is_file(Path) orelse filelib:is_dir(Path) of
        true -> ok;
        false -> error({missing_release_artifact, Path})
    end.

require_file(Path) ->
    case filelib:is_regular(Path) of
        true -> ok;
        false -> error({missing_required_file, Path})
    end.

require_empty_output(Path) ->
    case file:list_dir(Path) of
        {error, enoent} -> ok;
        {ok, []} -> ok;
        {ok, _} -> error({output_not_empty, Path});
        {error, Reason} -> error({output_unavailable, Path, Reason})
    end.

require_absent(Path) ->
    case file:read_file_info(Path) of
        {error, enoent} -> ok;
        {ok, _} -> error({path_already_exists, Path});
        {error, Reason} -> error({path_unavailable, Path, Reason})
    end.

ensure_directory(Path) ->
    filelib:ensure_dir(filename:join(Path, "placeholder")).

safe_version([]) ->
    false;
safe_version(Value) ->
    lists:all(
        fun(Character) ->
            (Character >= $a andalso Character =< $z) orelse
            (Character >= $A andalso Character =< $Z) orelse
            (Character >= $0 andalso Character =< $9) orelse
            lists:member(Character, "._-")
        end,
        Value
    ).
