#!/usr/bin/env python3
"""Read one character row of a jnext screenshot back as text.

    screen-text.py --font 48.rom SHOT.png ROW     -> prints e.g. "R = Reset"

WHY THIS EXISTS, when screen-diff.py and cell-diff.py are already here.

Both of those compare one picture against another, and neither can say what a
picture *says*. screen-diff.py answers "how much of the screen changed", which
is right for a takeover and useless for a line of text. cell-diff.py's `cells`
mode gets a reading of one piece of text only by finding the same glyphs
somewhere else in the same image — which worked for mfselect, whose menu renders
both candidate labels whatever is installed, and does not work at all for a line
whose words appear nowhere else on the screen.

Without a reading, a check can only assert that two runs disagree. ERRORS.md
records what that is worth: mfselect's M9 compared two runs, passed, and a
reviewer then SWAPPED the two labels — each run showing the other's — and it
passed again. "These two differ" is not "this one is right".

HOW IT READS. No OCR and no committed reference bitmap: the stub prints with the
ZX Spectrum ROM font, which main_bank_entry copies out of the paged-in ROM at
0x3D00 (main.asm:65-70, text.asm's font_address), so the exact bitmap of every
glyph is available from the ROM file on the SD image the bench already mounts.
ula.print_char XORs the glyph onto a screen show_ui has just cleared, at x
positions that are multiples of 8, so a cell is a straight 8x8 blit — reversing
it is a dictionary lookup, not recognition.

Ink and paper are DERIVED from the strip rather than assumed. The row is
required to contain at most two colours, and WHICH of them is ink is settled by
decoding both ways and keeping the reading that produces fewer unknown cells.
That is not a nicety: this screen is white ink on black paper (ui.asm fills the
attributes with WHITE+(BLACK<<3)), the opposite of what "text is dark" would
guess, and guessing wrong turns every cell into '?' rather than into a plausible
wrong answer. The margin is decisive — the wrong polarity inverts every glyph,
and an inverted glyph is not in the font — so a tie means something else is
wrong and is refused. A row using more than two colours is refused too.

Geometry is derived from the image size, as in cell-diff.py: jnext renders
320x256 (a 256x192 screen inside a 32-pixel border) at an integer scale.

Exit status is 0 when a row was read, 2 on any refusal. The reading is printed
with trailing blanks stripped; a completely blank row prints an empty line.
"""
import argparse
import sys

from PIL import Image

# The ROM font holds 96 characters, ' ' (32) to 127, eight bytes each.
FONT_OFFSET = 0x3D00
FONT_FIRST = 32
FONT_COUNT = 96


def load_font(path, offset):
    data = open(path, "rb").read()
    end = offset + FONT_COUNT * 8
    if len(data) < end:
        raise SystemExit(f"{path}: too short for a font at {offset:#06x}")
    glyphs = {}
    for i in range(FONT_COUNT):
        glyphs.setdefault(bytes(data[offset + i * 8:offset + i * 8 + 8]),
                          chr(FONT_FIRST + i))
    return glyphs


def load_shot(path):
    im = Image.open(path).convert("RGB")
    w, h = im.size
    scale, rem = divmod(w, 320)
    if scale < 1 or rem or h != scale * 256:
        raise SystemExit(f"{path}: {w}x{h} is not an integer scale of 320x256")
    return im, scale


def cells_for(sampled, ink):
    """The 32 cells of a sampled row, each as the eight bytes of its bitmap."""
    out = []
    for col in range(32):
        glyph = bytearray(8)
        for y in range(8):
            byte = 0
            for x in range(8):
                if sampled[y][col * 8 + x] == ink:
                    byte |= 0x80 >> x
            glyph[y] = byte
        out.append(bytes(glyph))
    return out


def read_row(im, scale, row, glyphs):
    """`row` as text, choosing the ink colour by which reading decodes."""
    org = 32 * scale
    top = org + row * 8 * scale
    px = im.load()

    # Sample first, decide ink second. Nearest-neighbour scaling means every
    # scale x scale block is one colour, so the top-left pixel of each is it.
    sampled = [[px[org + x * scale, top + y * scale] for x in range(256)]
               for y in range(8)]

    colours = sorted({c for line in sampled for c in line})
    if len(colours) > 2:
        raise SystemExit(
            f"row {row} uses {len(colours)} colours ({colours}); "
            "this reader needs exactly one ink and one paper")
    if len(colours) == 1:
        return " " * 32                 # blank row: nothing but paper

    readings = []
    for ink in colours:
        text = "".join(glyphs.get(c, "?") for c in cells_for(sampled, ink))
        readings.append((text.count("?"), text))
    readings.sort(key=lambda r: r[0])
    if readings[0][0] == readings[1][0]:
        raise SystemExit(
            f"row {row} reads equally (badly) either way round "
            f"({readings[0][0]} unknown cells); the font or the geometry is wrong")
    return readings[0][1]


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--font", required=True,
                    help="a ROM image containing the ZX character set")
    ap.add_argument("--font-offset", type=lambda s: int(s, 0), default=FONT_OFFSET,
                    help=f"where in it the font starts (default {FONT_OFFSET:#06x})")
    ap.add_argument("shot")
    ap.add_argument("row", type=int)
    args = ap.parse_args(argv[1:])

    if not 0 <= args.row < 24:
        raise SystemExit("ROW must be 0..23")

    glyphs = load_font(args.font, args.font_offset)
    im, scale = load_shot(args.shot)

    # An unreadable cell is '?' rather than a refusal: a wrong line is far more
    # useful reported as what it actually shows than as an error.
    print(read_row(im, scale, args.row, glyphs).rstrip())
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
