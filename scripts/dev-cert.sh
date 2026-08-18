#!/usr/bin/env bash
# Create a STABLE self-signed code-signing identity for dev builds so TCC (Accessibility /
# Automation) grants survive rebuilds. Ad-hoc signing changes the code identity every build, which
# invalidates the grant and forces re-approval each time. This identity is stable, so you grant once.
#
# Lives in its own keychain, protected by a random per-install password generated below (never
# committed, never hardcoded — see PW_FILE). Idempotent: re-running is a no-op once the identity
# exists, and refuses to create a second identity with the same CN. Undo with --remove.
#
# This dev cert must NEVER sign anything distributed. Release builds use a Developer ID identity
# in the user's own login keychain instead — see make-app.sh and README.md ("Signing and
# distribution").
set -euo pipefail

IDENTITY="Spacewalker Dev"
KEYCHAIN="spacewalker-dev.keychain-db"
KEYCHAIN_PATH="${HOME}/Library/Keychains/${KEYCHAIN}"

# The keychain password lives next to the app's own state, not in the repo. It only protects a
# throwaway self-signed dev cert whose actual use is already gated by the keychain ACL below
# (-T /usr/bin/codesign, no -A) — that ACL, not this file's secrecy, is what stops other local
# processes from using the key. chmod 600 keeps it readable only by the owning user, consistent
# with the app's other per-user state in this same directory.
STATE_DIR="${HOME}/Library/Application Support/Spacewalker"
PW_FILE="${STATE_DIR}/dev-keychain.pw"

TMP=""
cleanup() {
  # Runs on every exit path (success, error, or interrupt) so a failure mid-way through certificate
  # generation never leaves an unencrypted private key sitting in $TMPDIR.
  [[ -n "${TMP}" && -d "${TMP}" ]] && rm -rf "${TMP}"
}
trap cleanup EXIT INT TERM

if [[ "${1:-}" == "--remove" ]]; then
  security delete-keychain "${KEYCHAIN_PATH}" 2>/dev/null || true
  rm -f "${PW_FILE}"
  echo "Removed dev keychain and its password file. (Re-add to search list is automatic on next create.)"
  exit 0
fi

keychain_exists=false
[[ -f "${KEYCHAIN_PATH}" ]] && keychain_exists=true
pwfile_exists=false
[[ -f "${PW_FILE}" ]] && pwfile_exists=true

if [[ "${keychain_exists}" != "${pwfile_exists}" ]]; then
  echo "✗ Inconsistent dev-signing state: keychain present=${keychain_exists}, password file present=${pwfile_exists}." >&2
  echo "  (This can happen after an interrupted run, or if you have a keychain from an older" >&2
  echo "  version of this script that used a hardcoded password.) Run:" >&2
  echo "    scripts/dev-cert.sh --remove" >&2
  echo "  then re-run this script to start clean." >&2
  exit 1
fi

if ${keychain_exists}; then
  # Detect existing identities scoped to THIS keychain. Deliberately not `-v`: `-v` lists only
  # valid, trust-chained identities, and a self-signed cert never qualifies, so `-v` would report
  # "0 identities found" even when one is present (issue #13).
  match_count="$(security find-identity -p codesigning "${KEYCHAIN_PATH}" 2>/dev/null \
    | grep -c "\"${IDENTITY}\"" || true)"

  if (( match_count > 1 )); then
    echo "✗ Found ${match_count} identities named '${IDENTITY}' in ${KEYCHAIN_PATH} — refusing to" >&2
    echo "  add another (that would make codesign's identity lookup ambiguous). Run:" >&2
    echo "    scripts/dev-cert.sh --remove" >&2
    echo "  then re-run this script to start clean." >&2
    exit 1
  elif (( match_count == 1 )); then
    echo "✓ Identity '${IDENTITY}' already present — nothing to do."
    exit 0
  fi

  # match_count == 0: the keychain and its password file both exist, but the identity was never
  # imported — most likely an earlier run was interrupted between keychain creation and import.
  # Resume with the existing password rather than generating a new one (a new password can't be
  # retroactively applied to the already-created keychain).
  echo "▸ Resuming interrupted setup (keychain exists without an identity)…"
  KC_PW="$(cat "${PW_FILE}")"
else
  echo "▸ Creating dev keychain…"
  mkdir -p "${STATE_DIR}"
  KC_PW="$(openssl rand -base64 32)"
  (umask 077 && printf '%s' "${KC_PW}" > "${PW_FILE}")
  security create-keychain -p "${KC_PW}" "${KEYCHAIN_PATH}"
fi

security unlock-keychain -p "${KC_PW}" "${KEYCHAIN_PATH}"
# Auto-lock after an hour idle, and on sleep, instead of never (the previous no-flags call).
security set-keychain-settings -l -t 3600 "${KEYCHAIN_PATH}"
chmod 600 "${KEYCHAIN_PATH}"

# Add to the user's keychain search list, preserving every existing entry — read into an array and
# expand it quoted, rather than word-splitting an unquoted command substitution. `-s` REPLACES the
# whole list, so a dropped entry (e.g. login.keychain-db, if its path had been split apart) would
# silently break every other credential lookup for this user (issue #14).
search_list=()
while IFS= read -r kc; do
  search_list+=("${kc}")
done < <(security list-keychains -d user | tr -d '"' | sed 's/^[[:space:]]*//')

already_listed=false
for kc in "${search_list[@]}"; do
  if [[ "${kc}" == "${KEYCHAIN_PATH}" ]]; then
    already_listed=true
    break
  fi
done
${already_listed} || security list-keychains -d user -s "${search_list[@]}" "${KEYCHAIN_PATH}"

echo "▸ Generating self-signed code-signing certificate…"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/spacewalker-cert.XXXXXX")"
cat > "${TMP}/cert.cnf" <<'EOF'
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
  -keyout "${TMP}/key.pem" -out "${TMP}/cert.pem" \
  -config "${TMP}/cert.cnf" -extensions v3 >/dev/null 2>&1

# PKCS#12 encryption has to be something macOS's Security framework can still read, and the flag
# that controls that differs by openssl flavor:
#
#   * Real OpenSSL 3.x defaults to AES-256-CBC, which `security import` rejects, so it needs
#     `-legacy` to fall back to the older RC2/3DES scheme.
#   * LibreSSL — which is what /usr/bin/openssl is on macOS — already defaults to that older
#     scheme and has no `-legacy` flag at all. Passing it makes LibreSSL print its usage block
#     and exit without writing the .p12.
#
# Detect rather than assume: whichever openssl is first on PATH wins, and that legitimately varies
# between machines (Homebrew's openssl@3 vs the system LibreSSL).
#
# Written as two explicit branches rather than accumulating flags in an array: macOS ships bash
# 3.2, where expanding an empty array under `set -u` aborts with "unbound variable".
if openssl version | grep -q LibreSSL; then
  openssl pkcs12 -export -inkey "${TMP}/key.pem" -in "${TMP}/cert.pem" \
    -out "${TMP}/cert.p12" -passout pass:"${KC_PW}" -name "${IDENTITY}" >/dev/null 2>&1
else
  openssl pkcs12 -export -legacy -inkey "${TMP}/key.pem" -in "${TMP}/cert.pem" \
    -out "${TMP}/cert.p12" -passout pass:"${KC_PW}" -name "${IDENTITY}" >/dev/null 2>&1
fi

# Assert rather than trust. Every openssl/security call here is silenced so passwords and noise
# stay out of the terminal, which also means a failure is invisible — this script previously
# printed "✓ Created identity" while the keychain was in fact empty, and the first sign of trouble
# was make-app.sh refusing to sign much later.
[[ -s "${TMP}/cert.p12" ]] || {
  echo "✗ Failed to build the PKCS#12 bundle with $(openssl version)." >&2
  exit 1
}

echo "▸ Importing into keychain (authorized for codesign only)…"
# No `-A`: `-A` would authorize every local application to use the private key without prompting.
# `-T /usr/bin/codesign` already grants exactly the one binary that needs it; the partition list
# below is what actually lets codesign use it non-interactively.
security import "${TMP}/cert.p12" -k "${KEYCHAIN_PATH}" -P "${KC_PW}" -T /usr/bin/codesign >/dev/null 2>&1
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "${KC_PW}" "${KEYCHAIN_PATH}" >/dev/null 2>&1

# Confirm the identity is actually usable before claiming success. This is the same check
# make-app.sh makes, so agreeing here means the two scripts cannot drift apart again.
if ! security find-identity -p codesigning "${KEYCHAIN_PATH}" 2>/dev/null | grep -q "\"${IDENTITY}\""; then
  echo "✗ Import reported no error but '${IDENTITY}' is not in ${KEYCHAIN_PATH}." >&2
  exit 1
fi

echo "✓ Created identity '${IDENTITY}'."
security find-identity -p codesigning "${KEYCHAIN_PATH}" | grep "${IDENTITY}" || true
