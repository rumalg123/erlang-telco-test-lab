# Linux Docker deployment guide

## Recommendation

Use a native Linux host with Docker Engine and kernel SCTP. This is the
recommended and supported deployment shape for real M3UA/M2PA testing.

Docker Desktop on Windows or macOS adds a virtualized network boundary and is
not recommended for SCTP multihoming, host-address binding, path-failure, or
capacity testing. The Compose deployment deliberately uses Linux host
networking so the STP can use the host's SCTP stack and assigned signaling
addresses without container NAT.

This guide contains commands for the operator to run on the Linux deployment
host. The project creation process did not execute Docker commands.

## Container filesystem

```text
/lab/stp/
  system/                              complete writable OTP target system
    bin/telco_stp                      release launcher
    erts-17.0.3/bin/                   bundled emulator and ERTS tools
    lib/
      kernel-11.0.3/
      stdlib-8.0.2/
      sasl-4.4/
      crypto-5.9.1/
      telco_stp-0.3.0/ebin/            live BEAM/app/appup files
    releases/
      RELEASES                         release_handler database
      start_erl.data                   active ERTS and release versions
      telco_stp-1.0.tar.gz             installable release package
      1.0/
        telco_stp.rel                  release definition
        start.boot / start.script      embedded-system boot artifacts
        start_clean.boot / .script     maintenance/preflight boot
        sys.config                     active application configuration
        vm.args                        active emulator/kernel arguments
        BUILD_INFO                     generated release manifest
        sys.config.example             image reference copy
  logs/                                run_erl and application logs
    trace/                             PCAPNG exports
  crash_dumps/                         erl_crash.dump and crash artifacts
  db/                                  durable audit/application state
    snapshots/                         configuration and HA snapshots
  pipe/                                run_erl/to_erl named pipes
  secrets/                             optional secret-file mount

/opt/telco_stp/system/                 immutable complete image seed
```

This is a genuine self-contained OTP target system generated with OTP 29
`systools`, not only a directory that resembles a release. It boots in
`embedded` mode from its generated `start.boot`, automatically starts SASL,
Crypto and `telco_stp`, and uses its bundled ERTS rather than a system `erl`.
`release_handler` reads the persistent `releases/RELEASES` database.

`1.0` is the release version and `0.3.0` is the `telco_stp` application
version. They are intentionally independent. Exact OTP library versions in
the tree follow the pinned OTP image and can change when that image is
deliberately upgraded.

The container image keeps an immutable target system at
`/opt/telco_stp/system`. Compose bind-mounts the entire host
`stp/deploy/system` directory at `/lab/stp/system`. With
`STP_SYSTEM_MODE=seed`, startup fills missing target-system files from the
immutable seed without replacing existing host files. This preserves the
tracked host `sys.config`, `vm.args`, and any intentional live ebin overlay.
The resulting complete system tree remains writable so OTP release metadata
and future release packages can persist.

## 1. Linux host prerequisites

Recommended baseline:

- a currently supported 64-bit Linux distribution;
- native Docker Engine and the Compose plugin;
- a kernel with SCTP enabled as a module or built in;
- `lksctp-tools` for host diagnostics;
- signaling IP addresses assigned directly to host interfaces;
- synchronized time;
- enough file descriptors, memory and CPU for the proved load profile.

Install Docker Engine using the distribution-specific
[official Docker Engine instructions](https://docs.docker.com/engine/install/)
and install the Compose plugin. Do not use an unreviewed convenience script on
an operator host.

On Debian/Ubuntu, host SCTP diagnostic tools are normally installed with:

```bash
sudo apt-get update
sudo apt-get install -y lksctp-tools
```

Equivalent package names may differ on RHEL/Fedora/SUSE.

## 2. Enable SCTP on the host

Load the kernel protocol module:

```bash
sudo modprobe sctp
```

If SCTP is modular and should load after reboot:

```bash
printf '%s\n' sctp |
  sudo tee /etc/modules-load.d/sctp.conf
```

Verify:

```bash
grep -i sctp /proc/net/protocols
test -r /proc/net/sctp/assocs
ss -S -a
```

If `modprobe` reports that the module is unavailable, install a kernel/module
package containing SCTP or use a kernel built with SCTP. Do not give the
container `--privileged` just to work around a missing host protocol module.

SCTP is IP protocol number 132. Firewall and cloud/security-group policy must
allow protocol 132 between the exact signaling peers. A TCP or UDP port rule
for 2905/3565 is not an SCTP rule. Restrict:

- M3UA SCTP port 2905;
- M2PA SCTP port 3565;
- source/destination peer addresses;
- every multihoming path that is meant to be tested.

If connection tracking is used, ensure the host has the relevant SCTP
conntrack support and validate its timeouts under the target heartbeat/RTO
profile. Do not copy generic sysctl values into production without measurement.

## 3. Assign signaling addresses

With host networking, every configured `local_ips` value must exist on a host
interface:

```bash
ip -brief address
ip route
```

Use separate interfaces/VLANs/VRFs according to the lab design. Before
starting the STP, verify routing to every remote SCTP address from the intended
source path. SCTP multihoming validation requires at least two genuinely
independent paths; two addresses on one failure domain do not prove path
resilience.

Only one process can bind a given address/port combination on the host. Stop
or reconfigure any existing M3UA/M2PA service before enabling an inbound STP
listener.

## 4. Prepare the deployment checkout

Run from the repository root:

```bash
cp stp/deploy/env.example .env
```

Set the host UID/GID used for bind-mounted files:

```bash
sed -i "s/^STP_UID=.*/STP_UID=$(id -u)/" .env
sed -i "s/^STP_GID=.*/STP_GID=$(id -g)/" .env
```

Review every `.env` value:

| Variable | Purpose |
|---|---|
| `STP_UID`, `STP_GID` | Numeric identity used by the unprivileged container process; it must be able to write the host runtime mounts |
| `STP_APP_VERSION` | Application directory version, currently `telco_stp-0.3.0` |
| `STP_RELEASE_VERSION` | OTP release version, currently `1.0` |
| `STP_MEMORY_LIMIT`, `STP_CPU_LIMIT` | Container resource ceilings; size and prove these against the intended traffic profile |
| `STP_SYSTEM_MODE` | `seed` non-destructively fills missing target-system files from the image; `host` requires a complete pre-provisioned host target |
| `STP_EBIN_MODE` | `seed` copies the baked application into an empty live ebin; `host` requires a complete host app payload; `refresh` overwrites only the app ebin at startup |
| `STP_REQUIRE_SCTP` | Requires a successful real SCTP socket preflight when `true` |
| `STP_NODE_NAME` | Optional distributed Erlang long node name for HA, such as `stp_a@192.0.2.20` |
| `STP_COOKIE_FILE` | In-container cookie path when distributed Erlang is enabled |
| `STP_ERL_FLAGS` | Trusted Erlang emulator/kernel arguments |
| `RUN_ERL_LOG_GENERATIONS` | Number of rotated `run_erl` logs retained |
| `RUN_ERL_LOG_MAXSIZE` | Maximum bytes in one `run_erl` log generation |
| `ERLANG_IMAGE` | Deliberately pinned official Erlang/OTP 29 builder image |
| `RUNTIME_IMAGE` | Minimal Linux runtime base; ERTS itself comes from the generated target system |

`STP_SYSTEM_MODE=seed` does not overwrite files already on the host.
`STP_EBIN_MODE=refresh` is different: it replaces the current
`telco_stp-0.3.0/ebin` payload and must be used only for an intentional,
reviewed application refresh.

Prepare permissions:

```bash
mkdir -p \
  stp/deploy/system/lib/telco_stp-0.3.0/ebin \
  stp/deploy/system/releases/1.0 \
  stp/deploy/db \
  stp/deploy/logs \
  stp/deploy/crash_dumps \
  stp/deploy/pipe \
  stp/deploy/secrets

chown -R "$(id -u):$(id -g)" stp/deploy
chmod 0750 \
  stp/deploy/system/lib/telco_stp-0.3.0/ebin \
  stp/deploy/system/releases/1.0 \
  stp/deploy/db \
  stp/deploy/logs \
  stp/deploy/crash_dumps \
  stp/deploy/pipe \
  stp/deploy/secrets
chmod 0640 stp/deploy/system/releases/1.0/sys.config
chmod 0640 stp/deploy/system/releases/1.0/vm.args
chmod 0755 stp/build-linux.sh
```

On SELinux hosts, give these bind mounts an approved container file label or
define a site policy. Do not disable SELinux globally.

Review `compose.yaml` before running it. It requests:

- Linux host networking;
- writable bind mounts under `stp/deploy`;
- a read-only root filesystem;
- all Linux capabilities dropped;
- no-new-privileges;
- configurable CPU/memory limits.

It does not request privileged mode, host PID namespace, devices, or Docker
socket access.

## 5. Configure the STP

Edit:

```text
stp/deploy/system/releases/1.0/sys.config
```

Its default is intentionally safe:

- no links;
- no listeners;
- no routes;
- management disabled;
- tracing disabled;
- HA standalone;
- fault injection disabled;
- durable audit path under the mounted data directory.

Use the complete [`sys.config` reference](../config/README.md) and copy only
the required peer examples from `stp/config/`. Before enabling a real peer,
confirm:

- ITU versus ANSI point-code/SCCP profile;
- M3UA versus M2PA;
- exact local/remote SCTP addresses and ports;
- routing contexts, Network Appearance and traffic mode;
- DPC/OPC/NI/SI routes;
- GTT screening and translation order;
- reassembly/RKM/resource bounds.

Do not retain a catch-all default route unless the test specifically requires
it.

## 6. Build and start

To build the same complete target system directly on a Linux host that has
OTP 29 installed:

```bash
chmod 0755 stp/build-linux.sh stp/build-release-linux.sh
./stp/build-release-linux.sh
stp/_build/release/telco_stp-1.0/bin/telco_stp validate
```

That command runs the test suite and publishes a self-contained,
platform-specific target at `stp/_build/release/telco_stp-1.0`. Do not copy a
release generated on Windows to Linux, or one generated for a different CPU
architecture; bundled ERTS executables and native libraries are target
specific.

For the recommended container deployment, run from the repository root:

```bash
docker compose build stp
docker compose up -d stp
docker compose ps
```

The image build compiles with warnings as errors and runs the deterministic
test suite. It then uses OTP `systools` to generate the `.rel`, embedded boot
scripts, release package, `RELEASES` database and platform-specific target
system with bundled ERTS. The runtime entrypoint then:

1. non-destructively seeds the complete host-mounted OTP target system;
2. applies the selected application-ebin overlay policy;
3. validates all required release artifacts;
4. parses the active mounted `sys.config`;
5. opens and closes a real SCTP socket as a host-kernel preflight;
6. removes stale named pipes;
7. starts the embedded release from `start.boot` under `run_erl`.

For an intentionally loopback-only deployment without host SCTP, set
`STP_REQUIRE_SCTP=false` in `.env`. Do not use that setting for real M3UA/M2PA.

Inspect startup:

```bash
docker compose ps
docker compose logs --tail=200 stp
ls -la \
  stp/deploy/system \
  stp/deploy/system/releases \
  stp/deploy/system/releases/1.0 \
  stp/deploy/pipe \
  stp/deploy/logs \
  stp/deploy/crash_dumps
```

Most Erlang shell output is captured by `run_erl` under
`stp/deploy/logs/erlang.log.*`, not only by the Docker logging driver.

Confirm the generated release after startup:

```bash
docker exec stp /lab/stp/system/bin/telco_stp version
docker exec stp /lab/stp/system/bin/telco_stp validate
docker exec stp cat /lab/stp/system/releases/start_erl.data
```

## 7. Attach with `to_erl`

Attach exactly as follows:

```bash
docker exec -it stp to_erl /lab/stp/pipe/
```

Useful checks:

```erlang
telco_stp:status().
telco_stp:health().
telco_stp:links().
telco_stp:listeners().
telco_stp:routes().
telco_stp:alarms().
code:which(telco_stp).
release_handler:which_releases().
init:script_id().
```

Detach from `to_erl` with `Ctrl-D`. Do not use `Ctrl-C` as a routine detach
method because the break menu can affect the VM.

## 8. Host-mounted BEAM updates

Changing a `.beam` file on the host changes the file visible inside the
container immediately. The VM does not automatically load it.

Every replacement BEAM must:

- be compiled with OTP 29;
- come from a reviewed source revision;
- pass the test suite;
- be written atomically, not edited in place;
- remain compatible with the running process state and calling interfaces.

### Build on a Linux host with OTP 29

```bash
./stp/build-linux.sh --test --live
```

The script compiles into a staging directory and atomically publishes BEAM/app
files to `stp/deploy/system/lib/telco_stp-0.3.0/ebin`.

### Refresh from a rebuilt image

If the host does not have OTP 29, a controlled image refresh can seed the
newly built payload:

1. Set `STP_EBIN_MODE=refresh` in `.env`.
2. Build and recreate the STP service.
3. Verify the copied host ebin.
4. Return `STP_EBIN_MODE=seed` so later restarts preserve host changes.

`refresh` overwrites host BEAM/app files at startup. Never leave it enabled
when the host overlay intentionally contains an operator hotfix.

### Load one updated module

Attach with `to_erl`, confirm the selected path, then load:

```erlang
code:which(telco_stp_gtt).
code:load_file(telco_stp_gtt).
code:soft_purge(telco_stp_gtt).
code:which(telco_stp_gtt).
```

Expected load result:

```erlang
{module,telco_stp_gtt}
```

`code:soft_purge/1` returns `false` when a process still executes old code.
Do not use `code:purge/1` casually; it can terminate processes still running
old code. Stateful `gen_server`/`gen_statem` changes may require
`code_change/3`, process restart, application restart, or a full VM restart.

After a hot load, run focused health/traffic checks and inspect alarms.

## 9. OTP release state and controlled upgrades

The active target includes the initial release package and persistent
`release_handler` state:

```text
/lab/stp/system/releases/RELEASES
/lab/stp/system/releases/start_erl.data
/lab/stp/system/releases/telco_stp-1.0.tar.gz
```

Inspect it from the attached Erlang shell:

```erlang
release_handler:which_releases().
init:script_id().
```

The expected initial state is release `1.0` with status `permanent`. A formal
future online upgrade is not the same thing as copying an arbitrary BEAM.
It requires all of the following to be produced and reviewed together:

- a new application version and `.app`;
- real forward and rollback instructions in `telco_stp.appup`;
- a new release version and `.rel`;
- a `relup` generated against the installed base release;
- the matching release package, boot artifacts and configuration migration;
- upgrade, rollback, failover and traffic-continuity evidence.

Use `release_handler:unpack_release/1`, `check_install_release/1`,
`install_release/1` and `make_permanent/1` only with such a complete tested
package. The current `0.3.0` appup is intentionally a no-op baseline; it does
not authorize state-changing upgrades from an invented older version.

The container does not enable `heart`. Application-only upgrades can be
designed for in-service release handling, but an ERTS/OTP core upgrade that
requires emulator restart should be performed by building and recreating the
container with a newly tested target system. Never replace the bundled
`erts-*` directory beneath a running VM.

## 10. Reload `sys.config` or all BEAM files

Editing `stp/deploy/system/releases/1.0/sys.config` alone does not update
application environment already loaded into the VM.

For a full reread from the mounted config and complete code-path reload:

```bash
docker exec -it stp to_erl /lab/stp/pipe/
```

Then:

```erlang
init:restart().
```

The console disconnects while the VM restarts. Attach again and verify:

```erlang
application:get_all_env(telco_stp).
telco_stp:status().
telco_stp:health().
```

For controlled topology changes, prefer the runtime APIs and snapshots:

```erlang
telco_stp:save_configuration(
    "/lab/stp/db/snapshots/pre-change.bin"
).
telco_stp:add_link(LinkConfig).
telco_stp:add_route(Route).
```

A runtime API change is not automatically written back to `sys.config`.
Persist the intended declarative configuration separately.

## 11. Stop and restart

Use Compose for normal lifecycle control:

```bash
docker compose stop stp
docker compose start stp
docker compose restart stp
```

Compose allows a 45-second stop grace period. Verify association shutdown and
peer recovery during the operator acceptance campaign.

`init:stop().` exits the VM. Because the service uses
`restart: unless-stopped`, an unexpected VM exit can cause Docker to start it
again. Use Compose `stop` for an intentional maintenance stop.

## 12. Persistent files and backup

Host paths:

| Host path | Content |
|---|---|
| `stp/deploy/system` | Complete writable OTP target: bundled ERTS, OTP/application libraries, release packages, boot files and release database |
| `stp/deploy/system/lib/telco_stp-0.3.0/ebin` | Operator-visible live BEAM, `.app` and `.appup` overlay |
| `stp/deploy/system/releases/1.0/sys.config` | Declarative boot configuration |
| `stp/deploy/system/releases/1.0/vm.args` | Emulator/kernel arguments read at every boot |
| `stp/deploy/system/releases/RELEASES` | Persistent OTP release-handler database |
| `stp/deploy/db` | Durable audit/application data and snapshots |
| `stp/deploy/logs` | `run_erl`, application logs and trace exports |
| `stp/deploy/crash_dumps` | Erlang crash dumps |
| `stp/deploy/pipe` | Ephemeral named pipes; do not back up |
| `stp/deploy/secrets` | Optional secret files; back up only in an approved secrets system |

Back up the complete `system` tree as one version-consistent unit together
with configuration, audit logs and snapshots. Restoring only `RELEASES`, only
`start_erl.data`, or only selected OTP libraries can create a target that
looks valid but cannot boot or roll back. PCAPs can contain subscriber data
and require an explicit retention/deletion policy.

The entrypoint deletes stale `erlang.pipe.*` FIFOs at startup. Nothing
persistent should be stored in the pipe directory.

## 13. Distributed Erlang and warm standby

Run each STP HA member on a separate Linux host. Set unique resolvable names:

```dotenv
STP_NODE_NAME=stp_a@192.0.2.20
STP_COOKIE_FILE=/lab/stp/secrets/erlang.cookie
STP_ERL_FLAGS="-kernel inet_dist_listen_min 9100 inet_dist_listen_max 9100"
```

Create a high-entropy cookie file with mode `0400`, uncomment the cookie bind
mount in `compose.yaml`, and configure matching HA `peers`/shared secrets in
each host's `sys.config`.

Static emulator flags such as `+K true` belong in the mounted
`releases/1.0/vm.args`. `STP_ERL_FLAGS` is for reviewed, trusted one-off
arguments.

Restrict Erlang distribution TCP port 4369 and the fixed distribution port
9100 to the HA peer-management network. Never expose Erlang distribution to
the signaling network or the public Internet.

The application HA shared secret and Erlang distribution cookie are different
secrets. The current HA mechanism is manual warm standby. Externally fence the
former primary before promotion.

## 14. Observability

From `to_erl`:

```erlang
telco_stp:health().
telco_stp:prometheus().
telco_stp:alarms().
telco_stp:alarm_history().
telco_stp:trace_status().
```

The application returns Prometheus text but does not expose an HTTP port.
Deploy an authenticated collector if remote scraping is required.

Enable bounded trace deliberately:

```erlang
telco_stp:set_trace(#{
    enabled => true,
    max_packets => 10000,
    max_bytes => 67108864,
    capture_payload => true,
    header_bytes => 128
}).
telco_stp:export_pcapng(
    "/lab/stp/logs/trace/operator-test.pcapng"
).
```

## 15. Troubleshooting

### `SCTP is unavailable`

- run `sudo modprobe sctp` on the host;
- verify `/proc/net/sctp`;
- confirm the kernel contains SCTP;
- inspect host security policy;
- do not try to load the host kernel module from an unprivileged container.

### `{sctp_open_failed,eprotonosupport}`

The host kernel SCTP protocol is absent/disabled. This is not fixed by
installing only `libsctp1` inside the image.

### `{sctp_open_failed,eaddrnotavail}`

A configured `local_ips` address is not assigned in the host network
namespace. Check `ip address`, VLAN/VRF placement and configuration.

### Container exits before Erlang starts

Inspect:

```bash
docker compose logs stp
```

Typical causes are:

- invalid Erlang syntax in `sys.config`;
- wrong ownership or a non-writable `stp/deploy/system` bind mount;
- `STP_SYSTEM_MODE=host` with an incomplete target system;
- empty host ebin with no write permission;
- SCTP host preflight failure;
- distributed node name without a readable cookie.

### `to_erl` cannot connect

Check:

```bash
docker compose ps
ls -la stp/deploy/pipe
ls -la stp/deploy/logs
```

The path supplied to `to_erl` must end with `/`.

### Updated BEAM is visible but old behavior remains

The VM has not loaded the file, or a process still runs old code. Check:

```erlang
code:which(Module).
code:load_file(Module).
code:soft_purge(Module).
```

Use a controlled restart for incompatible state/record/protocol changes.

## 16. Production-readiness reminder

Docker packaging does not make the STP carrier-certified. Before production
substitution, complete the functional and evidence gates in
[`support-matrix.md`](support-matrix.md) and
[`remaining-work.md`](remaining-work.md), including vendor interop,
multihoming failure, capacity, overload, soak, HA fencing and security review.

## 17. Primary references

- [Official Erlang container image](https://hub.docker.com/_/erlang)
- [Docker Engine installation](https://docs.docker.com/engine/install/)
- [Compose service fields](https://docs.docker.com/reference/compose-file/services/)
- [Docker host networking](https://docs.docker.com/engine/network/drivers/host/)
- [OTP release structure](https://www.erlang.org/doc/system/release_structure.html)
- [OTP release handling](https://www.erlang.org/doc/system/release_handling.html)
- [`systools` release generation](https://www.erlang.org/doc/apps/sasl/systools.html)
- [`release_handler`](https://www.erlang.org/doc/apps/sasl/release_handler.html)
- [Erlang `run_erl` and `to_erl`](https://www.erlang.org/doc/apps/erts/run_erl_cmd.html)
- [Linux kernel SCTP documentation](https://docs.kernel.org/networking/sctp.html)
- [Linux `sctp(7)` interface reference](https://man7.org/linux/man-pages/man7/sctp.7.html)
