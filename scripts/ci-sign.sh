#!/usr/bin/env bash
#
#  ci-sign.sh
#  lmd
#
#  Sign every release binary with the Developer ID Application identity
#  that was imported into the temporary keychain by ci-import-cert.sh.
#  Mirrors scripts/sign-binaries.sh but reads identity/team from GH
#  Actions secrets rather than config/signing.env.
#
#  Required environment:
#      APPLE_CODE_SIGN_IDENTITY  SHA1 of the identity to use
#      APPLE_TEAM_ID             10-char team identifier
#      CI_KEYCHAIN_PATH          path to the temp keychain (set by ci-import-cert.sh)
#

set -euo pipefail

: "${APPLE_CODE_SIGN_IDENTITY:?APPLE_CODE_SIGN_IDENTITY not set}"
: "${APPLE_TEAM_ID:?APPLE_TEAM_ID not set}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${REPO_ROOT}/.build/release"
BUNDLE_ID_PREFIX="io.goodkind.lmd"
BINARIES=(lmd lmd-serve lmd-tui lmd-bench lmd-qa)

echo "[ci-sign] identity: ${APPLE_CODE_SIGN_IDENTITY}"
echo "[ci-sign] team:     ${APPLE_TEAM_ID}"

for binary in "${BINARIES[@]}"; do
    path="${BUILD_DIR}/${binary}"
    if [[ ! -f "${path}" ]]; then
        echo "[ci-sign] not found: ${path}" >&2
        exit 1
    fi

    identifier="${BUNDLE_ID_PREFIX}.${binary}"
    echo "  signing ${path} as ${identifier}"

    codesign \
        --sign "${APPLE_CODE_SIGN_IDENTITY}" \
        --identifier "${identifier}" \
        --options runtime \
        --timestamp \
        --force \
        "${path}"

    codesign --verify --strict --verbose=2 "${path}" | sed 's/^/    /'
done

echo "[ci-sign] done. ${#BINARIES[@]} binary(ies) signed."
