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
#   T4  our stub declines that NMI at a machine where no debugger has ever been
#       started. Since M2 that is a SERVED cause that correctly declines, not a
#       filtered-out one — the verdict is unchanged and the reason is not. See
#       the note at T4, which records why M2 did NOT invert it.
#   T5  the COPPER can raise the Multiface NMI on its own, at a chosen raster
#       line, with no CPU involvement — the mechanism M2's asynchronous break
#       is built on. Shown against the stock MF ROM for the same reason as T3:
#       our stub declines it, and would decline it whether or not the Copper
#       worked, so the stub cannot be the thing that demonstrates it.
#   T6  our stub TAKES OVER on a real M1 button NMI and paints its own screen.
#       The only check here that proves the stub is alive BY TAKING OVER,
#       rather than proving it correctly ignores something — see the note at
#       T6. T8 also judges liveness, and judges it a different way: not that
#       the stub arrives, but that it is still answering its own keyboard.
#   T7  a second M1 press after a SOFT RESET re-initialises the debugger
#       instead of declining (issue #26) — see the note at T7. The only check
#       here that presses the button twice WITH A RESET BETWEEN, which is why
#       five years of upstream and every earlier bench missed the defect it
#       guards. T8 is the other one HERE that presses twice, without a reset.
#   T8  a second M1 press with NO reset is DECLINED, and the stub is still
#       alive afterwards (issue #36). T7's other arm — see the note at T8.
#   T9  THE ASYNCHRONOUS-BREAK POLL, ~50 times a second (issue #22, M2). A
#       Copper list installed by the DEBUGGED PROGRAM raises the Multiface NMI
#       every frame, and the stub's new software-cause path must give the
#       machine back untouched every time — and must still be alive at the end.
#       See the note at T9.
#
# T3 is not decoration. Without it a broken fixture would make T4 look like a
# stub bug (or, worse, a change in T4's screen would look like a pass). If T3
# fails, the bench is broken and T4's verdict means nothing.
#
# T7 AND T8 ARE THE TWO ARMS OF ONE BRANCH, and neither covers the other. The
# NMI dispatch keys on the bank slot 7 held at the moment of the press: not
# MAIN_BANK means the debugger was NOT executing, so re-initialise (T7);
# MAIN_BANK means it was, so decline (T8). A regression sending EVERY press to
# init_main_bank would destroy live debug sessions and T7 would still pass,
# because T7's own arm would keep working — which is why T8 exists, and why it
# exists before M2 edits that routine.
#
# T4 AND T6 ARE NOT ALTERNATIVES, and an earlier note here said T6 would
# "replace" T4. It does not. They test different NMI causes against the same
# cause check in nmi66h: T6 sends a cause it accepts (the button), T4 a cause
# it rejects (a software NR 0x02 write).
#
# M2 DID NOT INVERT T4, AND THE ISSUE SAID IT WOULD. That instruction — carried
# here, in CLAUDE.md and in the plan since the fork — rested on an assumption
# about the shape of the fix: that teaching nmi66h to accept a software cause
# would make it TAKE OVER on one. It does not. The poll path accepts the cause
# and then declines unless BOTH our image is in MAIN_BANK and a debuggee is
# running, and in T4's run no debugger has ever been started, so the magic check
# fails and the screen is left alone. T4's verdict is therefore unchanged and
# still correct; what changed is the reason, which is now "the software cause is
# SERVED and correctly declines" rather than "the software cause is filtered
# out". Inverting it would have made it assert a takeover that must not happen.
# Where the software cause being served IS asserted is T9.
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
#   POLL_BIN     assembled test/copper_poll.asm

set -euo pipefail

JNEXT=${JNEXT:-$HOME/src/spectrum/jnext/build/gui-release/jnext}
SD_IMAGE=${SD_IMAGE:-$HOME/.jnext/sdcard/cspect-next-1gb-fixed.img}
OUT=${OUT:-build}
ROM=${ROM:-$OUT/enNextMf.rom}
TRIGGER_BIN=${TRIGGER_BIN:-$OUT/nmi_trigger.bin}
COPPER_BIN=${COPPER_BIN:-$OUT/copper_nmi.bin}
POLL_BIN=${POLL_BIN:-$OUT/copper_poll.bin}

# Frame budget. The Next needs ~900 frames to reach the NextZXOS welcome
# screen; the fixture is injected there and the screen is captured 150 frames
# (3 emulated seconds) later, which is ample for the stub to paint.
BOOT_FRAMES=900
SHOT_FRAMES=1050
EXIT_FRAMES=1100

# T7's choreography (issue #26): the stub is brought up with a button NMI,
# its own R key soft-resets the machine, NextZXOS boots again, and — in the
# second of the two runs — the button is pressed a SECOND time. Frame counts
# follow the same FLASH rule as everywhere else here: T7 compares its shots
# against run 6's stub screen, so RESET_SHOT_FRAMES sits a multiple of 32
# frames after SHOT_FRAMES (1050 + 36*32), keeping every compared pair at the
# same point in the FLASH attribute cycle.
RESET_KEY_FRAME=1080     # R pressed in the stub, 180 frames after it came up
SECOND_NMI_FRAME=2030    # the second NextZXOS boot is complete by here
RESET_SHOT_FRAMES=2202   # = SHOT_FRAMES + 36*32, and 172 frames after the NMI
RESET_EXIT_FRAMES=2262

# T8's choreography (issue #36), and every frame in it has a job. The stub is
# brought up with a button NMI at BOOT_FRAMES; "3" retargets the joy port, which
# is the state a re-initialisation would silently reset; the button is pressed a
# SECOND time with NO reset anywhere; and "B" is the liveness probe, which must
# come AFTER that press or it proves nothing about it. Same FLASH rule as
# everywhere else here: NORESET_SHOT_FRAMES is a multiple of 32 frames after
# SHOT_FRAMES (1050 + 13*32), and T8's two runs shoot at the same frame as each
# other, which is what makes their comparison a comparison of one variable.
#
# The three event frames are overridable so that T8's harness preconditions can
# be shown to FIRE rather than argued about — the reason run-dzrp-stub.sh's
# SECOND_NMI_FRAMES is: a red nobody can re-run is a story about a scratch tree.
# None of them is a build-constant seam of the IP_MAX family; no ROM is built
# differently, only this bench's schedule moves. Measured, each on the shipped
# ROM, and each takes a DIFFERENT one of T8's guards red:
#   NORESET_JOY_FRAME=850  -> "the joy-port key never landed" — pressed before
#                             the NMI, so the stub never polls it. 950 does NOT
#                             do it: measured, the stub is in main_loop and
#                             polling within 50 frames of the press, which is
#                             also how much margin the schedule below has.
#   NORESET_KEY_FRAME=1500 -> "the 'B' key never reached the one-press run"
#   NORESET_NMI_FRAME=1500 -> "the second press is not scheduled between them"
NORESET_JOY_FRAME=${NORESET_JOY_FRAME:-1100}   # "3", 200 frames after the stub came up
NORESET_NMI_FRAME=${NORESET_NMI_FRAME:-1200}   # the second press — no reset before it, unlike T7
NORESET_KEY_FRAME=${NORESET_KEY_FRAME:-1300}   # "B", 100 frames after that press
NORESET_SHOT_FRAMES=1466 # = SHOT_FRAMES + 13*32
NORESET_EXIT_FRAMES=1526

# T9's choreography (issue #22). The debugged program installs a Copper list
# that raises the Multiface NMI EVERY FRAME, so the stub's poll path runs
# thousands of times in one run and any leak it makes is repeated rather than
# rare. The fixture goes in EARLY — before the M1 press, so the polls are
# already hammering the machine while no debugger exists at all — and its own
# run 12 never presses the button, which is what puts the poll's magic-mismatch
# decline against code that CARES about MMU slot 7.
#
# Run 13 reuses T8's schedule exactly (BOOT_FRAMES / NORESET_JOY_FRAME /
# NORESET_KEY_FRAME / NORESET_SHOT_FRAMES) so that its screenshot can be
# compared with press1-ours.png BYTE FOR BYTE. That comparison is then a
# one-variable one: the Copper list, and nothing else.
POLL_INJECT_FRAME=800    # the list is running well before the button press
POLL_SHOT_FRAMES=1200    # ~8 emulated seconds of polling, ~400 NMIs
POLL_EXIT_FRAMES=1260

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
FONT_ROM_PATH='::/machines/next/48.rom'

# Shared jnext teardown — issue #17. Defines functions and nothing else, so it
# cannot disturb the `set -euo pipefail` above or the trap below.
# shellcheck source=test/bench-jnext.sh
. "$(dirname "$0")/bench-jnext.sh"

# WHAT ISSUE #17 MEANS HERE, AND WHAT IT DOES NOT. This bench passes no --esp,
# so its runs never bind port 11000 and it takes no bench lock; the "a survivor
# answers the next agent's client" failure cannot happen from here. What CAN
# happen is an emulator left running after a `timeout` fired or the script was
# interrupted — eight per run, competing for the machine with whatever bench is
# holding the lock, and holding a gigabyte working image open. So departure is
# confirmed for the same reason and by the same code, and the claim is the
# smaller one.
#
# THE WORKING IMAGES ARE REMOVED, and the two names are declared HERE — above
# the trap and above the copy — rather than beside the `cp` that creates them.
#
# `cp --reflink=auto` is free on a filesystem that supports reflinks and a full
# gigabyte on one that does not, silently; this bench makes TWO of them. About
# 22 GB of exactly these abandoned copies filled the /tmp quota on 2026-08-04
# and took the shell down mid-session — see ERRORS.md, and test/run-esp.sh,
# which carries the whole reasoning and the four wrong attempts it took to get
# the trap right. The short form: the copy is the slowest step here and so the
# likeliest moment to be interrupted, and under `set -u` a variable the handler
# has never seen aborts it before it reaches the `rm` — a leak fix that leaks.
#
# Nothing is lost. The diagnostics this bench leaves are its screenshots and its
# verdicts; the images are byte-for-byte copies of a reference file that is
# still sitting where it always was.
sd_stock=$OUT/sd-stock.img
sd_ours=$OUT/sd-ours.img

current_image=""
cleanup() {
    # Unlinked BEFORE departure is confirmed, because bench_await_departure can
    # `exit` and an exit that skipped this `rm` would reintroduce the leak. It
    # matches on the command line, not on the file, so removing first is safe.
    rm -f "$sd_stock" "$sd_ours"
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
[ -f "$POLL_BIN" ]   || die "poll fixture not built: $POLL_BIN (run 'make test')"
command -v mcopy >/dev/null || die "mtools (mcopy) is required to install the ROM into the SD image"

# T6 needs a headless M1 button press, which arrived in jnext 0.99.118. Checked
# explicitly because the failure mode otherwise is jnext exiting with "Unknown
# option" and the run being reported as a jnext crash — which cost real time
# once already. A stale binary should say so in one line.
bench_jnext_supports "$JNEXT" '--delayed-nmi' \
    || die "this jnext has no --delayed-nmi (need >= 0.99.118, found: $("$JNEXT" --help 2>&1 | grep -oE 'jnext [0-9.]+' | tail -1)); rebuild it — T6 cannot run without it"
python3 -c 'import PIL' 2>/dev/null || die "python3 Pillow is required to compare screenshots"

SCREEN_DIFF=$(dirname "$0")/screen-diff.py
SCREEN_TEXT=$(dirname "$0")/screen-text.py
[ -f "$SCREEN_TEXT" ] || die "screen reader not found: $SCREEN_TEXT (T8 reads a row of the stub's screen)"

# Percentage of pixels differing between two screenshots.
diff_pct() { python3 "$SCREEN_DIFF" "$1" "$2"; }

# True when the difference reaches the takeover threshold.
took_over() { awk -v pct="$1" -v thr="$TAKEOVER_PCT" 'BEGIN { exit !(pct >= thr) }'; }

# read_row <png> <row> — one character row of a screenshot, decoded with the ZX
# ROM font taken off the very SD image the machine boots. T8's use of it, and
# why a reading rather than a comparison, is at T8. Prints nothing and returns
# non-zero when the reader refuses; every caller treats that as a harness fault.
read_row() { python3 "$SCREEN_TEXT" --font "$font" "$1" "$2" 2>/dev/null; }

# border_rgb <png> — the border colour, as "r,g,b". Sampled at four corners,
# which are border in every Next screen mode and never paper, and required to
# agree so that a sample landing on something else is a hard error rather than a
# number this bench would go on to compare. jnext composes the border into the
# screenshot; it is the ULA that draws it.
#
# The same helper as test/run-no-hang.sh's, deliberately duplicated rather than
# shared, and the reason is the surgical-change rule rather than anything about
# bench-jnext.sh. That file's "functions and nothing else" invariant is about
# SOURCING — no `set`, no traps, no top-level state, so it cannot disturb a
# caller's `set -euo pipefail` or its trap wiring (MEMORY.md, issue #17) — and a
# pure function like this one would not violate it. What stops the sharing is
# that it would mean deleting run-no-hang.sh's copy: editing, and then having to
# re-run, a second bench this change has no business touching. Issue #17's own
# lesson cuts the other way and is worth weighing if a THIRD copy ever appears.
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
# the eight non-bright colours. Same values as run-no-hang.sh's N1/N2.
BORDER_BLACK=0,0,0
# T9's fixture speaks in these two: green while the poll is giving the machine
# back untouched, red — latched — the first time it is not. See copper_poll.asm.
BORDER_GREEN=0,182,0
BORDER_RED=182,0,0

# What the stub's own screen says, and both strings are drawn by ui.asm from
# data_const.asm. The joy-port line is T8's discriminator; the key line is the
# reader's control, chosen because it is drawn by the same code in the same font
# and its text is not in question.
NOJOY_TEXT="No joystick port used."
NOJOY_ROW=6
CONTROL_TEXT="R = Reset"
CONTROL_ROW=12

# Offset of the first partition, read from the MBR (LBA start is the 4 bytes
# at 0x1BE+8) rather than assumed, so a different image still works.
part_lba=$(od -An -tu4 -j 454 -N 4 "$SD_IMAGE" | tr -d ' ')
[ -n "$part_lba" ] && [ "$part_lba" -gt 0 ] || die "cannot read partition table from $SD_IMAGE"
part_off=$((part_lba * 512))

# --- working images --------------------------------------------------------
#
# The reference image is never touched: both working copies live in the build
# directory and are reflinked where the filesystem supports it, so a 1 GB copy
# costs nothing — and where it does not, it costs a gigabyte each, which is why
# both names are declared and trapped for removal further up rather than here.

mkdir -p "$SHOTS"

log "== preparing SD images (reference: $SD_IMAGE, partition offset $part_off)"
cp --reflink=auto -f "$SD_IMAGE" "$sd_stock"
cp --reflink=auto -f "$SD_IMAGE" "$sd_ours"
mcopy -o -i "$sd_ours@@$part_off" "$ROM" "$MF_ROM_PATH"

# The font the stub prints with, for T8's screen reader — taken out of the SAME
# image the machine boots, and out of the working COPY, so the reference is read
# and never written. Extracted here rather than at T8 because the working images
# are unlinked by the trap and this must happen while one exists.
font=$OUT/font-48.rom
mcopy -o -i "$sd_ours@@$part_off" "$FONT_ROM_PATH" "$font" \
    || die "cannot read $FONT_ROM_PATH out of the SD image (T8 needs it to read the screen)"

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

# T7's two runs: NMI, then the stub's own R key (a soft reset), then a second
# NextZXOS boot — and, in the second run only, a second NMI. jnext's stdout is
# kept, because T7's precondition is asserted from it: --delayed-nmi-frames
# QUEUES rather than overrides (so two NMIs in one run are possible at all),
# and the log's "Delayed NMI button ... pressed" lines are the evidence that
# both were really delivered — without that, a jnext that dropped the first
# press would turn run 8 into a FIRST press, whose takeover is not this
# check's subject and would pass it vacuously.
#
# run_reset <screenshot> <log> [second-nmi]
run_reset() {
    local shot=$1 rlog=$2 second=${3:-}
    local -a args=(
        --headless --machine next
        --sdcard "$sd_ours"
        --rtc "2026-01-01 12:00:00"
        --delayed-screenshot "$shot"
        --delayed-screenshot-frames "$RESET_SHOT_FRAMES"
        --delayed-automatic-exit-frames "$RESET_EXIT_FRAMES"
        --delayed-nmi-frames "$BOOT_FRAMES" nmi
        --delayed-keypress-frames "$RESET_KEY_FRAME" r
    )
    if [ -n "$second" ]; then
        args+=(--delayed-nmi-frames "$SECOND_NMI_FRAME" nmi)
    fi
    rm -f "$shot"
    current_image=$sd_ours
    local rc=0
    timeout "$RUN_TIMEOUT" "$JNEXT" "${args[@]}" >"$rlog" 2>&1 || rc=$?
    bench_await_departure "$sd_ours"
    current_image=""
    [ "$rc" -eq 0 ] || die "jnext reset run failed or timed out (shot=$shot)"
    [ -s "$shot" ] || die "no screenshot written: $shot"
}

# T8's two runs (issue #36): the stub comes up, "3" retargets the joy port, the
# button is pressed a second time with NO reset — in the second run only — and
# "B" is pressed afterwards. jnext's stdout is kept for the same reason as
# run_reset's, and the log level is raised for the same reason too: the
# "Delayed NMI button" line is platform/info, and a bench that suppressed it
# would report 0 presses against a stub that had taken two. jnext's current
# default happens to show it — run_reset above relies on that — but a
# precondition this check cannot do without should not rest on a default.
#
# run_noreset <screenshot> <log> [second-nmi]
run_noreset() {
    local shot=$1 rlog=$2 second=${3:-}
    local -a args=(
        --headless --machine next
        --sdcard "$sd_ours"
        --rtc "2026-01-01 12:00:00"
        --log-level "warn,platform=info"
        --delayed-screenshot "$shot"
        --delayed-screenshot-frames "$NORESET_SHOT_FRAMES"
        --delayed-automatic-exit-frames "$NORESET_EXIT_FRAMES"
        --delayed-nmi-frames "$BOOT_FRAMES" nmi
        --delayed-keypress-frames "$NORESET_JOY_FRAME" 3
    )
    if [ -n "$second" ]; then
        args+=(--delayed-nmi-frames "$NORESET_NMI_FRAME" nmi)
    fi
    args+=(--delayed-keypress-frames "$NORESET_KEY_FRAME" b)
    rm -f "$shot"
    current_image=$sd_ours
    local rc=0
    timeout "$RUN_TIMEOUT" "$JNEXT" "${args[@]}" >"$rlog" 2>&1 || rc=$?
    bench_await_departure "$sd_ours"
    current_image=""
    [ "$rc" -eq 0 ] || die "jnext second-press run failed or timed out (shot=$shot)"
    [ -s "$shot" ] || die "no screenshot written: $shot"
}

# T9's runs (issue #22). The poll fixture is injected early and left running;
# the button and the keys are optional, so one function serves all three.
#
# run_poll <image> <screenshot> [button-and-keys]
run_poll() {
    local image=$1 shot=$2 keys=${3:-}
    local -a args=(
        --headless --machine next
        --sdcard "$image"
        --rtc "2026-01-01 12:00:00"
        --inject "$POLL_BIN" --inject-org 8000 --inject-pc 8000
        --inject-delay "$POLL_INJECT_FRAME"
    )
    if [ -n "$keys" ]; then
        # T8's schedule, exactly, so run 13's screenshot is comparable with
        # press1-ours.png byte for byte.
        args+=(--delayed-nmi-frames "$BOOT_FRAMES" nmi
               --delayed-keypress-frames "$NORESET_JOY_FRAME" 3
               --delayed-keypress-frames "$NORESET_KEY_FRAME" b
               --delayed-screenshot "$shot"
               --delayed-screenshot-frames "$NORESET_SHOT_FRAMES"
               --delayed-automatic-exit-frames "$NORESET_EXIT_FRAMES")
    else
        args+=(--delayed-screenshot "$shot"
               --delayed-screenshot-frames "$POLL_SHOT_FRAMES"
               --delayed-automatic-exit-frames "$POLL_EXIT_FRAMES")
    fi
    rm -f "$shot"
    current_image=$image
    local rc=0
    timeout "$RUN_TIMEOUT" "$JNEXT" "${args[@]}" >/dev/null 2>&1 || rc=$?
    bench_await_departure "$image"
    current_image=""
    [ "$rc" -eq 0 ] || die "jnext poll run failed or timed out (image=$image shot=$shot)"
    [ -s "$shot" ] || die "no screenshot written: $shot"
}

log "== running the bench (13 headless runs, ~2min)"
run "$sd_stock" "$SHOTS/boot-stock.png"
run "$sd_ours"  "$SHOTS/boot-ours.png"
run "$sd_stock" "$SHOTS/nmi-stock.png" "$TRIGGER_BIN"
run "$sd_ours"  "$SHOTS/nmi-ours.png"  "$TRIGGER_BIN"
run "$sd_stock" "$SHOTS/copper-stock.png" "$COPPER_BIN"
run "$sd_ours"  "$SHOTS/button-ours.png" "" nmi
run_reset "$SHOTS/reset-ours.png"      "$SHOTS/reset-ours.log"
run_reset "$SHOTS/second-nmi-ours.png" "$SHOTS/second-nmi-ours.log" second
run_noreset "$SHOTS/press1-ours.png" "$SHOTS/press1-ours.log"
run_noreset "$SHOTS/press2-ours.png" "$SHOTS/press2-ours.log" second
run_poll "$sd_stock" "$SHOTS/poll-stock.png"
run_poll "$sd_ours"  "$SHOTS/poll-nodbg.png"
run_poll "$sd_ours"  "$SHOTS/poll-stub.png" keys

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

# T7 — a second M1 press after a SOFT RESET must re-initialise, not decline.
#
# Issue #26, reproduced headless on 2026-08-07 and traced to upstream's 2020
# NMI dispatch: on a button press, a matching magic number and build time in
# MAIN_BANK plus "no debuggee running" was read as "the debugger is already
# executing", and the NMI declined. A soft reset does not clear RAM, so after
# one the same evidence means something else — the image is STALE and NextZXOS
# is executing. The decline also leaks a bank: the entry path has already
# paged MAIN_BANK into slot 7 and the immediate return never restores it, so
# the machine came back with the debugger's bank at 0xE000 and hung shortly
# after. The fix reads slot_backup.slot7 — the bank slot 7 held at the moment
# of THIS press, saved by the entry path — which is MAIN_BANK only when the
# debugger itself was executing; anything else re-runs init_main_bank.
#
# The comparisons, and why each side of them exists:
#   - both runs shoot at the SAME frame, after the second boot; run 7 has no
#     second press, so the pair differ ONLY by what that press did. Declined
#     (the pre-fix ROM) they are byte-identical; re-initialised, ~90% apart.
#   - the takeover must also LOOK LIKE run 6's stub screen, which excludes a
#     crash painting garbage — the T6 lesson that a difference measure does
#     not know what it is looking at.
#   - two preconditions guard the harness half. The queued second NMI is
#     counted out of jnext's own log, because a jnext that dropped the first
#     press would make run 8 a FIRST press — a takeover that passes the diff
#     while never touching the path under test. And run 7 must differ from
#     the stub screen at all, or the R key never reset the machine and the
#     "decline" being judged never had a reset to survive.
nmi_count=$(grep -c 'Delayed NMI button' "$SHOTS/second-nmi-ours.log" || true)
reset_pct=$(diff_pct "$SHOTS/button-ours.png" "$SHOTS/reset-ours.png")
second_pct=$(diff_pct "$SHOTS/reset-ours.png" "$SHOTS/second-nmi-ours.png")
second_vs_stub_pct=$(diff_pct "$SHOTS/button-ours.png" "$SHOTS/second-nmi-ours.png")
if [ "$nmi_count" -ne 2 ]; then
    fail "T7 harness: jnext delivered $nmi_count of 2 queued NMI presses, so the sequence never ran"
elif ! took_over "$reset_pct"; then
    fail "T7 harness: the R key did not reset the machine ($reset_pct% vs the stub screen); nothing was judged"
elif ! took_over "$second_pct"; then
    fail "T7 a second NMI after a soft reset was DECLINED ($second_pct% changed): issue #26 is back"
elif took_over "$second_vs_stub_pct"; then
    fail "T7 the second NMI painted something unlike the stub's own screen ($second_vs_stub_pct% differs): see second-nmi-ours.png"
else
    pass "T7 a second NMI after a soft reset re-initialises the debugger ($second_pct% repainted)"
fi

# T8 — a second M1 press with NO reset must be DECLINED, and the stub must still
# be alive afterwards. Issue #36.
#
# THIS IS T7'S OTHER ARM, and it is the branch M2 edits first. The dispatch keys
# on the bank slot 7 held at the press: not MAIN_BANK => the debugger was not
# executing, re-initialise (T7); MAIN_BANK => it was, decline (here). Teaching
# nmi66h to accept a software cause reuses the same MF.nmi_slot7 byte, so a
# regression that sent EVERY press to init_main_bank would destroy live debug
# sessions — and T7 would still pass, because T7's arm would keep working.
#
# "NOTHING CHANGED" IS ALSO WHAT A WEDGED MACHINE LOOKS LIKE. The stub's screen
# is already painted and a hung Z80 repaints nothing, which is ERRORS.md's "the
# screen changed is not the stub took over" in mirror image. So the decline is
# judged on two things at once, and neither alone is enough.
#
# The liveness half is run-no-hang.sh's N1/N2 trick: press a key the stub polls
# and read the BORDER. main_loop polls the keyboard and check_key_border turns
# slow_border_change off, which blacks the border AND stops change_border_color
# touching it again — so black is stable rather than caught mid-cycle. A stub
# that never reached main_loop leaves whatever the cycle last wrote. That
# discriminator is not theoretical: it is what diagnosed a genuinely wedged stub
# on hardware on 2026-08-09, yellow and not cycling with B and R both dead.
#
# THE "3" PRESS IS STRUCTURALLY NECESSARY AND IS NOT DECORATION. Measured, not
# reasoned: against a scratch ROM whose dispatch sends every press to
# init_main_bank, a re-initialisation followed by the liveness key reproduces the
# reference screen EXACTLY — the re-init resets slow_border_change, "B" then
# turns it off again, and the two runs come out byte-identical. A check with the
# liveness key alone would go green against the very regression it exists to
# catch. So some state has to be moved away from its default BEFORE the second
# press, and in the UART build the joy-port selector is the one a keypress can
# reach: main_bank_entry sets it back to 2, so a re-init reverts the line and a
# decline leaves it. Measured over the three ROMs, same choreography:
#
#   shipped ROM      row 6 "No joystick port used."  border black  0.00% (identical)
#   every-press-init row 6 "Using Joy 2 (right)"     border black  0.33%
#   decline spins    row 6 "No joystick port used."  border red    40.03%
#
# The row is READ rather than compared, because "these two differ" is not "this
# one is right" — ERRORS.md, mfselect's M9 — and because reading it is what says
# the "3" press landed at all. Without that the discriminator would vanish
# silently and a re-init would pass. The reader is validated inside each shot
# first (row 12 is "R = Reset", drawn by the same code in the same font), so a
# broken reader reports itself instead of failing the subject.
#
# The byte comparison is the broad net that catches everything the two named
# faults do not: an error painted in the red area, a corrupted line, anything at
# all the second press might have changed.
#
# AND FOR THE WEDGE IT IS THE STRUCTURAL NET, WHICH THE BORDER IS NOT. A wedged
# stub freezes the border wherever change_border_color last left it, and that
# cycles 0..7 (transport_uart.asm), so about one run in eight it freezes on
# BLACK and the WEDGED branch below does not fire. The byte comparison still
# does, phase-independently: the reference's "B" repaints row 13 from
# `B = Border off` to `B = Border on` and the wedged run never does, which is
# 104 pixels, measured, all of them in that one character row. So the border is
# the branch that NAMES a wedge and the comparison is the one that CATCHES it.
#
# T8's discriminator is UART-ONLY, and that is a limit on where this check can be
# pointed rather than on what it covers. uart_joyport_selection, its key handler
# and its row all sit under IF ROM_VARIANT == ROM_VARIANT_UART (main.asm:80-83,
# ui.asm, data_const.asm). `make test` builds the UART ROM and src/mf_rom.asm —
# the routine under test — is common to both, so the coverage claim holds; but
# aiming T8 at a WiFi ROM would need different state to move before the press.
#
# THE ORDER OF THE THREE EVENTS IS ASSERTED, NOT READ OFF THE CONSTANTS, AND
# THAT GUARD WAS EARNED. Found while checking that the preconditions fire: with
# NORESET_NMI_FRAME moved to 1500 — past the screenshot at 1466 — the whole
# bench came out 8/8, having pressed the button after the picture was taken. The
# NMI-count precondition below says both presses were DELIVERED and says nothing
# about when, so on its own it lets this check pass having tested nothing. Same
# shape as W6's window (CLAUDE.md §4c): get an edge wrong and it fails GREEN.
# Two of the three edges have runtime preconditions instead — a joy-port key
# that lands before the stub is up is not polled, and a "B" that lands after the
# picture leaves the border uncycled — so what has to be static is only the
# chain itself. Its middle link matters as much as the outer ones: a joy-port
# press AFTER the second one would be re-applied by a re-initialisation and hide
# it, and a "B" BEFORE it would answer a liveness question about the wrong
# moment. Frames are emulated, not wall clock, so unlike W6 this really is by
# construction once the constants are in order.
noreset_nmis1=$(grep -c 'Delayed NMI button' "$SHOTS/press1-ours.log" || true)
noreset_nmis2=$(grep -c 'Delayed NMI button' "$SHOTS/press2-ours.log" || true)
ref_ctl=$(read_row "$SHOTS/press1-ours.png" "$CONTROL_ROW" || true)
sub_ctl=$(read_row "$SHOTS/press2-ours.png" "$CONTROL_ROW" || true)
ref_joy=$(read_row "$SHOTS/press1-ours.png" "$NOJOY_ROW" || true)
sub_joy=$(read_row "$SHOTS/press2-ours.png" "$NOJOY_ROW" || true)
# stderr is deliberately not swallowed: border_rgb refuses when the four corners
# disagree, and that message says which shot and which colours.
ref_border=$(border_rgb "$SHOTS/press1-ours.png" || true)
sub_border=$(border_rgb "$SHOTS/press2-ours.png" || true)
noreset_pct=$(diff_pct "$SHOTS/press1-ours.png" "$SHOTS/press2-ours.png")
if [ "$NORESET_JOY_FRAME" -ge "$NORESET_NMI_FRAME" ] || [ "$NORESET_NMI_FRAME" -ge "$NORESET_KEY_FRAME" ]; then
    fail "T8 harness: the second press is not scheduled between the two keys, so nothing here was judged"
elif [ "$noreset_nmis1" -ne 1 ] || [ "$noreset_nmis2" -ne 2 ]; then
    fail "T8 harness: jnext delivered $noreset_nmis1 of 1 and $noreset_nmis2 of 2 presses, so the sequence never ran"
elif [ "$ref_ctl" != "$CONTROL_TEXT" ] || [ "$sub_ctl" != "$CONTROL_TEXT" ] \
     || [ -z "$ref_border" ] || [ -z "$sub_border" ]; then
    # Both readings, together: a border sample that refused would otherwise
    # arrive at the WEDGED branch below as an empty string and be reported as a
    # wedged stub, which is a reader fault wearing a finding's name.
    fail "T8 harness: a screenshot could not be read — its control row or its border, so nothing was judged"
elif [ "$ref_joy" != "$NOJOY_TEXT" ]; then
    fail "T8 harness: the joy-port key never landed, so a re-initialisation would leave nothing to see"
elif [ "$ref_border" != "$BORDER_BLACK" ]; then
    fail "T8 harness: the 'B' key never reached the one-press run, so liveness could not be judged"
elif [ "$sub_border" != "$BORDER_BLACK" ]; then
    fail "T8 the stub is WEDGED after a second press: border $sub_border, not black, so 'B' was never polled"
elif [ "$sub_joy" != "$NOJOY_TEXT" ]; then
    fail "T8 a second press RE-INITIALISED the debugger instead of declining: the joy-port line was reset"
elif ! cmp -s "$SHOTS/press1-ours.png" "$SHOTS/press2-ours.png"; then
    fail "T8 a second press with no reset changed the screen ($noreset_pct% of pixels): see press2-ours.png"
else
    pass "T8 a second M1 press with no reset is declined and the stub is still alive (border $sub_border)"
fi

# T9 — THE ASYNCHRONOUS-BREAK POLL, running ~50 times a second. Issue #22, M2.
#
# This is the first check anywhere that executes the software-cause path in
# nmi66h, and it executes it about 400 times per run rather than once, which is
# the point: everything the poll touches it must put back, and a leak that is
# survivable once is fatal fifty times a second.
#
# THE FIXTURE IS THE DETECTOR, because a healthy poll is by design INVISIBLE and
# there is nothing about one to photograph. test/copper_poll.asm installs the
# two Copper instructions — in the DEBUGGED PROGRAM, which is where M2 decided
# they belong — puts a known bank in MMU slot 7 and spins reading NR 0x57 back.
# Green while every reading is the probe bank; red, LATCHED, the first time one
# is not, so a bench sampling the border at one frame cannot catch a good moment
# of a broken run.
#
# WHAT SAT UNDERNEATH THIS WAS A DEFECT IN THE HARNESS, NOT IN THE MACHINE, AND
# THE FIRST DIAGNOSIS OF IT WAS WRONG. It was recorded on 2026-08-10 as "a
# software Multiface NMI does not reliably put the CPU back on the instruction it
# interrupted", pre-existing, cause unresolved, and this fixture was padded with
# sixteen NOPs around it.
#
# It is jnext's `--inject`. `Emulator::inject_binary` (src/core/emulator.cpp:6683)
# sets PC, SP and IFF1/IFF2 and never clears the CPU's HALTED flag; NextZXOS idles
# in a `halt`, so an injected program starts with `halted = 1` and, running DI'd,
# has no way to clear it. The first NMI then takes jnext's
# `z80.halted ? pc+1 : pc` branch (src/cpu/z80_cpu.cpp:636) and captures the
# interrupted PC PLUS ONE — so exactly ONE return, the first, lands a byte late,
# and sixteen NOPs were simply wide enough to absorb it.
#
# Measured 2026-08-11 by removal, on `main`'s own ROM: with `ei : halt : di` in
# the fixture and NO padding, a `jr $` under this Copper list is returned to
# 402 times out of 402; without it, the same loop derails on its first NMI. The
# padding is gone. Nothing about the stub, upstream's handler or the Next's NMI
# path was ever implicated — see copper_poll.asm, and MEMORY.md 2026-08-11.
#
# THREE RUNS, AND EACH ANSWERS SOMETHING THE OTHERS CANNOT:
#
#   11  poll-stock   THE PRECONDITION, and it is here for exactly T3's reason.
#                    The same fixture against the SD image's own Multiface ROM
#                    must produce a takeover, which is what says the Copper list
#                    really raises the NMI in this run. Without it, a fixture
#                    that installed nothing would leave the border green and
#                    runs 12 and 13 would pass having polled nothing at all.
#   12  poll-nodbg   THE TRANSPARENCY VERDICT. No button is pressed, so no
#                    debugger ever exists: every poll pages MAIN_BANK in, finds
#                    somebody else's bytes where the magic should be, and has to
#                    decline AND PUT SLOT 7 BACK. That is issue #26's defect on
#                    a 50 Hz timer, and this is the only run in which the
#                    interrupted program cares what slot 7 holds — in run 13 the
#                    debugger is executing and slot 7 is legitimately MAIN_BANK,
#                    so a missing restore there would be invisible.
#   13  poll-stub    THE LIVENESS VERDICT. The stub is brought up and then
#                    polled thousands of times while STOPPED, which is the
#                    prgm_state decline. Judged two ways at once, because
#                    "nothing changed" is also what a wedged machine looks like
#                    (T8's lesson): the screen must be byte-identical to T8's
#                    one-press run, and the border must be BLACK, which only a
#                    stub that reached main_loop and polled "B" can produce.
#
# BYTE-IDENTITY IS AVAILABLE HERE BECAUSE RUN 13 USES T8'S SCHEDULE UNCHANGED —
# same boot frame, same "3", same "B", same shot frame — so the pair differ only
# by the Copper list. It is the broad net the two named verdicts are not: an
# error painted in the stub's red area, a corrupted line, anything at all the
# ~400 polls might have disturbed.
#
# WHAT T9 DOES NOT COVER, and it is worth being exact.
#
#   * IT NEVER BREAKS IN. No client is attached, so transport_poll_traffic
#     answers "quiet" every time and the break half of mf_nmi_poll is not
#     executed here at all — that is W8, in make test-dzrp-stub.
#   * IT DOES NOT DISCRIMINATE THE prgm_state TEST, because with no traffic a
#     build that omitted it would decline anyway.
#   * IT DOES NOT COVER THE NextREG SELECT LATCH RESTORE, and that was found by
#     building the red-first and watching it come out GREEN. The poll's own
#     .save_slot7_page_in writes port 0x243B with 0x57, so a build with the
#     restore deleted leaves the latch selecting exactly the register this
#     fixture reads. Nothing here covers it; W7 covers the button path's
#     equivalent byte and the poll path's has no check.
#   * THE MIS-RETURN ABOVE IS WORKED AROUND, NOT MEASURED. A check for it would
#     be a check on `main`'s behaviour as much as on M2's.
#
# What it IS shown red against is a build with the slot-7 restore removed: run 12
# goes red at the border. Measured, with the shipped ROM green three times.
poll_stock_pct=$(diff_pct "$SHOTS/boot-stock.png" "$SHOTS/poll-stock.png")
poll_nodbg_border=$(border_rgb "$SHOTS/poll-nodbg.png" || true)
poll_stub_border=$(border_rgb "$SHOTS/poll-stub.png" || true)
poll_stub_pct=$(diff_pct "$SHOTS/press1-ours.png" "$SHOTS/poll-stub.png")
if ! took_over "$poll_stock_pct"; then
    fail "T9 PRECONDITION: the poll fixture's Copper list raised no NMI ($poll_stock_pct% on the stock ROM)"
elif [ -z "$poll_nodbg_border" ] || [ -z "$poll_stub_border" ]; then
    fail "T9 harness: a screenshot's border could not be read, so nothing was judged"
elif [ "$poll_nodbg_border" = "$BORDER_RED" ]; then
    fail "T9 the poll did not give MMU slot 7 back to the interrupted program (issue #26 on a timer)"
elif [ "$poll_nodbg_border" != "$BORDER_GREEN" ]; then
    fail "T9 harness: the fixture never ran (border $poll_nodbg_border, wanted green), so nothing was judged"
elif [ "$poll_stub_border" != "$BORDER_BLACK" ]; then
    fail "T9 the stub is WEDGED after being polled while stopped: border $poll_stub_border, so 'B' was never polled"
elif ! cmp -s "$SHOTS/press1-ours.png" "$SHOTS/poll-stub.png"; then
    fail "T9 polling the stopped stub changed its screen ($poll_stub_pct% of pixels): see poll-stub.png"
else
    pass "T9 a Copper poll every frame leaves slot 7 alone and the stopped stub untouched and alive"
fi

log ""
# Derived, not hardcoded: the summary said "5/5" for a while after a sixth
# check was added, which is a small lie in exactly the place a reader trusts.
checks=9
if [ "$failures" -eq 0 ]; then
    verdict="$checks/$checks checks passed"
else
    verdict="$failures of $checks checks FAILED"
fi
log "$verdict  (screenshots in $SHOTS)"

# Picked up by the SessionStart hook, so a new session knows where it stands.
printf '%s\n' "$verdict" > "$OUT/last-test.txt"

exit "$((failures > 0 ? 1 : 0))"
