# Full lab roadmap and acceptance gates

## STP checkpoint — 2026-07-26

The OTP 29 STP now implements:

- M3UA ASP/SGP, heartbeat, traffic modes, SSNM, Error/Notify and policy-bounded
  RKM;
- outbound/inbound SCTP adapter boundaries with local/remote multihoming and
  M3UA/M2PA PPIDs/streams;
- M2PA alignment, proving, sequence/acknowledgement, link status, T7 and
  retrieval;
- ITU/ANSI MTP3 labels and ITU Q.707 SLTM/SLTA response;
- SCCP connectionless ITU/ANSI, bounded reassembly, SCMG state/replies;
- chained GT/TT/NP/NAI translation, digit/address transformation and
  screening;
- route/context/OPC matching, congestion-aware failover and hot component
  replacement;
- RBAC management, restart-safe hash-chain audit, alarms, health, Prometheus
  text and bounded PCAPNG trace;
- acknowledged HMAC warm-standby snapshots, persistence and explicit fenced
  promotion.

The deterministic OTP 29 suite contains 79 passing tests. The authoritative
scope and evidence boundary is `stp/docs/support-matrix.md`. Actionable
implementation tasks and acceptance criteria are in
`stp/docs/remaining-work.md`.

Still open for a broad production STP claim:

- full Q.704 SNMM changeover/changeback, inhibit and route-set procedures;
- SCCP connection-oriented classes and complete SCMG coordination timers;
- dedicated IPSP double-exchange procedure and SCTP security integration;
- hard-bounded ingress queues and a standard remote northbound interface;
- external-consensus active/active HA and rolling upgrade orchestration;
- target-host vendor interop, fuzz, capacity, multihoming chaos, soak,
  security and upgrade/rollback evidence.

## STP acceptance campaign

1. Freeze the intended ITU/ANSI, M3UA/M2PA, SCCP and GTT profile.
2. Run official/operator codec and state-machine vectors plus a malformed and
   fuzz corpus.
3. Interoperate with at least two target vendor releases.
4. Execute SCTP path failure and association churn on the target OS/kernel.
5. Measure MPS, latency, loss, memory and overload policy at stated limits.
6. Complete 24/72-hour soak and process/host failure campaigns.
7. Exercise fenced standby promotion, peer recovery, snapshot rollback and
   application upgrade.
8. Complete threat model, hardening, secret rotation and audit/trace retention
   review.

## HLR/HSS simulator

- MAP mobility, authentication, subscriber data and supplementary services;
- AuC vectors with pluggable secrets;
- optional Diameter S6a/Cx bridge;
- deterministic subscribers, scenario faults and hot replacement by a real
  HLR/HSS endpoint.

Acceptance requires a MAP/Diameter catalog, privacy controls, deterministic
fixtures, load targets and vendor interop evidence.

## MSC/VLR simulator

- BSSAP/DTAP mobility and call procedures;
- MAP integration with HLR and SMS routing;
- ISUP call/circuit model;
- optional SIP/IMS interworking;
- attach, location update, MO/MT call and handover load models.

Acceptance requires end-to-end state assertions, negative timers/causes,
stated CPS, soak and a real-MSC replacement exercise.

## SMSC simulator

- MAP MO/MT/alert/status reports;
- SMPP 3.4/5.0 ESME interface, segmentation, receipts and throttling;
- store-and-forward, retries, validity and idempotency;
- optional Diameter/SIP adapters.

Acceptance requires MO/MT scenarios, duplicate/retry proofs, sustained MPS,
data-retention controls and real-SMSC replacement.

## Integrated-lab release

- declarative topology and scenario runner;
- synchronized virtual time where protocol timers permit;
- traffic drain, hot-swap and rollback workflows;
- deterministic fixtures and a PCAP/event/artifact bundle per run;
- documented protocol profiles and explicit non-support;
- no connection to a public signaling network without authorization and
  isolation.
