#!/usr/bin/env python3
"""Draws the app icon: three usage bars on a dark squircle, the way the popover shows limits.

Writes an .iconset next to the output and folds it into AppIcon.icns with iconutil.
Needs Pillow: `python3 -m pip install pillow`.

    scripts/make-icon.py Sources/AIUsageBar/Resources/AppIcon.icns
"""
import os
import shutil
import subprocess
import sys

from PIL import Image, ImageDraw

SCALE = 4  # draw big, downsample for clean edges
SIZE = 1024 * SCALE

BACKGROUND_TOP = (30, 33, 44)
BACKGROUND_BOTTOM = (18, 20, 28)
TRACK = (52, 56, 72)
BARS = [  # (fill fraction, colour), matching the green / yellow / red bands of the meter
    (0.42, (82, 196, 120)),
    (0.68, (236, 190, 72)),
    (0.90, (232, 92, 86)),
]


def rounded_gradient(size, radius):
    """Vertical gradient clipped to a squircle-ish rounded rectangle."""
    gradient = Image.new("RGB", (1, size))
    for y in range(size):
        t = y / (size - 1)
        gradient.putpixel((0, y), tuple(
            round(BACKGROUND_TOP[i] * (1 - t) + BACKGROUND_BOTTOM[i] * t) for i in range(3)))
    gradient = gradient.resize((size, size))
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, size - 1, size - 1), radius=radius, fill=255)
    icon = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    icon.paste(gradient, (0, 0), mask)
    return icon


def draw(size):
    # Apple's template leaves a margin around the icon body so it sits like the system icons.
    body = round(size * 0.80)
    offset = (size - body) // 2
    icon = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    icon.paste(rounded_gradient(body, round(body * 0.225)), (offset, offset))
    d = ImageDraw.Draw(icon)

    left = offset + round(body * 0.17)
    right = offset + body - round(body * 0.17)
    height = round(body * 0.11)
    gap = round(body * 0.085)
    total = len(BARS) * height + (len(BARS) - 1) * gap
    top = offset + (body - total) // 2
    for fraction, colour in BARS:
        d.rounded_rectangle((left, top, right, top + height), radius=height // 2, fill=TRACK)
        end = left + round((right - left) * fraction)
        d.rounded_rectangle((left, top, end, top + height), radius=height // 2, fill=colour)
        top += height + gap
    return icon


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    out = sys.argv[1]
    master = draw(SIZE).resize((1024, 1024), Image.LANCZOS)
    iconset = os.path.splitext(out)[0] + ".iconset"
    shutil.rmtree(iconset, ignore_errors=True)
    os.makedirs(iconset)
    for points in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            px = points * scale
            name = f"icon_{points}x{points}" + ("@2x" if scale == 2 else "") + ".png"
            master.resize((px, px), Image.LANCZOS).save(os.path.join(iconset, name))
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", out], check=True)
    shutil.rmtree(iconset)
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
