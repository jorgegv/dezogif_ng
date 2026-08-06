#!/usr/bin/env python3
"""The client half of test/run-screen-agreement.sh.

    screen-agreement-client.py --dump raw.bin [--provoke-error]

Reads the stub's screen over DZRP and writes the 6912 raw bytes out, so the
bench can compare them against jnext's own screenshot of the same screen.

`--provoke-error` first sends command 42 (CMD_ADD_WATCHPOINT) on a SEPARATE,
throwaway connection. That command is outside `cmd_jump_table`, so
`get_cmd_pointer` routes it to `cmd_not_supported`, which stores
ERROR_CMD_NOT_SUPPORTED and jumps to `drain_main` — the stub repaints with
`Last Error: / Command not supported` in bright red and goes on serving.

WHY THAT LEVER, AND NOT AN INJECTED TIMEOUT. The red screen this bench needs is
the DISCRIMINATING half: a reader checked only against a blank error area has
been checked against the case where every wrong answer and the right one all
agree on zero. The obvious source is the tx-patience bench's P2, which paints
824 bright-red pixels of `TX Timeout` — but it gets there by making the module
too slow to answer an AT+CIPSEND, and this bench has to read 6912 bytes back
through that same crippled transport. It would be measuring the injection.

`cmd_not_supported` costs nothing: **the same shipped ROM as the clean run, one
extra command**, and the transport stays healthy, so the two runs differ in
exactly the thing being varied.

THE PROVOKING CONNECTION IS NOT THE READING ONE, and that is not tidiness.
`cmd_not_supported` sends no response at all, so its connection is left holding
a request that will never be answered; reading over it would mean reading a
stream with an unanswered command in front of it. It is closed, and the read
takes a fresh connection.

**NO CMD_INIT IS EVER SENT**, on either connection. It would clear `last_error`
and repaint — see screen.py. The read is a bare CMD_READ_MEM, which `cmd_loop`
dispatches with no session gate.

Prints `EXCHANGE_DONE <epoch>` when the screen has been read, so the bench can
check that jnext's frame-scheduled screenshot came AFTER it.

THEN IT HOLDS THE CONNECTION OPEN UNTIL `--hold-until` APPEARS, AND THAT IS
LOAD-BEARING RATHER THAN POLITE. "The screenshot came after the read" is not
"the screenshot is of the screen that was read", and the difference was
measured: the first version of this bench let the client disconnect as soon as
it had the bytes, and BOTH runs then failed with the screenshot showing
`Last Error: / RX Timeout` where the DZRP read had shown a clean area (G1) and
`Command not supported` (G2).

That is not a fault in the reader — it is the WiFi build's documented behaviour
(MEMORY.md, issue #16): parked in `cmd_loop`'s wait, the `<id>,CLOSED` the
module emits when a client hangs up ends the wait and then fails to parse as a
`+IPD` header, reaching `drain_main`. **So a client disconnecting repaints the
error area**, and a screenshot taken afterwards is of a different screen.

Holding the socket removes that repaint from the window. The bench creates the
sentinel once it has the screenshot, so the read and the capture bracket a
period in which nothing repaints.
"""
import argparse
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import dzrp        # noqa: E402
import screen      # noqa: E402

UNSUPPORTED_CMD = 42            # CMD_ADD_WATCHPOINT: outside the jump table


def connect(host, port, timeout):
    return dzrp.Dzrp(dzrp.TcpTransport(host, port, timeout),
                     start_byte=None, base_timeout=timeout)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=11000)
    ap.add_argument("--timeout", type=float, default=20.0)
    ap.add_argument("--dump", required=True)
    ap.add_argument("--provoke-error", action="store_true")
    ap.add_argument("--settle", type=float, default=2.0,
                    help="seconds after provoking, so the repaint is complete "
                         "before the screen is read")
    ap.add_argument("--hold-until", metavar="PATH",
                    help="keep the reading connection OPEN until this file "
                         "exists — see the docstring; without it the client's "
                         "own disconnect repaints the error area")
    ap.add_argument("--hold-timeout", type=float, default=300.0)
    args = ap.parse_args()

    if args.provoke_error:
        try:
            conv = connect(args.host, args.port, args.timeout)
        except OSError as e:
            print("could not connect to provoke: %s" % e)
            return 2
        try:
            conv.command(UNSUPPORTED_CMD, b"")
            # Answered — so this is no longer an unsupported command and the
            # bench's red screen would not appear. Say so rather than going on
            # to report a clean screen as a disagreement.
            print("PROVOKE_ANSWERED command %d was answered; it is no longer "
                  "routed to cmd_not_supported" % UNSUPPORTED_CMD)
            conv.close()
            return 3
        except dzrp.Timeout:
            pass                                # silence is the expected outcome
        except (OSError, dzrp.DzrpError) as e:
            print("provoke: %s: %s" % (type(e).__name__, e))
        conv.close()
        time.sleep(args.settle)

    try:
        conv = connect(args.host, args.port, args.timeout)
    except OSError as e:
        print("could not connect to read: %s" % e)
        return 2
    try:
        glyphs = screen.read_font(conv)
        scr = screen.read_screen(conv, glyphs=glyphs)
    except (OSError, dzrp.DzrpError, ValueError) as e:
        print("could not read the screen: %s: %s" % (type(e).__name__, e))
        conv.close()
        return 2

    open(args.dump, "wb").write(scr.raw)

    ok, got = scr.validate_reader()
    print("READER_VALID %s (row %d reads %r)"
          % ("yes" if ok else "NO", screen.VALIDATION_ROW, got))
    print("ERROR_PIXELS %d" % scr.error_pixels())
    for line in scr.error_text():
        print("ERROR_TEXT %s" % line)
    for i, line in enumerate(scr.status_block()):
        print("STATUS_%d %s" % (i, line))
    print("EXCHANGE_DONE %.3f" % time.time())
    sys.stdout.flush()

    if args.hold_until:
        # The connection stays OPEN across this wait. Nothing is sent on it:
        # the point is only that the module never emits `<id>,CLOSED`, so the
        # stub is never pushed into drain_main and the screen cannot change.
        deadline = time.time() + args.hold_timeout
        while time.time() < deadline:
            if os.path.exists(args.hold_until) and os.path.getsize(args.hold_until):
                break
            time.sleep(0.25)
        else:
            print("HOLD_TIMEOUT %s never appeared after %.0f s"
                  % (args.hold_until, args.hold_timeout))
            conv.close()
            return 2
        print("HELD_UNTIL %s" % args.hold_until)

    conv.close()
    return 0 if ok else 2


if __name__ == "__main__":
    sys.exit(main())
