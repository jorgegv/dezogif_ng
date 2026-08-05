#!/usr/bin/env bash
#
# The address parser's LENGTH BOUNDARY, exercised on the real Z80 code.
#
# Invoked by `make test-ip-boundary`. Two headless jnext runs, each with a WiFi
# ROM whose ESP_IP_MAX has been moved, and an emulated M1 button press.
#
# WHY THIS BENCH EXISTS, AND WHY IT LOOKS BACK TO FRONT
#
# esp_query_address copies the address out of AT+CIFSR's answer into a buffer
# bounded by ESP_IP_MAX, which ships as 15 — "255.255.255.255". The first
# version of that loop bounded the number of READ PASSES rather than the number
# of characters STORED, so the pass that should have read the closing quote
# after a maximum-length address had already been spent on the last character.
# An address of exactly 15 characters was therefore refused as "too long", and
# the screen told the user their WiFi was not set up on a machine that was
# working perfectly. 192.168.100.136 is 15 characters; this was an ordinary
# address, not a contrived maximum.
#
# EVERY BENCH IN THIS REPOSITORY WAS GREEN THROUGH THAT BUG, and no amount of
# care would have changed it. jnext's module answers 192.168.1.50 — twelve
# characters — and that is a `static constexpr STA_IP` in
# esp01/include/esp01/esp_at.h with no command-line option behind it. Twelve
# never reaches fifteen, so the boundary was simply not reachable.
#
# So the bound is moved instead of the address. With ESP_IP_MAX=12, jnext's own
# answer IS the maximum-length case; with 11, it is the one-too-long case. The
# code under test is the shipped code, running on the emulated machine, reading
# a real AT+CIFSR reply off a real UART — only a build-time constant differs.
# The alternative considered was a host-side model of the loop, which would
# have tested a transcription of that code rather than that code.
#
#   B1  ESP_IP_MAX=12  an address of exactly the bound is ACCEPTED
#                      -> the stub draws its connect line and reports no error
#   B2  ESP_IP_MAX=11  an address one over the bound is REFUSED
#                      -> the stub reports ERROR_NO_WIFI_ADDRESS
#
# B1 IS THE ONE THAT DISCRIMINATES. B2 passes against the broken loop as well,
# because that loop refused everything at the bound and above; it is here so
# that a "fix" which simply stopped bounding anything cannot pass. Both are
# needed and only together do they pin the boundary down.
#
# THE VERDICT IS READ OFF THE STUB'S OWN SCREEN, as bright-red pixels, the same
# measure bench W2 uses. ui.asm colours the bottom nine rows RED+BRIGHT and
# prints "Last Error: ..." there; jnext renders non-bright components as 182
# and bright as 255, and `out (BORDER),a` carries no bright bit, so exact
# (255,0,0) can only be that error text.
#
# WHAT IT DOES NOT COVER. The maximum-length line has never been RENDERED: the
# longest address jnext can produce is 12 characters, so the 32-column worst
# case (11 for "Connect at ", 15 for the address, 6 for ":11000") is unreachable
# here whatever the bound is set to. That one is held by an assembler ASSERT in
# transport_esp.asm instead, which is compile-time proof rather than a run.
#
# Environment (all set by the Makefile, all overridable):
#   JNEXT         path to the jnext binary
#   SD_IMAGE      reference SD card image; NEVER written, only copied
#   OUT           build directory
#   ROM_OK        WiFi ROM built with ESP_IP_MAX=12
#   ROM_TOOLONG   WiFi ROM built with ESP_IP_MAX=11

set -euo pipefail

# ---------------------------------------------------------------------------
# Bench mutex — see run-dzrp-stub.sh for the full reasoning. Two benches
# running at once bind the same port and answer each other's clients, and a
# contaminated run can come out GREEN.
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
ROM_OK=${ROM_OK:-$OUT/enNextMf-wifi-ipmax12.rom}
ROM_TOOLONG=${ROM_TOOLONG:-$OUT/enNextMf-wifi-ipmax11.rom}

# The address jnext's module reports, and its length. Both are asserted below
# rather than assumed: if jnext ever changes STA_IP, the bounds this bench
# chose stop meaning what they were chosen to mean, and it must say so instead
# of quietly testing nothing.
JNEXT_IP='192.168.1.50'
JNEXT_IP_LEN=${#JNEXT_IP}

BOOT_FRAMES=900
SHOT_FRAMES=1400
EXIT_FRAMES=1500
RUN_TIMEOUT=300

MF_ROM_PATH='::/machines/next/enNextMf.rom'

# Must match ESP_SERVER_PORT in src/transport_esp.asm. Nothing here talks to it
# — the verdict is read off the screen — but the stub still binds it, so the
# port has to be free before a run and free again after one. Issue #17.
PORT=11000

# Shared jnext teardown — issue #17. Defines functions and nothing else, so it
# cannot disturb the `set -euo pipefail` above or the traps below.
# shellcheck source=test/bench-jnext.sh
. "$(dirname "$0")/bench-jnext.sh"

log()  { printf '%s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# --- pre-flight ------------------------------------------------------------

[ -x "$JNEXT" ]        || die "jnext binary not found or not executable: $JNEXT"
[ -f "$SD_IMAGE" ]     || die "SD card image not found: $SD_IMAGE"
[ -f "$ROM_OK" ]       || die "not built: $ROM_OK (run 'make test-ip-boundary')"
[ -f "$ROM_TOOLONG" ]  || die "not built: $ROM_TOOLONG (run 'make test-ip-boundary')"
python3 -c 'import PIL' 2>/dev/null || die "python3 Pillow is required to read the stub's screen"
command -v mcopy >/dev/null || die "mtools (mcopy) is required to install the ROM into the SD image"

"$JNEXT" --help 2>&1 | grep -q -- '--delayed-nmi' \
    || die "this jnext has no --delayed-nmi (need >= 0.99.118); rebuild it"

# The whole design rests on 12 sitting strictly between the two bounds. Said
# out loud so a future jnext cannot silently invalidate it.
[ "$JNEXT_IP_LEN" -eq 12 ] || die "JNEXT_IP is $JNEXT_IP_LEN characters, not 12; re-choose the bounds"

for rom in "$ROM_OK" "$ROM_TOOLONG"; do
    variant=$(dd if="$rom" bs=1 skip=8160 count=19 2>/dev/null | tr -d '\0')
    [ "${variant#DeZoGiFnG_WIFI_}" != "$variant" ] \
        || die "$rom does not identify itself as a WiFi build (magic: '$variant')"
done

part_lba=$(od -An -tu4 -j 454 -N 4 "$SD_IMAGE" | tr -d ' ')
[ -n "$part_lba" ] && [ "$part_lba" -gt 0 ] || die "cannot read partition table from $SD_IMAGE"
part_off=$((part_lba * 512))

mkdir -p "$OUT" "$OUT/screenshots"

# --- the runs --------------------------------------------------------------
#
# The reference image is never written; the working copy is reflinked where the
# filesystem supports it and DELETED on the way out either way. The trap is
# armed before the copy, because the copy is the slowest thing here.

sd=$OUT/sd-ipboundary.img
jnext_pid=""
cleanup() {
    if [ -n "$jnext_pid" ] && kill -0 "$jnext_pid" 2>/dev/null; then
        kill "$jnext_pid" 2>/dev/null || true
        wait "$jnext_pid" 2>/dev/null || true
    fi
    # Unlinked BEFORE departure is confirmed: bench_await_departure can exit,
    # and an exit that skipped this would leak a gigabyte (ERRORS.md).
    rm -f "$sd"
    # And only now is the lock safe to drop — issue #17.
    bench_await_departure "$sd"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

failures=0
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; failures=$((failures + 1)); }

# bright_red <png> — how many pixels are EXACTLY bright red, i.e. how much
# "Last Error: ..." is on the screen. Zero means the stub reports no fault.
bright_red() {
    python3 -c "
from PIL import Image
raw = Image.open('$1').convert('RGB').tobytes()
print(sum(1 for i in range(0, len(raw), 3)
          if raw[i] == 255 and raw[i+1] == 0 and raw[i+2] == 0))
"
}

# run_stub <rom> <logfile> <screenshot> — boot a Next with <rom> as the
# Multiface ROM, press M1, capture the stub's screen, and stop.
run_stub() {
    local rom=$1 logfile=$2 shotfile=$3
    rm -f "$shotfile"

    # The stub binds the port even though nothing here connects to it, so a
    # foreign listener makes AT+CIPSERVER fail and the stub paints an error —
    # which this bench reads as its verdict. Refuse rather than mis-report.
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
    wait "$jnext_pid" 2>/dev/null || true
    jnext_pid=""
    rm -f "$sd"
    # That `wait` returned when the `timeout` WRAPPER exited, which says nothing
    # about jnext or about port 11000 — and the next run's stub cannot bind a
    # port this one is still holding. Issue #17.
    bench_await_departure "$sd"
    [ -s "$shotfile" ] || return 1

    # The reply really was the one this bench reasoned about. Without this the
    # checks below could be measuring a run in which AT+CIFSR never happened.
    grep -q "+CIFSR:STAIP,\"$JNEXT_IP\"" "$logfile" || return 2
    return 0
}

# ===========================================================================

log "== B1: an address of exactly ESP_IP_MAX characters ($JNEXT_IP, bound 12)"

rc=0
run_stub "$ROM_OK" "$OUT/ip-boundary-ok.log" "$OUT/screenshots/ip-boundary-ok.png" || rc=$?
if [ "$rc" -eq 1 ]; then
    fail "B1 no screenshot was written — the run did not get far enough to judge"
elif [ "$rc" -eq 2 ]; then
    fail "B1 the module never answered AT+CIFSR with $JNEXT_IP, so nothing was tested"
else
    red=$(bright_red "$OUT/screenshots/ip-boundary-ok.png")
    if [ "$red" -gt 0 ]; then
        fail "B1 an address of exactly the bound was REFUSED ($red bright-red pixels — the stub is showing 'No WiFi address'). The parser's bound counts read passes instead of stored characters, so the closing quote is never reached after a maximum-length address"
    else
        pass "B1 an address of exactly ESP_IP_MAX characters is accepted — no error on the stub's screen"
    fi
fi
log ""

log "== B2: an address one character over ESP_IP_MAX ($JNEXT_IP, bound 11)"

rc=0
run_stub "$ROM_TOOLONG" "$OUT/ip-boundary-toolong.log" "$OUT/screenshots/ip-boundary-toolong.png" || rc=$?
if [ "$rc" -eq 1 ]; then
    fail "B2 no screenshot was written — the run did not get far enough to judge"
elif [ "$rc" -eq 2 ]; then
    fail "B2 the module never answered AT+CIFSR with $JNEXT_IP, so nothing was tested"
else
    red=$(bright_red "$OUT/screenshots/ip-boundary-toolong.png")
    if [ "$red" -eq 0 ]; then
        fail "B2 an address one over the bound was ACCEPTED — the stub reports no error, so the parser is not bounding the copy at all"
    else
        pass "B2 an address one over ESP_IP_MAX is refused and reported ($red bright-red pixels)"
    fi
fi

# ===========================================================================

log ""
if [ "$failures" -ne 0 ]; then
    log "Diagnosis:"
    log "  jnext logs:   $OUT/ip-boundary-ok.log  $OUT/ip-boundary-toolong.log"
    log "  screenshots:  $OUT/screenshots/ip-boundary-ok.png  $OUT/screenshots/ip-boundary-toolong.png"
    log "  The screenshots show the stub's UI: rows 6 and 7 are the connect address"
    log "  or the reason there is not one."
fi

log "$((2 - failures))/2 checks passed"
exit "$((failures > 0 ? 1 : 0))"
