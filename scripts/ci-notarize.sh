#!/usr/bin/env bash
#
#  ci-notarize.sh
#  lmd
#
#  Notarize the signed release binaries in CI using App Store Connect
#  API key credentials (instead of the keychain profile used by the
#  local `make notarize` path). Zips the signed binaries, submits, and
#  waits for the verdict.
#
#  Required environment:
#      APPLE_API_KEY_P8_BASE64  base64 of the AuthKey_*.p8 file
#      APPLE_API_KEY_ID         10-char key identifier
#      APPLE_API_ISSUER_ID      UUID of the issuer (team)
#
#  Writes the final zip path to $GITHUB_OUTPUT as `artifact`.
#

set -euo pipefail

: "${APPLE_API_KEY_P8_BASE64:?APPLE_API_KEY_P8_BASE64 not set}"
: "${APPLE_API_KEY_ID:?APPLE_API_KEY_ID not set}"
: "${APPLE_API_ISSUER_ID:?APPLE_API_ISSUER_ID not set}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${REPO_ROOT}/.build/release"
DIST_DIR="${REPO_ROOT}/Products"
BINARIES=(lmd lmd-serve lmd-tui lmd-bench lmd-qa)

mkdir -p "${DIST_DIR}"

scratch="$(mktemp -d -t lmd-notarize.XXXXXX)"
trap 'rm -rf "${scratch}"' EXIT INT TERM

echo "[ci-notarize] decoding API key"
key_path="${scratch}/AuthKey_${APPLE_API_KEY_ID}.p8"
printf '%s' "${APPLE_API_KEY_P8_BASE64}" | base64 --decode > "${key_path}"

echo "[ci-notarize] staging signed binaries"
for binary in "${BINARIES[@]}"; do
    src="${BUILD_DIR}/${binary}"
    if [[ ! -f "${src}" ]]; then
        echo "[ci-notarize] missing ${src}; run sign first" >&2
        exit 1
    fi
    if ! codesign --verify --strict "${src}"; then
        echo "[ci-notarize] ${binary} is not signed" >&2
        exit 1
    fi
    cp "${src}" "${scratch}/${binary}"
done

stamp="$(date +%Y%m%d-%H%M%S)"
zip_path="${DIST_DIR}/lmd-${stamp}.zip"

echo "[ci-notarize] packaging -> ${zip_path}"
(
    cd "${scratch}"
    /usr/bin/ditto -c -k --keepParent . "${zip_path}"
)

echo "[ci-notarize] submitting to Apple notary service"
xcrun notarytool submit "${zip_path}" \
    --key "${key_path}" \
    --key-id "${APPLE_API_KEY_ID}" \
    --issuer "${APPLE_API_ISSUER_ID}" \
    --wait

echo "[ci-notarize] accepted. zip: ${zip_path}"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "artifact=${zip_path}" >> "${GITHUB_OUTPUT}"
    echo "[ci-notarize] wrote artifact path to GITHUB_OUTPUT"
fi
