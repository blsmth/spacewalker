#!/usr/bin/env bash
# One-command pipeline: render the 1024x1024 master (scripts/generate-icon.swift), slice it into
# every size macOS expects, and produce App/AppIcon.icns.
#
# Run this whenever the icon design changes; App/AppIcon.icns is committed so `make-app.sh` and a
# fresh checkout don't need Xcode's Icon Composer or this script to produce a runnable bundle —
# but the generator is the source of truth, not the binary.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
BUILD="${ROOT}/build/icon"
ICONSET="${BUILD}/AppIcon.iconset"
MASTER="${BUILD}/AppIcon-1024.png"

echo "▸ Rendering 1024x1024 master…"
rm -rf "${BUILD}"
mkdir -p "${ICONSET}"
swift "${ROOT}/scripts/generate-icon.swift" "${MASTER}"

# macOS iconset naming: icon_<point-size>x<point-size>[@2x].png. Point size and pixel size match
# at @1x; @2x doubles the pixels for the same point size.
declare -a SLOTS=(
  "16 icon_16x16.png"
  "32 icon_16x16@2x.png"
  "32 icon_32x32.png"
  "64 icon_32x32@2x.png"
  "128 icon_128x128.png"
  "256 icon_128x128@2x.png"
  "256 icon_256x256.png"
  "512 icon_256x256@2x.png"
  "512 icon_512x512.png"
  "1024 icon_512x512@2x.png"
)

echo "▸ Slicing iconset…"
for slot in "${SLOTS[@]}"; do
  read -r px name <<<"${slot}"
  sips -z "${px}" "${px}" "${MASTER}" --out "${ICONSET}/${name}" >/dev/null
done

echo "▸ Building App/AppIcon.icns…"
iconutil -c icns "${ICONSET}" -o "${ROOT}/App/AppIcon.icns"

echo "✓ ${ROOT}/App/AppIcon.icns"
