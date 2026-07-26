-module(telco_stp).

-export([
    start/0,
    stop/0,
    add_link/1,
    remove_link/1,
    add_listener/1,
    remove_listener/1,
    set_link_state/2,
    set_link_congestion/2,
    set_destination_state/4,
    set_subsystem_state/5,
    add_route/1,
    remove_route/1,
    add_gtt_rule/1,
    remove_gtt_rule/1,
    translate_global_title/1,
    transfer/1,
    load/3,
    inject_m3ua/2,
    inject_m2pa/3,
    retrieve_m2pa/2,
    set_fault_profile/1,
    set_overload_limits/1,
    links/0,
    listeners/0,
    routes/0,
    destination_states/0,
    subsystem_states/0,
    rkm_registrations/0,
    gtt_rules/0,
    reassembly_status/0,
    alarms/0,
    alarm_history/0,
    acknowledge_alarm/2,
    management/2,
    audit_events/0,
    verify_audit/0,
    health/0,
    prometheus/0,
    set_trace/1,
    trace_status/0,
    export_pcapng/1,
    ha_status/0,
    ha_snapshot/0,
    promote_standby/1,
    demote_primary/0,
    export_configuration/0,
    save_configuration/1,
    load_configuration/2,
    metrics/0,
    status/0
]).

-type link_name() :: term().
-type route_id() :: term().
-type transfer() :: #{
    opc := non_neg_integer(),
    dpc := non_neg_integer(),
    si := 0..15,
    ni := 0..3,
    mp := 0..3,
    sls := non_neg_integer(),
    payload := binary(),
    routing_context => [non_neg_integer()],
    network_appearance => non_neg_integer()
}.

-export_type([link_name/0, route_id/0, transfer/0]).

-spec start() -> {ok, [atom()]} | {error, term()}.
start() ->
    application:ensure_all_started(telco_stp).

-spec stop() -> ok | {error, term()}.
stop() ->
    application:stop(telco_stp).

-spec add_link(map()) -> {ok, pid()} | {error, term()}.
add_link(Config) ->
    telco_stp_link_manager:add(Config).

-spec remove_link(link_name()) -> ok | {error, term()}.
remove_link(Name) ->
    telco_stp_link_manager:remove(Name).

-spec add_listener(map()) -> {ok, map()} | {error, term()}.
add_listener(Config) ->
    telco_stp_listener_manager:add(Config).

-spec remove_listener(term()) -> ok | {error, term()}.
remove_listener(Name) ->
    telco_stp_listener_manager:remove(Name).

-spec set_link_state(link_name(), up | down | active | inactive) ->
    ok | {error, term()}.
set_link_state(Name, up) ->
    telco_stp_link_manager:set_admin(Name, up);
set_link_state(Name, down) ->
    telco_stp_link_manager:set_admin(Name, down);
set_link_state(Name, State) when State =:= active; State =:= inactive ->
    telco_stp_link_manager:force_state(Name, State);
set_link_state(_Name, State) ->
    {error, {invalid_link_state, State}}.

-spec set_link_congestion(link_name(), 0..3) -> ok | {error, term()}.
set_link_congestion(Name, Level) ->
    telco_stp_link_manager:set_congestion(Name, Level).

-spec set_destination_state(
    link_name(), available | unavailable | restricted | congested |
    user_unavailable, [{0..255, non_neg_integer()}], map()
) -> ok | {error, term()}.
set_destination_state(SourceLink, Status, Affected, Metadata) ->
    telco_stp_route_table:set_destination_state(
        SourceLink, Status, Affected, Metadata
    ).

-spec set_subsystem_state(
    link_name(), non_neg_integer(), 0..255,
    available | prohibited | congested |
    out_of_service_requested | out_of_service,
    map()
) -> ok | {error, term()}.
set_subsystem_state(SourceLink, PointCode, Ssn, Status, Metadata) ->
    telco_stp_scmg:set_state(
        SourceLink, PointCode, Ssn, Status, Metadata
    ).

-spec add_route(map()) -> ok | {error, term()}.
add_route(Route) ->
    telco_stp_route_table:add(Route).

-spec remove_route(route_id()) -> ok.
remove_route(Id) ->
    telco_stp_route_table:remove(Id).

-spec add_gtt_rule(map()) -> ok | {error, term()}.
add_gtt_rule(Rule) ->
    telco_stp_gtt:add(Rule).

-spec remove_gtt_rule(term()) -> ok.
remove_gtt_rule(Id) ->
    telco_stp_gtt:remove(Id).

-spec translate_global_title(map()) -> {ok, map()} | {error, term()}.
translate_global_title(Address) ->
    telco_stp_gtt:translate(Address).

-spec transfer(transfer()) -> {ok, map()} | {error, term()}.
transfer(Message) ->
    telco_stp_dispatcher:transfer(Message).

-spec load(transfer(), pos_integer(), pos_integer()) ->
    {ok, map()} | {error, term()}.
load(Template, Count, Concurrency) ->
    telco_stp_load:run(Template, Count, Concurrency).

-spec inject_m3ua(link_name(), binary()) -> ok | {error, term()}.
inject_m3ua(Link, Binary) ->
    telco_stp_link_manager:inject(Link, Binary).

-spec inject_m2pa(link_name(), non_neg_integer(), binary()) ->
    ok | {error, term()}.
inject_m2pa(Link, Stream, Binary) ->
    telco_stp_link_manager:inject(
        Link, Binary, #{stream => Stream, ppid => 5}
    ).

-spec retrieve_m2pa(link_name(), undefined | non_neg_integer()) ->
    {ok, [map()]} | {error, term()}.
retrieve_m2pa(Link, AfterFsn) ->
    telco_stp_link_manager:retrieve_m2pa(Link, AfterFsn).

-spec set_fault_profile(map()) -> ok | {error, term()}.
set_fault_profile(Profile) ->
    telco_stp_dispatcher:set_fault_profile(Profile).

-spec set_overload_limits(map()) -> ok | {error, term()}.
set_overload_limits(Limits) ->
    telco_stp_dispatcher:set_overload_limits(Limits).

-spec links() -> [map()].
links() ->
    telco_stp_link_manager:list().

-spec listeners() -> [map()].
listeners() ->
    telco_stp_listener_manager:list().

-spec routes() -> [map()].
routes() ->
    telco_stp_route_table:list().

-spec destination_states() -> [map()].
destination_states() ->
    telco_stp_route_table:destination_states().

-spec subsystem_states() -> [map()].
subsystem_states() ->
    telco_stp_scmg:states().

-spec rkm_registrations() -> [map()].
rkm_registrations() ->
    telco_stp_rkm:registrations().

-spec gtt_rules() -> [map()].
gtt_rules() ->
    telco_stp_gtt:list().

-spec reassembly_status() -> map().
reassembly_status() ->
    telco_stp_reassembly:status().

-spec alarms() -> [map()].
alarms() ->
    telco_stp_alarm:active().

-spec alarm_history() -> [map()].
alarm_history() ->
    telco_stp_alarm:history().

-spec acknowledge_alarm(term(), term()) -> ok | {error, term()}.
acknowledge_alarm(Id, Operator) ->
    telco_stp_alarm:acknowledge(Id, Operator).

-spec management(binary() | string(), term()) -> term().
management(Token, Request) ->
    telco_stp_mgmt:execute(Token, Request).

-spec audit_events() -> [map()].
audit_events() ->
    telco_stp_audit:events().

-spec verify_audit() -> ok | {error, term()}.
verify_audit() ->
    telco_stp_audit:verify().

-spec health() -> map().
health() ->
    telco_stp_observability:health().

-spec prometheus() -> binary().
prometheus() ->
    telco_stp_observability:prometheus().

-spec set_trace(map()) -> ok | {error, term()}.
set_trace(Config) ->
    telco_stp_trace:configure(Config).

-spec trace_status() -> map().
trace_status() ->
    telco_stp_trace:status().

-spec export_pcapng(file:filename_all()) ->
    {ok, map()} | {error, term()}.
export_pcapng(Path) ->
    telco_stp_trace:export_pcapng(Path).

-spec ha_status() -> map().
ha_status() ->
    telco_stp_ha:status().

-spec ha_snapshot() -> {ok, map()} | {error, term()}.
ha_snapshot() ->
    telco_stp_ha:snapshot_now().

-spec promote_standby(binary() | string()) ->
    {ok, map()} | {error, term()}.
promote_standby(FencingToken) ->
    telco_stp_ha:promote(FencingToken).

-spec demote_primary() -> ok | {error, term()}.
demote_primary() ->
    telco_stp_ha:demote().

-spec export_configuration() -> map().
export_configuration() ->
    telco_stp_config:export().

-spec save_configuration(file:filename_all()) ->
    {ok, map()} | {error, term()}.
save_configuration(Path) ->
    telco_stp_config:save(Path).

-spec load_configuration(file:filename_all(), merge | replace) ->
    {ok, map()} | {error, term()}.
load_configuration(Path, Mode) ->
    telco_stp_config:load(Path, Mode).

-spec metrics() -> map().
metrics() ->
    telco_stp_metrics:snapshot().

-spec status() -> map().
status() ->
    #{
        application => telco_stp,
        otp_release => erlang:system_info(otp_release),
        links => links(),
        listeners => listeners(),
        routes => routes(),
        destination_states => destination_states(),
        subsystem_states => subsystem_states(),
        rkm => telco_stp_rkm:status(),
        gtt_rules => gtt_rules(),
        reassembly => reassembly_status(),
        alarms => alarms(),
        audit_chain => verify_audit(),
        health => health(),
        trace => trace_status(),
        ha => ha_status(),
        overload => telco_stp_dispatcher:overload_status(),
        fault_profile => telco_stp_dispatcher:fault_profile(),
        metrics => metrics()
    }.
