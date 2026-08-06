#!/usr/bin/env python3
"""Two independent views of one screen, required to agree.

    screen-agreement.py --raw dump.bin --shot shot.png

WHY THIS IS THE INSTRUMENT CHECK, and why it is only available in the emulator.

`test/dzrp/screen.py` reads the Next's screen over DZRP so that observations
which used to need a human with a camera become numbers in a bench. That
reader has to be trusted on hardware, where there is nothing to check it
against — so it must be checked HERE, where there is.

Under jnext there are two completely independent views of the same 6912 bytes:

  * the PNG jnext writes, produced by the emulator's own ULA renderer from its
    own memory, through no code of ours;
  * the DZRP read, produced by the Z80 stub answering CMD_READ_MEM over an
    emulated UART and an emulated ESP-01, parsed by our client.

They share nothing but the machine. If our display-file addressing, our
attribute decoding, our palette or our framing were wrong, the two would
differ — and each is capable of being right while the other is wrong, which is
what makes agreement worth anything. "The code looks correct" is not evidence;
this is.

WHAT IS COMPARED, and all three matter:

  P1  every pixel of the 256x192 screen, rendered from the DZRP bytes against
      the same area of the screenshot. An exact match, not a percentage:
      unlike screen-diff.py's takeover measure there is no noise here, both
      views are of the same frame's memory, so anything but 0 differing pixels
      is a defect in the reader.
  P2  the bright-red count — `error_pixels()` against the same count taken from
      the picture. This is the number that will be quoted in probe output, so
      it is checked directly rather than inferred from P1.

      **THE PNG COUNT IS IN PHYSICAL PIXELS AND OURS IS IN LOGICAL ONES**, and
      conflating them is the first thing this tool got wrong. jnext renders at
      an integer scale — 2 in practice, a 640x512 image — so its whole-image
      `bright_red()` is `scale*scale` times a logical count. That is where the
      figures quoted throughout this project come from: **824 bright-red pixels
      of `TX Timeout` is 206 logical pixels at scale 2**, and a reader that
      printed 206 against a bench that printed 824 would look broken while
      being right. So P2 checks the logical counts are equal AND that the
      whole-image physical count is exactly `scale*scale` times ours.
  P3  the border contributes NO bright red. The PNG measure counts all
      320x256 while ours counts 256x192, so they can only be equal if the
      border is never exactly (255,0,0). ui.asm's error area is the only
      bright red on that screen and `out (BORDER),a` carries no bright bit —
      asserted here rather than believed, because P2's equality silently
      depends on it.

**RUN IT WITH AN ERROR ON THE SCREEN AS WELL AS A CLEAN ONE.** A reader
validated only against a blank error area has been validated against the easy
case: every wrong answer and the right one agree on zero. `run-screen-agreement.sh`
does both, using the injected TX budget that P2 of the tx-patience bench uses
to paint 824 bright-red pixels of `TX Timeout`.

Exit status is 0 when the views agree, 1 when they do not, 2 when the
comparison could not be made at all.
"""
import argparse
import os
import sys

from PIL import Image

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "dzrp"))

import screen  # noqa: E402

BORDER = 32                      # jnext renders 256x192 inside a 32-pixel border


def load_shot(path):
    """The screenshot, and its integer scale. Geometry as in cell-diff.py."""
    im = Image.open(path).convert("RGB")
    w, h = im.size
    scale, rem = divmod(w, 320)
    if scale < 1 or rem or h != scale * 256:
        raise SystemExit("%s: %dx%d is not an integer scale of 320x256" % (path, w, h))
    return im, scale


def shot_pixels(im, scale):
    """The 256x192 screen area, at 1:1. Nearest-neighbour scaling means the
    top-left pixel of each scale x scale block is the whole block."""
    px = im.load()
    out = bytearray(256 * 192 * 3)
    for y in range(192):
        for x in range(256):
            at = (y * 256 + x) * 3
            out[at:at + 3] = bytes(px[(BORDER + x) * scale, (BORDER + y) * scale])
    return bytes(out)


def bright_red_in(raw):
    return sum(1 for i in range(0, len(raw), 3)
               if raw[i] == 255 and raw[i + 1] == 0 and raw[i + 2] == 0)


def bright_red_border(im, scale):
    """Bright red anywhere OUTSIDE the 256x192 screen area."""
    px = im.load()
    w, h = im.size
    count = 0
    for y in range(0, h, scale):
        for x in range(0, w, scale):
            sx, sy = x // scale, y // scale
            if BORDER <= sx < BORDER + 256 and BORDER <= sy < BORDER + 192:
                continue
            if px[x, y] == (255, 0, 0):
                count += 1
    return count * scale * scale


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0],
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--raw", required=True, help="6912 bytes read over DZRP")
    ap.add_argument("--shot", required=True, help="jnext's own screenshot of the same screen")
    ap.add_argument("--label", default="", help="prefix for the result lines")
    args = ap.parse_args()

    tag = (args.label + " ") if args.label else ""

    try:
        raw = open(args.raw, "rb").read()
        scr = screen.Screen(raw)
    except (OSError, ValueError) as e:
        print("cannot use %s: %s" % (args.raw, e))
        return 2
    try:
        im, scale = load_shot(args.shot)
    except (OSError, SystemExit) as e:
        print("cannot use %s: %s" % (args.shot, e))
        return 2

    if scr.flashing():
        print("REFUSED: %d cells have FLASH set, so the screenshot caught one of "
              "two alternating renderings and a pixel comparison is a coin toss"
              % scr.flashing())
        return 2

    ours = scr.render_rgb()
    theirs = shot_pixels(im, scale)

    differing = sum(1 for i in range(0, len(ours), 3)
                    if ours[i:i + 3] != theirs[i:i + 3])
    failures = 0

    if differing:
        # Name the first disagreeing cell: "1841 pixels differ" is not
        # actionable, "row 8 column 3" is.
        at = next(i // 3 for i in range(0, len(ours), 3)
                  if ours[i:i + 3] != theirs[i:i + 3])
        y, x = divmod(at, 256)
        print("FAIL  %sP1 %d of 49152 pixels differ, first at row %d column %d "
              "(x=%d y=%d): the reader and the emulator disagree about the same screen"
              % (tag, differing, y // 8, x // 8, x, y))
        failures += 1
    else:
        print("PASS  %sP1 all 49152 pixels agree — the DZRP read renders exactly "
              "as jnext drew it" % tag)

    ours_red = scr.error_pixels()
    theirs_red = bright_red_in(theirs)
    whole_red = bright_red_in(Image.open(args.shot).convert("RGB").tobytes())
    if ours_red == theirs_red and whole_red == ours_red * scale * scale:
        print("PASS  %sP2 both views count %d bright-red pixels of error text "
              "(%d in the picture, at scale %d)" % (tag, ours_red, whole_red, scale))
    else:
        print("FAIL  %sP2 bright red: %d over DZRP, %d logical in the screen area, "
              "%d physical in the whole image at scale %d — expected %d and %d"
              % (tag, ours_red, theirs_red, whole_red, scale,
                 ours_red, ours_red * scale * scale))
        failures += 1

    border_red = bright_red_border(im, scale)
    if border_red:
        print("FAIL  %sP3 the border holds %d bright-red pixels, so the whole-image "
              "count the benches take is not the error area alone"
              % (tag, border_red))
        failures += 1
    else:
        print("PASS  %sP3 no bright red outside the screen area, so a whole-image "
              "count is the error text and nothing else" % tag)

    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
