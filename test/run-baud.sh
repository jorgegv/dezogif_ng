#!/usr/bin/env bash
#
# THE LINK NEGOTIATED UP FROM 115200, AND BROUGHT BACK DOWN WHEN IT CANNOT BE.
#
# Invoked by `make test-baud`. Five headless jnext runs, each with a WiFi ROM
# whose ESP_BAUD_HIGH has been moved, an emulated M1 button press, and a DZRP
# client over the emulated ESP-01 that reads the stub's own screen back with
# CMD_READ_MEM.
#
# THE HEADLINE RESULT IS L5, AND IT IS WHY THE SHIPPED ROM NEGOTIATES TO 460800
# AND NOT FURTHER. (Until 2026-08-09 it did not negotiate at all; the default was
# earned on hardware — see ESP_BAUD_HIGH in src/constants.asm.)
# 1000000 — the rate this work was commissioned for — does not survive a
# CMD_LOOPBACK of 1 KB or more, which overflows the UART's 512-byte Rx FIFO. The
# cost is the PER-BYTE RECEIVE PATH and has nothing to do with sending:
# `cmd_loopback` drains the whole payload into the swap bank before it sends
# anything (commands.asm:959-1018), and L5's own log shows the first dropped byte
# 2 ms after the +IPD header with zero guest TX in the window. The limit is the
# Z80 at 28 MHz, so no timeout or buffer size reaches it. Measured: clean at
# 230400 and 460800, overflowing at 600000, 750000, 921600 and 1000000 — i.e. the
# per-byte cost is above 470 and at most 610 T-states. **It is not an echo
# problem**: any large inbound payload is affected, and CMD_WRITE_BANK pushes
# 8-16 KB per bank on every DeZog .nex load. See ESP_BAUD_HIGH in
# src/constants.asm.
#
# WHY THIS BENCH EXISTS
#
# Issue #25. The ESP link has run at 115200 since the M0(b) spike, and on real
# hardware that is already 71% of what the wire can carry — 8192 bytes in 1.01 s,
# measured 2026-08-05 — so the wire is the ceiling. DeZog pushes 8-16 KB per bank
# through CMD_WRITE_BANK on every F5. The stub now asks the module to move to
# ESP_BAUD_HIGH (1000000 as shipped) once it has answered at 115200, moves its own
# prescaler to match, and comes back down if the module refuses or the link does
# not survive.
#
#   L1  BAUD_HIGH=460800     AT+UART_CUR goes out, the module accepts, THIS
#                            SIDE's prescaler really moves, and the stub serves
#                            DZRP afterwards saying 460800
#   L2  BAUD_HIGH=6000000    above what the module will parse, so it answers
#                            ERROR — and the stub must NOT move its own side,
#                            must still serve, and must say 115200
#   L3  BAUD_HIGH=115200    the negotiation assembled OUT, because that is what
#                            ships: no AT+UART anywhere, and the same service
#   L4  BAUD_HIGH=460800     a transport fault drives esp_recover, whose tail is
#       FAULT_LIMIT=1        `jp transport_init` — so the whole chain, negotiation
#                            included, runs a SECOND time and must still serve
#   L5  BAUD_HIGH=1000000    THE CEILING, kept as a checked fact: a symmetric
#                            1 KB loopback overflows the 512-byte Rx FIFO and the
#                            stub says so. This check PASSES when that happens
#
# WHAT MAKES L2 MORE THAN "IT DID NOT CRASH". The discriminating assertion is not
# that the stub still serves — it would serve just as well having moved its own
# prescaler into a rate the module cannot hear, right up until the first byte —
# but that jnext's own log shows the guest programming ONE prescaler value all
# run, the 115200 one. A stub that switched on a refusal would show two.
#
# L3 IS NOT PADDING. Without it, L1's AT+UART_CUR line and its prescaler move are
# not attributable to anything: L3 is the same ROM one constant away, and it shows
# both disappear together.
#
# THE SCREEN IS THE OUTCOME, AND IT IS READ AS TEXT RATHER THAN PHOTOGRAPHED.
# `ESP Baudrate:` at row 3 used to be a constant assembled from ESP_BAUDRATE; it
# is now drawn from the byte that the only two writers of the prescaler also
# write, so it is the one thing on the machine that says whether the negotiation
# took. It has to be, because BEHAVIOUR cannot: a stub that fell back serves
# exactly as well as one that did not. test/dzrp/screen-client.py fetches the
# display file with CMD_READ_MEM and decodes it with the ZX font taken off the
# same machine, which also makes the read itself 7680 bytes of traffic at
# whatever rate is live.
#
# The reader is validated inside every screen before its verdict is used — row 12
# must read `R = Reset` — so a broken instrument reports itself instead of
# reporting a clean error area, which is what a reader that reads nothing says too.
#
# WHAT THIS BENCH DOES NOT DO, AND THE FIRST ONE IS THE WHOLE POINT.
#
#   * IT SAYS NOTHING ABOUT THE RATE. jnext paces both directions from the
#     GUEST's own prescaler (uart.cpp:83-87) and its AT engine stores the baud it
#     was asked for and never reads it again (esp_at.h, `requested_baud_`). So
#     the emulated module cannot fail to understand us at any rate, and a stub
#     that moved one side and not the other is byte-for-byte indistinguishable
#     here from a correct switch. THE HALF-SWITCHED LINK — the failure this whole
#     design is shaped around — is structurally unreachable, and no seam on our
#     side can reach it, because the missing behaviour is the emulator's. What is
#     checked here is the SEQUENCE. Whether a real ESP-01 takes 1000000, and at
#     what error, is hardware's alone: `make test-hardware NEXT_IP=<ip>`, H4 and
#     H5 before and after, several runs.
#
#   * IT NEVER EXERCISES THE BRING-UP PROBE. transport_init greets the module at
#     115200 and, on silence, again at ESP_BAUD_HIGH, because the UART's
#     prescaler survives a soft reset (zxnext.vhd:3361-3367) and so both ends
#     stay at the raised rate across one. jnext's module answers the first
#     greeting every time, so that branch is DEAD CODE in the emulator. Nothing
#     here has run it. (NR 0x02 bit 7 does reset the module — nextreg.txt:37-49
#     — but it resets the expansion bus with it and jnext models no path from
#     that register to its ESP, so it is not used and could not be checked here.)
#
#   * IT DOES NOT RUN THE CONFORMANCE SUITE. It does not need to: the shipped ROM
#     IS the negotiating one, so `make test-dzrp-stub` already speaks all fifteen
#     checks at the raised rate.
#
#   * L4 SHOWS THE CHAIN RE-RUNS, not that a recovery repairs anything. No run
#     here can make the emulated module unresponsive, so what it re-initialises
#     is a module that was never broken.
#
# Environment (all set by the Makefile, all overridable):
#   JNEXT         path to the jnext binary
#   SD_IMAGE      reference SD card image; NEVER written, only copied
#   OUT           build directory
#   ROM_HIGH      WiFi ROM, BAUD_HIGH=460800
#   ROM_REFUSED   WiFi ROM, BAUD_HIGH=6000000
#   ROM_OFF       WiFi ROM, BAUD_HIGH=115200 (negotiation assembled out)
#   ROM_RECOVER   WiFi ROM, BAUD_HIGH=460800 FAULT_LIMIT=1
#   ROM_CEILING   WiFi ROM, BAUD_HIGH=1000000

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
ROM_HIGH=${ROM_HIGH:-$OUT/enNextMf-wifi-baud460800.rom}
ROM_REFUSED=${ROM_REFUSED:-$OUT/enNextMf-wifi-baud6000000.rom}
ROM_OFF=${ROM_OFF:-$OUT/enNextMf-wifi-baud115200.rom}
ROM_RECOVER=${ROM_RECOVER:-$OUT/enNextMf-wifi-fl1-baud460800.rom}
ROM_CEILING=${ROM_CEILING:-$OUT/enNextMf-wifi-baud1000000.rom}

SCREEN_CLIENT=$(dirname "$0")/dzrp/screen-client.py
RECOVER_CLIENT=$(dirname "$0")/dzrp/baud-recover-client.py
CONFORMANCE=$(dirname "$0")/dzrp/conformance.py

PORT=11000

# The three rates, kept here as well as in the Makefile so the log assertions
# below cannot drift away from the ROMs that were built.
HIGH_BAUD=460800
REFUSED_BAUD=6000000
LOW_BAUD=115200
CEILING_BAUD=1000000

# The prescaler jnext will log when the guest programs each rate. Fsys is
# 28000000 at the reference image's video timing 0, and the table rounds:
#   115200 -> (28000000 + 57600)/115200 = 243
#   460800 -> (28000000 + 230400)/460800 = 61
# Written out rather than derived so that a table change has to be noticed here.
LOW_PRESCALER=243
HIGH_PRESCALER=61

# AND THE VALUE THE DIVISOR TRANSIENTLY HOLDS WHILE IT IS BEING CHANGED, which
# this bench asserts rather than tolerates, because it is the hazard the frame
# register's hold bit exists to cover and it is visible here for free.
#
# The divisor goes out as two 7-bit halves through separate writes to 0x143B and
# there is no double buffering anywhere in serial/uart.vhd — each write lands on
# the register immediately. So between them the live value is a MIXTURE: the old
# high half with the new low half. jnext logs after every write, so the mixture
# appears in its log as an ordinary reading, and 243 -> 460800 shows as
# 243, 189, 61.
#
# 189 IS NOT A MAGIC NUMBER, it is that mixture computed the way the hardware
# computes it: the old value's bits 13:7 with the new value's bits 6:0. Deriving
# it here rather than writing the number is what makes this an assertion about
# the mechanism instead of about one arithmetic accident.
#
# Nothing samples the mixture, and that is the point rather than luck: both
# engines are held at idle across all three writes, so neither can latch it.
MIX_PRESCALER=$(( (LOW_PRESCALER & 0x3F80) | (HIGH_PRESCALER & 0x7F) ))

# NextZXOS needs ~900 frames to reach the welcome screen; the button is pressed
# there, exactly as run-headless.sh's T6 does.
BOOT_FRAMES=900

# A backstop only; the run is ended by killing jnext once the client is done.
EXIT_FRAMES=400000

# See run-tx-patience.sh: a client connecting inside bring-up's one AT+CIFSR
# exchange puts 1,CONNECT into the same scan and loses its first command. That is
# a real (small) property of bring-up, worked around here rather than fixed.
SETTLE=${SETTLE:-2}

CLIENT_TIMEOUT=90
RUN_TIMEOUT=300
LISTEN_TIMEOUT=90

MF_ROM_PATH='::/machines/next/enNextMf.rom'

# Shared jnext teardown — issue #17. Defines functions and nothing else, so it
# cannot disturb the `set -euo pipefail` above or the traps below.
# shellcheck source=test/bench-jnext.sh
. "$(dirname "$0")/bench-jnext.sh"

log()  { printf '%s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# --- pre-flight ------------------------------------------------------------

[ -x "$JNEXT" ]           || die "jnext binary not found or not executable: $JNEXT"
[ -f "$SD_IMAGE" ]        || die "SD card image not found: $SD_IMAGE"
[ -f "$SCREEN_CLIENT" ]   || die "client not found: $SCREEN_CLIENT"
[ -f "$RECOVER_CLIENT" ]  || die "client not found: $RECOVER_CLIENT"
[ -f "$CONFORMANCE" ]     || die "client not found: $CONFORMANCE"
command -v mcopy >/dev/null || die "mtools (mcopy) is required to install the ROM into the SD image"

for rom in "$ROM_HIGH" "$ROM_REFUSED" "$ROM_OFF" "$ROM_RECOVER" "$ROM_CEILING"; do
    [ -f "$rom" ] || die "not built: $rom (run 'make test-baud')"
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
    # "free", starting a run against an occupied port. -c cannot do that.
    # THE `|| true` IS FOR SOMETHING ELSE: `grep -c` exits 1 when the count is 0,
    # which is the ORDINARY case here.
    [ "$(ss -ltn 2>/dev/null | grep -cE "127\.0\.0\.1:$PORT\b" || true)" -eq 0 ] \
        || die "something is already listening on 127.0.0.1:$PORT — stop it first (CSpect, a stale jnext?)"
fi

part_lba=$(od -An -tu4 -j 454 -N 4 "$SD_IMAGE" | tr -d ' ')
[ -n "$part_lba" ] && [ "$part_lba" -gt 0 ] || die "cannot read partition table from $SD_IMAGE"
part_off=$((part_lba * 512))

mkdir -p "$OUT"

# --- the runs --------------------------------------------------------------
#
# The reference image is never written; the working copy is reflinked where the
# filesystem supports it and DELETED on the way out either way. The trap is armed
# BEFORE the copy, because the copy is the slowest thing here and so the likeliest
# moment to be interrupted; jnext_pid is declared empty first so `set -u` cannot
# abort the handler before it reaches the rm.

sd=$OUT/sd-baud.img
jnext_pid=""
cleanup() {
    if [ -n "$jnext_pid" ] && kill -0 "$jnext_pid" 2>/dev/null; then
        kill "$jnext_pid" 2>/dev/null || true
        wait "$jnext_pid" 2>/dev/null || true
    fi
    # Unlinked BEFORE departure is confirmed: bench_await_departure can exit, and
    # an exit that skipped this would reintroduce the abandoned-gigabyte leak
    # ERRORS.md records.
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

# prescalers <logfile> — every distinct prescaler value the GUEST programmed,
# in order of first appearance, space separated.
#
# jnext logs each 0x143B write as `prescaler LSB lower/upper = .., full LSB = N`,
# and N after the pair is the whole 14-bit divisor. That is a DIRECT reading of
# the thing this issue moves — no timing, no inference — and it is the only way
# any run here can tell a stub that reprogrammed its own side from one that only
# told the module.
prescalers() {
    grep -oE 'full LSB = [0-9]+' "$1" 2>/dev/null | awk '{print $4}' \
        | awk '!seen[$0]++' | tr '\n' ' ' | sed 's/ $//'
}

# run_client <rom> <logfile> <client-cmd...> — boot a Next with <rom> as the
# Multiface ROM, press M1, wait for the stub's own listener, and run the client.
#
# Sets: client_out (everything the client printed), client_rc, listening (0/1).
client_out=""
client_rc=0
listening=0
run_client() {
    local rom=$1 logfile=$2
    shift 2
    client_out=""
    client_rc=0
    listening=0

    # Per run, not only at pre-flight: a foreign listener appearing between two
    # of this script's own runs would answer the client below, and a contaminated
    # run can come out GREEN (issue #17).
    bench_require_port_free "$PORT" "before this run started"

    cp --reflink=auto -f "$SD_IMAGE" "$sd"
    mcopy -o -i "$sd@@$part_off" "$rom" "$MF_ROM_PATH"

    timeout "$RUN_TIMEOUT" "$JNEXT" \
        --headless --machine next \
        --sdcard "$sd" \
        --rtc "2026-01-01 12:00:00" \
        --log-level "warn,esp01=debug,uart=debug" \
        --esp --esp-listen-address 127.0.0.1 \
        --delayed-nmi-frames "$BOOT_FRAMES" nmi \
        --delayed-automatic-exit-frames "$EXIT_FRAMES" \
        >"$logfile" 2>&1 &
    jnext_pid=$!

    local waited=0
    while [ "$waited" -lt "$LISTEN_TIMEOUT" ]; do
        if ss -ltn 2>/dev/null | grep -qE "127\.0\.0\.1:$PORT\b"; then
            listening=1
            break
        fi
        kill -0 "$jnext_pid" 2>/dev/null || break
        sleep 1
        waited=$((waited + 1))
    done

    if [ "$listening" -eq 1 ]; then
        sleep "$SETTLE"
        set +e
        client_out=$(timeout "$CLIENT_TIMEOUT" "$@" 2>&1)
        client_rc=$?
        set -e
    fi

    kill "$jnext_pid" 2>/dev/null || true
    wait "$jnext_pid" 2>/dev/null || true
    jnext_pid=""
    rm -f "$sd"
    bench_await_departure "$sd"
}

# baud_row — the rate the screen claims, out of the client's full-screen dump.
baud_row() {
    printf '%s\n' "$client_out" | sed -n 's/^ *3 | ESP Baudrate: *//p' | head -1
}

# reader_ok — did screen-client.py validate its own reader on this screen?
reader_ok() {
    printf '%s\n' "$client_out" | grep -q 'reader validation:.*(OK)'
}

# ===========================================================================
# L1 — the shipped ROM negotiates, and BOTH ends of the switch are witnessed.
#
# Three separate things have to hold, and each is checked from a different
# place, because no one of them is the claim on its own:
#
#   * the module was ASKED and agreed — jnext's AT engine logs the parsed baud;
#   * THIS SIDE moved — jnext's UART logs every prescaler the guest programmed,
#     and 28 must appear after 243. This is the half a stub could skip while
#     still passing every behavioural check in this repository, because the
#     emulated module never compares the rate it was told against the rate it is
#     spoken to;
#   * the link still carries DZRP, and the screen says which rate it is on.
#     The screen read is 7680 bytes, so "still carries" is not a token exchange.
# ===========================================================================
log "L1: BAUD_HIGH=$HIGH_BAUD — the negotiation, at a rate this stub can sustain"
run_client "$ROM_HIGH" "$OUT/baud-l1.log" \
    python3 "$SCREEN_CLIENT" --host 127.0.0.1 --port "$PORT" --timeout 20

l1_seen=$(prescalers "$OUT/baud-l1.log")
if [ "$listening" -ne 1 ]; then
    fail "L1 the stub never listened, so nothing here was tested"
elif ! grep -q "AT+UART baud set to $HIGH_BAUD" "$OUT/baud-l1.log"; then
    fail "L1 precondition: the module never accepted AT+UART_CUR=$HIGH_BAUD"
elif [ "$client_rc" -ne 0 ]; then
    fail "L1 the stub did not answer over DZRP at the raised rate (rc=$client_rc)"
elif ! reader_ok; then
    fail "L1 the screen reader failed validation, so no verdict was taken"
elif [ "$l1_seen" != "$LOW_PRESCALER $MIX_PRESCALER $HIGH_PRESCALER" ]; then
    fail "L1 the guest's own prescaler went $l1_seen, wanted $LOW_PRESCALER $MIX_PRESCALER $HIGH_PRESCALER"
elif [ "$(baud_row)" != "$HIGH_BAUD" ]; then
    fail "L1 the screen says $(baud_row), not $HIGH_BAUD"
else
    pass "L1 module accepted $HIGH_BAUD, prescaler went $l1_seen, screen agrees, DZRP served"
fi

# ===========================================================================
# L2 — a refused rate, and the stub must not move alone.
#
# 6000000 is above the 5000000 jnext's AT engine will parse, so it answers ERROR.
# The stub waits for "OK" alone here, deliberately, so a refusal reads as "do not
# move" exactly as silence does — and the assertion that matters is the negative
# one: ONE prescaler value all run. A stub that moved on a refusal would still
# serve this client, right up until the module's first unanswered byte.
# ===========================================================================
log "L2: BAUD_HIGH=$REFUSED_BAUD — a rate the module refuses"
run_client "$ROM_REFUSED" "$OUT/baud-l2.log" \
    python3 "$SCREEN_CLIENT" --host 127.0.0.1 --port "$PORT" --timeout 20

l2_seen=$(prescalers "$OUT/baud-l2.log")
if [ "$listening" -ne 1 ]; then
    fail "L2 the stub never listened, so the fallback was never reached"
elif ! grep -q "AT+UART baud .* answering ERROR" "$OUT/baud-l2.log"; then
    fail "L2 precondition: the module never refused AT+UART_CUR=$REFUSED_BAUD"
elif [ "$client_rc" -ne 0 ]; then
    fail "L2 the stub stopped serving after the refusal (rc=$client_rc)"
elif ! reader_ok; then
    fail "L2 the screen reader failed validation, so no verdict was taken"
elif [ "$l2_seen" != "$LOW_PRESCALER" ]; then
    fail "L2 the guest moved its own prescaler on a refusal: $l2_seen"
elif [ "$(baud_row)" != "$LOW_BAUD" ]; then
    fail "L2 the screen says $(baud_row), not $LOW_BAUD"
else
    pass "L2 refused, stub stayed at $LOW_PRESCALER, screen says $LOW_BAUD, DZRP served"
fi

# ===========================================================================
# L3 — the negotiation assembled out. The "before" control.
#
# One constant from L1 and L2, and it is what attributes their AT+UART_CUR line
# and L1's prescaler move to this feature rather than to anything else in the
# ROM. It is also a ROM a user can actually ship: the escape hatch for a board or
# a module that will not take the rate.
# ===========================================================================
log "L3: BAUD_HIGH=115200 — the negotiation compiled out"
run_client "$ROM_OFF" "$OUT/baud-l3.log" \
    python3 "$SCREEN_CLIENT" --host 127.0.0.1 --port "$PORT" --timeout 20

l3_seen=$(prescalers "$OUT/baud-l3.log")
if [ "$listening" -ne 1 ]; then
    fail "L3 the stub never listened, so the control says nothing"
elif grep -q 'AT+UART' "$OUT/baud-l3.log"; then
    fail "L3 this build still sent AT+UART, so the seam does not assemble it out"
elif [ "$client_rc" -ne 0 ]; then
    fail "L3 the stub did not answer over DZRP (rc=$client_rc)"
elif ! reader_ok; then
    fail "L3 the screen reader failed validation, so no verdict was taken"
elif [ "$l3_seen" != "$LOW_PRESCALER" ]; then
    fail "L3 the guest's own prescaler went $l3_seen, wanted $LOW_PRESCALER alone"
elif [ "$(baud_row)" != "$LOW_BAUD" ]; then
    fail "L3 the screen says $(baud_row), not $LOW_BAUD"
else
    pass "L3 no AT+UART at all, prescaler stayed $LOW_PRESCALER, screen says $LOW_BAUD"
fi

# ===========================================================================
# L4 — a recovery re-runs the whole chain, negotiation included.
#
# esp_recover ends `jp transport_init`, so every recovery repeats bring-up. At a
# raised rate that is the one place the sequence runs TWICE in a single power-on,
# and nothing else here executes it twice. The precondition is jnext's own log:
# two AT+UART_CUR lines and the prescaler moving 243 -> 28 -> 243 -> 28, the
# second pair being the recovery's.
#
# WHAT IT DOES NOT SHOW: that a recovery repairs anything. Nothing here can make
# the emulated module unresponsive, so what is re-initialised was never broken.
# ===========================================================================
log "L4: BAUD_HIGH=$HIGH_BAUD FAULT_LIMIT=1 — the chain re-runs after a fault"
run_client "$ROM_RECOVER" "$OUT/baud-l4.log" \
    python3 "$RECOVER_CLIENT" --host 127.0.0.1 --port "$PORT"

l4_asked=$(grep -c "AT+UART baud set to $HIGH_BAUD" "$OUT/baud-l4.log" || true)
l4_high=$(grep -oE 'full LSB = [0-9]+' "$OUT/baud-l4.log" | awk '{print $4}' \
          | grep -c "^$HIGH_PRESCALER$" || true)
if [ "$listening" -ne 1 ]; then
    fail "L4 the stub never listened, so no recovery could be provoked"
elif ! printf '%s\n' "$client_out" | grep -q '^INJECTED'; then
    fail "L4 precondition: the fault was never injected — the stub was not serving"
elif [ "$l4_asked" -lt 2 ]; then
    fail "L4 the recovery did not re-negotiate: $l4_asked AT+UART_CUR, wanted 2"
elif [ "$l4_high" -lt 2 ]; then
    fail "L4 the recovery did not re-program the rate: $l4_high moves to $HIGH_PRESCALER"
elif ! printf '%s\n' "$client_out" | grep -q '^SERVED'; then
    fail "L4 no fresh client was served after the recovery"
else
    pass "L4 recovery re-ran the chain: $l4_asked negotiations, $l4_high rate moves, served"
fi

# ===========================================================================
# L5 — the ceiling, and this check PASSES when the stub FAILS.
#
# 1000000 is the rate issue #25 was commissioned for, and it does not work. The
# subject is CMD_LOOPBACK at 1024 bytes and up, whose 1030-byte +IPD frame
# arrives faster than the receive path can drain it and overflows the UART's
# 512-byte Rx FIFO.
#
# IT IS A RECEIVE COST, NOT AN ECHO ONE, and this comment said otherwise until it
# was traced. `cmd_loopback` does NOT interleave: commands.asm:959-1018 drains
# the whole payload into the swap bank before it reaches send_length_and_seqno,
# and ESP_TX_CHUNK is on the transmit path alone. This check's own log settles
# it — the previous SEND OK is fully delivered, the +IPD header goes out, and the
# first dropped byte follows 2 ms later with ZERO guest TX writes and zero
# AT+CIPSEND in between.
#
# THE LIMIT IS THE Z80, NOT THE MODULE, which is what makes this measurement
# worth keeping rather than a note about an emulator: the per-byte work does not
# shrink when the byte time does, and jnext counts the same T-states a Next does.
# One byte time is prescaler x 10 T-states at 28 MHz, and the sweep brackets the
# cost above 470 (600000 fails) and at or below 610 (460800 passes). On real
# hardware it can only be worse.
#
# WHICH MAKES IT WIDER THAN THIS ONE CHECK: any large INBOUND payload is
# affected, and CMD_WRITE_BANK pushes 8-16 KB per bank every time DeZog loads a
# .nex. Whoever raises this ceiling must optimise the receive path.
#
# IT IS KEPT AS A CHECK RATHER THAN A PARAGRAPH so that whoever raises the
# default has to come here and make it go green — which means having changed the
# thing this measures, not just the constant. Same shape as W3, whose PASS is
# also another check going red.
#
# TWO ASSERTIONS, because "C5 failed" on its own has other causes: the loopback
# must fail AND jnext's uart log must show the Rx FIFO dropping bytes. A run
# where the stub simply died would satisfy the first and not the second.
# ===========================================================================
log "L5: BAUD_HIGH=$CEILING_BAUD — the ceiling, where the symmetric case breaks"
run_client "$ROM_CEILING" "$OUT/baud-l5.log" \
    python3 "$CONFORMANCE" --remote "tcp:127.0.0.1:$PORT" --only C5

l5_drops=$(grep -c 'RX FIFO overflow' "$OUT/baud-l5.log" || true)
if [ "$listening" -ne 1 ]; then
    fail "L5 the stub never listened, so the ceiling was never approached"
elif ! grep -q "AT+UART baud set to $CEILING_BAUD" "$OUT/baud-l5.log"; then
    fail "L5 precondition: the module never accepted AT+UART_CUR=$CEILING_BAUD"
elif [ "$client_rc" -eq 0 ]; then
    fail "L5 the 1 KB loopback SURVIVED $CEILING_BAUD — the ceiling has moved, re-measure it"
elif [ "$l5_drops" -eq 0 ]; then
    fail "L5 the loopback failed but the Rx FIFO never overflowed, so it failed for another reason"
else
    pass "L5 at $CEILING_BAUD the 1 KB loopback overflows the Rx FIFO ($l5_drops bytes dropped)"
fi

# --- verdict ---------------------------------------------------------------

echo
if [ "$failures" -eq 0 ]; then
    log "All 5 checks passed."
    exit 0
fi
log "$failures of 5 checks FAILED."
exit 1
