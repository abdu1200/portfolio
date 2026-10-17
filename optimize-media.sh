#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# optimize-media.sh
# Turns the raw screen recordings and screenshots in media-src/ into the small,
# web-ready files the site actually serves from public/media/.
#
#   media-src/<slug>.mp4            -> public/media/<slug>.webm  (VP9, primary)
#                                   -> public/media/<slug>.mp4   (H.264, fallback)
#   media-src/<slug>-thumbnail.png  -> public/media/<slug>.webp  (1600w poster)
#                         (or .jpg)
#
# Every output is framed for the 16:10 project card at up to 1600x1000. The card
# fills its box by cropping, so a source's height is what decides sharpness;
# 1000px keeps it crisp on high-DPI screens.
#
#   Landscape (desktop recordings, site screenshots): centre-cropped to 16:10,
#   the same area the card would show anyway, then scaled to at most 1600 wide.
#
#   Portrait (phone recordings, app screenshots): would be cut to a thin strip,
#   so the media is centred at full height and each side is filled from its own
#   outer edge, stretched and softened, so the fill continues its edge colour.
#
# The cards are muted, looping previews, so audio is stripped, video is capped
# at 30fps, and the MP4 gets +faststart so playback can begin before the whole
# file has arrived.
#
# Usage: npm run media            (only re-encodes outputs older than their source)
#        FORCE=1 npm run media    (re-encodes everything)
# -----------------------------------------------------------------------------
set -euo pipefail

SRC=media-src
OUT=public/media
mkdir -p "$OUT"

stale() { [[ -n "${FORCE:-}" || ! -f "$2" || "$1" -nt "$2" ]]; }

dims() { ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0:s=x "$1"; }

is_portrait() {
  local d; d=$(dims "$1")
  (( ${d#*x} > ${d%x*} ))
}

# The 16:10 frame filter for a source: a centre crop for landscape, or the
# edge-extended 1600x1000 frame for portrait.
frame() {
  if ! is_portrait "$1"; then
    echo "crop='min(iw,ih*16/10)':'min(ih,iw*10/16)',scale='min(1600,iw)':-2:flags=lanczos"
    return
  fi
  local W=1600 H=1000 d sw sh mw left right
  d=$(dims "$1"); sw=${d%x*}; sh=${d#*x}
  mw=$(( sw * H / sh / 2 * 2 ))            # media width at full height, kept even
  left=$(( (W - mw) / 2 )); right=$(( W - mw - left ))
  echo "scale=$mw:$H:flags=lanczos,split=3[m][l][r];[l]crop=8:ih:0:0,scale=$left:$H,boxblur=30:2[L];[r]crop=8:ih:iw-8:0,scale=$right:$H,boxblur=30:2[R];[L][m][R]hstack=3"
}

for video in "$SRC"/*.mp4; do
  [[ -e "$video" ]] || continue
  slug=$(basename "$video" .mp4)
  VF="$(frame "$video"),fps=30"

  if stale "$video" "$OUT/$slug.mp4"; then
    echo "→ $slug.mp4"
    ffmpeg -loglevel error -y -i "$video" -an -vf "$VF" \
      -c:v libx264 -preset slow -crf 28 -pix_fmt yuv420p -profile:v high \
      -movflags +faststart "$OUT/$slug.mp4"
  fi

  if stale "$video" "$OUT/$slug.webm"; then
    echo "→ $slug.webm"
    ffmpeg -loglevel error -y -i "$video" -an -vf "$VF" \
      -c:v libvpx-vp9 -crf 38 -b:v 0 -row-mt 1 -deadline good -cpu-used 2 \
      "$OUT/$slug.webm"
  fi
done

for thumb in "$SRC"/*-thumbnail.{png,jpg}; do
  [[ -e "$thumb" ]] || continue
  slug=$(basename "$thumb"); slug=${slug%-thumbnail.*}

  out="$OUT/$slug.webp"
  if stale "$thumb" "$out"; then
    echo "→ $slug.webp"
    ffmpeg -loglevel error -y -i "$thumb" -vf "$(frame "$thumb")" \
      -c:v libwebp -quality 80 -compression_level 6 "$out"
  fi
done

# Portraits: a 3:4 head-and-shoulders crop out of the full-length studio shots.
#   media-src/profile-1.jpg -> public/media/portrait-hero.webp
#   media-src/profile-2.jpg -> public/media/portrait-about.webp
portrait() {
  local src="$SRC/$1" out="$OUT/$2.webp"
  [[ -e "$src" ]] || return 0
  if stale "$src" "$out"; then
    echo "→ $2.webp"
    ffmpeg -loglevel error -y -i "$src" -vf "crop=640:853:$3:$4" \
      -c:v libwebp -quality 82 -compression_level 6 "$out"
  fi
}
portrait profile-1.jpg portrait-hero 106 120
portrait profile-2.jpg portrait-about 150 150

# Favicons: a square, greyscale head crop of the hero portrait, at the sizes
# browsers, Google results and iOS home screens ask for.
if [[ -e "$SRC/profile-1.jpg" ]] && stale "$SRC/profile-1.jpg" public/favicon-48.png; then
  echo "→ favicons"
  for size in 48 96 180; do
    name=$([[ $size == 180 ]] && echo apple-touch-icon || echo "favicon-$size")
    ffmpeg -loglevel error -y -i "$SRC/profile-1.jpg" \
      -vf "crop=640:853:106:120,crop=460:460:100:10,format=gray,eq=contrast=1.15:brightness=0.03,scale=$size:$size:flags=lanczos" \
      "public/$name.png"
  done
  # /favicon.ico is what browsers request when nothing else is declared.
  ffmpeg -loglevel error -y -i public/favicon-48.png -pix_fmt bgra public/favicon.ico
fi

du -h "$OUT"/* | sort -k2
