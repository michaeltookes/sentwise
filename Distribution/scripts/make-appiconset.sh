#!/usr/bin/env bash
# Regenerate the app's AppIcon.appiconset PNGs from the SVG masters.
#
# Home: Distribution/scripts/ — paths resolve relative to Distribution/.
# Single-sources the app icon from assets/Sentwise.svg (+ the hand-tuned
# assets/Sentwise-small.svg for the 16/32px slots), so a palette/brand change is
# made once in the SVGs and re-rendered here rather than hand-exported. This is
# the same master-split convention make-icns.sh uses for the ancillary .icns.
#
# Requires librsvg (brew install librsvg -> rsvg-convert) for a crisp re-render
# from the SVG; falls back to sips downscaling the checked-in 1024 PNG if it is
# unavailable (the 16/32px slots then lose the hand-tuned small master, so
# prefer rsvg-convert when regenerating the shipped set).
set -euo pipefail
cd "$(dirname "$0")/.."

LARGE_SVG="assets/Sentwise.svg"
SMALL_SVG="assets/Sentwise-small.svg"
FALLBACK_SRC="assets/png/icon_1024.png"
OUT="../Sentwise/Sentwise/Resources/Assets.xcassets/AppIcon.appiconset"

# Physical outputs <=32px use the hand-tuned small master; larger outputs use
# the full icon (mirrors make-icns.sh).
render() { # $1 = px, $2 = dest
  local svg="$LARGE_SVG"
  if [[ "$1" -le 32 ]]; then
    svg="$SMALL_SVG"
  fi

  if command -v rsvg-convert >/dev/null 2>&1; then
    rsvg-convert -w "$1" -h "$1" "$svg" -o "$2"
  else
    sips -z "$1" "$1" "$FALLBACK_SRC" --out "$2" >/dev/null
  fi
}

# slot filename            px
render 16   "$OUT/icon_16x16.png"
render 32   "$OUT/icon_16x16@2x.png"
render 32   "$OUT/icon_32x32.png"
render 64   "$OUT/icon_32x32@2x.png"
render 128  "$OUT/icon_128x128.png"
render 256  "$OUT/icon_128x128@2x.png"
render 256  "$OUT/icon_256x256.png"
render 512  "$OUT/icon_256x256@2x.png"
render 512  "$OUT/icon_512x512.png"
render 1024 "$OUT/icon_512x512@2x.png"

# Refresh the 1024 master PNG used by ancillary tooling (make-icns.sh fallback,
# DMG volume icon) from the same SVG so everything stays single-sourced.
if command -v rsvg-convert >/dev/null 2>&1; then
  rsvg-convert -w 1024 -h 1024 "$LARGE_SVG" -o "assets/png/icon_1024.png"
fi

echo "-> regenerated AppIcon.appiconset (+ assets/png/icon_1024.png)"
