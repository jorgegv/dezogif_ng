#!/usr/bin/env bash
#
# ASYNCHRONOUS BREAK OVER THE SERIAL CABLE — issue #43.
#
# Invoked by `make test-uart-break`. Three headless jnext runs with the UART
# ROM installed as the Multiface ROM and a recorded DZRP command stream on the
# joystick-port UART RX pin (`--joy-uart-rx`, jnext#251).
#
# WHY THIS EXISTS. `TRANSPORT_DEACTIVATE` is the one line asynchronous break in
# UART mode turns on, and until this bench it was reached by NO headless run at
# all: it runs only from `restore_registers`, reached only from `cmd_continue`,
# which needs a DZRP client on the serial transport — and nothing anywhere had
# ever been one, in jnext or on hardware. So the feature shipped carried by
# inspection and by the unchanged benches not regressing, which is a weaker
# position than anything else in this repository (issue #43, and §8.0 of
# doc/ASYNCHRONOUS-BREAK-DESIGN.md, whose evidence ladder this fills in).
#
# THERE IS NO CLIENT, AND THAT SHAPES EVERYTHING. A cable in jnext is a one-way
# byte stream from a file; the guest's replies leave through joystick pin 7 and
# reach nothing on the host. So the commands are PRE-RECORDED and the answers
# are read afterwards out of jnext's own UART TX log, which records every byte
# the guest transmits (`uart.cpp:743`, at `debug`). The stream is self-framing
# because UART mode prefixes every reply with MESSAGE_START_BYTE — upstream's
# documented serial extension, not a defect (doc/legacy/Design.md:30-31).
#
# WHAT IT COVERS:
#
#   run 1  the subject — cable in joystick socket 2, the stub's own default
#          port selection (`ld a,2`, src/main.asm:89, which is upstream's).
#     J1   A FREELY RUNNING DEBUGGEE IS STOPPED OVER THE CABLE. It carries the
#          Copper list itself, is resumed with NO temporary breakpoint — so
#          nothing the debugger planted can bring it back — and comes back with
#          MANUAL_BREAK, PC at its spin and SP its own. dezogif's headline
#          limitation, lifted on the transport dezogif actually shipped.
#     J3   AND THE CABLE'S RX WAS STILL ROUTED WHILE IT RAN: the debuggee's own
#          first instruction after the resume reads NR 0x0B and stores it, and
#          it reads 0xB1 — io mode on, socket 2, UART1. That is what
#          TRANSPORT_DEACTIVATE left, sampled by the debugged program.
#     J5   and the stub's screen says so, on the row the HOWTO sends a user to.
#
#   run 4  a debuggee that installs NOTHING — the same fixture minus its 44
#          bytes of Copper setup: `di`, the witness read, `jr $`.
#     J6   THE DEBUGGER'S OWN COPPER LIST BREAKS IT IN, over the cable. Since
#          2026-08-15 cmd_init installs a list on a first attach, in common code
#          with no ROM_VARIANT guard, so the serial build gets it too and the
#          joy-port default of 2 means the serial ROM ships with PC-initiated
#          break ON. J1 CANNOT SEE THAT — its fixture arms the Copper itself and
#          is green either way — which is exactly W10's argument on this
#          transport. Needs its own run for W10's reason too: the Copper outlives
#          the program that wrote the list, so sharing a machine with run 1 would
#          break in off run 1's list and pass for the wrong reason.
#
#   run 2  the control — identical, stream truncated after CMD_CONTINUE.
#     J2   NOTHING may come back. Without it a green J1 is not evidence that the
#          CABLE caused the break rather than the debuggee stopping by itself,
#          never having run, or the stub breaking in on something of its own.
#          W3's argument for C10, and W8's for its own pause.
#
#   run 3  the port-1 control — cable in socket 1, "1" pressed on the stub's
#          screen so `uart_joyport_selection` is 1.
#     J4   THE OTHER ARM OF THE SAME MACRO, REPRODUCED FROM SHIPPED BYTES WITH
#          NO PROBE ROM: on any selection but 2 the macro still clears NR 0x0B,
#          which is exactly what it did unconditionally before the fix, and the
#          debuggee duly witnesses 0x00. It is also state 1 of the HOWTO's seven
#          — "a serial build with the cable on joy port 1" — so one run covers
#          the regression control and the documented limitation together.
#     J5   the other half of the screen row.
#
# WHY THE BREAK ITSELF CANNOT BE THE DISCRIMINATOR, WHICH WAS MEASURED RATHER
# THAN REASONED. The RX FIFO is 512 bytes and NOTHING drains it on the resume
# path (`backup.asm:58-62` is transport_flush, then the macro, and no drain), so
# bytes that arrived while the debugger was still stopped are still there when
# the debuggee starts running and the first poll finds them. The recorded stream
# is ~190 bytes — ~2 ms of wire at 921600 — against the several milliseconds
# `cmd_init` spends in `show_ui`, so all of it is buffered before CMD_CONTINUE
# is even read. Measured: run 3 breaks in and answers every command exactly as
# run 1 does, byte for byte, with its cable's RX severed. A check that judged
# the break would therefore be GREEN on the pre-fix behaviour.
#
# So J1 and J4 are two different claims, and neither is the other. J1 is that
# the poll -> break -> notify path works with a running debuggee on this
# transport. J4 (with J3) is that the RX source survives the resume, or does
# not. Together they are the feature; separately neither would be.
#
# WHAT IT SAYS ABOUT HARDWARE: NOTHING. jnext's mux is jnext's reading of
# zxnext.vhd:3536-3539, and whether joystick socket 1 can receive AT ALL is DB9
# wiring the VHDL cannot settle — upstream's own comment in `transport_activate`
# says "RX = PIN 9 Joystick 2". If that is right, run 3's delivery is an
# emulator artefact and port 1 has never received on silicon, upstream included.
# It does not weaken J4, whose subject is the NR 0x0B the debuggee witnessed
# rather than anything arriving.
#
# Environment (all set by the Makefile, all overridable):
#   JNEXT      path to the jnext binary
#   SD_IMAGE   reference SD card image; NEVER written, only copied
#   OUT        build directory
#   ROM        our UART-mode enNextMf.rom

set -euo pipefail

# ---------------------------------------------------------------------------
# SERIALISE BENCH RUNS ACROSS PROCESSES. This bench binds no port and needs no
# client, so it cannot be answered by somebody else's stub the way the DZRP ones
# can — but it does start an emulator, and several at once on this machine slow
# every one of them enough to move the frame margins below. The lock is the same
# advisory one every other bench takes, so cooperating benches serialise without
# any of them knowing about the others.
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
ROM=${ROM:-$OUT/enNextMf.rom}

# NextZXOS needs ~900 frames to reach the welcome screen; the button is pressed
# there, exactly as run-headless.sh's T6 and run-dzrp-stub.sh do.
BOOT_FRAMES=${BOOT_FRAMES:-900}

# "1" on the stub's own screen, retargeting uart_joyport_selection — 200 frames
# after the stub came up, which is run-headless.sh's NORESET_JOY_FRAME and is
# measured there to be well past the ~50 frames the key poll needs.
JOY_KEY_FRAME=${JOY_KEY_FRAME:-1100}

# When the recorded stream starts. AFTER the key press, or run 3 would be fed
# through a mux the key is about to change; and after the stub is up, or the
# bytes are spent before anything can read them.
#
# Overridable so that the preconditions below have a re-runnable red rather
# than being a story about a scratch tree — the seam the IP_MAX / RX_WAIT /
# LINK_IDS family already uses. `STREAM_FRAME=100 make test-uart-break` puts the
# whole stream on the wire before the stub exists, and every run must then fail
# its "the stream was delivered" precondition instead of rendering a verdict.
STREAM_FRAME=${STREAM_FRAME:-1200}

# The screenshot, and then the end of the run. The stream is ~2 ms of wire and
# the break lands on the next Copper fire, so everything of interest is over
# within a handful of frames of STREAM_FRAME; the rest is the control's window.
SHOT_FRAMES=${SHOT_FRAMES:-1560}
EXIT_FRAMES=${EXIT_FRAMES:-1600}

# Wall-clock backstop only; the runs end on EXIT_FRAMES.
RUN_TIMEOUT=600

# Shared jnext teardown — issue #17. Defines functions and nothing else, so it
# cannot disturb the `set -euo pipefail` above or the traps below.
# shellcheck source=test/bench-jnext.sh
. "$(dirname "$0")/bench-jnext.sh"

MF_ROM_PATH='::/machines/next/enNextMf.rom'
FONT_ROM_PATH='::/machines/next/48.rom'
CABLE=$(dirname "$0")/dzrp/uart-cable.py
SCREENTEXT=$(dirname "$0")/screen-text.py

# The row the HOWTO sends a confused user to, and the row that validates the
# reader. Row 12 is "R = Reset", drawn by the same code with the same font and
# not in question, so a run whose reader is broken says so instead of reporting
# a wrong line — run-client-status.sh's rule, and mfselect's M9 lesson: read the
# row, do not merely diff two of them.
BREAK_ROW=7
CONTROL_ROW=12
CONTROL_TEXT="R = Reset"
READY_TEXT="PC break: ready"
NEEDS_TEXT="PC break: needs Joy 2"

log()  { printf '%s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# --- pre-flight ------------------------------------------------------------

[ -x "$JNEXT" ]     || die "jnext binary not found or not executable: $JNEXT"
[ -f "$SD_IMAGE" ]  || die "SD card image not found: $SD_IMAGE"
[ -f "$ROM" ]       || die "UART ROM not built: $ROM (run 'make mf-rom')"
[ -f "$CABLE" ]     || die "cable fixture not found: $CABLE"
[ -f "$SCREENTEXT" ]|| die "screen reader not found: $SCREENTEXT"
command -v mcopy >/dev/null || die "mtools (mcopy) is required to install the ROM into the SD image"
python3 -c 'import PIL' 2>/dev/null || die "python3 Pillow is required for J5's screen check"

bench_jnext_supports "$JNEXT" '--joy-uart-rx' \
    || die "this jnext cannot attach a serial source to the joystick port (need >= 0.99.155, jnext#251); rebuild it"
bench_jnext_supports "$JNEXT" '--joy-uart-connector' \
    || die "this jnext has no --joy-uart-connector (need >= 0.99.155); rebuild it"
bench_jnext_supports "$JNEXT" '--delayed-nmi' \
    || die "this jnext has no --delayed-nmi (need >= 0.99.118); rebuild it"

# The ROM must really be the UART one. Installing the WiFi build here would boot,
# take the NMI, paint a screen that mentions no joystick port at all, and never
# read a byte off the cable — and the failure would look like a transport bug
# rather than the wrong file. The magic string at the fixed offset is exactly
# what issue #4 put there to answer this question.
variant=$(dd if="$ROM" bs=1 skip=8160 count=19 2>/dev/null | tr -d '\0')
[ "${variant#DeZoGiFnG_UART_}" != "$variant" ] \
    || die "$ROM does not identify itself as a UART build (magic: '$variant')"

part_lba=$(od -An -tu4 -j 454 -N 4 "$SD_IMAGE" | tr -d ' ')
[ -n "$part_lba" ] && [ "$part_lba" -gt 0 ] || die "cannot read partition table from $SD_IMAGE"
part_off=$((part_lba * 512))

mkdir -p "$OUT" "$OUT/screenshots"

# --- the runs --------------------------------------------------------------
#
# The reference image is never written. The working copy is reflinked where the
# filesystem supports it and DELETED on the way out either way: --reflink=auto
# falls back to a real copy silently, and abandoned gigabyte copies from bench
# runs are what filled a scratch filesystem and took a session's shell down on
# 2026-08-04.
#
# The trap is armed BEFORE the copy, because the copy is the slowest thing here
# and therefore the likeliest moment to be interrupted; jnext_pid is declared
# empty first so `set -u` cannot abort the handler before it reaches the rm.

sd=$OUT/sd-uart-break.img
font=$OUT/font-48-uart-break.rom
stream=$OUT/uart-break-stream.bin
stream_ctl=$OUT/uart-break-stream-control.bin
stream_nc=$OUT/uart-break-stream-nocopper.bin

jnext_pid=""
cleanup() {
    if [ -n "$jnext_pid" ] && kill -0 "$jnext_pid" 2>/dev/null; then
        kill "$jnext_pid" 2>/dev/null || true
        wait "$jnext_pid" 2>/dev/null || true
    fi
    # Unlinked BEFORE departure is confirmed, deliberately: bench_await_departure
    # can exit, and an exit that skipped this would reintroduce the
    # abandoned-gigabyte leak ERRORS.md records.
    rm -f "$sd"
    bench_await_departure "$sd"
}
trap cleanup EXIT
# A handler that only RETURNS does not stop a bash script — the shell defers the
# signal, runs the handler and carries on. These exit, and the EXIT trap cleans.
trap 'exit 130' INT
trap 'exit 143' TERM

cp --reflink=auto -f "$SD_IMAGE" "$sd"
mcopy -o -i "$sd@@$part_off" "$ROM" "$MF_ROM_PATH"
mcopy -o -i "$sd@@$part_off" "$FONT_ROM_PATH" "$font" \
    || die "cannot read $FONT_ROM_PATH out of the SD image"

log "== building the recorded command streams"
python3 "$CABLE" build "$stream"           | sed 's/^/  | /'
python3 "$CABLE" build "$stream_ctl" --control | sed 's/^/  | /'
nc_build=$(J6_NO_COPPER=1 python3 "$CABLE" build "$stream_nc")
printf '%s\n' "$nc_build" | sed 's/^/  | /'

failures=0
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; failures=$((failures + 1)); }

# run_stub <tag> <connector> <stream> [joy key] — one emulator run.
run_stub() {
    local tag=$1 connector=$2 src=$3 key=${4:-}
    local logfile=$OUT/uart-break-$tag.log
    local shotfile=$OUT/screenshots/uart-break-$tag.png
    local -a extra=()
    [ -n "$key" ] && extra=(--delayed-keypress-frames "$JOY_KEY_FRAME" "$key")
    rm -f "$shotfile"

    timeout "$RUN_TIMEOUT" "$JNEXT" \
        --headless --machine next \
        --sdcard "$sd" \
        --rtc "2026-01-01 12:00:00" \
        --log-level warn,uart=debug \
        --joy-uart-rx "$src" \
        --joy-uart-rx-delay-frames "$STREAM_FRAME" \
        --joy-uart-connector "$connector" \
        --delayed-nmi-frames "$BOOT_FRAMES" nmi \
        "${extra[@]}" \
        --delayed-screenshot "$shotfile" --delayed-screenshot-frames "$SHOT_FRAMES" \
        --delayed-automatic-exit-frames "$EXIT_FRAMES" \
        >"$logfile" 2>&1 &
    jnext_pid=$!
    wait "$jnext_pid" 2>/dev/null || true
    jnext_pid=""
    bench_await_departure "$sd"
}

# stream_delivered <log> — did the cable actually reach the guest?
#
# ASSERTED, NOT ASSUMED, AND IT IS THE ONE PRECONDITION EVERY VERDICT HERE
# RESTS ON. jnext emits a one-shot warning when a source runs to its end having
# delivered nothing, naming the NR 0x0B it saw (`emulator.cpp:7591-7599`) — so a
# run whose mux was never what this bench assumed reports that rather than a
# silent pass over a path no byte took. The attach line is required too: a
# typo'd path, or a jnext that read the file and refused it, would otherwise
# look exactly like a stub that said nothing.
stream_delivered() {
    grep -q "joystick serial source attached" "$1" || return 1
    ! grep -q "byte(s) LOST" "$1"
}

read_row() {
    python3 "$SCREENTEXT" --font "$font" "$1" "$2" 2>/dev/null
}

# ===========================================================================
# Run 1 — the subject: the cable in socket 2, the stub's own default selection.
# ===========================================================================

log ""
log "== run 1: a freely running debuggee, stopped by bytes on the cable (joy port 2)"

subj_log=$OUT/uart-break-joy2.log
subj_shot=$OUT/screenshots/uart-break-joy2.png
run_stub joy2 2 "$stream"

subj_ok=0
subj_witness_ok=0
if ! stream_delivered "$subj_log"; then
    fail "J1 the cable delivered nothing: $(grep -o 'Current NR 0x0B = .*' "$subj_log" | head -1)"
    fail "J3 no witness: the cable delivered nothing to the guest"
else
    set +e
    subj_out=$(python3 "$CABLE" verdict "$subj_log" --label joy2 --expect-nr0b 0xB1 2>&1)
    subj_rc=$?
    set -e
    printf '%s\n' "$subj_out" | sed 's/^/  | /'

    # TWO SUBJECTS, TWO VERDICTS. The setup preconditions — the fixture landed,
    # CMD_CONTINUE was answered — gate both; past them each is reported on its
    # own line, because they fail for different reasons. A run whose debuggee
    # never started its Copper list makes J1 BAD and J3 a precondition, and an
    # earlier version reported the first of those as the second.
    if [ "$subj_rc" -ne 0 ]; then
        why=$(printf '%s' "$subj_out" | sed -n 's/^PRECONDITION joy2 //p' | head -1)
        fail "J1 precondition: $why"
        fail "J3 precondition: $why"
    else
        if [ "$(printf '%s' "$subj_out" | grep -c '^RESULT joy2 break OK')" -eq 1 ]; then
            subj_ok=1
            pass "J1 bytes on the joy-port cable stopped a freely running debuggee"
        else
            fail "J1 $(printf '%s' "$subj_out" | sed -n 's/^RESULT joy2 break BAD //p' | head -1)"
        fi
        if [ "$(printf '%s' "$subj_out" | grep -c '^RESULT joy2 witness OK')" -eq 1 ]; then
            subj_witness_ok=1
            pass "J3 the debuggee ran with the cable's RX still routed (NR 0x0B = 0xB1)"
        else
            fail "J3 $(printf '%s' "$subj_out" | sed -n 's/^RESULT joy2 witness \(BAD\|PRECONDITION\) //p' | head -1)"
        fi
    fi
fi

# ===========================================================================
# Run 2 — the control: the same, with everything after CMD_CONTINUE withheld.
#
# NOT OPTIONAL, for W3's reason exactly. A notification arriving after a resume
# is not evidence that the CABLE caused it: the debuggee could have stopped by
# itself, could never have run, or the stub could be breaking in on something of
# its own — a stray RST 0, a button, an NMI cause nobody asked for. The control
# removes the bytes and nothing may come back.
#
# It also runs the debuggee free for ~400 frames past the resume, so "it kept
# running" is a claim about eight emulated seconds and ~400 Copper polls rather
# than about a millisecond.
# ===========================================================================

log ""
log "== run 2: the same, with nothing sent after CMD_CONTINUE (control)"

ctl_log=$OUT/uart-break-control.log
run_stub control 2 "$stream_ctl"

if ! stream_delivered "$ctl_log"; then
    fail "J2 control: the cable delivered nothing, so nothing was resumed"
else
    set +e
    ctl_out=$(python3 "$CABLE" verdict "$ctl_log" --label control --control 2>&1)
    ctl_rc=$?
    set -e
    printf '%s\n' "$ctl_out" | sed 's/^/  | /'
    if [ "$ctl_rc" -ne 0 ]; then
        fail "J2 precondition: $(printf '%s' "$ctl_out" | sed -n 's/^PRECONDITION control //p' | head -1)"
    elif [ "$(printf '%s' "$ctl_out" | grep -c '^RESULT control OK')" -eq 1 ]; then
        pass "J2 control: nothing came back with nothing sent after the resume"
    else
        fail "J2 control: $(printf '%s' "$ctl_out" | sed -n 's/^RESULT control BAD //p' | head -1)"
    fi
fi

# ===========================================================================
# Run 3 — the port-1 control: TRANSPORT_DEACTIVATE's other arm.
#
# THE PRE-FIX BEHAVIOUR, REPRODUCED FROM SHIPPED BYTES AND WITH NO PROBE ROM.
# The macro clears NR 0x0B on every selection but 2, which is what it did
# unconditionally before the fix — so this run executes the same instruction the
# old code did and the debuggee witnesses the same 0x00. It is simultaneously
# state 1 of the HOWTO's seven ("a serial build with the cable on joy port 1"),
# which is the thing a user is most likely to meet.
# ===========================================================================

log ""
log "== run 3: the cable in socket 1 with the port-1 selection (control)"

p1_log=$OUT/uart-break-joy1.log
p1_shot=$OUT/screenshots/uart-break-joy1.png
run_stub joy1 1 "$stream" 1

p1_witness_ok=0
if ! stream_delivered "$p1_log"; then
    fail "J4 the cable delivered nothing: $(grep -o 'Current NR 0x0B = .*' "$p1_log" | head -1)"
else
    set +e
    p1_out=$(python3 "$CABLE" verdict "$p1_log" --label joy1 --expect-nr0b 0x00 2>&1)
    p1_rc=$?
    set -e
    printf '%s\n' "$p1_out" | sed 's/^/  | /'
    if [ "$p1_rc" -ne 0 ]; then
        fail "J4 precondition: $(printf '%s' "$p1_out" | sed -n 's/^PRECONDITION joy1 //p' | head -1)"
    elif [ "$(printf '%s' "$p1_out" | grep -c '^RESULT joy1 witness OK')" -eq 1 ]; then
        p1_witness_ok=1
        pass "J4 on joy port 1 the same macro clears NR 0x0B, as it did before the fix"
    else
        fail "J4 $(printf '%s' "$p1_out" | sed -n 's/^RESULT joy1 witness \(BAD\|PRECONDITION\) //p' | head -1)"
    fi
fi

# ===========================================================================
# Run 4 — J6: A DEBUGGEE THAT INSTALLS NOTHING, BROKEN IN OVER THE CABLE.
#
# THE SERIAL BUILD GETS THE DEBUGGER'S OWN COPPER LIST TOO, AND NOTHING HERE
# EXERCISED THAT. `cmd_init`'s call to copper_break_arm is common code with no
# ROM_VARIANT guard anywhere near it, so the install-at-first-attach behaviour
# is identical in both builds — but run 1's fixture arms the Copper ITSELF, as
# a Copper-using program does, so J1 is green whether the debugger armed one or
# not and cannot see the feature at all. This is W10's argument on the serial
# transport, and it matters more here than there: the joy-port default is 2, so
# the serial ROM ships with PC-initiated break ON, and this is the build a user
# with a cable actually runs.
#
# The fixture is THE SAME ONE minus its 44 bytes of Copper setup — `di`, the
# witness read, `jr $` — so the only thing that can raise a Multiface NMI 50
# times a second is the list cmd_init armed. Its shape is asserted from the
# build line rather than from J6_NO_COPPER having been exported, for the reason
# that line prints it.
#
# IT NEEDS ITS OWN RUN for W10's reason: the Copper outlives the program that
# wrote the list, which is the whole premise, so sharing a machine with run 1
# would break in off run 1's fixture's list and pass for the wrong reason.
#
# The witness is asserted too, and costs nothing extra: the read is the
# fixture's first instruction in both shapes, so NR 0x0B must still be 0xB1.
# That is J3's subject re-observed on a debuggee that installed nothing, which
# is worth having free rather than worth a sixth id.
#
# SHOWN RED THE DECISIVE WAY: against main's UART ROM — which contains no
# copper_break_arm at all — J6 reports "no notification: the running debuggee
# was never stopped" WITH J1 GREEN IN THE SAME RUN. That pairing is the whole
# evidence, and it is #44's J1-green/J3-red shape: J1 passes there because its
# own fixture arms the Copper, which is precisely why J1 cannot be the check for
# this. Reproduce it with
#
#   ROM=<a main-built enNextMf.rom> ./test/run-uart-break.sh
#
# INVOKED DIRECTLY AND NOT THROUGH make, because the recipe passes ROM=
# explicitly and silently overrides the environment — through make, the control
# runs the branch's own ROM and comes out GREEN. That is recorded in
# MEMORY.md for W5, it bit again here, and it is now in ERRORS.md.
# ===========================================================================

log ""
log "== run 4: a debuggee that installs no Copper list, stopped over the cable"

nc_log=$OUT/uart-break-nocopper.log
nc_shot=$OUT/screenshots/uart-break-nocopper.png
run_stub nocopper 2 "$stream_nc"

if [ "$(printf '%s' "$nc_build" | grep -c 'copper=no')" -ne 1 ]; then
    fail "J6 precondition: the stream was not built with the bare fixture, so it may have armed the Copper itself"
elif ! stream_delivered "$nc_log"; then
    fail "J6 the cable delivered nothing: $(grep -o 'Current NR 0x0B = .*' "$nc_log" | head -1)"
else
    set +e
    nc_out=$(J6_NO_COPPER=1 python3 "$CABLE" verdict "$nc_log" --label nocopper --expect-nr0b 0xB1 2>&1)
    nc_rc=$?
    set -e
    printf '%s\n' "$nc_out" | sed 's/^/  | /'
    if [ "$nc_rc" -ne 0 ]; then
        fail "J6 precondition: $(printf '%s' "$nc_out" | sed -n 's/^PRECONDITION nocopper //p' | head -1)"
    elif [ "$(printf '%s' "$nc_out" | grep -c '^RESULT nocopper break OK')" -eq 1 ]; then
        pass "J6 the debugger's own Copper list breaks a bare debuggee in over the cable"
    else
        fail "J6 $(printf '%s' "$nc_out" | sed -n 's/^RESULT nocopper break BAD //p' | head -1)"
    fi
fi

# ===========================================================================
# J5 — the screen row the HOWTO sends a user to, read as TEXT.
#
# READ, NOT DIFFED, and that is mfselect's M9 lesson: two runs differing in the
# right cells is satisfied by two labels SWAPPED, which is the obvious bug here
# — the two strings are adjacent lines of similar length on the same row. So
# each run is judged on what its own row SAYS, with the reader validated inside
# the same image first.
#
# It is the only check here whose subject is not TRANSPORT_DEACTIVATE, and it
# earns its run anyway: `show_ui`'s row 7 was added by the same change, is what
# doc/ASYNCHRONOUS-BREAK-USER-HOWTO.md tells a user to look at when Pause does
# nothing, and is covered by nothing else in this repository.
# ===========================================================================

log ""
log "== J5: the PC-break row on the stub's own screen"

j5_problems=()
for pair in "joy2:$subj_shot:$READY_TEXT" "joy1:$p1_shot:$NEEDS_TEXT"; do
    tag=${pair%%:*}; rest=${pair#*:}; shot=${rest%%:*}; want=${rest#*:}
    if [ ! -f "$shot" ]; then
        j5_problems+=("$tag had no screenshot")
        continue
    fi
    guard=$(read_row "$shot" "$CONTROL_ROW" || true)
    if [ "$guard" != "$CONTROL_TEXT" ]; then
        # A broken reader must report itself rather than be reported as a wrong
        # screen — run-client-status.sh's rule, and the reason row 12 is here.
        j5_problems+=("$tag reader broken: row $CONTROL_ROW read '$guard'")
        continue
    fi
    got=$(read_row "$shot" "$BREAK_ROW" || true)
    log "  | $tag row $BREAK_ROW reads: $got"
    # Both strings begin "PC break: ", so the shared prefix is dropped from the
    # verdict line: it is 3 words per row of nothing, and this line has to hold
    # two rows inside the ~20-word budget.
    [ "$got" = "$want" ] || j5_problems+=("$tag said '${got#PC break: }' not '${want#PC break: }'")
done

if [ ${#j5_problems[@]} -eq 0 ]; then
    pass "J5 the screen reads 'ready' on joy port 2 and 'needs Joy 2' on port 1"
else
    joined=$(printf '; %s' "${j5_problems[@]}"); fail "J5 ${joined:2}"
fi

# ---------------------------------------------------------------------------

rm -f "$stream" "$stream_ctl" "$stream_nc" "$font"

log ""
if [ "$failures" -eq 0 ]; then
    log "All 6 checks passed."
else
    log "$failures of 6 checks FAILED."
fi
# Referenced so `set -u` cannot turn an unused bookkeeping variable into a late
# abort if a future check reads them; they are the run-level summaries.
: "$subj_ok" "$subj_witness_ok" "$p1_witness_ok"
exit $([ "$failures" -eq 0 ] && echo 0 || echo 1)
