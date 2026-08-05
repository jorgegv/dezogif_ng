#!/usr/bin/env python3
"""W4's fixture — two commands queued back to back, both must be answered.

THE DEFECT THIS EXISTS FOR (issue #11). Every scan in transport_esp.asm skips
what it is not looking for, which is what lets it step over the module's
unsolicited lines. A `+IPD` frame arriving mid-scan was skipped the same way:
read off the wire and thrown away, so the client was answered by nothing at
all.

THE SHAPE. Two clients write their command at the same instant, so the module
emits two `+IPD` frames back to back. The stub reads the first, executes it,
and issues `AT+CIPSEND` — and the second frame is sitting in the RX FIFO ahead
of the module's `OK\\r\\n> `, so the wait for that prompt used to eat it whole.
Exactly one of the two commands was answered, every time.

Both connections are opened and INITed first, one at a time, so that the only
thing being tested here is the collision — not connecting, and not CMD_INIT.

IT COLLIDES TWICE, AND THE SECOND ROUND IS NOT A DUPLICATE. The first version of
the fix handled one collision and then refused every capture until a command
happened to arrive off the wire again — so the SECOND collision lost its command
exactly as before, silently. A single-collision check cannot see that: the
buffer only reaches the state that fails once a frame has been served out of it.
Found by review, reproduced 11 times out of 11, and this is the regression check
for it.

WHY THE STUB'S OTHER LOSING WINDOW IS NOT TESTED HERE. The same defect lives in
the wait for `SEND OK`, and it is unreachable in jnext: the module answers
instantly, so there is no window to land in. On a real Next it is 20-50 ms wide
and is hardware bench H3. See doc/HARDWARE-TESTING.md.

Exit 0 if both replies came back intact, 1 otherwise, with the reason on
stdout.
"""
import os
import sys
import threading

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import dzrp  # noqa: E402

HOST = os.environ.get("DZRP_HOST", "127.0.0.1")
PORT = int(os.environ.get("DZRP_PORT", "11000"))
TIMEOUT = float(os.environ.get("DZRP_TIMEOUT", "15"))

PAYLOADS = (bytes([0x11]) * 24, bytes([0x22]) * 24)


def connect():
    d = dzrp.Dzrp(dzrp.open_remote("tcp:%s:%d" % (HOST, PORT), timeout=TIMEOUT),
                  start_byte=None, base_timeout=TIMEOUT)
    d.command(dzrp.CMD_INIT, dzrp.init_payload())
    return d


def main():
    try:
        conns = [connect(), connect()]
    except Exception as e:
        print("could not open and initialise two connections (%s: %s) — nothing "
              "was tested" % (type(e).__name__, e))
        return 1

    def collide(tag):
        """One round: both connections write at the same instant. Returns the
        list of connections whose command was not answered correctly."""
        results = {}
        # A barrier, so neither command is written until both threads are ready
        # to write: the collision is the subject, and a client that gets there
        # first by a scheduling accident tests nothing.
        ready = threading.Barrier(len(conns))

        def exchange(i):
            try:
                ready.wait(timeout=TIMEOUT)
                got = conns[i].command(dzrp.CMD_LOOPBACK, PAYLOADS[i])
                results[i] = (None if got == PAYLOADS[i]
                              else "got %d bytes back and they are not its own "
                                   "payload" % len(got))
            except Exception as e:
                results[i] = "%s: %s" % (type(e).__name__, e)

        threads = [threading.Thread(target=exchange, args=(i,))
                   for i in range(len(conns))]
        for t in threads:
            t.start()
        for t in threads:
            t.join(TIMEOUT + 5)

        lost = [i for i in range(len(conns)) if results.get(i) is not None]
        for i in lost:
            print("round %s, connection %d: %s"
                  % (tag, i + 1, results.get(i, "no result at all")))
        if len(lost) == 1:
            print("round %s: exactly one of the two was answered, which is the "
                  "signature of a frame a scan discarded — issue #11" % tag)
        return lost

    rounds = ["first", "second"]
    failed = False
    for tag in rounds:
        if collide(tag):
            failed = True
            break

    for d in conns:
        try:
            d.close()
        except Exception:
            pass

    if failed:
        return 1
    print("both queued commands were answered in each of %d collisions, each "
          "with its own payload" % len(rounds))
    return 0


if __name__ == "__main__":
    sys.exit(main())
