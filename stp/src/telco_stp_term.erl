-module(telco_stp_term).

-export([compressed_binary/1, deterministic_binary/1, hmac_sha256/2, sha256/1]).

deterministic_binary(Term) ->
    term_to_binary(Term, [{minor_version, 2}, deterministic]).

compressed_binary(Term) ->
    term_to_binary(Term, [
        compressed, {minor_version, 2}, deterministic
    ]).

sha256(Term) ->
    crypto:hash(sha256, deterministic_binary(Term)).

hmac_sha256(Term, Secret) ->
    crypto:mac(hmac, sha256, Secret, deterministic_binary(Term)).
