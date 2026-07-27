# STP support and readiness matrix

This matrix is the authoritative statement of scope. “Tested” means the
deterministic OTP 29 suite passed on this development host. It does not mean
vendor interoperability, target-host capacity, or carrier certification.

Status meanings:

- **Implemented/tested** — covered by local automated tests.
- **Implemented/interop pending** — implemented, but real SCTP/vendor evidence
  is still required.
- **Partial** — useful within the boundary stated in the last column.
- **Not implemented** — must not be assumed.

## SIGTRAN, SCTP, and MTP

| Area | Status | Implemented boundary |
|---|---|---|
| M3UA common header, TLVs, padding, unknown parameters | Implemented/tested | Strict RFC 4666 length checks; unknown TLVs retained |
| M3UA DATA, Routing Context, Network Appearance | Implemented/tested | Multiple routing contexts; route-selected RC output |
| ASPUP/ASPDN/ASPAC/ASPIA and BEAT | Implemented/tested | ASP and SGP roles; passive and correlated active heartbeat |
| Traffic modes | Implemented/tested | Override, SLS-stable weighted loadshare, and broadcast |
| DUNA/DAVA/DAUD/SCON/DUPU/DRST | Implemented/tested | Per-source destination/user-part state and DAUD replies |
| M3UA Error and Notify | Implemented/tested | Malformed, unsupported, unexpected, RC/traffic-mode validation; alarmed inbound Notify/Error |
| M3UA RKM REG/DEREG | Implemented/tested | Repeated routing keys/results; dynamic or provisioned-only policy; bounded RC allocation; DPC/SI/OPC/NA matching; overlap rejection |
| IPSP double exchange | Partial | Symmetric control messages work; no dedicated double-exchange procedure/state proof |
| Outbound SCTP | Implemented/interop pending | M3UA PPID 3/2905, M2PA PPID 5/3565, stream selection, reconnect, local and remote multihoming |
| Inbound multi-association SCTP | Implemented/interop pending | Closed peer profiles, PPID validation, ephemeral association links |
| SCTP path events | Implemented/interop pending | Path alarms and metrics; target kernel behavior must be qualified |
| SCTP AUTH / IPsec | Not implemented | Deploy network-layer protection and host policy outside this application |
| ITU 14-bit and ANSI 24-bit MTP3 labels | Implemented/tested | Encode/decode and range checking |
| ITU Q.707 SLTM/SLTA | Implemented/tested | Strict codec and automatic same-link SLTA response over M3UA or M2PA |
| M2PA | Implemented/tested; interop pending | Alignment/proving/ready, streams, 24-bit FSN/BSN, immediate empty ACK, busy/outage, T7, retrieval |
| Q.704 SNMM and full link management over M2PA | Partial | Q.704 heading codec, M2PA TFP/TFR/TFA/TFC/UPU route-state ingestion, COO/XCO/CBD/ECO acknowledgement, XCO retrieval/reroute of unacknowledged user MSUs, ECO retrieval/reroute of the full unacknowledged user-MSU buffer, and CBD/CBA restoration to normal route selection are tested; no complete inhibit/uninhibit, forced reroute, or route-set-test state machines |
| Physical MTP2/TDM | Not implemented | M2PA/SCTP is the lowest native boundary |

## SCCP, SCMG, GTT, and routing

| Area | Status | Implemented boundary |
|---|---|---|
| SCCP UDT/UDTS/XUDT/XUDTS/LUDT/LUDTS | Implemented/tested | ITU and ANSI connectionless relay |
| SCCP addresses and Global Title indicators | Implemented/tested | ITU/ANSI point codes; GTI 1–4; TT, NP, NAI, digits, SSN, RI, national-use |
| Hop counter and optional parameters | Implemented/tested | Relay decrement/rejection; segmentation and importance structure |
| SCCP segmentation reassembly | Implemented/tested | Opt-in, timeout and memory/context bounded; ordered segment validation |
| SCCP SCMG | Implemented/tested | SSA, SSP, SST, SOR, SOG, SSC codecs; route constraints and SST local-state reply |
| Full SCMG coordination | Partial | State and reply behavior exists; no complete coordinated subsystem timer/broadcast procedure |
| SCCP connection-oriented classes | Not implemented | CR/CC/CREF/RLSD/RLC/DT/AK/ERR/IT are not a supported relay profile |
| GTT matching | Implemented/tested | Exact/prefix/length, TT, NP, NAI, SSN, RI, point code, national-use |
| GTT transforms | Implemented/tested | Digits, prefix replacement, strip/prepend/append, TT/NP/NAI/GTI, DPC, SSN, RI, removals |
| GTT chaining and screening | Implemented/tested | Priority/specificity, allow/deny/discard, continuation, loop and max-depth protection |
| Static route matching | Implemented/tested | DPC/mask, OPC masks, NI, SI, NA, RC, priority, ordered linksets |
| Route availability/failover | Implemented/tested | SSNM/SCMG constraints, congestion preference, ingress exclusion, active-link selection |

## Operations and resilience

| Area | Status | Implemented boundary |
|---|---|---|
| Runtime component replacement | Implemented/tested | Links, listeners, routes, and GTT rules can be added/removed without restarting routing |
| Configuration persistence | Implemented/tested | Atomic schema-v1 snapshot, SHA-256 integrity, transactional replace and rollback |
| Alarm lifecycle | Implemented/tested | Bounded active/history sets, raise/update/ack/clear, subscribers |
| Management authentication/RBAC | Implemented/tested | Closed by default; SHA-256 token verifier; viewer/operator/engineer/admin local API roles |
| Audit | Implemented/tested | Synchronous SHA-256 hash chain; bounded memory; optional append+sync disk log; restart recovery and verification |
| Health and Prometheus | Implemented/tested | Structured health map and Prometheus text generation; no bundled HTTP/TLS exporter |
| Raw trace and PCAPNG | Implemented/tested | Disabled by default; packet/byte-bounded ring; header/full capture; DLT_USER0 export |
| Warm-standby HA | Implemented/tested locally; multi-node pending | HMAC snapshots, acknowledged replication, source allow-list, persistence/reload, staleness/clock checks, explicit SHA-256 fencing token |
| Active/active HA and split-brain consensus | Not implemented | No quorum, lease service, Raft, or simultaneous forwarding plane |
| Dynamic RKM state on HA promotion | Partial | Snapshot records it; peers must re-register after promotion |
| Overload protection | Partial | Dispatcher high/low watermark shedding and bounded reassembly/trace/audit/RKM stores; Erlang mailboxes are not hard bounded |
| OpenTelemetry, SNMP, NETCONF/RESTCONF | Not implemented | Prometheus text and Erlang management API only |
| Secrets management | Partial | Only token hashes are configured; HA shared secret is application config and needs an external secret-delivery mechanism |

## Evidence not yet completed

The following are mandatory before an operator treats this as a production STP:

- Linux/target-OS SCTP execution and at least two target-vendor interop runs;
- multihoming path failure, association churn, malformed/fuzz, and recovery
  captures;
- Q.782/Q.784 or operator-equivalent MTP/SCCP campaigns for the selected
  profile;
- stated MPS, latency, loss and memory limits with overload and backpressure
  evidence;
- 24/72-hour soak, host failure, warm-standby promotion, rollback and upgrade
  exercises;
- security threat model, Erlang-distribution hardening, secret rotation, OS
  hardening and audit-retention review;
- a documented decision excluding unsupported SCCP connection-oriented and
  Q.704/M2PA procedures, or implementation and certification of them.
