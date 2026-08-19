#!/usr/bin/env bash
# Cut a Spacewalker release: build a notarized, signed dmg and publish it as a GitHub Release
# attached to a version tag.
#
# This is a LOCAL script, not a GitHub Actions workflow — see docs/RELEASING.md for why. Run it
# on the machine that holds the Developer ID signing identity, with notarization credentials
# already stored via `xcrun notarytool store-credentials` (see docs/RELEASING.md).
#
# Usage (from the repo root, on main, with App/Info.plist already bumped to the new version):
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
#     NOTARIZE_PROFILE=spacewalker-notary \
#     ./scripts/release.sh
#
# The version tagged and released is whatever CFBundleShortVersionString currently says in
# App/Info.plist — bump that (and CFBundleVersion) and commit BEFORE running this.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${ROOT}/App/Info.plist")"
[[ -n "${VERSION}" ]] || {
  echo "✗ Could not read CFBundleShortVersionString from App/Info.plist." >&2
  exit 1
}
TAG="v${VERSION}"

# Fail loudly and early on every precondition, before doing any expensive work (build, upload,
# network calls to Apple) — a release script that gets partway through and THEN discovers a
# missing credential is worse than one that refuses to start.
[[ -n "${SIGN_IDENTITY:-}" ]] || {
  echo "✗ SIGN_IDENTITY is not set. A release build must be signed with a Developer ID" >&2
  echo "  Application identity, not the local dev cert. See docs/RELEASING.md." >&2
  exit 1
}
[[ "${SIGN_IDENTITY}" != "Spacewalker Dev" ]] || {
  echo "✗ SIGN_IDENTITY is set to the local dev identity. Set it to your Developer ID" >&2
  echo "  Application identity instead. See docs/RELEASING.md." >&2
  exit 1
}
[[ -n "${NOTARIZE_PROFILE:-}" ]] || {
  echo "✗ NOTARIZE_PROFILE is not set. A release build must be notarized. See docs/RELEASING.md" >&2
  echo "  for the one-time 'xcrun notarytool store-credentials' setup." >&2
  exit 1
}

CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[[ "${CURRENT_BRANCH}" == "main" ]] || {
  echo "✗ On branch '${CURRENT_BRANCH}', not main. Releases are cut from main." >&2
  exit 1
}

[[ -z "$(git status --porcelain)" ]] || {
  echo "✗ Working tree is not clean. Commit or stash changes before releasing — the tag must" >&2
  echo "  point at exactly what gets built and released." >&2
  exit 1
}

if git rev-parse "${TAG}" >/dev/null 2>&1; then
  echo "✗ Tag ${TAG} already exists. Bump CFBundleShortVersionString in App/Info.plist first." >&2
  exit 1
fi

echo "▸ Building, signing, notarizing, and stapling ${TAG}…"
SIGN_IDENTITY="${SIGN_IDENTITY}" NOTARIZE_PROFILE="${NOTARIZE_PROFILE}" "${ROOT}/scripts/make-app.sh" release

DMG="${ROOT}/build/Spacewalker-${VERSION}.dmg"
[[ -f "${DMG}" ]] || {
  echo "✗ Expected dmg not found at ${DMG} after make-app.sh ran. Something upstream failed" >&2
  echo "  silently — check the make-app.sh output above." >&2
  exit 1
}

echo "▸ Tagging ${TAG}…"
git tag -a "${TAG}" -m "Spacewalker ${VERSION}"
git push origin "${TAG}"

echo "▸ Creating draft GitHub Release ${TAG}…"
# --draft: never auto-publish. Publishing (making the release and its dmg visible to the world)
# is a deliberate separate step Brendan takes after reviewing the generated notes and confirming
# the dmg actually installs and runs on a clean machine.
gh release create "${TAG}" "${DMG}" \
  --draft \
  --title "Spacewalker ${VERSION}" \
  --generate-notes

echo "✓ Draft release ${TAG} created with ${DMG} attached."
echo "  Review and publish when ready:"
echo "    gh release view ${TAG} --web"
