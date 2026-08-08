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
  2  RECOVER   a fresh client is tried once more after a wait. WHAT THAT MEANS
               DEPENDS ENTIRELY ON --no-lift, and the two readings are
               opposites rather than shades of one claim:

               default     the blackhole comes DOWN first, so our own kernel
                           finally answers the module's retransmissions. A
                           recovery here says the slot comes back once the
                           module is TOLD. It does NOT say the module recovers
                           on its own, and it is not a power cycle.
               --no-lift   the blackhole STAYS UP, so no FIN, no RST and no
                           retransmission of ours ever reaches the module about
                           those peers. A recovery here is the module
                           reclaiming a slot UNPROMPTED — which is what an
                           enforced AT+CIPSTO idle timeout would look like from
                           here. See below for what it still does not say.

--no-lift, AND THE THREE THINGS IT DOES NOT ESTABLISH EVEN WHEN IT RECOVERS.

The reason to have it is that the default path cannot ask the question at all:
it hands the module the news first and then measures the answer. With the rule
left up, anything that frees a slot came from the module's side.

  * It does not say WHICH slot came back, or that the oldest peer's did. No
    PC-side check can see connection ids — that limit is everywhere in this
    project and it applies here too.
  * It does not say WHAT freed it. An idle timeout on the module is the
    hypothesis; the stub's own esp_recover sweep (issue #19) is a second
    mechanism, and although a vanished peer is traced to raise no fault and so
    to trigger no sweep, this probe cannot OBSERVE that it did not. B4's error
    area is the nearest thing to a check on it.
  * IT CANNOT SEE `<id>,CLOSED`, and no probe on this side ever will. That line
    is the module talking to the Z80 over the UART; this is a TCP client on the
    other side of the module, so whether a reaped connection announces itself
    that way is NOT DETERMINABLE from anything here — not from a recovery, and
    not from its absence. It matters to issue #23, whose subject is watching
    for that line, and the honest answer is that it needs the stub's own eyes
    or a real module, never this. Nothing is claimed about it either way.
  * It says nothing at all unless the ceiling was actually reached in phase 1.
    A fresh client served after a walk that never ran out of slots is a client
    taking a slot that was free the whole time. The B3 reading below branches
    on that, AND SO DOES THE CLOSING PARAGRAPH — which asserted a reclaim
    unconditionally in the first version of this flag and printed it on a run
    that had none, under a B3 that had reported the refusal correctly.
  * "No ceiling was observed" is NOT "the module never ran out", and one stop
    makes the difference visible. A walk that ends on `NOFIREWALL` — our own
    iptables call failing — leaves `ceiling_hit` false having stopped LOOKING
    rather than having looked and found none. B1 has always reported that stop
    as outside its subject; B3's wording is written to cover both causes
    without claiming the stronger one.

THE CLOCK --recover IS MEASURED FROM, which is not the same moment on the two
paths. Peers are made to vanish ONE AT A TIME, so peer 1 has been silent for
the whole length of the walk by the time the last one is abandoned. On the
--no-lift path the wait therefore runs from the LAST peer going silent, so that
every peer has had at least --recover seconds; on the default path it runs from
the lift, unchanged, because there the thing being timed is how long the module
takes to act on news it has just been given. B5 reports the spread either way,
because a walk longer than the module's idle timeout could free a slot DURING
phase 1 and inflate the ceiling — on both paths.

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
     UNREACHABLE under --no-lift, which never lifts anything — the chain then
     comes down only in that same teardown, which runs whatever happens.
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
    ap.add_argument("--no-lift", action="store_true",
                    help="do NOT take the blackhole down before phase 2's wait. The "
                         "rules stay in place until the wrapper's teardown, so nothing "
                         "of ours ever tells the module the peers are gone — which is "
                         "what makes a recovery there the MODULE reclaiming a slot "
                         "rather than the module being told. The wait then runs from "
                         "the LAST peer going silent, not from now")
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
    # WHEN EACH PEER STOPPED BEING ABLE TO REACH THE MODULE, one entry per peer
    # really abandoned. It is what B5 and --no-lift's wait are computed from,
    # and it exists because the peers vanish ONE AT A TIME: peer 1 is already
    # ageing while peer 4 is still being connected, so "the walk" is not one
    # moment and a module that reclaims on a timer could act inside it.
    #
    # Taken at the close rather than at the CMD_INIT, which is the SAFE
    # direction and not merely the convenient one. The module last HEARD from
    # this peer a few tens of milliseconds earlier, when its CMD_INIT arrived,
    # so any idle timer on its side is fractionally AHEAD of what we record —
    # i.e. we under-report the age and wait fractionally longer than we claim.
    silent_at = []

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
        silent_at.append(time.monotonic())

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

    walk_end = time.monotonic()
    # DID THE MODULE ACTUALLY RUN OUT? Everything phase 2 can claim rests on
    # this. `NOFIREWALL` is the one stop that is not the module refusing
    # anybody — the walk ended for a reason outside its own subject.
    ceiling_hit = stopped_at is not None and stopped_at[1] != "NOFIREWALL"

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

    # B5 IS NUMBERED AFTER B4 AND PRINTED BEFORE B3, deliberately: check ids are
    # interface here (they are cited in doc/HARDWARE-TESTING.md and in issues)
    # so an id may not be reused or renumbered to suit print order. The row
    # belongs with phase 1's numbers, which is where it is printed.
    #
    # WHY IT IS A ROW AND NOT PROSE. The ceiling B1 reports is only a ceiling if
    # nothing gave a slot back while it was being measured, and the peers age
    # one after another. Against a module with an idle timeout — AT+CIPSTO — a
    # walk that took longer than that timeout could free peer 1's slot before
    # the last peer was even connected, and B1 would report a ceiling nobody
    # observed. These two numbers are what let a reader rule that out, and they
    # are printed on BOTH paths because the hazard belongs to phase 1 rather
    # than to phase 2's flag.
    if not silent_at:
        row("B5", NOTE, "no peer was abandoned, so there is no ageing to report")
    elif len(silent_at) == 1:
        row("B5", MEASURED,
            "one peer vanished; it had been silent %.0f s when the walk ended"
            % (walk_end - silent_at[0]))
    else:
        row("B5", MEASURED,
            "at the walk's end the oldest vanished peer had been silent %.0f s, the newest %.0f s"
            % (walk_end - silent_at[0], walk_end - silent_at[-1]))
        detail("Compare the first figure against the module's idle timeout "
               "(AT+CIPSTO). If the walk outlasted it, a slot may have been freed "
               "during phase 1 and B1's ceiling is not one.")

    # --- phase 2 ----------------------------------------------------------
    print("")
    if args.no_lift:
        # NOTHING IS LIFTED HERE. The DROP rules stay in the chain and the
        # wrapper's EXIT teardown removes them, exactly as it does on every
        # other path — that teardown is unconditional and is not touched by
        # this flag. What the flag buys is that no FIN, no RST and no
        # retransmission of ours reaches the module ABOUT THE ABANDONED PEERS —
        # our fresh clients still open and close normally, and their FINs do
        # reach it — so anything that frees one of THOSE slots came from the
        # module's own side.
        #
        # AND THE WAIT RUNS FROM THE LAST PEER, not from now and not from the
        # start of the run. Timing it from here would give the last peer
        # --recover seconds and every earlier one more, which is the direction
        # that cannot report a false recovery; timing it from the START of the
        # walk would give the last peer LESS than --recover, which is the
        # direction that can.
        if silent_at:
            elapsed = time.monotonic() - silent_at[-1]
            wait = max(0.0, args.recover - elapsed)
            detail("blackhole STILL UP. The last peer has been silent %.0f s; waiting "
                   "%.0f s more to make that %.0f s."
                   % (elapsed, wait, max(elapsed, args.recover)))
        else:
            wait = args.recover
            detail("blackhole STILL UP. No peer was abandoned, so this waits %.0f s "
                   "from now and there is nothing ageing." % wait)
        time.sleep(wait)
    else:
        try:
            lift_all(args.chain)
        except RuntimeError as e:
            row("B3", NOTE, "could not lift the blackhole: %s" % e)
            print("\nThe wrapper's EXIT teardown still removes the whole chain.")
            return 1

        detail("blackhole lifted; waiting %.0f s before asking again" % args.recover)
        time.sleep(args.recover)

    attempt = time.monotonic()
    rstate, rms, rwhy = fresh_client(args.host, args.port, args.timeout,
                                     "dezogif_ng-recovered")

    # DID THIS RUN ACTUALLY SEE A RECLAIM? Computed ONCE, here, and consulted
    # by both B3 below and the closing paragraph at the end of this function.
    #
    # It is a variable rather than a condition repeated in two places because
    # the first version of this branch DID repeat it — and got the second copy
    # wrong, printing "a recovery in phase 2 IS the module reclaiming
    # unprompted" as an unconditional sentence, eight lines under a B3 that had
    # correctly reported a REFUSED client. It shipped that way on the user's
    # own hardware run. Two renderings of one fact drifting apart is this
    # project's most-repeated failure, and the paragraph it happened in exists
    # precisely to stop a reader over-reading the result.
    #
    # All three conjuncts are load-bearing. A served client is a reclaim only
    # if the module really ran out (`ceiling_hit`) of slots this run really
    # abandoned (`silent_at`); otherwise it took a slot nobody was holding.
    reclaimed = args.no_lift and rstate == SERVED and ceiling_hit and bool(silent_at)

    if args.no_lift:
        if silent_at:
            where = ("blackhole still UP, last peer silent %.0f s"
                     % (attempt - silent_at[-1]))
        else:
            where = "nothing was ever blackholed"
        if rstate == SERVED:
            row("B3", MEASURED,
                "%s: a fresh client was served in %.0f ms" % (where, rms))
            # THREE READINGS, AND ONLY ONE OF THEM IS THE HEADLINE.
            if reclaimed:
                # "ABOUT THOSE PEERS" IS NOT PADDING, and the unqualified form
                # of this line was literally false: `fresh_client` opens and
                # cleanly closes a connection after every vanished peer, so our
                # FINs certainly do reach the module during the run. What the
                # per-source-port rules guarantee is narrower and is the whole
                # claim — nothing of ours reaches it about the ABANDONED ones.
                detail("THE MODULE FREED A SLOT UNPROMPTED: the rule never came down, "
                       "so no FIN, RST or retransmission of ours reached it ABOUT THOSE "
                       "PEERS. Something on the module's own side let one go.")
                detail("It does NOT say which slot, or what freed it — an idle timeout "
                       "is the hypothesis, the stub's own sweep is a second one, and no "
                       "PC-side check can see connection ids.")
            elif not ceiling_hit:
                # COVERS TWO CAUSES, and the second is weaker than it sounds:
                # the walk either served every peer, or ended early because our
                # own tooling broke (`NOFIREWALL`) and stopped looking. "No
                # ceiling was observed" is true of both; "the module never ran
                # out" is only true of the first, and claiming it would assert
                # a negative this run did not go far enough to earn.
                detail("READ NOTHING INTO THIS: phase 1 never SAW the module run out — "
                       "it either served throughout, or the walk ended early and stopped "
                       "looking. With no ceiling observed, nothing here is a reclaim.")
            else:
                detail("READ NOTHING INTO THIS: the module was already refusing before "
                       "this run abandoned anybody, so whatever was holding those slots "
                       "was not ours and this says nothing about a vanished peer.")
        else:
            row("B3", MEASURED,
                "%s: a fresh client still got %s" % (where, rstate))
            detail(rwhy or "no detail")
            detail("Within this wait the module reclaimed nothing by itself. That is a "
                   "LOWER BOUND on any idle timer it may have, not evidence that it has "
                   "none — wait longer before concluding otherwise.")
    elif rstate == SERVED:
        row("B3", MEASURED,
            "with the blackhole down and %.0f s elapsed, a fresh client was served in %.0f ms"
            % (args.recover, rms))
        detail("READ THIS NARROWLY: lifting the rule lets our kernel answer the "
               "module, which is news arriving from outside. It is not the module "
               "recovering on its own — pass --no-lift to ask that instead.")
    else:
        row("B3", MEASURED,
            "with the blackhole down and %.0f s elapsed, a fresh client still got %s"
            % (args.recover, rstate))
        detail(rwhy or "no detail")
        detail("Nothing the PC can do reaches it. That is issue #15's row 6, and a "
               "power cycle is the next thing to try — record whether it fixes it.")

    # Leave the Next's screen saying the session is closed (issue #14), the
    # same courtesy hardware-check.py pays. THE CMD_CLOSE is not a check and
    # renders no verdict; B4 below is a MEASURED row, like everything else this
    # probe prints.
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
    END, after phase 2's wait; reading it during phase 1 would cost one of the
    slots being counted. That moment is still the load-bearing one for the
    #15-is-#19 hypothesis, and it is still yours to watch. Note that with the
    module refusing everybody, B4's own connection is refused too and the row
    does not print at all — so on a run that ends refused, the screen is the
    ONLY place the answer exists.
  * the BORDER. It is not in the display file, so no CMD_READ_MEM can see it:
    moving, or frozen, and at what colour.
  * WHETHER the screen changed DURING the run. B4 is one point sample.
Photograph it, and say what it looked like BEFORE and AFTER.""")

    # BRANCHED ON WHAT HAPPENED, not on which flag was passed. See `reclaimed`
    # above for why that distinction cost a review round.
    if reclaimed:
        print("""
WHAT THIS RUN DOES NOT ESTABLISH. It shows what a vanished peer costs, not that
a vanished peer is what happened on 2026-08-05. The blackhole stayed UP and a
fresh client was served after the module had run out, so THIS run's recovery is
the module reclaiming unprompted — but it does not say WHICH slot came back, or
WHAT freed it, and no reading here can rule out the stub's own sweep. Issue #15
must not be closed on this. See doc/HARDWARE-TESTING.md.""")
    elif args.no_lift:
        print("""
WHAT THIS RUN DOES NOT ESTABLISH. It shows what a vanished peer costs, not that
a vanished peer is what happened on 2026-08-05. The blackhole stayed UP, so
nothing of ours told the module its peers were gone — and NO RECLAIM WAS SEEN:
either no client was served at the end, or no ceiling was ever observed for one
to be reclaimed from. B3 above says which. A run that ends unrecovered is a
LOWER BOUND on any idle timer the module may have, never evidence it has none.
Issue #15 must not be closed on this. See doc/HARDWARE-TESTING.md.""")
    else:
        print("""
WHAT THIS RUN DOES NOT ESTABLISH. It shows what a vanished peer costs, not that
a vanished peer is what happened on 2026-08-05. Phase 2's recovery, if any, is
the module being TOLD the peers are gone, not the module healing — pass
--no-lift to ask whether it heals on its own. Issue #15 must not be closed on
this. See doc/HARDWARE-TESTING.md.""")

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
