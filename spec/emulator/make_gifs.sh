#!/usr/bin/env bash
# Builds the README GIFs from the frames of the demo mode (ImageMagick 6):
#
#   RSSREADER_EMU_DEMO=1 spec/emulator/run.sh FRAMES_DIR
#   spec/emulator/make_gifs.sh FRAMES_DIR [OUT_DIR]
#
# OUT_DIR (default docs/images) gets views.gif, quick-reader.gif, reader-settings.gif
# and one still PNG per GIF (for places where a GIF does not move).
# Frames: 45 % (482 px wide), 16 levels of gray (as on the e-ink screen), 1.7 s each,
# 3 s on the first and the last frame, endless loop.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FRAMES="${1:?usage: $0 FRAMES_DIR [OUT_DIR]}"
OUT="${2:-$ROOT/docs/images}"
DELAY=170
DELAY_END=300
mkdir -p "$OUT"

# The same 16 grays for every frame: no flicker between frames, small files. The
# dither keeps the gradients of the card images smooth.
PALETTE="$(mktemp --suffix=.png)"
trap 'rm -f "$PALETTE"' EXIT
convert -size 16x1 gradient:black-white "$PALETTE"

# make_gif NAME STILL FRAME...: the GIF from the frames (in this order) and the
# still PNG from the frame STILL.
make_gif() {
    local name="$1" still="$2"
    shift 2
    local args=() count=$# i=0
    for frame in "$@"; do
        i=$((i + 1))
        if [ "$i" -eq 1 ] || [ "$i" -eq "$count" ]; then
            args+=(-delay "$DELAY_END")
        else
            args+=(-delay "$DELAY")
        fi
        args+=("$FRAMES/$frame.png")
    done
    convert "${args[@]}" -resize 45% -colorspace Gray -dither FloydSteinberg -remap "$PALETTE" \
        -layers Optimize -loop 0 "$OUT/$name.gif"
    convert "$FRAMES/$still.png" -resize 45% -colorspace Gray -dither FloydSteinberg -remap "$PALETTE" \
        -strip "$OUT/$name.png"
    echo "$OUT/$name.gif: $(stat -c %s "$OUT/$name.gif") bytes, $count frames"
}

make_gif views views-03-cards-large \
    views-01-home views-02-folder views-03-cards-large views-04-cards-compact \
    views-05-cards-text views-06-cards-minimal
make_gif quick-reader quick-02-page1 \
    quick-01-cards quick-02-page1 quick-03-page2 quick-04-page3 quick-05-page4 \
    quick-06-page5 quick-07-page6
make_gif reader-settings settings-02-dialog \
    settings-01-article settings-02-dialog settings-03-font-size settings-04-font-size-done \
    settings-05-line-spacing settings-06-line-spacing-done settings-07-font settings-08-font-done
