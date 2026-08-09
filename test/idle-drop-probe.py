#!/usr/bin/env python3
"""PROBE C — does the module drop an IDLE inbound connection, and after how long?

    make probe-idle-drop NEXT_IP=192.168.1.42 PROBE_ARGS="--expect-timeout 180"

THIS IS AN INSTRUMENT, NOT A GATE. It prints one number and says what that
number is and is not. There is no PASS here, no FAIL, and no exit code that
depends on whether the measurement matched what you expected — `--expect-timeout`
changes the WORDING of a row and never the verdict, because there is no verdict.
It is not part of `make test` and must not become part of it.

WHY THE NUMBER MATTERS. A module that reaps idle inbound connections settles two
questions this project has answered wrongly in both directions:

  * KNOWN-ISSUES.md #19's slot leak is BOUNDED by it, not permanent. A Next that
    refuses everybody because five peers vanished starts serving again once the
    oldest is reaped — so "power-cycle it" is the wrong advice, and the reopen
    criterion for #19 is "still refusing after longer than this timeout".
  * a DeZog session parked at a breakpoint while somebody READS CODE is silent
    for minutes and perfectly healthy. The stub sends nothing unprompted and the
    client sends nothing while you think, so both ends are quiet — which is
    exactly the condition an idle timeout measures. Issue #24 lengthens it
    deliberately for that reason, and this probe is how a build carrying #24 is
    shown to have taken.

NOTHING ABOUT THE TIMEOUT IS ASSUMED, AND THAT IS THE POINT OF `--expect-timeout`.
This probe CANNOT read `AT+CIPSTO?` — that needs `.UART` at the machine, or the
value the stub sets at bring-up. So the expectation is SUPPLIED BY THE CALLER and
is reported as such. Without one, the number is printed and nothing is attributed
to it. A draft of this tool printed the module's timeout as a constant and drew
conclusions from it; run against a stub that had raised the value it announced
that no timeout existed, which is a conclusion printed without consulting what
happened.

"SURVIVED" IS A LOWER BOUND, NOT AN ABSENCE. A connection still open at the
deadline says the timeout is LONGER than the deadline. It never says there is
none, and no length of wait can — this probe can only ever bracket the value from
below. Every survival branch below is worded that way on purpose.

AND A MATCH IS CONSISTENCY, NOT ATTRIBUTION. A drop at 182 s against an expected
180 s is a drop that is CONSISTENT with `AT+CIPSTO`. It is not proof that
`AT+CIPSTO` is what did it: from this side of the module any mechanism that closes
an idle inbound connection looks identical. What rules the alternatives out is
argued in the docs, not observed here — see "WHAT THIS CANNOT ESTABLISH" below.

WHAT MAKES THE RESULT ATTRIBUTABLE TO THE REMOTE AT ALL. Three things, because
"the socket closed" has more causes than the one being measured:

  1. a CMD_INIT round trip FIRST (R0). If the link, the framing and this client
     were not working there would be no session to time — so a later close cannot
     be a client bug that was there all along. It is also this probe's own
     instrument check: `make probe-jnext` validates probes A and B against a
     ceiling the emulator is known to have, and there is no equivalent here,
     because whether jnext models `AT+CIPSTO` at all is unknown. R0 at the start
     and a validated screen reader at the end are what say the probe was working
     at both ends of the wait.
  2. the client sends NOTHING afterwards and never closes. A read returning
     end-of-file is unambiguously the PEER closing; a read timing out is the peer
     still holding it. Those are different returns and are reported differently.
  3. the stub is the only other candidate closer and it has no path to this. An
     established connection is closed only by `esp_recover`'s sweep, which needs
     ESP_FAULT_LIMIT consecutive faults through `rxtx_error`; nothing transmits
     during the wait, so no fault can be raised. TRACED, not observed — and a
     fault-counted mechanism cannot produce a result that varies with elapsed
     time alone, which is the cross-check that makes the trace worth something.

THE SCREEN READ IS A SEPARATE OBSERVATION AND MUST NOT DESTROY THE FIRST. It runs
on a SECOND connection and sends NO CMD_INIT, because `cmd_init` does `xor a` /
`ld (last_error),a` and would erase the thing being read — the rule
`test/dzrp/screen.py` was built around. It sends no CMD_CLOSE either, unlike
probes A and B: this probe's subject INCLUDES the session line, and `cmd_close`
leaves through `jp main`, which repaints it. Leaving the courtesy undone is the
lesser cost. Same reasoning as `test/dzrp/screen-client.py`.

R5 READS THE IDENTITY LINE, and it is there because nothing else here can say
which ROM produced the measurement: DZRP's `PROGRAM_NAME` reports upstream's
`dezogif v2.2.1` for every build we ship, so a hardware result normally cannot be
tied to a build number (MEMORY.md, 2026-08-08). The stub prints its own
`dezogif_ng <variant> NN.NN` at row 0, and the screen reader can see it.

CHECK IDS ARE INTERFACE. `R0`-`R5` are cited in doc/HARDWARE-TESTING.md and in
issues. Shorten the prose after an id; never the id, and never renumber. The
family is `R` for *reap*, chosen because every other letter this project uses was
taken — `A` and `B` by the other two probes, `C` by the conformance suite.

WHAT THIS CANNOT ESTABLISH, and none of it is hidden:

  * WHAT closed the connection. See "a match is consistency" above.
  * WHETHER THE MODULE EMITS `<id>,CLOSED` WHEN IT REAPS. That line is the module
    talking to the Z80 over the UART, and this is a TCP client on the far side of
    the module. R4 reads what the stub CONCLUDED, which is the nearest thing
    available and is not the same observation — and on the survival path the
    close is OUR OWN clean FIN, so a changed session line there says nothing
    about a reap at all. It matters to issue #23.
  * WHETHER THE TIMER IS PER-CONNECTION OR GLOBAL. One connection is timed here.
    Probe B's bracket bears on that question; this does not.
  * A WEDGED-BUT-REACHABLE PEER, as against an idle one. Every byte of this
    probe's silence is a peer that is present and simply not talking.
  * THE BORDER, which is not in the display file and which no CMD_READ_MEM can
    reach. Photograph it.
  * ANYTHING ABOUT ANOTHER MODULE. `AT+CIPSTO` is settable, its range is 0-7200,
    and `0` disables it outright.

EXIT CODES.

  0  it measured something. THE ONLY ORDINARY OUTCOME — the number is the result,
     whatever it is, and whatever `--expect-timeout` said.
  2  it could not measure at all: nothing answered on the port, or the session
     could not be opened, so there was nothing to time.

Never 1, and never a code that depends on the comparison. This renders no verdict.
"""

import argparse
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "dzrp"))

import dzrp  # noqa: E402
import screen  # noqa: E402

# How the wait ended. CLOSED and RESET are both "the remote ended it" for timing
# purposes and are kept apart anyway, because a module reaping on a timer should
# hang up politely: an RST is a different story wearing the same duration.
CLOSED, RESET, SURVIVED, SPOKE = "CLOSED", "RESET", "SURVIVED", "SPOKE"
ENDED = (CLOSED, RESET)

MEASURED, NOTE = "MEAS", "NOTE"

_CODES = {MEASURED: "\033[1;36m", NOTE: "\033[1;33m"}
COLOUR = bool(sys.stdout.isatty()) and not os.environ.get("NO_COLOR")

INDENT = " " * 13


def paint(status, width=5):
    if not COLOUR:
        return "%-*s" % (width, status)
    return "%s%-*s\033[0m" % (_CODES.get(status, ""), width, status)


def row(tag, status, text):
    print("  %-4s %s %s" % (tag, paint(status), text), flush=True)


def detail(text):
    print("%s%s" % (INDENT, text), flush=True)


def auto_tolerance(expected):
    """How far from `expected` still counts as `expected`.

    A FRACTION WITH A FLOOR, because neither on its own serves `AT+CIPSTO`'s
    0-7200 range. A fixed band is a tenth of 180 and three parts in a thousand of
    7200 — far tighter at the top than any module's granularity deserves — so the
    band scales. The floor is there because at small values a tenth would be
    tighter than the overshoot actually measured: two runs at a documented 180 s
    dropped at 182.5 s and 181.8 s, so the fixed cost is a couple of seconds and a
    pure percentage would start flagging it as a finding.
    """
    return max(10.0, 0.10 * expected)


def auto_deadline(expected, tolerance):
    """How long to wait before giving up, when the caller did not say.

    Past `expected + tolerance`, so that a survival is a FINDING rather than an
    unfinished measurement. There is no such point when no expectation was given,
    nor when the expectation is 0 — "it never reaps" is a claim no finite wait can
    confirm — so both take 300 s, a round number comfortably past the ESP-AT
    default of 180.
    """
    if expected is None or expected <= 0:
        return 300.0
    return expected + tolerance + max(30.0, 0.10 * expected)


def open_session(host, port, timeout, name):
    """Connect and get one CMD_INIT answered. Returns (conv, ms, why)."""
    started = time.monotonic()
    try:
        transport = dzrp.TcpTransport(host, port, timeout)
    except OSError as e:
        return None, (time.monotonic() - started) * 1000.0, str(e)
    # start_byte=None, not "auto": this probe's subject is the ESP transport, and
    # the WiFi build emits no 0xA5 preamble. Guessing would let a desynchronised
    # stream look like a differently-framed one.
    conv = dzrp.Dzrp(transport, start_byte=None, base_timeout=timeout)
    try:
        conv.command(dzrp.CMD_INIT, dzrp.init_payload(name=name))
    except (OSError, dzrp.DzrpError) as e:
        conv.close()
        return None, (time.monotonic() - started) * 1000.0, str(e)
    return conv, (time.monotonic() - started) * 1000.0, ""


def wait_for_drop(conv, deadline, poll, report_every):
    """Say nothing, and watch. Returns (outcome, seconds_of_silence, why).

    THE SILENCE IS TIMED FROM HERE, which under-reports rather than over-reports.
    The module last HEARD from this peer a few milliseconds earlier, when the
    CMD_INIT arrived, so any timer on its side started fractionally before this
    clock did and the figure printed is fractionally short of the true age. That
    is the safe direction for a lower bound.

    Read through the shared transport rather than its socket, so that end-of-file
    and a timeout arrive as the two different exceptions the rest of this bench
    already distinguishes. `Timeout` is a subclass of `DzrpError` and is caught
    first for that reason.
    """
    silent_from = time.monotonic()
    next_report = report_every
    conv.t.set_timeout(poll)
    while True:
        if time.monotonic() - silent_from >= deadline:
            return SURVIVED, time.monotonic() - silent_from, ""
        try:
            got = conv.t.read(1)
        except dzrp.Timeout:
            waited = time.monotonic() - silent_from
            if waited >= next_report:
                detail("still connected, silent for %.0f s" % waited)
                while next_report <= waited:
                    next_report += report_every
            continue
        except dzrp.DzrpError as e:
            # TcpTransport.read raises this on end-of-file: a FIN from the peer.
            return CLOSED, time.monotonic() - silent_from, str(e)
        except OSError as e:
            # A reset arriving mid-wait. Same duration, different mechanism.
            return RESET, time.monotonic() - silent_from, str(e)
        # The stub does not speak unprompted with no debuggee running, so a byte
        # here is a finding of its own and must not be folded into the timing.
        return SPOKE, time.monotonic() - silent_from, "first byte %r" % got


def compare(outcome, seconds, expected, tolerance):
    """R2's line, plus any detail lines. Returns (status, text, [details]).

    THE ONLY PLACE THE EXPECTATION IS CONSULTED, and it produces prose and
    nothing else — no exit code, no verdict. Every branch is written so that it
    is true of the number in front of it and of nothing wider.
    """
    ended = outcome in ENDED

    if expected is None:
        if ended:
            return (NOTE,
                    "no --expect-timeout was given, so nothing is compared and "
                    "nothing is attributed",
                    ["Read AT+CIPSTO? at the machine with .UART, then re-run with it."])
        return (NOTE,
                "no --expect-timeout was given; this is a bare lower bound and "
                "nothing more",
                ["Read AT+CIPSTO? at the machine with .UART, then re-run with it."])

    if expected == 0:
        # AT+CIPSTO=0 disables the timeout, so 0 is not a value to match: it is
        # the claim that there is no reap. The numeric comparison below would be
        # meaningless here, which is why this branch comes first.
        if ended:
            return (MEASURED,
                    "0 s expected means the timeout is DISABLED, yet the remote "
                    "ended it — a finding", [])
        return (MEASURED,
                "no drop in %.0f s, consistent with the disabled (0 s) timeout "
                "expected" % seconds, [])

    if ended:
        if abs(seconds - expected) <= tolerance:
            return (MEASURED,
                    "%.1f s is the %.0f s expected, inside the +/- %.0f s tolerance"
                    % (seconds, expected, tolerance), [])
        which = "EARLIER" if seconds < expected else "LATER"
        return (MEASURED,
                "%.1f s is %s than the %.0f s expected — a finding, not a match"
                % (seconds, which, expected),
                ["Two runs before believing it: this is one connection, once."])

    # SURVIVED. Three readings, and only the first is a finding — see the
    # docstring on lower bounds. Which one applies depends entirely on where the
    # deadline fell relative to the expectation, so a caller who shortened the
    # deadline gets told that rather than told nothing.
    if seconds > expected + tolerance:
        return (MEASURED,
                "no drop in %.0f s, past the %.0f s expected: the expectation is "
                "NOT met" % (seconds, expected), [])
    if seconds >= expected - tolerance:
        return (NOTE,
                "the wait ended inside the tolerance band around %.0f s: "
                "inconclusive" % expected,
                ["Re-run with --deadline past %.0f s to make a survival mean "
                 "something." % (expected + tolerance)])
    return (NOTE,
            "no drop in %.0f s; %.0f s was expected, so this is consistent and "
            "confirms nothing" % (seconds, expected),
            ["Re-run with --deadline past %.0f s to confirm it."
             % (expected + tolerance)])


def read_screen_after(host, port, timeout, attempts):
    """The stub's own screen, on a FRESH connection. Returns (screen, why).

    RETRIED, on a fresh connection each time, and the reason is measured. A
    command arriving while the stub is inside `drain_main`'s ~100 ms drain is
    read off the wire and DISCARDED (MEMORY.md's CRLF entry), and this probe
    reaches here immediately after a connection ended — which is precisely when
    that drain runs. Same reasoning as screen-client.py's own retry.

    NO CMD_INIT and NO CMD_CLOSE: see the module docstring.
    """
    why = "no attempt was made"
    for attempt in range(max(1, attempts)):
        if attempt:
            time.sleep(1.0)
        conv = None
        try:
            conv = dzrp.Dzrp(dzrp.TcpTransport(host, port, timeout),
                             start_byte=None, base_timeout=timeout)
            return screen.read_screen(conv, glyphs=screen.read_font(conv)), ""
        except (OSError, dzrp.DzrpError, ValueError) as e:
            why = "%s: %s" % (type(e).__name__, e)
        finally:
            if conv is not None:
                conv.close()
    return None, why


def report_screen(scr, why, outcome):
    """R3, R4 and R5 — three observations off ONE read of the screen.

    ONE READ, so the three rows are of the same moment. R3 uses the Screen's own
    `observation()`, which is the wording probes A and B print through
    `screen.observe()`, rather than a second sentence that could drift from it;
    the caveat `observe()` folds into its text — that this run's own disconnect
    leaves `RX Timeout` behind — is a separate short line here instead.
    """
    if scr is None:
        row("R3", NOTE, "the screen could not be read (%s) — a fact about this read" % why)
        row("R4", NOTE, "the session line was not read")
        row("R5", NOTE, "the identity line was not read")
        return

    ok, _ = scr.validate_reader()
    row("R3", MEASURED if ok else NOTE, scr.observation())
    if not ok:
        # `observation()` has already said this is a broken reader rather than a
        # clean screen. Nothing else off this image may be believed.
        row("R4", NOTE, "not judged: the reader failed its own row-%d validation"
            % screen.VALIDATION_ROW)
        row("R5", NOTE, "not judged: the reader failed its own row-%d validation"
            % screen.VALIDATION_ROW)
        return

    if scr.only_error_is():
        detail("which is what this run's own disconnect leaves behind — see screen.py")

    # BOUNDED INTERPOLATION. A screen row is 32 characters, so the longest this
    # line can get is small and known — unlike the arbitrary text screen.py
    # refuses to interpolate into its own one-liner.
    row("R4", MEASURED, "session line: %r"
        % scr.row_text(screen.SESSION_ROW).rstrip())
    if outcome in ENDED:
        detail("the remote ended it; this line is what the stub made of that")
    else:
        detail("this probe closed it: a changed line here is our FIN, not a reap")

    row("R5", MEASURED, "identity line: %r" % scr.row_text(0).rstrip())
    detail("which build produced this; CMD_INIT reports upstream's name, not ours")


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--host", required=True,
                    help="the Next's IP address, off its own screen")
    ap.add_argument("--port", type=int, default=11000)
    ap.add_argument("--expect-timeout", type=float, default=None, metavar="SECONDS",
                    help="the idle timeout you EXPECT this remote to enforce. "
                         "Read it at the machine with .UART (AT+CIPSTO?), or take "
                         "it from what the stub sets at bring-up. Nothing is "
                         "assumed without it, and it changes only the wording of "
                         "R2 — never the exit code. 0 means you expect NO reap")
    ap.add_argument("--tolerance", type=float, default=None, metavar="SECONDS",
                    help="how far from --expect-timeout still counts as it "
                         "(default: 10%% of it, at least 10 s)")
    ap.add_argument("--deadline", type=float, default=None, metavar="SECONDS",
                    help="give up waiting after this long. A survival is only a "
                         "FINDING if this is past --expect-timeout plus the "
                         "tolerance; otherwise it is a lower bound and says so")
    ap.add_argument("--poll", type=float, default=5.0,
                    help="seconds per blocking read while waiting. It does not "
                         "delay detection — a close is readable at once — it only "
                         "bounds how often the loop wakes")
    ap.add_argument("--report-every", type=float, default=30.0,
                    help="seconds between progress lines during the silence")
    ap.add_argument("--timeout", type=float, default=20.0,
                    help="seconds per DZRP exchange; 6912 bytes at 115200 is ~1 s "
                         "on a Next, so be generous")
    ap.add_argument("--screen-attempts", type=int, default=3,
                    help="fresh connections to try for the closing screen read")
    args = ap.parse_args()

    if args.expect_timeout is not None and args.expect_timeout < 0:
        print("ERROR: --expect-timeout cannot be negative; 0 means you expect no "
              "reap at all.", file=sys.stderr)
        return 2

    tolerance = args.tolerance
    if tolerance is None:
        tolerance = auto_tolerance(args.expect_timeout or 0.0)
    deadline = args.deadline
    if deadline is None:
        deadline = auto_deadline(args.expect_timeout, tolerance)

    print("dezogif_ng idle-drop probe (C) — tcp:%s:%d" % (args.host, args.port))
    print("Started %s" % time.strftime("%Y-%m-%d %H:%M:%S"))
    print("An INSTRUMENT: it measures and reports. There is no PASS here.")
    if args.expect_timeout is None:
        print("No expected timeout given: the number will be reported and nothing "
              "attributed to it.")
    elif args.expect_timeout == 0:
        # 0 is not a duration with a tolerance around it; it is AT+CIPSTO's
        # "disabled", i.e. the claim that no reap should happen at all.
        print("Expecting NO reap at all (--expect-timeout 0) — SUPPLIED BY YOU, "
              "not read from the module.")
    else:
        print("Expecting %.0f s +/- %.0f s — SUPPLIED BY YOU, not read from the "
              "module." % (args.expect_timeout, tolerance))
    # The minutes are a courtesy for the long waits `AT+CIPSTO` can be set to,
    # and are omitted below two of them: "40 s (1 min)" rounds a number the
    # reader can already see into one that is wrong.
    print("Deadline %.0f s%s of silence.\n"
          % (deadline, " (%.0f min)" % (deadline / 60.0) if deadline >= 120 else ""))
    # SAID UP FRONT, because otherwise it is learned by reading R2 several
    # minutes later. A deadline short of the expectation cannot produce a
    # survival that means anything.
    if args.expect_timeout and deadline <= args.expect_timeout + tolerance:
        print("NOTE: that deadline is not past the expectation, so a survival "
              "here can only be a lower bound.\n")

    conv, ms, why = open_session(args.host, args.port, args.timeout,
                                 "dezogif_ng-idle-drop")
    if conv is None:
        row("R0", NOTE, "no session could be opened, so there was nothing to time")
        detail(why or "no detail")
        print("\nThis is a probe that could not reach its subject, not a finding "
              "about the module. Check, in order: the WiFi ROM is installed; M1 "
              "has been pressed since power-on; the address is the one on the "
              "Next's screen.")
        return 2
    row("R0", MEASURED,
        "CMD_INIT answered in %.0f ms: the session is live, and silence starts now" % ms)

    outcome, seconds, why = wait_for_drop(conv, deadline, args.poll, args.report_every)
    conv.close()

    if outcome == SPOKE:
        row("R1", NOTE,
            "the remote SPOKE unprompted after %.1f s: not a drop, and a finding "
            "of its own" % seconds)
        detail(why)
        detail("Nothing below is a measurement of an idle timeout; re-run.")
    elif outcome == SURVIVED:
        row("R1", MEASURED,
            "still connected after %.0f s of silence: any timeout here exceeds that"
            % seconds)
        detail("A LOWER BOUND, not an absence — only a longer wait can find one.")
    else:
        row("R1", MEASURED,
            "the remote ended the connection after %.1f s of silence" % seconds)
        detail("%s (%s)" % ("a clean close, FIN" if outcome == CLOSED
                            else "a reset, RST", why or "no detail"))

    if outcome != SPOKE:
        status, text, details = compare(outcome, seconds,
                                        args.expect_timeout, tolerance)
        row("R2", status, text)
        for line in details:
            detail(line)

    print("")
    scr, screen_why = read_screen_after(args.host, args.port, args.timeout,
                                        args.screen_attempts)
    report_screen(scr, screen_why, outcome)

    print("""
AT THE MACHINE — what R3-R5 cannot reach:
  * the BORDER. It is not in the display file, so no CMD_READ_MEM can see it.
  * whether anything changed DURING the wait. R3-R5 are one point sample, taken
    after it.
Photograph the screen; it is the only artefact.

WHAT THIS RUN DOES NOT ESTABLISH. It measures WHEN an idle connection ended, not
WHAT ended it — from this side of the module every mechanism that closes an idle
inbound link looks the same, and a match against --expect-timeout is consistency
and not attribution. It cannot see `<id>,CLOSED`, so it cannot say whether the
module announces a reap to the stub; R4 reads only what the stub concluded. One
connection, one module, once. See doc/HARDWARE-TESTING.md.""")
    return 0


if __name__ == "__main__":
    sys.exit(main())
