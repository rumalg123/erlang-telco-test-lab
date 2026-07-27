-module(telco_stp_m2pa_state).

-include("telco_stp.hrl").

-export([
    initial/0,
    status/1,
    status_stream/1,
    acknowledge/2,
    retrieve/2,
    valid_retrieval_sequence/1
]).

initial() ->
    #{
        tx_fsn => ?STP_M2PA_MAX_SEQUENCE,
        rx_fsn => ?STP_M2PA_MAX_SEQUENCE,
        peer_bsn => ?STP_M2PA_MAX_SEQUENCE,
        unacked => [],
        network_management => #{},
        local_status => out_of_service,
        remote_status => out_of_service,
        proving_token => undefined,
        alignment_token => undefined,
        last_error => undefined
    }.

status(M2pa) ->
    #{
        enabled => true,
        tx_fsn => maps:get(tx_fsn, M2pa),
        rx_fsn => maps:get(rx_fsn, M2pa),
        peer_bsn => maps:get(peer_bsn, M2pa),
        unacked => length(maps:get(unacked, M2pa)),
        network_management => maps:get(network_management, M2pa, #{}),
        local_status => maps:get(local_status, M2pa),
        remote_status => maps:get(remote_status, M2pa),
        last_error => maps:get(last_error, M2pa)
    }.

status_stream(#{status := Status})
        when Status =:= processor_outage;
             Status =:= processor_recovered ->
    1;
status_stream(_Message) ->
    0.

acknowledge(Bsn, M2pa) ->
    Unacked = maps:get(unacked, M2pa),
    case drop_acknowledged(Bsn, Unacked) of
        {found, Remaining} ->
            M2pa#{peer_bsn => Bsn, unacked => Remaining};
        not_found ->
            M2pa#{peer_bsn => Bsn}
    end.

retrieve(AfterFsn, M2pa) ->
    case valid_retrieval_sequence(AfterFsn) of
        false ->
            {error, {invalid_m2pa_retrieval_sequence, AfterFsn}};
        true ->
            Entries = maps:get(unacked, M2pa),
            SelectedEntries = entries_after_fsn(AfterFsn, Entries),
            Messages = [
                #{
                    fsn => maps:get(fsn, Entry),
                    transfer => maps:get(message, Entry)
                }
                || Entry <- SelectedEntries
            ],
            SelectedFsns = [maps:get(fsn, Item) || Item <- Messages],
            Remaining = [
                Entry
                || Entry <- Entries,
                   not lists:member(maps:get(fsn, Entry), SelectedFsns)
            ],
            {ok, Messages, M2pa#{unacked => Remaining}}
    end.

valid_retrieval_sequence(undefined) ->
    true;
valid_retrieval_sequence(Value) ->
    telco_stp_codec:in_range(Value, 0, ?STP_M2PA_MAX_SEQUENCE).

drop_acknowledged(_Bsn, []) ->
    not_found;
drop_acknowledged(Bsn, [#{fsn := Bsn} | Rest]) ->
    {found, Rest};
drop_acknowledged(Bsn, [_Entry | Rest]) ->
    drop_acknowledged(Bsn, Rest).

entries_after_fsn(undefined, Entries) ->
    Entries;
entries_after_fsn(AfterFsn, Entries) ->
    case lists:dropwhile(
        fun(Entry) -> maps:get(fsn, Entry) =/= AfterFsn end,
        Entries
    ) of
        [_Matched | Rest] -> Rest;
        [] -> Entries
    end.
