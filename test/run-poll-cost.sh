#!/usr/bin/env bash
#
# MEASURE WHAT THE ASYNCHRONOUS-BREAK POLL COSTS THE DEBUGGEE. Issue #22, M2.
#
# `make measure-poll-cost`. Four headless jnext runs and no verdict: this is an
# INSTRUMENT, like `make probe-slots`, not a gate. It prints MEAS rows and it is
# not part of `make test`.
#
# WHY IT EXISTS AS A COMMITTED THING AT ALL. The milestone's acceptance criteria
# name this measurement, and plan §10 and doc/ASYNCHRONOUS-BREAK-DESIGN.md §5
# both carry "~100-200 T-states/frame (≈0.3%)" as an estimate nobody had
# measured. It was first measured in a scratch tree on 2026-08-10 — which is
# this project's own "a red nobody can re-run" one organ along, and is why it
# lives here now.
#
# THE METHOD. test/copper_cost.asm spins in a fixed-length loop counting
# iterations in HL. Two builds differ in ONE assembler constant, COPPER_ON: with
# the list started the Multiface NMI fires every frame and the stub's poll runs;
# without it the machine is otherwise identical and no NMI is raised. HL is read
# out of a snapshot at two frame counts and the DIFFERENCE taken, so the
# fixture's own start-up and the snapshot's overhead cancel. The shortfall
# between the two builds is the poll.
#
# WHY A DIFFERENCE AND NOT A SINGLE READING: the fixture is injected at a fixed
# frame but starts with `ei : halt : di`, so it begins somewhere inside the
# following frame rather than at a frame boundary. Two readings and a subtraction
# make that irrelevant; one reading would fold it into the answer.
#
# IF YOU WIDEN THE WINDOW, READ THIS FIRST. HL is sixteen bits and the counter
# starts at zero when the fixture is injected, so a long enough window WRAPS —
# and a wrapped pair of readings is not obviously wrong, it is a plausible
# smaller number. Provoked deliberately: at LAST_FRAME=830 the count goes
# 11736 -> 51824, the second reading is still larger than the first, and the
# arithmetic yields `1484.9 iterations/frame` and a cost of 0.609% instead of the
# true ~3912 and 0.230%. Nothing about that output looks wrong.
#
# The first version of the guard tested only "did HL increase", which catches
# about 9 of the ~46 wrapping gap-widths and missed exactly this one. A bare
# ceiling on the readings does not help either — both of those numbers are far
# below any sane ceiling. TWO READINGS CANNOT DISTINGUISH A WRAP FROM A LARGE
# HONEST INCREASE, so the guard that matters is A PRIORI: it computes whether the
# window CAN wrap, from the clock and the loop's own nominal T-state count, and
# refuses before it looks at the numbers. Measured: 14 frames after injection is
# accepted at 28 MHz, 15 is refused, and the reviewer's 30 is refused loudly.
#
# THE CLOCK IS READ OFF THE MACHINE, not assumed. The poll runs at the DEBUGGEE's
# speed, so the same absolute cost is a very different fraction of a frame at
# 3.5 MHz than at 28 MHz. The fixture puts NR 0x07's read-back in D and this
# prints it. NOTE that REG_TURBO_MODE does not read back what was written: bits
# 5:4 are the ACTUAL speed and 1:0 the programmed one (zxnext.vhd:5903).
#
# WHAT IT CANNOT SAY. Nothing about real hardware — jnext counts the same
# T-states a Next does, which is what makes it entitled to this one, but no Next
# has run any of M2. And it measures the DECLINE path only: no client is
# attached, so every poll answers "quiet" and returns. A poll that breaks in
# costs the whole entry path, which is a different and much larger number that
# is paid once rather than per frame.
#
# Environment: JNEXT, SD_IMAGE, OUT, ROM, COST_BIN_ON, COST_BIN_OFF.

set -euo pipefail

JNEXT=${JNEXT:-$HOME/src/spectrum/jnext/build/gui-release/jnext}
SD_IMAGE=${SD_IMAGE:-$HOME/.jnext/sdcard/cspect-next-1gb-fixed.img}
OUT=${OUT:-build}
ROM=${ROM:-$OUT/enNextMf.rom}
COST_BIN_ON=${COST_BIN_ON:-$OUT/copper_cost_on.bin}
COST_BIN_OFF=${COST_BIN_OFF:-$OUT/copper_cost_off.bin}

# The fixture is injected once NextZXOS is up, exactly as run-headless.sh does.
INJECT_FRAME=800
# Two readings, nine frames apart. Short enough that HL cannot wrap (~4500
# iterations per frame at 28 MHz against HL's 65536), long enough that nine
# frames' worth of polls is a number rather than a rounding error.
FIRST_FRAME=${FIRST_FRAME:-803}
LAST_FRAME=${LAST_FRAME:-812}

RUN_TIMEOUT=120

. "$(dirname "$0")/bench-jnext.sh"

MF_ROM_PATH='::/machines/next/enNextMf.rom'

log()  { printf '%s\n' "$*"; }
meas() { printf 'MEAS  %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ -x "$JNEXT" ]        || die "jnext binary not found or not executable: $JNEXT"
[ -f "$SD_IMAGE" ]     || die "SD card image not found: $SD_IMAGE"
[ -f "$ROM" ]          || die "ROM not built: $ROM (run 'make measure-poll-cost')"
[ -f "$COST_BIN_ON" ]  || die "cost fixture not built: $COST_BIN_ON"
[ -f "$COST_BIN_OFF" ] || die "cost fixture not built: $COST_BIN_OFF"
command -v mcopy >/dev/null || die "mtools (mcopy) is required to install the ROM"

part_lba=$(od -An -tu4 -j 454 -N 4 "$SD_IMAGE" | tr -d ' ')
[ -n "$part_lba" ] && [ "$part_lba" -gt 0 ] || die "cannot read partition table from $SD_IMAGE"
part_off=$((part_lba * 512))

mkdir -p "$OUT"
sd=$OUT/sd-poll-cost.img

current_image=""
cleanup() {
    rm -f "$sd"
    [ -n "$current_image" ] && bench_await_departure "$current_image"
    true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

cp --reflink=auto -f "$SD_IMAGE" "$sd"
mcopy -o -i "$sd@@$part_off" "$ROM" "$MF_ROM_PATH"

# snap <binary> <frame> <file> — one run, one snapshot.
snap() {
    local bin=$1 frame=$2 out=$3
    rm -f "$out"
    current_image=$sd
    local rc=0
    timeout "$RUN_TIMEOUT" "$JNEXT" \
        --headless --machine next \
        --sdcard "$sd" \
        --rtc "2026-01-01 12:00:00" \
        --inject "$bin" --inject-org 8000 --inject-pc 8000 \
        --inject-delay "$INJECT_FRAME" \
        --delayed-snapshot "$out" --delayed-snapshot-frames "$frame" \
        --delayed-automatic-exit-frames "$((frame + 40))" \
        >/dev/null 2>&1 || rc=$?
    bench_await_departure "$sd"
    current_image=""
    [ "$rc" -eq 0 ] || die "jnext run failed or timed out (bin=$bin frame=$frame)"
    [ -s "$out" ]   || die "no snapshot written: $out"
}

log "== measuring the poll's cost (4 headless runs)"
snap "$COST_BIN_ON"  "$FIRST_FRAME" "$OUT/cost-on-first.sna"
snap "$COST_BIN_ON"  "$LAST_FRAME"  "$OUT/cost-on-last.sna"
snap "$COST_BIN_OFF" "$FIRST_FRAME" "$OUT/cost-off-first.sna"
snap "$COST_BIN_OFF" "$LAST_FRAME"  "$OUT/cost-off-last.sna"
log ""

python3 - "$OUT" "$FIRST_FRAME" "$LAST_FRAME" "$INJECT_FRAME" <<'EOF'
import struct, sys

out, first, last, inject = (sys.argv[1], int(sys.argv[2]),
                            int(sys.argv[3]), int(sys.argv[4]))
frames = last - first


def read(name):
    """HL and D out of a 48K .sna: I, HL', DE', BC', AF', HL, DE, ..."""
    d = open("%s/%s.sna" % (out, name), "rb").read()
    hl = struct.unpack("<H", d[9:11])[0]
    de = struct.unpack("<H", d[11:13])[0]
    return hl, de >> 8


on_first, clock = read("cost-on-first")
on_last, _ = read("cost-on-last")
off_first, _ = read("cost-off-first")
off_last, _ = read("cost-off-last")

# The frame is 50 Hz; the T-states in one depend on the clock the DEBUGGEE runs
# at, which is why the fixture reports it rather than leaving it to be inferred.
# Bits 1:0 are the PROGRAMMED speed (zxnext.vhd:5903, :5789). Derived HERE rather
# than beside the printing, because the wrap refusal below is built on it.
HZ = {0: 3.5, 1: 7.0, 2: 14.0, 3: 28.0}[clock & 0x03]
t_per_frame = HZ * 1e6 / 50.0

# THE WRAP REFUSAL, AND THE FIRST VERSION OF IT DID NOT DO WHAT ITS OWN COMMENT
# SAID. It tested `b <= a` alone — i.e. it fired only when a wrapped total
# happened to land numerically BELOW the first reading. Provoked and reproduced:
# at LAST_FRAME=830 the counter genuinely wraps, 11736 -> 51824, the final
# reading still exceeds the first, nothing is refused, and the script prints
# `1484.9 iterations/frame` and a cost of 0.609% as an ordinary MEAS line and
# exits 0. About 9 of the ~46 wrapping gap-widths were caught; the rest sailed
# through. A plausible wrong number is worse than a loud refusal, and this is the
# one file whose whole purpose is to be re-runnable evidence for somebody who
# widens the window.
#
# NOTE THAT A BARE READING BOUND DOES NOT FIX IT EITHER, which is the trap: both
# of those readings are below any sane ceiling. Two readings simply cannot tell a
# wrap from a large honest increase. So the load-bearing check is A PRIORI —
# whether the window CAN wrap — and the reading and rate checks are backstops for
# the case where the loop is not what this script thinks it is.
#
# MIN_LOOP_T is a hard floor rather than a guess: copper_cost.asm's loop is
# `ld b,8` (7) + eight `djnz` (99) + `inc hl` (6) + `jr` (12) = 124 T-states
# nominal, and no machine executes it in fewer. Measured here at 143, the
# difference being contention. If DELAY_COUNT ever shrinks, this must shrink with
# it — which is why the number is derived in a comment rather than asserted.
MIN_LOOP_T = 120        # below copper_cost.asm's nominal 124
MAX_LOOP_T = 250        # generously above the measured 143
SAFE_COUNT = 60000      # comfortably below HL's 65536

# The counter starts at zero when the fixture is injected, so what can wrap is
# the count at the LAST frame, measured from the injection — not the window.
span = last - inject
max_rate = t_per_frame / MIN_LOOP_T
if span * max_rate >= 65536:
    sys.exit("ERROR: the window can wrap: %d frames after injection at up to %.0f "
             "iterations/frame is %.0f, and HL holds 65536. No reading from it "
             "could be trusted. Keep the last frame within %d of the injection."
             % (span, max_rate, span * max_rate, int(65535 / max_rate)))

for a, b, what in ((on_first, on_last, "with the poll"),
                   (off_first, off_last, "without it")):
    if b <= a:
        sys.exit("ERROR: HL did not increase %s (%d -> %d): the counter wrapped, "
                 "so no rate can be taken. Shorten the window." % (what, a, b))
    if b >= SAFE_COUNT or a >= SAFE_COUNT:
        sys.exit("ERROR: a reading is within reach of HL's wrap %s (%d -> %d, "
                 "ceiling %d): the loop is faster than this script assumes. "
                 "Shorten the window." % (what, a, b, SAFE_COUNT))

on_rate = (on_last - on_first) / frames
off_rate = (off_last - off_first) / frames

# Third backstop: a wrap that survived both of the above would show up as a loop
# that suddenly takes far longer per iteration than its own instruction count
# allows. The band is a property of the fixture's code, so it is clock-independent.
observed_t = t_per_frame / off_rate
if not MIN_LOOP_T <= observed_t <= MAX_LOOP_T:
    sys.exit("ERROR: %.0f T-states per iteration is outside [%d, %d], which "
             "copper_cost.asm's loop cannot be. The counter probably wrapped, or "
             "the fixture changed and these bounds did not."
             % (observed_t, MIN_LOOP_T, MAX_LOOP_T))
lost = off_rate - on_rate
pct = 100.0 * lost / off_rate

t_per_iter = t_per_frame / off_rate
t_lost = lost * t_per_iter

print("MEAS  clock NR 0x07 = 0x%02X, so the debuggee ran at %.1f MHz "
      "(%.0f T-states per 50 Hz frame)" % (clock, HZ, t_per_frame))
print("MEAS  loop rate: %.1f iterations/frame without the poll, %.1f with it, "
      "over %d frames" % (off_rate, on_rate, frames))
print("MEAS  the poll costs %.3f%% of a frame at %.1f MHz" % (pct, HZ))
print("MEAS  which is %.0f T-states per frame, at %.0f T-states per iteration"
      % (t_lost, t_per_iter))
print("MEAS  ARITHMETIC, not a measurement: the same %.0f T-states is %.2f%% of "
      "a 3.5 MHz frame" % (t_lost, 100.0 * t_lost / (3.5e6 / 50.0)))
print("")
print("There is no PASS here. This is an instrument, and it measures the poll's")
print("DECLINE path only — no client is attached, so every poll answers 'quiet'.")
print("plan §10 and doc/ASYNCHRONOUS-BREAK-DESIGN.md §5 carry ~100-200")
print("T-states/frame as an ESTIMATE; compare it with the figure above.")
EOF
