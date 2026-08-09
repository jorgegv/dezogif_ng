#!/usr/bin/env bash
#
# THE MODULE'S OWN IDLE TIMEOUT, set by the stub and shown to govern.
#
# Invoked by `make test-cipsto`. Four headless jnext runs, each with a WiFi ROM
# whose ESP_SERVER_TIMEOUT (and, once, ESP_CIPSTO_STRICT) has been moved, an
# emulated M1 button press, and one DZRP client over the emulated ESP-01 that
# proves the stub is serving and then says nothing at all.
#
# WHY THIS BENCH EXISTS
#
# Issue #24, and the defect is the module's, not ours. `AT+CIPSTO` is the ESP's
# TCP-server idle timeout: a client silent for `<time>` seconds is hung up on by
# the module, with no involvement from the guest. The user's Next (AT 1.2.0.0 /
# SDK 1.5.4.1) reports `+CIPSTO:180` and ENFORCES it — a client that connected,
# sent CMD_INIT and then stayed silent was dropped after 182.5 s and 181.8 s on
# two runs. The stub had never sent the command, so that default governed us.
#
# THAT IS A DEZOG SESSION PARKED AT A BREAKPOINT. Neither side transmits while
# the user reads code, and on ESP8266 our own replies do not re-arm the timer.
# Confirmed with the real client at the machine: the registers view, the memory
# view and the debug toolbar all vanished — DeZog had ended the session, and it
# has no reconnect logic — while the stub was perfectly healthy, its border
# still cycling. Nothing on the Next said anything had happened.
#
# NO ORDINARY RUN CAN WATCH THE SHIPPED VALUE WORK, which is the same problem
# ESP_IP_MAX and ESP_RX_WAIT have and gets the same answer: the shipped 1800
# seconds is half an hour per check, so the BOUND is moved rather than the world.
# A client dropped at ten seconds shows that the value THIS ROM SENT is the value
# that governs, which is the whole claim. And an out-of-range value is refused by
# the module, which is the only way to execute the ERROR arm at all.
#
#   K1  SERVER_TIMEOUT=10     the silent client is DROPPED at ~10 s, and the
#                             module's log says it accepted our 10
#   K2  the SHIPPED ROM       the same silent client is STILL THERE over the
#                             same window, and the log says we sent 1800.
#                             One constant apart from K1
#   K3  SERVER_TIMEOUT=7201   refused by the module — and the stub comes up
#                             anyway, serves DZRP, and reports no fault
#   K4  the same, plus        the refusal treated as a bring-up failure:
#       CIPSTO_STRICT=1       nothing listens at all
#
# K2 IS NOT PADDING, AND NEITHER IS K4.
#
# Without K2, K1 shows only that a client got dropped, and the obvious reading —
# "our value governs" — would be unearned: a stub that dropped clients for some
# other reason would look identical. K1 and K2 differ in one build-time constant
# and in nothing else, so the ten seconds is attributable to the constant.
#
# Without K4, K3 is satisfied by a stub that never sent the command at all,
# which is precisely the state before this fix — hence K3's own log precondition
# as well. K4 goes further and is the controlled REMOVAL: it assembles the same
# step with esp_command_ok, i.e. waiting for OK alone, and the refusal then
# stops bring-up dead. ERRORS.md's standing complaint is that a fix never tested
# by removing it is a correlation.
#
# EVERY CHECK ASSERTS ITS PRECONDITION FROM jnext's OWN LOG, because a run that
# never sent AT+CIPSTO can satisfy K2, K3 and K4 by accident — and the ROM
# before this fix is exactly such a run. Measured against it: no `AT+CIPSTO`
# line anywhere, and the client alive at 25.03 s.
#
# WHAT THIS BENCH DOES NOT DO.
#
#   * IT CANNOT TELL A STUB THAT READS THE ANSWER FROM ONE THAT FIRES AND
#     FORGETS, and that is measured rather than suspected: a scratch build whose
#     CIPSTO step is `call esp_send_string` and nothing else passes **4 of 4**.
#     The reason is that every check here observes the MODULE — the value it was
#     given, and whether it enforces it — and the module behaves identically
#     either way. What a fire-and-forget stub really breaks is the SYNCHRONY of
#     the rest of bring-up: its answer stays in the FIFO, so AT+CIPSERVER's own
#     wait matches AT+CIPSTO's OK and every reply afterwards is off by one. jnext
#     survives that, because the remaining scans skip what they are not looking
#     for; a real module is where it would bite, which is the same "the emulator
#     sits on the safe side of us" shape that cost this project a night over a
#     connection id. K4 is the nearest thing to a guard — it shows the step's
#     answer really is consumed by SOMETHING, since a build that waits for `OK`
#     alone stops dead on the refusal.
#   * It says nothing about a real ESP-01. jnext models `AT+CIPSTO` from the
#     hardware measurement above (its own GH #240), so this shows the stub sends
#     the command and reads the answer, not that a module obeys. The hardware
#     check is to re-run the same silent-client probe on a Next and require the
#     connection to survive past 300 s where it died at ~182 s.
#   * It does not test the value 1800 as a POLICY. That trade — an idle session
#     safe for 30 minutes against a vanished peer's slot leaking for 30 minutes
#     instead of 3 — is a decision recorded in the issue and in MEMORY.md, and
#     no emulator run can weigh it.
#   * K1's drop is judged on a WINDOW, not on 10.00. The module polls on its own
#     schedule and the clock is wall clock (jnext installs no clock into its AT
#     engine), so the number is bounded rather than exact. Measured at exactly
#     10.00 s here; the window is wide enough that a loaded machine cannot fail
#     it and narrow enough that the firmware's own 180 cannot pass it.
#
# Environment (all set by the Makefile, all overridable):
#   JNEXT         path to the jnext binary
#   SD_IMAGE      reference SD card image; NEVER written, only copied
#   OUT           build directory
#   ROM_SHORT     WiFi ROM, SERVER_TIMEOUT=10
#   ROM_SHIPPED   the shipped WiFi ROM (SERVER_TIMEOUT=1800)
#   ROM_REFUSED   WiFi ROM, SERVER_TIMEOUT=7201
#   ROM_STRICT    WiFi ROM, SERVER_TIMEOUT=7201 CIPSTO_STRICT=1

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
ROM_SHORT=${ROM_SHORT:-$OUT/enNextMf-wifi-sto10.rom}
ROM_SHIPPED=${ROM_SHIPPED:-$OUT/enNextMf-wifi.rom}
ROM_REFUSED=${ROM_REFUSED:-$OUT/enNextMf-wifi-sto7201.rom}
ROM_STRICT=${ROM_STRICT:-$OUT/enNextMf-wifi-sto7201-stostrict1.rom}

CLIENT=$(dirname "$0")/dzrp/cipsto-client.py

PORT=11000

# The two probe values, kept here as well as in the Makefile so the log
# assertions below cannot drift away from the ROMs that were built.
SHORT_STO=10
SHIPPED_STO=1800
REFUSED_STO=7201

# NextZXOS needs ~900 frames to reach the welcome screen; the button is pressed
# there, exactly as run-headless.sh's T6 does.
BOOT_FRAMES=900

# K3 only. Late enough to land after the exchange — which the client REQUIRES
# rather than assumes, refusing the run if the file already exists when its
# commands have been answered.
SHOT_FRAMES=3000

# A backstop only; the run is ended by killing jnext once the client is done.
EXIT_FRAMES=400000

# See run-tx-patience.sh: a client connecting inside bring-up's one AT+CIFSR
# exchange puts 1,CONNECT into the same scan and loses its first command. That
# is a real (small) property of bring-up, worked around here rather than fixed.
SETTLE=${SETTLE:-2}

# How long the client stays silent. K1 ends early on the drop; K2 sits out the
# whole window, which is what makes its "still there" mean something.
WATCH_LONG=25
# K3's client only has to prove the stub is serving. Its ROM was REFUSED, so the
# module keeps its own 180-second default and no drop can happen inside this.
WATCH_SHORT=12

CLIENT_TIMEOUT=20

RUN_TIMEOUT=300
LISTEN_TIMEOUT=90
# K4 EXPECTS no listener, so a short wait here would make it pass for the wrong
# reason. It is bounded only so the bench terminates; what actually settles K4
# is the log — AT+CIPSTO sent, AT+CIPSERVER never reached — which no amount of
# waiting can fake either way.
LISTEN_TIMEOUT_NONE=45
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

for rom in "$ROM_SHORT" "$ROM_SHIPPED" "$ROM_REFUSED" "$ROM_STRICT"; do
    [ -f "$rom" ] || die "not built: $rom (run 'make test-cipsto')"
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

# AT+CIPSTO itself, jnext#240, shipped in 0.99.141. There is no flag for it, so
# --help cannot answer this; the version string can, and a jnext without it
# answers ERROR to everything here — which would turn K1 and K2 into a story
# about an emulator that never had the feature.
jnext_version=$("$JNEXT" --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
[ -n "$jnext_version" ] || die "cannot read a version out of '$JNEXT --version'"
jnext_patch=${jnext_version##*.}
case "$jnext_version" in
    0.99.*) [ "$jnext_patch" -ge 141 ] \
        || die "this jnext is $jnext_version and has no AT+CIPSTO (need >= 0.99.141); rebuild it" ;;
    *) ;;   # 1.x and later: the command shipped long before
esac

if command -v ss >/dev/null 2>&1; then
    # `grep -c` and not `-q`. -q exits at its first match, and the SIGPIPE that
    # would give `ss` comes back as 141 under pipefail — which `!` then reads as
    # "free", starting a run against an occupied port. -c cannot do that: it must
    # read to EOF to count, so there is no early close to signal.
    # THE `|| true` IS FOR SOMETHING ELSE: `grep -c` exits 1 when the count is
    # 0, which is the ORDINARY case here.
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

sd=$OUT/sd-cipsto.img
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

# run_silent_client <rom> <logfile> <watch> [shotfile] — boot a Next with <rom>
# as the Multiface ROM, press M1, wait for the stub's own listener, and run the
# silent client against it.
#
# Sets: client_out (everything the client printed), listening (0/1).
# Returns the client's exit code, or 10 if the listener never appeared.
client_out=""
listening=0
run_silent_client() {
    local rom=$1 logfile=$2 watch=$3 shotfile=${4:-} timeout_listen=${5:-$LISTEN_TIMEOUT}
    client_out=""
    listening=0
    [ -n "$shotfile" ] && rm -f "$shotfile"

    # Per run, not only at pre-flight: a foreign listener appearing between two
    # of this script's own runs would answer the client below, and a
    # contaminated run can come out GREEN (issue #17).
    bench_require_port_free "$PORT" "before this run started"

    cp --reflink=auto -f "$SD_IMAGE" "$sd"
    mcopy -o -i "$sd@@$part_off" "$rom" "$MF_ROM_PATH"

    local shot_args=()
    [ -n "$shotfile" ] && shot_args=(--delayed-screenshot "$shotfile"
                                     --delayed-screenshot-frames "$SHOT_FRAMES")

    timeout "$RUN_TIMEOUT" "$JNEXT" \
        --headless --machine next \
        --sdcard "$sd" \
        --rtc "2026-01-01 12:00:00" \
        --log-level "warn,esp01=debug" \
        --esp --esp-listen-address 127.0.0.1 \
        --delayed-nmi-frames "$BOOT_FRAMES" nmi \
        "${shot_args[@]}" \
        --delayed-automatic-exit-frames "$EXIT_FRAMES" \
        >"$logfile" 2>&1 &
    jnext_pid=$!

    local i
    for i in $(seq $((timeout_listen * 4))); do
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
        local shot_client=()
        [ -n "$shotfile" ] && shot_client=(--after-shot "$shotfile"
                                           --shot-timeout "$SHOT_TIMEOUT")
        client_out=$(python3 "$CLIENT" --host 127.0.0.1 --port "$PORT" \
            --timeout "$CLIENT_TIMEOUT" --watch "$watch" "${shot_client[@]}" 2>&1) || rc=$?
        printf '%s\n' "$client_out" | sed 's/^/  | /'
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

    return "$rc"
}

# at_sent <logfile> <command> — did that exact AT line reach the module?
at_sent() { grep -qF "AT <- \"$2\"" "$1"; }

# result_verdict / result_seconds — pull the client's one machine-readable line
# apart. "alive" or "dropped", and how long the silence had lasted.
result_verdict() { printf '%s\n' "$client_out" | awk '$1=="RESULT"{print $2}' | tail -1; }
result_seconds() { printf '%s\n' "$client_out" | awk '$1=="RESULT"{print $3}' | tail -1; }

# ===========================================================================

log "== K1: ESP_SERVER_TIMEOUT=$SHORT_STO — does the value the stub sent govern?"

rc=0
run_silent_client "$ROM_SHORT" "$OUT/cipsto-short.log" "$WATCH_LONG" || rc=$?
verdict=$(result_verdict); secs=$(result_seconds)
# The precondition, and without it a stub that never sent the command could
# satisfy this check by being dropped for some other reason. Two lines, because
# "we asked" and "the module agreed" are different facts: the second is jnext
# saying it took the value rather than answering ERROR.
if [ "$rc" -eq 10 ]; then
    fail "K1 the stub's listener never appeared — the run never got far enough to judge"
elif ! at_sent "$OUT/cipsto-short.log" "AT+CIPSTO=$SHORT_STO"; then
    fail "K1 PRECONDITION: the ROM never sent AT+CIPSTO=$SHORT_STO, so nothing here is about it"
elif ! grep -qF "AT+CIPSTO=$SHORT_STO — an inbound client" "$OUT/cipsto-short.log"; then
    fail "K1 PRECONDITION: the module did not accept AT+CIPSTO=$SHORT_STO"
elif [ "$rc" -ne 0 ]; then
    fail "K1 the client could not complete its exchange (rc=$rc), so its silence proves nothing"
elif [ "$verdict" != "dropped" ]; then
    fail "K1 the silent client survived ${secs}s: the timeout the stub set did not govern"
elif ! awk -v s="$secs" 'BEGIN{exit !(s >= 5 && s <= 20)}'; then
    fail "K1 the client was dropped after ${secs}s, which is not the ${SHORT_STO}s the stub asked for"
else
    pass "K1 the silent client was dropped after ${secs}s, the ${SHORT_STO}s this ROM set"
fi

log ""
log "== K2: the SHIPPED ROM ($SHIPPED_STO) — one constant apart, and nothing is dropped"

rc=0
run_silent_client "$ROM_SHIPPED" "$OUT/cipsto-shipped.log" "$WATCH_LONG" || rc=$?
verdict=$(result_verdict); secs=$(result_seconds)
# This is K1's control AND a check in its own right: the log assertion is what
# stops it passing on a ROM that sends nothing at all, which is the state before
# this fix and which survives the same silence for the same reason.
if [ "$rc" -eq 10 ]; then
    fail "K2 the stub's listener never appeared — the run never got far enough to judge"
elif ! at_sent "$OUT/cipsto-shipped.log" "AT+CIPSTO=$SHIPPED_STO"; then
    fail "K2 the shipped ROM did not send AT+CIPSTO=$SHIPPED_STO"
elif [ "$rc" -ne 0 ]; then
    fail "K2 the client could not complete its exchange (rc=$rc), so its silence proves nothing"
elif [ "$verdict" != "alive" ]; then
    fail "K2 the shipped ROM dropped a silent client after ${secs}s"
else
    pass "K2 the shipped ROM asked for ${SHIPPED_STO}s and its silent client survived ${secs}s"
fi

log ""
log "== K3: ESP_SERVER_TIMEOUT=$REFUSED_STO — refused by the module, and not a bring-up failure"

rc=0
shot=$OUT/screenshots/cipsto-refused.png
run_silent_client "$ROM_REFUSED" "$OUT/cipsto-refused.log" "$WATCH_SHORT" "$shot" || rc=$?
# The precondition is the whole reason this is not vacuous: a ROM that never
# sent the command also comes up, serves DZRP and reports nothing. What is being
# checked is that a REFUSAL was received and shrugged off.
if [ "$rc" -eq 10 ]; then
    fail "K3 nothing listened: the refused AT+CIPSTO stopped bring-up, which is the defect"
elif ! grep -qF "AT+CIPSTO=\"$REFUSED_STO\" is not" "$OUT/cipsto-refused.log"; then
    fail "K3 PRECONDITION: the module never refused AT+CIPSTO=$REFUSED_STO, so no ERROR arm ran"
elif [ "$rc" -eq 12 ] || [ "$rc" -eq 13 ]; then
    fail "K3 the screenshot was not taken after the exchange, so the error area was NOT judged"
elif [ "$rc" -ne 0 ]; then
    fail "K3 the stub listened but would not serve DZRP after the refusal (rc=$rc)"
else
    red=$(bright_red "$shot")
    if [ "$red" -ne 0 ]; then
        fail "K3 the stub served after the refusal but reports a fault ($red bright-red pixels)"
    else
        pass "K3 a refused AT+CIPSTO left the stub listening, serving DZRP and reporting no error"
    fi
fi

log ""
log "== K4: control — the same refusal with ESP_CIPSTO_STRICT=1 (wait for OK alone)"

rc=0
run_silent_client "$ROM_STRICT" "$OUT/cipsto-strict.log" "$WATCH_SHORT" "" "$LISTEN_TIMEOUT_NONE" || rc=$?
# "Nothing listened" alone would be satisfied by a run that never got as far as
# the AT chain, so the log settles it instead: the command WAS sent, and
# AT+CIPSERVER never followed it. That pins the missing listener on the wait,
# which is the one thing that differs from K3.
if ! at_sent "$OUT/cipsto-strict.log" "AT+CIPSTO=$REFUSED_STO"; then
    fail "K4 PRECONDITION: the control ROM never sent AT+CIPSTO, so it stopped somewhere else"
elif at_sent "$OUT/cipsto-strict.log" "AT+CIPSERVER=1,$PORT"; then
    fail "K4 the strict build carried on past the refusal, so K3's green is not the two-pattern wait"
elif [ "$listening" = 1 ]; then
    fail "K4 something was listening although AT+CIPSERVER was never sent — check for a stray jnext"
else
    pass "K4 waiting for OK alone abandons bring-up on the refusal: K3's green is the wait"
fi

log ""
log "Diagnosis:"
log "  jnext logs:   $OUT/cipsto-{short,shipped,refused,strict}.log"
log "  screenshot:   $shot"
log ""

total=4
if [ "$failures" -eq 0 ]; then
    log "All $total checks passed."
    exit 0
fi
log "$((total - failures))/$total passed, $failures FAILED."
exit 1
