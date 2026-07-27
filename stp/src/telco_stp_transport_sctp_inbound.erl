-module(telco_stp_transport_sctp_inbound).
-behaviour(telco_stp_transport).

-include("telco_stp.hrl").

-export([open/2, send/2, handle_info/2, close/1]).

open(_Owner, Config) ->
    Required = [listener_name, assoc_id],
    case [Key || Key <- Required, not maps:is_key(Key, Config)] of
        [] ->
            {ok, #{
                listener_name => maps:get(listener_name, Config),
                assoc_id => maps:get(assoc_id, Config),
                stream => maps:get(stream, Config, 0),
                ppid => adaptation_ppid(
                    maps:get(adaptation, Config, m3ua)
                )
            }};
        Missing ->
            {error, {missing_inbound_sctp_options, Missing}}
    end.

send({stream, Stream, Data}, State)
        when is_integer(Stream), Stream >= 0, is_binary(Data) ->
    send_on_stream(Stream, Data, State);
send(Data, #{stream := Stream} = State) when is_binary(Data) ->
    send_on_stream(Stream, Data, State).

send_on_stream(Stream, Data, #{
    listener_name := ListenerName,
    assoc_id := AssocId,
    ppid := Ppid
} = State) ->
    case telco_stp_listener_manager:send(
        ListenerName, AssocId, Stream, Ppid, Data
    ) of
        ok -> {ok, State};
        {error, Reason} ->
            {error, {inbound_sctp_send_failed, Reason}, State}
    end.

handle_info(_Info, State) ->
    {ignore, State}.

close(_State) ->
    ok.

adaptation_ppid(m3ua) -> ?STP_M3UA_PPID;
adaptation_ppid(m2pa) -> ?STP_M2PA_PPID.
