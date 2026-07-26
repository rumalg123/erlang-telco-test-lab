-module(telco_stp_gtt).
-behaviour(gen_server).

-export([
    start_link/0,
    add/1,
    remove/1,
    translate/1,
    list/0
]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(DEFAULT_MAX_CHAIN_DEPTH, 8).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

add(Rule) ->
    gen_server:call(?MODULE, {add, Rule}).

remove(Id) ->
    gen_server:call(?MODULE, {remove, Id}).

translate(Address) ->
    gen_server:call(?MODULE, {translate, Address}).

list() ->
    gen_server:call(?MODULE, list).

init([]) ->
    MaxDepth = application:get_env(
        telco_stp, gtt_max_chain_depth, ?DEFAULT_MAX_CHAIN_DEPTH
    ),
    true = is_integer(MaxDepth) andalso MaxDepth > 0 andalso
        MaxDepth =< 64,
    {ok, #{rules => #{}, max_chain_depth => MaxDepth}}.

handle_call({add, Rule0}, _From, #{rules := Rules} = State) ->
    case normalize_rule(Rule0) of
        {ok, #{id := Id} = Rule} ->
            case maps:is_key(Id, Rules) of
                true ->
                    {reply, {error, {already_exists, Id}}, State};
                false ->
                    {reply, ok, State#{rules => Rules#{Id => Rule}}}
            end;
        Error ->
            {reply, Error, State}
    end;
handle_call({remove, Id}, _From, #{rules := Rules} = State) ->
    {reply, ok, State#{rules => maps:remove(Id, Rules)}};
handle_call(
    {translate, Address}, _From,
    #{rules := Rules, max_chain_depth := MaxDepth} = State
) ->
    Reply = do_translate(Address, maps:values(Rules), MaxDepth),
    {reply, Reply, State};
handle_call(list, _From, #{rules := Rules} = State) ->
    {reply, lists:sort(fun rule_before/2, maps:values(Rules)), State};
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported}, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

normalize_rule(Rule) when is_map(Rule) ->
    case maps:find(id, Rule) of
        {ok, Id} ->
            try
                Match = normalize_match(
                    maps:get(match, Rule, legacy_match(Rule))
                ),
                Set = normalize_set(
                    maps:get(set, Rule, legacy_set(Rule))
                ),
                Priority = non_negative(
                    maps:get(priority, Rule, 100), priority
                ),
                Action = action(maps:get(
                    action, Rule,
                    case map_size(Set) of
                        0 -> allow;
                        _ -> translate
                    end
                )),
                Continue = boolean(
                    maps:get(continue, Rule, false), continue
                ),
                Enabled = boolean(
                    maps:get(enabled, Rule, true), enabled
                ),
                Reason = maps:get(
                    screening_reason, Rule, policy
                ),
                true = (
                    Action =:= translate orelse map_size(Set) =:= 0
                ) orelse error(
                    {screening_action_cannot_transform, Action}
                ),
                {ok, #{
                    id => Id,
                    priority => Priority,
                    enabled => Enabled,
                    action => Action,
                    match => Match,
                    set => Set,
                    continue => Continue,
                    screening_reason => Reason,
                    specificity => match_specificity(Match)
                }}
            catch
                error:Reason0 ->
                    {error, {invalid_gtt_rule, Reason0, Rule}}
            end;
        error ->
            {error, {missing_gtt_rule_fields, [id]}}
    end;
normalize_rule(Rule) ->
    {error, {invalid_gtt_rule, Rule}}.

legacy_match(Rule) ->
    LegacyKeys = [
        prefix,
        exact_digits,
        min_length,
        max_length,
        translation_type,
        numbering_plan,
        nature_of_address
    ],
    maps:with(LegacyKeys, Rule).

legacy_set(Rule) ->
    LegacyKeys = [
        dpc, ssn, routing_indicator, strip_digits, rewrite_prefix
    ],
    case lists:any(
        fun(Key) -> maps:is_key(Key, Rule) end, LegacyKeys
    ) of
        false ->
            #{};
        true ->
            Base0 = maybe_put(
                point_code, maps:find(dpc, Rule), #{}
            ),
            Base1 = maybe_put(ssn, maps:find(ssn, Rule), Base0),
            RoutingIndicator =
                case maps:find(routing_indicator, Rule) of
                    {ok, Value} -> Value;
                    error ->
                        case maps:is_key(ssn, Rule) of
                            true -> ssn;
                            false -> gt
                        end
                end,
            Base2 = Base1#{routing_indicator => RoutingIndicator},
            Base3 = maybe_put(
                strip_digits, maps:find(strip_digits, Rule), Base2
            ),
            case maps:find(rewrite_prefix, Rule) of
                {ok, Prefix} -> Base3#{prepend_digits => Prefix};
                error -> Base3
            end
    end.

normalize_match(Match) when is_map(Match) ->
    Allowed = [
        prefix,
        exact_digits,
        min_length,
        max_length,
        translation_type,
        numbering_plan,
        nature_of_address,
        ssn,
        routing_indicator,
        point_code,
        national_use
    ],
    no_unknown_keys(Match, Allowed, gtt_match),
    Prefix = normalize_digits_allow_empty(
        maps:get(prefix, Match, <<>>)
    ),
    Exact = optional_digits(
        maps:get(exact_digits, Match, undefined)
    ),
    MinLength = optional_non_negative(
        maps:get(min_length, Match, undefined), min_length
    ),
    MaxLength = optional_non_negative(
        maps:get(max_length, Match, undefined), max_length
    ),
    true = valid_length_range(MinLength, MaxLength) orelse
        error({invalid_length_range, MinLength, MaxLength}),
    #{
        prefix => Prefix,
        exact_digits => Exact,
        min_length => MinLength,
        max_length => MaxLength,
        translation_type => numeric_selector(
            maps:get(translation_type, Match, any),
            255, translation_type
        ),
        numbering_plan => numeric_selector(
            maps:get(numbering_plan, Match, any),
            15, numbering_plan
        ),
        nature_of_address => numeric_selector(
            maps:get(nature_of_address, Match, any),
            127, nature_of_address
        ),
        ssn => numeric_selector(
            maps:get(ssn, Match, any), 255, ssn
        ),
        routing_indicator => atom_selector(
            maps:get(routing_indicator, Match, any),
            [gt, ssn], routing_indicator
        ),
        point_code => numeric_selector(
            maps:get(point_code, Match, any),
            16#ffffff, point_code
        ),
        national_use => atom_selector(
            maps:get(national_use, Match, any),
            [true, false], national_use
        )
    };
normalize_match(Match) ->
    error({invalid_gtt_match, Match}).

normalize_set(Set) when is_map(Set) ->
    Allowed = [
        digits,
        replace_prefix,
        strip_digits,
        prepend_digits,
        append_digits,
        translation_type,
        numbering_plan,
        nature_of_address,
        gti,
        point_code,
        ssn,
        routing_indicator,
        national_use,
        remove
    ],
    no_unknown_keys(Set, Allowed, gtt_set),
    maps:fold(
        fun(Key, Value, Acc) ->
            Acc#{Key => normalize_set_value(Key, Value)}
        end,
        #{},
        Set
    );
normalize_set(Set) ->
    error({invalid_gtt_set, Set}).

normalize_set_value(digits, Value) ->
    normalize_digits(Value);
normalize_set_value(replace_prefix, {Old, New}) ->
    {
        normalize_digits_allow_empty(Old),
        normalize_digits_allow_empty(New)
    };
normalize_set_value(strip_digits, Value) ->
    non_negative(Value, strip_digits);
normalize_set_value(prepend_digits, Value) ->
    normalize_digits_allow_empty(Value);
normalize_set_value(append_digits, Value) ->
    normalize_digits_allow_empty(Value);
normalize_set_value(translation_type, Value) ->
    uint(Value, 8, translation_type);
normalize_set_value(numbering_plan, Value) ->
    uint(Value, 4, numbering_plan);
normalize_set_value(nature_of_address, Value) ->
    uint(Value, 7, nature_of_address);
normalize_set_value(gti, Value)
        when is_integer(Value), Value >= 1, Value =< 4 ->
    Value;
normalize_set_value(gti, Value) ->
    error({invalid_gti, Value});
normalize_set_value(point_code, Value) ->
    uint_max(Value, 16#ffffff, point_code);
normalize_set_value(ssn, Value) ->
    uint(Value, 8, ssn);
normalize_set_value(routing_indicator, Value)
        when Value =:= gt; Value =:= ssn ->
    Value;
normalize_set_value(routing_indicator, Value) ->
    error({invalid_routing_indicator, Value});
normalize_set_value(national_use, Value) ->
    boolean(Value, national_use);
normalize_set_value(remove, Values) when is_list(Values) ->
    Allowed = [
        point_code,
        ssn,
        global_title,
        national_use
    ],
    true = lists:all(
        fun(Value) -> lists:member(Value, Allowed) end, Values
    ) orelse error({invalid_gtt_remove_fields, Values}),
    lists:usort(Values);
normalize_set_value(Key, Value) ->
    error({invalid_gtt_set_value, Key, Value}).

do_translate(
    #{routing_indicator := gt, global_title := GlobalTitle} = Address,
    Rules,
    MaxDepth
) ->
    case maps:find(digits, GlobalTitle) of
        {ok, Digits0} ->
            try
                Digits = normalize_digits(Digits0),
                NormalizedAddress = Address#{
                    global_title => GlobalTitle#{digits => Digits}
                },
                evaluate(
                    NormalizedAddress,
                    Rules,
                    MaxDepth,
                    [],
                    [address_fingerprint(NormalizedAddress)]
                )
            catch
                error:Reason -> {error, Reason}
            end;
        error ->
            {error, global_title_has_no_digits}
    end;
do_translate(#{routing_indicator := ssn} = Address, _Rules, _MaxDepth) ->
    {ok, #{
        rule => none,
        rules => [],
        action => bypass,
        address => Address
    }};
do_translate(Address, _Rules, _MaxDepth) ->
    {error, {invalid_gtt_address, Address}}.

evaluate(_Address, _Rules, MaxDepth, Applied, _Seen)
        when length(Applied) >= MaxDepth ->
    {error, {gtt_max_chain_depth, MaxDepth, Applied}};
evaluate(Address, Rules, MaxDepth, Applied, Seen) ->
    Matches = [
        Rule
        || Rule <- Rules,
           maps:get(enabled, Rule),
           not lists:member(maps:get(id, Rule), Applied),
           rule_matches(Rule, Address)
    ],
    case lists:sort(fun rule_before/2, Matches) of
        [] when Applied =:= [] ->
            Digits = address_digits(Address),
            {error, {no_global_title_translation, Digits}};
        [] ->
            translation_result(Address, Applied);
        [Rule | _] ->
            evaluate_rule(
                Rule, Address, Rules, MaxDepth, Applied, Seen
            )
    end.

evaluate_rule(
    #{id := Id, action := deny} = Rule,
    Address, _Rules, _MaxDepth, Applied, _Seen
) ->
    {error, {
        gtt_screening_denied,
        Id,
        maps:get(screening_reason, Rule),
        address_summary(Address),
        Applied
    }};
evaluate_rule(
    #{id := Id, action := discard} = Rule,
    Address, _Rules, _MaxDepth, Applied, _Seen
) ->
    {error, {
        gtt_screening_discarded,
        Id,
        maps:get(screening_reason, Rule),
        address_summary(Address),
        Applied
    }};
evaluate_rule(
    #{id := Id, action := allow, continue := Continue},
    Address, Rules, MaxDepth, Applied, Seen
) ->
    continue_or_finish(
        Continue, Address, Rules, MaxDepth, Applied ++ [Id], Seen
    );
evaluate_rule(
    #{id := Id, action := translate, set := Set,
      continue := Continue},
    Address, Rules, MaxDepth, Applied, Seen
) ->
    Updated = apply_set(Set, Address),
    continue_or_finish(
        Continue, Updated, Rules, MaxDepth, Applied ++ [Id], Seen
    ).

continue_or_finish(
    false, Address, _Rules, _MaxDepth, Applied, _Seen
) ->
    translation_result(Address, Applied);
continue_or_finish(
    true, Address, Rules, MaxDepth, Applied, Seen
) ->
    Fingerprint = address_fingerprint(Address),
    case lists:member(Fingerprint, Seen) of
        true ->
            {error, {
                gtt_loop_detected, Applied, address_summary(Address)
            }};
        false ->
            evaluate(
                Address, Rules, MaxDepth, Applied, [Fingerprint | Seen]
            )
    end.

translation_result(Address, Applied) ->
    case validate_translated_address(Address) of
        ok ->
            {ok, #{
                rule => lists:last(Applied),
                rules => Applied,
                action => translated,
                address => Address
            }};
        {error, Reason} ->
            {error, {invalid_gtt_result, Reason, Applied}}
    end.

validate_translated_address(Address) ->
    case maps:find(point_code, Address) of
        error ->
            {error, missing_point_code};
        {ok, _PointCode} ->
            validate_routing_indicator(Address)
    end.

validate_routing_indicator(#{routing_indicator := ssn} = Address) ->
    case maps:is_key(ssn, Address) of
        true -> ok;
        false -> {error, missing_ssn_for_ssn_routing}
    end;
validate_routing_indicator(#{routing_indicator := gt} = Address) ->
    case maps:is_key(global_title, Address) of
        true -> ok;
        false -> {error, missing_global_title_for_gt_routing}
    end;
validate_routing_indicator(Address) ->
    {error, {invalid_routing_indicator, Address}}.

rule_matches(#{match := Match}, Address) ->
    GlobalTitle = maps:get(global_title, Address, #{}),
    Digits = maps:get(digits, GlobalTitle, <<>>),
    Prefix = maps:get(prefix, Match),
    prefix_matches(Prefix, Digits) andalso
    exact_matches(maps:get(exact_digits, Match), Digits) andalso
    length_matches(
        byte_size(Digits),
        maps:get(min_length, Match),
        maps:get(max_length, Match)
    ) andalso
    selector_matches(
        maps:get(translation_type, Match),
        maps:get(translation_type, GlobalTitle, undefined)
    ) andalso
    selector_matches(
        maps:get(numbering_plan, Match),
        maps:get(numbering_plan, GlobalTitle, undefined)
    ) andalso
    selector_matches(
        maps:get(nature_of_address, Match),
        maps:get(nature_of_address, GlobalTitle, undefined)
    ) andalso
    selector_matches(
        maps:get(ssn, Match),
        maps:get(ssn, Address, undefined)
    ) andalso
    selector_matches(
        maps:get(routing_indicator, Match),
        maps:get(routing_indicator, Address, undefined)
    ) andalso
    selector_matches(
        maps:get(point_code, Match),
        maps:get(point_code, Address, undefined)
    ) andalso
    selector_matches(
        maps:get(national_use, Match),
        maps:get(national_use, Address, false)
    ).

apply_set(Set, Address0) ->
    Remove = maps:get(remove, Set, []),
    Address1 = maps:without(Remove, Address0),
    Address2 = apply_address_fields(Set, Address1),
    apply_global_title_fields(Set, Address2).

apply_address_fields(Set, Address0) ->
    lists:foldl(
        fun(Key, Address) ->
            case maps:find(Key, Set) of
                {ok, Value} -> Address#{Key => Value};
                error -> Address
            end
        end,
        Address0,
        [point_code, ssn, routing_indicator, national_use]
    ).

apply_global_title_fields(Set, Address) ->
    GtKeys = [
        digits,
        replace_prefix,
        strip_digits,
        prepend_digits,
        append_digits,
        translation_type,
        numbering_plan,
        nature_of_address,
        gti
    ],
    case lists:any(
        fun(Key) -> maps:is_key(Key, Set) end, GtKeys
    ) of
        false ->
            Address;
        true ->
            GlobalTitle0 = maps:get(global_title, Address, #{}),
            Digits0 = maps:get(digits, GlobalTitle0, <<>>),
            Digits1 = maps:get(digits, Set, Digits0),
            Digits2 = replace_prefix(
                maps:get(replace_prefix, Set, undefined), Digits1
            ),
            Digits3 = strip_digits(
                maps:get(strip_digits, Set, 0), Digits2
            ),
            Digits4 = <<
                (maps:get(prepend_digits, Set, <<>>))/binary,
                Digits3/binary,
                (maps:get(append_digits, Set, <<>>))/binary
            >>,
            _ = normalize_digits(Digits4),
            GlobalTitle1 = lists:foldl(
                fun(Key, GlobalTitle) ->
                    case maps:find(Key, Set) of
                        {ok, Value} -> GlobalTitle#{Key => Value};
                        error -> GlobalTitle
                    end
                end,
                GlobalTitle0#{digits => Digits4},
                [
                    translation_type,
                    numbering_plan,
                    nature_of_address,
                    gti
                ]
            ),
            Address#{
                global_title => maps:remove(
                    encoding_scheme, GlobalTitle1
                )
            }
    end.

replace_prefix(undefined, Digits) ->
    Digits;
replace_prefix({Old, New}, Digits) ->
    case prefix_matches(Old, Digits) of
        true ->
            Suffix = binary:part(
                Digits, byte_size(Old), byte_size(Digits) - byte_size(Old)
            ),
            <<New/binary, Suffix/binary>>;
        false ->
            error({gtt_replace_prefix_mismatch, Old, Digits})
    end.

strip_digits(0, Digits) ->
    Digits;
strip_digits(Count, Digits) when Count =< byte_size(Digits) ->
    binary:part(Digits, Count, byte_size(Digits) - Count);
strip_digits(Count, Digits) ->
    error({gtt_strip_exceeds_digits, Count, Digits}).

prefix_matches(Prefix, Digits) ->
    byte_size(Digits) >= byte_size(Prefix) andalso
    binary:part(Digits, 0, byte_size(Prefix)) =:= Prefix.

exact_matches(undefined, _Digits) -> true;
exact_matches(Digits, Digits) -> true;
exact_matches(_Expected, _Digits) -> false.

length_matches(Length, undefined, undefined) ->
    Length >= 0;
length_matches(Length, Min, undefined) ->
    Length >= Min;
length_matches(Length, undefined, Max) ->
    Length =< Max;
length_matches(Length, Min, Max) ->
    Length >= Min andalso Length =< Max.

rule_before(A, B) ->
    SpecificityA = maps:get(specificity, A),
    SpecificityB = maps:get(specificity, B),
    PriorityA = maps:get(priority, A),
    PriorityB = maps:get(priority, B),
    case SpecificityA =:= SpecificityB of
        true ->
            case PriorityA =:= PriorityB of
                true -> maps:get(id, A) =< maps:get(id, B);
                false -> PriorityA < PriorityB
            end;
        false ->
            SpecificityA > SpecificityB
    end.

match_specificity(Match) ->
    PrefixScore = byte_size(maps:get(prefix, Match)),
    ExactScore =
        case maps:get(exact_digits, Match) of
            undefined -> 0;
            Exact -> 100000 + byte_size(Exact)
        end,
    SelectorScore = length([
        Key
        || Key <- [
            translation_type,
            numbering_plan,
            nature_of_address,
            ssn,
            routing_indicator,
            point_code,
            national_use,
            min_length,
            max_length
        ],
           maps:get(Key, Match) =/= any,
           maps:get(Key, Match) =/= undefined
    ]),
    ExactScore + (PrefixScore * 100) + SelectorScore.

numeric_selector(any, _Max, _Name) ->
    any;
numeric_selector(Values, Max, Name) when is_list(Values), Values =/= [] ->
    lists:usort([uint_max(Value, Max, Name) || Value <- Values]);
numeric_selector(Value, Max, Name) ->
    uint_max(Value, Max, Name).

atom_selector(any, _Allowed, _Name) ->
    any;
atom_selector(Values, Allowed, Name)
        when is_list(Values), Values =/= [] ->
    true = lists:all(
        fun(Value) -> lists:member(Value, Allowed) end, Values
    ) orelse error({invalid_selector, Name, Values}),
    lists:usort(Values);
atom_selector(Value, Allowed, Name) ->
    true = lists:member(Value, Allowed) orelse
        error({invalid_selector, Name, Value}),
    Value.

selector_matches(any, _Value) -> true;
selector_matches(Values, Value) when is_list(Values) ->
    lists:member(Value, Values);
selector_matches(Value, Value) -> true;
selector_matches(_Expected, _Actual) -> false.

valid_length_range(undefined, _Max) -> true;
valid_length_range(_Min, undefined) -> true;
valid_length_range(Min, Max) -> Min =< Max.

optional_digits(undefined) -> undefined;
optional_digits(Value) -> normalize_digits(Value).

optional_non_negative(undefined, _Name) -> undefined;
optional_non_negative(Value, Name) -> non_negative(Value, Name).

normalize_digits(Value) ->
    Digits = normalize_digits_allow_empty(Value),
    true = byte_size(Digits) > 0 orelse error(empty_digits),
    Digits.

normalize_digits_allow_empty(Value) when is_binary(Value) ->
    true = lists:all(
        fun(Char) -> Char >= $0 andalso Char =< $9 end,
        binary_to_list(Value)
    ) orelse error({invalid_digits, Value}),
    Value;
normalize_digits_allow_empty(Value) when is_list(Value) ->
    normalize_digits_allow_empty(unicode:characters_to_binary(Value));
normalize_digits_allow_empty(Value) ->
    error({invalid_digits, Value}).

no_unknown_keys(Map, Allowed, Name) ->
    Unknown = [
        Key || Key <- maps:keys(Map), not lists:member(Key, Allowed)
    ],
    true = Unknown =:= [] orelse
        error({unknown_fields, Name, Unknown}),
    ok.

action(translate) -> translate;
action(allow) -> allow;
action(deny) -> deny;
action(discard) -> discard;
action(Value) -> error({invalid_gtt_action, Value}).

boolean(true, _Name) -> true;
boolean(false, _Name) -> false;
boolean(Value, Name) -> error({invalid_boolean, Name, Value}).

uint(Value, Bits, Name) ->
    uint_max(Value, (1 bsl Bits) - 1, Name).

uint_max(Value, Max, _Name)
        when is_integer(Value), Value >= 0, Value =< Max ->
    Value;
uint_max(Value, _Max, Name) ->
    error({invalid_unsigned_integer, Name, Value}).

non_negative(Value, _Name) when is_integer(Value), Value >= 0 ->
    Value;
non_negative(Value, Name) ->
    error({invalid_non_negative_integer, Name, Value}).

maybe_put(Key, {ok, Value}, Map) -> Map#{Key => Value};
maybe_put(_Key, error, Map) -> Map.

address_digits(Address) ->
    maps:get(digits, maps:get(global_title, Address, #{}), <<>>).

address_summary(Address) ->
    GlobalTitle = maps:get(global_title, Address, #{}),
    #{
        digits => maps:get(digits, GlobalTitle, undefined),
        translation_type => maps:get(
            translation_type, GlobalTitle, undefined
        ),
        numbering_plan => maps:get(
            numbering_plan, GlobalTitle, undefined
        ),
        nature_of_address => maps:get(
            nature_of_address, GlobalTitle, undefined
        ),
        point_code => maps:get(point_code, Address, undefined),
        ssn => maps:get(ssn, Address, undefined),
        routing_indicator => maps:get(
            routing_indicator, Address, undefined
        )
    }.

address_fingerprint(Address) ->
    term_to_binary(Address).
