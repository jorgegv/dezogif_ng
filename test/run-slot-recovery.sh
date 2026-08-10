#!/usr/bin/env bash
#
# run-slot-recovery.sh — does anything give the module's inbound slots back,
# and does it reap anyone it should not? Issues #19, #24 and #40. Seven headless
# jnext runs, nine checks, and the verdict is a socket and a log rather than a
# picture.
#
# S1-S3 are issue #19: the sweep itself, reached the only way it could be
# reached when it was written — from esp_recover, after consecutive faults.
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
# S4-S7 are issue #24: the TRIGGER, which is what #19 never had. esp_recover
# fires on consecutive faults, and the state that strands a user raises none —
# nothing can connect, the leaked peers are silent, and an unprompted send to a
# stale id returns quietly. So the sweep sat there unable to run. esp_idle_tick
# reaches it from a quiet stub instead.
#
#   S4  the sweep fires with NO FAULT ANYWHERE. Nobody connects at all; the
#       stub is left alone past its idle period; AT+CIPCLOSE appears and
#       AT+CIPSERVER=0 does not, which is what says this was the idle trigger
#       and not esp_recover. A fresh client is then served — the listener was
#       never retired, unlike a recovery's sweep.
#   S5  it fires ONCE per idle period, not every period for ever. The same run
#       sits through several periods and must show exactly one sweep's worth of
#       AT+CIPCLOSE. Without this the shipped ROM would open a refusal window
#       every five minutes for as long as the machine was switched on.
#   S6  it does NOT fire while a DZRP session is open — a client that INITs and
#       then reads code for a while is silent and perfectly healthy, and
#       KNOWN-ISSUES.md #19 and issue #24 both forbid closing on suspicion.
#       ITS OWN CONTROL IS IN THE SAME RUN: the client then disconnects and a
#       sweep must follow, which is what shows the timer was live throughout
#       and only the session was holding it off. Without that half, a run that
#       was simply too short would pass.
#   S7  the control, IDLE_SWEEP=0: the trigger assembled out. The same run must
#       show no AT+CIPCLOSE at all.
#
# S8-S9 are issue #40, which is the trigger's own side effect rather than a new
# feature. Only a parsed +IPD restarted the timer, and a bare TCP connect never
# reaches one — so a socket the module accepted while the stub was idle sat
# inside a period it had not started, and was reaped by it. The module's
# `<id>,CONNECT` line now restarts the timer too, which gives such a socket a
# WHOLE period rather than whatever was left of somebody else's.
#
#   S8  a client connects and says NOTHING. It must still be there, and still
#       be served, at a moment past the deadline the run's own previous period
#       had set — and the log must show no sweep in between.
#   S9  the control, CONNECT_RESET=0: the same staging, the reset assembled
#       out. The same client must be closed before it ever speaks.
#
# HOW S8 IS STAGED, because "connect and wait" is not enough on its own. The
# grace the fix buys is exactly one period, so the difference is only visible
# to a client that connects LATE in one — connect at the start of a period and
# both ROMs let it live. So each run measures its own period first (arm the
# timer with one CMD_LOOPBACK, time the sweep that follows), then arms again,
# waits 0.65 of that, connects the silent client, and lets it speak 0.60 of a
# period later. On the control the deadline (1.00) falls inside that silence;
# on the shipped ROM the connect moves it to 1.65 and the client speaks at 1.25.
# Three preconditions keep a mis-staged run from reporting a verdict: the period
# must be sane, the connect must land in a band around 0.65, and no sweep may
# have fired before the client connected. Measured, five consecutive periods in
# one run: 1.737 1.789 1.790 1.786 1.797 s — a 3.4% spread against margins of
# 28% or better.
#
# WHY S3 AND S7 ARE BUILD SEAMS AND NOT SCRATCH TREES. The state being fixed
# here is unreachable in the shipped ROM by construction, so without a seam the
# red would be a story about a tree nobody can rebuild. Each pair differs in
# exactly one assembler constant, which is what attributes the green to the code
# under test and not to whatever it rides in.
#
# WHY THE IDLE PERIOD IS A SEAM TOO. The shipped ESP_IDLE_SWEEP_SECS is 300 —
# five minutes of doing nothing per check — so no bench anybody runs can sit it
# out. IDLE_SWEEP=10 makes it watchable, exactly as SERVER_TIMEOUT does for the
# module's own half-hour timeout in run-cipsto.sh.
#
# AND WHY THE IDLE ROMS ARE NOT BUILT FAULT_LIMIT=1 like S1's. A limit of one
# would let any single stray fault reach esp_recover, whose sweep is
# indistinguishable in the log from the one being measured — S4's whole
# attribution is that AT+CIPSERVER=0 is absent, and that reading is only worth
# having if a recovery was unlikely rather than one timeout away.
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
#   * THAT THE SWEEP REPAIRED ANYTHING, for S4-S7 especially. No run in an
#     emulator can make the emulated module unresponsive or leak a slot to a
#     peer that vanished, so what a green idle check shows is that the
#     MECHANISM FIRES from a quiet stub — never that it recovered a module that
#     was in trouble. Issue #24's acceptance criteria ask for exactly that
#     wording and this is it.
#   * ANY REAL TIMING. esp_idle_tick counts emulated video lines, and headless
#     jnext runs frames faster than real time, so the wall-clock waits below are
#     upper bounds on several idle periods rather than measurements of one. S8's
#     calibration is the one exception and it is deliberately RELATIVE: it never
#     says what a period is, only that one stretch of a run is 0.65 of another.
#   * THAT A REAL CLIENT WAS EVER BITTEN by what S8 covers. DeZog sends CMD_INIT
#     the moment it connects, so its own window is milliseconds wide against a
#     shipped period of 300 seconds. S8 stages a reachable state, not an
#     observed one; issue #40 says so in as many words.
#
# Environment (all set by the Makefile, all overridable):
#   JNEXT            path to the jnext binary
#   SD_IMAGE         reference SD card image; NEVER written, only copied
#   OUT              build directory
#   ROM_SWEEP        WiFi ROM, FAULT_LIMIT=1
#   ROM_NOSWEEP      the same, plus LINK_IDS=0
#   ROM_IDLE         WiFi ROM, IDLE_SWEEP=10 (shipped fault limit)
#   ROM_NOIDLE       the same, plus IDLE_SWEEP=0 — the trigger assembled out
#   ROM_NOCONNRESET  the same, plus CONNECT_RESET=0 — the connect reset out

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
ROM_IDLE=${ROM_IDLE:-$OUT/enNextMf-wifi-idle10.rom}
ROM_NOIDLE=${ROM_NOIDLE:-$OUT/enNextMf-wifi-idle0.rom}
ROM_NOCONNRESET=${ROM_NOCONNRESET:-$OUT/enNextMf-wifi-idle10-cr0.rom}

CLIENT=$(dirname "$0")/dzrp/slot-recovery-client.py
IDLE_CLIENT=$(dirname "$0")/dzrp/idle-sweep-client.py

PORT=11000

# The idle period the probe ROMs are built with, in EMULATED seconds. Pinned
# here as well as passed to the build so that a mismatch is a failure rather
# than a bench quietly waiting for something that cannot happen.
IDLE_SECS=10

# How long to wait, in WALL seconds, for the first sweep to appear in the log.
# Headless jnext runs frames faster than real time, so this is generous rather
# than tuned; a run that has not swept by here has not swept.
SWEEP_TIMEOUT=${SWEEP_TIMEOUT:-90}

# How long to keep watching afterwards, so that S5's "once" is a statement about
# several more idle periods rather than about the one that just ended.
SWEEP_SETTLE=${SWEEP_SETTLE:-20}

# How long --mode hold keeps its session open in silence. Must cover several
# idle periods; S6's own in-run control is what proves it did.
HOLD_SECS=${HOLD_SECS:-30}

# How many link ids the shipped sweep asks about. Pinned here as well as in the
# source deliberately: S2 is worth nothing if it counts whatever it finds.
LINK_IDS=5

# S8/S9's staging, as fractions of the period each run measures for itself. The
# silent client connects at CONNECT_AT and speaks SILENT_FOR later, so it speaks
# at 1.25 — past the control's deadline of 1.00 and well inside the shipped
# ROM's 1.65. See the header for the margins each of those leaves.
CONNECT_AT=0.65
SILENT_FOR=0.60

# The band the connect must actually land in for a verdict to be given, again as
# fractions of the measured period. Below 0.45 the control's own deadline would
# fall after the client had already spoken and its red would mean nothing; above
# 0.85 the sweep is likely to beat the client to the connect, which the sweep
# count checks directly anyway. Nominal is CONNECT_AT plus the client's own
# start-up, about 0.03 of a period here.
CONNECT_AT_MIN=0.45
CONNECT_AT_MAX=0.85

# A period this bench refuses to time anything against, in wall seconds. Ten
# emulated seconds measured 1.74-1.80 s here; a run far outside that is an
# emulator running at a speed these fractions were never chosen for.
PERIOD_MIN=${PERIOD_MIN:-0.30}
PERIOD_MAX=${PERIOD_MAX:-30.0}

# Long enough for a sweep's five-id walk to finish, in wall seconds. A client
# opened during one keeps its slot but may be closed by a LATER id in the same
# pass — a documented cost of #24 (transport_esp.asm, ESP_IDLE_SWEEP_SECS) and
# not what S8 is about, so the staging stays clear of it.
WALK_SETTLE=${WALK_SETTLE:-3}

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

[ -f "$IDLE_CLIENT" ] || die "client not found: $IDLE_CLIENT"

for rom in "$ROM_SWEEP" "$ROM_NOSWEEP" "$ROM_IDLE" "$ROM_NOIDLE" \
           "$ROM_NOCONNRESET"; do
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
elif [ "$rc" -eq 20 ]; then
    fail "S1 the client itself crashed: a harness fault, not a finding about the module"
    fail "S2 not judged: the client crashed"
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
elif [ "$rc" -eq 20 ]; then
    fail "S3 the client itself crashed: a harness fault, not a finding about the module"
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

# --- the idle trigger, issue #24 -------------------------------------------
#
# count_log <logfile> — the same counters run_client leaves, read from a log
# while or after jnext ran. Split out because the idle runs do their counting at
# a moment of their own choosing rather than at the end of a client.
count_log() {
    local logfile=$1
    stops=$(grep -c 'AT <- "AT+CIPSERVER=0"' "$logfile" || true)
    closes=$(grep -c 'AT <- "AT+CIPCLOSE=' "$logfile" || true)
    listens=$(grep -c 'AT+CIPSERVER=1,.* — listening' "$logfile" || true)
}

# wait_for_sweep <logfile> <seconds> — poll until at least one AT+CIPCLOSE is in
# the log, or give up. Polling rather than sleeping a fixed time because the
# emulator's frame rate, and so the stub's idea of elapsed time, is not ours to
# predict; the fixed sleep that matters is the one AFTER this, which is what
# makes "exactly one sweep" mean something.
wait_for_sweep() {
    wait_for_more_sweeps "$1" 0 "$2"
}

# wait_for_more_sweeps <logfile> <baseline> <seconds> — poll until the log holds
# MORE AT+CIPCLOSE than it did at <baseline>. A bare "is there one" is not enough
# for S6, whose whole subject is a sweep that happened at a particular moment in
# a run that has already swept once.
wait_for_more_sweeps() {
    local logfile=$1 baseline=$2 limit=$3 i n
    for i in $(seq $((limit * 4))); do
        n=$(grep -c 'AT <- "AT+CIPCLOSE=' "$logfile" 2>/dev/null || true)
        if [ "${n:-0}" -gt "$baseline" ]; then
            return 0
        fi
        sleep 0.25
    done
    return 1
}

log ""
log "== S4/S5: the idle trigger — a quiet stub sweeps once, with no fault"

log3=$OUT/slot-recovery-idle.log
shot3=$OUT/screenshots/slot-recovery-idle.png
swept=0

if start_stub "$ROM_IDLE" "$log3" "$shot3"; then
    # NOBODY CONNECTS. That is the state under test: the stub has come up, is
    # listening, and has nothing to do — which after ESP_IDLE_SWEEP_SECS is when
    # the sweep is owed.
    if wait_for_sweep "$log3" "$SWEEP_TIMEOUT"; then swept=1; fi
    # Several more idle periods, so that S5 is about repetition and not about
    # the period that has just ended.
    sleep "$SWEEP_SETTLE"
    count_log "$log3"
    # Only NOW does a client appear, which is what makes "served afterwards" a
    # statement about a stub that has already swept its own link ids.
    rc=0
    python3 "$IDLE_CLIENT" --host 127.0.0.1 --port "$PORT" \
        --timeout "$CLIENT_TIMEOUT" --mode fresh | sed 's/^/  | /' || rc=$?
    stop_stub
else
    rc=99
    stops=0; closes=0; listens=0
fi

log "  swept=$swept recoveries=$stops closes=$closes listens=$listens (from $log3)"

if [ "$rc" -eq 99 ]; then
    fail "S4 the stub's listener never appeared, so nothing was tested"
    fail "S5 the run never got far enough to count sweeps"
elif [ "$swept" -eq 0 ]; then
    fail "S4 no AT+CIPCLOSE in ${SWEEP_TIMEOUT}s of idling: the trigger never fired"
    fail "S5 nothing swept, so there was nothing to count"
elif [ "${stops:-0}" -ne 0 ]; then
    fail "S4 esp_recover ran ($stops AT+CIPSERVER=0), so this sweep is not attributable to the idle trigger"
    fail "S5 not judged: a recovery swept as well"
else
    if [ "$rc" -ne 0 ]; then
        fail "S4 the stub swept while idle but then would not serve a fresh client"
    else
        pass "S4 an idle stub swept its link ids with no fault, and still served a fresh client"
    fi
    # EXACTLY one sweep, not "at least one": the whole point of esp_idle_armed
    # is that a stub left switched on does not open a refusal window every
    # period for ever.
    if [ "${closes:-0}" -ne "$LINK_IDS" ]; then
        fail "S5 $closes AT+CIPCLOSE over many idle periods, where one sweep is $LINK_IDS"
    else
        pass "S5 the idle sweep ran once over many periods: $closes AT+CIPCLOSE, one per link id"
    fi
fi

# --- S6: a live session holds the trigger off ------------------------------

log ""
log "== S6: an open DZRP session must stop the clock — and its own control"

log4=$OUT/slot-recovery-idle-session.log
shot4=$OUT/screenshots/slot-recovery-idle-session.png
after=0

if start_stub "$ROM_IDLE" "$log4" "$shot4"; then
    sentinel=$OUT/idle-session.sentinel
    out4=$OUT/idle-session-client.txt
    rm -f "$sentinel"

    # BACKGROUNDED WITHOUT A PIPE, and both halves of that matter. Backgrounded
    # because the baseline has to be taken while the client is still holding;
    # unpiped because `cmd | sed &` makes $! the pid of SED, so `wait` would
    # report the wrong exit status — the shape ERRORS.md records losing an
    # afternoon to.
    rc=0
    python3 "$IDLE_CLIENT" --host 127.0.0.1 --port "$PORT" \
        --timeout "$CLIENT_TIMEOUT" --mode hold --watch "$HOLD_SECS" \
        --sentinel "$sentinel" >"$out4" 2>&1 &
    client_pid=$!

    # THE BASELINE IS TAKEN WHEN THE SESSION OPENS, NOT WHEN THE RUN DID. The
    # stub is idle from the moment it comes up and jnext runs several emulated
    # seconds per wall second, so with a ten-second period it has usually swept
    # once before this client ever connects. Counting from the start of the run
    # charged that sweep to the hold and failed a stub that was behaving.
    for _ in $(seq 240); do
        [ -s "$sentinel" ] && break
        kill -0 "$client_pid" 2>/dev/null || break
        sleep 0.25
    done
    count_log "$log4"
    baseline=${closes:-0}

    wait "$client_pid" || rc=$?
    sed 's/^/  | /' "$out4"
    count_log "$log4"
    during=$((closes - baseline))

    # The client has gone. The SAME run must now sweep AGAIN — more closes than
    # when the client exited — which is what says the timer was alive throughout
    # and only the open session was holding it off.
    if wait_for_more_sweeps "$log4" "${closes:-0}" "$SWEEP_TIMEOUT"; then after=1; fi
    stop_stub
else
    rc=99
    during=0; baseline=0; stops=0; closes=0; listens=0
fi

log "  baseline=$baseline during_session=$during after_disconnect=$after recoveries=$stops (from $log4)"

if [ "$rc" -eq 99 ]; then
    fail "S6 the stub's listener never appeared, so nothing was tested"
elif [ "$rc" -eq 3 ]; then
    fail "S6 the session was dropped during the hold, so the state under test was never held"
elif [ "$rc" -ne 0 ]; then
    fail "S6 the held session did not behave: the client exited $rc, so its silence proves nothing"
elif [ "${stops:-0}" -ne 0 ]; then
    fail "S6 esp_recover ran during this run, so no reading here is attributable to the idle trigger"
elif [ "$during" -ne 0 ]; then
    fail "S6 the stub swept $during link ids while a DZRP session was open — it closed on suspicion"
elif [ "$after" -eq 0 ]; then
    fail "S6 no sweep after the client left either, so this run never showed the timer was live"
else
    pass "S6 no sweep while the session was open, and one as soon as the client had gone"
fi

# --- S7: the control, the trigger assembled out ----------------------------

log ""
log "== S7: the control, IDLE_SWEEP=0 — no trigger at all"

log5=$OUT/slot-recovery-noidle.log
shot5=$OUT/screenshots/slot-recovery-noidle.png

if start_stub "$ROM_NOIDLE" "$log5" "$shot5"; then
    # The same wait as S4's, spent the same way: nobody connects.
    swept=0
    if wait_for_sweep "$log5" "$SWEEP_TIMEOUT"; then swept=1; fi
    sleep "$SWEEP_SETTLE"
    count_log "$log5"
    rc=0
    python3 "$IDLE_CLIENT" --host 127.0.0.1 --port "$PORT" \
        --timeout "$CLIENT_TIMEOUT" --mode fresh | sed 's/^/  | /' || rc=$?
    stop_stub
else
    rc=99
    swept=0; stops=0; closes=0; listens=0
fi

log "  swept=$swept recoveries=$stops closes=$closes listens=$listens (from $log5)"

if [ "$rc" -eq 99 ]; then
    fail "S7 the stub's listener never appeared, so the control tested nothing"
elif [ "$rc" -ne 0 ]; then
    fail "S7 the control ROM would not serve a fresh client, so its silence has another explanation"
elif [ "${closes:-0}" -ne 0 ]; then
    fail "S7 the control issued $closes AT+CIPCLOSE, so IDLE_SWEEP=0 did not remove the trigger"
else
    pass "S7 with the trigger assembled out the same idling produces no sweep at all"
fi

# --- S8/S9: a socket the module accepted, which has not spoken yet ----------
#
# Issue #40. Everything above measures whether the sweep FIRES; this measures
# who it takes with it.

# Floating point, because everything here is a fraction of a period the run has
# just measured for itself. awk rather than bc: it is already a hard dependency
# of this tree's benches and bc is not.
fmul() { awk -v a="$1" -v b="$2" 'BEGIN{printf "%.3f", a*b}'; }
fsub() { awk -v a="$1" -v b="$2" 'BEGIN{printf "%.3f", a-b}'; }
fdiv() { awk -v a="$1" -v b="$2" 'BEGIN{printf "%.3f", (b==0 ? 0 : a/b)}'; }
flt()  { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a<b)}'; }

# Like wait_for_more_sweeps but polling twenty times a second instead of four.
# The period being timed is under two seconds here, so a quarter-second poll
# would put a 14% error on the one number every fraction below is taken from.
wait_for_more_sweeps_fine() {
    local logfile=$1 baseline=$2 limit=$3 i n
    for i in $(seq $((limit * 20))); do
        n=$(grep -c 'AT <- "AT+CIPCLOSE=' "$logfile" 2>/dev/null || true)
        if [ "${n:-0}" -gt "$baseline" ]; then
            return 0
        fi
        sleep 0.05
    done
    return 1
}

# run_connect_grace <rom> <logfile> <shotfile> <clientout> — stages a silent
# client late in a measured idle period. Leaves $rc, $period, $connect_at,
# $base8, $at_connect and $at_speak set.
#
#   rc  0  the client survived its silence and was then served
#       3  it was closed before it ever spoke — issue #40's defect
#       4  it survived but its first command was not answered
#      97  the calibration never saw a sweep
#      98  an arming command was not answered
#      99  the stub's listener never appeared
run_connect_grace() {
    local rom=$1 logfile=$2 shotfile=$3 clientout=$4
    local base t0 t1 t2 t3 pre watch sentinel client_pid
    rc=0; period=0; connect_at=0; base8=0; at_connect=0; at_speak=0

    if ! start_stub "$rom" "$logfile" "$shotfile"; then
        rc=99
        return 0
    fi

    # The stub sweeps once shortly after boot, on its own, and then disarms, so
    # the state this needs — armed and counting from a known moment — has to be
    # created deliberately. Wait that first sweep out and let its five-id walk
    # finish before anything else connects.
    wait_for_sweep "$logfile" "$SWEEP_TIMEOUT" || true
    sleep "$WALK_SETTLE"

    # --- calibrate: one arming frame, then time the sweep it leads to -------
    count_log "$logfile"
    base=$closes
    if ! python3 "$IDLE_CLIENT" --host 127.0.0.1 --port "$PORT" \
            --timeout "$CLIENT_TIMEOUT" --mode arm >/dev/null 2>&1; then
        rc=98; stop_stub; return 0
    fi
    t0=$(date +%s.%N)
    if ! wait_for_more_sweeps_fine "$logfile" "$base" "$SWEEP_TIMEOUT"; then
        rc=97; stop_stub; return 0
    fi
    t1=$(date +%s.%N)
    period=$(fsub "$t1" "$t0")
    sleep "$WALK_SETTLE"

    # --- stage: arm again, wait most of a period, then connect in silence ---
    count_log "$logfile"
    base8=$closes
    if ! python3 "$IDLE_CLIENT" --host 127.0.0.1 --port "$PORT" \
            --timeout "$CLIENT_TIMEOUT" --mode arm >/dev/null 2>&1; then
        rc=98; stop_stub; return 0
    fi
    t2=$(date +%s.%N)
    pre=$(fmul "$period" "$CONNECT_AT")
    watch=$(fmul "$period" "$SILENT_FOR")
    sleep "$pre"

    sentinel=$OUT/connect-grace.sentinel
    rm -f "$sentinel"
    # Backgrounded WITHOUT a pipe: `cmd | sed &` makes $! the pid of sed, so
    # `wait` would report the wrong status. Same shape, same reason, as S6.
    python3 "$IDLE_CLIENT" --host 127.0.0.1 --port "$PORT" \
        --timeout "$CLIENT_TIMEOUT" --mode silent --watch "$watch" \
        --sentinel "$sentinel" >"$clientout" 2>&1 &
    client_pid=$!

    # The sentinel is written the instant the SOCKET is open and before a byte
    # is sent, so this is where in the idle period the connect really landed —
    # which is the one thing the whole staging turns on.
    for _ in $(seq 500); do
        [ -s "$sentinel" ] && break
        kill -0 "$client_pid" 2>/dev/null || break
        sleep 0.02
    done
    t3=$(date +%s.%N)
    count_log "$logfile"
    at_connect=$closes
    connect_at=$(fdiv "$(fsub "$t3" "$t2")" "$period")

    rc=0
    wait "$client_pid" || rc=$?
    count_log "$logfile"
    at_speak=$closes
    stop_stub
}

# judge_connect_grace <id> <expect> — the two checks differ in one thing, which
# is what they want to have happened to the silent client, so their four shared
# preconditions are written once. <expect> is `served` or `swept`.
judge_connect_grace() {
    local id=$1 expect=$2
    if [ "$rc" -eq 99 ]; then
        fail "$id the stub's listener never appeared, so nothing was tested"
    elif [ "$rc" -eq 98 ]; then
        fail "$id an arming command went unanswered, so the timer had no known origin"
    elif [ "$rc" -eq 97 ]; then
        fail "$id no sweep in the calibration, so this run has no period to time against"
    elif flt "$period" "$PERIOD_MIN" || flt "$PERIOD_MAX" "$period"; then
        fail "$id the measured idle period was ${period}s, outside anything these fractions fit"
    elif flt "$connect_at" "$CONNECT_AT_MIN" || flt "$CONNECT_AT_MAX" "$connect_at"; then
        fail "$id the client connected at $connect_at of the period, outside the staged band"
    elif [ "$at_connect" -ne "$base8" ]; then
        fail "$id a sweep had already fired when the client connected: it was never staged"
    elif [ "$expect" = "served" ]; then
        # The subject. Two things, and the second is what makes the first a
        # statement about the timer rather than about luck: no sweep may have
        # happened at all while the client sat there.
        if [ "$rc" -eq 3 ]; then
            fail "$id the silent client was closed before it ever spoke: the connect did not count"
        elif [ "$rc" -ne 0 ]; then
            fail "$id the silent client survived but was not served: the client exited $rc"
        elif [ "$at_speak" -ne "$base8" ]; then
            fail "$id a sweep fired while the silent client waited, $((at_speak - base8)) link ids closed"
        else
            pass "$id a client that connected and said nothing was not swept, and was served"
        fi
    else
        # The control. It must both sweep and take the client with it: a run
        # where no sweep fired at all would leave the client alive for a reason
        # that has nothing to do with the reset being assembled out.
        if [ "$at_speak" -eq "$base8" ]; then
            fail "$id no sweep fired at all, so the control never reached the state it compares"
        elif [ "$rc" -eq 0 ]; then
            fail "$id without the reset the silent client survived anyway, so S8's green is not it"
        elif [ "$rc" -ne 3 ] && [ "$rc" -ne 4 ]; then
            fail "$id the control client exited $rc, which is a harness fault and not a finding"
        else
            pass "$id without the connect reset the same client is closed before it speaks"
        fi
    fi
}

log ""
log "== S8: a client that connects and has not spoken yet must not be swept"

log6=$OUT/slot-recovery-connect-grace.log
run_connect_grace "$ROM_IDLE" "$log6" \
    "$OUT/screenshots/slot-recovery-connect-grace.png" \
    "$OUT/connect-grace-client.txt"
[ -f "$OUT/connect-grace-client.txt" ] && sed 's/^/  | /' "$OUT/connect-grace-client.txt"

log "  period=${period}s connect_at=$connect_at base=$base8 at_connect=$at_connect at_speak=$at_speak rc=$rc (from $log6)"
judge_connect_grace S8 served

log ""
log "== S9: the control, CONNECT_RESET=0 — the connect reset assembled out"

log7=$OUT/slot-recovery-noconnreset.log
run_connect_grace "$ROM_NOCONNRESET" "$log7" \
    "$OUT/screenshots/slot-recovery-noconnreset.png" \
    "$OUT/noconnreset-client.txt"
[ -f "$OUT/noconnreset-client.txt" ] && sed 's/^/  | /' "$OUT/noconnreset-client.txt"

log "  period=${period}s connect_at=$connect_at base=$base8 at_connect=$at_connect at_speak=$at_speak rc=$rc (from $log7)"
judge_connect_grace S9 swept

# --- verdict ---------------------------------------------------------------

log ""
if [ "$failures" -eq 0 ]; then
    log "All checks passed (9/9)."
else
    log "$failures check(s) FAILED."
fi
exit $((failures > 0))
