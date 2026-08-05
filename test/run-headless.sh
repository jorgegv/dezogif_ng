#!/usr/bin/env bash
#
# Local headless test bench for the dezogif_ng stub.
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
#   T5  the COPPER can raise the Multiface NMI on its own, at a chosen raster
#       line, with no CPU involvement — the mechanism M2's asynchronous break
#       is built on. Shown against the stock MF ROM for the same reason as T3:
#       our stub declines it, and would decline it whether or not the Copper
#       worked, so the stub cannot be the thing that demonstrates it.
#   T6  our stub TAKES OVER on a real M1 button NMI and paints its own screen.
#       The only check here that proves the stub is alive rather than proving
#       it correctly ignores something — see the note at T6.
#
# T3 is not decoration. Without it a broken fixture would make T4 look like a
# stub bug (or, worse, a change in T4's screen would look like a pass). If T3
# fails, the bench is broken and T4's verdict means nothing.
#
# T4 AND T6 ARE NOT ALTERNATIVES, and an earlier note here said T6 would
# "replace" T4. It does not. They test different NMI causes against the same
# cause check in nmi66h: T6 sends a cause it accepts (the button), T4 a cause
# it rejects (a software NR 0x02 write). Keeping both is what makes T4 a
# regression check M2 has to invert deliberately, rather than one that quietly
# disappears the day the button check arrives.
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
#   COPPER_BIN   assembled test/copper_nmi.asm

set -euo pipefail

JNEXT=${JNEXT:-$HOME/src/spectrum/jnext/build/gui-release/jnext}
SD_IMAGE=${SD_IMAGE:-$HOME/.jnext/sdcard/cspect-next-1gb-fixed.img}
OUT=${OUT:-build}
ROM=${ROM:-$OUT/enNextMf.rom}
TRIGGER_BIN=${TRIGGER_BIN:-$OUT/nmi_trigger.bin}
COPPER_BIN=${COPPER_BIN:-$OUT/copper_nmi.bin}

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

# Shared jnext teardown — issue #17. Defines functions and nothing else, so it
# cannot disturb the `set -euo pipefail` above or the trap below.
# shellcheck source=test/bench-jnext.sh
. "$(dirname "$0")/bench-jnext.sh"

# WHAT ISSUE #17 MEANS HERE, AND WHAT IT DOES NOT. This bench passes no --esp,
# so its runs never bind port 11000 and it takes no bench lock; the "a survivor
# answers the next agent's client" failure cannot happen from here. What CAN
# happen is an emulator left running after a `timeout` fired or the script was
# interrupted — six per run, competing for the machine with whatever bench is
# holding the lock, and holding a gigabyte working image open. So departure is
# confirmed for the same reason and by the same code, and the claim is the
# smaller one.
#
# The working images are still left behind on purpose: that leak is real and is
# recorded in ERRORS.md, and removing it is a different change from this one.
current_image=""
cleanup() {
    if [ -n "$current_image" ]; then
        bench_await_departure "$current_image"
    fi
}
trap cleanup EXIT
# A handler that only RETURNS does not stop a bash script — the shell defers the
# signal, runs the handler and carries on. These exit, and the EXIT trap runs on
# the way out.
trap 'exit 130' INT
trap 'exit 143' TERM

failures=0

log()  { printf '%s\n' "$*"; }
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; failures=$((failures + 1)); }

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# --- pre-flight ------------------------------------------------------------

[ -x "$JNEXT" ]      || die "jnext binary not found or not executable: $JNEXT"
[ -f "$SD_IMAGE" ]   || die "SD card image not found: $SD_IMAGE"
[ -f "$ROM" ]        || die "ROM not built: $ROM (run 'make mf-rom')"
[ -f "$TRIGGER_BIN" ]|| die "NMI fixture not built: $TRIGGER_BIN (run 'make test')"
[ -f "$COPPER_BIN" ] || die "Copper fixture not built: $COPPER_BIN (run 'make test')"
command -v mcopy >/dev/null || die "mtools (mcopy) is required to install the ROM into the SD image"

# T6 needs a headless M1 button press, which arrived in jnext 0.99.118. Checked
# explicitly because the failure mode otherwise is jnext exiting with "Unknown
# option" and the run being reported as a jnext crash — which cost real time
# once already. A stale binary should say so in one line.
"$JNEXT" --help 2>&1 | grep -q -- '--delayed-nmi' \
    || die "this jnext has no --delayed-nmi (need >= 0.99.118, found: $("$JNEXT" --help 2>&1 | grep -oE 'jnext [0-9.]+' | head -1)); rebuild it — T6 cannot run without it"
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

# run <image> <screenshot> [trigger-binary] [nmi-button]
run() {
    local image=$1 shot=$2 trigger=${3:-} button=${4:-}
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
    # A real M1 button press, at the same frame the injected fixtures fire, so
    # every screenshot is taken at the same point in the FLASH cycle.
    if [ -n "$button" ]; then
        args+=(--delayed-nmi-frames "$BOOT_FRAMES" "$button")
    fi
    rm -f "$shot"
    current_image=$image
    local rc=0
    timeout "$RUN_TIMEOUT" "$JNEXT" "${args[@]}" >/dev/null 2>&1 || rc=$?

    # BEFORE anything is concluded, and before the next run starts. `timeout`
    # returning is not jnext having exited — on a timeout it has only been sent
    # a SIGTERM. Issue #17; see test/bench-jnext.sh.
    bench_await_departure "$image"
    current_image=""

    [ "$rc" -eq 0 ] \
        || die "jnext run failed or timed out (image=$image trigger=${trigger:-none})"
    [ -s "$shot" ] || die "no screenshot written: $shot"
}

log "== running the bench (6 headless runs, ~50s)"
run "$sd_stock" "$SHOTS/boot-stock.png"
run "$sd_ours"  "$SHOTS/boot-ours.png"
run "$sd_stock" "$SHOTS/nmi-stock.png" "$TRIGGER_BIN"
run "$sd_ours"  "$SHOTS/nmi-ours.png"  "$TRIGGER_BIN"
run "$sd_stock" "$SHOTS/copper-stock.png" "$COPPER_BIN"
run "$sd_ours"  "$SHOTS/button-ours.png" "" nmi

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
    fail "T2 boot differs with our ROM installed ($(diff_pct "$SHOTS/boot-stock.png" "$SHOTS/boot-ours.png")% of pixels; see boot-{stock,ours}.png)"
fi

# T3 — control for T4.
stock_pct=$(diff_pct "$SHOTS/boot-stock.png" "$SHOTS/nmi-stock.png")
if took_over "$stock_pct"; then
    pass "T3 CONTROL: the NMI fixture fires the Multiface NMI (stock MF ROM repaints $stock_pct%)"
else
    fail "T3 CONTROL: the NMI fixture did not fire the Multiface NMI ($stock_pct%): T4 below means nothing"
fi

# T4 — the actual subject.
#
# The expectation here is DECLINE, not takeover, and that is not a workaround.
# mf_rom.asm's nmi66h reads NR 0x02 on entry, masks 00011100b and returns
# immediately unless the result is zero — "return if not a button press".
# NR 0x02 bit 3 reads back as nr_02_generate_mf_nmi, which zxnext.vhd:3843-3848
# latches on ANY accepted NR 0x02 bit-3 write and clears only on an explicit
# write of bit 3 = 0. Our fixture is exactly such a write, so upstream's stub
# is *designed* to ignore it, and the screen must be untouched.
#
# Two separate things would change this expectation, and they are not the same:
#   - jnext gaining a headless button-NMI (a --delayed-nmi option is in development as of
#     2026-08-03). nmi66h accepts a button cause, so that lets the bench assert a real takeover
#     for the FIRST time — the strongest check available here. It does not require any stub
#     change at all.
#   - M2 teaching nmi66h to accept a software cause, below.
#
# M2 MUST FLIP THIS. The plan's asynchronous break is a Copper `MOVE $02,$08`,
# which sets the same latch through the same signal (nmi_gen_nr_mf covers CPU
# and Copper alike, zxnext.vhd:3832) and will be filtered by the same check
# until nmi66h is taught to accept a software cause. When that lands, this
# assertion becomes took_over and the message becomes a takeover.
ours_pct=$(diff_pct "$SHOTS/boot-ours.png" "$SHOTS/nmi-ours.png")
if took_over "$ours_pct"; then
    fail "T4 our stub took the screen on a NON-BUTTON NMI ($ours_pct%): nmi66h's cause check has changed"
else
    pass "T4 our stub declines a non-button NMI and leaves the screen alone ($ours_pct% changed)"
fi

# T5 — the Copper NMI, M2's mechanism.
copper_pct=$(diff_pct "$SHOTS/boot-stock.png" "$SHOTS/copper-stock.png")
if took_over "$copper_pct"; then
    pass "T5 a two-instruction Copper list raises the Multiface NMI ($copper_pct% repainted)"
else
    fail "T5 the Copper did not raise the Multiface NMI ($copper_pct% changed; see copper-stock.png)"
fi

# T6 — the stub is ALIVE.
#
# Every other check here proves a negative: it assembles, it does not perturb
# the boot, it correctly ignores a cause it should ignore. This one proves the
# stub runs. A real M1 button press is a cause nmi66h accepts, so the stub
# relocates MAIN into a RAM bank, pages itself into slot 7, and paints its own
# UI over the NextZXOS screen — which is a ~90% repaint, in the same range as
# the stock Multiface monitor's 91%.
#
# It exercises, in one run and for the first time in this project: Multiface
# paging, the relocation, show_ui, and the core-version check passing (the
# reference image reports 03.02.03, above the 03.01.10 that stackless NMI
# needs). If T6 goes red, one of those broke, and nothing else in the bench
# would have noticed.
#
# WHAT IT DOES NOT COVER, and this is larger than it looks. T6 NEVER RESUMES.
# No DZRP client attaches, so the stub idles in main.asm's main_loop: its
# transport_byte_available poll is a status-bit read that returns at once, so
# the `jp nz,cmd_loop` never fires and cmd_loop — with the blocking
# transport_wait_rx inside it — is never reached at all. The run ends when
# --delayed-automatic-exit-frames kills it. Nothing after "the debugger
# came up" executes: not the exit path,
# not backup.asm's restoration, and not the return-to-debuggee half of
# stackless NMI — which is the half plan §3.4 says actually matters, because
# without it entering the debugger corrupts the program being debugged. What
# T6 does exercise of stackless NMI is the ENTRY side only.
# So: a green T6 means the stub comes up. It does not mean the NMI path is
# sound, and a second press after a resume is not "the next question" — the
# first resume has not happened either.
#
# It is also a DIFFERENCE measure, which does not know what it is looking at:
# a crash or a garbage screen would also differ from the boot screen by ~90%
# (the lesson in ERRORS.md). The second condition below removes the most
# likely wrong-thing-answered case — that our ROM was not installed and the
# stock Multiface monitor took the NMI — by requiring the result NOT to look
# like T3's stock-monitor screen. A crashed machine would still pass, so
# button-ours.png is the artefact to look at when anything here surprises you.
button_pct=$(diff_pct "$SHOTS/boot-ours.png" "$SHOTS/button-ours.png")
vs_stock_pct=$(diff_pct "$SHOTS/nmi-stock.png" "$SHOTS/button-ours.png")
if ! took_over "$button_pct"; then
    fail "T6 our stub did NOT take over on an M1 button NMI ($button_pct%): nmi66h, the relocation or show_ui broke"
elif ! took_over "$vs_stock_pct"; then
    fail "T6 something took over but it looks like the STOCK Multiface monitor ($vs_stock_pct% unlike it): is our ROM installed?"
else
    pass "T6 the stub is ALIVE: it takes over on a real M1 button NMI ($button_pct% repainted, $vs_stock_pct% unlike stock)"
fi

log ""
# Derived, not hardcoded: the summary said "5/5" for a while after a sixth
# check was added, which is a small lie in exactly the place a reader trusts.
checks=6
if [ "$failures" -eq 0 ]; then
    verdict="$checks/$checks checks passed"
else
    verdict="$failures of $checks checks FAILED"
fi
log "$verdict  (screenshots in $SHOTS)"

# Picked up by the SessionStart hook, so a new session knows where it stands.
printf '%s\n' "$verdict" > "$OUT/last-test.txt"

exit "$((failures > 0 ? 1 : 0))"
