#!/usr/bin/env python3
"""A DZRP client for the idle-sweep checks — issues #24 and #40.

The client half of S4-S9 in test/run-slot-recovery.sh. Every check here turns
on whether the stub swept while nobody was talking to it, and the modes differ
only in who was connected and whether they had said anything.

  --mode fresh   connect, prove the stub is serving, leave. The bench has
                 already waited out several idle periods before starting this,
                 so what it establishes is that a stub which has just swept its
                 own link ids can still serve — S4's second half, and the
                 reason the sweep is not allowed to retire the listener.

  --mode hold    connect, prove the stub is serving, then say NOTHING for
                 --watch seconds while holding the socket open. That is a DeZog
                 session parked at a breakpoint, and the stub must not sweep
                 underneath it (S6). It then disconnects, so that the same run
                 can go on and show the sweep firing once the session is gone —
                 which is S6's own in-run control and is why the mode does not
                 simply exit while connected.

  --mode arm     connect, send ONE CMD_LOOPBACK, leave. Issue #40's staging
                 needs a known origin for the idle timer, and an inbound frame
                 is what sets one: esp_sync_ipd resets the tick counter and
                 re-arms the sweep. It is a bare CMD_LOOPBACK and NOT CMD_INIT
                 on purpose — CMD_INIT would open a DZRP session, which stops
                 the clock entirely (S6's subject) and would leave the origin
                 depending on the module reporting the close afterwards.

  --mode silent  connect and say NOTHING AT ALL for --watch seconds, then send
                 one CMD_LOOPBACK and report whether it was answered. This is
                 issue #40: a socket the module has accepted but which has not
                 yet introduced itself. It writes its --sentinel the moment the
                 socket is open — before any traffic, unlike --mode hold, whose
                 sentinel marks an open SESSION — so the bench can read the
                 sweep count at the instant of the connect and know where in
                 the idle period this client landed.

WHY THE HOLD MUST BE OBSERVED AND NOT SLEPT THROUGH. If the module hangs up on
us mid-hold — its own AT+CIPSTO timeout, which this ROM sets to 1800 s and which
therefore should not fire — the session ends early and every later "no sweep
happened" reading would be about a state nobody staged. So the wait is a real
socket read and a drop is the PEER closing, reported as a distinct exit code
rather than folded into success.

WHAT IT DOES NOT DO IS JUDGE. It prints one machine-readable line —

    RESULT served
    RESULT held 30.00
    RESULT armed
    RESULT silent 1.10

— and the bench decides, because the counting that matters happens in jnext's
own log rather than over this socket: no PC-side client can see an AT+CIPCLOSE.

EXIT CODES
  0   the mode ran to its own conclusion; read the RESULT line
  1   CMD_INIT was never answered — the run is not evidence about anything
  2   could not connect at all
  3   the connection was dropped while it was meant to be held: --mode hold
      lost the session it claims to have held, and --mode silent was closed
      before it ever spoke, which is issue #40's whole subject
  4   the follow-up command was unanswered or came back wrong

THE --sentinel FILE IS WHAT MAKES S6 MEAN ANYTHING, and it was added because the
first version of that check was wrong in the direction that FAILS RATHER THAN
PASSES — which is the only reason it was caught. The bench counted every
AT+CIPCLOSE in the run and charged them all to the hold; but the stub is idle
from the moment it comes up, and headless jnext runs several emulated seconds per
wall second, so with a ten-second probe period it had already swept once before
this client connected at all. Measured: the sweep at 18:31:38.96 and this
client's first frame at 18:31:39.54.

So the count has to start when the SESSION does, and only the client knows when
that is. It writes this file once the exchange is answered and before it goes
silent; the bench waits for it, takes its baseline, and judges the delta.
"""

import argparse
import os
import socket
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import dzrp                                          # noqa: E402


def serving(d):
    """CMD_INIT then a small CMD_LOOPBACK. Raises on anything unexpected.

    Two commands rather than one, for cipsto-client.py's reason: a connection
    that was accepted but never answered has more than one explanation, and only
    an answered exchange rules out "the stub never came up" before the check
    starts counting.
    """
    d.command(dzrp.CMD_INIT, dzrp.init_payload())
    payload = bytes(range(8))
    reply = d.command(dzrp.CMD_LOOPBACK, payload)
    if reply != payload:
        raise ValueError("CMD_LOOPBACK came back %r, expected %r"
                         % (reply, payload))


def stay_silent(t, seconds):
    """Hold the socket open, saying nothing, for `seconds`.

    Returns None if the silence ran its course, or a string saying how it
    ended. Shared by --mode hold and --mode silent so that "the peer closed"
    is decided in ONE place: a recv of b"" is the module or the stub hanging
    up, and telling that apart from our own timeout is the whole point of
    reading rather than sleeping.
    """
    t.sock.settimeout(1.0)
    started = time.time()
    while True:
        elapsed = time.time() - started
        if elapsed >= seconds:
            return None
        try:
            if t.sock.recv(64) == b"":
                return "the peer closed the connection after %.2fs" % elapsed
        except socket.timeout:
            continue
        except OSError as e:                        # noqa: BLE001
            return "socket error after %.2fs — %s" % (elapsed, e)
        # Nothing should arrive unprompted here. Report it rather than let a
        # surprise be read as silence.
        print("unexpected bytes from the stub at %.2fs" % elapsed)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=11000)
    ap.add_argument("--timeout", type=float, default=20.0)
    ap.add_argument("--mode", choices=("fresh", "hold", "arm", "silent"),
                    required=True)
    ap.add_argument("--watch", type=float, default=30.0,
                    help="--mode hold / --mode silent: how long to say nothing")
    ap.add_argument("--sentinel", default=None,
                    help="a file to write at the moment the silence starts, so "
                         "the bench can take its baseline then and not before. "
                         "--mode hold writes it once the SESSION is open; "
                         "--mode silent once the SOCKET is, having sent nothing")
    args = ap.parse_args()

    try:
        t = dzrp.TcpTransport(args.host, args.port, args.timeout)
    except Exception as e:                          # noqa: BLE001
        print("could not connect to %s:%d — %s" % (args.host, args.port, e))
        return 2

    # No 0xA5 preamble: this is the WiFi build, where the byte is absent by
    # design (transport_esp.asm, point 1).
    d = dzrp.Dzrp(t, start_byte=None)
    payload = bytes(range(8))

    def loopback():
        """One CMD_LOOPBACK. Returns None if it echoed, else why it did not."""
        try:
            reply = d.command(dzrp.CMD_LOOPBACK, payload)
        except Exception as e:                      # noqa: BLE001
            return "%s: %s" % (type(e).__name__, e)
        if reply != payload:
            return "came back %r, expected %r" % (reply, payload)
        return None

    # --- arm ----------------------------------------------------------------
    # ONE inbound frame and nothing else, which is what gives the checks below
    # a known origin for the idle timer: esp_sync_ipd resets the tick counter
    # and re-arms the sweep on every frame it parses. NOT CMD_INIT — that would
    # open a session and stop the clock; see the module docstring.
    if args.mode == "arm":
        why = loopback()
        if why is not None:
            print("the arming CMD_LOOPBACK failed — %s" % why)
            t.close()
            return 4
        print("RESULT armed")
        t.close()
        return 0

    # --- silent -------------------------------------------------------------
    # Issue #40. NOTHING is sent before the silence, so from the stub's side
    # this is a socket the module has accepted and which has never introduced
    # itself. The sentinel goes out here, before any traffic at all, because
    # what the bench needs to know is WHERE IN THE IDLE PERIOD the connect
    # landed — not when a session opened, which is --mode hold's question.
    if args.mode == "silent":
        if args.sentinel:
            with open(args.sentinel, "w") as fh:
                fh.write("socket open\n")
                fh.flush()
                os.fsync(fh.fileno())
        print("socket open, nothing sent; silent for %.2fs" % args.watch)
        started = time.time()
        why = stay_silent(t, args.watch)
        if why is not None:
            print("%s, before it had said anything at all" % why)
            t.close()
            return 3
        # It survived. Only an answered command says the stub will still serve
        # it — a socket that is merely unclosed proves nothing.
        why = loopback()
        if why is not None:
            print("the silent client's first command failed — %s" % why)
            t.close()
            return 4
        print("RESULT silent %.2f" % (time.time() - started))
        t.close()
        return 0

    t0 = time.time()
    try:
        d.command(dzrp.CMD_INIT, dzrp.init_payload())
    except Exception as e:                          # noqa: BLE001
        print("CMD_INIT got no usable reply after %.1fs — %s: %s"
              % (time.time() - t0, type(e).__name__, e))
        t.close()
        return 1
    print("CMD_INIT answered in %.2fs" % (time.time() - t0))

    why = loopback()
    if why is not None:
        print("CMD_LOOPBACK failed — %s" % why)
        t.close()
        return 4

    if args.mode == "fresh":
        print("RESULT served")
        t.close()
        return 0

    # --- hold ---------------------------------------------------------------
    # The session is open and answering. Say so BEFORE going silent: everything
    # the bench charges to the hold is counted from here.
    if args.sentinel:
        with open(args.sentinel, "w") as fh:
            fh.write("session open\n")
            fh.flush()
            os.fsync(fh.fileno())

    print("session open; holding it silent for %.0fs" % args.watch)
    held = time.time()
    why = stay_silent(t, args.watch)
    if why is not None:
        print("%s — the session was not held" % why)
        t.close()
        return 3

    # Still alive after the silence? A command answered here is what says the
    # session really was open for the whole hold rather than merely unclosed.
    why = loopback()
    if why is not None:
        print("the held session stopped answering — %s" % why)
        t.close()
        return 4

    print("RESULT held %.2f" % (time.time() - held))
    # The close is part of the check, not tidying up: the bench waits for a
    # sweep AFTER this, which is what shows the timer was live all along and
    # that only the open session was holding it off.
    t.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
