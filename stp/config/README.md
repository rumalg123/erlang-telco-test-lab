# `sys.config` reference

This is the complete configuration reference for the current STP application.
The container reads:

```text
/lab/stp/system/releases/1.0/sys.config
```

Compose bind-mounts the complete target system from `stp/deploy/system`; the
active configuration is therefore the host file:

```text
stp/deploy/system/releases/1.0/sys.config
```

`sys.config` is an Erlang term file. It must contain one list, end with a
period, and use Erlang syntax exactly:

```erlang
[
    {telco_stp, [
        {links, []},
        {listeners, []},
        {routes, []}
    ]}
].
```

Configuration is read at VM boot. Editing the mounted file does not
automatically change already-running application state. Use runtime management
functions for a controlled live change, or execute `init:restart().`/restart
the container to reread the entire file.

## Top-level `telco_stp` fields

| Field | Type/default | Meaning |
|---|---|---|
| `links` | list, `[]` | Static outbound, loopback, or otherwise explicitly configured signaling links |
| `listeners` | list, `[]` | Inbound one-to-many SCTP listeners and their allowed peer profiles |
| `routes` | list, `[]` | Static MTP routing table |
| `gtt_rules` | list, `[]` | SCCP global-title matching, screening and transformation rules |
| `gtt_max_chain_depth` | integer, `8` | Maximum number of continued GTT rules; valid range 1-64 |
| `sccp_reassembly_limits` | map | Global bounds for opt-in SCCP segmentation reassembly |
| `rkm_policy` | map | Global M3UA Routing Key Management allocation bounds/default policy |
| `alarm_history_limit` | integer, `1000` | Maximum retained alarm lifecycle events |
| `active_alarm_limit` | integer, `1000` | Maximum simultaneously retained active alarms |
| `audit_history_limit` | integer, `10000` | Maximum in-memory audit records; valid range 1-1,000,000 |
| `audit_log_path` | path or `undefined` | Optional append+sync durable audit log |
| `management_credentials` | list, `[]` | Token-digest identities and roles; empty disables authenticated management |
| `trace` | map | Raw signaling capture configuration |
| `ha` | map | Standalone/primary/standby signed-state replication configuration |
| `overload_limits` | map | Dispatcher mailbox shedding thresholds |
| `fault_profile` | map | Lab drop/duplicate/delay injection; keep disabled for normal operation |

Unknown application keys are ignored by OTP, but malformed values used by a
worker can stop application startup. Always retain a known-good copy and
validate changes in the test lab.

## `links`

Minimum link:

```erlang
#{
    name => msc_a,
    linkset => msc_as,
    adaptation => m3ua,
    transport => telco_stp_transport_sctp,
    remote_hosts => [{192,0,2,10}, {192,0,2,11}],
    remote_port => 2905,
    local_ips => [{192,0,2,20}, {192,0,2,21}]
}
```

### Common link fields

| Field | Type/default | Meaning |
|---|---|---|
| `name` | required term | Unique runtime link identifier |
| `linkset` | required term | Linkset used by routes and traffic-mode selection |
| `adaptation` | `m3ua` or `m2pa`, default `m3ua` | SIGTRAN adaptation |
| `transport` | module, default loopback | `telco_stp_transport_sctp` for outbound SCTP; loopback for deterministic testing |
| `admin` | `up` or `down`, default `up` | Initial administrative state |
| `auto_activate` | boolean, default `false` | Test shortcut that enters ACTIVE after transport connection; avoid for real M3UA peers |
| `weight` | integer 1-100, default `1` | Relative loadshare weight |
| `point_code_variant` | `itu` or `ansi` | ITU 14-bit or ANSI 24-bit MTP3 label profile |
| `sccp_variant` | `itu` or `ansi`, default `itu` | SCCP address/codec profile |
| `sccp_reassembly` | boolean, default `false` | Enables bounded SCCP segmentation reassembly for traffic from this link |
| `reconnect_ms` | integer, default `1000` | Delay before transport reconnect |
| `stream` | non-negative integer, default `0` | Default M3UA SCTP stream; M2PA chooses status/user-data streams by protocol |

For `telco_stp_transport_loopback`, `peer` controls where transmitted frames
go. Its default is `sink`. It may be a PID, `{registered, Name}` for a locally
registered process, or `{link, OtherLink}` to inject into another configured
loopback link. This field is intended for deterministic in-VM tests, not an
external signaling peer.

### Outbound SCTP fields

| Field | Type/default | Meaning |
|---|---|---|
| `remote_host` | IP/hostname | One remote SCTP address; mutually exclusive with `remote_hosts` |
| `remote_hosts` | non-empty list | Remote multihoming addresses used by `connectx_init` |
| `remote_port` | integer | Defaults to 2905 for M3UA or 3565 for M2PA |
| `local_ips` | list, default `[any]` | Local bind/multihoming addresses; each must exist on the Linux host when host networking is used |
| `local_port` | integer, default `0` | Local SCTP port; `0` asks the kernel for an ephemeral port |
| `connect_timeout_ms` | integer, default `5000` | Association setup timeout |

Do not configure both `remote_host` and `remote_hosts`.

### M3UA fields

| Field | Type/default | Meaning |
|---|---|---|
| `role` | `asp` or `sg`, default `sg` | `asp` initiates ASPUP after connecting; `sg` waits for peer ASPUP |
| `routing_context` | list of uint32 | Static routing contexts sent/accepted with ASPAC |
| `network_appearance` | uint32 or `any` | Default network appearance used by destination audit |
| `traffic_mode` | `override`, `loadshare`, or `broadcast`; default `loadshare` | ASP traffic mode and link selection behavior |
| `allowed_traffic_modes` | list | Modes accepted from an inbound ASPAC; defaults to the configured `traffic_mode` |
| `heartbeat_interval_ms` | integer, default `0` | `0` disables active heartbeat; otherwise send interval |
| `heartbeat_timeout_ms` | integer, default `10000` | Correlated heartbeat acknowledgement timeout |
| `heartbeat_failure_action` | `inactive` or `reconnect` | Action after a heartbeat timeout |
| `rkm_route_priority` | integer, default `10` | Priority assigned to routes installed by RKM |
| `rkm_network_indicator` | `any` or 0-3 | NI assigned to dynamically installed RKM routes |
| `network_indicator` | 0-3, default `2` | NI used when this link evaluates destination-audit state |
| `audit_service_indicator` | 0-15, default `3` | SI used when evaluating a DAUD response |
| `rkm` | map or absent | Per-peer RKM authorization policy; RKM is disabled when absent |

Per-link RKM policy:

```erlang
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
```

- `mode`: `dynamic` accepts any valid key within the allow-lists;
  `provisioned_only` requires an exact canonical match in `provisioned_keys`.
- `allowed_network_appearances`: `any` or a list of uint32 values.
- `allowed_dpcs`: `any` or `{WildcardBits, PointCode}` patterns. This is RKM
  wildcard-bit notation, not the static-route mask notation.
- `provisioned_keys`: exact allowed routing keys for `provisioned_only`.

Each entry in `provisioned_keys` uses:

- `local_rk_identifier`: uint32 request correlation value, default `0`;
- `traffic_mode_type`: `override`, `loadshare`, or `broadcast`, default
  `loadshare`;
- `network_appearance`: uint32 or `any`; `any` is rejected when the peer
  policy has a concrete `allowed_network_appearances` list;
- `destinations`: required non-empty list of destination maps.

Each destination map uses `dpc => {WildcardBits, PointCode}` and may add
`service_indicators => any | [0..15]` and
`originating_point_codes => any | [{WildcardBits, PointCode}]`. Point-code
width is 14 bits for an ITU link and 24 bits for an ANSI link. A routing-key
request must stay inside the peer allow-list; accepted keys create bounded
dynamic routes using `rkm_route_priority` and `rkm_network_indicator`.

### M2PA fields

RKM and M3UA heartbeat fields do not apply to M2PA.

| Field | Type/default | Meaning |
|---|---|---|
| `m2pa_proving_ms` | positive integer, default `500` | Local proving interval |
| `m2pa_alignment_timeout_ms` | positive integer, default `60000` | Maximum alignment/proving time |
| `m2pa_t7_ms` | positive integer, default `10000` | Excessive acknowledgement-delay timer |
| `m2pa_max_unacked` | positive integer, default `10000` | Maximum retained unacknowledged user-data messages |
| `m2pa_proving_filler_bytes` | 0-65535, default `0` | Optional proving-status filler length |

The current M2PA boundary does not implement complete Q.704
changeover/changeback/inhibit procedures. See the support matrix before using
M2PA for anything beyond the documented profile.

## `listeners`

Example:

```erlang
#{
    name => northbound_sgp,
    port => 2905,
    local_ips => [{192,0,2,20}, {192,0,2,21}],
    backlog => 256,
    profiles => [
        #{
            id => msc_a,
            remote_ips => [
                {198,51,100,10},
                {198,51,100,11}
            ],
            link_name_prefix => msc_a_assoc,
            linkset => msc_a_as,
            adaptation => m3ua,
            routing_context => [100],
            traffic_mode => loadshare
        }
    ]
}
```

Listener fields:

| Field | Type/default | Meaning |
|---|---|---|
| `name` | required term | Unique listener identifier |
| `port` | integer, default `2905` | Local SCTP listening port |
| `local_ips` | list, default `[any]` | Local listener addresses |
| `backlog` | integer, default `128` | SCTP listen backlog |
| `profiles` | required non-empty list | Ordered peer allow-list and per-association link template |

Profile identity/matching fields:

| Field | Meaning |
|---|---|
| `id` | Operator-visible profile identifier |
| `remote_ip` | Match one remote address |
| `remote_ips` | Match any address in a list |
| `remote_port` | Optional additional remote-port match |
| `accept_any` | Accept otherwise unmatched peers; dangerous outside an isolated negative-test lab |
| `link_name` | Fixed ephemeral-link name; suitable only when one association can exist |
| `link_name_prefix` | Produces `{Prefix, AssocId}` for concurrent associations |
| `linkset` | Required destination linkset for the generated link |

All other profile fields become generated link fields, including
`adaptation`, variants, routing contexts, traffic mode, heartbeat and M2PA
timers. First matching profile wins. There is no implicit accept-all profile.

## `routes`

Example:

```erlang
#{
    id => msc_a_sccp,
    dpc => 4321,
    mask => 16#3fff,
    opc_patterns => [{16#3fff, 100}],
    ni => 2,
    si => [3],
    network_appearance => 1,
    routing_context => 100,
    priority => 10,
    traffic_mode => loadshare,
    linksets => [msc_primary, msc_secondary],
    enabled => true
}
```

| Field | Type/default | Meaning |
|---|---|---|
| `id` | required term | Unique route identifier |
| `dpc` | required uint24 | Destination point-code pattern |
| `mask` | uint24, default `16#ffffff` | Significant-bit mask; `16#3fff` exact ITU, `16#ffffff` exact ANSI, `0` default |
| `opc_patterns` | `any` or list of `{Mask, PC}` | Optional origin point-code screening |
| `ni` | `any`, value, or non-empty list | Network Indicator match, values 0-3 |
| `si` | `any`, value, or non-empty list | Service Indicator match, values 0-15 |
| `network_appearance` | `any`, value, or list | M3UA Network Appearance selector |
| `routing_context` | uint32 or `undefined` | Routing Context placed on the selected outbound M3UA DATA |
| `priority` | non-negative integer, default `100` | Lower wins among equally specific masks |
| `traffic_mode` | `override`, `loadshare`, `broadcast` | Link selection within the route |
| `linksets` | required non-empty list | Ordered failover list |
| `enabled` | boolean, default `true` | Administrative route state |

More-specific masks sort before less-specific masks. Destination and subsystem
state can still exclude or penalize matching paths.

## `gtt_rules`

Advanced rules use `match` and `set`:

```erlang
#{
    id => normalize_mobile,
    priority => 10,
    enabled => true,
    action => translate,
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
    continue => true,
    screening_reason => numbering_plan_policy
}
```

Rule fields:

| Field | Default | Meaning |
|---|---|---|
| `id` | required | Unique rule identifier |
| `priority` | `100` | Lower wins after match specificity |
| `enabled` | `true` | Administrative rule state |
| `action` | inferred | `translate`, `allow`, `deny`, or `discard` |
| `match` | map | Input selectors |
| `set` | map | Output transformations; only valid with `translate` |
| `continue` | `false` | Continue evaluating the transformed address |
| `screening_reason` | `policy` | Reason returned for deny/discard |

`match` supports:

- `prefix`, `exact_digits`, `min_length`, `max_length`;
- `translation_type` 0-255;
- `numbering_plan` 0-15;
- `nature_of_address` 0-127;
- `ssn` 0-255;
- `routing_indicator` as `gt` or `ssn`;
- `point_code` 0-`16#ffffff`;
- `national_use` boolean.

Numeric/address selectors can be `any`. `set` supports:

- `digits`;
- `replace_prefix => {Old, New}`;
- `strip_digits`, `prepend_digits`, `append_digits`;
- `translation_type`, `numbering_plan`, `nature_of_address`, `gti`;
- `point_code`, `ssn`, `routing_indicator`, `national_use`;
- `remove => [point_code | ssn | global_title | national_use]`.

Legacy top-level `prefix`, TT/NP/NAI, `dpc`, `ssn`, `strip_digits` and
`rewrite_prefix` fields remain accepted, but new configurations should use
`match`/`set`.

## `sccp_reassembly_limits`

| Field | Default | Meaning |
|---|---|---|
| `max_contexts` | `10000` | Maximum concurrent segmented messages |
| `max_context_bytes` | `65536` | Maximum payload bytes in one context |
| `max_total_bytes` | `67108864` | Global retained reassembly bytes |
| `timeout_ms` | `10000` | Context expiry |

These limits matter only for links/profiles with
`sccp_reassembly => true`.

## `rkm_policy`

| Field | Default | Meaning |
|---|---|---|
| `default_mode` | `disabled` | Fallback peer RKM mode |
| `max_registrations` | `4096` | Global live-registration bound |
| `rc_start` | `10000` | First dynamically allocated Routing Context |
| `rc_end` | `4294967295` | Last allocatable Routing Context |

Per-link `rkm` policy must still explicitly enable a peer.

## Alarms and audit

- `alarm_history_limit` and `active_alarm_limit` bound alarm memory.
- `audit_history_limit` bounds audit records retained in memory.
- `audit_log_path` enables durable append+sync storage. In the Compose layout,
  use a path under `/lab/stp/db`, for example
  `/lab/stp/db/audit/audit.bin`.

When a configured audit file exists, its entire framed hash chain is verified
on startup. Corruption fails startup rather than silently starting a new
chain. Plan archive/rotation procedures around that behavior.

## `management_credentials`

Example:

```erlang
{management_credentials, [
    #{
        id => noc_viewer,
        token_sha256 => <<32-byte-SHA-256-digest>>,
        roles => [viewer]
    },
    #{
        id => lab_engineer,
        token_sha256 => <<32-byte-SHA-256-digest>>,
        roles => [engineer]
    }
]}.
```

Fields:

- `id`: audit identity term;
- `token_sha256`: exactly 32 raw digest bytes, never a hexadecimal text string;
- `roles`: non-empty list from `viewer`, `operator`, `engineer`, `admin`.

Tokens must be at least 16 bytes when presented. Empty credentials make
`telco_stp:management/2` return `management_disabled`. Direct Erlang calls
remain a trusted-local interface.

## `trace`

| Field | Default | Meaning |
|---|---|---|
| `enabled` | `false` | Capture raw received/transmitted adaptation frames |
| `max_packets` | `10000` | Ring packet bound |
| `max_bytes` | `67108864` | Ring captured-byte bound |
| `capture_payload` | `true` | Capture full payload; false captures only `header_bytes` |
| `header_bytes` | `128` | Per-frame header capture limit when payload capture is disabled |

Export paths should be under `/lab/stp/logs/trace` so they persist on the host.
Trace data can contain subscriber information.

## `ha`

| Field | Default | Meaning |
|---|---|---|
| `mode` | `standalone` | `standalone`, `primary`, or `standby` |
| `peers` | `[]` | Allowed distributed Erlang node names |
| `interval_ms` | `1000` | Primary snapshot interval; minimum 100 ms |
| `replication_timeout_ms` | `2000` | Acknowledged remote-call timeout |
| `max_staleness_ms` | `10000` | Oldest promotable replica |
| `max_clock_skew_ms` | `5000` | Allowed future timestamp skew |
| `shared_secret` | `undefined` | Primary/standby HMAC secret, at least 32 bytes |
| `fencing_token_sha256` | `undefined` | Standby promotion-token digest, exactly 32 bytes |
| `snapshot_path` | `undefined` | Standby replica path; use `/lab/stp/db/snapshots/standby.bin` |

Primary and standby modes require a shared secret. Standby requires the
fencing digest. This is manual warm standby, not active/active consensus.

## `overload_limits`

| Field | Default | Meaning |
|---|---|---|
| `high_watermark` | `10000` | Enter shedding at/above this dispatcher mailbox length |
| `low_watermark` | `5000` | Leave shedding after dropping to/below this value |

The low watermark must not exceed the high watermark. These are load-shedding
thresholds, not a hard Erlang-mailbox bound.

## `fault_profile`

| Field | Default/range | Meaning |
|---|---|---|
| `drop_percent` | `0`, range 0-100 | Randomly drop submitted traffic |
| `duplicate_percent` | `0`, range 0-100 | Randomly send a second copy |
| `delay_ms` | `0`, range 0-60000 | Delay dispatch |

Use only for controlled tests. Set all three to zero for normal operation.

## Container environment versus `sys.config`

Container environment controls packaging/runtime mechanics:

- `STP_APP_VERSION`, `STP_RELEASE_VERSION`: versioned `system/lib` and
  `system/releases` directory names;
- `STP_SYSTEM_ROOT`, `STP_SEED_SYSTEM_ROOT`: writable host target and immutable
  image target;
- `STP_SYSTEM_MODE`: non-destructive target-system seeding or strict
  host-provisioned mode;
- `STP_LIVE_EBIN`: host-mounted application ebin;
- `STP_SEED_EBIN`: image-baked first-start payload;
- `STP_CONFIG_FILE`: mounted versioned configuration file;
- `STP_VM_ARGS_FILE`: mounted versioned emulator/kernel argument file;
- `STP_EBIN_MODE`: host BEAM seeding policy;
- `STP_REQUIRE_SCTP`: Linux SCTP preflight;
- `STP_NODE_NAME`, `STP_COOKIE_FILE`: distributed Erlang;
- `STP_ERL_FLAGS`: trusted OTP emulator/kernel flags.

Protocol, routing, management and HA application settings belong in
`sys.config`.
