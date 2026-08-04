#!/usr/bin/env python3
"""Make the stub send an UNPROMPTED notification to a client that has gone.

Bench check W2 (test/run-dzrp-stub.sh). Not part of the conformance suite: it
asserts on the remote's *state* afterwards rather than on a protocol exchange,
and it deliberately leaves the machine crashed, so it needs its own run.

WHY IT EXISTS. The WiFi transport addresses every reply to the connection the
last `+IPD` came from. Nothing resets that id when the peer disappears, so a
notification the stub sends on its own initiative — from the M1 button, or from
a stray RST 0 through breakpoints.asm — is aimed at a dead connection.
`AT+CIPSEND` on a closed cid is answered ERROR; a transport that waits only for
the `>` prompt turns that into a TX timeout, which resets the call stack,
discards the notification and reports a fault on a machine with nothing wrong
with it. Measured before the fix: "Last Error: TX Timeout" on the stub's screen.

HOW THE UNPROMPTED NOTIFICATION IS PROVOKED, and it is worth stating plainly
because it is a crash. Nothing has been loaded, so the saved debuggee registers
are all zero; CMD_CONTINUE therefore resumes at PC=0 with SP=0 and the machine
runs into the first RST 0 byte it meets — measured at 0x6417, break reason 2.
That is exactly the "leftover breakpoint fires with nobody attached" path, and
it needs no button press and no timing luck. The socket is closed in the same
breath as the command, so the module has already emitted `<id>,CLOSED` by the
time the stub tries to send.

The precondition is asserted by the bench from jnext's own log, not by this
script, so a run where the crash did NOT happen fails loudly instead of passing
without having tested anything.
"""
import socket
import struct
import sys
import time

PORT = 11000
CMD_INIT = 1
CMD_GET_REGISTERS = 3
CMD_CONTINUE = 6

# bp1_enable, bp1_addr, bp2_enable, bp2_addr, alternate_command,
# range_start, range_end — all zero: no temporary breakpoints, just run.
CONTINUE_PAYLOAD = bytes(11)

_seq = 0


def build(cmd, payload=b""):
    global _seq
    _seq = _seq % 255 + 1
    return struct.pack("<IBB", len(payload), _seq, cmd) + payload, _seq


def read_frame(sock):
    hdr = b""
    while len(hdr) < 4:
        chunk = sock.recv(4 - len(hdr))
        if not chunk:
            raise RuntimeError("remote closed the connection")
        hdr += chunk
    n = struct.unpack("<I", hdr)[0]
    body = b""
    while len(body) < n:
        chunk = sock.recv(n - len(body))
        if not chunk:
            raise RuntimeError("remote closed the connection")
        body += chunk
    return body[0], body[1:]


def command(sock, cmd, payload=b""):
    frame, seq = build(cmd, payload)
    sock.sendall(frame)
    while True:
        got, body = read_frame(sock)
        if got == 0:
            continue          # a notification; not what this call asked for
        if got != seq:
            raise RuntimeError("sequence mismatch: sent %d, got %d" % (seq, got))
        return body


def main():
    init = bytes((2, 1, 0)) + b"orphan-notify\x00"

    sock = socket.create_connection(("127.0.0.1", PORT), timeout=10)
    sock.settimeout(10)
    command(sock, CMD_INIT, init)

    # Command and FIN together, so the module frames the `+IPD` and then the
    # `<id>,CLOSED` before the stub can possibly have finished with it.
    frame, _ = build(CMD_CONTINUE, CONTINUE_PAYLOAD)
    sock.sendall(frame)
    sock.close()
    print("   sent CMD_CONTINUE and closed the socket in the same breath")

    time.sleep(2)

    # CMD_GET_REGISTERS on purpose, and not CMD_INIT: cmd_init clears
    # last_error and repaints the UI, which would erase the very thing the
    # bench's screenshot is about to look for.
    try:
        sock2 = socket.create_connection(("127.0.0.1", PORT), timeout=10)
        sock2.settimeout(10)
        body = command(sock2, CMD_GET_REGISTERS)
        sock2.close()
    except (OSError, RuntimeError) as e:
        print("   FAILED: the stub did not serve a new client afterwards: %s" % e)
        return 1

    if len(body) < 28:
        print("   FAILED: register block is only %d bytes" % len(body))
        return 1
    print("   the stub served a new client afterwards (%d-byte register block)" % len(body))
    return 0


if __name__ == "__main__":
    sys.exit(main())
