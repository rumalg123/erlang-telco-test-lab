-module(telco_stp_m3ua).

-include("telco_stp.hrl").

-export([
    encode/1,
    decode/1,
    encode_data/1,
    protocol_data/1
]).

-type message_class() :: management | transfer | ssnm | aspsm | asptm | rkm.
-type message() :: #{
    class := message_class() | non_neg_integer(),
    type := atom() | non_neg_integer(),
    params => map() | list()
}.

-export_type([message/0]).

-spec encode(message()) -> {ok, binary()} | {error, term()}.
encode(#{class := Class0, type := Type0} = Message) ->
    try
        Class = class_id(Class0),
        Type = type_id(Class0, Type0),
        Params = encode_params(maps:get(params, Message, #{})),
        Length = 8 + byte_size(Params),
        {ok, <<?STP_M3UA_VERSION:8, 0:8, Class:8, Type:8,
               Length:32/big, Params/binary>>}
    catch
        error:Reason ->
            {error, Reason}
    end;
encode(Message) ->
    {error, {invalid_m3ua_message, Message}}.

-spec decode(binary()) -> {ok, message()} | {error, term()}.
decode(<<?STP_M3UA_VERSION:8, _Reserved:8, ClassId:8, TypeId:8, Length:32/big,
         Rest/binary>> = Binary)
        when Length >= 8 ->
    try
        case byte_size(Binary) of
            Length ->
                case decode_params(Rest, #{unknown => []}) of
                    {ok, Params} ->
                        Class = class_name(ClassId),
                        {ok, #{
                            class => Class,
                            type => type_name(ClassId, TypeId),
                            params => tidy_unknown(Params),
                            raw_class => ClassId,
                            raw_type => TypeId,
                            raw_message => Binary
                        }};
                    Error ->
                        Error
                end;
            Actual ->
                {error, {invalid_message_length, Length, Actual}}
        end
    catch
        error:Reason ->
            {error, Reason}
    end;
decode(<<Version:8, _/binary>>) when Version =/= ?STP_M3UA_VERSION ->
    {error, {unsupported_version, Version}};
decode(Binary) when is_binary(Binary) ->
    {error, {truncated_m3ua_header, byte_size(Binary)}};
decode(Value) ->
    {error, {not_binary, Value}}.

-spec encode_data(map()) -> {ok, binary()} | {error, term()}.
encode_data(Message) ->
    try
        ProtocolData = protocol_data(Message),
        Base = #{protocol_data => ProtocolData},
        WithRc =
            case maps:find(routing_context, Message) of
                {ok, Rc} -> Base#{routing_context => Rc};
                error -> Base
            end,
        Params =
            case maps:find(network_appearance, Message) of
                {ok, Na} -> WithRc#{network_appearance => Na};
                error -> WithRc
            end,
        encode(#{class => transfer, type => data, params => Params})
    catch
        error:Reason ->
            {error, Reason}
    end.

-spec protocol_data(map()) -> map().
protocol_data(Message) ->
    Required = [opc, dpc, si, ni, mp, sls, payload],
    lists:foreach(
        fun(Key) ->
            case maps:is_key(Key, Message) of
                true -> ok;
                false -> error({missing_protocol_data_field, Key})
            end
        end,
        Required
    ),
    Opc = uint(maps:get(opc, Message), 32, opc),
    Dpc = uint(maps:get(dpc, Message), 32, dpc),
    Si = uint(maps:get(si, Message), 8, si),
    Ni = uint(maps:get(ni, Message), 8, ni),
    Mp = uint(maps:get(mp, Message), 8, mp),
    Sls = uint(maps:get(sls, Message), 8, sls),
    Payload = maps:get(payload, Message),
    true = is_binary(Payload) orelse error({invalid_payload, Payload}),
    #{opc => Opc, dpc => Dpc, si => Si, ni => Ni, mp => Mp, sls => Sls,
      payload => Payload}.

encode_params(Params) when is_map(Params) ->
    KnownOrder = [
        network_appearance,
        routing_context,
        protocol_data,
        correlation_id,
        affected_point_code,
        concerned_destination,
        congestion_indications,
        user_cause,
        traffic_mode_type,
        asp_identifier,
        heartbeat_data,
        info_string,
        error_code,
        status,
        diagnostic_information,
        routing_keys,
        registration_results,
        deregistration_results
    ],
    Known = [
        encode_param(Key, maps:get(Key, Params))
        || Key <- KnownOrder, maps:is_key(Key, Params)
    ],
    Unknown = [
        encode_tlv(Tag, Value)
        || {Tag, Value} <- maps:get(unknown, Params, [])
    ],
    iolist_to_binary(Known ++ Unknown);
encode_params(Params) when is_list(Params) ->
    iolist_to_binary([encode_param(Key, Value) || {Key, Value} <- Params]);
encode_params(Params) ->
    error({invalid_m3ua_parameters, Params}).

encode_param(network_appearance, Value) ->
    encode_tlv(
        ?STP_M3UA_PARAM_NETWORK_APPEARANCE,
        <<(uint(Value, 32, network_appearance)):32/big>>
    );
encode_param(routing_context, Values) when is_list(Values), Values =/= [] ->
    Value = << <<(uint(Item, 32, routing_context)):32/big>> || Item <- Values >>,
    encode_tlv(?STP_M3UA_PARAM_ROUTING_CONTEXT, Value);
encode_param(protocol_data, Data) when is_map(Data) ->
    Opc = uint(maps:get(opc, Data), 32, opc),
    Dpc = uint(maps:get(dpc, Data), 32, dpc),
    Si = uint(maps:get(si, Data), 8, si),
    Ni = uint(maps:get(ni, Data), 8, ni),
    Mp = uint(maps:get(mp, Data), 8, mp),
    Sls = uint(maps:get(sls, Data), 8, sls),
    Payload = maps:get(payload, Data),
    true = is_binary(Payload) orelse error({invalid_payload, Payload}),
    encode_tlv(?STP_M3UA_PARAM_PROTOCOL_DATA, <<
        Opc:32/big, Dpc:32/big, Si:8, Ni:8, Mp:8, Sls:8, Payload/binary
    >>);
encode_param(correlation_id, Value) ->
    encode_tlv(
        ?STP_M3UA_PARAM_CORRELATION_ID,
        <<(uint(Value, 32, correlation_id)):32/big>>
    );
encode_param(affected_point_code, Values) when is_list(Values), Values =/= [] ->
    Value = <<
        <<(uint(Mask, 8, mask)):8, (uint(PointCode, 24, point_code)):24/big>>
        || {Mask, PointCode} <- Values
    >>,
    encode_tlv(?STP_M3UA_PARAM_AFFECTED_POINT_CODE, Value);
encode_param(concerned_destination, PointCode) ->
    encode_tlv(
        ?STP_M3UA_PARAM_CONCERNED_DESTINATION,
        <<0:8, (uint(PointCode, 24, concerned_destination)):24/big>>
    );
encode_param(congestion_indications, Level) ->
    encode_tlv(
        ?STP_M3UA_PARAM_CONGESTION_INDICATIONS,
        <<0:24, (uint(Level, 8, congestion_indications)):8>>
    );
encode_param(user_cause, {Cause, User}) ->
    encode_tlv(?STP_M3UA_PARAM_USER_CAUSE, <<
        (uint(Cause, 16, cause)):16/big,
        (uint(User, 16, user)):16/big
    >>);
encode_param(traffic_mode_type, override) ->
    encode_param(traffic_mode_type, 1);
encode_param(traffic_mode_type, loadshare) ->
    encode_param(traffic_mode_type, 2);
encode_param(traffic_mode_type, broadcast) ->
    encode_param(traffic_mode_type, 3);
encode_param(traffic_mode_type, Value) ->
    encode_tlv(
        ?STP_M3UA_PARAM_TRAFFIC_MODE_TYPE,
        <<(uint(Value, 32, traffic_mode_type)):32/big>>
    );
encode_param(asp_identifier, Value) ->
    encode_tlv(
        ?STP_M3UA_PARAM_ASP_IDENTIFIER,
        <<(uint(Value, 32, asp_identifier)):32/big>>
    );
encode_param(heartbeat_data, Value) when is_binary(Value) ->
    encode_tlv(?STP_M3UA_PARAM_HEARTBEAT_DATA, Value);
encode_param(info_string, Value) when is_binary(Value) ->
    encode_tlv(?STP_M3UA_PARAM_INFO_STRING, Value);
encode_param(error_code, invalid_version) ->
    encode_param(error_code, 16#01);
encode_param(error_code, unsupported_message_class) ->
    encode_param(error_code, 16#03);
encode_param(error_code, unsupported_message_type) ->
    encode_param(error_code, 16#04);
encode_param(error_code, unsupported_traffic_mode) ->
    encode_param(error_code, 16#05);
encode_param(error_code, unexpected_message) ->
    encode_param(error_code, 16#06);
encode_param(error_code, protocol_error) ->
    encode_param(error_code, 16#07);
encode_param(error_code, invalid_stream_identifier) ->
    encode_param(error_code, 16#09);
encode_param(error_code, management_blocking) ->
    encode_param(error_code, 16#0d);
encode_param(error_code, asp_identifier_required) ->
    encode_param(error_code, 16#0e);
encode_param(error_code, invalid_asp_identifier) ->
    encode_param(error_code, 16#0f);
encode_param(error_code, invalid_parameter_value) ->
    encode_param(error_code, 16#11);
encode_param(error_code, parameter_field_error) ->
    encode_param(error_code, 16#12);
encode_param(error_code, unexpected_parameter) ->
    encode_param(error_code, 16#13);
encode_param(error_code, destination_status_unknown) ->
    encode_param(error_code, 16#14);
encode_param(error_code, invalid_network_appearance) ->
    encode_param(error_code, 16#15);
encode_param(error_code, missing_parameter) ->
    encode_param(error_code, 16#16);
encode_param(error_code, invalid_routing_context) ->
    encode_param(error_code, 16#19);
encode_param(error_code, no_configured_as) ->
    encode_param(error_code, 16#1a);
encode_param(error_code, Value) ->
    encode_tlv(
        ?STP_M3UA_PARAM_ERROR_CODE,
        <<(uint(Value, 32, error_code)):32/big>>
    );
encode_param(status, {StatusType, StatusInfo}) ->
    encode_tlv(?STP_M3UA_PARAM_STATUS, <<
        (uint(StatusType, 16, status_type)):16/big,
        (uint(StatusInfo, 16, status_info)):16/big
    >>);
encode_param(diagnostic_information, Value) when is_binary(Value) ->
    encode_tlv(?STP_M3UA_PARAM_DIAGNOSTIC_INFORMATION, Value);
encode_param(routing_keys, Keys) when is_list(Keys), Keys =/= [] ->
    [
        encode_tlv(?STP_M3UA_PARAM_ROUTING_KEY, encode_routing_key(Key))
        || Key <- Keys
    ];
encode_param(registration_results, Results)
        when is_list(Results), Results =/= [] ->
    [
        encode_tlv(
            ?STP_M3UA_PARAM_REGISTRATION_RESULT,
            encode_registration_result(Result)
        )
        || Result <- Results
    ];
encode_param(deregistration_results, Results)
        when is_list(Results), Results =/= [] ->
    [
        encode_tlv(
            ?STP_M3UA_PARAM_DEREGISTRATION_RESULT,
            encode_deregistration_result(Result)
        )
        || Result <- Results
    ];
encode_param(Tag, Value) when is_integer(Tag), is_binary(Value) ->
    encode_tlv(Tag, Value);
encode_param(Key, Value) ->
    error({invalid_m3ua_parameter, Key, Value}).

encode_tlv(Tag, Value)
        when is_integer(Tag), Tag >= 0, Tag =< ?STP_UINT16_MAX,
                            is_binary(Value) ->
    Length = 4 + byte_size(Value),
    PadLength = (4 - (Length rem 4)) rem 4,
    <<Tag:16/big, Length:16/big, Value/binary, 0:(PadLength * 8)>>.

decode_params(<<>>, Acc) ->
    {ok, Acc};
decode_params(<<Tag:16/big, Length:16/big, Rest/binary>>, Acc)
        when Length >= 4 ->
    ValueLength = Length - 4,
    PadLength = (4 - (Length rem 4)) rem 4,
    case Rest of
        <<Value:ValueLength/binary, _Padding:PadLength/binary, Tail/binary>> ->
            decode_params(Tail, decode_param(Tag, Value, Acc));
        _ ->
            {error, {truncated_m3ua_parameter, Tag, Length}}
    end;
decode_params(<<Tag:16/big, Length:16/big, _/binary>>, _Acc) ->
    {error, {invalid_m3ua_parameter_length, Tag, Length}};
decode_params(Rest, _Acc) ->
    {error, {truncated_m3ua_parameter_header, byte_size(Rest)}}.

decode_param(?STP_M3UA_PARAM_NETWORK_APPEARANCE, <<Value:32/big>>, Acc) ->
    Acc#{network_appearance => Value};
decode_param(?STP_M3UA_PARAM_ROUTING_CONTEXT, Value, Acc)
        when byte_size(Value) rem 4 =:= 0 ->
    Acc#{routing_context => [Item || <<Item:32/big>> <= Value]};
decode_param(?STP_M3UA_PARAM_PROTOCOL_DATA, <<
    Opc:32/big, Dpc:32/big, Si:8, Ni:8, Mp:8, Sls:8, Payload/binary
>>, Acc) ->
    Acc#{protocol_data => #{
        opc => Opc, dpc => Dpc, si => Si, ni => Ni, mp => Mp, sls => Sls,
        payload => Payload
}};
decode_param(?STP_M3UA_PARAM_CORRELATION_ID, <<Value:32/big>>, Acc) ->
    Acc#{correlation_id => Value};
decode_param(?STP_M3UA_PARAM_AFFECTED_POINT_CODE, Value, Acc)
        when byte_size(Value) rem 4 =:= 0 ->
    Acc#{affected_point_code => [
        {Mask, PointCode} || <<Mask:8, PointCode:24/big>> <= Value
    ]};
decode_param(?STP_M3UA_PARAM_CONCERNED_DESTINATION,
             <<_Reserved:8, PointCode:24/big>>, Acc) ->
    Acc#{concerned_destination => PointCode};
decode_param(?STP_M3UA_PARAM_CONGESTION_INDICATIONS,
             <<_Reserved:24, Level:8>>, Acc) ->
    Acc#{congestion_indications => Level};
decode_param(?STP_M3UA_PARAM_USER_CAUSE,
             <<Cause:16/big, User:16/big>>, Acc) ->
    Acc#{user_cause => {Cause, User}};
decode_param(?STP_M3UA_PARAM_TRAFFIC_MODE_TYPE, <<Value:32/big>>, Acc) ->
    Acc#{traffic_mode_type => traffic_mode_name(Value)};
decode_param(?STP_M3UA_PARAM_ASP_IDENTIFIER, <<Value:32/big>>, Acc) ->
    Acc#{asp_identifier => Value};
decode_param(?STP_M3UA_PARAM_HEARTBEAT_DATA, Value, Acc) ->
    Acc#{heartbeat_data => Value};
decode_param(?STP_M3UA_PARAM_INFO_STRING, Value, Acc) ->
    Acc#{info_string => Value};
decode_param(?STP_M3UA_PARAM_ERROR_CODE, <<Value:32/big>>, Acc) ->
    Acc#{error_code => Value};
decode_param(?STP_M3UA_PARAM_STATUS,
             <<StatusType:16/big, StatusInfo:16/big>>, Acc) ->
    Acc#{status => {StatusType, StatusInfo}};
decode_param(?STP_M3UA_PARAM_DIAGNOSTIC_INFORMATION, Value, Acc) ->
    Acc#{diagnostic_information => Value};
decode_param(?STP_M3UA_PARAM_ROUTING_KEY, Value, Acc) ->
    append_decoded(routing_keys, decode_routing_key(Value), Acc);
decode_param(?STP_M3UA_PARAM_REGISTRATION_RESULT, Value, Acc) ->
    append_decoded(
        registration_results, decode_registration_result(Value), Acc
    );
decode_param(?STP_M3UA_PARAM_DEREGISTRATION_RESULT, Value, Acc) ->
    append_decoded(
        deregistration_results, decode_deregistration_result(Value), Acc
    );
decode_param(Tag, Value, #{unknown := Unknown} = Acc) ->
    Acc#{unknown => [{Tag, Value} | Unknown]}.

append_decoded(Key, Value, Acc) ->
    Acc#{Key => maps:get(Key, Acc, []) ++ [Value]}.

encode_routing_key(Key) when is_map(Key) ->
    LocalId = maps:get(local_rk_identifier, Key),
    Destinations = routing_key_destinations(Key),
    true = Destinations =/= [] orelse
        error({missing_routing_key_destination, Key}),
    Prefix0 = [
        encode_tlv(
            ?STP_M3UA_PARAM_LOCAL_RK_IDENTIFIER,
            <<(uint(LocalId, 32, local_rk_identifier)):32/big>>
        )
    ],
    Prefix1 = optional_nested_uint(
        routing_context, ?STP_M3UA_PARAM_ROUTING_CONTEXT, Key, Prefix0
    ),
    Prefix2 =
        case maps:find(traffic_mode_type, Key) of
            {ok, Mode} ->
                Prefix1 ++ [encode_nested_traffic_mode(Mode)];
            error ->
                Prefix1
        end,
    Prefix3 = optional_nested_uint(
        network_appearance, ?STP_M3UA_PARAM_NETWORK_APPEARANCE, Key, Prefix2
    ),
    iolist_to_binary(
        Prefix3 ++ [encode_routing_key_destination(Item) ||
                    Item <- Destinations]
    );
encode_routing_key(Key) ->
    error({invalid_routing_key, Key}).

routing_key_destinations(#{destinations := Destinations})
        when is_list(Destinations) ->
    Destinations;
routing_key_destinations(#{destination_point_codes := Dpcs} = Key)
        when is_list(Dpcs) ->
    ServiceIndicators = maps:get(service_indicators, Key, any),
    Originating = maps:get(originating_point_codes, Key, any),
    [
        #{
            dpc => Dpc,
            service_indicators => ServiceIndicators,
            originating_point_codes => Originating
        }
        || Dpc <- Dpcs
    ];
routing_key_destinations(_Key) ->
    [].

encode_routing_key_destination(#{dpc := {Mask, PointCode}} = Group) ->
    Dpc = encode_tlv(?STP_M3UA_PARAM_DESTINATION_POINT_CODE, <<
        (uint(Mask, 8, dpc_mask)):8,
        (uint(PointCode, 24, destination_point_code)):24/big
    >>),
    WithSi =
        case maps:get(service_indicators, Group, any) of
            any ->
                [Dpc];
            Sis when is_list(Sis), Sis =/= [] ->
                [
                    Dpc,
                    encode_tlv(
                        ?STP_M3UA_PARAM_SERVICE_INDICATORS,
                        << <<(uint(Si, 8, service_indicator)):8>>
                           || Si <- Sis >>
                    )
                ];
            InvalidSis ->
                error({invalid_service_indicators, InvalidSis})
        end,
    case maps:get(originating_point_codes, Group, any) of
        any ->
            WithSi;
        Opcs when is_list(Opcs), Opcs =/= [] ->
            OpcValue = <<
                <<(uint(OpcMask, 8, opc_mask)):8,
                  (uint(Opc, 24, originating_point_code)):24/big>>
                || {OpcMask, Opc} <- Opcs
            >>,
            WithSi ++ [
                encode_tlv(?STP_M3UA_PARAM_ORIGINATING_POINT_CODE, OpcValue)
            ];
        InvalidOpcs ->
            error({invalid_originating_point_codes, InvalidOpcs})
    end;
encode_routing_key_destination(Group) ->
    error({invalid_routing_key_destination, Group}).

optional_nested_uint(KeyName, Tag, Source, Acc) ->
    case maps:find(KeyName, Source) of
        {ok, Value} ->
            Acc ++ [encode_tlv(
                Tag, <<(uint(Value, 32, KeyName)):32/big>>
            )];
        error ->
            Acc
    end.

encode_nested_traffic_mode(override) ->
    encode_tlv(?STP_M3UA_PARAM_TRAFFIC_MODE_TYPE, <<1:32/big>>);
encode_nested_traffic_mode(loadshare) ->
    encode_tlv(?STP_M3UA_PARAM_TRAFFIC_MODE_TYPE, <<2:32/big>>);
encode_nested_traffic_mode(broadcast) ->
    encode_tlv(?STP_M3UA_PARAM_TRAFFIC_MODE_TYPE, <<3:32/big>>);
encode_nested_traffic_mode(Value) ->
    encode_tlv(
        ?STP_M3UA_PARAM_TRAFFIC_MODE_TYPE,
        <<(uint(Value, 32, traffic_mode_type)):32/big>>
    ).

encode_registration_result(Result) when is_map(Result) ->
    LocalId = maps:get(local_rk_identifier, Result),
    Status = registration_status_id(
        maps:get(registration_status, Result)
    ),
    RoutingContext = maps:get(routing_context, Result, 0),
    iolist_to_binary([
        encode_tlv(?STP_M3UA_PARAM_LOCAL_RK_IDENTIFIER, <<
            (uint(LocalId, 32, local_rk_identifier)):32/big
        >>),
        encode_tlv(?STP_M3UA_PARAM_REGISTRATION_STATUS, <<Status:32/big>>),
        encode_tlv(?STP_M3UA_PARAM_ROUTING_CONTEXT, <<
            (uint(RoutingContext, 32, routing_context)):32/big
        >>)
    ]);
encode_registration_result(Result) ->
    error({invalid_registration_result, Result}).

encode_deregistration_result(Result) when is_map(Result) ->
    RoutingContext = maps:get(routing_context, Result),
    Status = deregistration_status_id(
        maps:get(deregistration_status, Result)
    ),
    iolist_to_binary([
        encode_tlv(?STP_M3UA_PARAM_ROUTING_CONTEXT, <<
            (uint(RoutingContext, 32, routing_context)):32/big
        >>),
        encode_tlv(?STP_M3UA_PARAM_DEREGISTRATION_STATUS, <<Status:32/big>>)
    ]);
encode_deregistration_result(Result) ->
    error({invalid_deregistration_result, Result}).

decode_routing_key(Value) ->
    Tlvs = decode_nested_tlvs(Value),
    decode_routing_key_tlvs(Tlvs, #{destinations => []}, undefined).

decode_routing_key_tlvs([], Key, undefined) ->
    validate_decoded_routing_key(Key);
decode_routing_key_tlvs([], Key, Current) ->
    validate_decoded_routing_key(add_destination(Current, Key));
decode_routing_key_tlvs(
    [{?STP_M3UA_PARAM_LOCAL_RK_IDENTIFIER, <<LocalId:32/big>>} | Rest],
    Key,
    Current
) ->
    ensure_absent(local_rk_identifier, Key),
    decode_routing_key_tlvs(
        Rest, Key#{local_rk_identifier => LocalId}, Current
    );
decode_routing_key_tlvs(
    [{?STP_M3UA_PARAM_ROUTING_CONTEXT, <<RoutingContext:32/big>>} | Rest],
    Key,
    Current
) ->
    ensure_absent(routing_context, Key),
    decode_routing_key_tlvs(
        Rest, Key#{routing_context => RoutingContext}, Current
    );
decode_routing_key_tlvs(
    [{?STP_M3UA_PARAM_TRAFFIC_MODE_TYPE, <<Mode:32/big>>} | Rest],
    Key,
    Current
) ->
    ensure_absent(traffic_mode_type, Key),
    decode_routing_key_tlvs(
        Rest, Key#{traffic_mode_type => traffic_mode_name(Mode)}, Current
    );
decode_routing_key_tlvs(
    [{?STP_M3UA_PARAM_NETWORK_APPEARANCE, <<Na:32/big>>} | Rest],
    Key,
    Current
) ->
    ensure_absent(network_appearance, Key),
    decode_routing_key_tlvs(
        Rest, Key#{network_appearance => Na}, Current
    );
decode_routing_key_tlvs(
    [{?STP_M3UA_PARAM_DESTINATION_POINT_CODE,
      <<Mask:8, PointCode:24/big>>} | Rest],
    Key,
    undefined
) ->
    decode_routing_key_tlvs(Rest, Key, #{dpc => {Mask, PointCode}});
decode_routing_key_tlvs(
    [{?STP_M3UA_PARAM_DESTINATION_POINT_CODE,
      <<Mask:8, PointCode:24/big>>} | Rest],
    Key,
    Current
) ->
    decode_routing_key_tlvs(
        Rest, add_destination(Current, Key),
        #{dpc => {Mask, PointCode}}
    );
decode_routing_key_tlvs(
    [{?STP_M3UA_PARAM_SERVICE_INDICATORS, Sis} | Rest],
    Key,
    #{dpc := _} = Current
) when byte_size(Sis) > 0 ->
    ensure_absent(service_indicators, Current),
    decode_routing_key_tlvs(
        Rest, Key,
        Current#{service_indicators => binary_to_list(Sis)}
    );
decode_routing_key_tlvs(
    [{?STP_M3UA_PARAM_ORIGINATING_POINT_CODE, Opcs} | Rest],
    Key,
    #{dpc := _} = Current
) when byte_size(Opcs) > 0, byte_size(Opcs) rem 4 =:= 0 ->
    ensure_absent(originating_point_codes, Current),
    decode_routing_key_tlvs(
        Rest, Key,
        Current#{originating_point_codes => [
            {Mask, Opc} || <<Mask:8, Opc:24/big>> <= Opcs
        ]}
    );
decode_routing_key_tlvs([{Tag, Binary} | _], _Key, _Current) ->
    error({invalid_routing_key_parameter, Tag, Binary}).

add_destination(Current, #{destinations := Destinations} = Key) ->
    Key#{destinations => Destinations ++ [
        maps:merge(
            #{service_indicators => any, originating_point_codes => any},
            Current
        )
    ]}.

validate_decoded_routing_key(#{
    local_rk_identifier := _,
    destinations := [_ | _]
} = Key) ->
    Key;
validate_decoded_routing_key(Key) ->
    error({invalid_routing_key, Key}).

decode_registration_result(Value) ->
    Params = nested_unique_params(Value, #{
        ?STP_M3UA_PARAM_LOCAL_RK_IDENTIFIER => local_rk_identifier,
        ?STP_M3UA_PARAM_REGISTRATION_STATUS => registration_status,
        ?STP_M3UA_PARAM_ROUTING_CONTEXT => routing_context
    }),
    case Params of
        #{
            local_rk_identifier := LocalId,
            registration_status := Status,
            routing_context := RoutingContext
        } ->
            #{
                local_rk_identifier => LocalId,
                registration_status => registration_status_name(Status),
                routing_context => RoutingContext
            };
        _ ->
            error({invalid_registration_result, Params})
    end.

decode_deregistration_result(Value) ->
    Params = nested_unique_params(Value, #{
        ?STP_M3UA_PARAM_ROUTING_CONTEXT => routing_context,
        ?STP_M3UA_PARAM_DEREGISTRATION_STATUS => deregistration_status
    }),
    case Params of
        #{
            routing_context := RoutingContext,
            deregistration_status := Status
        } ->
            #{
                routing_context => RoutingContext,
                deregistration_status => deregistration_status_name(Status)
            };
        _ ->
            error({invalid_deregistration_result, Params})
    end.

nested_unique_params(Value, TagNames) ->
    lists:foldl(
        fun({Tag, <<Integer:32/big>>}, Acc) ->
            case maps:find(Tag, TagNames) of
                {ok, Name} ->
                    ensure_absent(Name, Acc),
                    Acc#{Name => Integer};
                error ->
                    error({unsupported_nested_parameter, Tag})
            end;
           ({Tag, Binary}, _Acc) ->
                error({invalid_nested_parameter, Tag, Binary})
        end,
        #{},
        decode_nested_tlvs(Value)
    ).

decode_nested_tlvs(Binary) ->
    decode_nested_tlvs(Binary, []).

decode_nested_tlvs(<<>>, Acc) ->
    lists:reverse(Acc);
decode_nested_tlvs(<<Tag:16/big, Length:16/big, Rest/binary>>, Acc)
        when Length >= 4 ->
    ValueLength = Length - 4,
    PadLength = (4 - (Length rem 4)) rem 4,
    case Rest of
        <<Value:ValueLength/binary, Padding:PadLength/binary, Tail/binary>> ->
            true = all_zero(Padding) orelse
                error({invalid_m3ua_padding, Tag}),
            decode_nested_tlvs(Tail, [{Tag, Value} | Acc]);
        _ ->
            error({truncated_nested_parameter, Tag, Length})
    end;
decode_nested_tlvs(<<Tag:16/big, Length:16/big, _/binary>>, _Acc) ->
    error({invalid_nested_parameter_length, Tag, Length});
decode_nested_tlvs(Binary, _Acc) ->
    error({truncated_nested_parameter_header, byte_size(Binary)}).

all_zero(Binary) ->
    Binary =:= <<0:(byte_size(Binary) * 8)>>.

ensure_absent(Key, Map) ->
    true = not maps:is_key(Key, Map) orelse
        error({duplicate_nested_parameter, Key}).

registration_status_id(successfully_registered) -> 0;
registration_status_id(error_unknown) -> 1;
registration_status_id(invalid_dpc) -> 2;
registration_status_id(invalid_network_appearance) -> 3;
registration_status_id(invalid_routing_key) -> 4;
registration_status_id(permission_denied) -> 5;
registration_status_id(cannot_support_unique_routing) -> 6;
registration_status_id(routing_key_not_provisioned) -> 7;
registration_status_id(insufficient_resources) -> 8;
registration_status_id(unsupported_rk_parameter) -> 9;
registration_status_id(invalid_traffic_mode) -> 10;
registration_status_id(routing_key_change_refused) -> 11;
registration_status_id(routing_key_already_registered) -> 12;
registration_status_id(Value) -> uint(Value, 32, registration_status).

registration_status_name(0) -> successfully_registered;
registration_status_name(1) -> error_unknown;
registration_status_name(2) -> invalid_dpc;
registration_status_name(3) -> invalid_network_appearance;
registration_status_name(4) -> invalid_routing_key;
registration_status_name(5) -> permission_denied;
registration_status_name(6) -> cannot_support_unique_routing;
registration_status_name(7) -> routing_key_not_provisioned;
registration_status_name(8) -> insufficient_resources;
registration_status_name(9) -> unsupported_rk_parameter;
registration_status_name(10) -> invalid_traffic_mode;
registration_status_name(11) -> routing_key_change_refused;
registration_status_name(12) -> routing_key_already_registered;
registration_status_name(Value) -> Value.

deregistration_status_id(successfully_deregistered) -> 0;
deregistration_status_id(error_unknown) -> 1;
deregistration_status_id(invalid_routing_context) -> 2;
deregistration_status_id(permission_denied) -> 3;
deregistration_status_id(not_registered) -> 4;
deregistration_status_id(asp_currently_active) -> 5;
deregistration_status_id(Value) ->
    uint(Value, 32, deregistration_status).

deregistration_status_name(0) -> successfully_deregistered;
deregistration_status_name(1) -> error_unknown;
deregistration_status_name(2) -> invalid_routing_context;
deregistration_status_name(3) -> permission_denied;
deregistration_status_name(4) -> not_registered;
deregistration_status_name(5) -> asp_currently_active;
deregistration_status_name(Value) -> Value.

tidy_unknown(#{unknown := []} = Params) ->
    maps:remove(unknown, Params);
tidy_unknown(#{unknown := Unknown} = Params) ->
    Params#{unknown => lists:reverse(Unknown)}.

uint(Value, Bits, _Name)
        when is_integer(Value), Value >= 0, Value < (1 bsl Bits) ->
    Value;
uint(Value, _Bits, Name) ->
    error({invalid_unsigned_integer, Name, Value}).

class_id(Name) when is_atom(Name) ->
    case lists:keyfind(Name, 1, class_ids()) of
        {Name, Id} -> Id;
        false -> error({invalid_message_class, Name})
    end;
class_id(Value) when is_integer(Value), Value >= 0, Value =< 255 -> Value;
class_id(Value) -> error({invalid_message_class, Value}).

class_name(Id) ->
    case lists:keyfind(Id, 2, class_ids()) of
        {Name, Id} -> Name;
        false -> Id
    end.

class_ids() ->
    [
        {management, 0},
        {transfer, 1},
        {ssnm, 2},
        {aspsm, 3},
        {asptm, 4},
        {rkm, 9}
    ].

type_id(_Class, Value) when is_integer(Value), Value >= 0, Value =< 255 -> Value;
type_id(Class, Type) ->
    ClassId = class_id(Class),
    case lists:filter(
        fun({CandidateClass, CandidateType, _TypeId}) ->
            CandidateClass =:= ClassId andalso CandidateType =:= Type
        end,
        type_ids()
    ) of
        [{ClassId, Type, TypeId}] -> TypeId;
        [] -> error({invalid_message_type, Class, Type})
    end.

type_name(Class, Type) ->
    case lists:filter(
        fun({CandidateClass, _CandidateType, CandidateTypeId}) ->
            CandidateClass =:= Class andalso CandidateTypeId =:= Type
        end,
        type_ids()
    ) of
        [{Class, TypeName, Type}] -> TypeName;
        [] -> Type
    end.

type_ids() ->
    [
        {0, error, 0},
        {0, notify, 1},
        {1, data, 1},
        {2, duna, 1},
        {2, dava, 2},
        {2, daud, 3},
        {2, scon, 4},
        {2, dupu, 5},
        {2, drst, 6},
        {3, asp_up, 1},
        {3, asp_down, 2},
        {3, heartbeat, 3},
        {3, asp_up_ack, 4},
        {3, asp_down_ack, 5},
        {3, heartbeat_ack, 6},
        {4, asp_active, 1},
        {4, asp_inactive, 2},
        {4, asp_active_ack, 3},
        {4, asp_inactive_ack, 4},
        {9, registration_request, 1},
        {9, registration_response, 2},
        {9, deregistration_request, 3},
        {9, deregistration_response, 4}
    ].

traffic_mode_name(1) -> override;
traffic_mode_name(2) -> loadshare;
traffic_mode_name(3) -> broadcast;
traffic_mode_name(Value) -> Value.
