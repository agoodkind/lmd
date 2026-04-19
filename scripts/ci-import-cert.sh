#!/usr/bin/env bash
#
#  ci-import-cert.sh
#  lmd
#
#  Import a base64-encoded Developer ID Application .p12 into a fresh
#  temporary keychain so that `codesign` can find the identity. Designed
#  for GitHub Actions macOS runners where we don't have a persistent
#  login keychain with the developer certificate installed.
#
#  Required environment:
#      APPLE_DEVELOPER_ID_P12_BASE64   base64 of the single-identity .p12
#      APPLE_DEVELOPER_ID_P12_PASSWORD import password for that .p12
#      KEYCHAIN_PASSWORD               optional; auto-generated if unset
#
#  Writes the keychain path to $GITHUB_ENV as CI_KEYCHAIN_PATH so later
#  steps can `security delete-keychain` in cleanup.
#

set -euo pipefail

: "${APPLE_DEVELOPER_ID_P12_BASE64:?APPLE_DEVELOPER_ID_P12_BASE64 not set}"
: "${APPLE_DEVELOPER_ID_P12_PASSWORD:?APPLE_DEVELOPER_ID_P12_PASSWORD not set}"

KEYCHAIN_NAME="lmd-build.keychain-db"
KEYCHAIN_PATH="${RUNNER_TEMP:-/tmp}/${KEYCHAIN_NAME}"
KEYCHAIN_PASSWORD="${KEYCHAIN_PASSWORD:-$(uuidgen)}"

# Work in a scratch dir we fully control; never write to the repo.
scratch="$(mktemp -d -t lmd-cert.XXXXXX)"
trap 'rm -rf "${scratch}"' EXIT INT TERM

echo "[ci-import-cert] decoding .p12 to ${scratch}"
printf '%s' "${APPLE_DEVELOPER_ID_P12_BASE64}" | base64 --decode > "${scratch}/cert.p12"

echo "[ci-import-cert] creating temp keychain at ${KEYCHAIN_PATH}"
security create-keychain -p "${KEYCHAIN_PASSWORD}" "${KEYCHAIN_PATH}"
security set-keychain-settings -lut 7200 "${KEYCHAIN_PATH}"
security unlock-keychain -p "${KEYCHAIN_PASSWORD}" "${KEYCHAIN_PATH}"

# Put the temp keychain first in the search list so codesign finds it.
security list-keychains -d user -s "${KEYCHAIN_PATH}" $(security list-keychains -d user | xargs)

echo "[ci-import-cert] importing identity"
security import "${scratch}/cert.p12" \
    -k "${KEYCHAIN_PATH}" \
    -P "${APPLE_DEVELOPER_ID_P12_PASSWORD}" \
    -T /usr/bin/codesign \
    -T /usr/bin/security

# Allow codesign to use the key without triggering the interactive dialog.
security set-key-partition-list \
    -S apple-tool:,apple:,codesign: \
    -s \
    -k "${KEYCHAIN_PASSWORD}" \
    "${KEYCHAIN_PATH}"

echo "[ci-import-cert] identities now available to codesign:"
security find-identity -v -p codesigning "${KEYCHAIN_PATH}"

if [[ -n "${GITHUB_ENV:-}" ]]; then
    echo "CI_KEYCHAIN_PATH=${KEYCHAIN_PATH}" >> "${GITHUB_ENV}"
    echo "[ci-import-cert] wrote CI_KEYCHAIN_PATH to GITHUB_ENV"
fi

echo "[ci-import-cert] done"
