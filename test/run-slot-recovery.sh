#!/usr/bin/env bash
#
# run-slot-recovery.sh — does a recovery give the module's inbound slots back?
# Issue #19. Two headless jnext runs, three checks, and the verdict is a socket
# rather than a picture.
#
#   S1  the SHIPPED sweep. Fill every inbound slot with connections that are
#       answered and then held, confirm the module stops granting them, inject
#       one transport fault so esp_recover runs, and require a FRESH client to
#       be served afterwards.
#   S2  the sweep really ran, from jnext's own log: one AT+CIPCLOSE per link id.
#       Not redundant with S1 — a module that freed slots for some other reason
#       would satisfy S1 and say nothing about this code.
#   S3  the control, LINK_IDS=0: esp_recover assembled exactly as it was before
#       #19. The same run must leave the fresh client UNSERVED.
#
# WHY S3 IS A BUILD SEAM AND NOT A SCRATCH TREE. The state being fixed here is
# unreachable in the shipped ROM by construction, so without a seam the red
# would be a story about a tree nobody can rebuild. S1 and S3 differ in exactly
# one assembler constant, which is what attributes S1's green to the sweep and
# not to the recovery it rides in.
#
# WHY THE FAULT IS INJECTED AT ALL. esp_recover fires after ESP_FAULT_LIMIT
# CONSECUTIVE faults, and jnext answers everything it is asked, so five in a row
# cannot be produced here. Both ROMs are built FAULT_LIMIT=1, the seam
# run-no-hang.sh's N4 already uses, so a single truncated command reaches it.
#
# WHAT A GREEN RUN DOES NOT ESTABLISH
#
#   * ANYTHING ABOUT A REAL ESP-01. jnext's ceiling is four inbound slots
#     because it reserves slot 0 for an outbound AT+CIPSTART; a real module was
#     measured at five (2026-08-06, probe A on the user's Next). The sweep is
#     written not to care, and this bench cannot check that it was right to be.
#   * WHICH ids the stub closed. No PC-side check can see them — they live
#     between the Z80 and the module — so S2 counts the commands, not the slots
#     they freed.
#   * That the peers here are WEDGED. They are answered and then silent, which
#     occupies a slot exactly as a wedged peer does; nothing here reproduces
#     whatever makes a real peer stop responding. Issue #19 is about the slot,
#     and the slot is what is measured.
#   * That this fixes issue #15. It removes one mechanism that produces #15's
#     outward signature. That is not the same claim, and #15 was closed on
#     other evidence.
#
# Environment (all set by the Makefile, all overridable):
#   JNEXT         path to the jnext binary
#   SD_IMAGE      reference SD card image; NEVER written, only copied
#   OUT           build directory
#   ROM_SWEEP     WiFi ROM, FAULT_LIMIT=1
#   ROM_NOSWEEP   the same, plus LINK_IDS=0

set -euo pipefail

# ---------------------------------------------------------------------------
# Bench mutex — see run-dzrp-stub.sh. Two benches running at once bind the same
# port and answer each other's clients, and a contaminated run can come out
# GREEN.
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
ROM_SWEEP=${ROM_SWEEP:-$OUT/enNextMf-wifi-fl1.rom}
ROM_NOSWEEP=${ROM_NOSWEEP:-$OUT/enNextMf-wifi-fl1-li0.rom}

CLIENT=$(dirname "$0")/dzrp/slot-recovery-client.py

PORT=11000

# How many link ids the shipped sweep asks about. Pinned here as well as in the
# source deliberately: S2 is worth nothing if it counts whatever it finds.
LINK_IDS=5

BOOT_FRAMES=900
SHOT_FRAMES=200000
EXIT_FRAMES=400000

# Seconds between the listener appearing and the first client connecting. The
# listener exists as soon as AT+CIPSERVER is accepted, but the guest then sends
# AT+CIFSR and scans the answer for OK; a client connecting inside that window
# puts `1,CONNECT` into the same scan and loses its first command. Same value
# and same reason as run-no-hang.sh and run-dzrp-stub.sh.
SETTLE=${SETTLE:-2}

CLIENT_TIMEOUT=10
RECLAIM_TIMEOUT=40
RUN_TIMEOUT=600
LISTEN_TIMEOUT=90

MF_ROM_PATH='::/machines/next/enNextMf.rom'

# Shared jnext teardown — issue #17. Defines functions and nothing else, so it
# cannot disturb the `set -euo pipefail` above or the traps below.
# shellcheck source=test/bench-jnext.sh
. "$(dirname "$0")/bench-jnext.sh"

log()  { printf '%s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# --- pre-flight ------------------------------------------------------------

[ -x "$JNEXT" ]    || die "jnext binary not found or not executable: $JNEXT"
[ -f "$SD_IMAGE" ] || die "SD card image not found: $SD_IMAGE"
[ -f "$CLIENT" ]   || die "client not found: $CLIENT"
command -v mcopy >/dev/null || die "mtools (mcopy) is required to install the ROM into the SD image"

for rom in "$ROM_SWEEP" "$ROM_NOSWEEP"; do
    [ -f "$rom" ] || die "not built: $rom (run 'make test-slot-recovery')"
    # The magic string issue #4 put at a fixed offset, used for what it is for:
    # a UART ROM here would boot, take the NMI, paint its UI and listen on
    # nothing, and the failure would read as a transport bug.
    variant=$(dd if="$rom" bs=1 skip=8160 count=19 2>/dev/null | tr -d '\0')
    [ "${variant#DeZoGiFnG_WIFI_}" != "$variant" ] \
        || die "$rom does not identify itself as a WiFi build (magic: '$variant')"
done

# The whole bench rests on this command existing in the emulator — it is why
# #19 waited on jnext#211 rather than shipping unexecutable Z80.
bench_jnext_supports "$JNEXT" '--esp-listen-address' \
    || die "this jnext has no --esp-listen-address (need >= 0.99.118); rebuild it"
# `grep -c`, not `grep -q`: -q exits at the first match and the SIGPIPE that
# gives `strings` comes back as 141 under pipefail, which is the defect the
# previous commit removed from nine benches. -c reads to EOF.
[ "$(strings "$JNEXT" 2>/dev/null | grep -c 'AT+CIPCLOSE=' || true)" -gt 0 ] \
    || die "this jnext has no AT+CIPCLOSE=<id> (need jnext#211, >= 0.99.127); rebuild it"

if command -v ss >/dev/null 2>&1; then
    ! ss -ltn 2>/dev/null | grep -qE "127\.0\.0\.1:$PORT\b" \
        || die "something is already listening on 127.0.0.1:$PORT — stop it first (CSpect, a stale jnext?)"
fi

part_lba=$(od -An -tu4 -j 454 -N 4 "$SD_IMAGE" | tr -d ' ')
[ -n "$part_lba" ] && [ "$part_lba" -gt 0 ] || die "cannot read partition table from $SD_IMAGE"
part_off=$((part_lba * 512))

mkdir -p "$OUT" "$OUT/screenshots"

# --- the runs --------------------------------------------------------------
#
# The reference image is never written; the working copy is reflinked where the
# filesystem supports it and DELETED on the way out either way. The trap is
# armed BEFORE the copy, because the copy is the slowest thing here and so the
# likeliest moment to be interrupted; jnext_pid is declared empty first so
# `set -u` cannot abort the handler before it reaches the rm.

sd=$OUT/sd-slotrec.img
jnext_pid=""
cleanup() {
    if [ -n "$jnext_pid" ] && kill -0 "$jnext_pid" 2>/dev/null; then
        kill "$jnext_pid" 2>/dev/null || true
        wait "$jnext_pid" 2>/dev/null || true
    fi
    # Unlinked BEFORE departure is confirmed: bench_await_departure can exit,
    # and an exit that skipped this would reintroduce the abandoned-gigabyte
    # leak ERRORS.md records.
    rm -f "$sd"
    # And only now is the lock safe to drop — issue #17.
    bench_await_departure "$sd"
}
trap cleanup EXIT
# A handler that only RETURNS does not stop a bash script — the shell defers the
# signal, runs the handler and carries on. These exit, and the EXIT trap cleans.
trap 'exit 130' INT
trap 'exit 143' TERM

failures=0
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; failures=$((failures + 1)); }

# The screenshot is a DIAGNOSTIC and nothing here asserts on it: the verdict is
# whether a socket was served, which is a stronger reading than any pixel count.
start_stub() {
    local rom=$1 logfile=$2 shotfile=$3
    rm -f "$shotfile"

    # Per run, not only at pre-flight: a foreign listener appearing between two
    # of this script's own runs would answer the client we are about to start,
    # and a contaminated run can come out GREEN (issue #17).
    bench_require_port_free "$PORT" "before this run started"

    cp --reflink=auto -f "$SD_IMAGE" "$sd"
    mcopy -o -i "$sd@@$part_off" "$rom" "$MF_ROM_PATH"

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
        kill -0 "$jnext_pid" 2>/dev/null || break
        if python3 -c "
import socket, sys
s = socket.socket(); s.settimeout(0.2)
sys.exit(0 if s.connect_ex(('127.0.0.1', $PORT)) == 0 else 1)
" 2>/dev/null; then
            sleep "$SETTLE"
            return 0
        fi
        sleep 0.25
    done
    return 1
}

stop_stub() {
    if [ -n "$jnext_pid" ] && kill -0 "$jnext_pid" 2>/dev/null; then
        kill "$jnext_pid" 2>/dev/null || true
        wait "$jnext_pid" 2>/dev/null || true
    fi
    jnext_pid=""
    rm -f "$sd"
    bench_await_departure "$sd"
}

# run_client <rom> <logfile> <shotfile> — leaves $rc, $drops, $stops, $closes,
# $listens set for the checks below. The counts come from jnext's own log, so a
# run that never reached the state being tested reports that instead of a
# verdict about it.
run_client() {
    local rom=$1 logfile=$2 shotfile=$3
    rc=0
    if start_stub "$rom" "$logfile" "$shotfile"; then
        python3 "$CLIENT" --host 127.0.0.1 --port "$PORT" \
            --timeout "$CLIENT_TIMEOUT" --reclaim-timeout "$RECLAIM_TIMEOUT" \
            | sed 's/^/  | /' || rc=$?
    else
        rc=99
    fi
    # The COMMAND line, not the module's acknowledgement of it — jnext logs both
    # and counting the pair would double every recovery.
    drops=$(grep -c 'inbound connection dropped' "$logfile" || true)
    stops=$(grep -c 'AT <- "AT+CIPSERVER=0"' "$logfile" || true)
    closes=$(grep -c 'AT <- "AT+CIPCLOSE=' "$logfile" || true)
    listens=$(grep -c 'AT+CIPSERVER=1,.* — listening' "$logfile" || true)
    stop_stub
}

# --- S1 / S2: the shipped sweep --------------------------------------------

log "== S1/S2: the shipped sweep — a recovery must give a slot back"

log1=$OUT/slot-recovery-sweep.log
run_client "$ROM_SWEEP" "$log1" "$OUT/screenshots/slot-recovery-sweep.png"

log "  drops=$drops recoveries=$stops closes=$closes listens=$listens (from $log1)"

if [ "$rc" -eq 99 ]; then
    fail "S1 the stub's listener never appeared, so nothing was tested"
    fail "S2 the run never got far enough to count the sweep's commands"
elif [ "$rc" -eq 2 ] || [ "$rc" -eq 1 ]; then
    fail "S1 the module granted too few connections to exhaust, so nothing was tested"
    fail "S2 the run never reached a recovery"
elif [ "$rc" -eq 3 ]; then
    fail "S1 the module never stopped granting slots, so this run had no ceiling to test"
    fail "S2 the run never reached a recovery"
elif [ "${drops:-0}" -lt 1 ]; then
    fail "S1 the module never logged a dropped connection, so the slots were never full"
    fail "S2 precondition failed with S1"
elif [ "${stops:-0}" -lt 1 ]; then
    fail "S1 the recovery never ran: no AT+CIPSERVER=0, so the fault count never reached its limit"
    fail "S2 the recovery never ran, so no sweep could have"
elif [ "${listens:-0}" -lt $((stops + 1)) ]; then
    fail "S1 the recovery ran $stops time(s) but the module listened only $listens, where $((stops + 1)) was owed"
    fail "S2 not judged: the recovery did not complete"
else
    if [ "$rc" -ne 0 ]; then
        fail "S1 the recovery ran and re-listened but a fresh client was still refused: no slot came back"
    else
        pass "S1 slots were full, the recovery ran, and a fresh client was served afterwards"
    fi
    # Per recovery, not in total: a second recovery would sweep again, and a
    # bench that accepted "at least five" would pass a sweep that ran once for
    # two recoveries.
    want=$((stops * LINK_IDS))
    if [ "${closes:-0}" -ne "$want" ]; then
        fail "S2 the sweep issued $closes AT+CIPCLOSE for $stops recovery(ies), where $want was owed"
    else
        pass "S2 the sweep issued one AT+CIPCLOSE per link id, $closes for $stops recovery(ies)"
    fi
fi

# --- S3: the control -------------------------------------------------------

log ""
log "== S3: the control, LINK_IDS=0 — esp_recover as it was before #19"

log2=$OUT/slot-recovery-nosweep.log
run_client "$ROM_NOSWEEP" "$log2" "$OUT/screenshots/slot-recovery-nosweep.png"

log "  drops=$drops recoveries=$stops closes=$closes listens=$listens (from $log2)"

if [ "$rc" -eq 99 ]; then
    fail "S3 the stub's listener never appeared, so the control tested nothing"
elif [ "$rc" -eq 1 ] || [ "$rc" -eq 2 ] || [ "$rc" -eq 3 ]; then
    fail "S3 the control never reached a ceiling, so its silence proves nothing"
elif [ "${drops:-0}" -lt 1 ]; then
    fail "S3 the module never logged a dropped connection, so the slots were never full"
elif [ "${stops:-0}" -lt 1 ]; then
    fail "S3 the recovery never ran, so the control did not reach the state it compares"
elif [ "${listens:-0}" -lt $((stops + 1)) ]; then
    fail "S3 the recovery ran $stops time(s) but re-listened only $listens times: it did not complete"
elif [ "${closes:-0}" -ne 0 ]; then
    fail "S3 the control issued $closes AT+CIPCLOSE, so LINK_IDS=0 did not remove the sweep"
elif [ "$rc" -eq 0 ]; then
    fail "S3 a fresh client was served WITHOUT the sweep, so S1's green is not the sweep"
else
    pass "S3 without the sweep the same run leaves a fresh client refused, as it did before #19"
fi

# --- verdict ---------------------------------------------------------------

log ""
if [ "$failures" -eq 0 ]; then
    log "All checks passed (3/3)."
else
    log "$failures check(s) FAILED."
fi
exit $((failures > 0))
