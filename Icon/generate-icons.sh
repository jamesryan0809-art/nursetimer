#!/usr/bin/env bash
# Rasterize Icon/AppIcon.svg into the AppIcon asset catalogs for all three targets,
# plus verification renders. Run from anywhere:
#   Icon/generate-icons.sh
#
# Needs a rasterizer: rsvg-convert (apt install librsvg2-bin) or resvg.
# Flattens alpha (via ImageMagick if present) so Xcode/App Store don't warn.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SVG="$HERE/AppIcon.svg"

have() { command -v "$1" >/dev/null 2>&1; }

render() {  # size out
  local size="$1" out="$2" tmp="$2.tmp.png"
  if have rsvg-convert; then
    rsvg-convert -w "$size" -h "$size" -b '#0F766E' "$SVG" -o "$tmp"
  elif have resvg; then
    resvg -w "$size" -h "$size" --background '#0F766E' "$SVG" "$tmp"
  else
    echo "Need rsvg-convert (apt install librsvg2-bin) or resvg." >&2
    exit 1
  fi
  if have magick; then magick "$tmp" -alpha off "$out"; rm -f "$tmp"
  elif have convert; then convert "$tmp" -alpha off "$out"; rm -f "$tmp"
  else mv "$tmp" "$out"; fi
}

# App-icon PNG (single 1024 universal) for each target's catalog.
for target in App Watch Widget; do
  out="$ROOT/$target/Assets.xcassets/AppIcon.appiconset"
  mkdir -p "$out"
  render 1024 "$out/AppIcon-1024.png"
done

# Verification renders (eyeball proportions at store / iPhone / watch sizes).
mkdir -p "$HERE/preview"
render 1024 "$HERE/preview/icon-1024.png"
render 180  "$HERE/preview/icon-180.png"
render 88   "$HERE/preview/icon-88.png"

echo "Icons generated into App/Watch/Widget Assets.xcassets and Icon/preview/."
