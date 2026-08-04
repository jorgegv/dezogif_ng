#!/usr/bin/env python3
"""Client half of the M0(b) ESP server bench.

Connects to the TCP server the guest fixture (test/esp_server.asm) opened
through the emulated ESP-01, and checks that what goes in comes back out.

The assertions are on BYTES OVER A SOCKET, which is what makes this bench
different from the rest of `make test`: every other check in this project
judges a screenshot, and a screenshot cannot tell a takeover from a crash.
Here a wrong answer is a wrong answer.

Exit code 0 if every check passed, 1 otherwise. One line per check on stdout,
in the same `PASS`/`FAIL` shape run-headless.sh uses.
"""

import socket
import sys
import time

HOST = "127.0.0.1"
PORT = 11000

# How long to wait for the guest to finish booting, get injected, and bring the
# ESP up. Generous: this covers a NextZXOS boot inside an emulator, and being
# impatient here would show up as a flaky bench rather than as a real failure.
LISTEN_TIMEOUT = 90.0

# Once connected, the guest owes us an answer promptly.
ECHO_TIMEOUT = 20.0

failures = 0


def check(ok, message):
    global failures
    if ok:
        print(f"  \033[32mPASS\033[0m  {message}")
    else:
        print(f"  \033[31mFAIL\033[0m  {message}")
        failures += 1
    return ok


def connect(timeout=LISTEN_TIMEOUT):
    """Wait for the guest's listener to appear, then connect to it."""
    deadline = time.time() + timeout
    last = None
    while time.time() < deadline:
        try:
            s = socket.create_connection((HOST, PORT), timeout=5)
            s.settimeout(ECHO_TIMEOUT)
            return s
        except OSError as exc:
            last = exc
            time.sleep(0.25)
    print(f"  (no listener on {HOST}:{PORT} after {timeout:.0f}s: {last})")
    return None


def echo(sock, payload):
    """Send payload, read back exactly as many bytes, or as many as arrive."""
    sock.sendall(payload)
    got = b""
    try:
        while len(got) < len(payload):
            chunk = sock.recv(4096)
            if not chunk:
                break
            got += chunk
    except socket.timeout:
        pass
    return got


def main():
    # E1 -- the listener exists at all.
    #
    # This one check covers the whole AT bring-up chain, because each step
    # gates the next in the fixture: ATE0, AT, AT+CIPMUX=1 and finally
    # AT+CIPSERVER=1,11000, which the engine REFUSES unless CIPMUX came first.
    # Nothing listens unless all four succeeded.
    first = connect()
    if not check(first is not None,
                 f"E1 the guest brought the ESP up and is listening on {HOST}:{PORT}"):
        # Everything below needs the connection; there is nothing to salvage.
        return 1

    # E2 -- a payload comes back.
    #
    # This is the +IPD parser and the CIPSEND reply in one exchange, and it is
    # also the check that the connection id was READ rather than assumed. jnext
    # reserves slot 0 for the guest's own outbound AT+CIPSTART, so this
    # connection is cid 1; a fixture that hardcoded the 0 the Espressif docs
    # lead you to expect would be told ERROR and would answer nothing at all.
    payload = b"PING"
    got = echo(first, payload)
    check(got == payload,
          f"E2 a payload echoes back byte-identically on the first connection "
          f"(sent {payload!r}, got {got!r})")

    # A COMPLETELY empty reply means the guest is not answering at all, and
    # every check below then fails for a reason that is not its own. The
    # emulator run is bounded in FRAMES, not in wall clock, so jnext exits
    # while the guest is still silent; this read ends on EOF as the socket is
    # torn down, and E4a's connection is refused because nothing is listening
    # any more. True, and it tells you nothing about the id.
    #
    # This was not theory — it is what the id-hardcoded-to-0 control produces.
    # Two WRONG mechanisms were confidently asserted before this one was
    # measured: first that the guest, parked in its failure loop, refused the
    # second connection (it cannot — the listener is emulator-side), then that
    # each check waited out ECHO_TIMEOUT (they do not — the whole failing run
    # takes ~9s, where two 20s timeouts alone would need 40). Reporting the
    # cascade as independent evidence is the mistake ERRORS.md names in
    # another form.
    silent = not got
    if silent:
        print("  (the guest answered nothing at all — the checks below cannot be "
              "read as independent evidence; fix E2 first)")

    # E3 -- the loop re-arms.
    #
    # A parser that consumed one byte too many or too few would survive E2 and
    # die here, because the leftovers land in the middle of the next +IPD
    # header. Sending a DIFFERENT length is the point: it also exercises the
    # decimal length parse with two digits rather than one.
    payload = b"hello-dezogif-ng"
    got = echo(first, payload)
    check(got == payload,
          f"E3 a second, longer payload echoes on the same connection "
          f"(sent {payload!r}, got {got!r})")

    # E4 -- the id is genuinely taken from the header.
    #
    # E2 rules out a hardcoded 0. This rules out a hardcoded anything: with the
    # first connection still open, this one is cid 2, so a fixture that always
    # replied on cid 1 would answer on the wrong socket and this read would
    # time out. That matters well beyond the fixture — MEMORY.md 2026-08-04
    # records that a stub which assumes an id "will send its replies to the
    # outbound slot, producing no error, no data, and a debug session that
    # looks like a DZRP bug".
    second = None
    try:
        second = socket.create_connection((HOST, PORT), timeout=10)
        second.settimeout(ECHO_TIMEOUT)
    except OSError as exc:
        note = " — but see above: the guest was already silent" if silent else ""
        print(f"  (second connection refused: {exc}{note})")
    if check(second is not None, "E4a a second simultaneous connection is accepted"):
        payload = b"second"
        got = echo(second, payload)
        check(got == payload,
              f"E4b the second connection echoes too, so the id comes from the "
              f"+IPD header and is not assumed (sent {payload!r}, got {got!r})")

    for sock in (first, second):
        if sock:
            sock.close()
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
