#!/usr/bin/env bash
#
#  notarize.sh
#  lmd
#
#  Submit a zip of the signed release binaries to Apple's notary
#  service and wait for the verdict. Bare CLI binaries (no .app /
#  .pkg / .dmg wrapper) cannot be `stapler staple`d, so the notary
#  ticket lives on Apple's servers; first-launch Gatekeeper checks
#  hit the network. For an offline-friendly distribution, wrap into
#  a .pkg first and staple that.
#
#  Usage:
#      scripts/notarize.sh
#
#  Reads NOTARY_PROFILE from config/signing.env. Create the profile
#  once with `make notary-setup`.
#

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIGNING_ENV="${REPO_ROOT}/config/signing.env"
BUILD_DIR="${REPO_ROOT}/.build/release"
DIST_DIR="${REPO_ROOT}/Products"

if [[ ! -f "${SIGNING_ENV}" ]]; then
    echo "notarize: missing ${SIGNING_ENV}" >&2
    exit 1
fi

# shellcheck disable=SC1090
source "${SIGNING_ENV}"

: "${NOTARY_PROFILE:?NOTARY_PROFILE not set in ${SIGNING_ENV}}"

DEFAULT_BINARIES=(lmd lmd-serve lmd-tui lmd-bench lmd-qa)

mkdir -p "${DIST_DIR}"

# Stage signed copies into Products/ so the zip has predictable layout
# and we don't pollute .build/.
STAGE_DIR="$(mktemp -d -t lmd-notarize.XXXXXX)"
trap 'rm -rf "${STAGE_DIR}"' EXIT INT TERM

for binary in "${DEFAULT_BINARIES[@]}"; do
    src="${BUILD_DIR}/${binary}"
    if [[ ! -f "${src}" ]]; then
        echo "notarize: missing ${src}; run \`make sign\` first" >&2
        exit 1
    fi
    cp "${src}" "${STAGE_DIR}/${binary}"
done

# Quick signature sanity check before paying the round-trip latency.
for binary in "${DEFAULT_BINARIES[@]}"; do
    if ! codesign --verify --strict "${STAGE_DIR}/${binary}"; then
        echo "notarize: ${binary} not signed; run \`make sign\` first" >&2
        exit 1
    fi
done

stamp="$(date +%Y%m%d-%H%M%S)"
zip_path="${DIST_DIR}/lmd-${stamp}.zip"

echo "[notarize] packaging -> ${zip_path}"
(
    cd "${STAGE_DIR}"
    /usr/bin/ditto -c -k --keepParent . "${zip_path}"
)

echo "[notarize] submitting to Apple notary service (profile=${NOTARY_PROFILE})"
echo "[notarize] this typically takes 1-5 minutes"
xcrun notarytool submit "${zip_path}" \
    --keychain-profile "${NOTARY_PROFILE}" \
    --wait

echo "[notarize] success. zip: ${zip_path}"
echo "[notarize] note: bare binaries cannot be stapled; first-launch checks online."
