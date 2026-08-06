#!/usr/bin/env bash
#
# VALIDATE THE ISSUE #15 PROBES AGAINST jnext, BEFORE THEY ARE POINTED AT A NEXT.
#
# Invoked by `make probe-jnext`. Two headless runs of the shipped WiFi ROM, one
# per probe:
#
#   V1  probe A — the slot-ceiling probe. It must find jnext's OWN documented
#       ceiling, which is 4.
#   V2  probe B — the vanished-peer probe. Fresh clients must survive exactly 3
#       vanished peers and be refused after the 4th. Needs root for one
#       firewall chain; SKIPPED, loudly, when that is not available.
#
# ===========================================================================
# WHY THIS EXISTS AT ALL, AND IT IS THE MOST IMPORTANT PART OF THE PAIR
# ===========================================================================
#
# A probe that never worked reports a negative result indistinguishable from a
# real one. This project has already paid for that once: the first hardware
# sweep of the CRLF swallow band reported a REFUTATION, and the refutation was
# a harness that read a DZRP response length as payload-only where it counts
# from the sequence byte, so every trial died on its first command and the
# verdict logic scored that as "answered" (ERRORS.md). The numbers were real.
# The instrument was not.
#
# Issue #15 has no reproduction. If probe A is pointed at a Next and reports
# "no ceiling found", that must mean the module has none in reach — not that
# the probe cannot see one. The only way to earn that is to point it first at a
# machine whose ceiling is KNOWN, and check it finds that number.
#
# ===========================================================================
# WHERE THE EXPECTED NUMBERS COME FROM — DERIVED, NOT CHOSEN
# ===========================================================================
#
# jnext, `src/esp01/include/esp01/esp_at.h`:
#
#   MAX_CONNECTIONS   = 5   ("ESP-AT's own AT+CIPMUX=1 limit (ids 0..4), which
#                            is why the table is this size")
#   FIRST_INBOUND_CID = 1   (slot 0 holds the BORROWED outbound transport, so
#                            an inbound connection may not take it —
#                            simplification 8a)
#
# so jnext serves MAX_CONNECTIONS - FIRST_INBOUND_CID = **4** inbound
# connections, and `src/esp01/src/esp_at.cpp:894-902` closes anything past that
# at once — "Real firmware refuses past its own ceiling too; ours is one lower
# because slot 0 is reserved".
#
#   V1 expects a ceiling of 4: four connections held open, the fifth dropped.
#
#   V2 expects fresh clients to survive 3. A vanished peer keeps its slot for
#   ever, and the fresh client that follows it needs one of its own — so with
#   four slots the first three vanishings leave one free and the fourth does
#   not. That is 4 - 1, derived from the same two constants.
#
# **REAL FIRMWARE SHOULD BE ONE HIGHER**, by jnext's own comment: nothing on a
# real module reserves a slot for outbound when the guest never sends
# AT+CIPSTART, so ids 0..4 are all available and the ceiling is **5**. That
# difference is not a nuisance — it is a CHECK. A probe reporting 4 against
# hardware would be reproducing an emulator artefact rather than measuring a
# module, and this project has been bitten twice by jnext's value sitting on the
# safe side of ours: a connection id of 0 that made the stub discard every
# reply, and a 15-character IP address the parser refused. Both were green in
# every emulator run.
#
# NEITHER NUMBER IS ASSERTED AGAINST HARDWARE. `--expect-ceiling` is passed
# here and must never be passed there: on a Next the number is the unknown being
# measured, and a probe that insisted on an answer would not be an instrument.
#
# ===========================================================================
# WHAT A GREEN RUN OF THIS DOES NOT ESTABLISH
# ===========================================================================
#
# That either probe measures a REAL module. jnext's ceiling is four integers in
# a header file, and its "connection" is a host TCP socket; a real ESP-01's is
# firmware with its own buffers, timers and failure modes. This shows the
# instruments can find a ceiling and can hold a slot open — nothing about what
# an ESP-01 does. And nothing here reproduces issue #15.
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
PROBE_A=$HERE/slot-ceiling-probe.py
PROBE_B_WRAPPER=$HERE/run-vanished-peer.sh

PORT=11000

# jnext's own numbers, derived above. Written here once and used twice, so a
# reader can see that V2's 3 is V1's 4 minus one rather than a second guess.
JNEXT_INBOUND_SLOTS=4
JNEXT_VANISH_SURVIVED=$((JNEXT_INBOUND_SLOTS - 1))

BOOT_FRAMES=900
SHOT_FRAMES=60000
EXIT_FRAMES=400000

# Seconds between the listener appearing and the first client connecting. The
# listener exists as soon as AT+CIPSERVER is accepted, but the guest then sends
# AT+CIFSR and scans the answer for OK; a client connecting inside that window
# puts `1,CONNECT` into the same scan and loses its first command. Same value
# and same reason as run-no-hang.sh, run-tx-patience.sh and run-dzrp-stub.sh.
SETTLE=${SETTLE:-2}

RUN_TIMEOUT=900
LISTEN_TIMEOUT=90

MF_ROM_PATH='::/machines/next/enNextMf.rom'

# Shared jnext teardown — issue #17. Defines functions and nothing else, so it
# cannot disturb the `set -euo pipefail` above or the traps below.
# shellcheck source=test/bench-jnext.sh
. "$HERE/bench-jnext.sh"

log() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# --- pre-flight ------------------------------------------------------------

[ -x "$JNEXT" ]    || die "jnext binary not found or not executable: $JNEXT"
[ -f "$SD_IMAGE" ] || die "SD card image not found: $SD_IMAGE"
[ -f "$PROBE_A" ]  || die "probe A not found: $PROBE_A"
[ -f "$ROM" ]      || die "not built: $ROM (run 'make probe-jnext')"
command -v mcopy >/dev/null || die "mtools (mcopy) is required to install the ROM into the SD image"
python3 -c 'import PIL' 2>/dev/null || die "python3 Pillow is required to read the stub's screen"

# The magic string issue #4 put at a fixed offset, used for what it is for: a
# UART ROM here would boot, take the NMI, paint its UI and listen on nothing,
# and the failure would read as a module finding.
variant=$(dd if="$ROM" bs=1 skip=8160 count=19 2>/dev/null | tr -d '\0')
[ "${variant#DeZoGiFnG_WIFI_}" != "$variant" ] \
    || die "$ROM does not identify itself as a WiFi build (magic: '$variant')"

"$JNEXT" --help 2>&1 | grep -q -- '--delayed-nmi' \
    || die "this jnext has no --delayed-nmi (need >= 0.99.118); rebuild it"

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

sd=$OUT/sd-probes.img
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
# A handler that only RETURNS does not stop a bash script — the shell defers the
# signal, runs the handler and carries on. These exit, and the EXIT trap cleans.
trap 'exit 130' INT
trap 'exit 143' TERM

failures=0
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; failures=$((failures + 1)); }
skip() { printf 'SKIP  %s\n' "$*"; }

# bright_red <png> — how many pixels are EXACTLY bright red, i.e. how much
# "Last Error: ..." is on the stub's screen. ui.asm colours the bottom nine rows
# RED+BRIGHT and nothing else on that screen is red at all; jnext renders a
# non-bright component as 182, and `out (BORDER),a` carries no bright bit, so
# exact (255,0,0) can only be that error text. The same measure W2, P2 and N3
# use.
#
# HERE IT IS AN OBSERVATION, NOT A CHECK. Issue #15's row 4 is that the screen
# stayed intact while TCP degraded, and this is the emulator's version of that
# same reading — reported so a reader can compare it with the photograph taken
# at the machine.
bright_red() {
    python3 -c "
from PIL import Image
raw = Image.open('$1').convert('RGB').tobytes()
print(sum(1 for i in range(0, len(raw), 3)
          if raw[i] == 255 and raw[i+1] == 0 and raw[i+2] == 0))
"
}

# start_stub <logfile> <screenshot> — boot a Next with our WiFi ROM as the
# Multiface ROM, press M1, and wait for the stub's own listener. That wait is an
# assertion in itself: the port can only exist once the NMI was taken, MAIN was
# relocated, UART0 came up and AT+CIPMUX=1 / AT+CIPSERVER=1,<port> were both
# accepted.
start_stub() {
    local logfile=$1 shotfile=$2
    rm -f "$shotfile"

    # Per run, not only at pre-flight: a foreign listener appearing between two
    # of this script's own runs would answer the probe we are about to start,
    # and a contaminated run can come out GREEN (issue #17).
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

# `jnext_pid` is the `timeout` WRAPPER's, so the kill and wait below say nothing
# about jnext or about port 11000. bench_await_departure is what turns "the
# wrapper is gone" into "the emulator is gone", and this bench must not drop the
# lock — or start its next run — before that is true. Issue #17.
stop_stub() {
    if [ -n "$jnext_pid" ] && kill -0 "$jnext_pid" 2>/dev/null; then
        kill "$jnext_pid" 2>/dev/null || true
        wait "$jnext_pid" 2>/dev/null || true
    fi
    jnext_pid=""
    rm -f "$sd"
    bench_await_departure "$sd"
}

# ===========================================================================

log "== V1: probe A must find jnext's own ceiling of $JNEXT_INBOUND_SLOTS inbound slots"
log ""

shot1=$OUT/screenshots/probe-a.png
log1=$OUT/probe-a.log
rc=0
if start_stub "$log1" "$shot1"; then
    python3 "$PROBE_A" --host 127.0.0.1 --port "$PORT" --timeout 10 \
        --limit 8 --expect-ceiling "$JNEXT_INBOUND_SLOTS" | sed 's/^/  | /' || rc=$?
    # The module really did drop somebody, from its own log rather than from
    # the probe's reading of a socket. Without this V1 could pass having
    # measured a stub that simply stopped answering.
    drops=$(grep -c 'inbound connection dropped' "$log1" || true)
    stop_stub
    if [ "$rc" -eq 2 ]; then
        fail "V1 the probe never reached the stub, so nothing was measured"
    elif [ "$rc" -eq 3 ]; then
        fail "V1 probe A did not measure jnext's documented ceiling of $JNEXT_INBOUND_SLOTS"
    elif [ "$rc" -ne 0 ]; then
        fail "V1 probe A exited $rc, which it should never do"
    elif [ "${drops:-0}" -lt 1 ]; then
        fail "V1 the module never reported dropping a connection, so the ceiling was not what stopped the walk"
    else
        pass "V1 probe A found the ceiling at $JNEXT_INBOUND_SLOTS and the module logged $drops drop(s)"
    fi
    red=0
    [ -s "$shot1" ] && red=$(bright_red "$shot1")
    log "  observation: the stub's error area held $red bright-red pixels while clients were dropped"
else
    stop_stub
    fail "V1 the stub's listener never appeared — the run never got far enough to judge"
fi

log ""
log "== V2: probe B must exhaust those slots with peers that never say goodbye"
log ""

if [ "$(id -u)" -ne 0 ] && ! sudo -n true 2>/dev/null; then
    skip "V2 needs root for one firewall chain and sudo would prompt — run: sudo -v, then make probe-jnext"
    log "     (probe B is NOT validated by this run. Do not point it at hardware on the strength of V1.)"
else
    shot2=$OUT/screenshots/probe-b.png
    log2=$OUT/probe-b.log
    rc=0
    if start_stub "$log2" "$shot2"; then
        SUDO=""
        [ "$(id -u)" -eq 0 ] || SUDO="sudo -n"
        # shellcheck disable=SC2086
        $SUDO "$PROBE_B_WRAPPER" --host 127.0.0.1 --port "$PORT" \
            --peers 6 --recover 5 --timeout 10 \
            --expect-ceiling "$JNEXT_VANISH_SURVIVED" 2>&1 | sed 's/^/  | /' || rc=$?
        drops=$(grep -c 'inbound connection dropped' "$log2" || true)
        stop_stub
        if [ "$rc" -eq 2 ]; then
            fail "V2 the probe never reached the stub, so nothing was measured"
        elif [ "$rc" -eq 3 ]; then
            fail "V2 fresh clients did not stop after $JNEXT_VANISH_SURVIVED vanished peers"
        elif [ "$rc" -ne 0 ]; then
            fail "V2 probe B exited $rc, which it should never do"
        elif [ "${drops:-0}" -lt 1 ]; then
            fail "V2 the module never dropped anybody, so no slot was ever really exhausted"
        else
            pass "V2 vanished peers exhausted the module after $JNEXT_VANISH_SURVIVED survivals, $drops drop(s) logged"
        fi
        red=0
        [ -s "$shot2" ] && red=$(bright_red "$shot2")
        log "  observation: the stub's error area held $red bright-red pixels while clients were dropped"
        # The wrapper cleans up its own chain; this is the independent second
        # opinion, because "it said it cleaned up" is not "it cleaned up".
        if $SUDO iptables -w -S 2>/dev/null | grep -q DEZOGIF_PROBE; then
            fail "V2 the firewall chain DEZOGIF_PROBE SURVIVED the run — remove it by hand now"
        else
            pass "V2 the firewall chain is gone, checked independently of the probe's own teardown"
        fi
    else
        stop_stub
        fail "V2 the stub's listener never appeared — the run never got far enough to judge"
    fi
fi

log ""
log "Diagnosis:"
log "  jnext logs:   $OUT/probe-a.log  $OUT/probe-b.log"
log "  screenshots:  $OUT/screenshots/probe-a.png  $OUT/screenshots/probe-b.png"
log ""
log "These are INSTRUMENT CHECKS. A green run says the probes can measure a"
log "ceiling in the emulator. It says nothing about a real ESP-01, and nothing"
log "at all about issue #15."
log ""

if [ "$failures" -eq 0 ]; then
    log "All instrument checks passed."
    exit 0
fi
log "$failures instrument check(s) FAILED."
exit 1
