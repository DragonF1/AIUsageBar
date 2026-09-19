#!/bin/bash
# Renders the README screenshots into docs/screenshots/ from fixture numbers: the app's --render
# flag draws every surface (menu bar strip, popover, sessions and cost windows) for each tab in
# light and dark mode, without touching your usage, transcripts or Keychain and without any
# Screen Recording grant. Windows flash up for a few seconds while it runs.
# Pass a directory to render somewhere else.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-docs/screenshots}"

swift build -c release 2>&1 | tail -1
BIN=".build/release/AIUsageBar"

# The pictures carry the clock ("Updated 4:07 PM", "last answer 2m ago", a lighter weekend
# "Today"), so unless RENDER_TZ says otherwise they are rendered in a zone where it is a weekday
# mid afternoon right now. Etc/GMT zones are sign-inverted: Etc/GMT-3 is UTC+3.
pick_zone() {
    local fallback=""
    for offset in $(seq -12 14); do
        local zone
        if (( offset >= 0 )); then zone="Etc/GMT-$offset"; else zone="Etc/GMT+$(( -offset ))"; fi
        read -r weekday hour <<< "$(TZ=$zone date '+%u %H')"
        hour=$((10#$hour))
        if (( weekday <= 5 && hour >= 14 && hour <= 16 )); then echo "$zone"; return; fi
        if [[ -z "$fallback" ]] && (( weekday <= 5 && hour >= 13 && hour <= 17 )); then fallback=$zone; fi
    done
    echo "${fallback:-UTC}"
}
ZONE="${RENDER_TZ:-$(pick_zone)}"
echo "Rendering in $ZONE ($(TZ=$ZONE date '+%a %H:%M'))"

# One process per appearance: AppKit resolves colours against the first appearance it draws under.
mkdir -p "$OUT"
TZ="$ZONE" "$BIN" --render "$OUT" --appearance light >/dev/null
TZ="$ZONE" "$BIN" --render "$OUT" --appearance dark >/dev/null

# Optional: palette-quantise (halves the files) when Pillow and NumPy are around.
if python3 -c "import PIL, numpy" 2>/dev/null; then
    python3 scripts/shrink-png.py "$OUT"/*.png
else
    echo "Pillow or NumPy missing; PNGs left at full size (pip3 install pillow numpy)"
fi
du -ch "$OUT"/*.png | tail -1
