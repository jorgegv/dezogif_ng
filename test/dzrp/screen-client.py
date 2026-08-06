#!/usr/bin/env python3
"""Read the stub's screen over DZRP and say what is on it.

    screen-client.py --host 192.168.1.42 [--dump raw.bin] [--dump-font f.bin]

Prints the reader's own validation, the error-area reading, the session line,
and every non-blank row — then exits 0 if the screen was READ, whatever it
said. A screen with an error on it is a successful reading, not a failure:
this is an instrument, like the probes it feeds.

Exit codes:
  0  the screen was read and reported
  2  nothing could be read — no listener, or the reader failed its own
     row-12 validation, which means a broken instrument and NOT a clean screen

**IT SENDS NO CMD_INIT.** That would clear `last_error` and repaint the very
area being read; see screen.py. It sends CMD_READ_MEM and nothing else, and
it does not send CMD_CLOSE either — closing the session would repaint through
`jp main` and change the session line this may have been run to read.
"""
import argparse
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import dzrp        # noqa: E402
import screen      # noqa: E402


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--host", required=True)
    ap.add_argument("--port", type=int, default=11000)
    ap.add_argument("--timeout", type=float, default=20.0,
                    help="6912 bytes at 115200 is ~1 s on a Next; be generous")
    ap.add_argument("--dump", help="write the 6912 raw bytes here")
    ap.add_argument("--dump-font", help="write the 768 font bytes here")
    ap.add_argument("--font", help="a local ROM to take the font from instead of "
                                   "the machine (fallback; see screen.py)")
    ap.add_argument("--quiet", action="store_true",
                    help="print only the one-line observation")
    ap.add_argument("--attempts", type=int, default=3,
                    help="fresh connections to try before giving up (default 3)")
    args = ap.parse_args()

    # RETRIED, ON A FRESH CONNECTION, and the reason is measured. A command
    # arriving while the stub is inside `drain_main`'s ~100 ms drain is read off
    # the wire and DISCARDED (MEMORY.md's CRLF entry), so a read attempted just
    # after another client disconnected can time out against a perfectly healthy
    # machine. Seen here: three runs of this tool back to back, and the third
    # got `timed out after 0 of 1 bytes` while the first two were fine.
    #
    # Same reasoning as hardware-check.py's `connect()`: this tool's subject is
    # what the screen SAYS, so a transient must not be reported as "the screen
    # could not be read". It is the opposite of the slot-ceiling probe, whose
    # subject IS the transient and which therefore never retries.
    #
    # It costs a connection per attempt, which is why `screen.observe()` — used
    # inside the probes, over a connection they already hold — does not do this.
    scr = font_bytes = None
    why = "no attempt was made"
    for attempt in range(max(1, args.attempts)):
        if attempt:
            time.sleep(1.0)
        conv = None
        try:
            conv = dzrp.Dzrp(dzrp.TcpTransport(args.host, args.port, args.timeout),
                             start_byte=None, base_timeout=args.timeout)
            if args.font:
                glyphs = screen.load_font_file(args.font)
                font_bytes = None
            else:
                font_bytes = screen.read_mem(conv, screen.FONT_ADDR, screen.FONT_LEN)
                glyphs = screen.glyph_table(font_bytes)
            scr = screen.read_screen(conv, glyphs=glyphs)
            break
        except (OSError, dzrp.DzrpError, ValueError) as e:
            why = "%s: %s" % (type(e).__name__, e)
        finally:
            if conv is not None:
                conv.close()

    if scr is None:
        print("could not read the screen after %d attempt(s) — %s"
              % (max(1, args.attempts), why))
        return 2

    if args.dump:
        open(args.dump, "wb").write(scr.raw)
    if args.dump_font and font_bytes:
        open(args.dump_font, "wb").write(font_bytes)

    ok, got = scr.validate_reader()
    if args.quiet:
        print(scr.observation())
        return 0 if ok else 2

    print("screen read from %s:%d — %d bytes" % (args.host, args.port, len(scr.raw)))
    print("  reader validation: row %d reads %r (%s)"
          % (screen.VALIDATION_ROW, got, "OK" if ok else "WRONG — instrument fault"))
    if not ok:
        print("  NOT reporting this screen's contents: a reader that cannot read "
              "row 12 saying 'no error' would mean nothing.")
        return 2
    print("  error area: %d bright-red pixels" % scr.error_pixels())
    for line in scr.error_text():
        print("    ! %s" % line)
    print("  session line (row %d): %r"
          % (screen.SESSION_ROW, scr.row_text(screen.SESSION_ROW).rstrip()))
    if scr.flashing():
        print("  NOTE: %d cells have FLASH set; a render of those is only true "
              "half the time" % scr.flashing())
    print("  full screen:")
    for row in range(screen.ROWS):
        text = scr.row_text(row).rstrip()
        if text:
            print("    %2d | %s" % (row, text))
    return 0


if __name__ == "__main__":
    sys.exit(main())
