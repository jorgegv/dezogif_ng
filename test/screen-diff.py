#!/usr/bin/env python3
"""Print how much two jnext screenshots differ, as a percentage of pixels.

Usage: screen-diff.py A.png B.png   ->  prints e.g. "91.41"

Exists because "the screenshots are not byte-identical" is far too weak a
test for "the stub took over the screen": a single character of NextZXOS
repainting is enough to satisfy it. The bench thresholds this number
instead.
"""
import sys
from PIL import Image, ImageChops


def main(argv):
    if len(argv) != 3:
        print("usage: screen-diff.py A.png B.png", file=sys.stderr)
        return 2
    a = Image.open(argv[1]).convert("RGB")
    b = Image.open(argv[2]).convert("RGB")
    if a.size != b.size:
        print("100.00")
        return 0
    raw = ImageChops.difference(a, b).tobytes()
    differing = sum(1 for i in range(0, len(raw), 3) if raw[i] or raw[i + 1] or raw[i + 2])
    print(f"{100.0 * differing / (a.width * a.height):.2f}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
