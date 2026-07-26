-module(telco_stp_console).

-export([boot/0]).

boot() ->
    case application:ensure_all_started(telco_stp) of
        {ok, _Applications} ->
            io:format(
                "telco_stp lab started on OTP ~ts~n"
                "Use telco_stp:status(). to inspect it.~n"
                "Use telco_stp:stop(). to stop it.~n",
                [erlang:system_info(otp_release)]
            ),
            ok;
        {error, Reason} ->
            io:format("Failed to start telco_stp: ~p~n", [Reason]),
            halt(1)
    end.

