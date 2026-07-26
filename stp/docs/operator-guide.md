# STP operator guide

## Scope and safety

Connect this lab only to signaling networks for which the operator has
explicit authorization. Use isolated interfaces, firewall rules and test
point codes/GT ranges. Do not put it in public-network transit or
emergency-service paths based only on the local regression suite.

The [support matrix](support-matrix.md) distinguishes implemented behavior
from target-platform and carrier-acceptance evidence.

## Prerequisites

- Erlang/OTP 29.
- Linux or another target OS with kernel SCTP for real M3UA/M2PA.
- Port 2905/PPID 3 for M3UA or port 3565/PPID 5 for M2PA.
- Two isolated paths/interfaces for meaningful SCTP multihoming tests.
- Synchronized clocks for HA staleness checks and trace correlation.
- Restricted, encrypted storage for audit logs, snapshots and PCAPs.

Build and run the deterministic suite:

```powershell
.\build.cmd stp -Test
```

The Windows build validates codecs/state machines through loopback. It does
not validate Windows SCTP, a vendor peer, or the deployment kernel.

## Outbound M3UA

Use `remote_hosts` and `local_ips` for multihoming:

```erlang
#{
    name => msc_a,
    linkset => msc_a_as,
    adaptation => m3ua,
    transport => telco_stp_transport_sctp,
    role => asp,
    point_code_variant => itu,
    sccp_variant => itu,
    remote_hosts => [{198,51,100,10}, {198,51,100,11}],
    remote_port => 2905,
    local_ips => [{192,0,2,20}, {192,0,2,21}],
    local_port => 2905,
    routing_context => [100],
    traffic_mode => loadshare,
    heartbeat_interval_ms => 30000,
    heartbeat_timeout_ms => 10000,
    heartbeat_failure_action => inactive,
    rkm => #{
        mode => provisioned_only,
        allowed_network_appearances => [1],
        allowed_dpcs => [{0, 4321}],
        provisioned_keys => [#{
            traffic_mode_type => loadshare,
            network_appearance => 1,
            destinations => [#{
                dpc => {0, 4321},
                service_indicators => any,
                originating_point_codes => any
            }]
        }]
    }
}.
```

RKM is closed unless enabled for the link. `provisioned_only` is the safer
operator profile. `dynamic` permits validated runtime registrations within
the allowed NA/DPC policy and global registration/RC bounds.

## Inbound M3UA/M2PA

Use [`../config/inbound-sgp.example.config`](../config/inbound-sgp.example.config).
Profiles are ordered and closed by default. Each must identify allowed remote
addresses and can additionally match a port. `accept_any => true` is suitable
only for an isolated negative-test interface.

Associations become ephemeral links. Removing a listener removes those links.
Static listener/profile configuration is persisted; live SCTP associations
are not.

For an M2PA profile set `adaptation => m2pa`,
`point_code_variant => itu | ansi`, and suitable timers:

```erlang
#{
    adaptation => m2pa,
    point_code_variant => itu,
    sccp_variant => itu,
    m2pa_proving_ms => 500,
    m2pa_alignment_timeout_ms => 10000,
    m2pa_t7_ms => 1000
}.
```

M2PA uses stream 0 for applicable link-status traffic and stream 1 for user
data. It retains unacknowledged user data for retrieval. The implemented
boundary does not claim complete Q.704 changeover/changeback or inhibit
procedures. A complete outbound example is
[`../config/m2pa-peer.example.config`](../config/m2pa-peer.example.config).

## Routes, contexts, and failover

Routes can match:

- `dpc` plus 24-bit integer `mask`;
- `opc_patterns => [{Mask, Opc}]`;
- `ni`, `si`, `network_appearance`, and `routing_context`;
- lower numeric `priority`;
- ordered `linksets`;
- `traffic_mode => override | loadshare | broadcast`.

`16#ffffff` is an exact ANSI mask, `16#3fff` exact ITU, and `0` a default.
Avoid persistent default routes in operator topologies.

Inspect live selection inputs:

```erlang
telco_stp:links().
telco_stp:routes().
telco_stp:destination_states().
telco_stp:subsystem_states().
telco_stp:rkm_registrations().
```

M3UA DUNA/DAVA/DRST/SCON/DUPU and SCCP SSA/SSP/SSC state constrain path
selection. DAUD and SST receive state-based replies. Ingress routing excludes
the source link.

## GTT and screening

Use `match` and `set` maps for advanced rules:

```erlang
telco_stp:add_gtt_rule(#{
    id => normalize_e164,
    priority => 10,
    match => #{
        prefix => <<"9477">>,
        translation_type => 0,
        numbering_plan => 1,
        nature_of_address => 4
    },
    set => #{
        replace_prefix => {<<"9477">>, <<"077">>},
        translation_type => 1
    },
    continue => true
}).
```

Screen before translation with `action => allow | deny | discard`. Deny and
discard rules cannot transform. Translation rules can change digits, TT, NP,
NAI, GTI, DPC, SSN, routing indicator and national-use. Chain depth defaults
to 8 and address loops are rejected.

SCCP reassembly is opt-in per link with `sccp_reassembly => true`. Configure
context count, per-context bytes, total bytes and timeout globally. Do not
enable it without sizing those limits for the test profile.

## Secure management and audit

Generate long random tokens outside Erlang configuration management and store
only their SHA-256 digest:

```erlang
crypto:hash(sha256, Token).
```

Configure identities:

```erlang
{management_credentials, [
    #{
        id => noc_viewer,
        token_sha256 => <<32-byte-digest>>,
        roles => [viewer]
    },
    #{
        id => lab_engineer,
        token_sha256 => <<32-byte-digest>>,
        roles => [engineer]
    }
]}.
```

Roles:

- `viewer`: status/configuration/state reads;
- `operator`: reads and operational state/alarm/fault controls;
- `engineer`: reads, operations and topology/routing configuration;
- `admin`: all recognized management requests.

Call `telco_stp:management(Token, Request)`. Direct `telco_stp:*` calls are a
trusted-local interface. Erlang distribution must be disabled or restricted
and protected according to the deployment threat model.

Set `audit_log_path` to enable append+sync persistence. Startup fails on a
corrupt configured audit log. Monitor `telco_stp:verify_audit/0` and the
`{management,audit_persistence}` alarm. Protect/rotate the file using an
operator procedure that preserves chain evidence.

## Observability and trace

```erlang
telco_stp:health().
telco_stp:prometheus().
telco_stp:alarms().
telco_stp:alarm_history().
telco_stp:acknowledge_alarm(Id, Operator).
```

`prometheus/0` returns exposition text; it does not open an HTTP port. Put a
small authenticated/TLS collector around it.

Trace is off by default. Configure packet and byte limits before enabling it,
then export with `telco_stp:export_pcapng/1`. The PCAPNG uses DLT_USER0 and a
`TSTP` metadata header. Captures can contain MSISDNs and other subscriber
information.

## Warm standby

Use distinct distributed Erlang node names and protect distribution with
network isolation and current OTP security configuration. Primary and standby
must share a random secret of at least 32 bytes.

Primary:

```erlang
{ha, #{
    mode => primary,
    peers => ['stp_b@standby-host'],
    interval_ms => 1000,
    replication_timeout_ms => 2000,
    max_staleness_ms => 10000,
    max_clock_skew_ms => 5000,
    shared_secret => <<"at-least-32-random-secret-bytes">>,
    fencing_token_sha256 => undefined,
    snapshot_path => undefined
}}.
```

The corresponding files are
[`../config/ha-primary.example.config`](../config/ha-primary.example.config)
and
[`../config/ha-standby.example.config`](../config/ha-standby.example.config).

Standby:

```erlang
{ha, #{
    mode => standby,
    peers => ['stp_a@primary-host'],
    interval_ms => 1000,
    replication_timeout_ms => 2000,
    max_staleness_ms => 10000,
    max_clock_skew_ms => 5000,
    shared_secret => <<"the-same-32-byte-random-secret">>,
    fencing_token_sha256 => <<32-byte-sha256-digest>>,
    snapshot_path => "/var/lib/telco_stp/standby.snapshot"
}}.
```

Before promotion, externally fence the former primary and verify that it
cannot send signaling. Then:

```erlang
telco_stp:ha_status().
telco_stp:promote_standby(FencingToken).
```

The token check is an explicit operator gate, not distributed consensus. Do
not automate promotion without an external quorum/lease/fencing system.
Dynamic RKM peers must re-register after promotion.

## Component replacement and rollback

1. Save the known-good configuration.
2. Stop new scenarios and drain the generator.
3. Administratively take the simulated link down and remove it.
4. Add the real SCTP link/listener.
5. Verify association, ASP/M2PA state, route state, heartbeat/SLT, health and
   alarms.
6. Run a low-rate probe and capture it.
7. Ramp only through approved test levels.
8. On failure, isolate the real peer and restore the snapshot in `replace`
   mode.

```erlang
telco_stp:save_configuration("snapshots/pre-peer.bin").
telco_stp:set_link_state(lab_peer, down).
telco_stp:remove_link(lab_peer).
telco_stp:add_link(ProductionLink).
telco_stp:load_configuration("snapshots/pre-peer.bin", replace).
```

## Operator acceptance record

Before declaring the selected profile usable, record:

- exact OTP, OS/kernel, NIC and peer-vendor releases;
- negotiated SCTP addresses/streams, M3UA/M2PA parameters and captures;
- path failure, association churn and restart behavior;
- GT/TT/NP/NAI screening and transform conformance vectors;
- malformed/fuzz corpus results;
- MPS, latency percentiles, memory, shedding and loss behavior;
- required 24/72-hour soak;
- standby persistence/promotion, fencing and rollback results;
- firewall, Erlang distribution, OS hardening, secret rotation, PCAP and audit
  retention reviews.
