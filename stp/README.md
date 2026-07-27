# Erlang/OTP 29 STP interoperability lab

`stp/` is a modular SS7/SIGTRAN STP for operator interoperability,
replacement, failover, routing, GTT and negative testing.

It supports the features asked about explicitly:

- **GT and TT-based routing:** GTI 1–4, translation type, numbering plan,
  nature of address, digits, SSN, routing indicator, point code and
  national-use matching.
- **GT/TT transformation:** chained rules can rewrite digits and change TT,
  NP, NAI, GTI, DPC, SSN and routing indicator, or screen with
  allow/deny/discard actions.
- **Multihoming:** outbound SCTP supports multiple local and remote addresses;
  inbound listeners support multiple local addresses and multiple concurrent
  peer associations.
- **M3UA and M2PA:** M3UA ASP/SGP, SSNM, RKM and management messages; M2PA
  alignment, sequence/acknowledgement, link status, T7 and retrieval.
- **Replaceable peers:** loopback links and real SCTP peers use the same link
  boundary and can be removed/added at runtime.

This is materially closer to a carrier STP test platform, but it is not a
certified drop-in production STP. The precise implemented and open boundaries
are in the [support matrix](docs/support-matrix.md). The implementation-ready
handoff is in the [remaining-work backlog](docs/remaining-work.md).

## Build and verify

From the repository root:

```powershell
.\build.cmd stp -Test
```

The build locates `C:\Program Files\Erlang OTP`, requires OTP release 29,
compiles with warnings as errors, and currently runs 77 deterministic tests.
Real SCTP interop must run on Linux or another target host with kernel SCTP;
the Windows suite uses deterministic loopback transport.

## Linux container deployment

Native Linux with kernel SCTP is the recommended deployment platform. The
repository includes an OTP 29 multi-stage
[`Dockerfile`](Dockerfile), a root
[`compose.yaml`](../compose.yaml), a fully host-mounted OTP target system, and
`run_erl`/`to_erl` console access. The build uses OTP `systools` to create a
genuine embedded release with bundled ERTS, `.rel`, boot scripts, `RELEASES`,
`start_erl.data`, a release package and versioned libraries. Its
operator-visible paths include
`/lab/stp/system/releases/1.0/sys.config` and
`/lab/stp/system/lib/telco_stp-0.3.0/ebin`.

On Linux with OTP 29, a complete non-container target can also be built with:

```bash
chmod 0755 stp/build-linux.sh stp/build-release-linux.sh
./stp/build-release-linux.sh
```

Follow the complete
[Linux Docker deployment guide](docs/linux-docker-deployment.md). Every
supported `sys.config` field is described in the
[configuration reference](config/README.md).

Start the default lab:

```powershell
.\start-lab.cmd
```

Inspect it:

```erlang
telco_stp:status().
telco_stp:health().
telco_stp:alarms().
telco_stp:prometheus().
```

## Chained GT/TT routing example

The first rule normalizes digits and changes TT. The second rule matches the
new TT, changes it again, and converts GT routing to DPC/SSN routing:

```erlang
telco_stp:add_gtt_rule(#{
    id => normalize_mobile,
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

telco_stp:add_gtt_rule(#{
    id => route_mobile,
    priority => 20,
    match => #{prefix => <<"077">>, translation_type => 1},
    set => #{
        translation_type => 2,
        point_code => 4321,
        ssn => 6,
        routing_indicator => ssn
    }
}).
```

Rules also accept `exact_digits`, `min_length`, `max_length`, `ssn`,
`routing_indicator`, `point_code` and `national_use`. Transform fields include
`digits`, `strip_digits`, `prepend_digits`, `append_digits`, `gti`, `remove`,
and all GT/address output fields. Chaining has loop and maximum-depth
protection.

## Multihomed production-facing M3UA peer

```erlang
telco_stp:add_link(#{
    name => real_msc,
    linkset => msc_as,
    adaptation => m3ua,
    transport => telco_stp_transport_sctp,
    role => asp,
    point_code_variant => itu,
    sccp_variant => itu,
    remote_hosts => [{192,0,2,10}, {192,0,2,11}],
    remote_port => 2905,
    local_ips => [{192,0,2,20}, {192,0,2,21}],
    local_port => 2905,
    routing_context => [100],
    traffic_mode => loadshare,
    heartbeat_interval_ms => 30000,
    heartbeat_timeout_ms => 10000,
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
}).
```

For M2PA use `adaptation => m2pa`, port 3565, `point_code_variant`, and the
M2PA timer fields documented in the operator guide. RKM applies to M3UA only.
See [`config/m2pa-peer.example.config`](config/m2pa-peer.example.config).

## Hot replacement workflow

```erlang
telco_stp:save_configuration(
    "snapshots/before-real-msc.bin"
).
telco_stp:set_link_state(lab_msc, down).
telco_stp:remove_link(lab_msc).
telco_stp:add_link(RealMscConfig).
```

Release traffic only after association state, ASP/M2PA state, route state,
health and alarms pass. Roll back atomically with:

```erlang
telco_stp:load_configuration(
    "snapshots/before-real-msc.bin", replace
).
```

Inbound production ASPs use
[`config/inbound-sgp.example.config`](config/inbound-sgp.example.config).
The controlled drain, verification and rollback sequence is in the
[operator guide](docs/operator-guide.md).

## Secure operations

The authenticated management boundary is disabled until
`management_credentials` is configured. Store only the SHA-256 token digest:

```erlang
crypto:hash(sha256, <<"a-long-random-token">>).
telco_stp:management(Token, status).
telco_stp:verify_audit().
```

Roles are `viewer`, `operator`, `engineer`, and `admin`. The direct
`telco_stp:*` Erlang API is a trusted local boundary; do not expose Erlang
distribution to untrusted networks.

Tracing is disabled by default and bounded when enabled:

```erlang
telco_stp:set_trace(#{
    enabled => true,
    max_packets => 10000,
    max_bytes => 67108864,
    capture_payload => true,
    header_bytes => 128
}).
telco_stp:export_pcapng("artifacts/stp.pcapng").
```

PCAPs and signaling payloads can contain subscriber data. Apply access,
retention and deletion policy.

## Main APIs

```erlang
%% Components and routes
telco_stp:add_link(Config).
telco_stp:remove_link(Name).
telco_stp:add_listener(Config).
telco_stp:remove_listener(Name).
telco_stp:add_route(Route).
telco_stp:remove_route(Id).
telco_stp:add_gtt_rule(Rule).
telco_stp:remove_gtt_rule(Id).

%% Traffic and state
telco_stp:transfer(MtpTransfer).
telco_stp:inject_m3ua(Link, Binary).
telco_stp:inject_m2pa(Link, Stream, Binary).
telco_stp:retrieve_m2pa(Link, AfterFsn).
telco_stp:set_destination_state(Link, Status, PCs, Metadata).
telco_stp:set_subsystem_state(Link, PC, SSN, Status, Metadata).

%% Operations
telco_stp:health().
telco_stp:prometheus().
telco_stp:alarms().
telco_stp:audit_events().
telco_stp:ha_status().
telco_stp:ha_snapshot().
telco_stp:promote_standby(FencingToken).
```

Route masks are 24-bit integer masks, not prefix lengths. `16#ffffff` is an
exact ANSI point-code mask, `16#3fff` an exact ITU point-code mask, and `0` a
default. Default routes should not remain enabled in an operator topology.

## Repository map

```text
src/
  telco_stp_link.erl             per-link M3UA/M2PA state
  telco_stp_m3ua.erl             RFC 4666 codec
  telco_stp_m2pa.erl             RFC 4165 codec
  telco_stp_mtp3.erl             ITU/ANSI labels
  telco_stp_slt.erl              Q.707 SLTM/SLTA
  telco_stp_sccp.erl             SCCP connectionless codec
  telco_stp_scmg.erl             subsystem management state
  telco_stp_reassembly.erl       bounded SCCP reassembly
  telco_stp_gtt.erl              chained GTT and screening
  telco_stp_rkm.erl              M3UA routing-key management
  telco_stp_route_table.erl      routing and path constraints
  telco_stp_dispatcher.erl       relay, overload and faults
  telco_stp_mgmt.erl             token/RBAC boundary
  telco_stp_audit.erl            durable hash-chain audit
  telco_stp_ha.erl               signed warm-standby snapshots
  telco_stp_trace.erl            bounded raw trace/PCAPNG
```

## Open production gates

The principal functional gaps are full Q.704 network-management
changeover/changeback/inhibit procedures, SCCP connection-oriented classes,
complete SCMG coordination timers, IPSP double exchange, SCTP security
integration, hard bounded ingress queues, active/active consensus, and a
standard remote northbound protocol.

Even for the implemented profile, operator acceptance still requires vendor
interop, target-platform multihoming failure, fuzz, capacity, overload,
24/72-hour soak, HA promotion, security and upgrade/rollback evidence.
Task boundaries and acceptance criteria for the next implementation session
are tracked in [remaining-work.md](docs/remaining-work.md).
