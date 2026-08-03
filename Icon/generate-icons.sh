#!/usr/bin/env bash
# Rasterize Icon/AppIcon.svg into the AppIcon asset catalogs for all three targets
# (a single 1024x1024 universal icon per platform — Xcode/actool derives every required
# iOS + watchOS size from it), plus verification renders. Run from anywhere:
#   Icon/generate-icons.sh
#
# Needs a rasterizer: rsvg-convert (apt install librsvg2-bin) or resvg, AND a flattener
# (ImageMagick: apt install imagemagick). App Store REJECTS app icons that carry an alpha
# channel, so the shipped catalog icons are flattened to fully opaque and then VERIFIED —
# the script fails loud rather than emitting a transparent icon that fails App Store review.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SVG="$HERE/AppIcon.svg"
BG='#0F766E'

have() { command -v "$1" >/dev/null 2>&1; }

rasterize() {  # size out.png — renders the SVG at `size` onto BG (may carry an alpha channel)
  local size="$1" out="$2"
  if have rsvg-convert; then
    rsvg-convert -w "$size" -h "$size" -b "$BG" "$SVG" -o "$out"
  elif have resvg; then
    resvg -w "$size" -h "$size" --background "$BG" "$SVG" "$out"
  else
    echo "Need rsvg-convert (apt install librsvg2-bin) or resvg." >&2; exit 1
  fi
}

flatten_alpha() {  # in-place: strip the alpha channel so the icon is fully opaque
  local f="$1"
  if have magick; then magick "$f" -background "$BG" -alpha remove -alpha off "$f"
  elif have convert; then convert "$f" -background "$BG" -alpha remove -alpha off "$f"
  fi
}

# App Store requires opaque icons — refuse to generate shipped catalog icons without a flattener
# rather than silently emit an alpha PNG that fails validation.
if ! (have magick || have convert); then
  echo "ImageMagick (magick/convert) is required to flatten the app-icon alpha channel —" >&2
  echo "App Store rejects icons with alpha. Install it (apt install imagemagick) and retry." >&2
  exit 1
fi

# Shipped app-icon PNG (single 1024 universal) for each target's catalog, flattened opaque.
for target in App Watch Widget; do
  out="$ROOT/$target/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"
  mkdir -p "$(dirname "$out")"
  rasterize 1024 "$out"
  flatten_alpha "$out"
done

# Verify no alpha/transparency slipped through (fail loud — far cheaper than an App Store reject).
if have python3; then
  python3 - "$ROOT/App/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png" \
            "$ROOT/Watch/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png" \
            "$ROOT/Widget/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png" <<'PY'
import struct, sys
bad = 0
for p in sys.argv[1:]:
    d = open(p, "rb").read()
    off, ct, chunks = 8, None, []
    while off < len(d):
        ln = struct.unpack(">I", d[off:off+4])[0]
        typ = d[off+4:off+8].decode("latin1")
        chunks.append(typ)
        if typ == "IHDR":
            ct = d[off+8+9]           # color type byte (4/6 = has alpha)
        off += 12 + ln
        if typ == "IEND":
            break
    if ct in (4, 6) or "tRNS" in chunks:
        print("ALPHA/transparency present:", p); bad = 1
sys.exit(bad)
PY
  echo "Verified: app icons are 1024x1024 and fully opaque (no alpha)."
else
  echo "WARNING: python3 not found — skipped the no-alpha verification. Confirm opacity manually." >&2
fi

# Verification renders (eyeball proportions at store / iPhone / watch sizes; not shipped).
mkdir -p "$HERE/preview"
for s in 1024 180 88; do rasterize "$s" "$HERE/preview/icon-$s.png"; done

echo "Icons generated into App/Watch/Widget Assets.xcassets and Icon/preview/."
