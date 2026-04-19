#!/usr/bin/env bash
#
#  sign-binaries.sh
#  lmd
#
#  Codesign every release binary with the Developer ID Application
#  identity, hardened runtime, and a secure timestamp. Required before
#  notarization.
#
#  Usage:
#      scripts/sign-binaries.sh [binary...]
#
#  With no args, signs every binary listed in BINARIES (matches the
#  Makefile). With args, signs just those (paths or names under
#  .build/release/).
#
#  Reads identity + team from config/signing.env. Refuses to run if
#  that file is missing.
#

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIGNING_ENV="${REPO_ROOT}/config/signing.env"
BUILD_DIR="${REPO_ROOT}/.build/release"

if [[ ! -f "${SIGNING_ENV}" ]]; then
    echo "sign-binaries: missing ${SIGNING_ENV}" >&2
    echo "    cp config/signing.env.example config/signing.env and fill in your values" >&2
    exit 1
fi

# shellcheck disable=SC1090
source "${SIGNING_ENV}"

: "${CODE_SIGN_IDENTITY:?CODE_SIGN_IDENTITY not set in ${SIGNING_ENV}}"
: "${DEVELOPMENT_TEAM:?DEVELOPMENT_TEAM not set in ${SIGNING_ENV}}"
: "${BUNDLE_ID_PREFIX:?BUNDLE_ID_PREFIX not set in ${SIGNING_ENV}}"

# Default binary set: keep in sync with Makefile BINARIES.
DEFAULT_BINARIES=(lmd lmd-serve lmd-tui lmd-bench lmd-qa)

if [[ $# -gt 0 ]]; then
    targets=("$@")
else
    targets=("${DEFAULT_BINARIES[@]}")
fi

sign_one() {
    local binary_name="$1"
    local binary_path

    if [[ -f "${binary_name}" ]]; then
        binary_path="${binary_name}"
        binary_name="$(basename "${binary_name}")"
    else
        binary_path="${BUILD_DIR}/${binary_name}"
    fi

    if [[ ! -f "${binary_path}" ]]; then
        echo "sign-binaries: not found: ${binary_path}" >&2
        return 1
    fi

    local identifier="${BUNDLE_ID_PREFIX}.${binary_name}"
    echo "  signing ${binary_path} as ${identifier}"

    codesign \
        --sign "${CODE_SIGN_IDENTITY}" \
        --identifier "${identifier}" \
        --options runtime \
        --timestamp \
        --force \
        "${binary_path}"

    codesign --verify --strict --verbose=2 "${binary_path}" 2>&1 \
        | sed 's/^/    /'
}

echo "[sign] identity: ${CODE_SIGN_IDENTITY}"
echo "[sign] team:     ${DEVELOPMENT_TEAM}"
for target in "${targets[@]}"; do
    sign_one "${target}"
done
echo "[sign] done. ${#targets[@]} binary(ies) signed."
