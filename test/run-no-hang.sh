#!/usr/bin/env bash
#
# WAITS THAT END, AND SENDS THAT ARE NOT ABANDONED — issue #16, parts A and B.
#
# Invoked by `make test-no-hang`. Three headless jnext runs against WiFi ROMs
# that differ from the shipped one only in build-time constants, in the same
# shape as run-tx-patience.sh and run-ip-boundary.sh:
#
#   N1  WAIT_SECS=0   the loop as it was BEFORE the bound existed. A client
#                     that speaks once and then goes quiet WITHOUT hanging up
#                     leaves the stub in cmd_loop's wait for ever, so the "B"
#                     key pressed during that silence is never polled and the
#                     border stays the yellow transport_read_byte left it.
#   N2  the SHIPPED   the same run, one constant away: the bound expires, the
#       WiFi ROM      stub returns to main_loop, the "B" key IS polled, and the
#                     border goes black.
#   N3  RX_WAIT=400   an AT+CIPSEND whose '>' prompt arrives later than the stub
#       TX_PASSES=1   is willing to wait. The stub must still have written the
#                     <len> bytes it announced, or the module is left counting
#                     them off against whatever it is told next. A SECOND client
#                     is the judge.
#
# ---------------------------------------------------------------------------
# WHAT N1/N2 MEASURE, AND WHAT THEY DELIBERATELY DO NOT
# ---------------------------------------------------------------------------
#
# "CAN IT STILL SERVE" IS NOT THE QUESTION, and asking it would have produced a
# check that passes either way. The wait ends on ANY byte from the module, so a
# second command — or a disconnect, which makes the module emit `<id>,CLOSED` —
# ends it in the unbounded build too. Measured on real hardware by the manager
# session on 2026-08-05: a client killed mid-command left the stub owed five
# payload bytes in that very loop, and the next connection was answered in 4 ms.
# This bench reports the trailing exchange and asserts nothing about it.
#
# THE VERDICT IS A KEYPRESS, because the point of the bound is that the debugger
# goes back to the loop where it answers its own machine. `main_loop` polls the
# keyboard; `cmd_loop`'s wait does not. So "B" — the border toggle the stub
# advertises on its own screen — is pressed during the silence, and the answer
# is the border colour in one screenshot:
#
#   unbounded : YELLOW. transport_read_byte writes YELLOW after every byte it
#               takes, nothing has written the border since, and the key was
#               never polled because main_loop was never reached.
#   bounded   : BLACK. check_key_border toggled slow_border_change off, which
#               blacks the border AND stops change_border_color touching it
#               again, so the colour is stable rather than caught mid-cycle.
#
# Expiry reports NO error, deliberately — an idle client is not a fault — so
# there is no red text to count here, which is what W2 and P2 use.
#
# TWO ORDERINGS HAVE TO HOLD, and one of them is asserted rather than assumed.
# The screenshot and the keypress happen at fixed emulated frame counts while
# everything else here is wall-clock, and headless jnext runs frames far faster
# than real time.
#
#   * The SCREENSHOT must come after the exchange. The client requires the file
#     to be ABSENT when its first command is answered and then waits for it, so
#     a picture taken too early exits 12 and the bench says the run proves
#     nothing rather than reporting an early yellow border as a hang.
#   * The KEYPRESS must come after the exchange too, and that one is left to
#     KEY_FRAMES. It fails SAFELY: a "B" pressed before the client connects is
#     handled in main_loop, turning slow_border_change off, and then CMD_INIT's
#     own border flash leaves YELLOW standing in BOTH runs — so N2 goes red and
#     says so, instead of N1 passing for the wrong reason.
#
# ---------------------------------------------------------------------------
# WHAT N3 MEASURES, AND WHERE ITS EVIDENCE STOPS
# ---------------------------------------------------------------------------
#
# esp_flush_chunk announces `AT+CIPSEND=<id>,<len>` and only then writes <len>
# bytes. If the '>' never comes inside the budget, the pre-fix code jumped to
# tx_timeout — walking away from a transaction it had already announced.
#
# jnext reproduces the consequence exactly, and by construction rather than by
# luck: its AT engine enters `Mode::Payload` the instant it accepts the command
# (esp01/src/esp_at.cpp:496, which also queues the prompt), counts every later
# byte against the outstanding length (:181), and has no timeout anywhere in
# between. So an abandoned send leaves the emulated module swallowing whatever
# the stub writes next — including the `AT+CIPSEND` for the NEXT client's reply.
#
# THE PROMPT ARM IS REACHED HERE BY MOVING A BUDGET, not by faking a module.
# RX_WAIT=400 makes one pass ~0.97 ms at 28 MHz, and TX_PASSES=1 gives the
# prompt exactly one pass; the command line itself is 17 characters, which is
# ~1.5 ms of transmission at 115200 before jnext can even see its terminator.
# So the budget is short of the wire, deterministically. Bring-up survives it:
# ESP_INIT_PASSES is 20 of those passes, and the tx-patience table already
# records this combination coming up and serving.
#
# ITS EVIDENCE IS EMULATOR-ONLY, AND THE HARDWARE POINTS THE OTHER WAY. Issue
# #15 offers the abandoned send as the best available explanation for a real
# Next needing a power cycle, and says in as many words that it is a reading
# rather than a measurement. On 2026-08-05 the manager session drove four
# candidate triggers at a real Next on build 000B — a client dying mid-command,
# a client that stops READING mid-response, connection churn, and an RST while
# the stub was blocked mid-flush — and NONE of them wedged it; every one
# recovered within ~3 s. So what N3 shows is that the stub no longer leaves a
# module in a state a module should never be left in, demonstrated on the only
# module that can be made to hold that state here. It does NOT show that this
# was #15's trigger, and nothing in this bench should be read as saying so.
#
# ---------------------------------------------------------------------------
# WHAT NOTHING HERE COVERS
# ---------------------------------------------------------------------------
#
# * THE SERIAL BUILD. Part A changes transport_uart.asm identically and no
#   bench in this repository can drive that transport headless — `make test`'s
#   T6 runs the serial ROM but attaches no client, so it never reaches cmd_loop
#   at all. The serial half of part A is unexercised, by construction.
# * The recovery in part C. Making the emulated module unresponsive is not
#   something jnext offers, so the fault counter reaching its limit has no run
#   behind it. See MEMORY.md and the comment on esp_recover.
# * Anything about a real ESP-01.
#
# Environment (all set by the Makefile, all overridable):
#   JNEXT         path to the jnext binary
#   SD_IMAGE      reference SD card image; NEVER written, only copied
#   OUT           build directory
#   ROM_UNBOUND   WiFi ROM, WAIT_SECS=0
#   ROM_BOUND     the shipped WiFi ROM
#   ROM_SLOWPROMPT WiFi ROM, RX_WAIT=400 TX_PASSES=1

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
ROM_UNBOUND=${ROM_UNBOUND:-$OUT/enNextMf-wifi-wait0.rom}
ROM_BOUND=${ROM_BOUND:-$OUT/enNextMf-wifi.rom}
ROM_SLOWPROMPT=${ROM_SLOWPROMPT:-$OUT/enNextMf-wifi-rxwait400-txp1.rom}

IDLE_CLIENT=$(dirname "$0")/dzrp/idle-client.py
SEND_CLIENT=$(dirname "$0")/dzrp/abandoned-send-client.py

PORT=11000

# NextZXOS needs ~900 frames to reach the welcome screen; the button is pressed
# there, exactly as run-headless.sh's T6 does.
BOOT_FRAMES=900

# The "B" press, and then the picture. Both must land after the exchange, and
# the shipped bound is 5 emulated seconds — ~250 frames — which has to fit
# between the exchange and the keypress. See the ordering note in the header for
# which of these is asserted and which fails safely. Measured: the exchange
# lands around frame @@EXCHANGE_FRAME@@ in these runs.
KEY_FRAMES=6000
SHOT_FRAMES=9000

# A backstop only; each run is ended by killing jnext once its client is done.
EXIT_FRAMES=400000

# Seconds between the listener appearing and the first client connecting. The
# listener exists as soon as AT+CIPSERVER is accepted, but the guest then sends
# AT+CIFSR and scans the answer for OK; a client connecting inside that window
# puts `1,CONNECT` into the same scan and loses its first command. Same value
# and same reason as run-tx-patience.sh and run-dzrp-stub.sh.
SETTLE=${SETTLE:-2}

CLIENT_TIMEOUT=20
SHOT_TIMEOUT=180
RUN_TIMEOUT=600
LISTEN_TIMEOUT=90

MF_ROM_PATH='::/machines/next/enNextMf.rom'

log()  { printf '%s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# --- pre-flight ------------------------------------------------------------

[ -x "$JNEXT" ]       || die "jnext binary not found or not executable: $JNEXT"
[ -f "$SD_IMAGE" ]    || die "SD card image not found: $SD_IMAGE"
[ -f "$IDLE_CLIENT" ] || die "client not found: $IDLE_CLIENT"
[ -f "$SEND_CLIENT" ] || die "client not found: $SEND_CLIENT"
python3 -c 'import PIL' 2>/dev/null || die "python3 Pillow is required to read the stub's screen"
command -v mcopy >/dev/null || die "mtools (mcopy) is required to install the ROM into the SD image"

for rom in "$ROM_UNBOUND" "$ROM_BOUND" "$ROM_SLOWPROMPT"; do
    [ -f "$rom" ] || die "not built: $rom (run 'make test-no-hang')"
    # The magic string issue #4 put at a fixed offset, used for what it is for:
    # a UART ROM here would boot, take the NMI, paint its UI and listen on
    # nothing, and the failure would read as a transport bug.
    variant=$(dd if="$rom" bs=1 skip=8160 count=19 2>/dev/null | tr -d '\0')
    [ "${variant#DeZoGiFnG_WIFI_}" != "$variant" ] \
        || die "$rom does not identify itself as a WiFi build (magic: '$variant')"
done

"$JNEXT" --help 2>&1 | grep -q -- '--esp-listen-address' \
    || die "this jnext has no --esp-listen-address (need >= 0.99.118); rebuild it"
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

sd=$OUT/sd-nohang.img
jnext_pid=""
cleanup() {
    if [ -n "$jnext_pid" ] && kill -0 "$jnext_pid" 2>/dev/null; then
        kill "$jnext_pid" 2>/dev/null || true
        wait "$jnext_pid" 2>/dev/null || true
    fi
    rm -f "$sd"
}
trap cleanup EXIT
# A handler that only RETURNS does not stop a bash script — the shell defers the
# signal, runs the handler and carries on. These exit, and the EXIT trap cleans.
trap 'exit 130' INT
trap 'exit 143' TERM

failures=0
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; failures=$((failures + 1)); }

# border_rgb <png> — the border colour, as "r,g,b".
#
# Sampled from the top-left corner, which is border on every Next screen mode
# and is never paper: jnext composes the border into the screenshot (it is the
# ULA that draws it). Four pixels are read and required to agree, so a sample
# that landed on something other than a flat border is a hard error rather than
# a number this bench would go on to compare.
border_rgb() {
    python3 -c "
from PIL import Image
import sys
im = Image.open('$1').convert('RGB')
w, h = im.size
pts = [(2, 2), (w - 3, 2), (2, h - 3), (w - 3, h - 3)]
seen = {im.getpixel(p) for p in pts}
if len(seen) != 1:
    sys.exit('the four border corners of $1 do not agree: %s' % sorted(seen))
print('%d,%d,%d' % seen.pop())
"
}

# jnext renders a non-bright colour component as 182 and a bright one as 255;
# `out (BORDER),a` carries no bright bit, so the border can only ever be one of
# the eight non-bright colours.
BORDER_BLACK=0,0,0
BORDER_YELLOW=182,182,0

# start_stub <rom> <logfile> <screenshot> — boot a Next with <rom> as the
# Multiface ROM, press M1, and wait for the stub's own listener. That wait is an
# assertion in itself: the port can only exist once the NMI was taken, MAIN was
# relocated, UART0 came up and AT+CIPMUX=1 / AT+CIPSERVER=1,<port> were both
# accepted. Returns non-zero if it never appears.
start_stub() {
    local rom=$1 logfile=$2 shotfile=$3
    local keypress_args=()
    [ -n "${KEYPRESS:-}" ] && keypress_args=(--delayed-keypress-frames "$KEY_FRAMES" "$KEYPRESS")
    rm -f "$shotfile"
    cp --reflink=auto -f "$SD_IMAGE" "$sd"
    mcopy -o -i "$sd@@$part_off" "$rom" "$MF_ROM_PATH"

    timeout "$RUN_TIMEOUT" "$JNEXT" \
        --headless --machine next \
        --sdcard "$sd" \
        --rtc "2026-01-01 12:00:00" \
        --log-level "warn,esp01=debug" \
        --esp --esp-listen-address 127.0.0.1 \
        --delayed-nmi-frames "$BOOT_FRAMES" nmi \
        "${keypress_args[@]}" \
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
}

# idle_run <rom> <log> <shot> — the N1/N2 body. Prints the client's output and
# returns its exit code, or 10 if the listener never appeared.
idle_run() {
    local rom=$1 logfile=$2 shotfile=$3 rc=0
    start_stub "$rom" "$logfile" "$shotfile" || { stop_stub; return 10; }
    python3 "$IDLE_CLIENT" --host 127.0.0.1 --port "$PORT" \
        --timeout "$CLIENT_TIMEOUT" --after-shot "$shotfile" \
        --shot-timeout "$SHOT_TIMEOUT" | sed 's/^/  | /' || rc=$?
    stop_stub
    return "$rc"
}

# ===========================================================================

KEYPRESS=b

log "== N1: control — the wait as it was BEFORE the bound (WAIT_SECS=0)"

shot1=$OUT/screenshots/no-hang-unbound.png
rc=0
idle_run "$ROM_UNBOUND" "$OUT/no-hang-unbound.log" "$shot1" || rc=$?
if [ "$rc" -eq 10 ]; then
    fail "N1 the stub's listener never appeared — the run never got far enough to judge"
elif [ "$rc" -eq 1 ]; then
    fail "N1 the first CMD_INIT was never answered, so the stub was never put into the wait this check is about"
elif [ "$rc" -eq 12 ]; then
    fail "N1 the screenshot was taken BEFORE the exchange — the border there says nothing about the silence, so this run is void (lower SHOT_FRAMES)"
elif [ "$rc" -eq 13 ]; then
    fail "N1 no screenshot was written, so the screen could not be checked"
elif [ "$rc" -ne 0 ]; then
    fail "N1 the client failed for a reason outside this check's subject (exit $rc)"
else
    border1=$(border_rgb "$shot1") || { fail "N1 $border1"; border1=; }
    if [ -n "$border1" ] && [ "$border1" != "$BORDER_YELLOW" ]; then
        fail "N1 the border is $border1, not the yellow ($BORDER_YELLOW) transport_read_byte leaves — something in the unbounded build DID reach main_loop, so N2's black would prove nothing about the bound"
    elif [ -n "$border1" ]; then
        pass "N1 with no bound the stub sat in cmd_loop's wait through the whole silence: 'B' was never polled and the border is still yellow ($border1)"
    fi
fi

log ""
log "== N2: the shipped bound, one constant away — same client, same silence, same key"

shot2=$OUT/screenshots/no-hang-bound.png
rc=0
idle_run "$ROM_BOUND" "$OUT/no-hang-bound.log" "$shot2" || rc=$?
if [ "$rc" -eq 10 ]; then
    fail "N2 the stub's listener never appeared — the run never got far enough to judge"
elif [ "$rc" -eq 1 ]; then
    fail "N2 the first CMD_INIT was never answered, so the stub was never put into the wait this check is about"
elif [ "$rc" -eq 12 ]; then
    fail "N2 the screenshot was taken BEFORE the exchange, so this run is void (lower SHOT_FRAMES)"
elif [ "$rc" -eq 13 ]; then
    fail "N2 no screenshot was written, so the screen could not be checked"
elif [ "$rc" -ne 0 ]; then
    fail "N2 the client failed for a reason outside this check's subject (exit $rc)"
else
    border2=$(border_rgb "$shot2") || { fail "N2 $border2"; border2=; }
    if [ -n "$border2" ] && [ "$border2" = "$BORDER_YELLOW" ]; then
        fail "N2 the border is still yellow — 'B' was never polled, so the bound did not expire and the stub never left cmd_loop's wait"
    elif [ -n "$border2" ] && [ "$border2" != "$BORDER_BLACK" ]; then
        fail "N2 the border is $border2 — neither the yellow of a stub still waiting nor the black of one that handled 'B'. Most likely the keypress landed before the exchange; see KEY_FRAMES"
    elif [ -n "$border2" ]; then
        pass "N2 the bound expired and the stub went back to its idle loop: 'B' was polled and the border is black ($border2)"
    fi
fi

KEYPRESS=
log ""
log "== N3: an AT+CIPSEND whose prompt came too late must still be completed"

shot3=$OUT/screenshots/no-hang-slowprompt.png
rc=0
if start_stub "$ROM_SLOWPROMPT" "$OUT/no-hang-slowprompt.log" "$shot3"; then
    python3 "$SEND_CLIENT" --host 127.0.0.1 --port "$PORT" \
        --timeout "$CLIENT_TIMEOUT" | sed 's/^/  | /' || rc=$?
    # The precondition, asserted from the module's own log rather than assumed:
    # the stub must really have announced at least one send. Without this a run
    # in which nothing was ever sent would pass N3 for the wrong reason.
    sends=$(grep -c 'AT+CIPSEND' "$OUT/no-hang-slowprompt.log" || true)
    stop_stub
    if [ "$rc" -eq 2 ]; then
        fail "N3 the client could not reach the stub at all, so nothing was tested"
    elif [ "${sends:-0}" -lt 1 ]; then
        fail "N3 the precondition never happened — no AT+CIPSEND in $OUT/no-hang-slowprompt.log, so the module was never put in the state this check is about"
    elif [ "$rc" -ne 0 ]; then
        fail "N3 a SECOND client went unanswered after the first send missed its prompt ($sends AT+CIPSEND in the log) — the module is still counting off payload it was promised"
    else
        pass "N3 the first send missed its prompt ($sends AT+CIPSEND in the log) and a second client was still answered — the module was not left owed"
    fi
else
    stop_stub
    fail "N3 the stub's listener never appeared — the run never got far enough to judge"
fi

log ""
log "Diagnosis:"
log "  jnext logs:   $OUT/no-hang-unbound.log  $OUT/no-hang-bound.log  $OUT/no-hang-slowprompt.log"
log "  screenshots:  $shot1  $shot2  $shot3"
log ""

total=3
if [ "$failures" -eq 0 ]; then
    log "All $total checks passed."
    exit 0
fi
log "$((total - failures))/$total passed, $failures FAILED."
exit 1
