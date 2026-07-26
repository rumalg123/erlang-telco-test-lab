# STP architecture

## Design objective

Every signaling peer is replaceable at runtime. The stable boundary is an M3UA
or M2PA signaling link plus management operations; simulated MSC/SMSC/HLR
behavior does not live inside the STP.

```text
                    +------------- telco_stp -------------+
SCTP M3UA/M2PA <--> | transport -> per-link gen_statem     |
loopback        <--> |                    |                 |
                    |                    v                 |
                    | dispatcher -> routes/path constraints|
                    |    |       |       |       |         |
                    |  SCCP    GTT/RKM  SSNM/SCMG  SLT     |
                    |    |               |                 |
                    | reassembly      alarms/metrics       |
                    |                                      |
                    | auth/RBAC -> audit   trace -> PCAPNG |
                    | warm-standby signed state replication|
                    +--------------------------------------+
```

`telco_stp_sup` uses `rest_for_one`. Foundational stores start before the
dynamic link supervisor, routing, dispatcher and HA workers. A per-link crash
is isolated and restored by the link manager from its existing configuration.

## Adaptation and transport boundary

The transport contract accepts binary frames plus stream/PPID metadata. The
loopback transport and outbound/inbound SCTP transports use the same per-link
state machine.

- M3UA defaults to SCTP port 2905 and PPID 3.
- M2PA defaults to SCTP port 3565 and PPID 5.
- M3UA transfer data is carried through the RFC 4666 protocol-data parameter.
- M2PA carries encoded ITU/ANSI MTP3 messages on stream 1 and link status on
  the RFC-defined stream.

Outbound SCTP uses multiple local addresses and OTP `connectx_init` for
multiple remote addresses. Inbound one-to-many listeners match associations
against ordered, closed peer profiles and create ephemeral per-association
links. Unknown peers and invalid PPIDs are rejected/alarmed.

## Transfer model

The internal primitive is:

```erlang
#{
    opc := non_neg_integer(),
    dpc := non_neg_integer(),
    si := 0..15,
    ni := 0..3,
    mp := 0..3,
    sls := non_neg_integer(),
    payload := binary(),
    routing_context => [0..16#ffffffff],
    network_appearance => 0..16#ffffffff,
    point_code_variant => itu | ansi,
    sccp_variant => itu | ansi
}
```

The M3UA codec accepts RFC field widths. The routing layer uses 24-bit masks,
which cover ANSI 24-bit and ITU 14-bit point codes.

## Routing decision

1. Validate transfer and optional M3UA context fields.
2. For SCCP SI 3, optionally reassemble segmented XUDT/LUDT, process SCMG,
   decrement hop count, and perform GTT when the called address uses GT.
3. Match DPC/mask, OPC patterns, NI, SI, Network Appearance and Routing
   Context.
4. Prefer the most specific DPC mask, then lower route priority.
5. Exclude unavailable destinations/subsystems and the ingress link; prefer
   unrestricted and lower-congestion paths.
6. Try linksets in configured order.
7. Apply override, SLS-stable weighted loadshare, or broadcast.
8. Apply a route-provided routing context and send through the selected
   link’s M3UA or M2PA adaptation.

ITU Q.707 SLTM is intercepted before transit routing and acknowledged on the
same source link. This avoids requiring a route for link maintenance traffic.

## GTT pipeline

Rules are ordered by match specificity and numeric priority. A rule can:

- match exact/prefix/length, TT, NP, NAI, SSN, RI, point code and national-use;
- allow, deny, discard, or translate;
- replace/strip/prepend/append digits;
- set TT, NP, NAI, GTI, point code, SSN, RI and national-use;
- remove selected address fields;
- continue into another rule.

The engine records applied rule IDs and rejects address loops or a chain above
the configured depth.

## Bounded state

Explicit bounds exist for SCCP reassembly contexts/bytes/time, RKM
registrations and RC range, alarms/history, in-memory audit history, raw trace
packets/bytes, and GTT chain depth. Dispatcher high/low watermarks shed new
work with hysteresis.

Erlang process mailboxes themselves are not hard bounded. Target-host overload
testing must prove that configured watermarks keep memory within the operator
limit.

## Management, audit, and observability

The authenticated API stores token digests, compares them in constant time,
maps identities to roles, and synchronously records each success, denial and
authentication failure. With `audit_log_path` configured, framed audit events
are append+sync written, reloaded on restart, and hash-chain verified.
Corruption causes the audit worker/application start to fail rather than
silently starting a new chain.

Prometheus output is generated as text by `telco_stp:prometheus/0`; deployment
must put its own authenticated HTTP/TLS exporter around that function. Raw
trace is disabled by default and uses a packet/byte-bounded ring. PCAPNG
records use DLT_USER0 with a small `TSTP` metadata prefix identifying
direction, adaptation, stream and link.

## HA boundary

In primary mode, the HA worker creates schema-versioned snapshots containing
static configuration, destination states, subsystem states and RKM
registration inventory. It HMAC-SHA256 signs each snapshot and waits for an
acknowledgement from allowed standby nodes. A standby verifies source, HMAC,
schema/configuration, clock skew and monotonic newness, then atomically
persists the replica.

Promotion requires an operator-supplied token matching the configured SHA-256
fencing digest and a non-stale replica. Static configuration and route/SCMG
state are restored; dynamic RKM peers must re-register.

This is warm standby. Erlang distribution connectivity plus a static fencing
token is not consensus or a distributed lease. Active/active forwarding,
automatic failover and split-brain prevention require an external quorum/lease
design and remain outside the implemented claim.
