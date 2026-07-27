-module(telco_stp_test_runner).

-export([run/0]).

run() ->
    Modules = [
        telco_stp_m3ua_tests,
        telco_stp_m2pa_tests,
        telco_stp_mtp3_tests,
        telco_stp_snmm_tests,
        telco_stp_sccp_tests,
        telco_stp_scmg_tests,
        telco_stp_slt_tests,
        telco_stp_integration_tests,
        telco_stp_advanced_tests
    ],
    case eunit:test(Modules, [verbose]) of
        ok -> halt(0);
        error -> halt(1)
    end.
