-module(telco_stp_sctp).

-include("telco_stp.hrl").

-export([adaptation_ppid/1, default_port/1, valid_ppid/2]).

adaptation_ppid(m3ua) -> ?STP_M3UA_PPID;
adaptation_ppid(m2pa) -> ?STP_M2PA_PPID.

default_port(m3ua) -> ?STP_M3UA_PORT;
default_port(m2pa) -> ?STP_M2PA_PORT.

valid_ppid(_Adaptation, 0) -> true;
valid_ppid(m3ua, ?STP_M3UA_PPID) -> true;
valid_ppid(m3ua, ?STP_M3UA_NETWORK_PPID) -> true;
valid_ppid(m2pa, ?STP_M2PA_PPID) -> true;
valid_ppid(m2pa, ?STP_M2PA_NETWORK_PPID) -> true;
valid_ppid(_Adaptation, _Ppid) -> false.
