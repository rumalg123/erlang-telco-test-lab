-module(telco_stp_scmg).
-behaviour(gen_server).

-include("telco_stp.hrl").

-export([
    start_link/0,
    encode/2,
    decode/2,
    ingest/3,
    set_state/5,
    states/0,
    path_constraints/1
]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

encode(Message, Variant) ->
    try
        {ok, encode_message(Message, Variant)}
    catch
        error:Reason -> {error, Reason}
    end.

decode(Binary, Variant) ->
    try
        {ok, decode_message(Binary, Variant)}
    catch
        error:Reason -> {error, Reason}
    end.

ingest(SourceLink, MtpMessage, SccpMessage) ->
    gen_server:call(
        ?MODULE, {ingest, SourceLink, MtpMessage, SccpMessage}
    ).

set_state(SourceLink, PointCode, Ssn, Status, Metadata) ->
    gen_server:call(
        ?MODULE,
        {set_state, SourceLink, PointCode, Ssn, Status, Metadata}
    ).

states() ->
    gen_server:call(?MODULE, states).

path_constraints(Message) ->
    gen_server:call(?MODULE, {path_constraints, Message}).

init([]) ->
    {ok, #{states => #{}}}.

handle_call(
    {ingest, SourceLink, MtpMessage, SccpMessage},
    _From,
    #{states := States} = State
) ->
    case management_payload(SccpMessage) of
        not_management ->
            {reply, not_management, State};
        {ok, Payload} ->
            Variant = maps:get(sccp_variant, MtpMessage, itu),
            case decode(Payload, Variant) of
                {ok, Scmg} ->
                    NetworkAppearance = maps:get(
                        network_appearance, MtpMessage, any
                    ),
                    {Reply, Updated} = process_management(
                        SourceLink,
                        NetworkAppearance,
                        Scmg,
                        States
                    ),
                    {reply, {ok, Scmg, Reply}, State#{states => Updated}};
                {error, Reason} ->
                    {reply, {error, {malformed_scmg, Reason}}, State}
            end
    end;
handle_call(
    {set_state, SourceLink, PointCode, Ssn, Status, Metadata},
    _From,
    #{states := States} = State
) ->
    case validate_state(PointCode, Ssn, Status, Metadata) of
        ok ->
            NetworkAppearance = maps:get(
                network_appearance, Metadata, any
            ),
            Entry = Metadata#{
                source_link => SourceLink,
                point_code => PointCode,
                ssn => Ssn,
                status => Status,
                network_appearance => NetworkAppearance,
                updated_at => erlang:system_time(millisecond)
            },
            Key = {SourceLink, NetworkAppearance, PointCode, Ssn},
            emit_alarm(Entry),
            {reply, ok, State#{states => States#{Key => Entry}}};
        Error ->
            {reply, Error, State}
    end;
handle_call(states, _From, #{states := States} = State) ->
    {reply, maps:values(States), State};
handle_call(
    {path_constraints, Message}, _From,
    #{states := States} = State
) ->
    {reply, constraints(Message, maps:values(States)), State};
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported}, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

encode_message(#{
    type := Type,
    affected_ssn := Ssn,
    affected_point_code := PointCode
} = Message, Variant) ->
    TypeCode = type_code(Type),
    SsnValue = uint(Ssn, 8, affected_ssn),
    PointCodePart = encode_point_code(PointCode, Variant),
    Smi = uint(maps:get(multiplicity, Message, 0), 2, multiplicity),
    Base = <<TypeCode:8, SsnValue:8, PointCodePart/binary, Smi:8>>,
    case Type of
        ssc ->
            Congestion = maps:get(congestion_level, Message),
            <<Base/binary, (range(
                Congestion, 1, 8, congestion_level
            )):8>>;
        _ ->
            Base
    end;
encode_message(Message, Variant) ->
    error({invalid_scmg_message, Message, Variant}).

decode_message(Binary, itu) ->
    decode_itu(Binary);
decode_message(Binary, ansi) ->
    decode_ansi(Binary);
decode_message(_Binary, Variant) ->
    error({invalid_sccp_variant, Variant}).

decode_itu(<<TypeCode:8, Ssn:8, PointCode:16/little, Smi:8>>)
        when PointCode =< 16#3fff ->
    decode_fields(TypeCode, Ssn, PointCode, Smi, undefined);
decode_itu(<<
    TypeCode:8, Ssn:8, PointCode:16/little, Smi:8, Congestion:8
>>) when PointCode =< 16#3fff ->
    decode_fields(
        TypeCode, Ssn, PointCode, Smi, Congestion
    );
decode_itu(Binary) ->
    error({invalid_scmg_length, itu, byte_size(Binary)}).

decode_ansi(<<TypeCode:8, Ssn:8, PointCode:24/little, Smi:8>>) ->
    decode_fields(TypeCode, Ssn, PointCode, Smi, undefined);
decode_ansi(<<
    TypeCode:8, Ssn:8, PointCode:24/little, Smi:8, Congestion:8
>>) ->
    decode_fields(TypeCode, Ssn, PointCode, Smi, Congestion);
decode_ansi(Binary) ->
    error({invalid_scmg_length, ansi, byte_size(Binary)}).

decode_fields(TypeCode, Ssn, PointCode, Smi, Congestion) ->
    Type = type_name(TypeCode),
    true = Smi =< 3 orelse error({invalid_scmg_multiplicity, Smi}),
    Base = #{
        type => Type,
        affected_ssn => Ssn,
        affected_point_code => PointCode,
        multiplicity => Smi
    },
    case {Type, Congestion} of
        {ssc, Level} when is_integer(Level), Level >= 1, Level =< 8 ->
            Base#{congestion_level => Level};
        {ssc, Level} ->
            error({invalid_scmg_congestion, Level});
        {_Other, undefined} ->
            Base;
        {_Other, _Unexpected} ->
            error({unexpected_scmg_congestion, Type})
    end.

management_payload(#{
    called_party := #{routing_indicator := ssn, ssn := 1},
    data := Payload
}) when is_binary(Payload) ->
    {ok, Payload};
management_payload(_SccpMessage) ->
    not_management.

process_management(
    SourceLink, NetworkAppearance, Scmg, States
) ->
    Type = maps:get(type, Scmg),
    case Type of
        sst ->
            {
                {reply, status_reply(NetworkAppearance, Scmg, States)},
                States
            };
        _ ->
            Entry = scmg_entry(
                SourceLink, NetworkAppearance, Scmg
            ),
            Key = {
                SourceLink,
                NetworkAppearance,
                maps:get(point_code, Entry),
                maps:get(ssn, Entry)
            },
            emit_alarm(Entry),
            {none, States#{Key => Entry}}
    end.

scmg_entry(SourceLink, NetworkAppearance, Scmg) ->
    Type = maps:get(type, Scmg),
    Base = #{
        source_link => SourceLink,
        network_appearance => NetworkAppearance,
        point_code => maps:get(affected_point_code, Scmg),
        ssn => maps:get(affected_ssn, Scmg),
        multiplicity => maps:get(multiplicity, Scmg),
        status => status_for_type(Type),
        management_type => Type,
        updated_at => erlang:system_time(millisecond)
    },
    case maps:find(congestion_level, Scmg) of
        {ok, Level} -> Base#{congestion_level => Level};
        error -> Base
    end.

status_reply(NetworkAppearance, Scmg, States) ->
    PointCode = maps:get(affected_point_code, Scmg),
    Ssn = maps:get(affected_ssn, Scmg),
    LocalStatus =
        case maps:find(
            {local, NetworkAppearance, PointCode, Ssn}, States
        ) of
            {ok, Entry} -> maps:get(status, Entry);
            error ->
                case maps:find(
                    {local, any, PointCode, Ssn}, States
                ) of
                    {ok, Entry} -> maps:get(status, Entry);
                    error -> prohibited
                end
        end,
    Type =
        case LocalStatus of
            available -> ssa;
            _ -> ssp
        end,
    Scmg#{type => Type}.

constraints(Message, Entries) ->
    case {
        maps:find(sccp_called_point_code, Message),
        maps:find(sccp_called_ssn, Message)
    } of
        {{ok, PointCode}, {ok, Ssn}} ->
            NetworkAppearance = maps:get(
                network_appearance, Message, any
            ),
            Matching = [
                Entry
                || Entry <- Entries,
                   maps:get(point_code, Entry) =:= PointCode,
                   maps:get(ssn, Entry) =:= Ssn,
                   network_appearance_matches(
                       NetworkAppearance,
                       maps:get(network_appearance, Entry)
                   )
            ],
            #{
                unavailable => lists:usort([
                    maps:get(source_link, Entry)
                    || Entry <- Matching,
                       lists:member(
                           maps:get(status, Entry),
                           [
                               prohibited,
                               out_of_service_requested,
                               out_of_service
                           ]
                       )
                ]),
                congestion => maps:from_list([
                    {
                        maps:get(source_link, Entry),
                        scmg_congestion_to_m3ua(
                            maps:get(congestion_level, Entry, 1)
                        )
                    }
                    || Entry <- Matching,
                       maps:get(status, Entry) =:= congested
                ])
            };
        _ ->
            #{unavailable => [], congestion => #{}}
    end.

validate_state(PointCode, Ssn, Status, Metadata) ->
    case is_integer(PointCode) andalso PointCode >= 0 andalso
         PointCode =< ?STP_POINT_CODE_MASK_24 andalso
         is_integer(Ssn) andalso Ssn >= 0 andalso Ssn =< 255 andalso
         lists:member(
             Status,
             [
                 available,
                 prohibited,
                 congested,
                 out_of_service_requested,
                 out_of_service
             ]
         ) andalso is_map(Metadata) of
        true -> ok;
        false ->
            {error, {
                invalid_subsystem_state,
                PointCode, Ssn, Status, Metadata
            }}
    end.

emit_alarm(#{source_link := Source, point_code := Pc, ssn := Ssn,
             status := available} = Entry) ->
    telco_stp_alarm:clear(
        {subsystem, Source, Pc, Ssn}, Entry
    );
emit_alarm(#{source_link := Source, point_code := Pc, ssn := Ssn,
             status := congested} = Entry) ->
    telco_stp_alarm:raise(
        {subsystem, Source, Pc, Ssn}, minor, Entry
    );
emit_alarm(#{source_link := Source, point_code := Pc, ssn := Ssn} = Entry) ->
    telco_stp_alarm:raise(
        {subsystem, Source, Pc, Ssn}, major, Entry
    ).

status_for_type(ssa) -> available;
status_for_type(ssp) -> prohibited;
status_for_type(ssc) -> congested;
status_for_type(sor) -> out_of_service_requested;
status_for_type(sog) -> out_of_service.

type_code(ssa) -> 1;
type_code(ssp) -> 2;
type_code(sst) -> 3;
type_code(sor) -> 4;
type_code(sog) -> 5;
type_code(ssc) -> 6;
type_code(Type) -> error({invalid_scmg_type, Type}).

type_name(1) -> ssa;
type_name(2) -> ssp;
type_name(3) -> sst;
type_name(4) -> sor;
type_name(5) -> sog;
type_name(6) -> ssc;
type_name(Type) -> error({invalid_scmg_type, Type}).

encode_point_code(PointCode, itu) ->
    <<(uint(PointCode, 14, affected_point_code)):16/little>>;
encode_point_code(PointCode, ansi) ->
    <<(uint(PointCode, 24, affected_point_code)):24/little>>;
encode_point_code(_PointCode, Variant) ->
    error({invalid_sccp_variant, Variant}).

scmg_congestion_to_m3ua(Level) when Level >= 7 -> 3;
scmg_congestion_to_m3ua(Level) when Level >= 4 -> 2;
scmg_congestion_to_m3ua(_Level) -> 1.

network_appearance_matches(any, _Value) -> true;
network_appearance_matches(_Value, any) -> true;
network_appearance_matches(Value, Value) -> true;
network_appearance_matches(_A, _B) -> false.

uint(Value, Bits, Name) ->
    range(Value, 0, (1 bsl Bits) - 1, Name).

range(Value, Min, Max, _Name)
        when is_integer(Value), Value >= Min, Value =< Max ->
    Value;
range(Value, _Min, _Max, Name) ->
    error({invalid_integer, Name, Value}).
