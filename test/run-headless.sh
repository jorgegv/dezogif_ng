#!/usr/bin/env bash
#
# Local headless test bench for the dezogif_esp stub.
#
# No VS Code, no DeZog, no hardware: everything here runs jnext headless and
# judges PNG screenshots. Invoked by `make test`.
#
# What it proves, in order of strength:
#
#   T1  the bench itself boots a Next and captures a screen
#   T2  installing our enNextMf.rom does not perturb the NextZXOS boot
#   T3  CONTROL: the software-NMI fixture really does fire the Multiface NMI,
#       demonstrated against the SD image's own (stock) Multiface ROM
#   T4  our stub declines that NMI, because it is not a button press — which
#       is what upstream's nmi66h is written to do. See the note at T4; M2
#       has to invert this one.
#
# T3 is not decoration. Without it a broken fixture would make T4 look like a
# stub bug (or, worse, a change in T4's screen would look like a pass). If T3
# fails, the bench is broken and T4's verdict means nothing.
#
# Every run uses identical frame counts so the two screenshots being compared
# are at the same point in the FLASH attribute cycle; otherwise "the screen
# changed" would be true of any two captures.
#
# Environment (all set by the Makefile, all overridable):
#   JNEXT        path to the jnext binary
#   SD_IMAGE     reference SD card image; NEVER written, only copied
#   OUT          build directory
#   ROM          our enNextMf.rom
#   TRIGGER_BIN  assembled test/nmi_trigger.asm

set -euo pipefail

JNEXT=${JNEXT:-$HOME/src/spectrum/jnext/build/gui-release/jnext}
SD_IMAGE=${SD_IMAGE:-$HOME/.jnext/sdcard/cspect-next-1gb-fixed.img}
OUT=${OUT:-build}
ROM=${ROM:-$OUT/enNextMf.rom}
TRIGGER_BIN=${TRIGGER_BIN:-$OUT/nmi_trigger.bin}

# Frame budget. The Next needs ~900 frames to reach the NextZXOS welcome
# screen; the fixture is injected there and the screen is captured 150 frames
# (3 emulated seconds) later, which is ample for the stub to paint.
BOOT_FRAMES=900
SHOT_FRAMES=1050
EXIT_FRAMES=1100

# Wall-clock guard per emulator run. Headless runs above take ~6s.
RUN_TIMEOUT=120

# How much of the screen must change before we call it a takeover. The stock
# Multiface monitor repaints 91% of the screen; NextZXOS idling repaints
# 0.01% (a character cell or two). Anything in between is not a takeover, and
# treating "not byte-identical" as one produces a false PASS — it did, which
# is why this threshold exists.
TAKEOVER_PCT=25

SHOTS=$OUT/screenshots
MF_ROM_PATH='::/machines/next/enNextMf.rom'

failures=0

log()  { printf '%s\n' "$*"; }
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; failures=$((failures + 1)); }

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# --- pre-flight ------------------------------------------------------------

[ -x "$JNEXT" ]      || die "jnext binary not found or not executable: $JNEXT"
[ -f "$SD_IMAGE" ]   || die "SD card image not found: $SD_IMAGE"
[ -f "$ROM" ]        || die "ROM not built: $ROM (run 'make mf_rom')"
[ -f "$TRIGGER_BIN" ]|| die "NMI fixture not built: $TRIGGER_BIN (run 'make test')"
command -v mcopy >/dev/null || die "mtools (mcopy) is required to install the ROM into the SD image"
python3 -c 'import PIL' 2>/dev/null || die "python3 Pillow is required to compare screenshots"

SCREEN_DIFF=$(dirname "$0")/screen-diff.py

# Percentage of pixels differing between two screenshots.
diff_pct() { python3 "$SCREEN_DIFF" "$1" "$2"; }

# True when the difference reaches the takeover threshold.
took_over() { awk -v pct="$1" -v thr="$TAKEOVER_PCT" 'BEGIN { exit !(pct >= thr) }'; }

# Offset of the first partition, read from the MBR (LBA start is the 4 bytes
# at 0x1BE+8) rather than assumed, so a different image still works.
part_lba=$(od -An -tu4 -j 454 -N 4 "$SD_IMAGE" | tr -d ' ')
[ -n "$part_lba" ] && [ "$part_lba" -gt 0 ] || die "cannot read partition table from $SD_IMAGE"
part_off=$((part_lba * 512))

# --- working images --------------------------------------------------------
#
# The reference image is never touched: both working copies live in the build
# directory and are reflinked where the filesystem supports it, so a 1 GB copy
# costs nothing.

mkdir -p "$SHOTS"
sd_stock=$OUT/sd-stock.img
sd_ours=$OUT/sd-ours.img

log "== preparing SD images (reference: $SD_IMAGE, partition offset $part_off)"
cp --reflink=auto -f "$SD_IMAGE" "$sd_stock"
cp --reflink=auto -f "$SD_IMAGE" "$sd_ours"
mcopy -o -i "$sd_ours@@$part_off" "$ROM" "$MF_ROM_PATH"

# --- runs ------------------------------------------------------------------

# run <image> <screenshot> [trigger]
run() {
    local image=$1 shot=$2 trigger=${3:-}
    local -a args=(
        --headless --machine next
        --sdcard "$image"
        --rtc "2026-01-01 12:00:00"
        --delayed-screenshot "$shot"
        --delayed-screenshot-frames "$SHOT_FRAMES"
        --delayed-automatic-exit-frames "$EXIT_FRAMES"
    )
    if [ -n "$trigger" ]; then
        args+=(--inject "$trigger" --inject-org 8000 --inject-pc 8000
               --inject-delay "$BOOT_FRAMES")
    fi
    rm -f "$shot"
    timeout "$RUN_TIMEOUT" "$JNEXT" "${args[@]}" >/dev/null 2>&1 \
        || die "jnext run failed or timed out (image=$image trigger=${trigger:-none})"
    [ -s "$shot" ] || die "no screenshot written: $shot"
}

log "== running the bench (4 headless runs, ~30s)"
run "$sd_stock" "$SHOTS/boot-stock.png"
run "$sd_ours"  "$SHOTS/boot-ours.png"
run "$sd_stock" "$SHOTS/nmi-stock.png" "$TRIGGER_BIN"
run "$sd_ours"  "$SHOTS/nmi-ours.png"  "$TRIGGER_BIN"

# --- assertions ------------------------------------------------------------

log ""

# T1
if [ -s "$SHOTS/boot-stock.png" ]; then
    pass "T1 bench boots a ZX Next and captures a screen"
else
    fail "T1 bench produced no screen"
fi

# T2 — our ROM must be inert until the NMI fires.
if cmp -s "$SHOTS/boot-stock.png" "$SHOTS/boot-ours.png"; then
    pass "T2 our enNextMf.rom does not perturb the NextZXOS boot (0.00% of pixels differ)"
else
    fail "T2 boot differs with our ROM installed ($(diff_pct "$SHOTS/boot-stock.png" "$SHOTS/boot-ours.png")% of pixels; see $SHOTS/boot-{stock,ours}.png)"
fi

# T3 — control for T4.
stock_pct=$(diff_pct "$SHOTS/boot-stock.png" "$SHOTS/nmi-stock.png")
if took_over "$stock_pct"; then
    pass "T3 CONTROL: the NMI fixture fires the Multiface NMI (stock MF ROM repaints $stock_pct% of the screen)"
else
    fail "T3 CONTROL: the NMI fixture did not fire the Multiface NMI (only $stock_pct% changed) — the bench is broken and T4 below is meaningless"
fi

# T4 — the actual subject.
#
# The expectation here is DECLINE, not takeover, and that is not a workaround.
# mf_rom.asm's nmi66h reads NR 0x02 on entry, masks 00011100b and returns
# immediately unless the result is zero — "return if not a button press".
# NR 0x02 bit 3 reads back as nr_02_generate_mf_nmi, which zxnext.vhd:3843-3847
# latches on ANY accepted NR 0x02 bit-3 write and clears only on an explicit
# write of bit 3 = 0. Our fixture is exactly such a write, so upstream's stub
# is *designed* to ignore it, and the screen must be untouched.
#
# M2 MUST FLIP THIS. The plan's asynchronous break is a Copper `MOVE $02,$08`,
# which sets the same latch through the same signal (nmi_gen_nr_mf covers CPU
# and Copper alike, zxnext.vhd:3832) and will be filtered by the same check
# until nmi66h is taught to accept a software cause. When that lands, this
# assertion becomes took_over and the message becomes a takeover.
ours_pct=$(diff_pct "$SHOTS/boot-ours.png" "$SHOTS/nmi-ours.png")
if took_over "$ours_pct"; then
    fail "T4 our stub took the screen on a NON-BUTTON NMI ($ours_pct%) — nmi66h's cause check has changed; if that was deliberate (M2), invert this assertion"
else
    pass "T4 our stub declines a non-button NMI and leaves the screen alone ($ours_pct% changed), as nmi66h's cause check intends"
fi

log ""
if [ "$failures" -eq 0 ]; then
    verdict="4/4 checks passed"
else
    verdict="$failures of 4 checks FAILED"
fi
log "$verdict  (screenshots in $SHOTS)"

# Picked up by the SessionStart hook, so a new session knows where it stands.
printf '%s\n' "$verdict" > "$OUT/last-test.txt"

exit "$((failures > 0 ? 1 : 0))"
