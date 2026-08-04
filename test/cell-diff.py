#!/usr/bin/env python3
"""Compare character cells of jnext screenshots.

    cell-diff.py rows  A.png B.png ROW    -> differing columns of ROW, e.g. "23 24 25 26"
                                             (an empty line if the row is identical)
    cell-diff.py cells SPEC SPEC          -> "same" or "differ"
                                             SPEC = FILE@ROW:COL0-COL1

screen-diff.py answers "how much of the screen changed". That is the right
question for a screen takeover and the wrong one for a line of text: two status
lines differing in exactly the four characters of a transport name differ in
about 0.05% of the screen, which no threshold can tell from noise.

**`rows` compares two screenshots; `cells` compares two pieces of text.** That
distinction is the whole reason the second mode exists, and it was added because
the first one alone was not enough. A check built on `rows` can say that two runs
disagree about something at columns 23-26; it can NOT say which of them is right,
because it has no reading of either. Two labels **swapped** — each run showing
the other's — differ in exactly those columns and sail through. Demonstrated
rather than theorised: an independent reviewer swapped the two strings in
mfselect's installed_name() and the bench stayed green.

`cells` closes that without OCR and without a committed reference bitmap, by
comparing a piece of text against another piece of text **inside one
screenshot**. mfselect's menu renders `dezogif_ng WiFi (ESP-01)` and
`dezogif_ng UART (joy port)` on rows 6 and 7 whatever is installed, so the
correct glyphs for both labels are already on screen, in the same ROM font and
under the same attribute as the status row. Requiring the status row's transport
field to match the RIGHT menu entry and to differ from the other is ground truth
internal to a single image, which a swap cannot satisfy.

Geometry: jnext renders 320x256 — a 256x192 screen inside a 32-pixel border — at
an integer scale, so the paper origin is (32,32) scaled and a character cell is 8
pixels scaled. Derived from the image size rather than hardcoded, so a different
--scale does not silently shift every column.

Cells are compared as raw pixels, so INK and PAPER must match as well as the
glyphs: a normal row compared against an inverse-video one reports "differ"
however identical the text. mfselect's status row and its *unselected* menu rows
are both ATTR_BODY; keeping the selected row out of the comparison is the
caller's job.
"""
import re
import sys

from PIL import Image

SPEC = re.compile(r"^(?P<path>.+)@(?P<row>\d+):(?P<c0>\d+)-(?P<c1>\d+)$")


def load(path):
    im = Image.open(path).convert("RGB")
    w, h = im.size
    scale, rem = divmod(w, 320)
    if scale < 1 or rem or h != scale * 256:
        raise SystemExit(f"{path}: {w}x{h} is not an integer scale of 320x256")
    return im, scale


def cell(im, scale, row, col):
    org = 32 * scale
    size = 8 * scale
    left = org + col * size
    top = org + row * size
    return im.crop((left, top, left + size, top + size)).tobytes()


def check_bounds(row, c0, c1):
    if not 0 <= row < 24:
        raise SystemExit("ROW must be 0..23")
    if not 0 <= c0 <= c1 < 32:
        raise SystemExit("columns must be 0..31 and COL0 <= COL1")


def cmd_rows(argv):
    if len(argv) != 3:
        raise SystemExit("usage: cell-diff.py rows A.png B.png ROW")
    row = int(argv[2])
    check_bounds(row, 0, 31)

    ia, sa = load(argv[0])
    ib, sb = load(argv[1])
    if ia.size != ib.size:
        raise SystemExit("screenshots are different sizes")

    differing = [c for c in range(32)
                 if cell(ia, sa, row, c) != cell(ib, sb, row, c)]
    print(" ".join(str(c) for c in differing))
    return 0


def parse(spec):
    m = SPEC.match(spec)
    if not m:
        raise SystemExit(f"bad cell spec {spec!r}; expected FILE@ROW:COL0-COL1")
    row, c0, c1 = (int(m.group(k)) for k in ("row", "c0", "c1"))
    check_bounds(row, c0, c1)
    im, scale = load(m.group("path"))
    return [cell(im, scale, row, c) for c in range(c0, c1 + 1)]


def cmd_cells(argv):
    if len(argv) != 2:
        raise SystemExit("usage: cell-diff.py cells FILE@ROW:C0-C1 FILE@ROW:C0-C1")
    a = parse(argv[0])
    b = parse(argv[1])
    if len(a) != len(b):
        raise SystemExit("the two specs cover different numbers of cells")
    print("same" if a == b else "differ")
    return 0


def main(argv):
    if len(argv) < 2 or argv[1] not in ("rows", "cells"):
        print("usage: cell-diff.py rows  A.png B.png ROW\n"
              "       cell-diff.py cells FILE@ROW:C0-C1 FILE@ROW:C0-C1", file=sys.stderr)
        return 2
    return cmd_rows(argv[2:]) if argv[1] == "rows" else cmd_cells(argv[2:])


if __name__ == "__main__":
    sys.exit(main(sys.argv))
