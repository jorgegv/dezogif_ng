#!/usr/bin/env bash
#
# The DZRP conformance suite, pointed at OUR OWN STUB.
#
# Invoked by `make test-dzrp-stub`. Two headless jnext runs with the WiFi ROM
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
# WHAT IT DOES NOT COVER. Real hardware, where the ESP has to be associated
# first and answers at whatever baud it was last left at (doc/WIFI-SETUP.md).
# Nothing here resumes a debuggee that was ever properly loaded — W2's
# CMD_CONTINUE resumes zeroed registers on purpose, which is a crash, not a
# demonstration that the return-to-debuggee path works.
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

MF_ROM_PATH='::/machines/next/enNextMf.rom'
CONFORMANCE=$(dirname "$0")/dzrp/conformance.py
ORPHAN=$(dirname "$0")/dzrp/orphan-notify.py

# Longer than the suite's own 5 s default. The loopback sweep now goes to 4096
# bytes, which is ~8 KB over a 115200 link plus seventeen AT+CIPSEND round
# trips, and the emulator does not run that at wall-clock speed.
DZRP_TIMEOUT=${DZRP_TIMEOUT:-25}

log()  { printf '%s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# --- pre-flight ------------------------------------------------------------

[ -x "$JNEXT" ]      || die "jnext binary not found or not executable: $JNEXT"
[ -f "$SD_IMAGE" ]   || die "SD card image not found: $SD_IMAGE"
[ -f "$ROM" ]        || die "WiFi ROM not built: $ROM (run 'make mf-rom-wifi')"
[ -f "$CONFORMANCE" ]|| die "conformance suite not found: $CONFORMANCE"
[ -f "$ORPHAN" ]     || die "W2 fixture not found: $ORPHAN"
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

"$JNEXT" --help 2>&1 | grep -q -- '--esp-listen-address' \
    || die "this jnext has no --esp-listen-address (need >= 0.99.118); rebuild it"
"$JNEXT" --help 2>&1 | grep -q -- '--delayed-nmi' \
    || die "this jnext has no --delayed-nmi (need >= 0.99.118); rebuild it"

# A port already in use would make the suite talk to somebody else's listener
# and report the results as ours.
if command -v ss >/dev/null 2>&1; then
    ! ss -ltn 2>/dev/null | grep -qE "127\.0\.0\.1:$PORT\b" \
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
shot=$OUT/screenshots/dzrp-stub.png
shot2=$OUT/screenshots/dzrp-stub-w2.png

jnext_pid=""
cleanup() {
    if [ -n "$jnext_pid" ] && kill -0 "$jnext_pid" 2>/dev/null; then
        kill "$jnext_pid" 2>/dev/null || true
        wait "$jnext_pid" 2>/dev/null || true
    fi
    rm -f "$sd"
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

# stop_stub — end the emulator run and reap it.
stop_stub() {
    if [ -n "$jnext_pid" ] && kill -0 "$jnext_pid" 2>/dev/null; then
        kill "$jnext_pid" 2>/dev/null || true
        wait "$jnext_pid" 2>/dev/null || true
    fi
    jnext_pid=""
}

# start_stub <logfile> <screenshot> — boot a Next with our WiFi ROM, press M1,
# and wait for the stub's own listener to appear. That wait is an ASSERTION, not
# a convenience: the port can only exist once the NMI was taken, MAIN was
# relocated into a RAM bank, UART0 came up at 115200, and AT+CIPMUX=1 and
# AT+CIPSERVER=1,<port> were both accepted — a chain in which every step gates
# the next. Returns non-zero if it never appears.
start_stub() {
    local logfile=$1 shotfile=$2
    rm -f "$shotfile"
    timeout "$RUN_TIMEOUT" "$JNEXT" \
        --headless --machine next \
        --sdcard "$sd" \
        --rtc "2026-01-01 12:00:00" \
        --log-level "warn,esp01=debug" \
        --esp --esp-listen-address 127.0.0.1 \
        --delayed-nmi-frames "$BOOT_FRAMES" nmi \
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
set +e
python3 "$CONFORMANCE" --remote "tcp:127.0.0.1:$PORT" --expect-preamble none \
    --timeout "$DZRP_TIMEOUT" $DZRP_ARGS
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
    connects=$(grep -c "accepted as cid" "$jlog2" || true)

    # The precondition, asserted rather than assumed: the stub really did try to
    # send to a connection the module had already closed. Without this line the
    # rest of W2 would pass without having tested anything.
    refused=$(grep -c "which is not open — answering ERROR" "$jlog2" || true)

    if [ "$connects" -gt 6 ]; then
        fail "W2 CONTAMINATED — $connects connections in $jlog2 where this fixture makes 2. Another bench run reached our stub, so this verdict means nothing in either direction. Re-run with no other jnext alive (pgrep jnext)."
    elif [ "$refused" -lt 1 ]; then
        fail "W2 the precondition never happened — no AT+CIPSEND was refused in $jlog2, so nothing was tested"
    elif [ "$orphan_rc" -ne 0 ]; then
        fail "W2 the stub did not serve a client after the orphaned notification (see $jlog2)"
    elif [ ! -s "$shot2" ]; then
        fail "W2 no screenshot was written ($shot2), so the error area could not be checked"
    else
        red=$(bright_red "$shot2")
        if [ "$red" -gt 0 ]; then
            fail "W2 the stub reported a transport error after the orphaned notification ($red bright-red pixels in $shot2 — it is 'Last Error: TX Timeout'); esp_conn_valid was not cleared when the peer went"
        else
            pass "W2 an unprompted notification to a departed client ($refused AT+CIPSEND refused) leaves the stub quiet — no error on screen — and still serving"
        fi
    fi
fi

# ===========================================================================

log ""
if [ "$failures" -ne 0 ]; then
    log "Diagnosis:"
    log "  jnext logs:   $jlog  $jlog2"
    log "  screenshots:  $shot  $shot2"
fi

exit "$((failures > 0 ? 1 : 0))"
