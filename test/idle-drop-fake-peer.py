#!/usr/bin/env python3
"""A fake DZRP peer that reaps an idle connection on a timer, or never does.

    test/idle-drop-fake-peer.py --port 11987 --drop-after 20     # reaps
    test/idle-drop-fake-peer.py --port 11987                     # never reaps

WHAT THIS IS FOR, AND IT IS NARROW. `test/idle-drop-probe.py` has one number and
several ways of describing it, and the descriptions are the part that was wrong
in its draft: a survival was reported as "there is no timeout" when it means "the
timeout is longer than I waited", and a drop was attributed to a value the probe
had hardcoded. Those branches take minutes each to reach against a real Next and
cannot be reached at all against jnext, whose `AT+CIPSTO` support is unknown. So
they are exercised here instead, in seconds, one argument apart.

IT IS NOT A STUB, NOT AN EMULATOR, AND PROVES NOTHING ABOUT EITHER. It answers
exactly the three things the probe sends — a `CMD_INIT`, and the two
`CMD_READ_MEM`s the screen reader makes — from a synthetic screen it draws
itself. A green run here says the probe's wording is right about a peer that
behaved in a known way. It says nothing about a real ESP-01, nothing about the
Z80, and nothing about `AT+CIPSTO`.

THE TIMER IS AN IDLE TIMER, which is what makes it the right shape: it counts
from the last byte RECEIVED, so a client that keeps talking is never reaped and
one that goes quiet is. That is `AT+CIPSTO`'s documented behaviour and it is the
only property of the module this file imitates.

THE SCREEN IS SYNTHETIC AND THE FONT IS SERVED WITH IT. `screen.py` decodes a
character cell by looking its eight bitmap bytes up in a font it reads from the
same remote, so any self-consistent font round-trips: this one gives each
character a unique pattern and gives space eight zero bytes, so a blank error
area really counts zero bright-red pixels. Row 12 carries `R = Reset`, because
the reader validates itself against that row before any verdict is taken from it.

Ctrl-C to stop it. It serves connections one at a time, which is all the probe
ever opens.
"""

import argparse
import select
import socket
import struct
import sys
import time

CMD_INIT = 1
CMD_READ_MEM = 8

FONT_ADDR, FONT_LEN = 0x3D00, 768
SCREEN_ADDR, DISPLAY_LEN, ATTR_LEN = 0x4000, 6144, 768

COLS, ROWS = 32, 24
ERROR_FIRST_ROW = 15
ATTR_BODY = 0x07                        # white ink, black paper
ATTR_ERROR = 0x02 | 0x40                # bright red ink, black paper


def font_bytes():
    """96 glyphs of eight bytes, unique per character, and blank for space."""
    out = bytearray()
    for code in range(32, 128):
        if code == 32:
            out += b"\x00" * 8
        else:
            out += bytes((code, code ^ 0x7E, code, code ^ 0x3C,
                          code, code ^ 0x18, code, code ^ 0x81))
    assert len(out) == FONT_LEN
    return bytes(out)


def make_screen(rows):
    """A display file plus attributes, drawn from {row: text} with that font."""
    font = font_bytes()
    display = bytearray(DISPLAY_LEN)
    for row, text in rows.items():
        for col, ch in enumerate(text[:COLS]):
            code = ord(ch)
            if not 32 <= code < 128:
                code = 32
            glyph = font[(code - 32) * 8:(code - 32) * 8 + 8]
            # The display file's thirds-then-rows-then-scanlines order, the same
            # arithmetic screen.py reverses.
            base = (row // 8) * 2048 + (row % 8) * 32 + col
            for line in range(8):
                display[base + line * 256] = glyph[line]
    attrs = bytearray(ATTR_BODY for _ in range(ATTR_LEN))
    for row in range(ERROR_FIRST_ROW, ROWS):
        for col in range(COLS):
            attrs[row * COLS + col] = ATTR_ERROR
    return bytes(display) + bytes(attrs)


class Memory:
    """The two regions the screen reader asks for, and zeros everywhere else."""

    def __init__(self, screen):
        self.regions = [(FONT_ADDR, font_bytes()), (SCREEN_ADDR, screen)]

    def read(self, addr, size):
        out = bytearray(size)
        for base, data in self.regions:
            for i in range(size):
                off = addr + i - base
                if 0 <= off < len(data):
                    out[i] = data[off]
        return bytes(out)


def read_exactly(sock, n):
    out = b""
    while len(out) < n:
        chunk = sock.recv(n - len(out))
        if not chunk:
            return None
        out += chunk
    return out


def respond(sock, seq, body):
    # <length:4><seq:1><body>, and the length counts FROM the sequence byte —
    # the asymmetry with a command frame that cost this project a silent hang
    # (MEMORY.md, "DZRP's two length conventions").
    sock.sendall(struct.pack("<I", 1 + len(body)) + bytes([seq]) + body)


def serve(sock, mem, drop_after, log):
    """One connection, until the peer goes or the idle timer reaps it."""
    last_rx = time.monotonic()
    while True:
        if drop_after:
            left = drop_after - (time.monotonic() - last_rx)
            if left <= 0:
                log("idle %.1f s: closing it, as a module with a timeout would"
                    % drop_after)
                sock.close()
                return
        else:
            left = 1.0
        if not select.select([sock], [], [], min(left, 1.0))[0]:
            continue

        header = read_exactly(sock, 6)
        if header is None:
            log("the client went away")
            sock.close()
            return
        last_rx = time.monotonic()
        length, seq, cmd = struct.unpack("<IBB", header)
        payload = read_exactly(sock, length) if length else b""
        if payload is None:
            log("the client went away mid-command")
            sock.close()
            return

        if cmd == CMD_INIT:
            log("CMD_INIT")
            respond(sock, seq, bytes([0, 2, 1, 0, 4]) + b"fake-idle-peer\x00")
        elif cmd == CMD_READ_MEM:
            addr, size = struct.unpack("<HH", payload[1:5])
            log("CMD_READ_MEM %#06x,%d" % (addr, size))
            respond(sock, seq, mem.read(addr, size))
        else:
            # Nothing else is expected. Answering with an empty body keeps the
            # stream in step rather than inventing an error the probe cannot
            # read, which is what a silent handler would be.
            log("command %d — answering empty" % cmd)
            respond(sock, seq, b"")


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", type=int, default=11987,
                    help="deliberately NOT 11000: the benches bind that one")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--drop-after", type=float, default=0.0, metavar="SECONDS",
                    help="close a connection after this long with nothing "
                         "received on it. 0 (the default) never closes one")
    ap.add_argument("--session-line", default="Session lost - client gone",
                    help="what row 8 says, so the probe's R4 has something to read")
    ap.add_argument("--identity", default="dezogif_ng WiFi 00.13",
                    help="what row 0 says, for R5")
    args = ap.parse_args()

    screen = make_screen({
        0: args.identity,
        8: args.session_line,
        12: "R = Reset",                # the reader validates itself on this
    })
    mem = Memory(screen)

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        srv.bind((args.host, args.port))
    except OSError as e:
        # SAID IN ONE LINE, BECAUSE OF WHAT AN UNREAD TRACEBACK COSTS. This was
        # written after a run of this file died exactly here, into a log nobody
        # looked at, while an EARLIER copy with a different --drop-after went on
        # answering on the port. The probe then measured that copy's delay and
        # reported it as matching an expectation it had nothing to do with — a
        # contaminated run that came out looking right, which is the failure this
        # repository names most often.
        print("cannot listen on %s:%d — %s.\nSomething else is already there; "
              "check with: ss -ltnp | grep %d"
              % (args.host, args.port, e, args.port), file=sys.stderr)
        return 2
    srv.listen(4)
    print("fake idle peer on %s:%d — %s" % (
        args.host, args.port,
        "reaping an idle connection after %.1f s" % args.drop_after
        if args.drop_after else "never reaping"), flush=True)

    n = 0
    while True:
        conn, peer = srv.accept()
        n += 1
        tag = "[conn %d] " % n
        print("%saccepted from %s:%d" % (tag, peer[0], peer[1]), flush=True)
        try:
            serve(conn, mem, args.drop_after,
                  lambda m, tag=tag: print(tag + m, flush=True))
        except (OSError, struct.error) as e:
            print("%s%s: %s" % (tag, type(e).__name__, e), flush=True)
            conn.close()


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("")
