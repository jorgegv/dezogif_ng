#!/usr/bin/env python3
"""End-to-end DZRP conformance checks against a remote given as a parameter.

    python3 test/dzrp/conformance.py --remote tcp:127.0.0.1:11000
    python3 test/dzrp/conformance.py --remote serial:/dev/ttyUSB0:921600

Run by `make test-dzrp REMOTE=...`. Issue #2.

WHY THIS EXISTS. Nothing else in this repository sends a DZRP command and
checks the reply: `make test` judges screenshots, `make test-mfselect` judges
files on an SD image, and the Z80 unit tests need VS Code. The deliverable of
this project is a protocol implementation, and the protocol had no test.

WHAT IT DELIBERATELY DOES NOT TEST. DeZog owns instruction-length calculation,
the original opcode stored under a breakpoint, the temporary breakpoints used
to step off one, and breakpoint-condition evaluation. Asserting any of those
against the remote would encode the wrong contract, and push whoever tried to
make it pass into building the very thing that fights DeZog at runtime. This
suite behaves the way DeZog behaves.

A PARTIAL REMOTE IS LEGITIMATE. DZRP has 29 commands and remotes implement
different subsets — CSpect's DeZog plugin, for one, does not implement
CMD_LOOPBACK and closes the connection on it. So an unimplemented command is
reported as UNSUPPORTED, not failed, unless it is named in --require. Each
check therefore runs on its own connection: one refused command must not take
the rest of the suite down with it.
"""

import argparse
import os
import time
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import dzrp  # noqa: E402

PASS, FAIL, UNSUP = "PASS", "FAIL", "UNSUP"

# Command names, for --require and for reporting.
NAMES = {
    "INIT": dzrp.CMD_INIT,
    "LOOPBACK": dzrp.CMD_LOOPBACK,
    "GET_REGISTERS": dzrp.CMD_GET_REGISTERS,
    "READ_MEM": dzrp.CMD_READ_MEM,
    "WRITE_MEM": dzrp.CMD_WRITE_MEM,
}


class Unsupported(Exception):
    """The remote does not implement this command."""


# CMD_INIT is how every DZRP conversation starts. A remote that cannot answer
# it is broken, not partial, so it is never eligible to be excused as
# UNSUPPORTED however it fails.
ALWAYS_REQUIRED = {"INIT"}


def talk(d, cmd_id, payload=b""):
    """Send a command, mapping only a DELIBERATE refusal onto Unsupported.

    A remote that does not know a command closes the connection — that is what
    CSpect's plugin does, and it is not a protocol violation.

    A TIMEOUT IS NOT THAT. It means the remote is waiting for bytes we did not
    send, which is what a wrong length field looks like from this side, and
    treating it as "unimplemented" is how this suite once reported a completely
    broken handshake as 8 UNSUPPORTED checks and exit 0. Timeouts propagate as
    failures.
    """
    try:
        return d.command(cmd_id, payload)
    except dzrp.DzrpError as e:
        if "closed" in str(e):
            raise Unsupported(str(e))
        raise


# --------------------------------------------------------------------------
# checks — each returns (status, detail) and gets a fresh connection
# --------------------------------------------------------------------------


def chk_init(d):
    """Version negotiation: the first command DeZog itself sends."""
    body = talk(d, dzrp.CMD_INIT, dzrp.init_payload())
    if len(body) < 6:
        return FAIL, "response too short for error+version+machine+name: %d bytes" % len(body)
    err = body[0]
    ver = "%d.%d.%d" % (body[1], body[2], body[3])
    machine = body[4]
    name = body[5:].split(b"\x00")[0].decode("ascii", "replace")
    if err != 0:
        return FAIL, "error code %d (version %s, %r)" % (err, ver, name)
    return PASS, "DZRP %s, machine %d, %r" % (ver, machine, name)


def chk_length_convention(d):
    """A command's length counts the payload ONLY; a response's counts from the
    sequence number. They are not symmetric, and assuming they are makes the
    remote wait in silence rather than complain — which is how this check
    earned its place. CMD_INIT answering at all proves the outbound half; the
    inbound half is proven by the frame parsing cleanly."""
    body = talk(d, dzrp.CMD_INIT, dzrp.init_payload())
    if not body:
        return FAIL, "no response body"
    return PASS, "command length = payload only; response length counts the seq byte"


def chk_preamble(d, expect):
    """Does the remote prefix frames with 0xA5?

    Not a bug hunt — a capability probe. Upstream extended DZRP by this byte
    for the serial link (doc/legacy/Design.md:30-31): DeZog "will wait on this
    byte before it recognizes messages coming from the Next", because a game
    that grabs the joy port makes the Next emit endless zeroes. DeZog's
    ZxNextSerialRemote strips byte 165; its CSpectRemote does not.

    So the correct answer differs by transport: present in UART mode, absent
    for a socket remote. That is why this reports rather than assumes, and why
    --expect-preamble exists for callers who know which they are talking to.
    """
    talk(d, dzrp.CMD_INIT, dzrp.init_payload())
    seen = d.observed_start_byte
    desc = "0xA5" if seen == dzrp.START_BYTE else "none"
    if expect == "report":
        return PASS, "preamble: %s (recorded, not asserted)" % desc
    want = dzrp.START_BYTE if expect == "a5" else None
    if seen == want:
        return PASS, "preamble is %s, as expected" % desc
    return FAIL, "expected %s, observed %s" % (expect, desc)


def chk_loopback(d):
    """Framing and byte order, without touching machine state. The project's
    dzrp skill puts this first for our own server: if it does not round-trip,
    nothing above it is worth debugging."""
    talk(d, dzrp.CMD_INIT, dzrp.init_payload())
    data = bytes(range(1, 33))
    got = talk(d, dzrp.CMD_LOOPBACK, data)
    if got != data:
        return FAIL, "sent %d bytes, got %d back and they differ" % (len(data), len(got))
    return PASS, "32 bytes round-tripped unchanged"


def chk_loopback_sizes(d):
    """Boundaries, including empty and past any plausible internal buffer."""
    talk(d, dzrp.CMD_INIT, dzrp.init_payload())
    for n in (0, 1, 255, 256, 1024):
        payload = bytes((i * 7 + n) & 0xFF for i in range(n))
        got = talk(d, dzrp.CMD_LOOPBACK, payload)
        if got != payload:
            return FAIL, "%d bytes came back as %d and differ" % (n, len(got))
    return PASS, "exact at 0, 1, 255, 256 and 1024 bytes"


def chk_sequence(d):
    """A response must carry the sequence number of the command that asked for
    it; the client raises on a mismatch, so five clean exchanges is the
    assertion."""
    for _ in range(5):
        talk(d, dzrp.CMD_INIT, dzrp.init_payload())
    return PASS, "5 consecutive commands, sequence numbers echoed correctly"


def chk_registers(d):
    """DeZog indexes into the register block, so a short answer is a hard
    failure rather than a partial one."""
    talk(d, dzrp.CMD_INIT, dzrp.init_payload())
    body = talk(d, dzrp.CMD_GET_REGISTERS)
    if len(body) < 28:
        return FAIL, "register block is only %d bytes" % len(body)
    return PASS, "%d-byte register block" % len(body)


def chk_memory(d):
    """Write then read back, in RAM clear of the ROM and of the debugger's own
    slots 6 and 7."""
    talk(d, dzrp.CMD_INIT, dzrp.init_payload())
    addr, n = 0x8000, 64
    data = bytes((i * 13 + 1) & 0xFF for i in range(n))
    talk(d, dzrp.CMD_WRITE_MEM, b"\x00" + addr.to_bytes(2, "little") + data)
    body = talk(d, dzrp.CMD_READ_MEM,
                b"\x00" + addr.to_bytes(2, "little") + n.to_bytes(2, "little"))
    if body != data:
        return FAIL, "wrote %d bytes at 0x%04X, read %d and they differ" % (n, addr, len(body))
    return PASS, "%d bytes at 0x%04X survived the round trip" % (n, addr)


CHECKS = [
    ("C1 CMD_INIT negotiates a version", chk_init, "INIT"),
    ("C2 length conventions are as specified", chk_length_convention, "INIT"),
    ("C3 frame preamble", None, "INIT"),            # needs the expect argument
    ("C4 CMD_LOOPBACK round-trips", chk_loopback, "LOOPBACK"),
    ("C5 CMD_LOOPBACK is exact at size boundaries", chk_loopback_sizes, "LOOPBACK"),
    ("C6 sequence numbers echo back", chk_sequence, "INIT"),
    ("C7 CMD_GET_REGISTERS returns a register block", chk_registers, "GET_REGISTERS"),
    ("C8 memory write/read round-trip", chk_memory, "WRITE_MEM"),
]


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--remote", required=True,
                    help="tcp:<host>:<port> or serial:<device>:<baud>")
    ap.add_argument("--start-byte", default="auto", choices=["auto", "a5", "none"],
                    help="frame preamble the remote uses (default: autodetect)")
    ap.add_argument("--expect-preamble", default="report",
                    choices=["report", "a5", "none"],
                    help="assert the preamble rather than only reporting it")
    ap.add_argument("--require", default="",
                    help="comma-separated commands whose absence is a FAILURE "
                         "rather than UNSUPPORTED, e.g. INIT,LOOPBACK")
    ap.add_argument("--timeout", type=float, default=5.0)
    args = ap.parse_args()

    required = {s.strip().upper() for s in args.require.split(",") if s.strip()}
    unknown = required - set(NAMES)
    if unknown:
        print("ERROR: --require names unknown commands: %s" % ", ".join(sorted(unknown)),
              file=sys.stderr)
        return 2

    sb = {"auto": "auto", "a5": dzrp.START_BYTE, "none": None}[args.start_byte]

    print("== DZRP conformance against %s" % args.remote)
    if required:
        print("   required commands: %s" % ", ".join(sorted(required)))
    print("")

    counts = {PASS: 0, FAIL: 0, UNSUP: 0}

    for label, fn, cmd_name in CHECKS:
        # Each check gets a fresh connection, so one refused command cannot
        # take the rest down. A remote that serves one client at a time needs
        # a moment to start listening again between them — CSpect's plugin
        # logs "Disconnected / Waiting for a connection" — so retry briefly
        # rather than calling that transient gap an unreachable remote.
        transport = None
        for attempt in range(20):
            try:
                transport = dzrp.open_remote(args.remote, timeout=args.timeout)
                break
            except (OSError, dzrp.DzrpError):
                time.sleep(0.25)
        if transport is None:
            print("ERROR: cannot reach %s after 5s of retries" % args.remote,
                  file=sys.stderr)
            return 2
        d = dzrp.Dzrp(transport, start_byte=sb)
        try:
            if fn is None:                       # the preamble check needs a flag
                status, detail = chk_preamble(d, args.expect_preamble)
            else:
                status, detail = fn(d)
        except Unsupported as e:
            if cmd_name in required or cmd_name in ALWAYS_REQUIRED:
                status = FAIL
                detail = "CMD_%s is REQUIRED but the remote does not implement it (%s)" % (
                    cmd_name, e)
            else:
                status = UNSUP
                detail = "remote does not implement CMD_%s" % cmd_name
        except dzrp.DzrpError as e:
            status, detail = FAIL, str(e)
        finally:
            d.close()

        counts[status] += 1
        print("%-5s %s%s" % (status, label, " — %s" % detail if detail else ""))

    total = len(CHECKS)
    print("")
    summary = "%d passed, %d failed, %d unsupported, of %d checks" % (
        counts[PASS], counts[FAIL], counts[UNSUP], total)
    print("DZRP conformance: " + summary)
    # Everything-unsupported is not a pass. A remote that answered nothing at
    # all would otherwise exit 0, which is precisely the "green result that
    # cannot distinguish success from noise" ERRORS.md already warns about.
    if counts[PASS] == 0:
        print("  (nothing passed — treating that as a failure, not a partial remote)")
        return 1
    return 1 if counts[FAIL] else 0


if __name__ == "__main__":
    sys.exit(main())
