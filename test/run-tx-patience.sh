#!/usr/bin/env bash
#
# THE SEND-WAIT BUDGET, exercised on the real Z80 code.
#
# Invoked by `make test-tx-patience`. Three headless jnext runs, each with a
# WiFi ROM whose ESP_RX_WAIT and/or ESP_TX_PASSES have been moved, an emulated
# M1 button press, and one DZRP exchange over the emulated ESP-01.
#
# WHY THIS BENCH EXISTS
#
# Issue #11. On real hardware the stub abandoned sends that were working: H3
# failed 3 runs of 3 and H5 truncated a 4097-byte loopback at 236 bytes — about
# one ESP_TX_CHUNK delivered and then nothing — with "Last Error: TX Timeout"
# on the Next's screen. The cause was esp_flush_chunk's two waits, for
# AT+CIPSEND's '>' prompt and for the SEND OK that closes the chunk, running on
# the same single-pass budget as main_loop's idle poll: about 100 ms, which a
# real ESP-01 overran. The fix raises the budget around exactly those two waits
# and lowers it again, so the idle poll keeps its short one.
#
# NO ORDINARY RUN HERE CAN REACH THAT, and that is the whole problem. jnext
# answers an AT+CIPSEND at once, so 100 ms is never approached and the timeout
# arm is dead code in the emulator — `make test-dzrp-stub` was green before the
# fix and is green after it, exactly as it was for the connection-id disaster
# that also cost a hardware session (transport_esp.asm, point 3).
#
# So the BUDGET is moved instead of the module, in the same shape as
# run-ip-boundary.sh moves the address bound instead of the address.
# ESP_RX_WAIT=1600 makes one pass ~3.9 ms at 28 MHz, which is shorter than the
# time jnext itself takes to answer an AT+CIPSEND for a full chunk. The code
# under test is the shipped code on the emulated machine talking to a real
# emulated module over a real UART; only build-time constants differ.
#
#   P1  RX_WAIT=1600  TX_PASSES=10  the SHIPPED patience against an injected
#                                   slow module -> the exchange completes
#   P2  RX_WAIT=1600  TX_PASSES=1   the PRE-FIX single budget, same module
#                                   -> a reply is lost and the stub reports
#                                      "Last Error: TX Timeout"
#   P3  RX_WAIT default (40000) TX_PASSES=1
#                                   -> completes. P2's red is the injected
#                                      budget, not TX_PASSES=1 by itself
#
# P3 IS NOT PADDING. Without it P2 only shows that a build with TX_PASSES=1
# fails, and the obvious reading — "the fix is load-bearing" — would be
# unearned: the same red would appear if the seam itself broke the stub.
# ERRORS.md's standing complaint is that a fix never tested by removing it is a
# correlation; P3 is what makes P2's removal a controlled one, since P2 and P3
# differ only in RX_WAIT and P1 and P2 only in TX_PASSES.
#
# THE MEASURED NUMBERS BEHIND THE CHOICE OF 1600, one exchange per cell,
# CMD_INIT then a 1024-byte CMD_LOOPBACK:
#
#   RX_WAIT   TX_PASSES=1                      TX_PASSES=10
#     400     CMD_INIT lost                    loopback lost
#     800     CMD_INIT lost                    loopback truncated at 716 bytes
#    1600     a reply lost, 4 of 4 runs        both exact, 4 of 4 runs
#   40000     both exact, 6 of 6 runs          both exact (the shipped ROM)
#
# 800/TX_PASSES=10 is worth keeping in view: 716 of 1025 bytes is three chunks
# and then silence, which is H5's hardware symptom to within a chunk.
#
# WHICH exchange P2 loses varies run to run — 3 of 4 lose the loopback, 1 of 4
# CMD_INIT — and the client is written so that only "did both complete" is
# asserted. The reason is arithmetic rather than luck: the module owes SEND OK
# only once it has taken the whole chunk, so a 25-byte reply costs ~2 ms and a
# 240-byte one ~21 ms, and 3.9 ms sits between them.
#
# ONE HARNESS RACE HAD TO BE REMOVED FIRST, and it is worth recording because
# it produced 2 failures in 8 runs of a build that was FINE. The listener exists
# as soon as AT+CIPSERVER is accepted, but the guest then sends AT+CIFSR and
# scans the answer for OK; a client connecting inside that window puts
# 1,CONNECT / 1,CLOSED into the same scan and its first command is eaten. Hence
# SETTLE below. That is a real (small) property of bring-up, noted here rather
# than fixed, because it belongs with M3's reconnect work.
#
# WHAT THIS BENCH DOES NOT DO. It does not measure a real ESP-01, and nothing
# here can: ESP_TX_PASSES=10 is a judgement call about hardware latency (see
# transport_esp.asm) and this only shows that raising the budget rides out a
# module slower than one pass, and that lowering it does not. The hardware
# question is still H3 and H5 on a real Next.
#
# Environment (all set by the Makefile, all overridable):
#   JNEXT         path to the jnext binary
#   SD_IMAGE      reference SD card image; NEVER written, only copied
#   OUT           build directory
#   ROM_FIXED     WiFi ROM, RX_WAIT=1600 TX_PASSES=10
#   ROM_PREFIX    WiFi ROM, RX_WAIT=1600 TX_PASSES=1
#   ROM_CONTROL   WiFi ROM, default RX_WAIT, TX_PASSES=1

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
ROM_FIXED=${ROM_FIXED:-$OUT/enNextMf-wifi-rxwait1600-txp10.rom}
ROM_PREFIX=${ROM_PREFIX:-$OUT/enNextMf-wifi-rxwait1600-txp1.rom}
ROM_CONTROL=${ROM_CONTROL:-$OUT/enNextMf-wifi-txp1.rom}

CLIENT=$(dirname "$0")/dzrp/tx-patience-client.py

PORT=11000
LOOPBACK_SIZE=1024

# NextZXOS needs ~900 frames to reach the welcome screen; the button is pressed
# there, exactly as run-headless.sh's T6 does.
BOOT_FRAMES=900

# Late enough to be reached AFTER the exchange, which is what makes the error
# area worth reading: the stub paints "Last Error: ..." within a frame or two of
# the timeout, and frames run fast while no DZRP traffic is flowing. Measured to
# land after every exchange in every run of the table above.
SHOT_FRAMES=3000

# A backstop only; the run is ended by killing jnext once the exchange is done.
EXIT_FRAMES=200000

# See the harness-race note above.
SETTLE=${SETTLE:-2}

# Long enough that a slow emulator is not mistaken for a lost reply, short
# enough that P2's expected failure does not dominate the bench's runtime.
CLIENT_TIMEOUT=20

RUN_TIMEOUT=300
LISTEN_TIMEOUT=90
SHOT_TIMEOUT=60

MF_ROM_PATH='::/machines/next/enNextMf.rom'

# Shared jnext teardown — issue #17. Defines functions and nothing else, so it
# cannot disturb the `set -euo pipefail` above or the traps below.
# shellcheck source=test/bench-jnext.sh
. "$(dirname "$0")/bench-jnext.sh"

log()  { printf '%s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# --- pre-flight ------------------------------------------------------------

[ -x "$JNEXT" ]     || die "jnext binary not found or not executable: $JNEXT"
[ -f "$SD_IMAGE" ]  || die "SD card image not found: $SD_IMAGE"
[ -f "$CLIENT" ]    || die "client not found: $CLIENT"
python3 -c 'import PIL' 2>/dev/null || die "python3 Pillow is required to read the stub's screen"
command -v mcopy >/dev/null || die "mtools (mcopy) is required to install the ROM into the SD image"

for rom in "$ROM_FIXED" "$ROM_PREFIX" "$ROM_CONTROL"; do
    [ -f "$rom" ] || die "not built: $rom (run 'make test-tx-patience')"
    # The magic string issue #4 put at a fixed offset, used for what it is for:
    # a UART ROM here would boot, take the NMI, paint its UI and listen on
    # nothing, and the failure would read as a transport bug.
    variant=$(dd if="$rom" bs=1 skip=8160 count=19 2>/dev/null | tr -d '\0')
    [ "${variant#DeZoGiFnG_WIFI_}" != "$variant" ] \
        || die "$rom does not identify itself as a WiFi build (magic: '$variant')"
done

bench_jnext_supports "$JNEXT" '--esp-listen-address' \
    || die "this jnext has no --esp-listen-address (need >= 0.99.118); rebuild it"
bench_jnext_supports "$JNEXT" '--delayed-nmi' \
    || die "this jnext has no --delayed-nmi (need >= 0.99.118); rebuild it"

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

# --- the runs --------------------------------------------------------------
#
# The reference image is never written; the working copy is reflinked where the
# filesystem supports it and DELETED on the way out either way. The trap is
# armed BEFORE the copy, because the copy is the slowest thing here and so the
# likeliest moment to be interrupted; jnext_pid is declared empty first so
# `set -u` cannot abort the handler before it reaches the rm.

sd=$OUT/sd-txpatience.img
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

# bright_red <png> — how many pixels are EXACTLY bright red, i.e. how much
# "Last Error: ..." is on the screen. ui.asm colours the bottom nine rows
# RED+BRIGHT and nothing else on that screen is red at all; jnext renders
# non-bright components as 182 and bright as 255, and `out (BORDER),a` carries
# no bright bit, so exact (255,0,0) can only be that error text. Zero means the
# stub reports no fault.
bright_red() {
    python3 -c "
from PIL import Image
raw = Image.open('$1').convert('RGB').tobytes()
print(sum(1 for i in range(0, len(raw), 3)
          if raw[i] == 255 and raw[i+1] == 0 and raw[i+2] == 0))
"
}

# run_exchange <rom> <logfile> <screenshot> — boot a Next with <rom> as the
# Multiface ROM, press M1, wait for the stub's own listener, run one DZRP
# exchange, and capture the stub's screen.
#
# Returns the client's exit code, or 10 if the listener never appeared, or 11 if
# no screenshot was written. Those two are told apart from a lost reply on
# purpose: they mean the run never got far enough to be evidence about anything.
run_exchange() {
    local rom=$1 logfile=$2 shotfile=$3
    rm -f "$shotfile"

    # Per run, not only at pre-flight: a foreign listener appearing between two
    # of this script's own runs would answer the client below, and a
    # contaminated run can come out GREEN (issue #17).
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

    local i listening=0
    for i in $(seq $((LISTEN_TIMEOUT * 4))); do
        kill -0 "$jnext_pid" 2>/dev/null || break
        if python3 -c "
import socket, sys
s = socket.socket(); s.settimeout(0.2)
sys.exit(0 if s.connect_ex(('127.0.0.1', $PORT)) == 0 else 1)
" 2>/dev/null; then listening=1; break; fi
        sleep 0.25
    done

    local rc=10
    if [ "$listening" = 1 ]; then
        sleep "$SETTLE"
        rc=0
        python3 "$CLIENT" --host 127.0.0.1 --port "$PORT" \
            --timeout "$CLIENT_TIMEOUT" --size "$LOOPBACK_SIZE" \
            | sed 's/^/  | /' || rc=$?

        for i in $(seq $((SHOT_TIMEOUT * 4))); do
            [ -s "$shotfile" ] && break
            kill -0 "$jnext_pid" 2>/dev/null || break
            sleep 0.25
        done
    fi

    if [ -n "$jnext_pid" ] && kill -0 "$jnext_pid" 2>/dev/null; then
        kill "$jnext_pid" 2>/dev/null || true
        wait "$jnext_pid" 2>/dev/null || true
    fi
    jnext_pid=""
    rm -f "$sd"
    # That killed and reaped the `timeout` WRAPPER, which says nothing about
    # jnext or about port 11000. The next run — and the next bench to take the
    # lock — must not inherit this one's listener. Issue #17.
    bench_await_departure "$sd"

    [ "$rc" -eq 10 ] && return 10
    [ -s "$shotfile" ] || return 11
    return "$rc"
}

# ===========================================================================

log "== P1: the shipped budget (ESP_TX_PASSES=10) against a module slower than one pass"

rc=0
run_exchange "$ROM_FIXED" "$OUT/tx-patience-fixed.log" \
             "$OUT/screenshots/tx-patience-fixed.png" || rc=$?
if [ "$rc" -eq 10 ]; then
    fail "P1 the stub's listener never appeared — the run never got far enough to judge"
elif [ "$rc" -eq 11 ]; then
    fail "P1 no screenshot was written, so the error area could not be checked"
elif [ "$rc" -ne 0 ]; then
    fail "P1 the exchange did not complete at ESP_TX_PASSES=10: the injected module is too slow to be a fair test"
else
    red=$(bright_red "$OUT/screenshots/tx-patience-fixed.png")
    if [ "$red" -ne 0 ]; then
        fail "P1 the exchange completed but the stub reports a fault ($red bright-red pixels)"
    else
        pass "P1 CMD_INIT and a ${LOOPBACK_SIZE}-byte loopback both completed, and the stub reports no error"
    fi
fi

log ""
log "== P2: the pre-fix single budget (ESP_TX_PASSES=1), same injected module"

rc=0
run_exchange "$ROM_PREFIX" "$OUT/tx-patience-prefix.log" \
             "$OUT/screenshots/tx-patience-prefix.png" || rc=$?
if [ "$rc" -eq 10 ]; then
    fail "P2 the stub's listener never appeared — the run never got far enough to judge"
elif [ "$rc" -eq 11 ]; then
    fail "P2 no screenshot was written, so the error area could not be checked"
elif [ "$rc" -eq 0 ]; then
    fail "P2 the exchange COMPLETED with the pre-fix budget: the injection misses the send waits, so P1 proves nothing"
else
    red=$(bright_red "$OUT/screenshots/tx-patience-prefix.png")
    if [ "$red" -eq 0 ]; then
        fail "P2 a reply was lost but the stub reports NO error, so it is not this bench's TX timeout"
    else
        pass "P2 a reply was lost and the stub reports 'Last Error: TX Timeout' ($red bright-red pixels), issue #11's symptom"
    fi
fi

log ""
log "== P3: control — the same ESP_TX_PASSES=1 build at the SHIPPED ESP_RX_WAIT"

rc=0
run_exchange "$ROM_CONTROL" "$OUT/tx-patience-control.log" \
             "$OUT/screenshots/tx-patience-control.png" || rc=$?
if [ "$rc" -eq 10 ]; then
    fail "P3 the stub's listener never appeared — the run never got far enough to judge"
elif [ "$rc" -eq 11 ]; then
    fail "P3 no screenshot was written, so the error area could not be checked"
elif [ "$rc" -ne 0 ]; then
    fail "P3 the exchange did not complete even at the shipped ESP_RX_WAIT, so P2's red is not the injected budget"
else
    red=$(bright_red "$OUT/screenshots/tx-patience-control.png")
    if [ "$red" -ne 0 ]; then
        fail "P3 the exchange completed but the stub reports a fault ($red bright-red pixels)"
    else
        pass "P3 the same build at the shipped ESP_RX_WAIT is fine: P2's red is the budget, not TX_PASSES=1"
    fi
fi

log ""
log "Diagnosis:"
log "  jnext logs:   $OUT/tx-patience-fixed.log  $OUT/tx-patience-prefix.log  $OUT/tx-patience-control.log"
log "  screenshots:  $OUT/screenshots/tx-patience-{fixed,prefix,control}.png"
log ""

total=3
if [ "$failures" -eq 0 ]; then
    log "All $total checks passed."
    exit 0
fi
log "$((total - failures))/$total passed, $failures FAILED."
exit 1
