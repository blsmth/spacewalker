#!/usr/bin/env bash
# Assemble Spacewalker.app from the SwiftPM release build.
#
# Menu-bar apps need a real bundle (for LSUIElement) and a stable code signature (so the
# Accessibility grant sticks across rebuilds — needed once M2 adds switching). We ad-hoc sign here;
# real distribution swaps in a Developer ID identity + notarization (see PLAN.md §6).
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP="$ROOT/build/Spacewalker.app"
CONFIG="${1:-release}"

echo "▸ Building ($CONFIG)…"
swift build -c "$CONFIG" >/dev/null

BIN="$ROOT/.build/$CONFIG/SpacewalkerApp"
[ -f "$BIN" ] || { echo "✗ binary not found at $BIN"; exit 1; }

echo "▸ Assembling bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Spacewalker"
cp "$ROOT/App/Info.plist" "$APP/Contents/Info.plist"

# Unlock the dev signing keychain non-interactively (it's a separate keychain, so a reboot locks it
# and codesign would otherwise pop a password prompt). Password is the one dev-cert.sh created.
DEV_KEYCHAIN="$HOME/Library/Keychains/spacewalker-dev.keychain-db"
if [ -f "$DEV_KEYCHAIN" ]; then
  security unlock-keychain -p "spacewalker-dev" "$DEV_KEYCHAIN" 2>/dev/null || true
  security set-keychain-settings "$DEV_KEYCHAIN" 2>/dev/null || true  # no auto-lock timeout
fi

# Prefer the STABLE self-signed dev identity (scripts/dev-cert.sh) so TCC grants survive rebuilds.
# Fall back to ad-hoc if it isn't set up (grants won't persist then). No hardened runtime in dev —
# that needs Developer ID + notarization (M6). The entitlement + NSAppleEventsUsageDescription
# (Info.plist) are what let the Automation prompt appear.
# Detect the dev identity with a real test-sign (it's self-signed, so `find-identity -v` won't list
# it as "valid" even though codesign can use it).
SIGN_IDENTITY="-"
PROBE="$ROOT/build/.sign-probe"
mkdir -p "$ROOT/build"; cp /bin/echo "$PROBE"
if codesign --force --sign "Spacewalker Dev" "$PROBE" >/dev/null 2>&1; then
  SIGN_IDENTITY="Spacewalker Dev"
fi
rm -f "$PROBE"
echo "▸ Signing with identity: $SIGN_IDENTITY"
codesign --force --sign "$SIGN_IDENTITY" \
  --identifier app.spacewalker.menubar \
  --entitlements "$ROOT/App/Spacewalker.entitlements" \
  "$APP" >/dev/null

echo "✓ $APP"
