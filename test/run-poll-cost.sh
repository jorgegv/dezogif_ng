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
FIRST_FRAME=803
LAST_FRAME=812

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

python3 - "$OUT" "$FIRST_FRAME" "$LAST_FRAME" <<'EOF'
import struct, sys

out, first, last = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
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

# A wrap would make a difference meaningless, and it is the mistake the first
# attempt at this made — so it is refused rather than reported.
for a, b, what in ((on_first, on_last, "with the poll"),
                   (off_first, off_last, "without it")):
    if b <= a:
        sys.exit("ERROR: HL did not increase %s (%d -> %d): the counter wrapped, "
                 "so no rate can be taken. Shorten the window." % (what, a, b))

on_rate = (on_last - on_first) / frames
off_rate = (off_last - off_first) / frames
lost = off_rate - on_rate
pct = 100.0 * lost / off_rate

# The frame is 50 Hz; the T-states in one depend on the clock the DEBUGGEE runs
# at, which is why the fixture reports it rather than leaving it to be inferred.
# Bits 1:0 are the PROGRAMMED speed (zxnext.vhd:5903, :5789).
HZ = {0: 3.5, 1: 7.0, 2: 14.0, 3: 28.0}[clock & 0x03]
t_per_frame = HZ * 1e6 / 50.0
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
