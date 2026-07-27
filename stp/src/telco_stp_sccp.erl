-module(telco_stp_sccp).

-include("telco_stp.hrl").

-export([
    encode/1,
    encode/2,
    decode/1,
    decode/2,
    encode_address/1,
    encode_address/2,
    decode_address/1,
    decode_address/2,
    encode_segmentation/1,
    decode_segmentation/1,
    prepare_relay/1
]).

-spec encode(map()) -> {ok, binary()} | {error, term()}.
encode(#{type := _Type} = Message) ->
    encode(Message, maps:get(point_code_variant, Message, itu));
encode(Message) ->
    {error, {invalid_sccp_message, Message}}.

-spec encode(map(), itu | ansi) -> {ok, binary()} | {error, term()}.
encode(#{type := Type} = Message, Variant)
        when Variant =:= itu; Variant =:= ansi ->
    try
        {ok, encode_message(Type, Message, Variant)}
    catch
        error:Reason -> {error, Reason}
    end;
encode(Message, Variant) ->
    {error, {invalid_sccp_message, Message, Variant}}.

-spec decode(binary()) -> {ok, map()} | {error, term()}.
decode(Binary) ->
    decode(Binary, itu).

-spec decode(binary(), itu | ansi) -> {ok, map()} | {error, term()}.
decode(
    <<?STP_SCCP_UDT, ProtocolClass:8, P1:8, P2:8, P3:8, _/binary>> = Binary,
    Variant
) when Variant =:= itu; Variant =:= ansi ->
    decode_short(
        udt, protocol_class, ProtocolClass, undefined,
        [{2, P1}, {3, P2}, {4, P3}], Binary, Variant
    );
decode(
    <<?STP_SCCP_UDTS, ReturnCause:8, P1:8, P2:8, P3:8, _/binary>> = Binary,
    Variant
) when Variant =:= itu; Variant =:= ansi ->
    decode_short(
        udts, return_cause, ReturnCause, undefined,
        [{2, P1}, {3, P2}, {4, P3}], Binary, Variant
    );
decode(
    <<?STP_SCCP_XUDT, ProtocolClass:8, Hop:8,
      P1:8, P2:8, P3:8, P4:8, _/binary>> = Binary,
    Variant
) when Variant =:= itu; Variant =:= ansi ->
    decode_short(
        xudt, protocol_class, ProtocolClass, Hop,
        [{3, P1}, {4, P2}, {5, P3}, {6, P4}], Binary, Variant
    );
decode(
    <<?STP_SCCP_XUDTS, ReturnCause:8, Hop:8,
      P1:8, P2:8, P3:8, P4:8, _/binary>> = Binary,
    Variant
) when Variant =:= itu; Variant =:= ansi ->
    decode_short(
        xudts, return_cause, ReturnCause, Hop,
        [{3, P1}, {4, P2}, {5, P3}, {6, P4}], Binary, Variant
    );
decode(
    <<?STP_SCCP_LUDT, ProtocolClass:8, Hop:8,
      P1:16/little, P2:16/little, P3:16/little, P4:16/little,
      _/binary>> = Binary,
    Variant
) when Variant =:= itu; Variant =:= ansi ->
    decode_long(
        ludt, protocol_class, ProtocolClass, Hop,
        [{4, P1}, {6, P2}, {8, P3}, {10, P4}], Binary, Variant
    );
decode(
    <<?STP_SCCP_LUDTS, ReturnCause:8, Hop:8,
      P1:16/little, P2:16/little, P3:16/little, P4:16/little,
      _/binary>> = Binary,
    Variant
) when Variant =:= itu; Variant =:= ansi ->
    decode_long(
        ludts, return_cause, ReturnCause, Hop,
        [{4, P1}, {6, P2}, {8, P3}, {10, P4}], Binary, Variant
    );
decode(<<Type:8, _/binary>>, Variant)
        when Variant =:= itu; Variant =:= ansi ->
    {error, {unsupported_sccp_message_type, Type}};
decode(Binary, Variant)
        when is_binary(Binary),
             (Variant =:= itu orelse Variant =:= ansi) ->
    {error, {truncated_sccp_message, byte_size(Binary)}};
decode(Value, Variant) ->
    {error, {invalid_sccp_decode_input, Value, Variant}}.

-spec encode_address(map()) -> {ok, binary()} | {error, term()}.
encode_address(Address) when is_map(Address) ->
    encode_address(
        Address, maps:get(point_code_variant, Address, itu)
    );
encode_address(Address) ->
    {error, {invalid_sccp_address, Address}}.

-spec encode_address(map(), itu | ansi) ->
    {ok, binary()} | {error, term()}.
encode_address(Address, Variant)
        when is_map(Address),
             (Variant =:= itu orelse Variant =:= ansi) ->
    try
        PointCodePart =
            case maps:find(point_code, Address) of
                {ok, PointCode} ->
                    encode_point_code(Variant, PointCode);
                error ->
                    <<>>
            end,
        SsnPart =
            case maps:find(ssn, Address) of
                {ok, Ssn} -> <<(uint(Ssn, 8, ssn)):8>>;
                error -> <<>>
            end,
        {Gti, GlobalTitlePart} =
            case maps:find(global_title, Address) of
                {ok, GlobalTitle} -> encode_global_title(GlobalTitle);
                error -> {0, <<>>}
            end,
        RoutingBit =
            case maps:get(routing_indicator, Address, gt) of
                ssn -> 1;
                gt -> 0;
                RoutingValue ->
                    error({invalid_routing_indicator, RoutingValue})
            end,
        NationalBit =
            case maps:get(national_use, Address, false) of
                true -> 1;
                false -> 0;
                NationalValue ->
                    error({invalid_national_use, NationalValue})
            end,
        PcBit = present_bit(PointCodePart),
        SsnBit = present_bit(SsnPart),
        Indicator = PcBit bor (SsnBit bsl 1) bor (Gti bsl 2) bor
                    (RoutingBit bsl 6) bor (NationalBit bsl 7),
        {ok, <<
            Indicator:8,
            PointCodePart/binary,
            SsnPart/binary,
            GlobalTitlePart/binary
        >>}
    catch
        error:Reason -> {error, Reason}
    end;
encode_address(Address, Variant) ->
    {error, {invalid_sccp_address, Address, Variant}}.

-spec decode_address(binary()) -> {ok, map()} | {error, term()}.
decode_address(<<Indicator:8, Rest/binary>>) ->
    decode_address(<<Indicator:8, Rest/binary>>, itu);
decode_address(Binary) when is_binary(Binary) ->
    {error, {truncated_sccp_address, byte_size(Binary)}};
decode_address(Value) ->
    {error, {invalid_sccp_address, Value}}.

-spec decode_address(binary(), itu | ansi) ->
    {ok, map()} | {error, term()}.
decode_address(<<Indicator:8, Rest/binary>>, Variant)
        when Variant =:= itu; Variant =:= ansi ->
    try
        PcPresent = Indicator band 1,
        SsnPresent = (Indicator bsr 1) band 1,
        Gti = (Indicator bsr 2) band ?STP_SCCP_ADDRESS_GTI_MASK,
        RoutingIndicator =
            case (Indicator bsr 6) band 1 of
                1 -> ssn;
                0 -> gt
            end,
        National = ((Indicator bsr 7) band 1) =:= 1,
        {PointCodeFields, AfterPc} = decode_point_code(
            PcPresent, Rest, Variant
        ),
        {SsnFields, AfterSsn} = decode_ssn(SsnPresent, AfterPc),
        {GlobalTitleFields, Tail} = decode_global_title(Gti, AfterSsn),
        true = Tail =:= <<>> orelse error({trailing_address_octets, Tail}),
        {ok, maps:merge(
            #{
                routing_indicator => RoutingIndicator,
                national_use => National
            },
            maps:merge(
                PointCodeFields,
                maps:merge(SsnFields, GlobalTitleFields)
            )
        )}
    catch
        error:Reason -> {error, Reason}
    end;
decode_address(Binary, Variant)
        when is_binary(Binary),
             (Variant =:= itu orelse Variant =:= ansi) ->
    {error, {truncated_sccp_address, byte_size(Binary)}};
decode_address(Value, Variant) ->
    {error, {invalid_sccp_address, Value, Variant}}.

-spec prepare_relay(map()) -> {ok, map()} | {error, term()}.
prepare_relay(#{type := Type, hop_counter := Hop} = Message)
        when Type =:= xudt; Type =:= xudts; Type =:= ludt; Type =:= ludts ->
    case Hop of
        Value when is_integer(Value), Value > 1 ->
            {ok, Message#{hop_counter => Value - 1}};
        1 ->
            {error, hop_counter_violation};
        Value ->
            {error, {invalid_hop_counter, Value}}
    end;
prepare_relay(Message) when is_map(Message) ->
    {ok, Message}.

encode_message(udt, Message, Variant) ->
    encode_short(?STP_SCCP_UDT, protocol_class, Message, false, Variant);
encode_message(udts, Message, Variant) ->
    encode_short(?STP_SCCP_UDTS, return_cause, Message, false, Variant);
encode_message(xudt, Message, Variant) ->
    encode_short(?STP_SCCP_XUDT, protocol_class, Message, true, Variant);
encode_message(xudts, Message, Variant) ->
    encode_short(?STP_SCCP_XUDTS, return_cause, Message, true, Variant);
encode_message(ludt, Message, Variant) ->
    encode_long(?STP_SCCP_LUDT, protocol_class, Message, Variant);
encode_message(ludts, Message, Variant) ->
    encode_long(?STP_SCCP_LUDTS, return_cause, Message, Variant);
encode_message(Type, _Message, _Variant) ->
    error({unsupported_sccp_message_type, Type}).

encode_short(TypeCode, FixedKey, Message, HasHopAndOptions, Variant) ->
    Fixed = uint(maps:get(FixedKey, Message), 8, FixedKey),
    HopPart =
        case HasHopAndOptions of
            true -> <<(uint(maps:get(hop_counter, Message), 8, hop_counter)):8>>;
            false -> <<>>
        end,
    Called = short_parameter(encode_address_value(
        maps:get(called_party, Message), Variant
    )),
    Calling = short_parameter(encode_address_value(
        maps:get(calling_party, Message), Variant
    )),
    Data = short_parameter(binary_value(maps:get(data, Message), data)),
    case HasHopAndOptions of
        false ->
            P1 = 3,
            P2 = 2 + byte_size(Called),
            P3 = 1 + byte_size(Called) + byte_size(Calling),
            pointers_fit([P1, P2, P3]),
            <<
                TypeCode:8, Fixed:8, P1:8, P2:8, P3:8,
                Called/binary, Calling/binary, Data/binary
            >>;
        true ->
            Options = encode_options(maps:get(options, Message, [])),
            P1 = 4,
            P2 = 3 + byte_size(Called),
            P3 = 2 + byte_size(Called) + byte_size(Calling),
            P4 =
                case Options of
                    <<>> -> 0;
                    _ ->
                        1 + byte_size(Called) + byte_size(Calling) +
                        byte_size(Data)
                end,
            pointers_fit([P1, P2, P3, P4]),
            <<
                TypeCode:8, Fixed:8, HopPart/binary,
                P1:8, P2:8, P3:8, P4:8,
                Called/binary, Calling/binary, Data/binary, Options/binary
            >>
    end.

encode_long(TypeCode, FixedKey, Message, Variant) ->
    Fixed = uint(maps:get(FixedKey, Message), 8, FixedKey),
    Hop = uint(maps:get(hop_counter, Message), 8, hop_counter),
    Called = short_parameter(encode_address_value(
        maps:get(called_party, Message), Variant
    )),
    Calling = short_parameter(encode_address_value(
        maps:get(calling_party, Message), Variant
    )),
    DataValue = binary_value(maps:get(data, Message), data),
    true = byte_size(DataValue) =< 3952 orelse
        error({sccp_long_data_too_large, byte_size(DataValue)}),
    Data = <<(byte_size(DataValue)):16/little, DataValue/binary>>,
    Options = encode_options(maps:get(options, Message, [])),
    P1 = 7,
    P2 = 5 + byte_size(Called),
    P3 = 3 + byte_size(Called) + byte_size(Calling),
    P4 =
        case Options of
            <<>> -> 0;
            _ ->
                1 + byte_size(Called) + byte_size(Calling) + byte_size(Data)
        end,
    <<
        TypeCode:8, Fixed:8, Hop:8,
        P1:16/little, P2:16/little, P3:16/little, P4:16/little,
        Called/binary, Calling/binary, Data/binary, Options/binary
    >>.

decode_short(
    Type, FixedKey, FixedValue, Hop, Pointers, Binary, Variant
) ->
    try
        [CalledRaw, CallingRaw, Data] = [
            read_parameter(Binary, Position, Pointer, 1)
            || {Position, Pointer} <- lists:sublist(Pointers, 3)
        ],
        Called = decode_address_value(CalledRaw, Variant),
        Calling = decode_address_value(CallingRaw, Variant),
        Base = #{
            type => Type,
            FixedKey => FixedValue,
            called_party => Called,
            calling_party => Calling,
            data => Data,
            point_code_variant => Variant
        },
        WithHop =
            case Hop of
                undefined -> Base;
                _ -> Base#{hop_counter => Hop}
            end,
        WithOptions =
            case length(Pointers) of
                4 ->
                    {_Position, OptionalPointer} = lists:nth(4, Pointers),
                    OptionalPosition = element(1, lists:nth(4, Pointers)),
                    WithHop#{options => read_options(
                        Binary, OptionalPosition, OptionalPointer
                    )};
                _ ->
                    WithHop
            end,
        {ok, WithOptions}
    catch
        error:Reason -> {error, Reason}
    end.

decode_long(
    Type, FixedKey, FixedValue, Hop, Pointers, Binary, Variant
) ->
    try
        [{CalledPos, CalledPtr}, {CallingPos, CallingPtr},
         {DataPos, DataPtr}, {OptionsPos, OptionsPtr}] = Pointers,
        Called = decode_address_value(
            read_parameter(Binary, CalledPos, CalledPtr, 1), Variant
        ),
        Calling = decode_address_value(
            read_parameter(Binary, CallingPos, CallingPtr, 1), Variant
        ),
        Data = read_parameter(Binary, DataPos, DataPtr, 2),
        {ok, #{
            type => Type,
            FixedKey => FixedValue,
            hop_counter => Hop,
            called_party => Called,
            calling_party => Calling,
            data => Data,
            options => read_options(Binary, OptionsPos, OptionsPtr),
            point_code_variant => Variant
        }}
    catch
        error:Reason -> {error, Reason}
    end.

read_parameter(Binary, PointerPosition, Pointer, LengthSize)
        when Pointer > 0 ->
    Offset = PointerPosition + Pointer,
    Size = byte_size(Binary),
    true = Offset + LengthSize =< Size orelse
        error({sccp_pointer_out_of_range, PointerPosition, Pointer, Size}),
    case LengthSize of
        1 ->
            Length = binary:at(Binary, Offset),
            read_parameter_value(Binary, Offset + 1, Length);
        2 ->
            <<Length:16/little>> = binary:part(Binary, Offset, 2),
            read_parameter_value(Binary, Offset + 2, Length)
    end;
read_parameter(_Binary, PointerPosition, 0, _LengthSize) ->
    error({missing_mandatory_sccp_parameter, PointerPosition}).

read_parameter_value(Binary, Offset, Length) ->
    true = Offset + Length =< byte_size(Binary) orelse
        error({truncated_sccp_parameter, Offset, Length}),
    binary:part(Binary, Offset, Length).

read_options(_Binary, _PointerPosition, 0) ->
    [];
read_options(Binary, PointerPosition, Pointer) ->
    Offset = PointerPosition + Pointer,
    true = Offset < byte_size(Binary) orelse
        error({sccp_optional_pointer_out_of_range, PointerPosition, Pointer}),
    decode_options(binary:part(Binary, Offset, byte_size(Binary) - Offset), []).

decode_options(<<0, _Tail/binary>>, Acc) ->
    lists:reverse(Acc);
decode_options(<<Tag:8, Length:8, Rest/binary>>, Acc)
        when byte_size(Rest) >= Length ->
    <<Value:Length/binary, Tail/binary>> = Rest,
    decode_options(Tail, [decode_option(Tag, Value) | Acc]);
decode_options(<<>>, Acc) ->
    lists:reverse(Acc);
decode_options(Binary, _Acc) ->
    error({truncated_sccp_options, Binary}).

encode_options([]) ->
    <<>>;
encode_options(Options) when is_list(Options) ->
    Encoded = [
        begin
            Tag = option_tag(Name),
            Value = encode_option(Name, Value0),
            true = byte_size(Value) =< 255 orelse
                error({sccp_option_too_large, Name}),
            <<Tag:8, (byte_size(Value)):8, Value/binary>>
        end
        || {Name, Value0} <- Options
    ],
    iolist_to_binary([Encoded, <<0>>]);
encode_options(Options) ->
    error({invalid_sccp_options, Options}).

encode_address_value(Address, Variant) ->
    case encode_address(Address, Variant) of
        {ok, Binary} -> Binary;
        {error, Reason} -> error(Reason)
    end.

decode_address_value(Binary, Variant) ->
    case decode_address(Binary, Variant) of
        {ok, Address} -> Address;
        {error, Reason} -> error(Reason)
    end.

encode_global_title(GlobalTitle) when is_map(GlobalTitle) ->
    Gti = maps:get(gti, GlobalTitle, infer_gti(GlobalTitle)),
    case Gti of
        1 ->
            Digits = digits(GlobalTitle),
            Odd = byte_size(Digits) rem 2,
            Nai = uint(maps:get(nature_of_address, GlobalTitle, 0), 7, nai),
            {1, <<Odd:1, Nai:7, (encode_bcd(Digits))/binary>>};
        2 ->
            TranslationType = uint(
                maps:get(translation_type, GlobalTitle, 0), 8,
                translation_type
            ),
            Raw = binary_value(
                maps:get(address_information, GlobalTitle, <<>>),
                address_information
            ),
            {2, <<TranslationType:8, Raw/binary>>};
        3 ->
            Digits = digits(GlobalTitle),
            TranslationType = uint(
                maps:get(translation_type, GlobalTitle, 0), 8,
                translation_type
            ),
            NumberingPlan = uint(
                maps:get(numbering_plan, GlobalTitle, 0), 4, numbering_plan
            ),
            EncodingScheme = encoding_scheme(GlobalTitle, Digits),
            {3, <<
                TranslationType:8, NumberingPlan:4, EncodingScheme:4,
                (encode_bcd(Digits))/binary
            >>};
        4 ->
            Digits = digits(GlobalTitle),
            TranslationType = uint(
                maps:get(translation_type, GlobalTitle, 0), 8,
                translation_type
            ),
            NumberingPlan = uint(
                maps:get(numbering_plan, GlobalTitle, 0), 4, numbering_plan
            ),
            EncodingScheme = encoding_scheme(GlobalTitle, Digits),
            Nai = uint(maps:get(nature_of_address, GlobalTitle, 0), 7, nai),
            {4, <<
                TranslationType:8, NumberingPlan:4, EncodingScheme:4,
                0:1, Nai:7, (encode_bcd(Digits))/binary
            >>};
        _ ->
            error({unsupported_global_title_indicator, Gti})
    end;
encode_global_title(GlobalTitle) ->
    error({invalid_global_title, GlobalTitle}).

decode_global_title(0, Rest) ->
    {#{}, Rest};
decode_global_title(1, <<Odd:1, Nai:7, Encoded/binary>>) ->
    Digits = decode_bcd(Encoded, Odd =:= 1),
    {#{global_title => #{
        gti => 1,
        nature_of_address => Nai,
        digits => Digits
    }}, <<>>};
decode_global_title(2, <<TranslationType:8, Raw/binary>>) ->
    {#{global_title => #{
        gti => 2,
        translation_type => TranslationType,
        address_information => Raw
    }}, <<>>};
decode_global_title(3, <<
    TranslationType:8, NumberingPlan:4, EncodingScheme:4, Encoded/binary
>>) ->
    Odd = EncodingScheme =:= 1,
    Digits = decode_bcd(Encoded, Odd),
    {#{global_title => #{
        gti => 3,
        translation_type => TranslationType,
        numbering_plan => NumberingPlan,
        encoding_scheme => EncodingScheme,
        digits => Digits
    }}, <<>>};
decode_global_title(4, <<
    TranslationType:8, NumberingPlan:4, EncodingScheme:4,
    _Spare:1, Nai:7, Encoded/binary
>>) ->
    Odd = EncodingScheme =:= 1,
    Digits = decode_bcd(Encoded, Odd),
    {#{global_title => #{
        gti => 4,
        translation_type => TranslationType,
        numbering_plan => NumberingPlan,
        encoding_scheme => EncodingScheme,
        nature_of_address => Nai,
        digits => Digits
    }}, <<>>};
decode_global_title(Gti, Rest) ->
    error({invalid_global_title, Gti, Rest}).

decode_point_code(0, Rest, _Variant) ->
    {#{}, Rest};
decode_point_code(1, <<PointCode:16/little, Rest/binary>>, itu)
        when PointCode =< ?STP_ITU_POINT_CODE_MAX ->
    {#{point_code => PointCode}, Rest};
decode_point_code(1, <<PointCode:24/little, Rest/binary>>, ansi) ->
    {#{point_code => PointCode}, Rest};
decode_point_code(1, Rest, Variant) ->
    error({invalid_or_truncated_point_code, Variant, Rest}).

encode_point_code(itu, PointCode) ->
    Pc = uint(PointCode, 14, point_code),
    <<Pc:16/little>>;
encode_point_code(ansi, PointCode) ->
    Pc = uint(PointCode, 24, point_code),
    <<Pc:24/little>>.

decode_ssn(0, Rest) ->
    {#{}, Rest};
decode_ssn(1, <<Ssn:8, Rest/binary>>) ->
    {#{ssn => Ssn}, Rest};
decode_ssn(1, Rest) ->
    error({truncated_ssn, Rest}).

infer_gti(GlobalTitle) ->
    case {
        maps:is_key(translation_type, GlobalTitle),
        maps:is_key(numbering_plan, GlobalTitle),
        maps:is_key(nature_of_address, GlobalTitle)
    } of
        {true, true, true} -> 4;
        {true, true, false} -> 3;
        {true, false, _} -> 2;
        {false, false, true} -> 1;
        _ -> error({cannot_infer_global_title_indicator, GlobalTitle})
    end.

digits(GlobalTitle) ->
    normalize_digits(maps:get(digits, GlobalTitle)).

normalize_digits(Value) when is_binary(Value) ->
    true = byte_size(Value) > 0 orelse error(empty_global_title),
    true = lists:all(
        fun(Char) -> Char >= $0 andalso Char =< $9 end,
        binary_to_list(Value)
    ) orelse error({invalid_global_title_digits, Value}),
    Value;
normalize_digits(Value) when is_list(Value) ->
    normalize_digits(unicode:characters_to_binary(Value));
normalize_digits(Value) ->
    error({invalid_global_title_digits, Value}).

encoding_scheme(GlobalTitle, Digits) ->
    Expected =
        case byte_size(Digits) rem 2 of
            1 -> 1;
            0 -> 2
        end,
    case maps:get(encoding_scheme, GlobalTitle, Expected) of
        Expected -> Expected;
        Value -> error({encoding_scheme_digit_parity_mismatch, Value, Digits})
    end.

encode_bcd(Digits) ->
    encode_bcd(binary_to_list(Digits), []).

encode_bcd([], Acc) ->
    list_to_binary(lists:reverse(Acc));
encode_bcd([Low], Acc) ->
    encode_bcd([], [Low - $0 | Acc]);
encode_bcd([Low, High | Rest], Acc) ->
    encode_bcd(Rest, [((High - $0) bsl 4) bor (Low - $0) | Acc]).

decode_bcd(Binary, Odd) ->
    Nibbles = lists:flatmap(
        fun(Byte) ->
            [
                Byte band ?STP_SCCP_BCD_NIBBLE_MASK,
                (Byte bsr 4) band ?STP_SCCP_BCD_NIBBLE_MASK
            ]
        end,
        binary_to_list(Binary)
    ),
    Digits0 =
        case {Odd, Nibbles} of
            {true, []} -> error(invalid_empty_odd_bcd);
            {true, _} ->
                true = lists:last(Nibbles) =:= 0 orelse
                    error({invalid_bcd_filler, lists:last(Nibbles)}),
                lists:droplast(Nibbles);
            {false, _} ->
                Nibbles
        end,
    true = lists:all(fun(Value) -> Value =< 9 end, Digits0) orelse
        error({invalid_bcd_digit, Digits0}),
    list_to_binary([Value + $0 || Value <- Digits0]).

short_parameter(Value) ->
    true = byte_size(Value) =< 255 orelse
        error({sccp_parameter_too_large, byte_size(Value)}),
    <<(byte_size(Value)):8, Value/binary>>.

pointers_fit(Pointers) ->
    true = lists:all(
        fun(Value) -> Value >= 0 andalso Value =< 255 end,
        Pointers
    ) orelse error({sccp_pointer_overflow, Pointers}),
    ok.

present_bit(<<>>) -> 0;
present_bit(_Binary) -> 1.

option_tag(Name) when is_atom(Name) ->
    case lists:keyfind(Name, 1, option_tags()) of
        {Name, Tag} -> Tag;
        false -> error({unknown_sccp_option, Name})
    end;
option_tag(Tag) when is_integer(Tag), Tag > 0, Tag =< 255 -> Tag;
option_tag(Name) -> error({unknown_sccp_option, Name}).

option_name(Tag) ->
    case lists:keyfind(Tag, 2, option_tags()) of
        {Name, Tag} -> Name;
        false -> Tag
    end.

option_tags() ->
    [
        {segmentation, ?STP_SCCP_OPTION_SEGMENTATION},
        {importance, ?STP_SCCP_OPTION_IMPORTANCE}
    ].

encode_option(segmentation, Value) when is_map(Value) ->
    encode_segmentation_value(Value);
encode_option(_Name, Value) when is_binary(Value) ->
    Value;
encode_option(Name, Value) ->
    error({invalid_sccp_option_value, Name, Value}).

decode_option(?STP_SCCP_OPTION_SEGMENTATION, Value) ->
    {segmentation, decode_segmentation_value(Value)};
decode_option(Tag, Value) ->
    {option_name(Tag), Value}.

-spec encode_segmentation(map()) -> {ok, binary()} | {error, term()}.
encode_segmentation(Segmentation) when is_map(Segmentation) ->
    try
        {ok, encode_segmentation_value(Segmentation)}
    catch
        error:Reason -> {error, Reason}
    end;
encode_segmentation(Value) ->
    {error, {invalid_segmentation, Value}}.

-spec decode_segmentation(binary()) -> {ok, map()} | {error, term()}.
decode_segmentation(Binary) when is_binary(Binary) ->
    try
        {ok, decode_segmentation_value(Binary)}
    catch
        error:Reason -> {error, Reason}
    end;
decode_segmentation(Value) ->
    {error, {invalid_segmentation, Value}}.

encode_segmentation_value(#{
    first_segment := First,
    class := Class,
    remaining_segments := Remaining,
    local_reference := LocalReference
}) ->
    FirstBit =
        case First of
            true -> 1;
            false -> 0;
            _ -> error({invalid_first_segment, First})
        end,
    ClassValue = uint(Class, 1, segmentation_class),
    RemainingValue = uint(Remaining, 4, remaining_segments),
    Reference = uint(LocalReference, 24, segmentation_local_reference),
    <<
        FirstBit:1,
        ClassValue:1,
        0:2,
        RemainingValue:4,
        Reference:24/big
    >>;
encode_segmentation_value(Value) ->
    error({invalid_segmentation, Value}).

decode_segmentation_value(<<
    FirstBit:1,
    Class:1,
    Spare:2,
    Remaining:4,
    LocalReference:24/big
>>) ->
    true = Spare =:= 0 orelse
        error({nonzero_segmentation_spare_bits, Spare}),
    #{
        first_segment => FirstBit =:= 1,
        class => Class,
        remaining_segments => Remaining,
        local_reference => LocalReference
    };
decode_segmentation_value(Binary) ->
    error({invalid_segmentation_length, byte_size(Binary)}).

binary_value(Value, _Name) when is_binary(Value) ->
    Value;
binary_value(Value, Name) ->
    error({invalid_binary, Name, Value}).

uint(Value, Bits, _Name)
        when is_integer(Value), Value >= 0, Value < (1 bsl Bits) ->
    Value;
uint(Value, _Bits, Name) ->
    error({invalid_unsigned_integer, Name, Value}).
