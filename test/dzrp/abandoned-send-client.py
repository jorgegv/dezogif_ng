#!/usr/bin/env python3
"""Two clients in a row, where the FIRST one's reply is expected to be lost.

The client half of test/run-no-hang.sh's N3 (issue #16, part B). It exists to
ask one question that no other check here asks: after the stub has announced an
`AT+CIPSEND=<id>,<len>` and then walked away without writing `<len>` bytes, is
the MODULE still able to serve anybody?

WHY THAT IS ANSWERABLE IN THE EMULATOR AT ALL. jnext's AT engine enters
`Mode::Payload` the instant it accepts an `AT+CIPSEND` and stays there until
exactly `<len>` bytes have arrived — `esp01/src/esp_at.cpp:496` sets the mode
and queues the prompt, `:181` counts every later byte against it, and there is
no timeout anywhere in between. So an abandoned send leaves the emulated module
swallowing whatever the stub writes next, which is precisely the state issue #15
hypothesised on hardware, reproduced here by construction rather than by luck.

THE FIRST EXCHANGE IS NOT ASSERTED ON. With the injected budget the prompt
arrives later than the stub is willing to wait, so whether that reply comes back
depends on the fix under test and on timing; either outcome is reported and
neither is a verdict. The verdict is the SECOND connection, which is a client
that did nothing wrong asking a question the module can only answer if it is
back in command mode.

EXIT CODES
  0   the second client was answered
  1   the second client was not answered  (the module is still swallowing)
  2   could not connect at all
  3   the FIRST client was never even framed — the run never got far enough to
      be evidence about anything
"""

import argparse
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import dzrp                                          # noqa: E402


def one_init(host, port, timeout, label):
    """Connect, CMD_INIT, close. Returns (ok, message)."""
    try:
        t = dzrp.TcpTransport(host, port, timeout)
    except Exception as e:                          # noqa: BLE001
        return None, "%s could not connect to %s:%d — %s" % (label, host, port, e)
    # No 0xA5 preamble: this is the WiFi build (transport_esp.asm, point 1).
    d = dzrp.Dzrp(t, start_byte=None)
    t0 = time.time()
    try:
        d.command(dzrp.CMD_INIT, dzrp.init_payload())
    except Exception as e:                          # noqa: BLE001
        t.close()
        return False, "%s CMD_INIT unanswered after %.1fs — %s: %s" % (
            label, time.time() - t0, type(e).__name__, e)
    t.close()
    return True, "%s CMD_INIT answered in %.2fs" % (label, time.time() - t0)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=11000)
    ap.add_argument("--timeout", type=float, default=15.0)
    ap.add_argument("--gap", type=float, default=2.0,
                    help="seconds between the two connections, so the stub has "
                         "finished its drain and repainted before the second one")
    args = ap.parse_args()

    ok1, msg1 = one_init(args.host, args.port, args.timeout, "client 1")
    print(msg1)
    if ok1 is None:
        return 2

    time.sleep(args.gap)

    ok2, msg2 = one_init(args.host, args.port, args.timeout, "client 2")
    print(msg2)
    if ok2 is None:
        # The listener went away entirely. That is not "the module is
        # swallowing" and must not be reported as it.
        return 2
    return 0 if ok2 else 1


if __name__ == "__main__":
    sys.exit(main())
