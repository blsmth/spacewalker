#!/usr/bin/env bash
# Package a built Spacewalker.app into a distributable .dmg.
#
# Uses `hdiutil` (ships with every macOS install) instead of the popular `create-dmg` Homebrew
# formula. PLAN.md §6 names create-dmg, but it buys us little here — we don't need a custom
# background image or icon layout, just an app + an /Applications shortcut — and it would be
# the first Homebrew dependency in the release pipeline. dev-cert.sh already hit real breakage
# from assuming a specific tool flavor is on PATH (openssl: LibreSSL vs Homebrew's openssl@3,
# see 61625e2); a tool that may or may not be installed, at whatever version happens to be
# on the release machine, is the same class of risk for no real benefit. hdiutil is guaranteed
# present and version-stable because it ships with the OS.
#
# Called automatically by make-app.sh after the app is built, signed, and (if requested)
# notarized/stapled. Can also be run standalone against an already-built .app:
#   ./scripts/make-dmg.sh [path-to-Spacewalker.app]
#
# Env vars (same names/semantics as make-app.sh):
#   SIGN_IDENTITY     Identity to sign the .dmg with. Defaults to whatever signed the .app
#                      (read back via `codesign -dv`), so a caller that already exported it for
#                      make-app.sh doesn't have to repeat it here.
#   NOTARIZE_PROFILE   If set, submits the .dmg ITSELF for notarization and staples the ticket
#                      to it. This is a separate submission from the one make-app.sh may have
#                      already done for the .app zip — notarizing only the .app is not enough
#                      to make the .dmg pass Gatekeeper: macOS assesses whatever file actually
#                      carries the com.apple.quarantine flag after download, which for a DMG
#                      is the DMG itself, not the app inside it. Same notarytool keychain
#                      profile used by make-app.sh.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP="${1:-${ROOT}/build/Spacewalker.app}"

[[ -d "${APP}" ]] || {
  echo "✗ App bundle not found at ${APP}. Run ./scripts/make-app.sh first." >&2
  exit 1
}

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${APP}/Contents/Info.plist")"
[[ -n "${VERSION}" ]] || {
  echo "✗ Could not read CFBundleShortVersionString from ${APP}/Contents/Info.plist." >&2
  exit 1
}

DMG="${ROOT}/build/Spacewalker-${VERSION}.dmg"
STAGING="${ROOT}/build/dmg-staging"

echo "▸ Staging dmg contents…"
rm -rf "${STAGING}"
mkdir -p "${STAGING}"
cp -R "${APP}" "${STAGING}/"
ln -s /Applications "${STAGING}/Applications"

echo "▸ Building ${DMG}…"
rm -f "${DMG}"
hdiutil create -volname "Spacewalker" -srcfolder "${STAGING}" -ov -format UDZO "${DMG}" >/dev/null
rm -rf "${STAGING}"

echo "▸ Verifying dmg integrity…"
hdiutil verify "${DMG}" >/dev/null

SIGN_IDENTITY="${SIGN_IDENTITY:-}"
if [[ -z "${SIGN_IDENTITY}" ]]; then
  # Reuse whatever identity signed the .app rather than requiring it twice. `-dv` alone omits
  # the certificate chain; `-dvvv` (verbose level 3) prints one "Authority=" line per
  # certificate, leaf first — that leaf is the identity name codesign accepts as --sign.
  #
  # Captured to a variable before parsing, rather than piped straight into awk: with
  # `set -o pipefail`, awk's `exit` on the first match closes the pipe while codesign may still
  # be writing, and codesign's resulting SIGPIPE would make the whole pipeline (and this script)
  # exit nonzero even though the identity was found.
  codesign_info="$(codesign -dvvv "${APP}" 2>&1)"
  SIGN_IDENTITY="$(printf '%s\n' "${codesign_info}" | awk -F= '/^Authority=/{print $2; exit}')"
fi

if [[ -z "${SIGN_IDENTITY}" ]]; then
  echo "⚠ Could not determine a signing identity from ${APP}; leaving ${DMG} unsigned." >&2
  echo "  An unsigned dmg will be rejected by Gatekeeper once it carries the download" >&2
  echo "  quarantine flag, even if the app inside is properly signed. Set SIGN_IDENTITY to fix." >&2
else
  if [[ "${SIGN_IDENTITY}" == "Spacewalker Dev" ]]; then
    # Same non-interactive unlock make-app.sh does. Needed here too because this script may run
    # standalone (not just chained from make-app.sh in the same process), and the dev keychain
    # auto-locks after an hour idle or on sleep (see dev-cert.sh) — without this, codesign fails
    # with the unhelpful "errSecInternalComponent" rather than a clear "keychain locked" message.
    DEV_KEYCHAIN="${HOME}/Library/Keychains/spacewalker-dev.keychain-db"
    DEV_PW_FILE="${HOME}/Library/Application Support/Spacewalker/dev-keychain.pw"
    if [[ -f "${DEV_KEYCHAIN}" && -f "${DEV_PW_FILE}" ]]; then
      security unlock-keychain -p "$(cat "${DEV_PW_FILE}")" "${DEV_KEYCHAIN}"
    fi
  fi

  echo "▸ Signing dmg with identity: ${SIGN_IDENTITY}"
  CODESIGN_ARGS=(--force --sign "${SIGN_IDENTITY}")
  if [[ "${SIGN_IDENTITY}" != "Spacewalker Dev" ]]; then
    # See make-app.sh for why the dev identity skips --timestamp (no network dependency for
    # local builds it will never pass Gatekeeper anyway).
    CODESIGN_ARGS+=(--timestamp)
  fi
  codesign "${CODESIGN_ARGS[@]}" "${DMG}"
  codesign --verify "${DMG}"
fi

echo "✓ ${DMG}"

if [[ -n "${NOTARIZE_PROFILE:-}" ]]; then
  if [[ -z "${SIGN_IDENTITY}" || "${SIGN_IDENTITY}" == "Spacewalker Dev" ]]; then
    echo "✗ NOTARIZE_PROFILE is set but ${DMG} isn't signed with a Developer ID identity." >&2
    echo "  Notarization will be rejected. Set SIGN_IDENTITY to your Developer ID Application" >&2
    echo "  identity and re-run." >&2
    exit 1
  fi
  echo "▸ Submitting dmg for notarization (uploads to Apple; can take a few minutes)…"
  xcrun notarytool submit "${DMG}" --keychain-profile "${NOTARIZE_PROFILE}" --wait
  echo "▸ Stapling notarization ticket to dmg…"
  xcrun stapler staple "${DMG}"
  echo "✓ Notarized and stapled: ${DMG}"
fi
