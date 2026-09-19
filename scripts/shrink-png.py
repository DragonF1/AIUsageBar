#!/usr/bin/env python3
"""Palette-quantises screenshot PNGs in place (needs Pillow and NumPy).

The renderer's PNGs are 32-bit; a 256-colour palette halves them with no visible change on
these flat UI surfaces. Median cut is the only Pillow quantiser that keeps greys grey, and it
runs on RGB only, so the opaque pixels are quantised first and the anti-aliased rounded
corners get a few palette slots of their own, bucketed by alpha, so their transparency survives.
"""
import sys

import numpy as np
from PIL import Image

OPAQUE_COLOURS = 246  # leaves room for the transparent slot and the alpha buckets below
ALPHA_BUCKETS = 8


def shrink(path):
    image = Image.open(path).convert("RGBA")
    pixels = np.asarray(image)
    alpha = pixels[..., 3]
    quantised = Image.fromarray(pixels[..., :3]).quantize(
        colors=OPAQUE_COLOURS, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE
    )
    index = np.asarray(quantised).astype(np.uint16)
    palette = [tuple(int(v) for v in c) + (255,)
               for c in np.asarray(quantised.getpalette(), dtype=np.uint8).reshape(-1, 3)[:OPAQUE_COLOURS]]

    clear = alpha == 0
    index[clear] = len(palette)
    palette.append((0, 0, 0, 0))

    partial = (alpha > 0) & (alpha < 255)
    if partial.any():
        bucket = np.zeros(alpha.shape, dtype=np.int32)
        bucket[partial] = (alpha[partial].astype(np.int32) * ALPHA_BUCKETS) // 256
        for b in range(ALPHA_BUCKETS):
            members = partial & (bucket == b)
            if not members.any():
                continue
            mean = pixels[members][:, :3].mean(axis=0).round().astype(int)
            index[members] = len(palette)
            palette.append((int(mean[0]), int(mean[1]), int(mean[2]),
                            min(int(round((b + 0.5) * 256 / ALPHA_BUCKETS)), 254)))
    assert len(palette) <= 256

    out = Image.frombytes("P", image.size, index.astype(np.uint8).tobytes())
    flat = [v for c in palette for v in c[:3]] + [0, 0, 0] * (256 - len(palette))
    out.putpalette(flat)
    transparency = bytes(c[3] for c in palette) + bytes([255] * (256 - len(palette)))
    out.save(path, optimize=True, transparency=transparency)


if __name__ == "__main__":
    for p in sys.argv[1:]:
        shrink(p)
