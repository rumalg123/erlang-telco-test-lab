-module(telco_stp_transport_loopback).
-behaviour(telco_stp_transport).

-export([open/2, send/2, handle_info/2, close/1]).

open(Owner, Config) ->
    {ok, #{
        owner => Owner,
        link => maps:get(name, Config),
        peer => maps:get(peer, Config, sink)
    }}.

send({stream, Stream, Data}, #{link := Link, peer := Peer} = State)
        when is_integer(Stream), Stream >= 0, is_binary(Data) ->
    send_to_peer({m2pa, Link, Stream, Data}, Data, Peer, State);
send(Data, #{link := Link, peer := Peer} = State) when is_binary(Data) ->
    send_to_peer({m3ua, Link, Data}, Data, Peer, State).

send_to_peer(Message, Data, Peer, State) ->
    case Peer of
        sink ->
            ok;
        Pid when is_pid(Pid) ->
            Pid ! Message;
        {registered, Name} when is_atom(Name) ->
            case whereis(Name) of
                undefined -> ok;
                Pid -> Pid ! Message
            end;
        {link, OtherLink} ->
            _ =
                case Message of
                    {m2pa, _Link, Stream, Data} ->
                        telco_stp_link_manager:inject(
                            OtherLink, Data, #{stream => Stream, ppid => 5}
                        );
                    _ ->
                        telco_stp_link_manager:inject(OtherLink, Data)
                end,
            ok
    end,
    {ok, State}.

handle_info(_Info, State) ->
    {ignore, State}.

close(_State) ->
    ok.
