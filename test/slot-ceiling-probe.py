#!/usr/bin/env python3
"""PROBE A — how many clients the module will hold, and whether a close gives one back.

    make probe-slots NEXT_IP=192.168.1.42        # a real Next
    make probe-jnext                             # the emulator, to validate this

THIS IS AN INSTRUMENT, NOT A GATE. It prints numbers and observations and it
does not render a verdict, because issue #15's trigger is unknown and a probe
that said PASS or FAIL would be asserting a conclusion nobody has. It is not
part of `make test` and must not become part of it.

WHAT IT IS FOR.

Issue #15 is a real Next that stopped serving anyone until it was power-cycled.
Its signature has two halves and only one of them is explained. The CRLF swallow
band fixed in build 000E accounts for the `RX Timeout`, the frozen border and the
hung client. It does NOT account for the power cycle — a swallowed command is
transient — nor for the accept latency that was measured degrading at the time,
**83 ms, then 389 ms, then a timeout**. That degradation is on the MODULE's side
of the UART: the Z80 does not accept TCP connections and cannot make one slow.

Issue #19 says the module holds a small number of inbound connections, drops
anything past them, and that **nothing in the stub ever frees one** — the fix
would be `AT+CIPCLOSE=<id>`, which is not written because jnext cannot model it.
A power cycle is the only thing in the system today that reclaims a slot. That
fits the unexplained half exactly: stub healthy, screen intact, TCP degrading and
then refusing, recoverable only by pulling the plug.

So the hypothesis under test is that **#15 IS #19**, and this probe measures the
one number that hypothesis rests on: how many clients the module will hold.

WHAT IT DOES, in three phases.

  0  BASELINE   one connection, with retries, to establish the remote is there
                and to time a connect on an empty module. Closed again.
  1  WALK       connections opened ONE AT A TIME and HELD OPEN, each given a
                CMD_INIT. Single attempt each, no retries: a connection that
                needed three goes is the signal, not noise to be smoothed away.
                At the first one that is not served, the EARLIEST STILL-OPEN
                connection is asked whether it still answers.
  2  RECLAIM    every held connection closed cleanly, then fresh ones opened.
                Whether service returns says whether a clean close frees a slot.

THE EARLIER-CONNECTION QUESTION IS THE WHOLE POINT OF PHASE 1, and without it
this probe would be worth very little. "The fifth client got nothing" has two
completely different causes:

  * the MODULE is full — it has no slot to give, so the stub never hears about
    that client at all. An earlier connection still answers, because the stub is
    perfectly healthy and is still being handed `+IPD` from the connections it
    already has.
  * the STUB is wedged — it is not reading anything, so nobody is answered.
    The earlier connection goes quiet too.

Those look identical from the client that got nothing, which is exactly the
position issue #15 was reported from. One extra exchange separates them.

THE FOUR OUTCOMES A CONNECTION CAN HAVE, and they are not interchangeable:

  SERVED    connect completed and CMD_INIT was answered.
  DROPPED   connect completed and the peer then closed it with no DZRP reply.
            This is what a module out of slots looks like: it accepts at the TCP
            layer and hangs up. jnext does exactly this (esp_at.cpp:894-902).
  SILENT    connect completed, the socket stayed open, nothing came back inside
            the timeout. NOT the same as DROPPED — this is what a wedged stub
            would look like, or a module that took the connection and never
            reported it.
  REFUSED   connect() itself failed. No listener, or the backlog was full.

WHAT THIS PROBE CANNOT ESTABLISH, and none of it is hidden:

  * It cannot see connection IDs. They are consumed by the stub, and what
    reaches this script is DZRP frames with the id already stripped. So it
    measures HOW MANY slots there are and never WHICH ones.
  * It cannot make a peer vanish. Every connection it opens is closed cleanly
    by the kernel, and a clean close is measured NOT to leak (issue #15's
    E-C: 12 rounds of abortive RST, accept latency flat at 4-12 ms). Producing
    a slot that is never given back is PROBE B's job, and B is the half of this
    pair that can actually reproduce #19.
  * It cannot reproduce #15. Finding a ceiling proves a ceiling exists; it does
    not prove the ceiling is what a real user hit on 2026-08-05.
  * It cannot read the Next's screen. See the checklist it prints.

EXIT CODE. 0 when it measured something, 2 when it could not measure at all
(nothing listening). Never 1: there is no failure for it to report.
"""

import argparse
import os
import re
import socket
import statistics
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "dzrp"))

import dzrp  # noqa: E402

# Connection outcomes. See the module docstring: these are four different
# findings and collapsing any two of them would destroy the probe's only
# discriminator.
SERVED, DROPPED, SILENT, REFUSED = "SERVED", "DROPPED", "SILENT", "REFUSED"

MEASURED, NOTE = "MEAS", "NOTE"

# Colour, on the same terms as hardware-check.py: a terminal, and NO_COLOR
# unset. Nothing here is green, because nothing here is a pass.
_ANSI = re.compile(r"\033\[[0-9;]*m")
_CODES = {MEASURED: "\033[1;36m", NOTE: "\033[1;33m",
          SERVED: "\033[1;36m", DROPPED: "\033[1;35m",
          SILENT: "\033[1;31m", REFUSED: "\033[1;31m"}
COLOUR = bool(sys.stdout.isatty()) and not os.environ.get("NO_COLOR")


def paint(status, width=5):
    if not COLOUR:
        return "%-*s" % (width, status)
    return "%s%-*s\033[0m" % (_CODES.get(status, ""), width, status)


class Report:
    """The probe's own output, and the machine-readable record behind it.

    Rows are printed as they land — a run against hardware takes tens of
    seconds and a reader watching it should see the walk happen rather than a
    wall of text at the end. `rows` is kept so the summary can be DERIVED: the
    headless bench once hardcoded its own totals and went on printing them
    after a check was added (MEMORY.md), and a probe that mis-states its own
    ceiling would be worse than one that does not print it.
    """

    def __init__(self):
        self.rows = []

    def add(self, tag, status, detail):
        self.rows.append((tag, status, detail))
        print("  %-4s %s %s" % (tag, paint(status), detail), flush=True)

    def detail(self, text):
        print("       %s" % text, flush=True)


def open_one(host, port, timeout, name):
    """One connection attempt with NO retries. Returns (state, ms, conv, why).

    `conv` is the live Dzrp conversation when the state is SERVED, and None
    otherwise — a caller that holds it is holding the module's slot open, which
    is the whole mechanism of phase 1.

    THE ABSENCE OF A RETRY IS DELIBERATE and is the opposite of what
    hardware-check.py's `connect()` does. That function retries because its
    checks are about DZRP correctness and a transient must not be reported as a
    protocol failure. This probe's subject IS the transient: whether a
    connection is granted, and how long it took, is the measurement.
    """
    started = time.monotonic()
    try:
        transport = dzrp.TcpTransport(host, port, timeout)
    except OSError as e:
        return REFUSED, (time.monotonic() - started) * 1000.0, None, str(e)
    ms = (time.monotonic() - started) * 1000.0

    conv = dzrp.Dzrp(transport, start_byte=None, base_timeout=timeout)
    try:
        conv.command(dzrp.CMD_INIT, dzrp.init_payload(name=name))
    except dzrp.Timeout as e:
        # Left OPEN on purpose. A silent connection still occupies whatever the
        # module gave it, and closing it here would quietly undo the state the
        # next attempt is supposed to meet.
        return SILENT, ms, conv, str(e)
    except dzrp.DzrpError as e:
        conv.close()
        if "closed the connection" in str(e):
            return DROPPED, ms, None, str(e)
        return SILENT, ms, None, str(e)
    except OSError as e:
        # A reset arriving during the exchange: the peer hung up hard. Same
        # finding as DROPPED — the connection was not honoured — and the text
        # says which form it took.
        conv.close()
        return DROPPED, ms, None, str(e)
    return SERVED, ms, conv, ""


def still_answers(conv, timeout):
    """Does an already-established connection still get replies? (ok, why)."""
    payload = bytes([0x5A]) * 8
    try:
        conv.t.set_timeout(timeout)
        body = conv.command(dzrp.CMD_LOOPBACK, payload)
    except (OSError, dzrp.DzrpError) as e:
        return False, str(e)
    if body != payload:
        return False, "loopback returned %d bytes, not its own payload" % len(body)
    return True, ""


def close_all(conns):
    for conv in conns:
        try:
            conv.close()
        except Exception:                       # noqa: BLE001 — teardown only
            pass


def trend(times):
    """min/median/max plus the first-to-last change, as one short clause.

    The CHANGE is the part issue #15 cares about. The reported degradation was
    83 ms -> 389 ms -> timeout, so a probe that printed only a median would
    average away the one shape it was built to look for.
    """
    if not times:
        return "no connects were timed"
    body = "min %.0f, median %.0f, max %.0f ms" % (
        min(times), statistics.median(times), max(times))
    if len(times) < 2:
        return body
    return "%s; first %.0f, last %.0f" % (body, times[0], times[-1])


def baseline(host, port, timeout, attempts, report):
    """Phase 0. Is anything there at all, and what does an idle connect cost?

    Retried, unlike phase 1: this one is establishing that the instrument has a
    subject, and giving up on a single jitter spike would report a working Next
    as an absent one. Returns True when the walk may proceed.
    """
    last = ""
    for i in range(attempts):
        state, ms, conv, why = open_one(host, port, timeout, "dezogif_ng-slot-probe")
        if state == SERVED:
            close_all([conv])
            report.add("A0", MEASURED,
                       "the remote answered CMD_INIT on an idle module, connect %.0f ms"
                       % ms)
            if i:
                report.detail("(that took %d attempts; a retry here is itself a finding)"
                              % (i + 1))
            return True
        last = "%s — %s" % (state, why)
        time.sleep(0.5)
    report.add("A0", NOTE,
               "nothing usable on %s:%d after %d attempts: %s" % (host, port, attempts, last))
    return False


def walk(host, port, timeout, limit, report):
    """Phase 1. Open and HOLD connections until one is not served.

    Returns (held, times, first_bad) — the live conversations, the connect
    times of every attempt including the failed one, and (index, state, why)
    for the attempt that stopped the walk, or None if the limit was reached
    with everything still being served.
    """
    held, times, first_bad = [], [], None

    for i in range(1, limit + 1):
        state, ms, conv, why = open_one(
            host, port, timeout, "dezogif_ng-slot-probe-%d" % i)
        times.append(ms)

        if state == SERVED:
            held.append(conv)
            report.add("#%d" % i, SERVED,
                       "connect %.0f ms, CMD_INIT answered, held open" % ms)
            continue

        # THE SECOND ATTEMPT IS A CONTROL, not a retry. A ceiling is a
        # persistent property of the module; a transient is not. Without this,
        # one unlucky packet would be reported as the answer to the question
        # this whole probe exists to ask. Same shape as H3's delayed retry.
        report.add("#%d" % i, state, "connect %.0f ms — %s" % (ms, why or "no detail"))
        report.detail("retrying once after 2 s, to separate a ceiling from a transient")
        time.sleep(2.0)
        state2, ms2, conv2, why2 = open_one(
            host, port, timeout, "dezogif_ng-slot-probe-%dr" % i)
        times.append(ms2)
        if state2 == SERVED:
            held.append(conv2)
            report.add("#%dr" % i, SERVED,
                       "connect %.0f ms, answered on the retry: that was a transient, not a ceiling"
                       % ms2)
            continue

        if conv2 is not None:
            close_all([conv2])
        report.add("#%dr" % i, state2,
                   "connect %.0f ms — %s: the same answer twice" % (ms2, why2 or "no detail"))
        first_bad = (i, state2, why2)
        break

    return held, times, first_bad


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--host", required=True, help="the Next's IP address, or 127.0.0.1 for jnext")
    ap.add_argument("--port", type=int, default=11000)
    ap.add_argument("--timeout", type=float, default=10.0,
                    help="seconds per DZRP exchange; generous, a WiFi link is not localhost")
    ap.add_argument("--limit", type=int, default=8,
                    help="stop after this many connections even if all are served")
    ap.add_argument("--reopen", type=int, default=2,
                    help="fresh connections to try in the reclaim phase")
    ap.add_argument("--settle", type=float, default=2.0,
                    help="seconds between closing the held connections and reopening")
    ap.add_argument("--baseline-attempts", type=int, default=6)
    ap.add_argument("--expect-ceiling", type=int, default=0,
                    help="only for the emulator harness: exit 3 if the measured "
                         "ceiling is not this. NEVER pass it for hardware — the "
                         "hardware number is the unknown being measured")
    args = ap.parse_args()

    print("dezogif_ng slot-ceiling probe (A) — tcp:%s:%d" % (args.host, args.port))
    print("Started %s" % time.strftime("%Y-%m-%d %H:%M:%S"))
    print("An INSTRUMENT: it measures and reports. There is no PASS here.\n")

    report = Report()
    if not baseline(args.host, args.port, args.timeout, args.baseline_attempts, report):
        print("\nNothing answered, so nothing below could run. This is a probe that "
              "could not reach its subject, not a finding about slots.")
        print("Check, in order: the WiFi ROM is installed; M1 has been pressed since "
              "power-on; the address is the one on the Next's screen.")
        return 2

    print("")
    held, times, first_bad = walk(args.host, args.port, args.timeout, args.limit, report)
    ceiling = len(held)

    # --- the discriminator ------------------------------------------------
    #
    # Asked ONLY when the walk stopped. With everything served there is nobody
    # being refused, so there is nothing to discriminate and asking would
    # produce a reassuring line about a question that was never posed.
    if first_bad and held:
        ok, why = still_answers(held[0], args.timeout)
        if ok:
            report.add("A1", MEASURED,
                       "connection 1 still answered while connection %d got nothing: "
                       "the stub is alive" % first_bad[0])
        else:
            report.add("A1", MEASURED,
                       "connection 1 stopped answering too (%s): this is the stub, "
                       "not the module" % why)
    elif first_bad:
        report.add("A1", NOTE,
                   "the very first connection was not served, so there is no earlier "
                   "one to ask")
    else:
        report.add("A1", NOTE,
                   "every connection up to the --limit of %d was served: no ceiling "
                   "was reached" % args.limit)

    if first_bad:
        report.add("A2", MEASURED,
                   "%d connections held open at once; number %d came back %s"
                   % (ceiling, first_bad[0], first_bad[1]))
    else:
        report.add("A2", MEASURED,
                   "%d connections held open at once and none was refused" % ceiling)

    # --- reclaim ----------------------------------------------------------
    close_all(held)
    time.sleep(args.settle)

    reopened, reopen_times = 0, []
    for i in range(args.reopen):
        state, ms, conv, why = open_one(
            args.host, args.port, args.timeout, "dezogif_ng-slot-probe-r%d" % i)
        reopen_times.append(ms)
        if state == SERVED:
            reopened += 1
            close_all([conv])
        else:
            report.detail("reopen %d: %s — %s" % (i + 1, state, why or "no detail"))
            if conv is not None:
                close_all([conv])

    if reopened == args.reopen:
        report.add("A3", MEASURED,
                   "after closing all %d cleanly, %d of %d fresh connections were served"
                   % (ceiling, reopened, args.reopen))
    else:
        report.add("A3", MEASURED,
                   "after closing all %d cleanly, only %d of %d fresh connections were "
                   "served" % (ceiling, reopened, args.reopen))

    report.add("A4", MEASURED, "accept latency, %d connects: %s" % (len(times), trend(times)))
    if reopen_times:
        report.detail("reclaim phase connects: %s" % trend(reopen_times))

    # Leave the machine's screen saying the session is closed rather than
    # whatever the last CMD_INIT claimed — issue #14's status line, and the same
    # courtesy hardware-check.py pays. Not a check; it adds no row.
    try:
        conv = dzrp.Dzrp(dzrp.TcpTransport(args.host, args.port, args.timeout),
                         start_byte=None, base_timeout=args.timeout)
        dzrp.send_close_quietly(conv)
    except (OSError, dzrp.DzrpError) as e:
        print("  (teardown: could not send CMD_CLOSE: %s)" % e)

    print("""
AT THE MACHINE — this probe cannot see any of it, and all three matter:
  * the ERROR AREA (bottom rows, red on black). Clean while TCP degrades is the
    load-bearing observation: it says the stub is not faulting, so whatever is
    refusing connections is on the module's side of the UART.
  * the BORDER. Moving means the stub is still cycling; frozen yellow means it
    is parked in a read.
  * the SESSION LINE. "Session opened (CMD_INIT)" after this run is expected —
    every connection above sent one.
Photograph it, and say whether anything changed DURING the run.""")

    print("""
WHAT THIS RUN DOES NOT ESTABLISH. A ceiling found here is a ceiling under
CLEANLY CLOSED connections, which are measured not to leak. It is not a
reproduction of issue #15, and #15 must not be closed on it. Probe B is the
half that abandons a peer without FIN or RST; see doc/HARDWARE-TESTING.md.""")

    if args.expect_ceiling:
        if ceiling == args.expect_ceiling:
            print("\nInstrument check: measured ceiling %d, as expected for this remote."
                  % ceiling)
        else:
            print("\nInstrument check FAILED: measured ceiling %d, expected %d."
                  % (ceiling, args.expect_ceiling))
            return 3
    return 0


if __name__ == "__main__":
    sys.exit(main())
