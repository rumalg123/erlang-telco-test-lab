-module(telco_stp_mgmt).
-behaviour(gen_server).

-include("telco_stp.hrl").

-export([start_link/0, execute/2, reload_credentials/0, hash_token/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

execute(Token, Request) ->
    gen_server:call(
        ?MODULE, {execute, Token, Request}, ?STP_DEFAULT_OPERATION_TIMEOUT_MS
    ).

reload_credentials() ->
    gen_server:call(?MODULE, reload_credentials).

hash_token(Token) ->
    crypto:hash(sha256, token_binary(Token)).

init([]) ->
    {ok, #{credentials => load_credentials()}}.

handle_call(reload_credentials, _From, State) ->
    try
        Credentials = load_credentials(),
        {reply, ok, State#{credentials => Credentials}}
    catch
        error:Reason ->
            {reply, {error, Reason}, State}
    end;
handle_call({execute, Token, Request}, _From, State) ->
    case authenticate(Token, maps:get(credentials, State)) of
        {ok, Identity} ->
            execute_authorized(Identity, Request, State);
        {error, Reason} ->
            telco_stp_metrics:increment({management, authentication_failed}),
            _ = telco_stp_audit:record(
                anonymous, authentication, management_api, denied,
                #{reason => Reason}
            ),
            {reply, {error, Reason}, State}
    end;
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported}, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

execute_authorized(Identity, Request, State) ->
    Permission = required_permission(Request),
    case authorized(Permission, maps:get(roles, Identity)) of
        true ->
            Result =
                try dispatch(Request)
                catch
                    Class:Reason ->
                        {error, {management_action_failed, Class, Reason}}
                end,
            telco_stp_metrics:increment({management, request, Permission}),
            _ = telco_stp_audit:record(
                maps:get(id, Identity),
                request_action(Request),
                request_target(Request),
                result_class(Result),
                #{roles => maps:get(roles, Identity)}
            ),
            {reply, Result, State};
        false ->
            telco_stp_metrics:increment({management, authorization_denied}),
            _ = telco_stp_audit:record(
                maps:get(id, Identity),
                request_action(Request),
                request_target(Request),
                denied,
                #{
                    reason => insufficient_role,
                    required_permission => Permission,
                    roles => maps:get(roles, Identity)
                }
            ),
            {reply, {error, forbidden}, State}
    end.

load_credentials() ->
    Credentials = application:get_env(
        ?STP_APP, ?STP_ENV_MANAGEMENT_CREDENTIALS, []
    ),
    true = is_list(Credentials) orelse
        error(invalid_management_credentials),
    lists:map(fun normalize_credential/1, Credentials).

normalize_credential(#{
    id := Id, token_sha256 := Hash, roles := Roles
}) when is_binary(Hash), byte_size(Hash) =:= ?STP_SHA256_BYTES,
        is_list(Roles), Roles =/= [] ->
    true = lists:all(fun valid_role/1, Roles) orelse
        error({invalid_management_roles, Id, Roles}),
    #{id => Id, token_sha256 => Hash, roles => lists:usort(Roles)};
normalize_credential(Credential) ->
    error({invalid_management_credential, Credential}).

authenticate(_Token, []) ->
    {error, management_disabled};
authenticate(Token, Credentials) ->
    try
        Hash = hash_token(Token),
        case [
            Credential
            || Credential <- Credentials,
               secure_equal(
                   Hash, maps:get(token_sha256, Credential)
               )
        ] of
            [Identity] -> {ok, Identity};
            _ -> {error, unauthorized}
        end
    catch
        error:_ -> {error, unauthorized}
    end.

secure_equal(A, B)
        when is_binary(A), is_binary(B), byte_size(A) =:= byte_size(B) ->
    crypto:hash_equals(A, B);
secure_equal(_A, _B) ->
    false.

token_binary(Token) when is_binary(Token), byte_size(Token) >= 16 ->
    Token;
token_binary(Token) when is_list(Token), length(Token) >= 16 ->
    unicode:characters_to_binary(Token);
token_binary(_Token) ->
    error(invalid_management_token).

valid_role(Role) ->
    maps:is_key(Role, role_permissions()).

authorized(_Permission, Roles) when is_list(Roles) ->
    lists:member(admin, Roles) orelse
    lists:any(
        fun(Role) -> role_allows(Role, _Permission) end,
        Roles
    ).

role_allows(Role, Permission) ->
    lists:member(Permission, maps:get(Role, role_permissions(), [])).

role_permissions() ->
    #{
        viewer => [read],
        operator => [read, operate],
        engineer => [read, operate, configure],
        admin => [read, operate, configure, admin]
    }.

required_permission(status) -> read;
required_permission(links) -> read;
required_permission(listeners) -> read;
required_permission(routes) -> read;
required_permission(gtt_rules) -> read;
required_permission(alarms) -> read;
required_permission(audit_events) -> read;
required_permission(metrics) -> read;
required_permission(rkm_registrations) -> read;
required_permission({set_link_state, _, _}) -> operate;
required_permission({set_link_congestion, _, _}) -> operate;
required_permission({set_destination_state, _, _, _, _}) -> operate;
required_permission({set_subsystem_state, _, _, _, _, _}) -> operate;
required_permission({acknowledge_alarm, _, _}) -> operate;
required_permission({set_fault_profile, _}) -> operate;
required_permission({set_overload_limits, _}) -> operate;
required_permission({add_link, _}) -> configure;
required_permission({remove_link, _}) -> configure;
required_permission({add_listener, _}) -> configure;
required_permission({remove_listener, _}) -> configure;
required_permission({add_route, _}) -> configure;
required_permission({remove_route, _}) -> configure;
required_permission({add_gtt_rule, _}) -> configure;
required_permission({remove_gtt_rule, _}) -> configure;
required_permission({save_configuration, _}) -> configure;
required_permission({load_configuration, _, _}) -> configure;
required_permission(_Request) -> admin.

dispatch(status) -> telco_stp:status();
dispatch(links) -> telco_stp:links();
dispatch(listeners) -> telco_stp:listeners();
dispatch(routes) -> telco_stp:routes();
dispatch(gtt_rules) -> telco_stp:gtt_rules();
dispatch(alarms) -> telco_stp:alarms();
dispatch(audit_events) -> telco_stp_audit:events();
dispatch(metrics) -> telco_stp:metrics();
dispatch(rkm_registrations) -> telco_stp:rkm_registrations();
dispatch({set_link_state, Name, LinkState}) ->
    telco_stp:set_link_state(Name, LinkState);
dispatch({set_link_congestion, Name, Level}) ->
    telco_stp:set_link_congestion(Name, Level);
dispatch({set_destination_state, Link, Status, Affected, Metadata}) ->
    telco_stp:set_destination_state(
        Link, Status, Affected, Metadata
    );
dispatch({set_subsystem_state, Link, Pc, Ssn, Status, Metadata}) ->
    telco_stp:set_subsystem_state(
        Link, Pc, Ssn, Status, Metadata
    );
dispatch({acknowledge_alarm, Id, Operator}) ->
    telco_stp:acknowledge_alarm(Id, Operator);
dispatch({set_fault_profile, Profile}) ->
    telco_stp:set_fault_profile(Profile);
dispatch({set_overload_limits, Limits}) ->
    telco_stp:set_overload_limits(Limits);
dispatch({add_link, Config}) -> telco_stp:add_link(Config);
dispatch({remove_link, Name}) -> telco_stp:remove_link(Name);
dispatch({add_listener, Config}) -> telco_stp:add_listener(Config);
dispatch({remove_listener, Name}) -> telco_stp:remove_listener(Name);
dispatch({add_route, Route}) -> telco_stp:add_route(Route);
dispatch({remove_route, Id}) -> telco_stp:remove_route(Id);
dispatch({add_gtt_rule, Rule}) -> telco_stp:add_gtt_rule(Rule);
dispatch({remove_gtt_rule, Id}) -> telco_stp:remove_gtt_rule(Id);
dispatch({save_configuration, Path}) ->
    telco_stp:save_configuration(Path);
dispatch({load_configuration, Path, Mode}) ->
    telco_stp:load_configuration(Path, Mode);
dispatch(Request) -> {error, {unsupported_management_request, Request}}.

request_action(Request) when is_atom(Request) -> Request;
request_action(Request) when is_tuple(Request), tuple_size(Request) > 0 ->
    element(1, Request);
request_action(_Request) -> unknown.

request_target({Action, Target}) ->
    {Action, Target};
request_target({Action, Target, _}) ->
    {Action, Target};
request_target({Action, Target, _, _}) ->
    {Action, Target};
request_target({Action, Target, _, _, _}) ->
    {Action, Target};
request_target({Action, Target, _, _, _, _}) ->
    {Action, Target};
request_target(Request) ->
    Request.

result_class({error, Reason}) -> {error, Reason};
result_class(_Result) -> success.
