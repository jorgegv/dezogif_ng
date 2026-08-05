#!/usr/bin/env python3
"""A client that speaks once and then goes quiet WITHOUT hanging up.

The client half of test/run-no-hang.sh's N1 and N2 (issue #16, part A). Its job
is to put the stub into `cmd_loop`'s wait — which happens the moment a command
has been answered — and then leave it there, so the bench can photograph the
screen and see whether the stub is still alive.

WHY IT MUST NOT CLOSE THE SOCKET. A disconnect makes the module emit
`<id>,CLOSED`, and any byte at all from the module ends that wait. So a client
that hangs up tests nothing: the stub would leave the loop either way. The
silence has to be a live, attached, idle client — which is also exactly what a
DeZog session stopped at a breakpoint looks like.

WHY THE VERDICT IS A PHOTOGRAPH AND NOT A REPLY. A second command also ends the
wait, for the same reason, so "can it still answer" does NOT discriminate a
bounded wait from an unbounded one — it was measured on real hardware too
(a client killed mid-command, the next connection answered in 4 ms). The only
thing that differs is what the stub DID with the silence: the bounded build
gives up, reports RX Timeout and repaints, and the unbounded one is still
sitting in the loop with a clean screen. So this client's contribution is the
silence and the ORDERING guard below; the bench reads the pixels.

THE ORDERING GUARD IS THE POINT OF --after-shot. The screenshot is taken at a
fixed emulated frame count, and headless jnext runs frames far faster than real
time, so "the screenshot lands after the exchange" is a timing assumption and
not a fact. This client refuses to let it be an assumption: it requires the file
to be ABSENT when its first command is answered and then waits for it to appear.
A run where the picture was taken too early exits 12 and the bench says the run
proves nothing, rather than reporting a clean screen as evidence of a hang.

EXIT CODES
  0   the exchange was answered, the screenshot was taken after it, and the
      trailing exchange (reported, not asserted) was attempted
  1   the first CMD_INIT was never answered — the run is not evidence
  2   could not connect at all
  12  the screenshot already existed when the first command was answered
  13  the screenshot never appeared inside --shot-timeout
"""

import argparse
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import dzrp                                          # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=11000)
    ap.add_argument("--timeout", type=float, default=20.0)
    ap.add_argument("--after-shot", required=True,
                    help="the screenshot the bench will judge; must not exist "
                         "yet when the first command is answered")
    ap.add_argument("--shot-timeout", type=float, default=180.0)
    args = ap.parse_args()

    try:
        t = dzrp.TcpTransport(args.host, args.port, args.timeout)
    except Exception as e:                          # noqa: BLE001
        print("could not connect to %s:%d — %s" % (args.host, args.port, e))
        return 2

    # No 0xA5 preamble: this is the WiFi build (transport_esp.asm, point 1).
    d = dzrp.Dzrp(t, start_byte=None)

    t0 = time.time()
    try:
        d.command(dzrp.CMD_INIT, dzrp.init_payload())
    except Exception as e:                          # noqa: BLE001
        print("CMD_INIT unanswered after %.1fs — %s: %s"
              % (time.time() - t0, type(e).__name__, e))
        t.close()
        return 1
    print("CMD_INIT answered in %.2fs; the stub is now in cmd_loop's wait"
          % (time.time() - t0))

    if os.path.exists(args.after_shot):
        print("the screenshot %s already existed — it was taken BEFORE the "
              "exchange, so this run says nothing about what the stub did with "
              "the silence" % args.after_shot)
        t.close()
        return 12

    # Silence, with the socket held open. Nothing is sent and nothing is read.
    print("holding the connection open and saying nothing, until %s appears"
          % args.after_shot)
    t0 = time.time()
    while not os.path.exists(args.after_shot):
        if time.time() - t0 > args.shot_timeout:
            print("no screenshot after %.0fs" % args.shot_timeout)
            t.close()
            return 13
        time.sleep(0.25)
    # The file can exist before it is complete; the bench waits for a non-empty
    # one too, and a moment here costs nothing.
    time.sleep(0.5)
    print("screenshot appeared after %.1fs of silence" % (time.time() - t0))

    # REPORTED, NOT ASSERTED. Both builds answer this — see the docstring.
    t.set_timeout(args.timeout)
    t0 = time.time()
    try:
        d.command(dzrp.CMD_INIT, dzrp.init_payload())
        print("a later command on the SAME connection was answered in %.2fs "
              "(both builds do this; it is not the verdict)" % (time.time() - t0))
    except Exception as e:                          # noqa: BLE001
        print("a later command on the same connection was NOT answered — %s: %s"
              % (type(e).__name__, e))
    t.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
