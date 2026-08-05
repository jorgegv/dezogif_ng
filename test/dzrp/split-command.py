#!/usr/bin/env python3
"""W5's fixture — a command split across `+IPD` frames while a second client speaks.

THE DEFECT THIS EXISTS FOR (issue #13). Three handlers send their response
header and THEN read payload bytes: `cmd_get_tbblue_reg`, `cmd_set_breakpoints`
and `cmd_restore_mem`. If the command's payload does not all arrive in one
`+IPD` frame, those reads run through `esp_require_payload`, which takes the
NEXT frame off the wire — from whichever connection it belongs to — and writes
`esp_conn_id` on the way past. Two things then go wrong at once:

  1. **the reply is addressed to the wrong socket**, because the buffered
     response is flushed with an `AT+CIPSEND=<id>` carrying the id of whoever
     spoke last; and
  2. **the command's remaining payload is read out of the other client's
     frame** — for `cmd_set_breakpoints` that is breakpoint addresses assembled
     from two clients' bytes and then written into the debuggee as `RST 0`.

THE SHAPE. Connection A writes the six header bytes of a `CMD_GET_TBBLUE_REG`
and stops; connection B writes a whole `CMD_LOOPBACK`; then A writes its one
remaining payload byte, the register number. The module frames those as three
`+IPD`s in that order, so the stub meets B's frame exactly where A's payload
should have been.

`CMD_GET_TBBLUE_REG` is the reproducer because it makes both failure modes
observable in one byte. Its payload is a register NUMBER and its response is
that register's VALUE, so a spliced payload does not merely corrupt something
out of sight — it comes back on the wire as the wrong register's value. The
byte B's frame would supply is B's own length LSB, which is chosen here (see
WRONG_REG) and read cleanly beforehand, so the two possible answers are known
in advance and are asserted to differ. Without that the check would be
comparing a value against itself.

WHAT EACH ASSERTION IS FOR, since one fix does not cover both:

  * "A's reply reached A"  — failure mode 1. A latch of the connection at the
    first byte of a response is enough for this on its own.
  * "A's reply carries register RIGHT_REG's value" — failure mode 2. A latch
    does nothing for this: the payload really was read from B's frame, and the
    correctly-addressed reply then carries the wrong register's value.
  * "B's own command is still answered, in full and in sync" — the other half
    of mode 2. B's frame must not be half-consumed as somebody else's payload.

Exit 0 if all of that holds, 1 otherwise, with the reason on stdout.
"""
import os
import socket
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import dzrp  # noqa: E402

HOST = os.environ.get("DZRP_HOST", "127.0.0.1")
PORT = int(os.environ.get("DZRP_PORT", "11000"))
TIMEOUT = float(os.environ.get("DZRP_TIMEOUT", "15"))

# Seconds between the three writes, and it is bounded on BOTH sides — measured
# against a headless jnext on 2026-08-05, not chosen:
#
#   below ~2 ms   the module frames A's header and A's payload as ONE `+IPD`
#                 (it cuts one chunk per quiet moment, taking whatever has
#                 accumulated), so there is no split left to test;
#   above ~20 ms  the stub's own RX budget expires while it waits for the
#                 continuation — ESP_RX_WAIT is ~100 ms of EMULATED time and
#                 this emulator runs several times faster than real time — and
#                 the command is abandoned with an RX timeout instead.
#
# 8 ms sits between them with margin either way. Both edges were measured: a
# 2 ms gap produced `+IPD,1,7`, and gaps of 5/10/20 ms were answered while
# 40/80/160 ms were not. The bench asserts the resulting frame shape from the
# module's log, so drifting out of this window FAILS rather than passing
# vacuously.
GAP = float(os.environ.get("DZRP_SPLIT_GAP", "0.008"))

# The register A asks for, and the register a spliced payload would ask for
# instead. WRONG_REG is not a free choice: it is the low byte of B's frame
# length, i.e. the first byte of B's command, which is the byte the stub would
# read as A's payload. B's payload is sized to make it so.
RIGHT_REG = 0x00        # machine ID
WRONG_REG = 0x09        # peripheral 4 setting
B_PAYLOAD = bytes([0x5A]) * WRONG_REG


def connect():
    t = dzrp.open_remote("tcp:%s:%d" % (HOST, PORT), timeout=TIMEOUT)
    # Each write must reach the module as its own segment; Nagle would be free
    # to merge A's header with A's payload byte and dissolve the whole subject
    # of this check.
    try:
        t.sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    except OSError:
        pass
    d = dzrp.Dzrp(t, start_byte=None, base_timeout=TIMEOUT)
    d.command(dzrp.CMD_INIT, dzrp.init_payload())
    return d


def read_reg(d, reg):
    body = d.command(dzrp.CMD_GET_TBBLUE_REG, bytes([reg]))
    if len(body) != 1:
        raise dzrp.DzrpError(
            "CMD_GET_TBBLUE_REG answered %d payload bytes, expected 1" % len(body))
    return body[0]


def main():
    import time

    try:
        # B FIRST, AND THAT IS NOT COSMETIC. jnext cuts one `+IPD` per quiet
        # moment and scans its connections in cid order (esp_at.cpp,
        # frame_ipd), so whichever connected first wins a tie. Opening B first
        # therefore makes B's frame come out ahead of A's payload byte even if
        # the two land in the same window, which is the order this check needs.
        # The GAP below aligns arrival order the same way, so the two mechanisms
        # agree instead of racing; the bench asserts the resulting frame order
        # from the module's log rather than trusting either.
        b = connect()
        a = connect()
    except Exception as e:
        print("could not open and initialise two connections (%s: %s) — "
              "nothing was tested" % (type(e).__name__, e))
        return 1

    # --- what the two possible answers are, measured rather than assumed -----
    try:
        right = read_reg(a, RIGHT_REG)
        wrong = read_reg(a, WRONG_REG)
    except Exception as e:
        print("PRECONDITION: could not read NextREG 0x%02X and 0x%02X cleanly "
              "(%s: %s) — nothing was tested"
              % (RIGHT_REG, WRONG_REG, type(e).__name__, e))
        return 1
    if right == wrong:
        print("PRECONDITION: NextREG 0x%02X and 0x%02X both read 0x%02X, so a "
              "spliced payload would be indistinguishable from a correct one. "
              "Pick a different RIGHT_REG/WRONG_REG pair."
              % (RIGHT_REG, WRONG_REG, right))
        return 1
    print("NextREG 0x%02X = 0x%02X (what A asks for), 0x%02X = 0x%02X (what B's "
          "frame would supply instead)" % (RIGHT_REG, right, WRONG_REG, wrong))

    # --- the split ----------------------------------------------------------
    a_frame, a_seq = a.build_command(dzrp.CMD_GET_TBBLUE_REG, bytes([RIGHT_REG]))
    b_frame, b_seq = b.build_command(dzrp.CMD_LOOPBACK, B_PAYLOAD)
    assert b_frame[0] == WRONG_REG, (
        "B's frame starts 0x%02X, not 0x%02X — B_PAYLOAD is the wrong size, so "
        "a spliced payload would not ask for WRONG_REG" % (b_frame[0], WRONG_REG))

    a.send_raw(a_frame[:6])         # length, sequence number and command ID
    time.sleep(GAP)
    b.send_raw(b_frame)             # a whole command, from somebody else
    time.sleep(GAP)
    a.send_raw(a_frame[6:])         # the register number

    failed = False

    try:
        seq, body = a._read_frame()
        if seq != a_seq:
            print("connection A was answered with sequence number %d, not its "
                  "own %d" % (seq, a_seq))
            failed = True
        elif len(body) != 1:
            print("connection A's reply carries %d payload bytes, expected 1"
                  % len(body))
            failed = True
        elif body[0] == wrong:
            print("connection A was answered with NextREG 0x%02X's value "
                  "(0x%02X) instead of 0x%02X's: its payload byte was read out "
                  "of the OTHER connection's frame — issue #13, failure mode 2"
                  % (WRONG_REG, body[0], RIGHT_REG))
            failed = True
        elif body[0] != right:
            print("connection A was answered 0x%02X, which is neither NextREG "
                  "0x%02X (0x%02X) nor 0x%02X (0x%02X)"
                  % (body[0], RIGHT_REG, right, WRONG_REG, wrong))
            failed = True
    except Exception as e:
        print("connection A, which sent the split command, was never answered "
              "(%s: %s) — its reply went somewhere else, which is issue #13, "
              "failure mode 1" % (type(e).__name__, e))
        failed = True

    try:
        seq, body = b._read_frame()
        if seq == a_seq:
            print("connection B received a reply carrying connection A's "
                  "sequence number (%d): A's response was flushed to B — "
                  "issue #13, failure mode 1" % seq)
            failed = True
        elif seq != b_seq:
            print("connection B was answered with sequence number %d, not its "
                  "own %d" % (seq, b_seq))
            failed = True
        elif body != B_PAYLOAD:
            print("connection B's loopback came back as %d bytes and they are "
                  "not its own payload" % len(body))
            failed = True
    except Exception as e:
        print("connection B's own command was never answered (%s: %s) — its "
              "frame was consumed as somebody else's payload"
              % (type(e).__name__, e))
        failed = True

    # --- and the stub is still usable afterwards -----------------------------
    #
    # Not decoration: the fix parks a frame that does not belong to the command
    # in progress, so "the stub stopped serving because something is stuck in
    # its buffer" is a failure this change could newly cause.
    try:
        c = connect()
        echo = bytes([0x77]) * 16
        got = c.command(dzrp.CMD_LOOPBACK, echo)
        if got != echo:
            print("a fresh connection afterwards got %d bytes back and they "
                  "are not its own payload" % len(got))
            failed = True
        c.close()
    except Exception as e:
        print("the stub did not serve a fresh connection after the split "
              "command (%s: %s)" % (type(e).__name__, e))
        failed = True

    for d in (a, b):
        try:
            d.close()
        except Exception:
            pass

    if failed:
        return 1
    print("the split command was answered on its own connection with its own "
          "payload, and the other client's command was answered too")
    return 0


if __name__ == "__main__":
    sys.exit(main())
