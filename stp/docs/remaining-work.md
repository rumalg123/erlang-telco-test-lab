# STP remaining implementation backlog

This document is the implementation handoff for future sessions. Read it
together with:

- [`support-matrix.md`](support-matrix.md) for the authoritative current claim;
- [`architecture.md`](architecture.md) for existing component boundaries;
- [`operator-guide.md`](operator-guide.md) for operational behavior.

Do not mark an item implemented in the support matrix until its automated
tests pass on OTP 29. Do not mark an interoperability or carrier-acceptance
item complete without attaching the corresponding external evidence.

## Current verified baseline

- Application version: `0.3.0`.
- OTP release: 29.
- Deterministic suite: 63 passing tests.
- Implemented core: M3UA ASP/SGP, SSNM, RKM, M2PA basic link procedures,
  ITU/ANSI MTP3 labels, ITU SLTM/SLTA response, connectionless SCCP, bounded
  reassembly, SCMG state, chained GTT, routing/failover, Q.704 SNMM codec
  and basic M2PA transfer-management route-state ingestion, RBAC/audit,
  Prometheus text, PCAPNG trace, and manual warm-standby HA.
- Baseline command: `.\build.cmd stp -Test`.

## P0 — complete Q.704 MTP3 network management

This is the largest protocol blocker for production-facing M2PA.

Implement:

- SNMM codec profiles for the selected ITU and ANSI variants;
- changeover order/acknowledgement, including extended sequence numbers needed
  by M2PA;
- emergency changeover;
- changeback declaration/acknowledgement;
- link inhibit, uninhibit and force-uninhibit procedures;
- transfer prohibited, restricted and allowed;
- controlled/forced rerouting and traffic restart;
- route-set congestion and route-set-test procedures;
- per-link and per-route timers, retry limits and state visibility;
- retrieval/resequencing integration with `telco_stp:retrieve_m2pa/2`.

Expected code boundaries:

- add a dedicated `telco_stp_snmm` codec;
- add a supervised MTP3 network-management state worker;
- keep M2PA framing/sequencing inside `telco_stp_link`;
- apply resulting route state through `telco_stp_route_table`;
- expose state, counters and alarms through `telco_stp:status/0`.

Acceptance:

- known ITU/ANSI message vectors and malformed vectors;
- normal, emergency and failed changeover scenarios;
- retrieval with 24-bit M2PA sequence wrap;
- changeback without duplicate or incorrectly ordered retransmission;
- inhibit/uninhibit collision and timer-expiry tests;
- Q.782/operator-equivalent scenario results;
- support matrix updated only for the exact profile proven.

Completed first slice:

- Q.704 heading-code codec for CHM, ECM, FCM, TFM, RSM, MIM, TRM, DLM and UPU
  message families;
- deterministic ITU/ANSI round-trip and malformed-vector tests;
- M2PA ingress handling for TFP, TFR, TFA, TFC and UPU into the existing
  destination-state constraints.

## P0 — bounded ingress and overload control

The current dispatcher sheds above a mailbox watermark, but the mailbox itself
is not hard bounded.

Implement:

- bounded ingress queues partitioned by priority/service indicator or peer;
- configurable per-link and global message/byte limits;
- admission policy for discard, reject, pause and priority preservation;
- SCTP receive-side flow-control strategy where supported;
- fair scheduling so one peer cannot starve others;
- explicit overload levels and hysteresis;
- bounded delayed-fault queues and load-generator submissions;
- memory, queue age, shed reason and recovery metrics.

Acceptance:

- sustained overload cannot exceed the configured memory envelope;
- priority traffic behavior is deterministic and documented;
- no unbounded auxiliary queue or timer population;
- burst, slow-consumer and malicious-peer tests;
- measured recovery time and loss policy.

## P0 — production HA and split-brain prevention

The current implementation is manual warm standby. It is not active/active
consensus.

Implement or integrate:

- an external quorum/lease/fencing authority;
- automatic promotion only while holding a valid lease;
- immediate forwarding shutdown on lease loss;
- monotonic replicated log or consensus-backed state version;
- duplicate-node and network-partition handling;
- dynamic RKM ownership/restoration or deterministic peer re-registration;
- alarm/audit/configuration continuity;
- rolling upgrade and version compatibility policy.

Expected boundary:

- do not turn `telco_stp_ha` into an ad-hoc consensus implementation;
- define a small lease provider behavior and implement a proven external
  provider;
- keep manual promotion available for isolated labs.

Acceptance:

- old primary is demonstrably fenced before the new node forwards;
- partition, delayed packet, node pause and clock-skew campaigns;
- repeated failover without configuration regression;
- restart from persisted replica;
- upgrade and rollback across adjacent schema/application versions.

## P1 — SCCP connection-oriented service

Implement only if target scenarios require it:

- CR, CC, CREF;
- DT1, DT2, AK;
- ED, EA if required by the selected class;
- RLSD, RLC, ERR and IT;
- protocol classes 2 and 3;
- local-reference allocation and collision protection;
- connection state, credit/window, sequencing, inactivity and release timers;
- relay behavior and failure return causes;
- bounded connection count and buffered bytes.

Expected boundary:

- extend `telco_stp_sccp` for codec work;
- use a separate supervised connection-state service rather than storing
  connections in the dispatcher.

Acceptance:

- full lifecycle, simultaneous release, reset/error and timer tests;
- malformed reference/sequence/credit vectors;
- bounded-resource and peer-loss cleanup tests;
- target-vendor interop for every claimed SCCP class.

## P1 — complete SCMG coordination

Existing SSA/SSP/SST/SOR/SOG/SSC codec and route constraints are not a complete
coordinated subsystem-management procedure.

Implement:

- SST scheduling, retry and cancellation timers;
- concerned-subsystem and concerned-point-code tables;
- SSA/SSP/SSC propagation to configured peers;
- SOR/SOG coordination and collision handling;
- multiplicity handling for replicated subsystems;
- restart recovery and stale-state expiry;
- rate limiting to prevent management-message storms.

Acceptance:

- remote/local subsystem failure and recovery scenarios;
- timer, duplicate, collision and restart cases;
- routing changes only for the relevant PC/SSN/Network Appearance;
- bounded table and timer population.

## P1 — complete M3UA IPSP double exchange

Implement:

- explicit IPSP single-exchange and double-exchange roles;
- independent local and remote ASP state;
- simultaneous ASPUP/ASPAC collision handling;
- per-routing-context AS state;
- recovery after one-sided restart;
- invalid transition Error/Notify behavior.

Acceptance:

- state-transition matrix tests for both exchange modes;
- simultaneous start, restart, timeout and malformed-control scenarios;
- interop with target IPSP implementations.

## P1 — standard northbound operations

The token/RBAC Erlang API is a local control boundary, not a standard remote
management service.

Implement:

- authenticated TLS endpoint using the operator-selected protocol, such as
  REST or NETCONF;
- mutual TLS or equivalent machine identity;
- credential/role integration without exposing raw tokens in logs;
- request IDs, idempotency and optimistic configuration versioning;
- streamed alarms/events with backpressure;
- readiness/liveness and protected Prometheus HTTP endpoints;
- configuration validation/dry-run and change transaction audit.

Optional:

- SNMP alarm/status adapter;
- OpenTelemetry traces/metrics export.

Acceptance:

- authorization matrix and negative tests;
- TLS/certificate rotation tests;
- request replay/idempotency tests;
- rate limiting and slow-client behavior;
- API compatibility/versioning documentation.

## P1 — security and secrets

Implement or integrate:

- external delivery and rotation of HA secrets and management credentials;
- SCTP AUTH and/or IPsec deployment profile where the target requires it;
- hardened Erlang distribution with strict network isolation;
- audit-log rotation/archival that preserves chain verification;
- sensitive-field redaction and PCAP access/retention controls;
- dependency, static-analysis and fuzzing pipeline.

Acceptance:

- documented threat model;
- secret/certificate rotation without uncontrolled signaling interruption;
- penetration test and remediation record;
- verified least-privilege host/service configuration.

## P2 — physical SS7 boundary

Only implement when physical legacy integration is required:

- an MTP2 adapter behavior below the existing MTP3 boundary;
- hardware/TDM driver integration;
- link alignment, proving, error monitoring and FISU/LSSU/MSU behavior;
- clocking, timeslot and hardware alarm management.

This requires selected hardware and cannot be certified through loopback tests.

## External evidence backlog

These are not coding tasks, but remain mandatory release gates:

- Linux/target-kernel SCTP execution;
- at least two target-vendor interoperability campaigns;
- multihoming path failure and association churn captures;
- malformed input and protocol fuzz campaigns;
- Q.782/Q.784 or operator-equivalent conformance;
- stated MPS and latency targets with memory/overload results;
- 24/72-hour soak;
- process, node, host and network-partition chaos;
- fenced promotion, disaster recovery and rolling upgrade;
- security and operational-readiness reviews.

Store resulting PCAPs, reports and environment manifests under `lab/artifacts/`
or an external controlled evidence repository. Do not commit subscriber data,
live secrets or unrestricted production captures.

## Suggested implementation order

1. Freeze the intended deployment profile: M3UA-only or M3UA plus M2PA.
2. For M2PA production use, complete Q.704 network management first.
3. Implement bounded ingress and prove overload behavior.
4. Integrate external HA fencing/lease control.
5. Add SCCP connection-oriented service only when scenarios require it.
6. Complete SCMG and IPSP procedures for the selected peer profiles.
7. Add remote operations/security integration.
8. Run the external acceptance campaign.

## Resume instruction for a future session

Use this prompt:

> Read `stp/docs/support-matrix.md`,
> `stp/docs/remaining-work.md`, `stp/docs/architecture.md`, and
> `stp/docs/operator-guide.md`. Run `.\build.cmd stp -Test` to establish the
> 63-test OTP 29 baseline. Implement the highest-priority incomplete item I
> name, preserve existing component boundaries, add deterministic malformed
> and state-machine tests, and update the support matrix only for behavior
> actually proven.
