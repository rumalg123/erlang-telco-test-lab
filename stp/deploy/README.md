# STP host deployment tree

This directory is the host-persistent counterpart of `/lab/stp`. The entire
`deploy/system` directory is mounted at `/lab/stp/system`, so it becomes the
writable OTP target system used by the running node.

Before first start the repository contains only operator inputs and
placeholders:

```text
deploy/
  system/
    releases/1.0/
      sys.config                       active application configuration
      vm.args                          emulator/kernel arguments
    lib/telco_stp-0.3.0/ebin/
      .gitkeep
  logs/                                run_erl/application logs
  crash_dumps/                         erl_crash.dump
  db/                                  audit data and HA snapshots
  pipe/                                run_erl/to_erl FIFOs
  secrets/                             optional secret-file sources
```

With `STP_SYSTEM_MODE=seed`, the first container start non-destructively fills
`deploy/system` from the complete image target at `/opt/telco_stp/system`.
Existing `sys.config`, `vm.args`, and operator ebin files are not overwritten.
After seeding, the host tree contains:

```text
system/
  bin/telco_stp
  erts-17.0.3/bin/...
  lib/
    kernel-11.0.3/...
    stdlib-8.0.2/...
    sasl-4.4/...
    crypto-5.9.1/...
    telco_stp-0.3.0/ebin/...
  releases/
    RELEASES
    start_erl.data
    telco_stp-1.0.tar.gz
    1.0/
      telco_stp.rel
      start.boot
      start.script
      start_clean.boot
      start_clean.script
      sys.config
      vm.args
      BUILD_INFO
```

The exact bundled OTP application versions follow the pinned OTP 29 image.
`1.0` is the target-system release version; `0.3.0` is the `telco_stp`
application version.

The generated ERTS, OTP libraries, boot artifacts and package files are
ignored by Git because they are platform-specific build/deployment state.
Back up the complete deployed `system` tree as one consistent unit. Do not
restore or replace only `RELEASES`, `start_erl.data`, or `erts-*`.

Host file changes are visible inside the container immediately. A changed
BEAM is not executed until it is explicitly hot-loaded or the release is
restarted. Editing `sys.config` or `vm.args` takes effect on the next VM boot.

See the [Linux deployment guide](../docs/linux-docker-deployment.md) for
permissions, SCTP preparation, release validation, `to_erl`, hot loading and
recovery. See the [`sys.config` reference](../config/README.md) before changing
the active configuration.
