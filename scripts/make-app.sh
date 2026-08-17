#!/usr/bin/env bash
# Assemble Spacewalker.app from the SwiftPM release build.
#
# Menu-bar apps need a real bundle (for LSUIElement) and a stable code signature (so the
# Accessibility grant sticks across rebuilds — needed once M2 adds switching). By default we sign
# with the stable self-signed dev identity from scripts/dev-cert.sh. This is a LOCAL DEV build:
# hardened runtime is on, but the identity is self-signed and untrusted by Gatekeeper.
#
# For a release build, override the identity and (optionally) notarize:
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./scripts/make-app.sh release
#   SIGN_IDENTITY="Developer ID Application: ..." NOTARIZE_PROFILE=spacewalker-notary \
#     ./scripts/make-app.sh release
# See README.md ("Signing and distribution") for the one-time `notarytool store-credentials` setup.
# Neither a Developer ID cert nor a Team ID is required for local dev builds — SIGN_IDENTITY and
# NOTARIZE_PROFILE are both opt-in.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP="${ROOT}/build/Spacewalker.app"
CONFIG="${1:-release}"

echo "▸ Building (${CONFIG})…"
swift build -c "${CONFIG}" >/dev/null

BIN="${ROOT}/.build/${CONFIG}/SpacewalkerApp"
[[ -f "${BIN}" ]] || { echo "✗ binary not found at ${BIN}" >&2; exit 1; }

echo "▸ Assembling bundle…"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "${BIN}" "${APP}/Contents/MacOS/Spacewalker"
cp "${ROOT}/App/Info.plist" "${APP}/Contents/Info.plist"

SIGN_IDENTITY="${SIGN_IDENTITY:-}"

if [[ -z "${SIGN_IDENTITY}" ]]; then
  # Prefer the STABLE self-signed dev identity (scripts/dev-cert.sh) so TCC grants survive
  # rebuilds. Unlike the old behavior, we no longer fall back to ad-hoc signing on any failure
  # here — an ad-hoc signature has a designated requirement any other code can trivially satisfy,
  # which would silently discard the security properties the rest of this script sets up.
  DEV_KEYCHAIN="${HOME}/Library/Keychains/spacewalker-dev.keychain-db"
  DEV_PW_FILE="${HOME}/Library/Application Support/Spacewalker/dev-keychain.pw"

  if [[ ! -f "${DEV_KEYCHAIN}" || ! -f "${DEV_PW_FILE}" ]]; then
    echo "✗ No signing identity available. Run ./scripts/dev-cert.sh once to create the dev" >&2
    echo "  identity, or set SIGN_IDENTITY to a Developer ID identity for a release build." >&2
    exit 1
  fi

  # Unlock the dev signing keychain non-interactively (it's a separate keychain, so a reboot locks
  # it and codesign would otherwise pop a password prompt). The password is the one dev-cert.sh
  # generated and stored — see that script for why this file's location is acceptable.
  security unlock-keychain -p "$(cat "${DEV_PW_FILE}")" "${DEV_KEYCHAIN}"

  # Detect the dev identity by scoped lookup rather than `-v`: `-v` only lists trust-chained
  # identities, and this self-signed cert never qualifies as one (issue #13).
  match_count="$(security find-identity -p codesigning "${DEV_KEYCHAIN}" 2>/dev/null \
    | grep -c '"Spacewalker Dev"' || true)"

  case "${match_count}" in
    0)
      echo "✗ No 'Spacewalker Dev' identity found in ${DEV_KEYCHAIN}. Run ./scripts/dev-cert.sh." >&2
      exit 1
      ;;
    1)
      SIGN_IDENTITY="Spacewalker Dev"
      ;;
    *)
      echo "✗ Found ${match_count} identities named 'Spacewalker Dev' — ambiguous. Run:" >&2
      echo "    scripts/dev-cert.sh --remove && scripts/dev-cert.sh" >&2
      exit 1
      ;;
  esac
fi

echo "▸ Signing with identity: ${SIGN_IDENTITY}"
CODESIGN_ARGS=(
  --force
  --sign "${SIGN_IDENTITY}"
  --identifier app.spacewalker.menubar
  --entitlements "${ROOT}/App/Spacewalker.entitlements"
  --options runtime
)
if [[ "${SIGN_IDENTITY}" != "Spacewalker Dev" ]]; then
  # --timestamp calls out to Apple's timestamp authority over the network. That's required for a
  # release signature (notarization expects it) but would make every local dev build depend on
  # network access for no benefit, since the dev identity isn't trusted by Gatekeeper anyway.
  CODESIGN_ARGS+=(--timestamp)
fi
codesign "${CODESIGN_ARGS[@]}" "${APP}"
codesign --verify --deep --strict "${APP}"

echo "✓ ${APP}"

if [[ -n "${NOTARIZE_PROFILE:-}" ]]; then
  if [[ "${SIGN_IDENTITY}" == "Spacewalker Dev" ]]; then
    echo "✗ NOTARIZE_PROFILE is set but SIGN_IDENTITY is the dev cert. Notarization requires a" >&2
    echo "  Developer ID Application identity — set SIGN_IDENTITY accordingly." >&2
    exit 1
  fi
  echo "▸ Submitting for notarization (uploads to Apple; can take a few minutes)…"
  ZIP="${ROOT}/build/Spacewalker-notarize.zip"
  rm -f "${ZIP}"
  ditto -c -k --keepParent "${APP}" "${ZIP}"
  xcrun notarytool submit "${ZIP}" --keychain-profile "${NOTARIZE_PROFILE}" --wait
  rm -f "${ZIP}"
  echo "▸ Stapling notarization ticket…"
  xcrun stapler staple "${APP}"
  echo "✓ Notarized and stapled: ${APP}"
fi
