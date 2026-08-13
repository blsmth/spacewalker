#!/usr/bin/env bash
# Create a STABLE self-signed code-signing identity for dev builds so TCC (Accessibility /
# Automation) grants survive rebuilds. Ad-hoc signing changes the code identity every build, which
# invalidates the grant and forces re-approval each time. This identity is stable, so you grant once.
#
# Lives in its own keychain with a known password, so signing never prompts for your login password.
# Idempotent: re-running is a no-op once the identity exists. Undo with scripts/dev-cert.sh --remove
set -euo pipefail

IDENTITY="Spacewalker Dev"
KEYCHAIN="spacewalker-dev.keychain-db"
KEYCHAIN_PATH="$HOME/Library/Keychains/$KEYCHAIN"
KC_PW="spacewalker-dev"
TMP="${TMPDIR:-/tmp}/spacewalker-cert.$$"

if [[ "${1:-}" == "--remove" ]]; then
  security delete-keychain "$KEYCHAIN_PATH" 2>/dev/null || true
  echo "Removed dev keychain. (Re-add to search list is automatic on next create.)"
  exit 0
fi

if security find-identity -p codesigning -v 2>/dev/null | grep -q "$IDENTITY"; then
  echo "✓ Identity '$IDENTITY' already present — nothing to do."
  exit 0
fi

echo "▸ Creating dev keychain…"
security create-keychain -p "$KC_PW" "$KEYCHAIN_PATH" 2>/dev/null || true
security unlock-keychain -p "$KC_PW" "$KEYCHAIN_PATH"
security set-keychain-settings "$KEYCHAIN_PATH"                 # no auto-lock timeout
# Add to the user search list (preserving existing entries).
existing=$(security list-keychains -d user | sed -e 's/[">]//g' -e 's/^[[:space:]]*//')
security list-keychains -d user -s $existing "$KEYCHAIN_PATH"

echo "▸ Generating self-signed code-signing certificate…"
mkdir -p "$TMP"
cat > "$TMP/cert.cnf" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = Spacewalker Dev
[v3]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -config "$TMP/cert.cnf" -extensions v3 >/dev/null 2>&1
# -legacy: OpenSSL 3 defaults to AES-based PKCS#12 that macOS `security import` can't read.
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/cert.p12" -passout pass:"$KC_PW" -name "$IDENTITY" >/dev/null 2>&1

echo "▸ Importing into keychain (authorized for codesign)…"
security import "$TMP/cert.p12" -k "$KEYCHAIN_PATH" -P "$KC_PW" -T /usr/bin/codesign -A >/dev/null 2>&1
# Pre-authorize codesign to use the private key without an interactive prompt.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KC_PW" "$KEYCHAIN_PATH" >/dev/null 2>&1

rm -rf "$TMP"
echo "✓ Created identity '$IDENTITY'."
security find-identity -p codesigning -v | grep "$IDENTITY" || true
