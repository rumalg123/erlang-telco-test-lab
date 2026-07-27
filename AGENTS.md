# Repository Guidelines

## Project Structure & Module Organization

This is a component-based Erlang telecom lab. The implemented component is
`stp/`, with OTP source in `stp/src/`, deterministic tests in `stp/test/`,
operator configuration in `stp/config/`, deployment state in `stp/deploy/`,
and STP-specific design notes in `stp/docs/`. `msc/`, `smsc/`, and `hlr/` are
scaffolded components with the same `src/`, `test/`, `config/`, and `README.md`
layout. Put shared protocol contracts and test utilities in `common/` only
after at least two components need them. Cross-component topologies, fixtures,
scenarios, and generated artifacts belong in `lab/`.

## Build, Test, and Development Commands

- `.\build.cmd -Test`: builds all implemented components and runs tests.
- `.\build.cmd stp -Test`: builds STP and runs the current STP test suite.
- `.\build.cmd stp`: compiles STP without running tests.
- `.\start-lab.cmd`: starts the current lab topology, presently STP only.
- `./stp/build-release-linux.sh`: builds the Linux OTP release; run on Linux
  with OTP 29 and kernel SCTP support for real SCTP interop.

The Windows scripts expect Erlang/OTP 29 at `C:\Program Files\Erlang OTP` or
via `ERLANG_HOME`.

## Coding Style & Naming Conventions

Erlang modules use the `telco_stp_*` prefix for STP internals and expose public
APIs through `telco_stp.erl`. Keep functions small, add `-spec` declarations
for exported APIs, and follow the existing four-space continuation style.
Compilation uses `-Werror`, so fix warnings instead of suppressing them.
Configuration examples use descriptive names such as
`production-peer.example.config`.

## Testing Guidelines

Tests are plain Erlang modules under each component's `test/` directory; STP
tests are named `telco_stp_*_tests.erl` and are run by
`telco_stp_test_runner`. Add focused deterministic tests for routing, protocol
codec, state-machine, and failure-path changes. Run `.\build.cmd stp -Test`
before submitting STP changes; run `.\build.cmd -Test` when touching root
scripts, shared code, or cross-component layout.

## Commit & Pull Request Guidelines

The existing history uses short, direct commit subjects such as
`gitignore intellij .iml`. Prefer concise imperative subjects that identify the
changed area, for example `stp add m3ua error test`. Pull requests should
describe behavior changes, list verification commands, link related issues or
roadmap items, and include screenshots or logs only when UI, console, or
deployment behavior changes.

## Security & Configuration Tips

Do not commit generated captures, subscriber payloads, secrets, Erlang cookies,
or local deployment logs. Keep production peer examples sanitized and document
new `sys.config` fields in `stp/config/README.md`.
