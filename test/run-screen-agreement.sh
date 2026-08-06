#!/usr/bin/env bash
#
# VALIDATE THE DZRP SCREEN READER AGAINST jnext's OWN PICTURE OF THE SAME SCREEN.
#
# Invoked by `make test-screen-agreement`. Two headless runs of the shipped WiFi
# ROM, differing in one command:
#
#   G1  a CLEAN screen. The 6912 bytes read over DZRP must render EXACTLY as
#       jnext drew them, and both views must agree the error area is empty.
#   G2  a screen with a REAL ERROR on it. Same three comparisons, plus the
#       error area must be non-empty and readable as text.
#
# ===========================================================================
# WHY THIS IS THE ONLY PLACE THE READER CAN BE CHECKED
# ===========================================================================
#
# test/dzrp/screen.py exists so that observations which used to need a human
# with a camera — doc/HARDWARE-TESTING.md's S1-S4 — become numbers in a bench.
# It has to be trusted on hardware, where there is nothing to check it against.
#
# Under jnext there are TWO INDEPENDENT VIEWS of the same 6912 bytes:
#
#   * the PNG, drawn by the emulator's own ULA renderer from its own memory,
#     through no code of ours;
#   * the DZRP read, produced by the Z80 stub answering CMD_READ_MEM over an
#     emulated UART and an emulated ESP-01, parsed by our client.
#
# They share nothing but the machine, and either can be right while the other
# is wrong. Agreement is therefore evidence; "the code looks correct" is not.
# This is available only in the emulator, which is precisely why the reader is
# validated here and believed there.
#
# ===========================================================================
# G2 IS THE HALF THAT DISCRIMINATES
# ===========================================================================
#
# A reader checked only against a blank error area has been checked against the
# easy case: every wrong answer agrees with the right one on zero. ERRORS.md
# already carries this shape twice — mfselect's M9, which two SWAPPED labels
# passed, and the ESP_IP_MAX bound no input could reach.
#
# So G2 puts a real error on the screen. The lever is command 42, which
# `get_cmd_pointer` routes to `cmd_not_supported` -> `drain_main`, painting
# `Last Error: / Command not supported` in bright red. NOT the tx-patience
# bench's injected TX budget, though that is the project's usual way to redden
# this screen: it works by making the module too slow to answer an AT+CIPSEND,
# and this bench has to read 6912 bytes back through that same transport. G1
# and G2 run the SAME SHIPPED ROM and differ by one command.
#
# ===========================================================================
# WHAT A GREEN RUN DOES NOT ESTABLISH
# ===========================================================================
#
# Anything about a real ESP-01. jnext's ULA renderer is not a real ULA and its
# module is not a real module. What this shows is that our display-file
# addressing, attribute decoding, palette and framing are right about a machine
# — which is exactly the part that travels to hardware, since the display file
# layout is the same silicon either way.
#
# It also does not check the BORDER, which is not in the display file and which
# the reader therefore cannot see at all. That stays a human's job and the
# probes still say so.
#
# Environment (all set by the Makefile, all overridable):
#   JNEXT      path to the jnext binary
#   SD_IMAGE   reference SD card image; NEVER written, only copied
#   OUT        build directory
#   ROM        the WiFi ROM to install as the Multiface ROM

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
ROM=${ROM:-$OUT/enNextMf-wifi.rom}

HERE=$(cd "$(dirname "$0")" && pwd)
CLIENT=$HERE/dzrp/screen-agreement-client.py
COMPARE=$HERE/screen-agreement.py

PORT=11000
BOOT_FRAMES=900

# Far past the frame the client finishes at. Nothing can make a frame-scheduled
# capture wait for a TCP client, so the ordering is CHECKED below against the
# client's own timestamp rather than assumed from this number.
SHOT_FRAMES=12000
SHOT_TIMEOUT=180

# Seconds between the listener appearing and the first client connecting. Same
# value and same reason as run-probes-jnext.sh: a client landing inside
# bring-up's AT+CIFSR exchange loses its first command.
SETTLE=${SETTLE:-2}

RUN_TIMEOUT=900
LISTEN_TIMEOUT=90

MF_ROM_PATH='::/machines/next/enNextMf.rom'

# Shared jnext teardown — issue #17.
# shellcheck source=test/bench-jnext.sh
. "$HERE/bench-jnext.sh"

log() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# --- pre-flight ------------------------------------------------------------

[ -x "$JNEXT" ]    || die "jnext binary not found or not executable: $JNEXT"
[ -f "$SD_IMAGE" ] || die "SD card image not found: $SD_IMAGE"
[ -f "$CLIENT" ]   || die "client not found: $CLIENT"
[ -f "$COMPARE" ]  || die "comparison tool not found: $COMPARE"
[ -f "$ROM" ]      || die "not built: $ROM (run 'make test-screen-agreement')"
command -v mcopy >/dev/null || die "mtools (mcopy) is required to install the ROM into the SD image"
python3 -c 'import PIL' 2>/dev/null || die "python3 Pillow is required to read the screenshots"

variant=$(dd if="$ROM" bs=1 skip=8160 count=19 2>/dev/null | tr -d '\0')
[ "${variant#DeZoGiFnG_WIFI_}" != "$variant" ] \
    || die "$ROM does not identify itself as a WiFi build (magic: '$variant')"

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

# --- run scaffolding -------------------------------------------------------
#
# The reference image is never written; the working copy is DELETED on the way
# out. The trap is armed BEFORE the copy, because the copy is the slowest thing
# here and so the likeliest moment to be interrupted.

sd=$OUT/sd-screen-agreement.img
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
    bench_await_departure "$sd"
}
trap cleanup EXIT
# A handler that only RETURNS does not stop a bash script.
trap 'exit 130' INT
trap 'exit 143' TERM

failures=0
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; failures=$((failures + 1)); }

start_stub() {
    local logfile=$1 shotfile=$2
    rm -f "$shotfile"

    # Per run, not only at pre-flight: a foreign listener appearing between two
    # of this script's own runs would answer the client we are about to start.
    bench_require_port_free "$PORT" "before this run started"

    cp --reflink=auto -f "$SD_IMAGE" "$sd"
    mcopy -o -i "$sd@@$part_off" "$ROM" "$MF_ROM_PATH"

    timeout "$RUN_TIMEOUT" "$JNEXT" \
        --headless --machine next \
        --sdcard "$sd" \
        --rtc "2026-01-01 12:00:00" \
        --log-level "warn,esp01=debug" \
        --esp --esp-listen-address 127.0.0.1 \
        --delayed-nmi-frames "$BOOT_FRAMES" nmi \
        --delayed-screenshot "$shotfile" --delayed-screenshot-frames "$SHOT_FRAMES" \
        --delayed-automatic-exit-frames 400000 \
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

# `jnext_pid` is the `timeout` WRAPPER's, so the kill and wait below say nothing
# about jnext or about port 11000. bench_await_departure is what turns "the
# wrapper is gone" into "the emulator is gone" — issue #17.
stop_stub() {
    if [ -n "$jnext_pid" ] && kill -0 "$jnext_pid" 2>/dev/null; then
        kill "$jnext_pid" 2>/dev/null || true
        wait "$jnext_pid" 2>/dev/null || true
    fi
    jnext_pid=""
    rm -f "$sd"
    bench_await_departure "$sd"
}

# run_one <name> <label> <expect: clean|red> [--provoke-error]
run_one() {
    local name=$1 label=$2 expect=$3
    shift 3

    local shot=$OUT/screenshots/screen-agreement-$name.png
    local jlog=$OUT/screen-agreement-$name.log
    local cout=$OUT/screen-agreement-$name.client
    local raw=$OUT/screen-agreement-$name.bin

    rm -f "$raw" "$cout"

    if ! start_stub "$jlog" "$shot"; then
        stop_stub
        fail "$name the stub's listener never appeared — the run never got far enough to judge"
        return
    fi

    # THE CLIENT RUNS IN THE BACKGROUND AND HOLDS ITS CONNECTION OPEN until the
    # screenshot has landed. That is not scheduling convenience: a client that
    # disconnects makes the module emit `<id>,CLOSED`, which ends cmd_loop's
    # wait and then fails to parse as a `+IPD` header, so the stub reaches
    # drain_main and REPAINTS THE ERROR AREA (MEMORY.md, issue #16). Measured
    # here, not reasoned: with the client disconnecting immediately, both runs
    # failed with the screenshot reading `Last Error: / RX Timeout` where the
    # DZRP read had shown a clean area (G1) and `Command not supported` (G2).
    # The read was right and the picture was of a later screen.
    local sentinel=$OUT/screen-agreement-$name.captured
    rm -f "$sentinel"

    local crc=0
    python3 "$CLIENT" --host 127.0.0.1 --port "$PORT" --dump "$raw" \
        --hold-until "$sentinel" "$@" >"$cout" 2>&1 &
    local client_pid=$!

    # Wait for the read itself, while the client goes on holding the socket.
    local done_at="" i
    for i in $(seq 240); do
        done_at=$(awk '/^EXCHANGE_DONE /{print $2; exit}' "$cout" 2>/dev/null || true)
        [ -n "$done_at" ] && break
        kill -0 "$client_pid" 2>/dev/null || break
        sleep 0.25
    done

    if [ -z "$done_at" ]; then
        wait "$client_pid" 2>/dev/null || crc=$?
        sed 's/^/  | /' "$cout" || true
        stop_stub
        if [ "$crc" -eq 3 ]; then
            fail "$name command 42 was ANSWERED, so it no longer paints an error and G2 has no subject"
        else
            fail "$name the screen could not be read over DZRP (client exit $crc) — see $cout"
        fi
        return
    fi

    # Then the capture, with the connection still up.
    for i in $(seq $((SHOT_TIMEOUT * 2))); do
        [ -s "$shot" ] && break
        kill -0 "$jnext_pid" 2>/dev/null || break
        sleep 0.5
    done

    # Release the client only now. The screenshot is already on disk, so
    # whatever the disconnect repaints happens after both views were taken.
    # NON-EMPTY on purpose: the client requires a non-zero size, so that a file
    # seen half-created could never be read as the signal. An earlier version
    # wrote nothing here, the client never accepted it, and it held for its full
    # 300 s timeout instead — which still produced the right answer and hid a
    # broken handshake behind it.
    echo captured >"$sentinel"
    wait "$client_pid" 2>/dev/null || crc=$?
    sed 's/^/  | /' "$cout" || true
    stop_stub

    if [ "$crc" -ne 0 ]; then
        fail "$name the client exited $crc after reading — the hold handshake or the read is broken (see $cout)"
        return
    fi
    if [ ! -s "$raw" ]; then
        fail "$name nothing was dumped, so there is no DZRP view to compare"
        return
    fi

    if [ ! -s "$shot" ]; then
        fail "$name no screenshot was written ($shot), so there is only one view and nothing to compare"
        return
    fi

    # THE ORDERING, checked rather than assumed. Nothing can make jnext's
    # frame-scheduled capture wait for a TCP client, so a screenshot taken
    # BEFORE the read would be of a different screen and the disagreement would
    # be the bench's, not the reader's. The display file is static while the
    # stub idles — only the border cycles — so "after" is sufficient.
    local shot_at
    shot_at=$(stat -c %Y "$shot")
    if [ -n "$done_at" ] && [ "$(printf '%.0f' "$done_at")" -gt "$shot_at" ]; then
        fail "$name the capture ($shot_at) came BEFORE the DZRP read ($done_at): the bench, not the reader — raise SHOT_FRAMES"
        return
    fi

    local red
    red=$(awk '/^ERROR_PIXELS /{print $2; exit}' "$cout")
    case "$expect" in
        clean)
            if [ "${red:-0}" -ne 0 ]; then
                fail "$name the screen was meant to be CLEAN and the reader found $red bright-red pixels"
                return
            fi
            pass "$name the reader found a clean error area, as expected of an untouched stub"
            ;;
        red)
            if [ "${red:-0}" -eq 0 ]; then
                fail "$name no error was painted, so this run does not exercise the case that discriminates"
                return
            fi
            if ! grep -q '^ERROR_TEXT ' "$cout"; then
                fail "$name $red bright-red pixels but no readable error text: the reader sees ink it cannot decode"
                return
            fi
            pass "$name the reader found $red bright-red pixels and read them as text"
            ;;
    esac

    # The two views.
    local rc=0
    python3 "$COMPARE" --raw "$raw" --shot "$shot" --label "$label" || rc=$?
    if [ "$rc" -eq 0 ]; then
        : # the comparison prints its own PASS lines
    elif [ "$rc" -eq 2 ]; then
        fail "$name the two views could not be compared at all — see above"
    else
        failures=$((failures + 1))   # the comparison printed its own FAIL lines
    fi
}

# ===========================================================================

log "== G1: a clean screen, read over DZRP and compared with jnext's own picture"
log ""
run_one G1 G1 clean

log ""
log "== G2: the same ROM with a real error painted on it — the half that discriminates"
log ""
run_one G2 G2 red --provoke-error

log ""
log "Diagnosis:"
log "  jnext logs:   $OUT/screen-agreement-G1.log  $OUT/screen-agreement-G2.log"
log "  client output:$OUT/screen-agreement-G1.client  $OUT/screen-agreement-G2.client"
log "  raw screens:  $OUT/screen-agreement-G1.bin  $OUT/screen-agreement-G2.bin"
log "  screenshots:  $OUT/screenshots/screen-agreement-G1.png  $OUT/screenshots/screen-agreement-G2.png"
log ""
log "This validates the READER, in the one place two independent views of the"
log "same screen exist. It says nothing about a real ESP-01, and the reader"
log "cannot see the border in either place."
log ""

if [ "$failures" -eq 0 ]; then
    log "All checks passed."
    exit 0
fi
log "$failures check(s) FAILED."
exit 1
