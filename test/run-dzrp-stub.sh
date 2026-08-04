#!/usr/bin/env bash
#
# The DZRP conformance suite, pointed at OUR OWN STUB.
#
# Invoked by `make test-dzrp-stub`. One headless jnext run with the WiFi ROM
# installed as the Multiface ROM, an emulated M1 button press to bring the
# debugger up, and then test/dzrp/conformance.py talking DZRP over TCP to the
# emulated ESP-01.
#
# WHY THIS IS THE STRONGEST CHECK IN THE REPOSITORY. Everything else judges a
# proxy: `make test` compares pixels, `make test-mfselect` compares files on an
# SD image, `make test-esp` echoes bytes through a fixture that is not the
# debugger. This one sends DZRP commands to the debugger and reads its answers.
# Until it existed, the protocol — which is the entire deliverable — had never
# been exercised against our own code by anything.
#
# WHAT IT COVERS, and the chain is long because every link has to hold before
# the first byte of DZRP can move:
#
#   W1  the stub took the NMI, relocated MAIN, brought UART0 up at 115200,
#       and got AT+CIPMUX=1 / AT+CIPSERVER=1,11000 accepted — proven by the
#       port appearing, which nothing else in this repository has ever shown
#   W2..  whatever the conformance suite then reports (see doc/DZRP-TESTING.md)
#
# WHAT IT DOES NOT COVER. Real hardware, where the ESP has to be associated
# first and answers at whatever baud it was last left at (doc/WIFI-SETUP.md);
# and the resume path is only exercised as far as the suite goes — no check
# here sends CMD_CONTINUE to a running debuggee.
#
# Environment (all set by the Makefile, all overridable):
#   JNEXT        path to the jnext binary
#   SD_IMAGE     reference SD card image; NEVER written, only copied
#   OUT          build directory
#   ROM          our WiFi-mode enNextMf.rom
#   DZRP_ARGS    extra arguments for conformance.py

set -euo pipefail

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
SHOT_FRAMES=1000

# Wall-clock guards.
RUN_TIMEOUT=600
LISTEN_TIMEOUT=60

MF_ROM_PATH='::/machines/next/enNextMf.rom'
CONFORMANCE=$(dirname "$0")/dzrp/conformance.py

log()  { printf '%s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# --- pre-flight ------------------------------------------------------------

[ -x "$JNEXT" ]      || die "jnext binary not found or not executable: $JNEXT"
[ -f "$SD_IMAGE" ]   || die "SD card image not found: $SD_IMAGE"
[ -f "$ROM" ]        || die "WiFi ROM not built: $ROM (run 'make mf-rom-wifi')"
[ -f "$CONFORMANCE" ]|| die "conformance suite not found: $CONFORMANCE"
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
shot=$OUT/screenshots/dzrp-stub.png
jlog=$OUT/dzrp-stub.log

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

log "== booting a Next with our WiFi ROM installed, then pressing M1 at frame $BOOT_FRAMES"

rm -f "$shot"
timeout "$RUN_TIMEOUT" "$JNEXT" \
    --headless --machine next \
    --sdcard "$sd" \
    --rtc "2026-01-01 12:00:00" \
    --esp --esp-listen-address 127.0.0.1 \
    --delayed-nmi-frames "$BOOT_FRAMES" nmi \
    --delayed-screenshot "$shot" --delayed-screenshot-frames "$SHOT_FRAMES" \
    --delayed-automatic-exit-frames "$EXIT_FRAMES" \
    >"$jlog" 2>&1 &
jnext_pid=$!

# --- W1: the stub is listening ---------------------------------------------
#
# This is an assertion, not a convenience wait. The port can only appear after
# the NMI was taken, MAIN was relocated into a RAM bank, UART0 was brought up
# at 115200 and the module accepted AT+CIPMUX=1 and AT+CIPSERVER=1,<port> — a
# chain in which every step gates the next.

log "== waiting for the stub to listen on 127.0.0.1:$PORT (up to ${LISTEN_TIMEOUT}s)"
listening=0
for _ in $(seq $((LISTEN_TIMEOUT * 4))); do
    if ! kill -0 "$jnext_pid" 2>/dev/null; then
        break
    fi
    if python3 -c "
import socket, sys
s = socket.socket()
s.settimeout(0.2)
sys.exit(0 if s.connect_ex(('127.0.0.1', $PORT)) == 0 else 1)
" 2>/dev/null; then
        listening=1
        break
    fi
    sleep 0.25
done

if [ "$listening" -ne 1 ]; then
    log ""
    log "FAIL  W1 the stub never listened on 127.0.0.1:$PORT"
    log "Diagnosis:"
    log "  jnext log:   $jlog"
    log "  screenshot:  $shot  (the stub's own UI reports the last error it saw)"
    grep -iE 'esp01|at <-|at ->|error' "$jlog" | tail -30 | sed 's/^/  | /' || true
    exit 1
fi
log "PASS  W1 the stub brought the ESP up and is listening on 127.0.0.1:$PORT"
log ""

# --- W2..: the protocol ----------------------------------------------------
#
# --expect-preamble none is an assertion this branch owes: the 0xA5 byte is
# required over serial and must be ABSENT over a socket, because DeZog's
# CSpectRemote — the client this transport is spoken to by — does not strip it.
# Reporting it instead of asserting it would leave the one thing MEMORY.md
# singles out about WiFi mode untested.
set +e
python3 "$CONFORMANCE" --remote "tcp:127.0.0.1:$PORT" --expect-preamble none $DZRP_ARGS
suite_rc=$?
set -e

log ""
if [ "$suite_rc" -ne 0 ]; then
    log "Diagnosis:"
    log "  jnext log:   $jlog"
    log "  screenshot:  $shot"
    grep -iE 'esp01' "$jlog" | tail -30 | sed 's/^/  | /' || true
fi

exit "$suite_rc"
