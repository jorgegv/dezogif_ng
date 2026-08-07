#!/usr/bin/env bash
#
# The DZRP conformance suite, pointed at OUR OWN STUB.
#
# Invoked by `make test-dzrp-stub`. Five headless jnext runs with the WiFi ROM
# installed as the Multiface ROM and an emulated M1 button press to bring the
# debugger up, with a TCP client talking to the emulated ESP-01.
#
# WHY THIS IS THE STRONGEST CHECK IN THE REPOSITORY. Everything else judges a
# proxy: `make test` compares pixels, `make test-mfselect` compares files on an
# SD image, `make test-esp` echoes bytes through a fixture that is not the
# debugger. This one sends DZRP commands to the debugger and reads its answers.
# Until it existed, the protocol — which is the entire deliverable — had never
# been exercised against our own code by anything.
#
# WHAT IT COVERS:
#
#   run 1
#     W1   the stub took the NMI, relocated MAIN, brought UART0 up at 115200,
#          and got AT+CIPMUX=1 / AT+CIPSERVER=1,11000 accepted — proven by the
#          port appearing, which nothing else in this repository has ever shown
#     C1.. whatever the conformance suite then reports; its loopback sweep now
#          runs past jnext's 2048-byte `+IPD` split, so the transport's
#          reassembly across frames is covered (see doc/DZRP-TESTING.md)
#
#   run 2
#     W2   an UNPROMPTED notification aimed at a client that has gone leaves the
#          stub quiet and still serving, instead of parking on a TX timeout.
#          Its own run because it deliberately crashes the debuggee and because
#          its verdict is read off the stub's screen, which the suite repaints.
#
#   run 3
#     W3   THE NEGATIVE CONTROL FOR C10, and it is here for the same reason T3
#          is here for T4: without it, "C10 passed" is not evidence that C10 can
#          fail. The identical setup runs with the CMD_CONTINUE alone removed
#          (--no-continue), and C10 must go RED. If it stays green, C10 is
#          measuring something other than the resume — a green check that
#          cannot reach its own failing case is the mistake ERRORS.md already
#          records twice.
#
#   run 4
#     W4   TWO COMMANDS ARRIVING BACK TO BACK ARE BOTH ANSWERED. One of them
#          used to be destroyed by the wait for AT+CIPSEND's prompt, which
#          skipped it exactly as it skips the module's unsolicited lines — no
#          error, nothing sent, the client waiting for ever (issue #11). It
#          asserts its own precondition from the module's log, the way W2 does:
#          two +IPD frames really were emitted with nothing sent between them.
#          The same defect's OTHER window, the wait for SEND OK, is
#          unreachable here because jnext answers instantly; that one is
#          hardware bench H3.
#
#   run 5
#     W5   A COMMAND SPLIT ACROSS +IPD FRAMES IS ANSWERED ON ITS OWN
#          CONNECTION, WITH ITS OWN PAYLOAD (issue #13). cmd_get_tbblue_reg,
#          cmd_set_breakpoints and cmd_restore_mem all send their response
#          header BEFORE reading payload, so a second client speaking in that
#          window used to supply the missing bytes and receive the reply. Its
#          precondition — three frames, from two connections, in the order that
#          makes the collision — is asserted from the module's log, as W4's is.
#
# WHAT IT DOES NOT COVER. Real hardware, where the ESP has to be associated
# first and answers at whatever baud it was last left at (doc/WIFI-SETUP.md).
# W2's CMD_CONTINUE is NOT evidence about the return path: it resumes zeroed
# registers on purpose, which is a crash. C10/C11 in run 1 are where the resume
# is actually tested, against a debuggee this suite loads itself.
#
# Environment (all set by the Makefile, all overridable):
#   JNEXT         path to the jnext binary
#   SD_IMAGE      reference SD card image; NEVER written, only copied
#   OUT           build directory
#   ROM           our WiFi-mode enNextMf.rom
#   DZRP_ARGS     extra arguments for conformance.py
#   DZRP_TIMEOUT  per-command timeout for conformance.py

set -euo pipefail

# ---------------------------------------------------------------------------
# SERIALISE BENCH RUNS ACROSS PROCESSES.
#
# The pre-flight further down refuses to START when something is already
# listening on our port. That is necessary and not sufficient, and the gap is
# the dangerous direction: once OUR jnext has bound the port, ANOTHER bench
# run's client connects to OUR stub, and both runs then report each other's
# traffic as their own.
#
# Measured on 2026-08-05, with several agents working in parallel: a W2 log
# that should carry exactly 2 client connections carried 14, and four jnext
# processes were alive at once. It cost a spurious W2 failure, an
# AT+CIPSERVER that could not bind mid-script, and a conformance run aimed at
# CSpect that was partly answered by our own stub — the last one detectable
# only because C1 reported `dezogif v2.2.1`.
#
# THE FAILURES GO BOTH WAYS, which is why this is a mutex and not a louder
# warning: a contaminated run can just as easily come out GREEN, with the
# checks answered by somebody else's healthy stub. A green light nobody can
# trust is worse than a red one.
#
# flock is advisory and process-scoped, so it serialises every cooperating
# bench without any of them needing to know about the others. The lock lives
# on $HOME (real disk) rather than /tmp, which is tmpfs on this machine.
# ---------------------------------------------------------------------------
BENCH_LOCK=${BENCH_LOCK:-$HOME/tmp/dezogif_ng-bench.lock}
if [ -z "${BENCH_LOCK_HELD:-}" ] && command -v flock >/dev/null 2>&1; then
    mkdir -p "$(dirname "$BENCH_LOCK")"
    export BENCH_LOCK_HELD=1
    exec flock "$BENCH_LOCK" "$0" "$@"
fi

JNEXT=${JNEXT:-$HOME/src/spectrum/jnext/build/gui-release/jnext}
SD_IMAGE=${SD_IMAGE:-$HOME/.jnext/sdcard/cspect-next-1gb-fixed.img}
OUT=${OUT:-build}
ROM=${ROM:-$OUT/enNextMf-wifi.rom}
DZRP_ARGS=${DZRP_ARGS:-}

# Must match ESP_SERVER_PORT in src/transport_esp.asm. DeZog's `cspect` default.
PORT=11000

# NextZXOS needs ~900 frames to reach the welcome screen; the button is pressed
# there, exactly as run-headless.sh's T6 does.
BOOT_FRAMES=900

# A backstop only. The run is ended by killing jnext once the suite is done, so
# this just has to outlast the suite; the wall-clock guard below is the real
# bound.
EXIT_FRAMES=200000

# THE SCREENSHOT IS TAKEN EARLY, AND THAT IS MEASURED RATHER THAN TIDY. Once
# DZRP traffic is flowing the emulator's frame rate collapses — the ESP UART
# adapter is ticked per Z80 instruction while it has anything to pace, and the
# debugger runs at 28 MHz — so a capture at frame 1200 was never reached inside
# the suite's ~25 s, while one at 1000 lands every time. It may therefore catch
# cmd_init's repaint of the UI in progress; it is a diagnostic, not an
# assertion, and the assertions are all on bytes.
SHOT_FRAMES=1100

# Wall-clock guards.
RUN_TIMEOUT=600
LISTEN_TIMEOUT=60

# Shared jnext teardown — issue #17. Defines functions and nothing else, so it
# cannot disturb the `set -euo pipefail` above or the traps below.
# shellcheck source=test/bench-jnext.sh
. "$(dirname "$0")/bench-jnext.sh"

MF_ROM_PATH='::/machines/next/enNextMf.rom'
CONFORMANCE=$(dirname "$0")/dzrp/conformance.py
ORPHAN=$(dirname "$0")/dzrp/orphan-notify.py
QUEUED=$(dirname "$0")/dzrp/queued-commands.py
SPLIT=$(dirname "$0")/dzrp/split-command.py
NMI_STOPPED=$(dirname "$0")/dzrp/nmi-while-stopped.py

# W6's second M1 press, in frames after the first.
#
# THIS IS A MARGIN, NOT A GUARANTEE, AND THE FIRST VERSION TREATED IT AS ONE.
# The press has to land after CMD_SET_SLOT has taken effect. At 600 frames that
# held, but only just: measured across two runs of the identical script on an
# idle machine, the gap between the reply to the "before" CMD_GET_REGISTERS and
# the press was 149 ms in one and 2 ms in the other. Inverted, CMD_SET_SLOT
# would overwrite whatever a corrupting press had just written, no further press
# would remain to observe, and W6 would report before=30 after=30 — GREEN, on a
# broken ROM. Found by review, by measuring rather than by reading.
#
# So two things changed. The margin is wider, and there is no cost to that:
# EXIT_FRAMES is a backstop, the run ends when the bench kills jnext, and the
# client is idle while these frames elapse, so the emulator runs at its
# unloaded rate. And the ordering is now ASSERTED from the log below, so if the
# margin is ever lost anyway the run fails RED as a precondition rather than
# passing.
# Overridable so the precondition's own control is re-runnable by anyone rather
# than being a story about a scratch tree, which is the seam the IP_MAX /
# RX_WAIT / LINK_IDS family already uses. `SECOND_NMI_FRAMES=901
# make test-dzrp-stub` puts the press before the client has said anything and
# W6 must go RED on the precondition, not green.
SECOND_NMI_FRAMES=${SECOND_NMI_FRAMES:-$((BOOT_FRAMES + 3000))}

# Longer than the suite's own 5 s default. The loopback sweep now goes to 4096
# bytes, which is ~8 KB over a 115200 link plus seventeen AT+CIPSEND round
# trips, and the emulator does not run that at wall-clock speed.
DZRP_TIMEOUT=${DZRP_TIMEOUT:-25}

# W3's control waits only for a notification that must never come, so it does
# not need the sweep's headroom. Shorter is safe here in a way it is not
# elsewhere: the control's verdict is "C10 went red", and C10 goes red on the
# missing notification whatever the wait was.
CONTROL_TIMEOUT=${CONTROL_TIMEOUT:-10}

# Seconds between the listener appearing and the first client connecting. See
# the note in start_stub; test/run-tx-patience.sh uses the same value for the
# same reason.
SETTLE=${SETTLE:-2}

log()  { printf '%s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# --- pre-flight ------------------------------------------------------------

[ -x "$JNEXT" ]      || die "jnext binary not found or not executable: $JNEXT"
[ -f "$SD_IMAGE" ]   || die "SD card image not found: $SD_IMAGE"
[ -f "$ROM" ]        || die "WiFi ROM not built: $ROM (run 'make mf-rom-wifi')"
[ -f "$CONFORMANCE" ]|| die "conformance suite not found: $CONFORMANCE"
[ -f "$ORPHAN" ]     || die "W2 fixture not found: $ORPHAN"
[ -f "$QUEUED" ]     || die "W4 fixture not found: $QUEUED"
[ -f "$SPLIT" ]      || die "W5 fixture not found: $SPLIT"
python3 -c 'import PIL' 2>/dev/null || die "python3 Pillow is required for W2's screen check"
command -v mcopy >/dev/null || die "mtools (mcopy) is required to install the ROM into the SD image"

# The ROM must really be the WiFi one. Installing the UART build here would
# produce a run that boots, takes the NMI, paints its UI and then listens on
# nothing — and the failure would look like a transport bug rather than the
# wrong file. The magic string at the fixed offset is exactly what issue #4 put
# there to answer this question.
variant=$(dd if="$ROM" bs=1 skip=8160 count=19 2>/dev/null | tr -d '\0')
[ "${variant#DeZoGiFnG_WIFI_}" != "$variant" ] \
    || die "$ROM does not identify itself as a WiFi build (magic: '$variant')"

bench_jnext_supports "$JNEXT" '--esp-listen-address' \
    || die "this jnext has no --esp-listen-address (need >= 0.99.118); rebuild it"
bench_jnext_supports "$JNEXT" '--delayed-nmi' \
    || die "this jnext has no --delayed-nmi (need >= 0.99.118); rebuild it"

# A port already in use would make the suite talk to somebody else's listener
# and report the results as ours.
if command -v ss >/dev/null 2>&1; then
    # `grep -c` and not `-q`. -q exits at its first match, and the SIGPIPE that
    # would give `ss` comes back as 141 under pipefail — which `!` then reads as
    # "free", starting a run against an occupied port. -c cannot do that: it must
    # read to EOF to count, so there is no early close to signal.
    # THE `|| true` IS FOR SOMETHING ELSE, and not for that: `grep -c` exits 1
    # when the count is 0, which is the ORDINARY case here.
    [ "$(ss -ltn 2>/dev/null | grep -cE "127\.0\.0\.1:$PORT\b" || true)" -eq 0 ] \
        || die "something is already listening on 127.0.0.1:$PORT — stop it first (CSpect, a stale jnext?)"
fi

part_lba=$(od -An -tu4 -j 454 -N 4 "$SD_IMAGE" | tr -d ' ')
[ -n "$part_lba" ] && [ "$part_lba" -gt 0 ] || die "cannot read partition table from $SD_IMAGE"
part_off=$((part_lba * 512))

mkdir -p "$OUT" "$OUT/screenshots"

# --- the run ---------------------------------------------------------------
#
# The reference image is never written. The working copy is reflinked where the
# filesystem supports it and DELETED on the way out either way: --reflink=auto
# falls back to a real copy silently, and abandoned gigabyte copies from bench
# runs are what filled a scratch filesystem and took a session's shell down on
# 2026-08-04.
#
# The trap is armed BEFORE the copy, because the copy is the slowest thing here
# and therefore the likeliest moment to be interrupted; jnext_pid is declared
# empty first so `set -u` cannot abort the handler before it reaches the rm.

sd=$OUT/sd-dzrp.img
jlog=$OUT/dzrp-stub.log
jlog2=$OUT/dzrp-stub-w2.log
jlog3=$OUT/dzrp-stub-w3.log
jlog4=$OUT/dzrp-stub-w4.log
jlog5=$OUT/dzrp-stub-w5.log
jlog6=$OUT/dzrp-stub-w6.log
shot=$OUT/screenshots/dzrp-stub.png
shot2=$OUT/screenshots/dzrp-stub-w2.png
shot3=$OUT/screenshots/dzrp-stub-w3.png
shot4=$OUT/screenshots/dzrp-stub-w4.png
shot5=$OUT/screenshots/dzrp-stub-w5.png
shot6=$OUT/screenshots/dzrp-stub-w6.png

jnext_pid=""
cleanup() {
    if [ -n "$jnext_pid" ] && kill -0 "$jnext_pid" 2>/dev/null; then
        kill "$jnext_pid" 2>/dev/null || true
        wait "$jnext_pid" 2>/dev/null || true
    fi
    # The image is unlinked BEFORE departure is confirmed, and that ordering is
    # deliberate: bench_await_departure can exit, and an exit that skipped this
    # would reintroduce the abandoned-gigabyte leak ERRORS.md records. An
    # emulator still holding the file keeps its blocks until it is killed, which
    # is exactly what the loud failure is telling a human to do.
    rm -f "$sd"
    # And only now is the lock safe to drop — issue #17.
    bench_await_departure "$sd"
}
trap cleanup EXIT
# A handler that only RETURNS does not stop a bash script — the shell defers
# the signal, runs the handler and carries on with the next line. These exit,
# and the EXIT trap above does the cleaning.
trap 'exit 130' INT
trap 'exit 143' TERM

cp --reflink=auto -f "$SD_IMAGE" "$sd"
mcopy -o -i "$sd@@$part_off" "$ROM" "$MF_ROM_PATH"

failures=0
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; failures=$((failures + 1)); }

# stop_stub — end the emulator run and reap it, and REFUSE TO CONTINUE UNTIL THE
# EMULATOR IS ACTUALLY GONE.
#
# `jnext_pid` is the `timeout` WRAPPER's, so the wait below returns when the
# wrapper has gone and says nothing about jnext or about port 11000. See
# test/bench-jnext.sh for what that cost on 2026-08-05.
stop_stub() {
    if [ -n "$jnext_pid" ] && kill -0 "$jnext_pid" 2>/dev/null; then
        kill "$jnext_pid" 2>/dev/null || true
        wait "$jnext_pid" 2>/dev/null || true
    fi
    jnext_pid=""
    bench_await_departure "$sd"
}

# start_stub <logfile> <screenshot> — boot a Next with our WiFi ROM, press M1,
# and wait for the stub's own listener to appear. That wait is an ASSERTION, not
# a convenience: the port can only exist once the NMI was taken, MAIN was
# relocated into a RAM bank, UART0 came up at 115200, and AT+CIPMUX=1 and
# AT+CIPSERVER=1,<port> were both accepted — a chain in which every step gates
# the next. Returns non-zero if it never appears.
start_stub() {
    local logfile=$1 shotfile=$2 second_nmi=${3:-}
    rm -f "$shotfile"
    local -a extra_nmi=()
    # `warn` hides the platform category's "Delayed NMI button ... pressed"
    # line, which is INFO — and that line is W6's whole synchronisation and its
    # precondition. Measured, not assumed: with the bench's usual level the
    # first run reported 0 of 2 presses against a stub that had demonstrably
    # taken one. Raised only for the runs that schedule a second press, so
    # every other run's log stays as small as it was.
    local levels="warn,esp01=debug"
    if [ -n "$second_nmi" ]; then
        extra_nmi=(--delayed-nmi-frames "$second_nmi" nmi)
        levels="$levels,platform=info"
    fi

    # Per run, not only at pre-flight: a foreign listener appearing between two
    # of this script's own runs would answer the client we are about to start,
    # and a contaminated run can come out GREEN (issue #17).
    bench_require_port_free "$PORT" "before this run started"

    timeout "$RUN_TIMEOUT" "$JNEXT" \
        --headless --machine next \
        --sdcard "$sd" \
        --rtc "2026-01-01 12:00:00" \
        --log-level "$levels" \
        --esp --esp-listen-address 127.0.0.1 \
        --delayed-nmi-frames "$BOOT_FRAMES" nmi \
        "${extra_nmi[@]}" \
        --delayed-screenshot "$shotfile" --delayed-screenshot-frames "$SHOT_FRAMES" \
        --delayed-automatic-exit-frames "$EXIT_FRAMES" \
        >"$logfile" 2>&1 &
    jnext_pid=$!

    local i
    for i in $(seq $((LISTEN_TIMEOUT * 4))); do
        kill -0 "$jnext_pid" 2>/dev/null || return 1
        if python3 -c "
import socket, sys
s = socket.socket()
s.settimeout(0.2)
sys.exit(0 if s.connect_ex(('127.0.0.1', $PORT)) == 0 else 1)
" 2>/dev/null; then
            # THEN SETTLE, BEFORE ANY CLIENT SPEAKS. The port exists as soon as
            # AT+CIPSERVER is accepted, and the stub then sends AT+CIFSR and
            # scans its answer for OK. A client landing inside that scan puts
            # `<id>,CONNECT` and its own `+IPD` into it, and its first command
            # is lost — the stub is looking for a line that starts with '+',
            # which is the one case issue #11's fix deliberately cannot capture.
            #
            # This is issue #10's spurious W2, and it is not a guess: with this
            # settle the precondition arose in 6 runs of 6, and without it in 5
            # of 6 — the same shape ERRORS.md records for test-tx-patience,
            # which settles for the same reason. It is the bench declining to
            # race the stub, NOT the stub being fixed: the window is real and
            # closing it is bring-up's problem, not this script's.
            sleep "$SETTLE"
            return 0
        fi
        sleep 0.25
    done
    return 1
}

# bright_red <png> — how many pixels are EXACTLY bright red.
#
# The stub's UI is the only thing that puts bright red on the screen: ui.asm
# colours the bottom nine rows RED+BRIGHT and prints "Last Error: ..." there,
# and nothing else on that screen is red at all. Measured on a real capture,
# jnext renders non-bright components as 182 and bright ones as 255, and the
# border can only ever be non-bright — `out (BORDER),a` carries no bright bit —
# so a red border cannot be mistaken for an error line. Zero means the stub is
# reporting no fault.
bright_red() {
    python3 -c "
from PIL import Image
raw = Image.open('$1').convert('RGB').tobytes()
print(sum(1 for i in range(0, len(raw), 3)
          if raw[i] == 255 and raw[i+1] == 0 and raw[i+2] == 0))
"
}

# ===========================================================================
# Run 1 — W1 and the conformance suite
# ===========================================================================

log "== run 1: booting a Next with our WiFi ROM installed, M1 at frame $BOOT_FRAMES"

if ! start_stub "$jlog" "$shot"; then
    log ""
    fail "W1 the stub never listened on 127.0.0.1:$PORT"
    log "Diagnosis:"
    log "  jnext log:   $jlog"
    log "  screenshot:  $shot  (the stub's own UI reports the last error it saw)"
    grep -iE 'esp01|at <-|at ->|error' "$jlog" | tail -30 | sed 's/^/  | /' || true
    exit 1
fi
pass "W1 the stub brought the ESP up and is listening on 127.0.0.1:$PORT"
log ""

# --expect-preamble none is an assertion this transport owes: the 0xA5 byte is
# required over serial and must be ABSENT over a socket, because DeZog's
# CSpectRemote — the client this transport is spoken to by — does not strip it.
# Reporting it instead of asserting it would leave the one thing MEMORY.md
# singles out about WiFi mode untested.
#
# --require CONTINUE,CLOSE because this stub implements both: were it ever to
# start refusing either command, the suite's partial-remote allowance would
# otherwise report that as UNSUPPORTED and pass. CLOSE is the same argument one
# command along — C15 is the only check that sends command 2, and talk() maps a
# remote that hangs up onto Unsupported, so a stub that started closing the
# socket on CMD_CLOSE would score UNSUP and this target would still exit 0.
set +e
python3 "$CONFORMANCE" --remote "tcp:127.0.0.1:$PORT" --expect-preamble none \
    --require CONTINUE,CLOSE --timeout "$DZRP_TIMEOUT" $DZRP_ARGS
suite_rc=$?
set -e
[ "$suite_rc" -eq 0 ] || failures=$((failures + 1))

stop_stub

# ===========================================================================
# Run 2 — W2: an unprompted notification with the client gone
#
# Its own emulator run, for two reasons: it deliberately crashes the debuggee
# (see test/dzrp/orphan-notify.py), and its verdict is read off the stub's
# SCREEN, which the conformance suite would have repainted.
#
# WHAT A RED W2 MEANS, since the verdict line no longer says it: bright red on
# that screen is "Last Error: TX Timeout", and the way this run produces it is
# esp_conn_valid not being cleared when the peer went — so the stub addressed an
# AT+CIPSEND to a dead cid, got ERROR, waited for a '>' that could not come, and
# reported a fault on a machine with nothing wrong with it. Pre-fix: 824 pixels.
# MEMORY.md 2026-08-04 and 2026-08-05 carry the whole history.
# ===========================================================================

log ""
log "== run 2: an unprompted notification aimed at a client that has gone"

if ! start_stub "$jlog2" "$shot2"; then
    fail "W2 the stub never listened on 127.0.0.1:$PORT for the second run"
else
    set +e
    python3 "$ORPHAN"
    orphan_rc=$?
    set -e

    # Wait for the capture the verdict is read from. The frame budget is early
    # on purpose — see SHOT_FRAMES.
    for _ in $(seq 120); do
        [ -s "$shot2" ] && break
        kill -0 "$jnext_pid" 2>/dev/null || break
        sleep 0.5
    done
    stop_stub

    # CONTAMINATION CHECK, belt to the flock's braces. If another bench run's
    # client reached our stub, this run's verdict is worthless in EITHER
    # direction — the checks may have been answered by somebody else's healthy
    # stub, which comes out GREEN. orphan-notify.py makes exactly 2
    # connections; a few more is retry margin, and 14 was the observed
    # signature of a second agent's suite running at the same time.
    #
    # The recovery, which the one-line verdict below no longer spells out: re-run
    # with no other jnext alive (`pgrep -x jnext`, not `pgrep -f`, which matches
    # its own command line). The same applies to W3, W4 and W5.
    connects=$(grep -c "accepted as cid" "$jlog2" || true)

    # The precondition, asserted rather than assumed: the stub really did try to
    # send to a connection the module had already closed. Without this line the
    # rest of W2 would pass without having tested anything.
    refused=$(grep -c "which is not open — answering ERROR" "$jlog2" || true)

    if [ "$connects" -gt 6 ]; then
        fail "W2 CONTAMINATED: $connects connections in $jlog2 where this fixture makes 2, so this verdict means nothing"
    elif [ "$refused" -lt 1 ]; then
        fail "W2 the precondition never happened: no AT+CIPSEND was refused in $jlog2, so nothing was tested"
    elif [ "$orphan_rc" -ne 0 ]; then
        fail "W2 the stub did not serve a client after the orphaned notification (see $jlog2)"
    elif [ ! -s "$shot2" ]; then
        fail "W2 no screenshot was written ($shot2), so the error area could not be checked"
    else
        red=$(bright_red "$shot2")
        if [ "$red" -gt 0 ]; then
            fail "W2 the stub reported a transport error after the orphaned notification ($red bright-red pixels of 'TX Timeout')"
        else
            pass "W2 an unprompted notification to a departed client ($refused AT+CIPSEND refused) leaves the stub quiet and still serving"
        fi
    fi
fi

# ===========================================================================
# Run 3 — W3: the negative control for C10
#
# C10 asserts that the debuggee ran. This run asserts that C10 NOTICES when it
# did not: the identical fixture is loaded and the registers are set exactly as
# before, and only the CMD_CONTINUE is withheld. C10 must go red.
#
# Its own emulator run because the control needs a stub that has not already
# been resumed, and a shorter --timeout because the only thing it waits for is
# a notification that must never arrive.
# ===========================================================================

log ""
log "== run 3: negative control — the same checks with no CMD_CONTINUE sent"

if ! start_stub "$jlog3" "$shot3"; then
    fail "W3 the stub never listened on 127.0.0.1:$PORT for the control run"
else
    set +e
    control_out=$(python3 "$CONFORMANCE" --remote "tcp:127.0.0.1:$PORT" \
        --expect-preamble none --only C10 --no-continue --timeout "$CONTROL_TIMEOUT" 2>&1)
    control_rc=$?
    set -e
    stop_stub
    printf '%s\n' "$control_out" | sed 's/^/  | /'

    # Same contamination check as W2, and it matters MORE here: this run's
    # expected verdict is a FAILURE, so a stub belonging to somebody else could
    # only make it redder, but a stub of ours reached by somebody else's client
    # could have been sent the CMD_CONTINUE this control withholds. The control
    # makes one connection and start_stub's port probe makes one more.
    w3_connects=$(grep -c "accepted as cid" "$jlog3" || true)

    if [ "$w3_connects" -gt 6 ]; then
        fail "W3 CONTAMINATED: $w3_connects connections in $jlog3 where this control makes 2, so it proves nothing"
    elif [ "$control_rc" -eq 0 ]; then
        fail "W3 the control PASSED with no CMD_CONTINUE sent: C10 is not measuring the resume"
    elif ! printf '%s' "$control_out" | grep -q '^FAIL  C10 '; then
        fail "W3 the control failed, but not at C10 — it never reached the check it controls"
    else
        pass "W3 with the CMD_CONTINUE withheld C10 goes red, so C10's green is about the resume"
    fi
fi

# ===========================================================================

# ===========================================================================
# Run 4 — W4: two commands queued back to back, both must be answered
#
# Its own emulator run because it needs a stub that has not been resumed or
# crashed by the runs above, and because its precondition is read out of a
# clean log.
# ===========================================================================

log ""
log "== run 4: two commands arriving back to back"

if ! start_stub "$jlog4" "$shot4"; then
    fail "W4 the stub never listened on 127.0.0.1:$PORT for the queued-command run"
else
    set +e
    queued_out=$(DZRP_PORT="$PORT" DZRP_TIMEOUT="$CONTROL_TIMEOUT" python3 "$QUEUED" 2>&1)
    queued_rc=$?
    set -e
    stop_stub
    printf '%s\n' "$queued_out" | sed 's/^/  | /'

    q_connects=$(grep -c "accepted as cid" "$jlog4" || true)

    # THE PRECONDITION, asserted from the module's own log rather than assumed:
    # two +IPD frames really were put on the wire with nothing sent between
    # them. Without this W4 passes vacuously whenever the client's two writes
    # happen not to collide — which is most of the reason a race makes a bad
    # test. `AT ->` is the module talking, `AT <-` is the stub.
    collided=$(grep -E 'AT (->|<-)' "$jlog4" \
        | awk '/AT -> .*\+IPD,/ { if (prev) { hit++ } ; prev = 1 ; next }
               { prev = 0 }
               END { print hit + 0 }')

    if [ "$q_connects" -gt 6 ]; then
        fail "W4 CONTAMINATED: $q_connects connections in $jlog4 where this fixture makes 3, so this verdict means nothing"
    elif [ "$collided" -lt 1 ]; then
        fail "W4 the precondition never happened: no two +IPD frames back to back in $jlog4, so nothing was tested"
    elif [ "$queued_rc" -ne 0 ]; then
        fail "W4 a command that arrived while the stub was answering another was LOST (issue #11); see $jlog4"
    else
        pass "W4 two commands queued back to back are both answered ($collided collision(s) in the module's log)"
    fi
fi

# ===========================================================================
# Run 5 — W5: a command split across +IPD frames while a second client speaks
#
# Its own emulator run for W4's reasons: a stub that has not been resumed or
# crashed by the runs above, and a clean log to read the precondition from.
# ===========================================================================

log ""
log "== run 5: a command split across frames while another connection speaks"

if ! start_stub "$jlog5" "$shot5"; then
    fail "W5 the stub never listened on 127.0.0.1:$PORT for the split-command run"
else
    set +e
    split_out=$(DZRP_PORT="$PORT" DZRP_TIMEOUT="$CONTROL_TIMEOUT" python3 "$SPLIT" 2>&1)
    split_rc=$?
    set -e
    stop_stub
    printf '%s\n' "$split_out" | sed 's/^/  | /'

    s_connects=$(grep -c "accepted as cid" "$jlog5" || true)

    # THE PRECONDITION, from the module's own log rather than assumed: the three
    # frames really were emitted, from two different connections, in the order
    # that puts somebody else's command exactly where the split command's
    # payload should have been.
    #
    # The lengths are the fixture's and must be read with it: 6 = a DZRP command
    # header, 15 = the other client's whole CMD_LOOPBACK, 1 = the register
    # number that was withheld. Change B_PAYLOAD in split-command.py and this
    # line has to change with it — which is the point of asserting the exact
    # shape rather than "some frames interleaved".
    split_ok=$(python3 - "$jlog5" <<'EOF'
import re, sys
frames = re.findall(r'\+IPD,(\d+),(\d+)', open(sys.argv[1], errors='replace').read())
frames = [(int(c), int(n)) for c, n in frames]
for i in range(len(frames) - 2):
    (c1, n1), (c2, n2), (c3, n3) = frames[i:i + 3]
    if (n1, n2, n3) == (6, 15, 1) and c1 == c3 and c2 != c1:
        print("%d,%d" % (c1, c2))
        break
else:
    print("")
EOF
)

    if [ "$s_connects" -gt 8 ]; then
        fail "W5 CONTAMINATED: $s_connects connections in $jlog5 where this fixture makes 3, so this verdict means nothing"
    elif [ -z "$split_ok" ]; then
        fail "W5 the precondition never happened: no 6/15/1 run of +IPD frames from two connections in $jlog5"
    elif [ "$split_rc" -ne 0 ]; then
        fail "W5 a split command was answered on the wrong connection or from the wrong payload (issue #13)"
    else
        pass "W5 a split command (cid $split_ok) got its own connection and payload, and the other client was answered too"
    fi
fi

# ===========================================================================
# Run 6 — W6: an M1 press while the debugger is STOPPED
#
# Issue #26's second defect. mf_rom.asm's entry path stored the bank it found
# in MAIN_SLOT into slot_backup.slot7 on EVERY press, before the dispatch had
# decided anything — so a press taken while the DEBUGGER was executing wrote
# MAIN_BANK over the debuggee's bank, which dbg_enter had saved when the
# breakpoint was taken, and the next CMD_CONTINUE would have paged the
# debugger's own bank into the debuggee's slot 7.
#
# It is observable over the socket because CMD_GET_REGISTERS reports slot 7
# from that byte rather than from the MMU. See test/dzrp/nmi-while-stopped.py,
# which carries the sequence and why each step is the one it is.
#
# THE SENTINEL IS THE VACUITY GUARD FOR ONE EDGE OF THE WINDOW, NOT BOTH. The
# press must land BETWEEN the client's two reads, and jnext schedules it in
# emulated FRAMES while the client counts wall clock — the same mismatch that
# makes an NMI against a running debuggee unschedulable here (MEMORY.md
# 2026-08-05). The bench waits for jnext's own log to report the second press
# and only then releases the client, so the press cannot follow the second
# read. The other edge — the press must not PRECEDE the setup — is a frame
# margin, and it is asserted from the log below rather than assumed, because
# that direction fails GREEN. See SECOND_NMI_FRAMES.
# ===========================================================================

log ""
log "== run 6: an M1 press while the debugger is stopped, with a bank saved"

sentinel6=$OUT/dzrp-stub-w6.sentinel
rm -f "$sentinel6"

if ! start_stub "$jlog6" "$shot6" "$SECOND_NMI_FRAMES"; then
    fail "W6 the stub never listened on 127.0.0.1:$PORT for the stopped-press run"
else
    set +e
    SENTINEL="$sentinel6" DZRP_PORT="$PORT" DZRP_TIMEOUT="$DZRP_TIMEOUT" \
        python3 "$NMI_STOPPED" >"$OUT/dzrp-stub-w6.client" 2>&1 &
    client6_pid=$!

    # Wait for the second press to be REPORTED, not merely scheduled. A
    # `Delayed NMI button ... pressed` line is written when it is delivered;
    # the announcement lines jnext prints at startup say "will press", so this
    # pattern cannot match them.
    nmi_seen=0
    for _ in $(seq $((RUN_TIMEOUT * 2))); do
        kill -0 "$client6_pid" 2>/dev/null || break
        if [ "$(grep -c 'Delayed NMI button' "$jlog6" 2>/dev/null || echo 0)" -ge 2 ]; then
            nmi_seen=1
            break
        fi
        sleep 0.5
    done
    # Released either way: a client left waiting on a sentinel that never comes
    # would report the harness fault itself, but only after its own timeout.
    printf 'go\n' > "$sentinel6"

    wait "$client6_pid"
    w6_rc=$?
    set -e
    stop_stub
    sed 's/^/  | /' "$OUT/dzrp-stub-w6.client"

    w6_presses=$(grep -c 'Delayed NMI button' "$jlog6" || true)
    w6_connects=$(grep -c "accepted as cid" "$jlog6" || true)

    # THE LEFT EDGE OF THE WINDOW, asserted from the module's own log exactly as
    # W4 and W5 assert theirs. The sentinel guarantees the press happened before
    # the SECOND read; nothing but a frame count guarantees it happened after
    # the FIRST, and that direction fails GREEN. The client sends exactly three
    # commands before it arms — CMD_INIT, CMD_SET_SLOT, CMD_GET_REGISTERS — so
    # at least three inbound frames must precede the second press. Fewer means
    # the press raced the setup and the run judged nothing.
    w6_before=$(python3 - "$jlog6" <<'EOF'
import re, sys
ipd = 0
presses = 0
for line in open(sys.argv[1], errors='replace'):
    if '+IPD,' in line:
        ipd += len(re.findall(r'\+IPD,\d+,\d+', line))
    if 'Delayed NMI button' in line:
        presses += 1
        if presses == 2:
            print(ipd)
            break
else:
    print(-1)
EOF
)

    if [ "$w6_connects" -gt 4 ]; then
        fail "W6 CONTAMINATED: $w6_connects connections in $jlog6 where this fixture makes 1"
    elif [ "$w6_presses" -ne 2 ]; then
        fail "W6 harness: jnext delivered $w6_presses of 2 NMI presses, so no press was judged"
    elif [ "$nmi_seen" -ne 1 ]; then
        fail "W6 harness: the second press was never seen in the log while the client waited"
    elif [ "$w6_before" -lt 3 ]; then
        fail "W6 harness: the press raced the setup — $w6_before commands had arrived, needed 3"
    elif [ "$w6_rc" -ne 0 ]; then
        fail "W6 an M1 press while stopped destroyed the debuggee's saved slot 7 bank (issue #26)"
    else
        pass "W6 an M1 press while the debugger is stopped leaves the debuggee's slot 7 bank intact"
    fi
fi

# ===========================================================================
# Summary
# ===========================================================================

log ""
if [ "$failures" -ne 0 ]; then
    log "Diagnosis:"
    log "  jnext logs:   $jlog  $jlog2  $jlog3  $jlog4  $jlog5  $jlog6"
    log "  screenshots:  $shot  $shot2  $shot3  $shot4  $shot5  $shot6"
fi

exit "$((failures > 0 ? 1 : 0))"
