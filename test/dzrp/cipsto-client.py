#!/usr/bin/env python3
"""A DZRP client that goes silent and reports how long the module tolerates it.

The client half of test/run-cipsto.sh (issue #24). It opens one connection,
proves the stub is serving, and then says nothing at all — which is exactly what
a DeZog session parked at a breakpoint looks like from the module's side, and is
the condition `AT+CIPSTO` measures.

WHY IT SERVES FIRST AND GOES SILENT SECOND, in that order and not the other way.

  * The two commands are what make a later close attributable. A connection that
    is dropped without ever having been answered has two explanations — the
    module timed it out, or the stub never came up — and only one of them is
    this bench's subject. A CMD_INIT and a CMD_LOOPBACK that both came back rule
    the second out before the clock starts.
  * `AT+CIPSTO`'s window is re-armed by bytes travelling FROM the client, and by
    nothing else. Our own replies do not re-arm it: that is documented for
    esp-at v2.2.0.0_esp8266 ("if the server initiates a communication with the
    client, the timer will not restart"), v1.5.4 is silent on the point, and
    jnext models the reading the requirement forces. So the clock starts at our
    last WRITE, which is why t0 is taken before the loopback's reply is read
    rather than after it.

WHAT IT REPORTS RATHER THAN JUDGES. It prints one machine-readable line —

    RESULT dropped 10.42
    RESULT alive 25.00

— and leaves the verdict to the bench, because the same run is a PASS in one
check and a FAIL in another: K1 requires the drop and K2 requires the survival,
and they differ by one build-time constant rather than by anything here.

The silence is a real socket read, so a drop is observed as the peer closing —
`recv` returning empty — and not inferred from a timeout of ours.

THE --after-shot GUARD, for the one check that judges the stub's screen. The
screenshot is taken at a fixed EMULATED frame count and headless jnext runs
frames several times faster than real time, so "the picture was taken after the
exchange" is a timing assumption rather than a fact. This refuses to let it be
one: the file must be ABSENT when the exchange completes, and must have appeared
by the end. A run where it landed early exits 12 and the bench reports a harness
fault instead of reading a clean error area as evidence. Borrowed wholesale from
idle-client.py, which met the same problem first.

EXIT CODES
  0   the exchange completed and the wait ran to one conclusion or the other;
      read the RESULT line for which
  1   CMD_INIT was never answered — the run is not evidence about anything
  2   could not connect at all
  4   CMD_LOOPBACK was not answered, or came back wrong: the stub is serving
      badly, which is a finding but not this one
  12  --after-shot already existed when the exchange completed
  13  --after-shot never appeared inside --shot-timeout
"""

import argparse
import os
import socket
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import dzrp                                          # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=11000)
    ap.add_argument("--timeout", type=float, default=20.0)
    ap.add_argument("--watch", type=float, default=25.0,
                    help="how long to stay silent, waiting for the module to "
                         "hang up on us")
    ap.add_argument("--after-shot", default=None,
                    help="a screenshot the bench will judge; must not exist "
                         "yet when the exchange completes")
    ap.add_argument("--shot-timeout", type=float, default=180.0)
    args = ap.parse_args()

    try:
        t = dzrp.TcpTransport(args.host, args.port, args.timeout)
    except Exception as e:                          # noqa: BLE001
        print("could not connect to %s:%d — %s" % (args.host, args.port, e))
        return 2

    # No 0xA5 preamble: this is the WiFi build, where the byte is absent by
    # design (transport_esp.asm, point 1).
    d = dzrp.Dzrp(t, start_byte=None)

    t_init = time.time()
    try:
        d.command(dzrp.CMD_INIT, dzrp.init_payload())
    except Exception as e:                          # noqa: BLE001
        print("CMD_INIT got no usable reply after %.1fs — %s: %s"
              % (time.time() - t_init, type(e).__name__, e))
        t.close()
        return 1
    print("CMD_INIT answered in %.2fs" % (time.time() - t_init))

    # The last thing we ever send. t0 is taken here rather than after the reply
    # because the module arms its silence window when it READS our bytes; the
    # difference is milliseconds, and taking it afterwards would charge the
    # stub's own reply time to the timeout being measured.
    payload = bytes(range(8))
    t0 = time.time()
    try:
        reply = d.command(dzrp.CMD_LOOPBACK, payload)
    except Exception as e:                          # noqa: BLE001
        print("CMD_LOOPBACK unanswered — %s: %s" % (type(e).__name__, e))
        t.close()
        return 4
    if reply != payload:
        print("CMD_LOOPBACK came back wrong: %r against %r" % (reply, payload))
        t.close()
        return 4
    if args.after_shot and os.path.exists(args.after_shot):
        print("%s already existed when the exchange completed: the picture is "
              "of an earlier screen" % args.after_shot)
        t.close()
        return 12
    print("CMD_LOOPBACK answered; going silent for up to %.0fs" % args.watch)

    # Now say nothing. A drop is the PEER closing — recv returning empty — and
    # not a timeout of ours, so the short socket timeout below is only how often
    # the loop wakes up to check the wall clock.
    t.sock.settimeout(1.0)
    verdict, elapsed = "alive", 0.0
    while True:
        elapsed = time.time() - t0
        if elapsed >= args.watch:
            break
        try:
            if t.sock.recv(64) == b"":
                verdict, elapsed = "dropped", time.time() - t0
                break
        except socket.timeout:
            continue
        except OSError as e:                        # noqa: BLE001
            # A reset rather than a clean close still means the connection is
            # gone, which is the thing being measured.
            print("socket error after %.2fs — %s" % (time.time() - t0, e))
            verdict, elapsed = "dropped", time.time() - t0
            break
        # Anything the stub sends unprompted is not a drop and is not expected
        # here; report it so a surprise cannot be read as silence.
        print("unexpected bytes from the stub at %.2fs" % (time.time() - t0))

    print("RESULT %s %.2f" % (verdict, elapsed))

    if args.after_shot:
        deadline = time.time() + args.shot_timeout
        while not os.path.exists(args.after_shot) and time.time() < deadline:
            time.sleep(0.25)
        if not os.path.exists(args.after_shot):
            print("%s never appeared" % args.after_shot)
            t.close()
            return 13

    t.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
