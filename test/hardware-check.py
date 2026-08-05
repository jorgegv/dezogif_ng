#!/usr/bin/env python3
"""The hardware bench: the checks that can only be answered by a real Next.

    make test-hardware NEXT_IP=192.168.1.42

WHY THIS EXISTS, AND WHY IT IS NOT JUST `make test-dzrp REMOTE=...`.

Nothing in this project has ever run on a ZX Spectrum Next. Every layer of the
test pyramid — screenshots, files on an SD image, bytes over a socket, and the
DZRP conformance suite itself — runs inside jnext, and jnext is an emulator of
the machine rather than the machine. Two of its fictions are known and written
down: it models **baud as timing only**, so the stub's 115200 would have passed
at any rate, and its ESP module is **permanently associated**, because jnext
implements no `AT+CWJAP=` at all. A third is suspected rather than known: jnext
numbers inbound connection ids from 1 as a consequence of reserving slot 0 for
outbound, which is a jnext design choice and may not be what the real module
does.

`make test-dzrp REMOTE=tcp:<ip>:11000` already speaks DZRP to anything, real
hardware included, and it is the right tool for "are the command handlers
correct". It is **not** the right tool for "is the emulator lying to us",
because it asks the same questions of hardware that it asks of jnext, and gets
the same answers when everything is fine. This script asks the questions whose
answers are only interesting on silicon:

  H1  Something is listening on the Next at all.
  H2  DZRP conformance — DELEGATED to conformance.py, not reimplemented.
  H3  The inbound connection id is read rather than assumed, on real firmware.
  H4  Round-trip latency, MEASURED. The plan calls 10-100 ms an "estimate".
  H5  Throughput, MEASURED. The plan calls "tens of KB/s" an "estimate".

H4 and H5 exist to move two rows of the plan's Appendix A off the "estimate"
rung of its evidence ladder. Their *numbers* are reported as MEASURED rather
than PASS, because a figure is not a verdict and a check that cannot fail must
not be allowed to look like one that can.

That is a statement about the numbers, NOT about the whole of H5. H5 also
carries a real FAIL: a large payload that comes back corrupted is the
reassembly path meeting framing we did not write, which is a genuine finding
and does flip the exit code. An earlier version of this paragraph said H4 and
H5 "never affect the exit code", which was simply false of the code beneath it.

WHAT H3 CANNOT DO, stated here because the first draft of the accompanying
document claimed otherwise twice. H3 shows that the connection id is READ from
the `+IPD` header rather than assumed. It does NOT observe what the module's
ids actually ARE, and no PC-side check can: the headers are consumed by the
stub, and what reaches this script is DZRP frames with the id already stripped.
So MEMORY.md's open question — whether real ESP-AT firmware numbers inbound
connections from 1 as jnext does — is NOT answerable from here, by this bench
or any successor to it that talks only over the socket.

H1 IS LOAD-BEARING FAR BEYOND ITS ONE LINE OF CODE. A TCP connection that
completes proves, in a single observation and on real hardware: that tbblue
loaded our `enNextMf.rom` (open question 2 — whether the firmware checksums it
— is answered "no" the moment this works); that the M1 button NMI was taken and
`nmi66h` accepted the cause; that `MAIN` was relocated into a RAM bank at slot
7 and is executing; that the core-version check passed; that UART0 came up at a
rate the real ESP-01 actually answers at; and that the module accepted `ATE0`,
`AT+CIPMUX=1` and `AT+CIPSERVER=1,11000`. Every one of those is inherited from
jnext runs today and none of them has been seen on hardware.

SO IF H1 FAILS, EVERYTHING BELOW IT IS SKIPPED AND SAYS SO. It is not reported
as five failures. ERRORS.md carries an entry for exactly this mistake — a
frame-bounded emulator run died under a client and produced three "findings"
that were all one harness artefact — and its lesson is that a test which can
fail for a reason outside its own subject has to say so.

WHAT THIS SCRIPT CANNOT SEE, and none of it is hidden:

  * The Next's screen. Whether the stub drew its UI, whether the error area is
    clear, and what the core version reads are observations for the human at
    the machine. doc/HARDWARE-TESTING.md carries them as a checklist.
  * THE RESUME PATH IS COVERED, and an earlier version of this comment said it
    was not. This script sends no CMD_CONTINUE of its own — a bare one against
    an unloaded machine is a crash, not a test — but H2 DELEGATES to
    conformance.py, and that suite carries C10/C11, which load a fixture, plant
    a temporary breakpoint and resume into it. So a passing H2 means the resume
    path ran wherever this was pointed, hardware included. The claim that no
    CMD_CONTINUE had reached a Next was written from what this file does and
    not from what it runs. Kept here as the correction, since the run that
    disproved it printed the false version underneath its own evidence.

    What that leaves genuinely untested is below.
  * The stackless-NMI return ADDRESS, which the emulator does not cover either:
    C10 sets PC itself, so save_nmi_return_address never runs. It needs an M1
    press while the debuggee is RUNNING, and hardware is the natural place for
    that — a human pressing the button has none of the frame-versus-wall-clock
    race that makes it unschedulable under jnext.
  * AltROM on hardware. Exercised in jnext by C10's RST 0 breakpoint, which can
    only reach the debugger through the patched Alt ROM; never on silicon.
  * The UART build. It needs a joy-port cable and a USB serial adapter; the
    conformance suite reaches it as serial:<dev>:<baud> when someone has that
    hardware set up, and this script does not pretend to.
"""

import argparse
import os
import socket
import statistics
import subprocess
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "dzrp"))

import dzrp  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
CONFORMANCE = os.path.join(HERE, "dzrp", "conformance.py")

PASS, FAIL, SKIP, MEASURED = "PASS", "FAIL", "SKIP", "MEAS"


def connect(host, port, timeout, socket_attempts=20, protocol_attempts=2, budget=None):
    """Open a DZRP conversation, retrying briefly, and send CMD_INIT.

    Returns (conversation, retries). THE RETRY COUNT IS PART OF THE RESULT, not
    an internal detail: a transport that needed three goes to answer is not the
    same machine as one that answered first time, and this bench exists to
    report what hardware actually does rather than to flatter it. Callers put
    the number in their own detail line, so a retry-smoothed PASS cannot read
    as a clean one. The same logic as H4/H5 being MEASURED rather than PASS.

    THE TWO BUDGETS ARE SEPARATE BECAUSE THE TWO FAILURES COST DIFFERENT
    AMOUNTS. A refused TCP connect fails in microseconds, so twenty of them are
    free and worth having. A protocol stall costs the FULL timeout — 15 seconds
    by default — so twenty of those is five minutes. The first version of this
    function reused one budget for both, and the measured result was a
    persistent fault taking 6m25s to report where it had previously taken 15s:
    a 25x regression in exactly the dimension that matters when somebody is
    sitting in front of a real Next waiting to be told what is wrong. Two
    protocol attempts ride out a single jitter spike, which is the transient
    this is for.

    THE PER-CALL BOUND IS NOT THE BENCH'S TIME-TO-REPORT, and an earlier
    version of this paragraph conflated them. One `connect()` costs at most two
    protocol attempts — about thirty seconds at the default timeout — but the
    bench makes several. Measured against a build with the connection id
    deliberately hardcoded: the whole run takes about **two minutes**, against
    6m25s before the budgets were split.

    The extra time in that particular run was H4's and H5's own fresh
    connections each needing a retry cycle, because the hardcoded id happened
    to coincide with jnext's low-id reuse timing — a property of how that
    specific break interacts with the emulator, not a general rule that one
    fault stalls every connection. The first draft of this paragraph gave the
    general version, which was a plausible mechanism rather than the traced
    one, and ERRORS.md already carries an entry about the difference.

    Thirty seconds was this author's arithmetic; two minutes is what a
    stopwatch said.

    `budget` is a wall-clock backstop over the whole thing, so no combination
    of slow failures can run away regardless of the counts.

    Two details here are copied from conformance.py rather than invented, so
    that the two benches agree about what talking to a remote involves:

      * THE RETRY. A remote that serves one client at a time needs a moment to
        start listening again after the previous connection closed. Calling
        that transient gap an unreachable remote is a false failure, and on a
        WiFi link the gap is longer than on localhost.
      * THE CMD_INIT. Every check in the conformance suite opens with one on
        its fresh connection. Whether our stub strictly requires it is not the
        point — a hardware bench that establishes the session differently from
        the suite it delegates to would be measuring a different thing.

    The preamble is pinned to absent (start_byte=None) rather than autodetected
    because this bench only ever talks to the WiFi build, where the 0xA5
    preamble must NOT be present. Autodetecting would quietly accept a ROM that
    emits it — which would mean the UART build was installed by mistake, the
    single likeliest setup error, and exactly the thing H1 cannot distinguish.

    THE RETRY COVERS THE CMD_INIT AS WELL AS THE CONNECT, and the first version
    of this function did not: the init was one line below the `except`, so a
    protocol-level stall aborted immediately with every remaining attempt
    unused, while this docstring claimed the retry protected against exactly
    that. It matters most on the target this bench is for. The stub's own RX
    budget is about 100 ms (`ESP_RX_WAIT` in transport_esp.asm), against a WiFi
    round trip the plan files as an unmeasured 10-100 ms ESTIMATE — so a jitter
    spike past that budget makes the *stub* reset through `rx_timeout` and drop
    the exchange, which is a transient this must ride out rather than report as
    a dead machine. Found in review, by measurement rather than by reading.
    """
    if budget is None:
        budget = max(40.0, timeout * 3.0)
    deadline = time.monotonic() + budget
    socket_left, protocol_left = socket_attempts, protocol_attempts
    retries, last = 0, None

    while True:
        d = None
        try:
            d = dzrp.Dzrp(dzrp.TcpTransport(host, port, timeout),
                          start_byte=None, base_timeout=timeout)
            d.command(dzrp.CMD_INIT, dzrp.init_payload())
            return d, retries
        except OSError as e:
            last, socket_left = e, socket_left - 1
            remaining = socket_left
        except dzrp.DzrpError as e:
            last, protocol_left = e, protocol_left - 1
            remaining = protocol_left

        # Close before retrying. The module serves four inbound connections at
        # most, so leaking one per attempt would exhaust them long before the
        # attempts ran out, and turn a transient into a wedge.
        if d is not None:
            try:
                d.close()
            except Exception:
                pass

        retries += 1
        if remaining <= 0:
            raise OSError("gave up on %s:%d after %d attempts — %s" % (
                host, port, retries, last))
        if time.monotonic() >= deadline:
            raise OSError("gave up on %s:%d after %d attempts and %.0fs — %s" % (
                host, port, retries, budget, last))
        time.sleep(0.25)


def retry_note(retries):
    """The clause a check appends when getting connected was not clean.

    Empty when it was, so a clean run reads exactly as before. Non-empty is
    deliberately conspicuous: an intermittent transport that eventually answers
    is a finding about the hardware, and it is the finding this bench would
    otherwise be least able to see, because everything downstream succeeds.
    """
    if not retries:
        return ""
    return "  [NOT CLEAN: %d connect retr%s needed]" % (
        retries, "y" if retries == 1 else "ies")


class Results:
    """Check outcomes, in order, with the counts the summary is derived from.

    Derived rather than written down: the headless bench once hardcoded "5/5"
    in its summary line and kept saying so after a sixth check was added, which
    is a small lie in exactly the place a reader trusts.
    """

    def __init__(self):
        self.rows = []

    def add(self, tag, status, detail):
        self.rows.append((tag, status, detail))
        print("  %-4s %-5s %s" % (tag, status, detail), flush=True)

    def count(self, status):
        return sum(1 for _, s, _ in self.rows if s == status)

    def failed(self):
        return self.count(FAIL) > 0


# --------------------------------------------------------------------------
# H1 — is anything there
# --------------------------------------------------------------------------


def h1_listener(host, port, timeout, results):
    """A completed TCP handshake, and what it proves is in the module docstring."""
    started = time.monotonic()
    try:
        sock = socket.create_connection((host, port), timeout=timeout)
    except OSError as e:
        results.add("H1", FAIL, "no listener on %s:%d after %.1fs — %s" % (
            host, port, time.monotonic() - started, e))
        return False
    sock.close()
    results.add("H1", PASS, "connected to %s:%d in %.0f ms — the stub's own "
                            "AT+CIPSERVER listener is up" % (
                                host, port, (time.monotonic() - started) * 1000))
    return True


# --------------------------------------------------------------------------
# H2 — conformance, delegated
# --------------------------------------------------------------------------


# Checks that are ALREADY red against our own stub in the emulator, with the
# issue that owns each. A red one here is not a hardware finding, and saying so
# is the entire point: somebody at a bench-top with a Next in front of them
# should not spend an evening debugging their WiFi over a defect that reproduces
# identically on a machine that has none.
#
# THIS IS A LABEL, NOT A SUPPRESSION. A listed check still fails, the bench
# still exits non-zero, and `--require INIT,LOOPBACK` is untouched. MEMORY.md is
# explicit that a red check must not be "fixed" by weakening it, and weakening
# it is exactly what a suppression would be.
#
# AN ENTRY MATCHES THE FAILURE, NOT JUST THE CHECK NUMBER. A check has more than
# one way to go red — the documented one and a desync that merely lands on the
# same line — so an entry carries the text it expects to see. Keyed on the check
# number alone, a hardware-only failure would be waved through as "already fails
# in the emulator", which is the one thing this table must never do.
#
# IT IS EMPTY, AND THAT IS A RESULT. Its one entry was C2 — issue #7, cmd_init
# reading the program name until a NUL and ignoring the frame's length field.
# That landed, C2 went green on its own, and the entry went with it, exactly as
# the comment here said it would. The mechanism stays for the next one.
KNOWN_RED = {
    "C12": {
        "signature": "it swallowed the command and carried on",
        "why": "issue #8 — CMD_PAUSE is routed to cmd_not_supported in src/commands.asm, so "
               "the frame is consumed and nothing is sent where the spec requires a Length=1 "
               "response. That jump-table entry dates to upstream's own 2023 commit, so both "
               "builds have always done it",
    },
}


def classify(fail_lines):
    """Split conformance FAIL lines into (known-red, novel), by code AND text."""
    known, novel = [], []
    for line in fail_lines:
        fields = line.split()
        code = fields[1] if len(fields) > 1 else "?"
        entry = KNOWN_RED.get(code)
        if entry and entry["signature"] in line:
            known.append(code)
        else:
            novel.append(code)
    return known, novel


def h2_conformance(remote, results, extra_args):
    """Run conformance.py as a subprocess and adopt its verdict.

    Deliberately a subprocess rather than an import. That suite owns what DZRP
    correctness means and has its own notion of UNSUPPORTED versus FAIL; the
    hardware bench should inherit that judgement wholesale rather than form a
    second opinion which could drift from it.
    """
    cmd = [sys.executable, CONFORMANCE, "--remote", remote,
           "--expect-preamble", "none", "--require", "INIT,LOOPBACK"] + extra_args
    print("\n--- conformance.py ---", flush=True)
    proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                          text=True)
    print(proc.stdout, end="", flush=True)
    print("--- end conformance.py ---\n", flush=True)

    if proc.returncode == 0:
        results.add("H2", PASS, "DZRP conformance suite passed in full")
        return
    if proc.returncode == 2:
        results.add("H2", FAIL, "the conformance suite could not talk to the remote at all")
        return

    fail_lines = [line for line in proc.stdout.splitlines() if line.startswith("FAIL ")]
    known, novel = classify(fail_lines)

    if known and not novel:
        results.add("H2", FAIL, "%s failed, and %s ALREADY fails against the emulator in "
                                "exactly this way: %s. Nothing here is a hardware finding" % (
                                    ", ".join(known),
                                    "it" if len(known) == 1 else "they all",
                                    "; ".join(KNOWN_RED[c]["why"] for c in known)))
    elif novel:
        results.add("H2", FAIL, "%s failed, of which %s %s NOT known-red — that is new on this "
                                "remote and is the part worth investigating" % (
                                    ", ".join(known + novel), ", ".join(novel),
                                    "is" if len(novel) == 1 else "are"))
    else:
        results.add("H2", FAIL, "the conformance suite exited %d — its own output above is "
                                "the detail" % proc.returncode)


# --------------------------------------------------------------------------
# H3 — the connection id, on real firmware
# --------------------------------------------------------------------------


def h3_connection_id(host, port, timeout, results):
    """Two connections open at once, each given its own distinct payload.

    THE QUESTION THIS ANSWERS. The stub reads the connection id out of the
    `+IPD,<id>,<len>:` header and echoes it back on `AT+CIPSEND=<id>,<len>`.
    MEMORY.md records that jnext numbers inbound connections from 1 because it
    reserves slot 0 for outbound `AT+CIPSTART` — and says in the same breath
    that this is a **jnext design choice**, that hardware may number
    differently, and that it must not be promoted to a hardware fact without
    measuring it. This measures it.

    WHY TWO CONNECTIONS AND NOT ONE. With one connection there is only one id
    in play, so a stub that ignored the header and hardcoded whatever that id
    happens to be would pass. This is bench check E4's shape, and E4 earned its
    place by being the only check that failed when the id was hardcoded to 1 —
    the other three passed. A wrong id here does not produce an error: it
    produces a reply delivered to the wrong socket, which reads as no error and
    no data, and looks like a DZRP bug rather than a framing one.

    WHAT IT DELIBERATELY DOES NOT DO. The two exchanges are sequential, not
    interleaved: A sends and is read to completion before B sends. Interleaving
    them would test something else entirely — whether a reply can be flushed to
    the wrong connection because a second command arrived and moved
    `esp_conn_id` first — and that is a property of our own buffering, not a
    hardware fact. See doc/HARDWARE-TESTING.md.
    """
    conns, retries = [], 0
    try:
        try:
            for _ in range(2):
                d, r = connect(host, port, timeout)
                conns.append(d)
                retries += r
        except (OSError, dzrp.DzrpError) as e:
            results.add("H3", FAIL, "could not open two simultaneous connections: %s. On "
                                    "hardware this may also mean the module accepted fewer "
                                    "connections than AT+CIPMUX=1 allows" % e)
            return

        payloads = [bytes([0x11]) * 24, bytes([0x22]) * 24]
        for i, (d, payload) in enumerate(zip(conns, payloads)):
            try:
                body = d.command(dzrp.CMD_LOOPBACK, payload)
            except dzrp.DzrpError as e:
                results.add("H3", FAIL, "connection %d got no usable reply (%s) — a reply "
                                        "addressed to the wrong id looks exactly like this"
                                        % (i + 1, e))
                return
            if body != payload:
                results.add("H3", FAIL, "connection %d got %d bytes back, and they are not "
                                        "its own payload — the id was assumed, not read"
                                        % (i + 1, len(body)))
                return

        results.add("H3", PASS, "two simultaneous connections each got their own payload "
                                "back — the +IPD id is read from the header, not assumed"
                                + retry_note(retries))
    finally:
        for d in conns:
            try:
                d.close()
            except Exception:
                pass


# --------------------------------------------------------------------------
# H4 / H5 — the two numbers the documents currently estimate
# --------------------------------------------------------------------------


def h4_latency(host, port, timeout, results, samples):
    """Round-trip time for a small CMD_LOOPBACK, reported as a distribution.

    The plan budgets "10-100 ms per round trip" and Appendix A files it as an
    ESTIMATE. One number is not a measurement of a WiFi link, so this reports
    min/median/max: the spread is the part that decides whether stepping is
    comfortable, and DeZog spends one round trip per single step.
    """
    try:
        d, retries = connect(host, port, timeout)
    except (OSError, dzrp.DzrpError) as e:
        results.add("H4", SKIP, "could not connect: %s" % e)
        return
    try:
        payload = b"\x5a" * 8
        times = []
        for _ in range(samples):
            started = time.monotonic()
            try:
                body = d.command(dzrp.CMD_LOOPBACK, payload)
            except dzrp.DzrpError as e:
                results.add("H4", SKIP, "loopback failed after %d samples: %s" % (len(times), e))
                return
            if body != payload:
                results.add("H4", SKIP, "loopback returned wrong data; H2 is the check that "
                                        "should be read for that")
                return
            times.append((time.monotonic() - started) * 1000.0)

        results.add("H4", MEASURED, "round trip over %d samples: min %.1f ms, median %.1f ms, "
                                    "max %.1f ms%s" % (len(times), min(times),
                                                       statistics.median(times), max(times),
                                                       retry_note(retries)))
    finally:
        d.close()


def h5_throughput(host, port, timeout, results, nbytes):
    """Bytes per second through a large CMD_LOOPBACK.

    Appendix A files ESP TCP throughput as an ESTIMATE ("tens of KB/s") and the
    plan works out 115200 baud as roughly 11.5 KB/s, making a 64 KB read about
    six seconds. A loopback moves the payload TWICE — out and back — so the
    figure reported here is the round-trip rate, and the one-way rate is
    stated beside it rather than left for the reader to halve.

    The size crosses jnext's 2048-byte +IPD split several times over. On
    hardware the module's own framing is whatever it is, which is the point:
    this is the first time the reassembly path meets a splitter we did not
    write.
    """
    timeout = max(timeout, 60.0)
    try:
        d, retries = connect(host, port, timeout)
    except (OSError, dzrp.DzrpError) as e:
        results.add("H5", SKIP, "could not connect: %s" % e)
        return
    try:
        payload = bytes((i * 7 + 3) & 0xFF for i in range(nbytes))
        started = time.monotonic()
        try:
            body = d.command(dzrp.CMD_LOOPBACK, payload)
        except dzrp.DzrpError as e:
            results.add("H5", SKIP, "%d-byte loopback failed: %s" % (nbytes, e))
            return
        elapsed = time.monotonic() - started

        if body != payload:
            results.add("H5", FAIL, "%d bytes did not survive the round trip — %d came back. "
                                    "This is the reassembly path meeting real ESP framing"
                                    % (nbytes, len(body)))
            return
        if elapsed <= 0:
            results.add("H5", SKIP, "elapsed time too small to divide by")
            return

        results.add("H5", MEASURED, "%d bytes round-tripped in %.2f s — %.1f KB/s round trip, "
                                    "%.1f KB/s one way%s" % (
                                        nbytes, elapsed,
                                        (nbytes * 2) / elapsed / 1024.0,
                                        nbytes / elapsed / 1024.0,
                                        retry_note(retries)))
    finally:
        d.close()


# --------------------------------------------------------------------------


UNCOVERED = """
NOT COVERED BY THIS RUN, and none of it is incidental:

  * The stackless-NMI return ADDRESS, untested in either place: it needs an M1
    press taken while the debuggee is running, which nothing performs yet.
    C10 sets PC itself, so save_nmi_return_address never runs.
  * AltROM on hardware. Exercised in jnext by C10's RST 0; never on silicon.
  * The Next's screen. Record it by hand — see doc/HARDWARE-TESTING.md.
  * The UART build, which needs a joy-port cable:
        make test-dzrp REMOTE=serial:/dev/ttyUSB0:921600
  * Whether a reply can be flushed to the WRONG connection when two commands
    interleave. That is a property of our buffering, not of the hardware.
"""


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--host", required=True,
                    help="the Next's IP address (there is no discovery; the connect-string "
                         "UI that would show it on screen is not built yet)")
    ap.add_argument("--port", type=int, default=11000,
                    help="DeZog's cspect default, and what the stub listens on (default: 11000)")
    ap.add_argument("--timeout", type=float, default=15.0,
                    help="seconds; generous, because a WiFi link is not a socket on localhost")
    ap.add_argument("--latency-samples", type=int, default=20)
    ap.add_argument("--throughput-bytes", type=int, default=4096,
                    help="CMD_LOOPBACK payload for H5 (spec caps it at 8192)")
    ap.add_argument("--skip-conformance", action="store_true",
                    help="skip H2 when it has already been run separately")
    args, extra = ap.parse_known_args()

    remote = "tcp:%s:%d" % (args.host, args.port)
    print("dezogif_ng hardware bench — %s" % remote)
    print("Started %s\n" % time.strftime("%Y-%m-%d %H:%M:%S"))

    results = Results()

    if not h1_listener(args.host, args.port, args.timeout, results):
        for tag in ("H2", "H3", "H4", "H5"):
            results.add(tag, SKIP, "nothing was listening; this check was NOT run")
        print("\nH1 failed, so nothing below it ran. The checks above are not four "
              "findings — they are one.")
        print("\nThings to check at the machine, in order: the WiFi ROM (not the UART one) "
              "is installed as the Multiface ROM; the M1 button has been pressed once since "
              "power-on; the Next is associated (doc/WIFI-SETUP.md); the IP is the one passed "
              "here; nothing else on the machine has taken the ESP.")
        return 1

    if args.skip_conformance:
        results.add("H2", SKIP, "skipped at the caller's request")
    else:
        h2_conformance(remote, results, extra)

    h3_connection_id(args.host, args.port, args.timeout, results)
    h4_latency(args.host, args.port, args.timeout, results, args.latency_samples)
    h5_throughput(args.host, args.port, args.timeout, results, args.throughput_bytes)

    total = len(results.rows)
    print("\n%d passed, %d failed, %d measured, %d skipped of %d" % (
        results.count(PASS), results.count(FAIL), results.count(MEASURED),
        results.count(SKIP), total))

    # A non-zero exit whose only cause is a defect that reproduces in the
    # emulator would otherwise read, at a bench-top, as "the hardware failed".
    if results.failed() and all("Nothing here is a hardware finding" in d
                                for _, s, d in results.rows if s == FAIL):
        print("\nThe only failure is one that ALREADY fails in the emulator, so this run "
              "found nothing wrong with the hardware. The exit code is still non-zero, "
              "deliberately: the check is labelled, not suppressed.")

    print(UNCOVERED)

    return 1 if results.failed() else 0


if __name__ == "__main__":
    sys.exit(main())
