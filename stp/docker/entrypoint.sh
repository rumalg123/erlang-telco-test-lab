#!/bin/sh

set -eu

umask 027

if [ "$#" -gt 0 ]; then
    exec "$@"
fi

STP_ROOT="${STP_ROOT:-/lab/stp}"
SYSTEM_ROOT="${STP_SYSTEM_ROOT:-${STP_ROOT}/system}"
SEED_SYSTEM_ROOT="${STP_SEED_SYSTEM_ROOT:-/opt/telco_stp/system}"
APP_VERSION="${STP_APP_VERSION:-0.3.0}"
RELEASE_VERSION="${STP_RELEASE_VERSION:-1.0}"
LIVE_EBIN="${STP_LIVE_EBIN:-${SYSTEM_ROOT}/lib/telco_stp-${APP_VERSION}/ebin}"
SEED_EBIN="${STP_SEED_EBIN:-${SEED_SYSTEM_ROOT}/lib/telco_stp-${APP_VERSION}/ebin}"
CONFIG_FILE="${STP_CONFIG_FILE:-${SYSTEM_ROOT}/releases/${RELEASE_VERSION}/sys.config}"
VM_ARGS_FILE="${STP_VM_ARGS_FILE:-${SYSTEM_ROOT}/releases/${RELEASE_VERSION}/vm.args}"
RELEASE_COMMAND="${STP_RELEASE_COMMAND:-${SYSTEM_ROOT}/bin/telco_stp}"
PIPE_DIR="${STP_PIPE_DIR:-${STP_ROOT}/pipe}"
LOG_DIR="${STP_LOG_DIR:-${STP_ROOT}/logs}"
SYSTEM_MODE="${STP_SYSTEM_MODE:-seed}"
EBIN_MODE="${STP_EBIN_MODE:-seed}"

fail() {
    printf 'STP startup failed: %s\n' "$*" >&2
    exit 1
}

case "${APP_VERSION}" in
    ""|*[!A-Za-z0-9._-]*)
        fail "STP_APP_VERSION contains unsafe characters"
        ;;
esac

case "${RELEASE_VERSION}" in
    ""|*[!A-Za-z0-9._-]*)
        fail "STP_RELEASE_VERSION contains unsafe characters"
        ;;
esac

require_directory() {
    path="$1"
    [ -d "${path}" ] || fail "required directory does not exist: ${path}"
    [ -r "${path}" ] || fail "required directory is not readable: ${path}"
}

require_directory "${SEED_SYSTEM_ROOT}"
require_directory "${SYSTEM_ROOT}"

case "${SYSTEM_MODE}" in
    seed)
        [ -w "${SYSTEM_ROOT}" ] ||
            fail "live OTP system is not writable: ${SYSTEM_ROOT}"
        SYSTEM_WAS_INCOMPLETE=false
        if [ ! -r "${SYSTEM_ROOT}/releases/RELEASES" ] ||
           [ ! -x "${RELEASE_COMMAND}" ]; then
            SYSTEM_WAS_INCOMPLETE=true
        fi
        cp -R -n "${SEED_SYSTEM_ROOT}/." "${SYSTEM_ROOT}/" ||
            fail "could not seed the live OTP system from ${SEED_SYSTEM_ROOT}"
        if [ "${SYSTEM_WAS_INCOMPLETE}" = "true" ]; then
            printf 'Seeded complete OTP target system into %s.\n' \
                "${SYSTEM_ROOT}"
        fi
        ;;
    host)
        [ -x "${RELEASE_COMMAND}" ] ||
            fail \
                "STP_SYSTEM_MODE=host requires a complete release in ${SYSTEM_ROOT}"
        ;;
    *)
        fail "STP_SYSTEM_MODE must be seed or host"
        ;;
esac

require_directory "${SEED_EBIN}"
require_directory "${LIVE_EBIN}"
require_directory "${PIPE_DIR}"
require_directory "${LOG_DIR}"

case "${EBIN_MODE}" in
    seed)
        if [ ! -f "${LIVE_EBIN}/telco_stp.app" ]; then
            [ -w "${LIVE_EBIN}" ] ||
                fail "live ebin is empty and not writable: ${LIVE_EBIN}"
            cp -f "${SEED_EBIN}"/* "${LIVE_EBIN}/"
            printf 'Seeded host-mounted ebin from image release payload.\n'
        fi
        ;;
    refresh)
        [ -w "${LIVE_EBIN}" ] ||
            fail "live ebin is not writable: ${LIVE_EBIN}"
        cp -f "${SEED_EBIN}"/* "${LIVE_EBIN}/"
        printf 'Refreshed host-mounted ebin from image release payload.\n'
        ;;
    host)
        [ -f "${LIVE_EBIN}/telco_stp.app" ] ||
            fail "STP_EBIN_MODE=host requires telco_stp.app in ${LIVE_EBIN}"
        ;;
    *)
        fail "STP_EBIN_MODE must be seed, refresh, or host"
        ;;
esac

[ -f "${LIVE_EBIN}/telco_stp.app" ] ||
    fail "telco_stp.app is missing from ${LIVE_EBIN}"
[ -f "${CONFIG_FILE}" ] ||
    fail "sys.config does not exist: ${CONFIG_FILE}"
[ -r "${CONFIG_FILE}" ] ||
    fail "sys.config is not readable: ${CONFIG_FILE}"
[ -f "${VM_ARGS_FILE}" ] ||
    fail "vm.args does not exist: ${VM_ARGS_FILE}"
[ -r "${VM_ARGS_FILE}" ] ||
    fail "vm.args is not readable: ${VM_ARGS_FILE}"
[ -x "${RELEASE_COMMAND}" ] ||
    fail "OTP release command is not executable: ${RELEASE_COMMAND}"
[ -w "${SYSTEM_ROOT}" ] ||
    fail "OTP system must be writable for release management: ${SYSTEM_ROOT}"
[ -w "${PIPE_DIR}" ] ||
    fail "pipe directory is not writable: ${PIPE_DIR}"
[ -w "${LOG_DIR}" ] ||
    fail "log directory is not writable: ${LOG_DIR}"

case "${CONFIG_FILE}" in
    *.config) ;;
    *) fail "STP_CONFIG_FILE must end in .config" ;;
esac

"${RELEASE_COMMAND}" validate ||
    fail "complete OTP release structure validation failed"

STP_CONFIG_FILE="${CONFIG_FILE}" \
"${RELEASE_COMMAND}" eval -noshell -eval '
    Path = os:getenv("STP_CONFIG_FILE"),
    case file:consult(Path) of
        {ok, [_]} ->
            halt(0);
        {ok, Terms} ->
            io:format(
                standard_error,
                "Expected one sys.config term, got ~p~n",
                [length(Terms)]
            ),
            halt(1);
        {error, Reason} ->
            io:format(
                standard_error,
                "Invalid sys.config: ~p~n",
                [Reason]
            ),
            halt(1)
    end.
' || fail "sys.config validation failed"

case "${STP_REQUIRE_SCTP:-true}" in
    true)
        STP_CONFIG_FILE="${CONFIG_FILE}" \
        "${RELEASE_COMMAND}" eval -noshell -eval '
            case gen_sctp:open([{active, false}, {port, 0}]) of
                {ok, Socket} ->
                    ok = gen_sctp:close(Socket),
                    halt(0);
                {error, Reason} ->
                    io:format(
                        standard_error,
                        "Linux SCTP preflight failed: ~p~n",
                        [Reason]
                    ),
                    halt(1)
            end.
        ' || fail \
            "SCTP is unavailable; load/enable SCTP on the Linux host"
        ;;
    false)
        printf 'SCTP preflight disabled by STP_REQUIRE_SCTP=false.\n'
        ;;
    *)
        fail "STP_REQUIRE_SCTP must be true or false"
        ;;
esac

find "${PIPE_DIR}" -maxdepth 1 \
    \( -type p -o -type s \) \
    -name 'erlang.pipe.*' \
    -delete

NODE_FLAGS=""
if [ -n "${STP_NODE_NAME:-}" ]; then
    case "${STP_NODE_NAME}" in
        *[!A-Za-z0-9_@.-]*)
            fail "STP_NODE_NAME contains unsafe characters"
            ;;
    esac

    COOKIE=""
    if [ -n "${STP_COOKIE_FILE:-}" ]; then
        [ -r "${STP_COOKIE_FILE}" ] ||
            fail "STP_COOKIE_FILE is not readable"
        COOKIE="$(tr -d '\r\n\t ' < "${STP_COOKIE_FILE}")"
    elif [ -n "${STP_ERLANG_COOKIE:-}" ]; then
        COOKIE="${STP_ERLANG_COOKIE}"
        printf '%s\n' \
            'Warning: STP_ERLANG_COOKIE is visible in the environment;' \
            'prefer STP_COOKIE_FILE.' >&2
    else
        fail "distributed node requires STP_COOKIE_FILE or STP_ERLANG_COOKIE"
    fi

    case "${COOKIE}" in
        ""|*[!A-Za-z0-9_+=/@.-]*)
            fail "Erlang cookie is empty or contains unsafe characters"
            ;;
    esac

    NODE_FLAGS="-name ${STP_NODE_NAME} -setcookie ${COOKIE}"
fi

ERL_FLAGS="${STP_ERL_FLAGS:-}"
ERL_COMMAND="exec ${RELEASE_COMMAND} foreground \
${NODE_FLAGS} \
${ERL_FLAGS}"

printf 'Starting complete OTP release %s from %s with config %s\n' \
    "${RELEASE_VERSION}" "${LIVE_EBIN}" "${CONFIG_FILE}"
printf 'Attach with: to_erl %s/\n' "${PIPE_DIR%/}"

exec run_erl \
    "${PIPE_DIR%/}/" \
    "${LOG_DIR}" \
    "${ERL_COMMAND}"
