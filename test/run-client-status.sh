#!/usr/bin/env bash
#
# The session line on the Next's own screen — issues #14, #23 and #28.
#
# Invoked by `make test-client-status`. Eight headless jnext runs with the WiFi
# ROM installed as the Multiface ROM and an emulated M1 button press. Five put
# the stub in a different session state and read row 8 of its screen BACK AS
# TEXT; the last three judge memory over the socket instead.
#
#   N1  a client connects over TCP and says NOTHING  ->  "No debug session yet."
#   N2  a client sends CMD_INIT                      ->  "Session opened - CMD_INIT"
#   N3  ... and then CMD_CLOSE                       ->  "Session closed - CMD_CLOSE"
#   N4  ... or instead VANISHES, no CMD_CLOSE        ->  "Session lost - client gone"
#   N5  the same, with the stub back in its idle loop first
#   N6  the same again with MMU slot 2 retargeted    ->  that bank is UNTOUCHED
#   N7  the same again with MMU slot 1 retargeted    ->  that SLOT is given back
#   N8  slot 2 retargeted, then CMD_CLOSE            ->  show_ui leaves it alone
#
# WHY IT READS THE ROW RATHER THAN COMPARING RUNS. A check that only requires
# the three screens to differ cannot say which of them is right, and ERRORS.md
# records what that costs: mfselect's M9 compared two runs, passed, and a
# reviewer then SWAPPED the two labels and it passed again. Here the two states
# that matter are adjacent lines of similar length, so a swap is exactly the
# plausible bug. test/screen-text.py decodes the row using the ZX ROM font off
# the SD image, so each run is judged on what it SAYS, on its own.
#
# The reader is validated INSIDE EACH RUN before its verdict is used: row 12 of
# the stub's screen is "R = Reset", drawn by the same code with the same font
# and not in question, so if that does not come back the run reports a broken
# reader instead of a wrong line.
#
# N1 IS NOT A BASELINE, it is the honesty check. The line reports a DZRP session
# and a socket is not one; a stub that lit it on a connection would be claiming
# what this transport cannot see. N1's client stays connected while the
# screenshot is taken, so it really is the "connected and silent" state.
#
# N4 AND N5 ARE ISSUE #23, and the fourth line is deliberately NOT N1's. Reusing
# "No debug session yet." would make the state after a vanished client
# indistinguishable from one where CMD_INIT was never seen at all, so a check
# for it would go green against a ROM that had simply failed to light the line —
# mfselect's M9 in a new costume (ERRORS.md). "Session lost - client gone" can
# only be drawn by having observed the connection go.
#
# N5 IS NOT A SECOND COPY OF N4, and the difference is which code redraws the
# row. N4's client vanishes while the stub sits in cmd_loop, so the scan that
# meets the `<id>,CLOSED` finds no header afterwards, times out, and reaches
# drain_main — whose show_ui draws the row. N5's waits for that same wait's bound
# to expire into main_loop first, where a scan that finds nothing is not an error
# and drain_main is never reached, so the ONLY thing that can have redrawn the
# row is esp_refresh_client_line. That is asserted rather than reasoned: N5
# requires the stub's error area to be CLEAN, which a run that had been through
# drain_main could not be (it would carry "Last Error: RX Timeout"). Without
# that line the two runs would exercise one path and claim two.
#
# AND THAT SAME ASSERTION IS WHAT MAKES N5'S ONE MARGIN FAIL SAFELY. Its client
# waits IDLE_WAIT wall seconds for a bound counted in EMULATED ones — the
# mismatch this project has been caught by before (W6's SECOND_NMI_FRAMES). The
# margin is wide, roughly 4x at the rate headless jnext runs at, but it is a
# margin. If it were ever lost the stub would still be in cmd_loop, the repaint
# would come from drain_main, and the error area would carry RX Timeout: N5 goes
# RED. It cannot fail green, which is the only property a margin has to have.
#
# IDLE_WAIT is overridable, so that is MEASURED rather than argued and anyone can
# re-run it: `IDLE_WAIT=0 make test-client-status` puts N5's client back inside
# cmd_loop, and N5 duly fails with 848 bright-red pixels of "RX Timeout" while
# its row-8 verdict is still correct. So the clean-area line is what separates
# the two paths, and it is the only thing that does.
#
# WHAT IT DOES NOT COVER, and the code says the same thing in the same words:
#   * a client that stops answering WITHOUT its socket closing. The module emits
#     no line for that, so nothing here can see it — a suspended peer that never
#     sends FIN or RST is KNOWN-ISSUES.md #2, not this.
#   * a `<id>,CLOSED` that arrives inside a transport_drain. That reads with raw
#     `in` and hands the bytes to nobody, so the observer never sees it; the
#     matching `<id>,CONNECT` when the module hands that id on is what covers it,
#     and no run here produces the case.
#   * what the stub DOES about a departed client. Nothing: the observation
#     touches the session line and none of the transport's own state, on purpose
#     (esp_line_event). Reconnect and recovery are issues #24 and #25.
#   * UART mode, which has no connection event at all and deliberately draws
#     nothing. There is nothing here to test.
#   * real hardware. This is jnext, like every other bench in this repository.
#
# Environment (all set by the Makefile, all overridable):
#   JNEXT     path to the jnext binary
#   SD_IMAGE  reference SD card image; NEVER written, only copied
#   OUT       build directory
#   ROM       our WiFi-mode enNextMf.rom

set -euo pipefail

# ---------------------------------------------------------------------------
# SERIALISE BENCH RUNS ACROSS PROCESSES — see test/run-dzrp-stub.sh for the
# measurement behind this. A run contaminated by another bench's client can come
# out GREEN, answered by somebody else's stub, which is worse than a red one.
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

PORT=11000
BOOT_FRAMES=900

# THE CAPTURE FRAME, and the one thing here that is a judgement rather than an
# assertion. jnext can only be told to screenshot at a frame, so nothing can
# make the capture wait for the client. It is set far past the frame the client
# finishes at (~1200 measured) and the ordering is then CHECKED against the
# client's own timestamp, so a capture that came too early is reported as a
# harness problem and not as the screen saying the wrong thing.
SHOT_FRAMES=6000
EXIT_FRAMES=200000

RUN_TIMEOUT=600
LISTEN_TIMEOUT=60
SHOT_TIMEOUT=180
SETTLE=${SETTLE:-2}

# The row the session line is drawn on: ESP_CLIENT_ROW in src/transport_esp.asm.
CLIENT_ROW=8
# A line drawn by the same code, in the same font, whose text is not in
# question. It is what validates the reader before its verdict is trusted.
CONTROL_ROW=12
CONTROL_TEXT="R = Reset"

MF_ROM_PATH='::/machines/next/enNextMf.rom'
FONT_ROM_PATH='::/machines/next/48.rom'
CLIENT=$(dirname "$0")/dzrp/session-client.py
SCREENTEXT=$(dirname "$0")/screen-text.py

# Shared jnext teardown — issue #17. This script's own stop_all was the first
# implementation of it, written when the contamination was seen; the other six
# benches never got it, which is what made #17 a repository-wide defect rather
# than a one-file one. The reasoning, and the two mistakes made getting it
# right, now live in that file. Defines functions and nothing else, so it cannot
# disturb the `set -euo pipefail` above or the traps below.
# shellcheck source=test/bench-jnext.sh
. "$(dirname "$0")/bench-jnext.sh"

log()  { printf '%s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# --- pre-flight ------------------------------------------------------------

[ -x "$JNEXT" ]     || die "jnext binary not found or not executable: $JNEXT"
[ -f "$SD_IMAGE" ]  || die "SD card image not found: $SD_IMAGE"
[ -f "$ROM" ]       || die "WiFi ROM not built: $ROM (run 'make mf-rom-wifi')"
[ -f "$CLIENT" ]    || die "client fixture not found: $CLIENT"
[ -f "$SCREENTEXT" ]|| die "screen reader not found: $SCREENTEXT"
python3 -c 'import PIL' 2>/dev/null || die "python3 Pillow is required to read the screen"
command -v mcopy >/dev/null || die "mtools (mcopy) is required to reach the SD image"

# The ROM must really be the WiFi one: the UART build draws no session line at
# all, and this bench would then report a missing feature where the truth is the
# wrong file. Issue #4's magic string is what answers that.
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
        || die "something is already listening on 127.0.0.1:$PORT — stop it first"
fi

part_lba=$(od -An -tu4 -j 454 -N 4 "$SD_IMAGE" | tr -d ' ')
[ -n "$part_lba" ] && [ "$part_lba" -gt 0 ] || die "cannot read partition table from $SD_IMAGE"
part_off=$((part_lba * 512))

mkdir -p "$OUT" "$OUT/screenshots"

# --- the run ---------------------------------------------------------------
#
# The reference image is never written; the working copy is deleted on the way
# out. The trap is armed BEFORE the copy — see test/run-dzrp-stub.sh.

sd=$OUT/sd-client-status.img
font=$OUT/font-48.rom

jnext_pid=""
client_pid=""
cleanup() {
    if [ -n "$client_pid" ] && kill -0 "$client_pid" 2>/dev/null; then
        kill "$client_pid" 2>/dev/null || true
        wait "$client_pid" 2>/dev/null || true
    fi
    if [ -n "$jnext_pid" ] && kill -0 "$jnext_pid" 2>/dev/null; then
        kill "$jnext_pid" 2>/dev/null || true
        wait "$jnext_pid" 2>/dev/null || true
    fi
    # Unlinked BEFORE departure is confirmed: bench_await_departure can exit,
    # and an exit that skipped this would leak a gigabyte (ERRORS.md).
    rm -f "$sd"
    # The EXIT path had no departure check even here — stop_all covers the run
    # boundaries, but not an interrupt landing mid-run. Issue #17.
    bench_await_departure "$sd"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

cp --reflink=auto -f "$SD_IMAGE" "$sd"
mcopy -o -i "$sd@@$part_off" "$ROM" "$MF_ROM_PATH"

# The font the stub prints with. Taken from the SAME image the machine boots, so
# the reader cannot be reading one font while the Next draws another.
mcopy -o -i "$sd@@$part_off" "$FONT_ROM_PATH" "$font" \
    || die "cannot read $FONT_ROM_PATH out of the SD image"

failures=0
# Counted by one_run rather than written down. The summary line here used to say
# "3 of 3" whatever had run, and a bench that reports a fixed total is a bench
# whose next check can go missing without anyone noticing — the same defect
# run-headless.sh had at five.
CHECKS=0
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; failures=$((failures + 1)); }

# stop_all — end this run's client and emulator, and REFUSE TO CONTINUE UNTIL
# THE EMULATOR IS ACTUALLY GONE.
#
# Killing the `timeout` wrapper does reach jnext through its signal forwarding,
# measured — but "does" is not "always did", and an emulator that outlives the
# lock this script holds is the worst failure mode in this repository: it binds
# port 11000 for the NEXT agent's bench, whose client then talks to our stub and
# whose run can come out GREEN on our answers. So the departure is checked, not
# assumed, by bench_await_departure — which kills only what OUR sd image is
# running, a path unique to this bench.
stop_all() {
    if [ -n "$client_pid" ] && kill -0 "$client_pid" 2>/dev/null; then
        kill "$client_pid" 2>/dev/null || true
        wait "$client_pid" 2>/dev/null || true
    fi
    client_pid=""
    if [ -n "$jnext_pid" ] && kill -0 "$jnext_pid" 2>/dev/null; then
        kill "$jnext_pid" 2>/dev/null || true
        wait "$jnext_pid" 2>/dev/null || true
    fi
    jnext_pid=""

    bench_await_departure "$sd"
}

# start_stub <logfile> <screenshot> — boot a Next with our WiFi ROM, press M1,
# and wait for the stub's own listener. That wait is an assertion: the port can
# only exist once the NMI was taken, MAIN was relocated, and AT+CIPMUX=1 /
# AT+CIPSERVER were both accepted.
start_stub() {
    local logfile=$1 shotfile=$2
    rm -f "$shotfile"

    # Per-run, not just at pre-flight: an emulator that appeared between two of
    # this script's own runs would otherwise answer the client we are about to
    # start, and a contaminated run can come out GREEN.
    if command -v ss >/dev/null 2>&1; then
        # `grep -c` and not `-q`. -q exits at its first match, and the SIGPIPE that
        # would give `ss` comes back as 141 under pipefail — which `!` then reads as
        # "free", starting a run against an occupied port. -c cannot do that: it must
        # read to EOF to count, so there is no early close to signal.
        # THE `|| true` IS FOR SOMETHING ELSE, and not for that: `grep -c` exits 1
        # when the count is 0, which is the ORDINARY case here.
        [ "$(ss -ltn 2>/dev/null | grep -cE "127\.0\.0\.1:$PORT\b" || true)" -eq 0 ] \
            || die "something is listening on 127.0.0.1:$PORT before this run started"
    fi

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
        kill -0 "$jnext_pid" 2>/dev/null || return 1
        if python3 -c "
import socket, sys
s = socket.socket()
s.settimeout(0.2)
sys.exit(0 if s.connect_ex(('127.0.0.1', $PORT)) == 0 else 1)
" 2>/dev/null; then
            # Settle before any client speaks: a client landing inside
            # bring-up's AT+CIFSR scan loses its first command, which is issue
            # #10 and is the bench declining to race the stub rather than the
            # stub being fixed. Same value and same reason as run-dzrp-stub.sh.
            sleep "$SETTLE"
            return 0
        fi
        sleep 0.25
    done
    return 1
}

# read_row <shot> <row> — the row, as text.
read_row() {
    python3 "$SCREENTEXT" --font "$font" "$1" "$2"
}

# bright_red <png> — how many pixels are EXACTLY bright red.
#
# The same instrument run-dzrp-stub.sh's W2 uses, and for a different question:
# there it is "did the stub report a fault", here it is "which code path
# redrew the row". ui.asm colours the bottom nine rows RED+BRIGHT and prints
# "Last Error: ..." into them, and nothing else on this screen is red at all;
# the border cannot be mistaken for it, because `out (BORDER),a` carries no
# bright bit. Zero means no error was reported, hence drain_main did not run.
bright_red() {
    python3 -c "
from PIL import Image
raw = Image.open('$1').convert('RGB').tobytes()
print(sum(1 for i in range(0, len(raw), 3)
          if raw[i] == 255 and raw[i+1] == 0 and raw[i+2] == 0))
"
}

# ===========================================================================
# one_run <name> <phase> <expected row 8 text> <why> [require-clean-error-area]
# ===========================================================================
one_run() {
    local name=$1 phase=$2 expected=$3 why=$4 clean=${5:-}
    CHECKS=$((CHECKS + 1))
    local jlog=$OUT/client-status-$name.log
    local shot=$OUT/screenshots/client-status-$name.png
    local cout=$OUT/client-status-$name.client.txt

    log ""
    log "== $name: $why"

    if ! start_stub "$jlog" "$shot"; then
        fail "$name the stub never listened on 127.0.0.1:$PORT (see $jlog)"
        stop_all
        return
    fi

    : >"$cout"
    HOLD=300 DZRP_PORT="$PORT" python3 "$CLIENT" "$phase" >"$cout" 2>&1 &
    client_pid=$!

    # Wait for the state to be set, not for the client to exit — it holds its
    # connection open on purpose so the screenshot sees the state as a live one.
    local i done_at=""
    for i in $(seq 240); do
        done_at=$(awk '/^EXCHANGE_DONE /{print $2; exit}' "$cout" 2>/dev/null || true)
        [ -n "$done_at" ] && break
        kill -0 "$client_pid" 2>/dev/null || break
        sleep 0.25
    done
    if [ -z "$done_at" ]; then
        fail "$name the client never reached its state — see $cout and $jlog"
        sed 's/^/  | /' "$cout" || true
        stop_all
        return
    fi
    sed 's/^/  | /' "$cout"

    # Then the capture.
    for i in $(seq $((SHOT_TIMEOUT * 2))); do
        [ -s "$shot" ] && break
        kill -0 "$jnext_pid" 2>/dev/null || break
        sleep 0.5
    done
    stop_all

    if [ ! -s "$shot" ]; then
        fail "$name no screenshot was written ($shot), so the screen could not be read"
        return
    fi

    # THE ORDERING, checked rather than assumed. Nothing can make jnext's
    # frame-scheduled capture wait for a TCP client, so a screenshot taken
    # before the state was set would show the previous line and be reported as
    # the wrong text. That is a check failing outside its own subject, which
    # this project treats as a defect in the check.
    local shot_at
    shot_at=$(stat -c %Y "$shot")
    if [ "$(printf '%.0f' "$done_at")" -gt "$shot_at" ]; then
        fail "$name the capture ($shot_at) came BEFORE the client's state ($done_at): the bench, not the stub — raise SHOT_FRAMES"
        return
    fi

    # THE READER IS VALIDATED FIRST, in this same image. Row 12 is drawn by the
    # same code in the same font and its text is not in question, so if it does
    # not come back the fault is the reader, the font or the geometry — and
    # saying so is not the same as saying the session line is wrong.
    local control
    control=$(read_row "$shot" "$CONTROL_ROW" || true)
    if [ "$control" != "$CONTROL_TEXT" ]; then
        fail "$name the reader failed: row $CONTROL_ROW should read '$CONTROL_TEXT', reads '$control' — session line NOT judged"
        return
    fi

    local got
    got=$(read_row "$shot" "$CLIENT_ROW" || true)
    if [ "$got" != "$expected" ]; then
        fail "$name row $CLIENT_ROW reads '$got', expected '$expected' (see $shot)"
        return
    fi

    # THE PRECONDITION THAT SAYS WHICH PATH DREW THE ROW, for N5 only. Its
    # client vanishes with the stub back in main_loop, where a scan that finds
    # no header is not an error and drain_main is never reached — so a clean
    # error area is what distinguishes this run from N4's, whose repaint comes
    # from drain_main's show_ui and which therefore carries "RX Timeout". Read
    # after the row so that a wrong line is still reported as a wrong line.
    if [ -n "$clean" ]; then
        local red
        red=$(bright_red "$shot")
        if [ "$red" -gt 0 ]; then
            fail "$name the stub reported an error ($red bright-red pixels), so this run went through drain_main"
            return
        fi
        pass "$name row $CLIENT_ROW reads '$got', error area clean"
        return
    fi
    pass "$name row $CLIENT_ROW reads '$got'"
}

one_run N1 silent "No debug session yet." \
    "a client connects over TCP and says nothing — a socket is not a session"
one_run N2 init "Session opened - CMD_INIT" \
    "a client sends CMD_INIT"
one_run N3 close "Session closed - CMD_CLOSE" \
    "the same client then sends CMD_CLOSE"
one_run N4 vanish "Session lost - client gone" \
    "a client vanishes without CMD_CLOSE, from inside cmd_loop"
one_run N5 vanish-idle "Session lost - client gone" \
    "the same, with the stub back in its idle loop" clean

# ===========================================================================
# N6 — the redraw must not write into a bank a client has paged in
#
# THE ONLY CHECK HERE JUDGED OVER THE SOCKET RATHER THAN OFF THE SCREEN, and it
# is about memory rather than about text. N5's repaint happens autonomously,
# triggered by the network, from main_loop's poll — and it writes at 0x4000.
# 0x4000 is the display file only while the debugger's own MMU slot 2 is mapped
# there, and `CMD_SET_SLOT 2,<bank>` is an ordinary DZRP command that retargets
# it (commands.asm's cmd_set_slot writes the MMU register directly for every
# slot but 7). A redraw that went ahead anyway would XOR the session line into
# that bank permanently: nothing backs up a bank, only slot_backup.slot0 and
# .slot7, and the debuggee gets it back corrupted.
#
# So this is N5 with one command in between: CMD_INIT, CMD_SET_SLOT 2,<bank>, a
# 32-byte probe parked where the row's first scanline lands, vanish, and read the
# probe back over a fresh connection.
#
# ITS THIRD OUTCOME IS A PRECONDITION AND NOT A VERDICT, which is what stops it
# passing or failing for the wrong reason. An all-zero read means show_ui's
# MEMCLEAR reached that bank, i.e. the run went through drain_main and never
# stood in the state being tested — reported as a precondition failure.
#
# TWO CORRECTIONS TO THAT, both made while fixing issue #28 and neither changing
# what this check does. The probe does NOT "contain no zero byte", which this
# comment used to say: eight of its 2048 bytes are 0x00, which is why a red here
# reports 2040 changed. What the outcome test needs is only that the probe is
# not ALL zeros, which holds. And WIPED cannot actually fire — any run that
# reaches show_ui also draws glyphs into character rows 8-15, i.e. into exactly
# 0x4800-0x4FFF — so this arm would report CORRUPT instead.
# See test/dzrp/session-client.py.
# ===========================================================================
slot_run() {
    local name=$1 why=$2
    CHECKS=$((CHECKS + 1))
    local jlog=$OUT/client-status-$name.log
    local shot=$OUT/screenshots/client-status-$name.png
    local cout=$OUT/client-status-$name.client.txt

    log ""
    log "== $name: $why"

    if ! start_stub "$jlog" "$shot"; then
        fail "$name the stub never listened on 127.0.0.1:$PORT (see $jlog)"
        stop_all
        return
    fi

    : >"$cout"
    HOLD=5 DZRP_PORT="$PORT" python3 "$CLIENT" vanish-slot >"$cout" 2>&1 &
    client_pid=$!

    local i verdict=""
    for i in $(seq 240); do
        verdict=$(awk '/^SLOT_PROBE /{print $2; exit}' "$cout" 2>/dev/null || true)
        [ -n "$verdict" ] && break
        kill -0 "$client_pid" 2>/dev/null || break
        sleep 0.25
    done
    sed 's/^/  | /' "$cout"
    stop_all

    case "$verdict" in
        OK)
            pass "$name a client's bank survived the redraw: slot 2 bank untouched across 2 KB" ;;
        CORRUPT)
            fail "$name the stub wrote the session line into the client bank paged in at slot 2" ;;
        WIPED)
            fail "$name PRECONDITION: show_ui cleared the bank, so this run never reached the redraw" ;;
        *)
            fail "$name the client reached no verdict — see $cout and $jlog" ;;
    esac
}

slot_run N6 "a client retargets MMU slot 2, then vanishes"


# N7 — the redraw must give MMU slot 1 back
#
# THE INVARIANT ISSUE #31 INTRODUCED, and the only check that covers it. The
# glyphs used to be copied into MAIN_BANK, which made printing immune to the MMU
# entirely; they are now read from the ROM, so text.font_map pages ROM into slot
# 1 for the duration of a paint and font_unmap puts back what was there.
#
# Slot 1 has NO BACKUP ANYWHERE — slot_backup holds slots 0 and 7 only — so the
# MMU register is itself the debuggee's storage for it. A paint that forgot the
# restore would report the wrong bank to DeZog AND hand the wrong bank to the
# debuggee on its next CMD_CONTINUE, silently. That is issue #26 one slot along.
#
# Judged over the socket, not off the screen: cmd_get_registers reads slots 0-6
# live out of the MMU, so the clobber is directly readable. The painter under
# test is the AUTONOMOUS one, esp_refresh_client_line — show_ui is reached from
# cmd_init, which resets slot 1 itself and would mask the answer.
#
# Shown red first by deleting the font_unmap call from esp_refresh_client_line:
# slot 1 came back 255, ROM_BANK, which is exactly what font_map leaves.
# ===========================================================================
slot1_run() {
    local name=$1 why=$2
    CHECKS=$((CHECKS + 1))
    local jlog=$OUT/client-status-$name.log
    local shot=$OUT/screenshots/client-status-$name.png
    local cout=$OUT/client-status-$name.client.txt

    log ""
    log "== $name: $why"

    if ! start_stub "$jlog" "$shot"; then
        fail "$name the stub never listened on 127.0.0.1:$PORT (see $jlog)"
        stop_all
        return
    fi

    : >"$cout"
    HOLD=5 DZRP_PORT="$PORT" python3 "$CLIENT" vanish-slot1 >"$cout" 2>&1 &
    client_pid=$!

    local i verdict=""
    for i in $(seq 240); do
        verdict=$(awk '/^SLOT1 /{print $2; exit}' "$cout" 2>/dev/null || true)
        [ -n "$verdict" ] && break
        kill -0 "$client_pid" 2>/dev/null || break
        sleep 0.25
    done
    sed 's/^/  | /' "$cout"
    stop_all

    case "$verdict" in
        OK)         pass "$name the redraw gave MMU slot 1 back to the client unchanged" ;;
        CLOBBERED)  fail "$name the redraw left ROM in MMU slot 1: the debuggee's bank is lost" ;;
        *)          fail "$name the client reached no verdict — see $cout and $jlog" ;;
    esac
}

slot1_run N7 "a client retargets MMU slot 1, then vanishes"


# ===========================================================================
# N8 — show_ui itself must not draw through a retargeted slot 2
#
# ISSUE #28, AND THE BIG ONE. N6 covers the autonomous painter, which writes one
# row; this covers show_ui, which opens with `MEMCLEAR SCREEN, SCREEN_SIZE` and
# then fills 1248 more bytes of attributes before printing anything. Through a
# slot 2 a client has retargeted with CMD_SET_SLOT that is 0x4000-0x5CDF, 7392
# bytes, of the client's own bank destroyed, permanently — nothing backs a bank
# up, only slot_backup.slot0 and .slot7 — and the debuggee gets it back that
# way. (Issue #28 says 8 KB; that is the size of the SLOT, not of the write.)
#
# THE TRIGGER IS CMD_CLOSE, NOT THE "B" KEY that issue #28 names. It is the same
# routine: `check_key_border` jumps to main_redraw and cmd_close reaches it
# through `jp main`, with show_ui below both. What CMD_CLOSE buys is that there
# is NO MARGIN anywhere in the check — the client orders its own commands over
# the socket, where an injected keypress is scheduled in emulated frames against
# a client counting wall clock, which is the mismatch W6 was caught by and which
# N5's IDLE_WAIT is documented as still carrying.
#
# IT ALSO WIDENS THE DEFECT, honestly: #28 says it needs "someone pressing B at
# the machine", and CMD_CLOSE is what DeZog sends on every Shift+F5. No human is
# involved. What this check therefore does NOT cover is `check_key_border`'s own
# `jp z,main_redraw` — nothing here presses a key, and a regression that stopped
# the "B" key reaching main_redraw would pass.
#
# THE PRECONDITION IS THE ORDERING PROOF `close` ALREADY USES: cmd_close answers
# before it reaches show_ui, so a reply to a FURTHER command is what says the
# repaint happened. Reported as UNRUN, distinct from a verdict, because a run
# that never redrew has tested nothing.
#
# AND THE SLOT IS READ BACK BEFORE THE BANK, so "the window was left forced" and
# "the bank was written through" are two verdicts and not one. See
# test/dzrp/session-client.py.
# ===========================================================================
close_slot_run() {
    local name=$1 why=$2
    CHECKS=$((CHECKS + 1))
    local jlog=$OUT/client-status-$name.log
    local shot=$OUT/screenshots/client-status-$name.png
    local cout=$OUT/client-status-$name.client.txt

    log ""
    log "== $name: $why"

    if ! start_stub "$jlog" "$shot"; then
        fail "$name the stub never listened on 127.0.0.1:$PORT (see $jlog)"
        stop_all
        return
    fi

    : >"$cout"
    HOLD=5 DZRP_PORT="$PORT" python3 "$CLIENT" close-slot >"$cout" 2>&1 &
    client_pid=$!

    local i verdict=""
    for i in $(seq 240); do
        verdict=$(awk '/^SHOW_UI /{print $2; exit}' "$cout" 2>/dev/null || true)
        [ -n "$verdict" ] && break
        kill -0 "$client_pid" 2>/dev/null || break
        sleep 0.25
    done
    sed 's/^/  | /' "$cout"
    stop_all

    case "$verdict" in
        OK)
            pass "$name show_ui redrew without touching the bank a client had paged into slot 2" ;;
        CORRUPT)
            fail "$name show_ui cleared and redrew through the client's bank at slot 2" ;;
        LEAKED)
            fail "$name show_ui left its own screen bank in slot 2 instead of the client's" ;;
        UNRUN)
            fail "$name PRECONDITION: nothing was answered after CMD_CLOSE, so show_ui never ran" ;;
        *)
            fail "$name the client reached no verdict — see $cout and $jlog" ;;
    esac
}

close_slot_run N8 "a client retargets MMU slot 2, then sends CMD_CLOSE"

log ""
if [ "$failures" -ne 0 ]; then
    log "Diagnosis:"
    log "  jnext logs:  $OUT/client-status-N*.log"
    log "  screenshots: $OUT/screenshots/client-status-N*.png"
    log "  read any row of one with:"
    log "    python3 $SCREENTEXT --font $font $OUT/screenshots/client-status-N2.png 8"
fi
log "$(( CHECKS - failures )) of $CHECKS checks passed"

exit "$((failures > 0 ? 1 : 0))"
