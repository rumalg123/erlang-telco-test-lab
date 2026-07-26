-module(telco_stp_observability).

-export([prometheus/0, health/0]).

prometheus() ->
    Metrics = telco_stp_metrics:snapshot(),
    Links = telco_stp_link_manager:list(),
    Alarms = telco_stp_alarm:active(),
    Routes = telco_stp_route_table:list(),
    Rkm = telco_stp_rkm:status(),
    Reassembly = telco_stp_reassembly:status(),
    Lines = [
        "# TYPE telco_stp_build_info gauge\n",
        metric(
            <<"telco_stp_build_info">>,
            #{
                otp_release => erlang:system_info(otp_release),
                node => atom_to_binary(node())
            },
            1
        ),
        "# TYPE telco_stp_metric_total counter\n",
        [
            metric(
                <<"telco_stp_metric_total">>,
                #{key => printable(Key)},
                Value
            )
            || {Key, Value} <- lists:sort(maps:to_list(Metrics))
        ],
        "# TYPE telco_stp_link_state gauge\n",
        [
            metric(
                <<"telco_stp_link_state">>,
                #{
                    link => printable(maps:get(name, Link)),
                    state => printable(maps:get(state, Link)),
                    adaptation => printable(
                        maps:get(adaptation, Link, m3ua)
                    )
                },
                1
            )
            || Link <- Links
        ],
        "# TYPE telco_stp_active_alarms gauge\n",
        metric(
            <<"telco_stp_active_alarms">>, #{}, length(Alarms)
        ),
        "# TYPE telco_stp_routes gauge\n",
        metric(<<"telco_stp_routes">>, #{}, length(Routes)),
        "# TYPE telco_stp_rkm_registrations gauge\n",
        metric(
            <<"telco_stp_rkm_registrations">>, #{},
            maps:get(registration_count, Rkm)
        ),
        "# TYPE telco_stp_reassembly_contexts gauge\n",
        metric(
            <<"telco_stp_reassembly_contexts">>, #{},
            maps:get(context_count, Reassembly, 0)
        )
    ],
    iolist_to_binary(Lines).

health() ->
    Links = telco_stp_link_manager:list(),
    Alarms = telco_stp_alarm:active(),
    Critical = [
        Alarm
        || Alarm <- Alarms,
           lists:member(
               maps:get(severity, Alarm), [critical, major]
           )
    ],
    ActiveLinks = length([
        Link || Link <- Links, maps:get(state, Link) =:= active
    ]),
    #{
        status =>
            case Critical of
                [] -> healthy;
                _ -> degraded
            end,
        node => node(),
        otp_release => erlang:system_info(otp_release),
        active_links => ActiveLinks,
        total_links => length(Links),
        active_alarms => length(Alarms),
        critical_or_major_alarms => length(Critical),
        audit_chain => telco_stp_audit:verify(),
        overload => telco_stp_dispatcher:overload_status(),
        timestamp => erlang:system_time(millisecond)
    }.

metric(Name, Labels, Value) ->
    [
        Name,
        encode_labels(Labels),
        " ",
        integer_to_binary(Value),
        "\n"
    ].

encode_labels(Labels) when map_size(Labels) =:= 0 ->
    <<>>;
encode_labels(Labels) ->
    Items = [
        [
            atom_to_binary(Key),
            "=\"",
            escape_label(printable(Value)),
            "\""
        ]
        || {Key, Value} <- lists:sort(maps:to_list(Labels))
    ],
    ["{", lists:join(",", Items), "}"].

printable(Value) when is_binary(Value) ->
    Value;
printable(Value) when is_atom(Value) ->
    atom_to_binary(Value);
printable(Value) when is_list(Value) ->
    unicode:characters_to_binary(Value);
printable(Value) ->
    iolist_to_binary(io_lib:format("~0p", [Value])).

escape_label(Binary) ->
    binary:replace(
        binary:replace(
            binary:replace(Binary, <<"\\">>, <<"\\\\">>, [global]),
            <<"\"">>, <<"\\\"">>, [global]
        ),
        <<"\n">>, <<"\\n">>, [global]
    ).
