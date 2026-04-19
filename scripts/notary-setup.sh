#!/usr/bin/env bash
#
#  notary-setup.sh
#  lmd
#
#  One-time interactive setup of the notary keychain profile so
#  scripts/notarize.sh can submit without prompts. Wraps
#  `xcrun notarytool store-credentials`.
#
#  Prerequisites (you generate these yourself, outside this repo):
#    1. Apple ID with a Developer Program membership.
#    2. App-specific password generated at https://appleid.apple.com
#       under Sign-In and Security -> App-Specific Passwords. This is
#       NOT your real Apple ID password.
#    3. Team ID from https://developer.apple.com/account.
#
#  The password is read interactively by `notarytool` and persisted
#  in the login keychain under NOTARY_PROFILE. It never appears in
#  this script, in shell history, or in this repo.
#

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIGNING_ENV="${REPO_ROOT}/config/signing.env"

if [[ ! -f "${SIGNING_ENV}" ]]; then
    echo "notary-setup: missing ${SIGNING_ENV}" >&2
    echo "    cp config/signing.env.example config/signing.env and fill in your values first" >&2
    exit 1
fi

# shellcheck disable=SC1090
source "${SIGNING_ENV}"

: "${NOTARY_PROFILE:?NOTARY_PROFILE not set in ${SIGNING_ENV}}"
: "${DEVELOPMENT_TEAM:?DEVELOPMENT_TEAM not set in ${SIGNING_ENV}}"

apple_id="${APPLE_ID:-}"
if [[ -z "${apple_id}" ]]; then
    read -r -p "Apple ID email: " apple_id
fi

if [[ -z "${apple_id}" ]]; then
    echo "notary-setup: Apple ID is required" >&2
    exit 1
fi

echo
echo "[notary-setup] storing credentials in keychain profile: ${NOTARY_PROFILE}"
echo "[notary-setup] team:     ${DEVELOPMENT_TEAM}"
echo "[notary-setup] apple id: ${apple_id}"
echo "[notary-setup] notarytool will prompt for the app-specific password next."
echo

xcrun notarytool store-credentials "${NOTARY_PROFILE}" \
    --apple-id "${apple_id}" \
    --team-id "${DEVELOPMENT_TEAM}"

echo
echo "[notary-setup] done. Verify with:"
echo "    xcrun notarytool history --keychain-profile ${NOTARY_PROFILE}"
