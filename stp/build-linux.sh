#!/bin/sh

set -eu

SCRIPT_DIR="$(
    CDPATH= cd -- "$(dirname -- "$0")" && pwd
)"
REPOSITORY_ROOT="$(
    CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd
)"

RUN_TESTS=false
LIVE=false
APP_VERSION="${STP_APP_VERSION:-0.3.0}"

case "${APP_VERSION}" in
    ""|*[!A-Za-z0-9._-]*)
        printf '%s\n' \
            'STP_APP_VERSION is empty or contains unsafe characters.' >&2
        exit 2
        ;;
esac

usage() {
    cat <<'EOF'
Usage: ./stp/build-linux.sh [--test] [--live]

  --test  Compile and run the deterministic EUnit suite before publishing.
  --live  Atomically publish BEAM/app files to the versioned deployment
          ebin so the Compose bind mount exposes them to the container.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --test)
            RUN_TESTS=true
            ;;
        --live)
            LIVE=true
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            usage >&2
            exit 2
            ;;
    esac
    shift
done

command -v erl >/dev/null 2>&1 ||
    {
        printf '%s\n' 'Erlang/OTP 29 erl was not found in PATH.' >&2
        exit 1
    }
command -v erlc >/dev/null 2>&1 ||
    {
        printf '%s\n' 'Erlang/OTP 29 erlc was not found in PATH.' >&2
        exit 1
    }

OTP_RELEASE="$(
    erl -noshell -eval \
        'io:put_chars(erlang:system_info(otp_release)), halt().'
)"
[ "${OTP_RELEASE}" = "29" ] ||
    {
        printf 'OTP 29 is required; found OTP %s.\n' \
            "${OTP_RELEASE}" >&2
        exit 1
    }

grep -Fq "{vsn, \"${APP_VERSION}\"}" \
    "${SCRIPT_DIR}/src/telco_stp.app.src" ||
    {
        printf 'STP_APP_VERSION %s does not match telco_stp.app.src.\n' \
            "${APP_VERSION}" >&2
        exit 1
    }

if [ "${LIVE}" = "true" ]; then
    OUTPUT="${SCRIPT_DIR}/deploy/system/lib/telco_stp-${APP_VERSION}/ebin"
else
    OUTPUT="${SCRIPT_DIR}/_build/default/lib/telco_stp/ebin"
fi

mkdir -p "${OUTPUT}"
mkdir -p "${SCRIPT_DIR}/_build"
STAGING="$(
    mktemp -d "${OUTPUT}/.stp-build.XXXXXX"
)"
TEST_OUTPUT="$(
    mktemp -d "${SCRIPT_DIR}/_build/.stp-test.XXXXXX"
)"

cleanup() {
    rm -rf -- "${STAGING}" "${TEST_OUTPUT}"
}
trap cleanup EXIT HUP INT TERM

erlc +debug_info -Werror \
    -I "${SCRIPT_DIR}/include" \
    -o "${STAGING}" \
    "${SCRIPT_DIR}/src/telco_stp_transport.erl"

for source in "${SCRIPT_DIR}"/src/*.erl; do
    if [ "${source}" != \
         "${SCRIPT_DIR}/src/telco_stp_transport.erl" ]; then
        erlc +debug_info -Werror \
            -I "${SCRIPT_DIR}/include" \
            -pa "${STAGING}" \
            -o "${STAGING}" \
            "${source}"
    fi
done

cp "${SCRIPT_DIR}/src/telco_stp.app.src" \
    "${STAGING}/telco_stp.app"
cp "${SCRIPT_DIR}/src/telco_stp.appup.src" \
    "${STAGING}/telco_stp.appup"

if [ "${RUN_TESTS}" = "true" ]; then
    for test_source in "${SCRIPT_DIR}"/test/*.erl; do
        erlc +debug_info -Werror \
            -I "${SCRIPT_DIR}/include" \
            -pa "${STAGING}" \
            -o "${TEST_OUTPUT}" \
            "${test_source}"
    done

    (
        cd "${REPOSITORY_ROOT}"
        erl \
            -pa "${TEST_OUTPUT}" \
            -pa "${STAGING}" \
            -noshell \
            -s telco_stp_test_runner run
    )
fi

for artifact in \
    "${STAGING}"/*.beam \
    "${STAGING}/telco_stp.app" \
    "${STAGING}/telco_stp.appup"; do
    name="$(basename -- "${artifact}")"
    mv -f -- "${artifact}" "${OUTPUT}/${name}"
done

printf 'Published OTP %s STP artifacts to %s\n' \
    "${OTP_RELEASE}" "${OUTPUT}"

if [ "${LIVE}" = "true" ]; then
    printf '%s\n' \
        'The container sees the files immediately; load or restart explicitly.'
fi
