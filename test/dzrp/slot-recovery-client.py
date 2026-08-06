#!/usr/bin/env python3
"""Fill the module's inbound slots, then see whether a recovery gives one back.

The client half of test/run-slot-recovery.sh (issue #19). It opens connections
until the module stops granting them, injects one transport fault so the stub's
self-recovery runs, and then asks the only question that matters: can a NEW
client be served afterwards?

WHY EVERY HELD CONNECTION SENDS CMD_INIT. A slot can be occupied by a socket
that never speaks, and that would be enough to exhaust the module — but then a
refusal at the ceiling would have two indistinguishable causes, "the module is
full" and "the stub is wedged", which is exactly the position issue #15 was
reported from. A connection that was ANSWERED proves the stub was alive when it
took the slot, so the refusal that follows is about the module.

WHY THE FAULT IS AN OVER-DECLARED LENGTH AND NOT A KILLED SOCKET. The stub has
to be made to fail a read while the module owes it an answer — only rxtx_error
counts towards ESP_FAULT_LIMIT, and cmd_loop's idle wait deliberately does not.
A frame whose length promises more bytes than are sent does it (the shape
conformance C2 uses), and it does it WITHOUT hanging up: a client that closes
its socket hands its slot back, which is the very thing being measured. So the
trigger connection stays open and silent, still holding its slot, exactly as a
wedged peer does.

WHAT THE VERDICT IS. A fresh connection being SERVED after the recovery. The
held sockets being closed by the stub is reported as corroboration and is NOT
the verdict: it says the sweep reached our peers, where the acceptance criterion
is about the module having room again.

WHAT THIS CANNOT SEE. Which link ids the stub closed — no PC-side check can,
the ids live between the Z80 and the module. And nothing here is evidence about
a real ESP-01: jnext's ceiling is four inbound slots because slot 0 is reserved,
a real module measured five, and the sweep is written not to care.

EXIT CODES
  0   the ceiling was reached, a fault was injected, and a fresh client was
      served afterwards
  1   fewer than two connections were served, so there was nothing to exhaust
  2   could not connect at all
  3   no ceiling inside --max attempts: the module never stopped granting slots,
      so this run has no subject
  4   THE RED — after the recovery a fresh client was still not served
"""

import argparse
import os
import socket
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import dzrp                                          # noqa: E402


def open_and_greet(host, port, timeout, name):
    """One connection attempt. Returns (state, conv, why).

    state is SERVED / DROPPED / SILENT / REFUSED, the vocabulary
    test/slot-ceiling-probe.py established. A SERVED conversation is returned
    live and the caller owns it: holding it is what holds the module's slot.
    """
    try:
        transport = dzrp.TcpTransport(host, port, timeout)
    except OSError as e:
        return "REFUSED", None, str(e)

    conv = dzrp.Dzrp(transport, start_byte=None, base_timeout=timeout)
    try:
        conv.command(dzrp.CMD_INIT, dzrp.init_payload(name=name))
    except dzrp.Timeout as e:
        # Left OPEN on purpose: connected-but-unanswered is still holding a
        # slot, and closing it here would perturb the count this exists to take.
        return "SILENT", conv, str(e)
    except dzrp.DzrpError as e:
        conv.close()
        return "DROPPED", None, str(e)
    except OSError as e:
        conv.close()
        return "DROPPED", None, str(e)
    return "SERVED", conv, ""


def peer_closed(conv):
    """Has the far end closed this connection? Never blocks, never consumes."""
    sock = conv.t.sock
    try:
        sock.setblocking(False)
        data = sock.recv(1, socket.MSG_PEEK)
        return data == b""
    except (BlockingIOError, InterruptedError):
        return False
    except OSError:
        return True
    finally:
        try:
            sock.setblocking(True)
        except OSError:
            pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=11000)
    ap.add_argument("--timeout", type=float, default=10.0)
    ap.add_argument("--max", type=int, default=8,
                    help="attempts before giving up on finding a ceiling")
    ap.add_argument("--reclaim-timeout", type=float, default=30.0,
                    help="how long to keep asking for a fresh connection after "
                         "the fault, since the listener is down for part of it")
    args = ap.parse_args()

    held = []

    # ---- fill -------------------------------------------------------------
    print("filling the module's inbound slots", flush=True)
    ceiling_state = None
    for i in range(1, args.max + 1):
        state, conv, why = open_and_greet(args.host, args.port, args.timeout,
                                          "slot-recovery-%d" % i)
        print("  attempt %d: %s%s" % (i, state, (" — " + why) if why else ""),
              flush=True)
        if state == "SERVED":
            held.append(conv)
            continue
        if state == "SILENT" and conv is not None:
            # Holding a slot without being answered. Keep it — it is occupying
            # the module just as effectively — but it is not evidence the stub
            # is alive, so it does not end the walk either.
            held.append(conv)
            continue
        ceiling_state = state
        break

    if not held and ceiling_state == "REFUSED":
        print("nothing was listening at all", flush=True)
        return 2
    if len(held) < 2:
        print("only %d connection(s) were granted — nothing to exhaust"
              % len(held), flush=True)
        for c in held:
            c.close()
        return 1
    if ceiling_state is None:
        print("no ceiling inside %d attempts: the module granted every slot "
              "asked for, so this run has no subject" % args.max, flush=True)
        for c in held:
            c.close()
        return 3
    print("ceiling reached: %d connections held, the next one %s"
          % (len(held), ceiling_state), flush=True)

    # ---- inject one transport fault ---------------------------------------
    # An honest header, a length promising four bytes that never arrive. The
    # stub blocks in transport_read_byte, its RX budget expires, and rxtx_error
    # counts the fault — the only counter ESP_FAULT_LIMIT watches.
    trigger = held[-1]
    frame = trigger.build_command(dzrp.CMD_INIT, dzrp.init_payload())
    trigger.send_raw(frame[:-4])
    print("injected a truncated command on the last held connection, and left "
          "it OPEN: a socket that closes hands its slot back", flush=True)

    # ---- can a NEW client be served? --------------------------------------
    # The listener is down for part of the recovery, so a REFUSED attempt here
    # is expected rather than the answer. Ask until the budget runs out.
    print("asking for a fresh connection for up to %.0fs" % args.reclaim_timeout,
          flush=True)
    deadline = time.time() + args.reclaim_timeout
    attempts = 0
    served = None
    last = ""
    while time.time() < deadline:
        attempts += 1
        state, conv, why = open_and_greet(args.host, args.port,
                                          min(args.timeout, 5.0), "reclaim")
        last = "%s%s" % (state, (" — " + why) if why else "")
        if state == "SERVED":
            served = conv
            break
        if conv is not None:
            conv.close()
        time.sleep(1.0)

    closed = sum(1 for c in held if peer_closed(c))
    print("of the %d held connections, %d were closed by the stub "
          "(corroboration, not the verdict)" % (len(held), closed), flush=True)

    rc = 0
    if served is None:
        print("NOT served after %d attempt(s) in %.0fs — last: %s"
              % (attempts, args.reclaim_timeout, last), flush=True)
        rc = 4
    else:
        print("served on attempt %d: the module had room again" % attempts,
              flush=True)
        served.close()

    for c in held:
        c.close()
    return rc


if __name__ == "__main__":
    sys.exit(main())
