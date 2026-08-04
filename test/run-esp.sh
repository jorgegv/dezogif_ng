#!/usr/bin/env bash
#
# M0(b) bench: the ESP-01 as a TCP server, checked over a real socket.
#
# Invoked by `make test-esp`. One headless jnext run, with the guest fixture
# (test/esp_server.asm) injected; a Python client on the host connects to the
# port the guest opened and checks that what it sends comes back.
#
# WHY THIS IS SEPARATE FROM `make test`. Not because it is less important —
# it asserts more than any check in that suite does. Two structural reasons:
#
#   1. It needs a live TCP client running CONCURRENTLY with the emulator.
#      run-headless.sh's every run is synchronous by design, and each of its
#      checks compares two screenshots taken at identical frame counts. A
#      concurrent client does not fit that shape and should not be forced into
#      it.
#   2. It binds a TCP port on the host. `make test` has no external
#      dependencies at all; this cannot make that promise, because the port
#      may be in use.
#
# WHAT IT PROVES, and it is the strongest evidence in this repository so far
# because the assertions are on BYTES rather than on pixels:
#
#   E1   the guest brought the ESP up and is listening. Covers the whole AT
#        chain — ATE0, AT, AT+CIPMUX=1, AT+CIPSERVER=1,11000 — because each
#        gates the next and CIPSERVER is REFUSED without CIPMUX.
#   E2   a payload echoes back byte-identically: the +IPD parser and the
#        AT+CIPSEND reply, end to end.
#   E3   a second, longer payload echoes on the same connection: the loop
#        re-arms, and nothing was left in the stream.
#   E4   a second SIMULTANEOUS connection echoes too. This is the one that
#        pins MEMORY.md's jnext note: inbound ids start at 1, so the second
#        connection is cid 2, and a fixture that assumed any fixed id would
#        answer on the wrong socket. A stub with that bug produces "no error,
#        no data, and a debug session that looks like a DZRP bug".
#
# WHAT IT DOES NOT PROVE. This is a spike, not the transport. It says nothing
# about DZRP, nothing about the debugger, and nothing about real hardware —
# where the ESP has to be associated first (jnext has no AT+CWJAP= at all,
# only the query form) and where the module answers at 115200 until told
# otherwise. The fixture is pinned to 115200 for that reason even though the
# emulator would accept any rate.
#
# Environment (all set by the Makefile, all overridable):
#   JNEXT        path to the jnext binary
#   SD_IMAGE     reference SD card image; NEVER written, only copied
#   OUT          build directory
#   ESP_BIN      assembled test/esp_server.asm

set -euo pipefail

JNEXT=${JNEXT:-$HOME/src/spectrum/jnext/build/gui-release/jnext}
SD_IMAGE=${SD_IMAGE:-$HOME/.jnext/sdcard/cspect-next-1gb-fixed.img}
OUT=${OUT:-build}
ESP_BIN=${ESP_BIN:-$OUT/esp_server.bin}

# Must match SERVER_PORT in test/esp_server.asm and esp-echo-client.py. It is
# DeZog's `cspect` default, which is why it is this number and not another.
PORT=11000

# The guest is injected once NextZXOS has booted, the same 900 frames
# run-headless.sh uses. The screenshot is taken late enough that the client
# has finished, so the border shows the LAST stage the fixture reached — which
# is the only diagnosis available when the socket checks fail.
BOOT_FRAMES=900
SHOT_FRAMES=2400
EXIT_FRAMES=2500

# Wall-clock guard. The run above takes ~12s.
RUN_TIMEOUT=180

CLIENT=$(dirname "$0")/esp-echo-client.py

log()  { printf '%s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# --- pre-flight ------------------------------------------------------------

[ -x "$JNEXT" ]    || die "jnext binary not found or not executable: $JNEXT"
[ -f "$SD_IMAGE" ] || die "SD card image not found: $SD_IMAGE"
[ -f "$ESP_BIN" ]  || die "ESP fixture not built: $ESP_BIN (run 'make test-esp')"
[ -f "$CLIENT" ]   || die "client not found: $CLIENT"

# Server mode arrived in jnext 0.99.118 (GH #210). Checked by name, because
# without it AT+CIPMUX=1 is answered ERROR and the fixture parks at border 2 —
# a failure that looks like a fixture bug and is not one.
"$JNEXT" --help 2>&1 | grep -q -- '--esp-listen-address' \
    || die "this jnext has no --esp-listen-address (need >= 0.99.118, found: $("$JNEXT" --help 2>&1 | grep -oE 'jnext [0-9.]+' | head -1)); rebuild it — the ESP server bench cannot run without it"

# A port already in use would make E1 connect to somebody else's listener and
# then fail the echo, which reads as a fixture bug. Say so up front instead.
if command -v ss >/dev/null 2>&1; then
    ! ss -ltn 2>/dev/null | grep -qE "127\.0\.0\.1:$PORT\b" \
        || die "something is already listening on 127.0.0.1:$PORT — stop it first (CSpect, a stale jnext?)"
fi

mkdir -p "$OUT"

# --- the run ---------------------------------------------------------------
#
# The reference image is never written: a reflink copy costs nothing where the
# filesystem supports it.
#
# AND IS A FULL GIGABYTE WHERE IT DOES NOT, which is why this one is deleted
# again at the end. `--reflink=auto` falls back to a real copy silently, and on
# tmpfs it always does — so a bench run from a scratchpad directory leaves a
# gigabyte behind with no warning. That is not hypothetical: ~22 GB of exactly
# these copies, abandoned by earlier bench runs in agent scratchpads, filled
# the /tmp quota on 2026-08-04 and took the shell down mid-session.
#
# Nothing is lost by removing it. The diagnostics this bench leaves are the
# screenshot and the jnext log; the image is a byte-for-byte copy of a
# reference file that is still sitting where it always was.
sd=$OUT/sd-esp.img
shot=$OUT/screenshots/esp-server.png
jlog=$OUT/esp-server.log
mkdir -p "$(dirname "$shot")"

# THE TRAP IS ARMED BEFORE THE COPY, and that ordering is the whole point.
#
# Arming it after the emulator launches — the obvious place, next to the pid it
# has to kill — leaves the copy itself unprotected, and the copy is the slowest
# thing here and therefore the likeliest moment to be interrupted. Killing the
# script during it was measured to leave a 777 MB partial image behind with no
# handler to remove it.
#
# So `jnext_pid` is declared empty first and cleanup tolerates that: under
# `set -u` an unset variable inside the trap would abort the handler before it
# reached the `rm`, turning a leak fix into a leak.
#
# Kill by PID, never by pattern: a pkill pattern matches this script's own
# command line and takes the bench down with the emulator.
jnext_pid=""
cleanup() {
    if [ -n "$jnext_pid" ] && kill -0 "$jnext_pid" 2>/dev/null; then
        kill "$jnext_pid" 2>/dev/null || true
        wait "$jnext_pid" 2>/dev/null || true
    fi
    rm -f "$sd"
}
trap cleanup EXIT
# A handler that just RETURNS does not stop a bash script: the shell defers the
# signal until the running foreground command finishes, runs the handler, and
# then carries on with the next line. Trapping INT/TERM with `cleanup` alone
# therefore cleaned up and then completed the run as if nothing had happened —
# which looks identical to a working interrupt from the outside, because the
# image is gone either way. These two handlers exit instead, and the EXIT trap
# above does the cleaning on the way out.
trap 'exit 130' INT
trap 'exit 143' TERM

cp --reflink=auto -f "$SD_IMAGE" "$sd"

log "== running the ESP server bench (1 headless jnext run + a TCP client, ~15s)"

rm -f "$shot"
timeout "$RUN_TIMEOUT" "$JNEXT" \
    --headless --machine next \
    --sdcard "$sd" \
    --rtc "2026-01-01 12:00:00" \
    --esp --esp-listen-address 127.0.0.1 \
    --inject "$ESP_BIN" --inject-org 8000 --inject-pc 8000 --inject-delay "$BOOT_FRAMES" \
    --delayed-screenshot "$shot" --delayed-screenshot-frames "$SHOT_FRAMES" \
    --delayed-automatic-exit-frames "$EXIT_FRAMES" \
    >"$jlog" 2>&1 &
jnext_pid=$!

log ""
set +e
python3 "$CLIENT"
client_rc=$?
set -e

# Let the run finish on its own so the screenshot is written. The EXIT trap
# stays armed: it is what removes the working image, on every path out of here.
wait "$jnext_pid" 2>/dev/null || true

# --- verdict ---------------------------------------------------------------

log ""
if [ "$client_rc" -eq 0 ]; then
    log "All checks passed."
else
    # The border is the fixture's own progress report, and on a failure it is
    # the only thing that says WHERE it stopped. Each colour is set on the
    # success of a step, so the colour names the last step that worked.
    log "Diagnosis:"
    log "  jnext log:   $jlog"
    log "  screenshot:  $shot"
    log "  the border colour is the last stage the fixture completed —"
    log "    0 black   nothing (never injected?)      4 green   CIPSERVER OK, listening"
    log "    1 blue    UART up                        5 cyan    CIFSR OK, waiting for a client"
    log "    2 red     the module answered AT         6 yellow  a +IPD was parsed"
    log "    3 magenta CIPMUX=1 OK                    7 white   an echo was acknowledged"
    grep -iE 'esp01|error' "$jlog" | tail -20 | sed 's/^/  | /' || true
fi

exit "$client_rc"
