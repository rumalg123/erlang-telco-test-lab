# Erlang Telecom Core Test Lab

This repository is organized as a component-based telecom lab. Every network
element owns its source, configuration, tests, and documentation so it can be
built, run, removed, or replaced by a production peer independently.

| Directory | Component | Status |
| --- | --- | --- |
| `stp/` | SS7/SIGTRAN STP | Advanced test implementation; 77 OTP 29 tests |
| `msc/` | MSC/VLR | Scaffolded; next implementation |
| `smsc/` | SMSC | Scaffolded |
| `hlr/` | HLR/AuC and future HSS bridge | Scaffolded |
| `common/` | Shared protocol/test libraries | Scaffolded |
| `lab/` | Cross-component topology and scenarios | Scaffolded |
| `docs/` | Whole-lab architecture and roadmap | Active |

## Current commands

Build and test every implemented component:

```powershell
.\build.cmd -Test
```

Build only STP:

```powershell
.\build.cmd stp -Test
```

Start the currently implemented lab topology:

```powershell
.\start-lab.cmd
```

That topology currently contains only the STP component. As MSC, SMSC, and HLR
are implemented, the root launcher will start them from `lab/topologies/`
rather than merging their code into STP.

## Component boundary

Each component will follow the same layout:

```text
component/
  src/       OTP application code
  test/      unit, protocol, and integration tests
  config/    standalone and production-peer configurations
  docs/      component-specific design and operations
  README.md  supported scope and component commands
```

Cross-component signaling contracts belong in `common/` only after at least
two components genuinely share them. End-to-end fixtures and scenarios belong
in `lab/`, not inside an individual network element.

See [STP documentation](stp/README.md) for the implemented signaling backbone
and [the full lab roadmap](docs/roadmap.md) for remaining acceptance gates.

For container deployment, use the
[Linux Docker deployment guide](stp/docs/linux-docker-deployment.md). Native
Linux with kernel SCTP is recommended for real M3UA/M2PA and multihoming.
