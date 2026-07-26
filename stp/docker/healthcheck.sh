#!/bin/sh

set -eu

PIPE_DIR="${STP_PIPE_DIR:-/lab/stp/pipe}"
LIVE_EBIN="${STP_LIVE_EBIN:-/lab/stp/system/lib/telco_stp-0.3.0/ebin}"
RELEASE_COMMAND="${STP_RELEASE_COMMAND:-/lab/stp/system/bin/telco_stp}"

[ -r "${LIVE_EBIN}/telco_stp.app" ]
"${RELEASE_COMMAND}" validate >/dev/null 2>&1
pgrep -x beam.smp >/dev/null 2>&1

pipe="$(
    find "${PIPE_DIR}" -maxdepth 1 \
        -type p \
        -name 'erlang.pipe.*' \
        -print \
        -quit
)"

[ -n "${pipe}" ]
