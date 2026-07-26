-module(telco_stp_transport).

-callback open(Owner :: pid(), Config :: map()) ->
    {ok, TransportState :: term()} | {error, Reason :: term()}.
-callback send(
    Data :: binary() | {stream, non_neg_integer(), binary()},
    TransportState :: term()
) ->
    {ok, NewTransportState :: term()} |
    {error, Reason :: term(), NewTransportState :: term()}.
-callback handle_info(Info :: term(), TransportState :: term()) ->
    {data, binary(), NewTransportState :: term()} |
    {data, binary(), map(), NewTransportState :: term()} |
    {down, Reason :: term(), NewTransportState :: term()} |
    {event, Event :: term(), NewTransportState :: term()} |
    {ignore, NewTransportState :: term()}.
-callback close(TransportState :: term()) -> ok.
