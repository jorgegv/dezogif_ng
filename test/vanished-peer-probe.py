#!/usr/bin/env python3
"""PROBE B — a peer that goes away with neither FIN nor RST, and what it costs.

NOT INVOKED DIRECTLY. `test/run-vanished-peer.sh` is the entry point: it owns
the firewall chain this writes into, and owns removing it whatever happens.
Read that script's header first — it states every rule that gets added.

THIS IS AN INSTRUMENT, NOT A GATE. It prints numbers and observations. There is
no PASS here, and issue #15 must not be closed on anything it reports.

WHY A FIREWALL RULE IS NECESSARY, AND WHY NOTHING CHEAPER WILL DO.

A slot on the module is freed when the peer says it is going. A `close()` sends
a FIN and says so; an abortive close (`SO_LINGER` 0) sends a RST and says so
harder. **Both were already measured not to leak** — issue #15's E-C ran 12
rounds of connect + RST against a real Next and accept latency stayed flat at
4-12 ms. There is no way from userspace to make a TCP peer simply stop
existing: the kernel always says something on the way out. Blackholing that
last packet is the only mechanism available, and it is why this probe is the
one that needs root.

WHAT VANISHES, EXACTLY. Each doomed connection is bound to a known local port
before it connects. Once it is established and served, a DROP rule for THAT
source port goes into the probe's own chain, and only then is the socket
closed. The FIN is dropped; every retransmission of it is dropped; and when the
kernel eventually gives up and destroys the socket, the RST it would send to
any later segment from the module is dropped too. From the module's side the
peer is simply gone, mid-conversation, for ever.

(If the socket has unread data buffered at close(), Linux sends a RST rather
than a FIN. It makes no difference here: the RST carries the same 5-tuple and
is dropped by the same rule.)

WHY THE RULE STAYS UP UNTIL THE END, and why it is per-source-port because of
that. Lifting it re-enables our own kernel's retransmissions and resets, which
is exactly the news the module needs to free the slot — so the blackhole is the
measurement, not a step in it. A rule scoped to the whole destination port
would blackhole this probe's own later connections and leave nothing to measure
with. Scoped to one source port, one connection vanishes and every other
connection to the same Next keeps working.

THE PHASES.

  0  BASELINE  one ordinary connection, served and closed cleanly. Establishes
               the subject exists and times a connect on a healthy module.
  1  VANISH    repeatedly: open a connection, have it served, blackhole it,
               abandon it — and then ask whether a FRESH ordinary client is
               still served, and how long its connect took. That pair of
               numbers, per vanished peer, is the whole measurement.
  2  LIFT      the blackhole comes down and a fresh client is tried again after
               a wait. WHAT THIS MEANS IS NARROW: taking the rule down lets our
               kernel finally answer the module, so a recovery here says the
               slot comes back once the module is TOLD. It does NOT say the
               module recovers on its own, and it is not a power cycle.

WHAT A RESULT WOULD AND WOULD NOT ESTABLISH.

  * "Service stopped after N vanished peers and did not return" is issue #19
    reproduced, with N measured. It makes the #15-is-#19 hypothesis testable
    rather than plausible. It still does not prove that is what happened to the
    user on 2026-08-05.
  * "Service never stopped" bounds the leak from the other side: it says the
    module tolerates at least that many vanished peers, which weakens the
    hypothesis without refuting it.
  * ACCEPT LATENCY IS THE OTHER HALF, and is the reason every phase-1 step
    times its fresh connect. #15's degradation was 83 ms -> 389 ms -> timeout.
    A ceiling that arrives abruptly and one that is approached through
    lengthening accepts are different findings about the same module.

EXIT CODES. The wrapper passes these through, so they are what a caller sees.

  0  it measured something. THE ONLY ORDINARY OUTCOME — the numbers are the
     result, whatever they are.
  1  the blackhole could not be lifted. The wrapper's EXIT teardown still
     removes the whole chain; this says the measurement is incomplete.
  2  it could not measure at all: not run as root (so run it through the
     wrapper), or nothing answered on the port.
  3  `--expect-ceiling` was passed and the measurement disagreed with it. Only
     the emulator harness ever passes that; against a Next the number is the
     unknown being measured, so 3 is unreachable there by construction.

The wrapper adds its own: 2 for a usage error, 1 for "not root" or for a
teardown that left something behind, 130 on SIGINT and 143 on SIGTERM.
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
import screen  # noqa: E402

SERVED, DROPPED, SILENT, REFUSED = "SERVED", "DROPPED", "SILENT", "REFUSED"
MEASURED, NOTE = "MEAS", "NOTE"

_CODES = {MEASURED: "\033[1;36m", NOTE: "\033[1;33m", SERVED: "\033[1;36m",
          DROPPED: "\033[1;35m", SILENT: "\033[1;31m", REFUSED: "\033[1;31m"}
COLOUR = bool(sys.stdout.isatty()) and not os.environ.get("NO_COLOR")


def paint(status, width=7):
    if not COLOUR:
        return "%-*s" % (width, status)
    return "%s%-*s\033[0m" % (_CODES.get(status, ""), width, status)


def row(tag, status, detail):
    print("  %-4s %s %s" % (tag, paint(status), detail), flush=True)


def detail(text):
    print("         %s" % text, flush=True)


class BoundTransport(dzrp.TcpTransport):
    """A TcpTransport whose local port is known before it connects.

    Knowing the source port is what lets one connection be blackholed while
    every other connection to the same host keeps working. `bind(('', 0))`
    assigns the port immediately, so `getsockname()` is authoritative before
    `connect()` is even called — there is no window in which the rule could be
    written for the wrong port.

    Deliberately does NOT call super().__init__, which would build a socket of
    its own with `create_connection` and leave nothing to bind. Everything else
    — read, write, set_timeout, close — is inherited unchanged, so this cannot
    drift from the transport the rest of the benches use.
    """

    def __init__(self, host, port, timeout):
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(timeout)
        sock.bind(("", 0))
        self.source_port = sock.getsockname()[1]
        self.name = "tcp:%s:%d (from :%d)" % (host, port, self.source_port)
        try:
            sock.connect((host, port))
        except OSError:
            sock.close()
            raise
        self.sock = sock


def serve_check(conv, timeout, name):
    """CMD_INIT on an open conversation. Returns (state, why)."""
    try:
        conv.t.set_timeout(timeout)
        conv.command(dzrp.CMD_INIT, dzrp.init_payload(name=name))
    except dzrp.Timeout as e:
        return SILENT, str(e)
    except dzrp.DzrpError as e:
        if "closed the connection" in str(e):
            return DROPPED, str(e)
        return SILENT, str(e)
    except OSError as e:
        return DROPPED, str(e)
    return SERVED, ""


def open_and_serve(host, port, timeout, name, bound=False):
    """Open one connection and try one CMD_INIT. (state, ms, conv, why).

    `conv` is returned even on SILENT, because a silent connection is still
    holding whatever the module gave it and the caller may want to keep it — or
    to blackhole it, which is this probe's entire subject.
    """
    factory = BoundTransport if bound else dzrp.TcpTransport
    started = time.monotonic()
    try:
        transport = factory(host, port, timeout)
    except OSError as e:
        return REFUSED, (time.monotonic() - started) * 1000.0, None, str(e)
    ms = (time.monotonic() - started) * 1000.0
    conv = dzrp.Dzrp(transport, start_byte=None, base_timeout=timeout)
    state, why = serve_check(conv, timeout, name)
    if state == DROPPED:
        conv.close()
        conv = None
    return state, ms, conv, why


def iptables(*args):
    """One iptables call, as root, raising with its own stderr on failure.

    The chain already exists — run-vanished-peer.sh created it and will remove
    it whatever happens here — so this only ever appends to it or empties it.
    Nothing in this file can add a rule outside that chain, which is what makes
    the shell script's three-command teardown sufficient.
    """
    proc = subprocess.run(["iptables", "-w"] + list(args),
                          capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError("iptables %s failed: %s"
                           % (" ".join(args), (proc.stderr or "").strip()))
    return proc.stdout


def blackhole(chain, host, port, source_port):
    iptables("-A", chain, "-p", "tcp", "-d", host,
             "--sport", str(source_port), "--dport", str(port), "-j", "DROP")


def lift_all(chain):
    """Empty our own chain. The chain itself stays; the shell removes it."""
    iptables("-F", chain)


def trend(times):
    if not times:
        return "nothing was timed"
    body = "min %.0f, median %.0f, max %.0f ms" % (
        min(times), statistics.median(times), max(times))
    if len(times) < 2:
        return body
    return "%s; first %.0f, last %.0f" % (body, times[0], times[-1])


def fresh_client(host, port, timeout, name):
    """An ordinary client, opened and closed cleanly. (state, ms, why)."""
    state, ms, conv, why = open_and_serve(host, port, timeout, name)
    if conv is not None:
        try:
            conv.close()
        except Exception:                       # noqa: BLE001 — teardown only
            pass
    return state, ms, why


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--host", required=True)
    ap.add_argument("--port", type=int, default=11000)
    ap.add_argument("--chain", required=True, help="the iptables chain the wrapper created")
    ap.add_argument("--peers", type=int, default=6)
    ap.add_argument("--recover", type=float, default=20.0)
    ap.add_argument("--timeout", type=float, default=10.0)
    ap.add_argument("--peer-settle", type=float, default=0.5,
                    help="seconds between one iteration's fresh client closing and "
                         "the next doomed peer connecting. A module needs a moment to "
                         "notice a clean close, and a slot counted as still-in-use "
                         "because we did not wait would be measured as a leak")
    ap.add_argument("--expect-ceiling", type=int, default=0,
                    help="only for the emulator harness: exit 3 if the number of "
                         "vanished peers a fresh client survives is not this. NEVER "
                         "pass it for hardware — that number is the unknown")
    args = ap.parse_args()

    if os.geteuid() != 0:
        print("ERROR: run this through test/run-vanished-peer.sh, which is what "
              "owns the firewall chain and its removal.", file=sys.stderr)
        return 2

    print("dezogif_ng vanished-peer probe (B) — tcp:%s:%d" % (args.host, args.port))
    print("Started %s" % time.strftime("%Y-%m-%d %H:%M:%S"))
    print("An INSTRUMENT: it measures and reports. There is no PASS here.\n")

    # --- phase 0 ----------------------------------------------------------
    state, ms, why = fresh_client(args.host, args.port, args.timeout,
                                  "dezogif_ng-vanish-probe")
    if state != SERVED:
        row("B0", NOTE, "the remote did not answer at all (%s): nothing below could run" % state)
        detail(why or "no detail")
        print("\nThis is a probe that could not reach its subject, not a finding about "
              "slots. Check the ROM, the M1 press and the address.")
        return 2
    row("B0", MEASURED, "baseline: an ordinary client was served, connect %.0f ms" % ms)

    # --- phase 1 ----------------------------------------------------------
    print("")
    # THREE COUNTS, NOT ONE, because they answer different questions and an
    # earlier version of this collapsed them into an expression nobody could
    # read. `vanished` is how many peers were really abandoned; `survived` is
    # how many of those a fresh client was still served after; `stopped_at`
    # names what ended the walk, or is None if the --peers budget ran out.
    vanished = 0
    survived = 0
    fresh_times = [ms]
    stopped_at = None

    for i in range(1, args.peers + 1):
        if i > 1:
            time.sleep(args.peer_settle)
        state, ms, conv, why = open_and_serve(
            args.host, args.port, args.timeout,
            "dezogif_ng-doomed-%d" % i, bound=True)

        if conv is None:
            # Never established, or hung up on: there is nothing to abandon, so
            # this is already the ceiling under CLEAN peers and the walk ends.
            row("V%d" % i, state, "connect %.0f ms — %s, so there was nothing to abandon"
                                  % (ms, why or "no detail"))
            stopped_at = (i, state, "the doomed connection itself was not granted")
            break

        source_port = conv.t.source_port
        if state != SERVED:
            detail("peer %d connected but was not served (%s); blackholing it anyway"
                   % (i, state))
        try:
            blackhole(args.chain, args.host, args.port, source_port)
        except RuntimeError as e:
            row("V%d" % i, NOTE, "could not install the blackhole: %s" % e)
            conv.close()
            stopped_at = (i, "NOFIREWALL", str(e))
            break

        # ONLY NOW. Closing before the rule is in place lets the FIN out, and a
        # FIN is exactly the news that frees the slot — the probe would then be
        # measuring a clean disconnect, which is already known to be harmless.
        conv.close()
        vanished += 1

        fstate, fms, fwhy = fresh_client(args.host, args.port, args.timeout,
                                         "dezogif_ng-after-%d" % i)
        fresh_times.append(fms)
        if fstate == SERVED:
            survived += 1
            row("V%d" % i, SERVED,
                "peer %d vanished (from :%d); a fresh client was still served, connect %.0f ms"
                % (i, source_port, fms))
        else:
            row("V%d" % i, fstate,
                "peer %d vanished (from :%d); a fresh client got %s after %.0f ms"
                % (i, source_port, fstate, fms))
            detail(fwhy or "no detail")
            stopped_at = (i, fstate, fwhy)
            break

    if stopped_at and stopped_at[1] in (SERVED, DROPPED, SILENT, REFUSED):
        row("B1", MEASURED,
            "fresh clients were served after %d vanished peers; the next one stopped them"
            % survived)
    elif stopped_at:
        row("B1", NOTE,
            "the walk ended early after %d vanished peers, for a reason outside its subject"
            % vanished)
    else:
        row("B1", MEASURED,
            "%d peers vanished and a fresh client was served after every one of them"
            % vanished)

    row("B2", MEASURED, "fresh-client accept latency, %d connects: %s"
                        % (len(fresh_times), trend(fresh_times)))

    # --- phase 2 ----------------------------------------------------------
    print("")
    try:
        lift_all(args.chain)
    except RuntimeError as e:
        row("B3", NOTE, "could not lift the blackhole: %s" % e)
        print("\nThe wrapper's EXIT teardown still removes the whole chain.")
        return 1

    detail("blackhole lifted; waiting %.0f s before asking again" % args.recover)
    time.sleep(args.recover)
    rstate, rms, rwhy = fresh_client(args.host, args.port, args.timeout,
                                     "dezogif_ng-recovered")
    if rstate == SERVED:
        row("B3", MEASURED,
            "with the blackhole down and %.0f s elapsed, a fresh client was served in %.0f ms"
            % (args.recover, rms))
        detail("READ THIS NARROWLY: lifting the rule lets our kernel answer the "
               "module, which is news arriving from outside. It is not the module "
               "recovering on its own.")
    else:
        row("B3", MEASURED,
            "with the blackhole down and %.0f s elapsed, a fresh client still got %s"
            % (args.recover, rstate))
        detail(rwhy or "no detail")
        detail("Nothing the PC can do reaches it. That is issue #15's row 6, and a "
               "power cycle is the next thing to try — record whether it fixes it.")

    # Leave the Next's screen saying the session is closed (issue #14), the
    # same courtesy hardware-check.py pays. Not a check; it adds no row.
    #
    # The screen is read BEFORE the CMD_CLOSE on this same connection: cmd_close
    # answers and then leaves through `jp main`, which repaints, so a read
    # afterwards would be of a screen this teardown had just changed.
    #
    # WHY THERE IS ONLY ONE READING HERE, WHERE PROBE A HAS TWO. The moment
    # worth seeing is phase 1's — a fresh client being refused — and at that
    # moment this probe holds NOTHING it could read over: every doomed peer is
    # behind the blackhole and every fresh client is opened and closed inside
    # `fresh_client`. Opening a connection there would take one of the very
    # slots being exhausted and move the number the probe exists to measure. So
    # the reading is taken at the end, where the slot is spent after the
    # counting rather than during it, and phase 1's screen stays a human's job.
    try:
        conv = dzrp.Dzrp(dzrp.TcpTransport(args.host, args.port, args.timeout),
                         start_byte=None, base_timeout=args.timeout)
        row("B4", MEASURED, screen.observe(conv))
        detail("read at teardown, after phase 2; see the note about phase 1 in the source")
        dzrp.send_close_quietly(conv)
    except (OSError, dzrp.DzrpError) as e:
        print("  (teardown: could not send CMD_CLOSE: %s)" % e)

    print("""
AT THE MACHINE — what B4 still cannot reach:
  * the ERROR AREA WHILE FRESH CLIENTS ARE BEING REFUSED. B4 reads it at the
    END, after phase 2 lifted the blackhole; reading it during phase 1 would
    cost one of the slots being counted. That moment is still the load-bearing
    one for the #15-is-#19 hypothesis, and it is still yours to watch.
  * the BORDER. It is not in the display file, so no CMD_READ_MEM can see it:
    moving, or frozen, and at what colour.
  * WHETHER the screen changed DURING the run. B4 is one point sample.
Photograph it, and say what it looked like BEFORE and AFTER.""")

    print("""
WHAT THIS RUN DOES NOT ESTABLISH. It shows what a vanished peer costs, not that
a vanished peer is what happened on 2026-08-05. Phase 2's recovery, if any, is
the module being TOLD the peers are gone, not the module healing. Issue #15
must not be closed on this. See doc/HARDWARE-TESTING.md.""")

    if args.expect_ceiling:
        if survived == args.expect_ceiling:
            print("\nInstrument check: fresh clients survived %d vanished peers, as "
                  "expected for this remote." % survived)
        else:
            print("\nInstrument check FAILED: fresh clients survived %d vanished "
                  "peers, expected %d." % (survived, args.expect_ceiling))
            return 3
    return 0


if __name__ == "__main__":
    sys.exit(main())
