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

THEN A THIRD CLIENT, AND THAT HALF IS NOT A DUPLICATE OF THE FIRST. The first
version of the fix freed the hold buffer only when a later chunk arrived off the
WIRE, so between finishing a held command and that happening, every capture was
refused and the frame destroyed — the first collision handled, the next one lost,
silently. Reaching that state needs a frame to arrive while the stub is flushing
the reply to a command it took OUT OF the hold, which is what connection 3 is
for: it is connected in advance and sends the moment the first reply lands, so
its frame arrives while the stub is still flushing the other command's reply out
of the hold. That reply is made ~1 KB, i.e. five AT+CIPSEND chunks, so the
window is tens of milliseconds rather than one.

Found by review, reproduced 11 times out of 11. Two colliding rounds do NOT
reach it — measured: the round-2 frames come off the wire through the idle poll,
which frees the buffer on its way past. That is why this fixture is shaped the
way it is rather than simply repeating the collision.

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
LATE_PAYLOAD = bytes([0x33]) * 24

# Connection 2's command — a 1 KB memory read, so a five-byte command gets a
# ~1 KB answer. That answer is the one the stub sends out of the hold,
# and at ESP_TX_CHUNK = 240 bytes it is five AT+CIPSENDs — five prompt waits,
# tens of milliseconds — which is the window the latecomer has to land in.
#
# TWO SIZES, EACH FOR ITS OWN REASON, and getting them the same way round costs
# the check its teeth. A big LOOPBACK would not do: loopback echoes, so the
# COMMAND would be a kilobyte too, and a frame larger than ESP_HOLD_MAX is
# dropped by design — the check then fails against a correct stub. And with both
# small the window is about a millisecond and the check passes against a stub
# known to have the bug. Both were measured, in that order.
BIG_READ_ADDR = 0x8000
BIG_READ_LEN = 1024


def connect():
    d = dzrp.Dzrp(dzrp.open_remote("tcp:%s:%d" % (HOST, PORT), timeout=TIMEOUT),
                  start_byte=None, base_timeout=TIMEOUT)
    d.command(dzrp.CMD_INIT, dzrp.init_payload())
    return d


def main():
    try:
        conns = [connect(), connect()]
        # Opened and initialised BEFORE the collision, not inside it: a TCP
        # handshake costs more than the window is wide, and the latecomer would
        # arrive after the stub had gone idle again.
        latecomer_conn = connect()
    except Exception as e:
        print("could not open and initialise three connections (%s: %s) — "
              "nothing was tested" % (type(e).__name__, e))
        return 1

    results = {}
    late = {}
    # A barrier, so neither command is written until both threads are ready to
    # write: the collision is the subject, and a client that gets there first by
    # a scheduling accident tests nothing.
    ready = threading.Barrier(len(conns))
    # Fired when the FIRST of the two replies lands. At that moment the stub is
    # about to answer the other one out of the hold, which is the window the
    # latecomer has to arrive in.
    first_reply = threading.Event()

    def exchange(i):
        try:
            ready.wait(timeout=TIMEOUT)
            if i == 0:
                got = conns[i].command(dzrp.CMD_LOOPBACK, PAYLOADS[i])
                results[i] = (None if got == PAYLOADS[i]
                              else "got %d bytes back and they are not its own "
                                   "payload" % len(got))
            else:
                # A five-byte command with a ~1 KB answer. THIS is the one the
                # stub serves out of the hold, so its answer is what keeps the
                # stub inside its send waits while the latecomer arrives.
                got = conns[i].command(
                    dzrp.CMD_READ_MEM,
                    b"\x00" + BIG_READ_ADDR.to_bytes(2, "little")
                    + BIG_READ_LEN.to_bytes(2, "little"))
                results[i] = (None if len(got) == BIG_READ_LEN
                              else "the %d-byte read came back as %d bytes"
                                   % (BIG_READ_LEN, len(got)))
        except Exception as e:
            results[i] = "%s: %s" % (type(e).__name__, e)
        finally:
            first_reply.set()

    def latecomer():
        if not first_reply.wait(timeout=TIMEOUT):
            late["err"] = "no reply ever arrived, so this half never started"
            return
        try:
            got = latecomer_conn.command(dzrp.CMD_LOOPBACK, LATE_PAYLOAD)
            late["err"] = (None if got == LATE_PAYLOAD
                           else "got %d bytes back, not its own payload" % len(got))
        except Exception as e:
            late["err"] = "%s: %s" % (type(e).__name__, e)

    threads = [threading.Thread(target=exchange, args=(i,))
               for i in range(len(conns))]
    threads.append(threading.Thread(target=latecomer))
    for t in threads:
        t.start()
    for t in threads:
        t.join(TIMEOUT + 5)

    failed = False
    lost = [i for i in range(len(conns)) if results.get(i) is not None]
    for i in lost:
        print("connection %d: %s" % (i + 1, results.get(i, "no result at all")))
    if len(lost) == 1:
        print("exactly one of the two was answered, which is the signature of a "
              "frame a scan discarded — issue #11")
    if lost:
        failed = True

    if late.get("err") is not None:
        print("the client that arrived while the stub was answering a HELD "
              "command was lost: %s" % late["err"])
        print("that is the hold buffer not being freed when the frame it held "
              "was served — issue #11, second instance, which one collision on "
              "its own cannot reach")
        failed = True

    for d in conns + [latecomer_conn]:
        try:
            d.close()
        except Exception:
            pass

    if failed:
        return 1
    print("both queued commands were answered, and a client arriving during a "
          "held command's reply was answered too")
    return 0


if __name__ == "__main__":
    sys.exit(main())
