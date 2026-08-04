#!/usr/bin/env python3
"""Which character cells differ between two jnext screenshots, on one row.

Usage: cell-diff.py A.png B.png ROW   ->  prints e.g. "23 24 25 26"
                                          (empty line if the row is identical)

screen-diff.py answers "how much of the screen changed". That is the right
question for a screen takeover and the wrong one for a line of text: two status
lines differing in exactly the four characters of a transport name differ in
about 0.05% of the screen, which no threshold can tell from noise.

This reports the differing 8x8 character cells of ONE row instead, so a check
can name the columns that are allowed to differ. That is a far tighter
assertion than a percentage: it fails if the two lines are identical (nothing
differs), if they differ anywhere else (a different string, not a different
variant field), or if either line was never drawn (the whole row differs).

Geometry: jnext renders 320x256 — a 256x192 screen inside a 32-pixel border —
at an integer scale, so the paper origin is (32,32) scaled and a character cell
is 8 pixels scaled. Derived from the image size rather than hardcoded, so a
different --scale does not silently shift every column.
"""
import sys

from PIL import Image


def cells(path):
    im = Image.open(path).convert("RGB")
    w, h = im.size
    scale, rem = divmod(w, 320)
    if scale < 1 or rem or h != scale * 256:
        raise SystemExit(f"{path}: {w}x{h} is not an integer scale of 320x256")
    return im, scale


def main(argv):
    if len(argv) != 4:
        print("usage: cell-diff.py A.png B.png ROW", file=sys.stderr)
        return 2
    row = int(argv[3])
    if not 0 <= row < 24:
        print("ROW must be 0..23", file=sys.stderr)
        return 2

    ia, sa = cells(argv[1])
    ib, sb = cells(argv[2])
    if ia.size != ib.size:
        raise SystemExit("screenshots are different sizes")

    org = 32 * sa
    cell = 8 * sa
    top = org + row * cell

    differing = []
    for col in range(32):
        left = org + col * cell
        box = (left, top, left + cell, top + cell)
        if ia.crop(box).tobytes() != ib.crop(box).tobytes():
            differing.append(col)

    print(" ".join(str(c) for c in differing))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
