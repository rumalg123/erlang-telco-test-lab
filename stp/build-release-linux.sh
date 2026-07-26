#!/bin/sh

set -eu

SCRIPT_DIR="$(
    CDPATH= cd -- "$(dirname -- "$0")" && pwd
)"
APP_VERSION="${STP_APP_VERSION:-0.3.0}"
RELEASE_VERSION="${STP_RELEASE_VERSION:-1.0}"
OUTPUT_PARENT="${SCRIPT_DIR}/_build/release"
FINAL_TARGET="${OUTPUT_PARENT}/telco_stp-${RELEASE_VERSION}"

safe_version() {
    case "$1" in
        ""|*[!A-Za-z0-9._-]*) return 1 ;;
        *) return 0 ;;
    esac
}

safe_version "${APP_VERSION}" ||
    {
        printf '%s\n' 'STP_APP_VERSION contains unsafe characters.' >&2
        exit 2
    }
safe_version "${RELEASE_VERSION}" ||
    {
        printf '%s\n' 'STP_RELEASE_VERSION contains unsafe characters.' >&2
        exit 2
    }

command -v escript >/dev/null 2>&1 ||
    {
        printf '%s\n' 'OTP 29 escript was not found in PATH.' >&2
        exit 1
    }

"${SCRIPT_DIR}/build-linux.sh" --test

mkdir -p "${OUTPUT_PARENT}"
STAGING="$(
    mktemp -d "${OUTPUT_PARENT}/.stp-release.XXXXXX"
)"
TARGET="${STAGING}/target"
BACKUP="${STAGING}/previous"

cleanup() {
    rm -rf -- "${STAGING}"
}
trap cleanup EXIT HUP INT TERM

escript "${SCRIPT_DIR}/release/build_release.escript" \
    "${SCRIPT_DIR}/_build/default/lib/telco_stp/ebin" \
    "${SCRIPT_DIR}/deploy/system/releases/${RELEASE_VERSION}/sys.config" \
    "${SCRIPT_DIR}/deploy/system/releases/${RELEASE_VERSION}/vm.args" \
    "${SCRIPT_DIR}/release/bin/telco_stp" \
    "${TARGET}" \
    "${RELEASE_VERSION}" \
    "${APP_VERSION}"

if [ -e "${FINAL_TARGET}" ]; then
    mv -- "${FINAL_TARGET}" "${BACKUP}"
fi

if mv -- "${TARGET}" "${FINAL_TARGET}"; then
    rm -rf -- "${BACKUP}"
else
    if [ -e "${BACKUP}" ]; then
        mv -- "${BACKUP}" "${FINAL_TARGET}"
    fi
    exit 1
fi

printf 'Published complete Linux OTP release to %s\n' "${FINAL_TARGET}"
printf 'Release package: %s/releases/telco_stp-%s.tar.gz\n' \
    "${FINAL_TARGET}" "${RELEASE_VERSION}"
