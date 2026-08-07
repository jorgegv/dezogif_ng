#!/usr/bin/env bash
#
# Headless bench for the .mfinstall dot command (issue #21), run by
# `make test-mfinstall`.
#
#   I1  `.mfinstall --load wifi` succeeds, and the identity block read back
#       THROUGH CONFIG MODE says WIFI — asserted in two halves, because the two
#       are different claims: the run says "Live now", and a run whose LAST act
#       was an install reads 0x1FE0 back out of the live ROM and names the
#       variant and build it finds there. Only the second half is evidence
#       about the ROM.
#   I2  after I1, an M1 button NMI brings up THE STUB'S OWN SCREEN and not the
#       stock Multiface monitor. THE STRONGEST CHECK HERE, and it answers issue
#       #21's open question 3 in the emulator: taylorza's worked example ends
#       with a soft reset (`NEXTREG 2,1`) — what they did, not a stated
#       requirement — and .mfinstall deliberately issues none. If the bytes
#       were not LIVE this goes red.
#   I3  `--unload` puts the original back: the same NMI then brings up the stock
#       monitor. Its second clause is the control — see the note at I3.
#   I4  `--load wifi` twice: the second is a no-op and says so, which is what
#       makes `--auto` from AUTOEXEC.BAS safe to run on every boot.
#   I5  `--auto` obeys /mfselect/mfinstall.yml — `install: wifi` behaves as
#       `--load wifi`, `install: none` installs nothing. The wifi half uses the
#       DEFAULT FILE THE BUILD SHIPS, so the config a user copies to the card is
#       one a run has parsed rather than one nothing has read.
#   I6  THE CONTROL FOR THE WHOLE BENCH: the SD card's machines/next/enNextMf.rom
#       is byte-identical afterwards. Without it every check above is equally
#       satisfied by a tool that simply wrote the file, which is mfselect's job
#       and not this one's. This is what says the mechanism was CONFIG MODE.
#   I7  THE CONTROL THAT ATTRIBUTES THE FIX TO ONE CONSTANT: a probe built with
#       DIVMMC_OFF=0 — DivMMC left mapped for the window, which is the ordinary
#       context a dot command runs in — must report the write BLOCKED, and an
#       NMI after it must bring up the stock monitor rather than the stub.
#   I8  THE ROUND TRIP: `--configure uart` writes /mfselect/mfinstall.yml and
#       `--auto` then reads it back and installs the UART stub. UART, not wifi,
#       because wifi is the shipped default and a --configure that did nothing
#       would pass on it.
#   I9  what `--configure wifi` writes is BYTE-IDENTICAL to the default the
#       build ships, and it says which default it set. Two separate sources — a
#       checked-in file the Makefile copies, and C that composes the same line —
#       and no screenshot can see the difference between them.
#
# WHY THE STUB'S SCREEN CARRIES AN ESP ERROR IN I2 AND I5, and why that is not
# the subject: no --esp is passed, so there is no emulated module and the WiFi
# build's AT chain times out and reports it. Passing --esp would bind a host TCP
# port and drag this bench into the lock every other port-binding bench needs,
# to make a screen that is prettier and no more conclusive. What I2 asserts is a
# TAKEOVER, which a failed AT chain does not affect.
#
# The dot command must run under a booted NextZXOS — every file access is the
# esxdos API, and a NEX injected at frame 0 hangs on the first RST $08. Hence the
# keypress choreography: boot to the command line (space/down/enter, as jnext's
# own regression suite does it) and type the command name.
#
# IT SAYS NOTHING ABOUT HARDWARE. jnext's config-mode model cites the same VHDL
# lines this design was read from, so agreement between them is not independent
# evidence — and this project has twice been bitten by an emulator whose values
# sat on the safe side of ours. See doc/CONFIG-MODE-ROM-REPLACEMENT.md.
set -euo pipefail

JNEXT=${JNEXT:-$HOME/src/spectrum/jnext/build/gui-release/jnext}
SD_IMAGE=${SD_IMAGE:-$HOME/.jnext/sdcard/cspect-next-1gb-fixed.img}
OUT=${OUT:-build}
DOT=${DOT:-$OUT/mfinstall}
ROM_UART=${ROM_UART:-$OUT/enNextMf.rom}
SUM_UART=${SUM_UART:-$OUT/dezouart.sum}
ROM_WIFI=${ROM_WIFI:-$OUT/enNextMf-wifi.rom}
SUM_WIFI=${SUM_WIFI:-$OUT/dezowifi.sum}
DOT_DMOFF0=${DOT_DMOFF0:-$OUT/mfinstall-dmoff0}
# The config file `make mfinstall` SHIPS, not one this script writes: see I5.
CONF_WIFI=${CONF_WIFI:-$OUT/deploy/mfselect/mfinstall.yml}
ROMSUM=${ROMSUM:-tools/romsum.py}
SCREENDIFF=${SCREENDIFF:-test/screen-diff.py}
SCREENTEXT=${SCREENTEXT:-test/screen-text.py}

MF_PATH='::/machines/next/enNextMf.rom'
FONT_ROM='::/machines/next/48.rom'
RUN_TIMEOUT=400

# --- frame choreography, all of it measured during calibration -------------
#
# space/down/enter at 400/470/500 reaches the NextZXOS command line, as jnext's
# own regression suite does it. A command is then typed one key at a time from
# CMD_START and given SETTLE frames to finish; `--load wifi` is the slowest,
# because it CRCs 8192 bytes bitwise before writing anything, and it completed
# inside 700 in every calibration run. The NMI lands after all of that, and the
# capture NMI_PAINT frames later — a budget sized for the WiFi build's AT chain
# timing out against an emulator with no ESP, which is far slower to paint than
# the stock monitor.
CMD_START=560
KEY_STEP=14
SETTLE=700
NMI_PAINT=1100

# How much of the screen must change before this bench calls it a takeover. The
# same 25% run-headless.sh uses, and for the same reason: NextZXOS idling moves
# 0.01% of the screen and treating "not byte-identical" as a takeover produced a
# false PASS there once already. Measured here: 97% for the stub, 95% unlike the
# stock monitor.
TAKEOVER_PCT=25

# ...and a SEPARATE, LOWER one for the stock Multiface monitor, which is not a
# second opinion about the same thing. The monitor draws a small window on a
# cleared screen, so against a nearly-empty command line it moves 17% — where
# against the NextZXOS WELCOME screen, which is what run-headless.sh's T3
# compares, it moves 91%. Judging it at 25% would fail a control that is working
# perfectly. It is only ever used to prove the NMI FIRED.
MENU_PCT=10

# Shared jnext teardown — issue #17. Defines functions and nothing else, so it
# cannot disturb the `set -euo pipefail` above or the trap below.
# shellcheck source=test/bench-jnext.sh
. "$(dirname "$0")/bench-jnext.sh"

# WHAT ISSUE #17 MEANS HERE, AND WHAT IT DOES NOT. This bench passes no --esp,
# so its runs never bind port 11000 and it takes no bench lock; the "a survivor
# answers the next agent's client" failure cannot originate here. What CAN is an
# emulator left running after a `timeout` fired or the script was interrupted —
# competing for the machine and holding a gigabyte working image open.
#
# THE WORKING IMAGES ARE REMOVED, and the list is declared HERE — above the trap
# and above the first copy. `cp --reflink=auto` is free on a filesystem that
# supports reflinks and a full gigabyte on one that does not, silently; this
# bench makes eight of them. About 22 GB of exactly these abandoned copies filled
# the /tmp quota on 2026-08-04 and took the shell down mid-session — see
# ERRORS.md, and test/run-esp.sh, which carries the whole reasoning and the four
# wrong attempts it took to get the trap right. Under `set -u` a variable the
# handler has never seen aborts it before it reaches the `rm`, hence an array
# that exists from the start and is empty rather than unset.
#
# They are removed at EXIT and not after each run, deliberately: I6 reads a file
# back OFF an image after its emulator has gone.
work_images=()

current_image=""
cleanup() {
    # Unlinked BEFORE departure is confirmed, because bench_await_departure can
    # `exit` and an exit that skipped this `rm` would reintroduce the leak. It
    # matches on the command line, not on the file, so removing first is safe.
    if [ "${#work_images[@]}" -gt 0 ]; then
        rm -f "${work_images[@]}"
    fi
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
checks=0
log()  { printf '%s\n' "$*"; }
# Derived, never hardcoded: a count written by hand keeps saying 5/5 after a
# sixth check is added, which is a lie in the one line a reader trusts.
pass() { printf 'PASS  %s\n' "$*"; checks=$((checks + 1)); }
fail() { printf 'FAIL  %s\n' "$*"; failures=$((failures + 1)); checks=$((checks + 1)); }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ -x "$JNEXT" ]    || die "jnext binary not found or not executable: $JNEXT"
[ -f "$SD_IMAGE" ] || die "SD card image not found: $SD_IMAGE"
[ -s "$DOT" ]      || die "mfinstall not built: $DOT (run 'make mfinstall')"
[ -s "$DOT_DMOFF0" ] || die "the DIVMMC_OFF=0 probe is not built: $DOT_DMOFF0 (run 'make test-mfinstall')"
[ -s "$CONF_WIFI" ] || die "the shipped config is not there: $CONF_WIFI (run 'make mfinstall')"
[ -f "$ROM_UART" ] || die "UART ROM not built: $ROM_UART (run 'make mfinstall')"
[ -f "$SUM_UART" ] || die "UART checksum not built: $SUM_UART (run 'make mfinstall')"
[ -f "$ROM_WIFI" ] || die "WiFi ROM not built: $ROM_WIFI (run 'make mfinstall')"
[ -f "$SUM_WIFI" ] || die "WiFi checksum not built: $SUM_WIFI (run 'make mfinstall')"
[ -f "$SCREENDIFF" ] || die "screen-diff helper not found: $SCREENDIFF"
[ -f "$SCREENTEXT" ] || die "screen-text helper not found: $SCREENTEXT"
command -v mcopy >/dev/null || die "mtools (mcopy) is required"
python3 -c 'import PIL' 2>/dev/null || die "python3 Pillow is required to read screenshots"

# I2, I3 and I5 all need a headless M1 button press, which arrived in jnext
# 0.99.118. NOT `--help | grep -q`, which reports the OPPOSITE of the truth when
# the flag is present — see bench_jnext_supports and ERRORS.md.
bench_jnext_supports "$JNEXT" '--delayed-nmi' \
    || die "this jnext has no --delayed-nmi (need >= 0.99.118); rebuild it — I2, I3 and I5 cannot run without it"

# Partition offset from the MBR rather than assumed, as the other benches do.
part_lba=$(od -An -tu4 -j 454 -N 4 "$SD_IMAGE" | tr -d ' ')
[ -n "$part_lba" ] && [ "$part_lba" -gt 0 ] || die "cannot read partition table"
part_off=$((part_lba * 512))

mkdir -p "$OUT/screenshots"
shots=$OUT/screenshots

# The stock Multiface ROM and the ROM font, both taken off the reference image
# rather than committed: the font is what screen-text.py decodes the dot
# command's own output with, and the stock ROM is I6's reference.
stock=$OUT/mfinstall-stock.rom
mcopy -o -n -i "$SD_IMAGE@@$part_off" "$MF_PATH" "$stock" \
    || die "no stock MF ROM on the reference image"
font=$OUT/mfinstall-font.rom
mcopy -o -n -i "$SD_IMAGE@@$part_off" "$FONT_ROM" "$font" \
    || die "no 48.rom on the reference image; screen-text.py needs its font"
python3 "$ROMSUM" "$stock" > "$OUT/mfinstall-stock.sum"

wifi_sum=$(cat "$SUM_WIFI")
stock_sum=$(cat "$OUT/mfinstall-stock.sum")
[ "$stock_sum" != "$wifi_sum" ] \
    || die "the stock and dezogif_ng ROMs have the same CRC; the bench cannot tell them apart"

# --- helpers ---------------------------------------------------------------

# Emit --delayed-keypress-frames flags spelling out a string, then ENTER.
# '/' is SYMBOL SHIFT + V and '-' is SYMBOL SHIFT + J on a Spectrum keyboard;
# jnext takes both as sym+<char>, and neither is a single-character key name.
type_keys() {
    local frame=$1 str=$2 i c k
    for (( i = 0; i < ${#str}; i++ )); do
        c=${str:i:1}
        case "$c" in
            /)   k="sym+v" ;;
            -)   k="sym+j" ;;
            " ") k="space" ;;
            *)   k="$c" ;;
        esac
        printf -- '--delayed-keypress-frames %d %s ' "$frame" "$k"
        frame=$((frame + KEY_STEP))
    done
    printf -- '--delayed-keypress-frames %d enter ' "$frame"
}

# prepare_image <image> [yml-install-value]
#
# The card as `make mfinstall` leaves it plus what mfselect captures on its first
# run: both of our ROMs, both .sums, the dot command in /dot/, and the STOCK ROM
# as original.rom with a .sum beside it — which is the state --unload needs and
# the state a real user is in. machines/next/enNextMf.rom is left exactly as the
# reference image has it, which is what makes I6 meaningful.
prepare_image() {
    local image=$1 yml=${2:-} dot=${3:-$DOT}
    # Registered BEFORE the copy, for the reason the trap is armed before it: an
    # interrupt during the copy is the case that once left a 777 MB partial image
    # behind, and a name recorded afterwards is a name a handler firing during
    # the copy has never seen.
    work_images+=("$image")
    cp --reflink=auto -f "$SD_IMAGE" "$image"
    mmd -i "$image@@$part_off" ::/mfselect
    mcopy -o -i "$image@@$part_off" "$ROM_WIFI" ::/mfselect/dezowifi.rom
    mcopy -o -i "$image@@$part_off" "$SUM_WIFI" ::/mfselect/dezowifi.sum
    mcopy -o -i "$image@@$part_off" "$ROM_UART" ::/mfselect/dezouart.rom
    mcopy -o -i "$image@@$part_off" "$SUM_UART" ::/mfselect/dezouart.sum
    mcopy -o -i "$image@@$part_off" "$stock"    ::/mfselect/original.rom
    mcopy -o -i "$image@@$part_off" "$OUT/mfinstall-stock.sum" ::/mfselect/original.sum
    mcopy -o -i "$image@@$part_off" "$dot"      ::/dot/mfinstall
    # THE wifi CASE USES THE FILE THE BUILD SHIPS, and that is not a detail.
    # `make mfinstall` puts a default mfinstall.yml in build/deploy/mfselect/
    # for the user to copy onto the card, so the file a run parses here is
    # byte-for-byte the file they will be running — CRLF, comment block and
    # all. A generated `install: wifi` would leave the shipped one checked by
    # nothing, which is how a preamble long enough to push the key past
    # read_config()'s 511-byte window would ship green. `none` is still
    # generated: nothing ships a file saying that.
    if [ "$yml" = wifi ]; then
        mcopy -o -i "$image@@$part_off" "$CONF_WIFI" ::/mfselect/mfinstall.yml
    elif [ -n "$yml" ]; then
        printf 'install: %s\n' "$yml" > "$OUT/mfinstall-conf.yml"
        mcopy -o -i "$image@@$part_off" "$OUT/mfinstall-conf.yml" ::/mfselect/mfinstall.yml
    fi
    return 0
}

# run_dot <image> <shot> <nmi:yes|no> <command>...
#
# Types each command in turn, gives each SETTLE frames to finish, then optionally
# presses the M1 button and captures NMI_PAINT frames later.
run_dot() {
    local image=$1 shot=$2 want_nmi=$3
    shift 3

    local keys="" frame=$CMD_START cmd
    for cmd in "$@"; do
        keys="$keys $(type_keys "$frame" "$cmd")"
        frame=$(( frame + ${#cmd} * KEY_STEP + SETTLE ))
    done

    local nmiarg="" shot_frame=$frame
    if [ "$want_nmi" = yes ]; then
        nmiarg="--delayed-nmi-frames $frame nmi"
        shot_frame=$(( frame + NMI_PAINT ))
    fi

    rm -f "$shot"
    current_image=$image
    local rc=0
    # shellcheck disable=SC2086
    timeout "$RUN_TIMEOUT" "$JNEXT" --headless --machine next \
        --sdcard "$image" --rtc "2026-01-01 12:00:00" \
        --delayed-keypress-frames 400 space \
        --delayed-keypress-frames 470 down \
        --delayed-keypress-frames 500 enter \
        $keys $nmiarg \
        --delayed-screenshot "$shot" \
        --delayed-screenshot-frames "$shot_frame" \
        --delayed-automatic-exit-frames $(( shot_frame + 60 )) \
        >/dev/null 2>&1 || rc=$?

    # BEFORE anything is read off the image, and before the next run starts.
    # `timeout` returning is not jnext having exited — on a timeout it has only
    # been sent a SIGTERM, and an emulator still holding this image open is one
    # that may still be writing to it. Issue #17; see test/bench-jnext.sh.
    bench_await_departure "$image"
    current_image=""

    [ "$rc" -eq 0 ] || die "jnext run failed or timed out (image=$image)"
    [ -s "$shot" ]  || die "no screenshot written: $shot"
}

diff_pct() { python3 "$SCREENDIFF" "$1" "$2"; }
over()     { awk -v pct="$1" -v thr="$2" 'BEGIN { exit !(pct >= thr) }'; }

# screen_has <shot> <text> — is <text> on any row of <shot>?
#
# A READING, NOT A COMPARISON, and this project has paid for the difference:
# mfselect's M9 compared two runs, passed, and a reviewer then SWAPPED the two
# labels and it passed again (ERRORS.md). "These two differ" is not "this one is
# right". Every row is tried because the dot command prints wherever NextZXOS's
# cursor happens to be, which nothing here controls; rows screen-text.py refuses
# (more than two colours, or an unreadable glyph) are skipped rather than fatal,
# since most of this screen is not text at all.
screen_has() {
    local shot=$1 want=$2 r txt
    for r in $(seq 0 23); do
        txt=$(python3 "$SCREENTEXT" --font "$font" "$shot" "$r" 2>/dev/null) || continue
        case "$txt" in *"$want"*) return 0 ;; esac
    done
    return 1
}

log "== mfinstall bench (12 headless runs, ~6min)"
log "   stock MF ROM CRC $stock_sum, dezogif_ng WiFi $wifi_sum"

# --- run 1: the command line, with no NMI. The baseline the stock monitor is
#            judged against, and it differs from run 2 ONLY by the NMI ------
img1=$OUT/sd-mfinstall-1.img
prepare_image "$img1"
run_dot "$img1" "$shots/mfinstall-cmdline.png" no ".mfinstall --help"

# --- run 2: the same, plus the M1 button. The stock Multiface monitor ------
img2=$OUT/sd-mfinstall-2.img
prepare_image "$img2"
run_dot "$img2" "$shots/mfinstall-stock-nmi.png" yes ".mfinstall --help"

# --- run 3: install the WiFi ROM, and stop there ---------------------------
img3=$OUT/sd-mfinstall-3.img
prepare_image "$img3"
run_dot "$img3" "$shots/mfinstall-load-wifi.png" no ".mfinstall --load wifi"

# --- run 4: install it, then press the M1 button ---------------------------
img4=$OUT/sd-mfinstall-4.img
prepare_image "$img4"
run_dot "$img4" "$shots/mfinstall-wifi-nmi.png" yes ".mfinstall --load wifi"

# --- run 5: install it twice -----------------------------------------------
img5=$OUT/sd-mfinstall-5.img
prepare_image "$img5"
run_dot "$img5" "$shots/mfinstall-twice.png" no \
    ".mfinstall --load wifi" ".mfinstall --load wifi"

# --- run 6: install it, put the original back, then press the button -------
img6=$OUT/sd-mfinstall-6.img
prepare_image "$img6"
run_dot "$img6" "$shots/mfinstall-unload-nmi.png" yes \
    ".mfinstall --load wifi" ".mfinstall --unload"

# --- runs 7 and 8: --auto, once for each answer the config file can give ---
img7=$OUT/sd-mfinstall-7.img
prepare_image "$img7" wifi
run_dot "$img7" "$shots/mfinstall-auto-wifi.png" yes ".mfinstall --auto"

img8=$OUT/sd-mfinstall-8.img
prepare_image "$img8" none
run_dot "$img8" "$shots/mfinstall-auto-none.png" yes ".mfinstall --auto"

# --- runs 9 and 10: the DIVMMC_OFF=0 probe, once for each half of I7 -------
#
# Two runs and not one, because the two halves cannot be read off one picture:
# the message is printed to the command line and the M1 button then paints over
# it. Both use the probe binary and are otherwise identical to runs 3 and 4.
img9=$OUT/sd-mfinstall-9.img
prepare_image "$img9" "" "$DOT_DMOFF0"
run_dot "$img9" "$shots/mfinstall-dmoff0.png" no ".mfinstall --load wifi"

img10=$OUT/sd-mfinstall-10.img
prepare_image "$img10" "" "$DOT_DMOFF0"
run_dot "$img10" "$shots/mfinstall-dmoff0-nmi.png" yes ".mfinstall --load wifi"

# --- runs 11 and 12: --configure, which writes the config and NOTHING else --
#
# Two runs, and the split is what makes I8 and I9 separate claims rather than
# one composite. Run 11 is the round trip: --configure writes the file, --auto
# reads it back and acts on it, so a writer that produced something this
# program's own parser cannot read goes red. Run 12 asks a question no screen
# can answer — whether the bytes it writes are the bytes the build SHIPS.
#
# UART in run 11 on purpose: the shipped default is wifi, so a --configure that
# wrote nothing at all would leave the file saying wifi and the run would pass
# on the default it never changed.
img11=$OUT/sd-mfinstall-11.img
prepare_image "$img11" wifi
run_dot "$img11" "$shots/mfinstall-configure.png" yes \
    ".mfinstall --configure uart" ".mfinstall --auto"

img12=$OUT/sd-mfinstall-12.img
prepare_image "$img12" none
run_dot "$img12" "$shots/mfinstall-configure-wifi.png" no ".mfinstall --configure wifi"

log ""

cmdline=$shots/mfinstall-cmdline.png
stocknmi=$shots/mfinstall-stock-nmi.png
loadwifi=$shots/mfinstall-load-wifi.png
wifinmi=$shots/mfinstall-wifi-nmi.png
twice=$shots/mfinstall-twice.png
unloadnmi=$shots/mfinstall-unload-nmi.png
autowifi=$shots/mfinstall-auto-wifi.png
autonone=$shots/mfinstall-auto-none.png
configured=$shots/mfinstall-configure.png
configuredw=$shots/mfinstall-configure-wifi.png
dmoff0=$shots/mfinstall-dmoff0.png
dmoff0nmi=$shots/mfinstall-dmoff0-nmi.png

# --- I1 --------------------------------------------------------------------
#
# TWO HALVES, because "the tool said it worked" and "the ROM says so" are
# different claims and only the second is about the ROM. The first is run 3's
# own report. The second is read out of run 5, whose second invocation reads
# 0x1FE0 from the LIVE Multiface ROM through a read-only config-mode pass — the
# only way that block can be read at all, since outside the window 0x1FE0 is the
# DivMMC ROM.
#
# THE TOOL READS IT AFTER THE INSTALL, NOT BEFORE, so the line reports what is
# live NOW. It has to: load_rom borrows the display file for its buffer and
# blanks it afterwards, so anything printed beforehand is erased. A first version
# printed it first and the line vanished — caught by this check going red, which
# is the argument for reading the screen back as text rather than comparing it
# with another picture.
i1=0
screen_has "$loadwifi" "Live now" \
    || { i1=1; log "      run 3: the install did not report success"; }
screen_has "$twice" "dezogif_ng WiFi" \
    || { i1=1; log "      run 5: the live ROM's identity block does not say WiFi"; }
if [ "$i1" -eq 0 ]; then
    pass "I1 --load wifi installs, and the live ROM's identity block reads back as WiFi"
else
    fail "I1 --load wifi did not install, or the live identity block does not say WiFi"
fi

# --- I2 --------------------------------------------------------------------
#
# THE STRONGEST CHECK HERE. Two clauses, and the second is not a formality: a
# percentage cannot tell a takeover from a crash, so requiring the result to be
# unlike the STOCK monitor is what excludes "the NMI fired and our ROM was never
# installed" — which is exactly what a discarded config-mode write would look
# like. Measured: 97% repainted, 95% unlike stock.
#
# AND IT IS WHAT ANSWERS ISSUE #21'S OPEN QUESTION 3. mfinstall issues no
# `NEXTREG 2,1`; if a soft reset were needed for the bytes to become live, this
# is the check that would be red.
i2_pct=$(diff_pct "$loadwifi" "$wifinmi")
i2_vs_stock=$(diff_pct "$stocknmi" "$wifinmi")
if ! over "$i2_pct" "$TAKEOVER_PCT"; then
    fail "I2 nothing took over on the M1 button after --load wifi ($i2_pct% changed)"
elif ! over "$i2_vs_stock" "$TAKEOVER_PCT"; then
    fail "I2 something took over but it looks like the stock monitor ($i2_vs_stock% unlike it)"
else
    pass "I2 the stub is LIVE with no soft reset ($i2_pct% repainted, $i2_vs_stock% unlike stock)"
fi

# --- I3 --------------------------------------------------------------------
#
# THE SECOND CLAUSE IS THE CONTROL FOR THIS WHOLE BENCH'S NMI, and without it
# I3 passes vacuously: if the button never fired, run 2 and run 6 would BOTH
# show an untouched command line and would be identical, which is exactly what
# the first clause asks for. So the stock reference has to be shown to be a real
# takeover first — against run 1, which differs from run 2 only by the NMI.
i3_pct=$(diff_pct "$stocknmi" "$unloadnmi")
i3_ctl=$(diff_pct "$cmdline" "$stocknmi")
if ! over "$i3_ctl" "$MENU_PCT"; then
    fail "I3 CONTROL: the M1 button did not raise the stock monitor ($i3_ctl%); I3 means nothing"
elif over "$i3_pct" "$MENU_PCT"; then
    fail "I3 --unload did not restore the original ROM ($i3_pct% unlike the stock monitor)"
else
    pass "I3 --unload restores the original: the stock monitor comes up ($i3_pct% differs)"
fi

# --- I4 --------------------------------------------------------------------
#
# ITS MEANING IS UNCHANGED AND ITS MECHANISM IS NOT. The tool used to decide
# this by matching the identity block's variant field; it now COMPARES ALL 8192
# BYTES against what is live, inside the same window, and writes only what
# differs. So this check went from "it recognised a WiFi ROM" to "it found the
# bytes already there", which is the stronger claim and the one that keeps a
# locally rebuilt stub — same identity, different bytes — from being skipped.
if screen_has "$twice" "Already loaded"; then
    pass "I4 a second --load wifi finds the bytes already there and writes nothing"
else
    fail "I4 a second --load wifi did not report itself a no-op"
fi

# --- I5 --------------------------------------------------------------------
#
# Both halves are needed and neither implies the other: a tool that ignored the
# config file entirely and always installed would pass the first, and one that
# never installed would pass the second.
#
# The wifi half is also the only check anywhere on the DEFAULT config file the
# build ships — see prepare_image. It reaches the card through mcopy, which
# writes a long-filename entry for `mfinstall.yml` exactly as a PC copying it
# there would, so the name and the CRLF content are both exercised rather than
# assumed. What it cannot say is anything about a REAL Next: NextZXOS reads its
# own long-named config files (/nextzxos/enBrowsext.cfg), which is why the name
# is believed, but nothing here has opened this file on silicon.
i5=0
i5_wifi=$(diff_pct "$stocknmi" "$autowifi")
i5_none=$(diff_pct "$stocknmi" "$autonone")
if ! over "$i5_wifi" "$TAKEOVER_PCT"; then
    i5=1; log "      install: wifi — the stub did not come up ($i5_wifi% unlike stock)"
fi
if over "$i5_none" "$MENU_PCT"; then
    i5=1; log "      install: none — something was installed anyway ($i5_none% unlike stock)"
fi
if [ "$i5" -eq 0 ]; then
    pass "I5 --auto obeys the shipped mfinstall.yml: wifi installs the stub, none installs nothing"
else
    fail "I5 --auto does not obey mfinstall.yml"
fi

# --- I6 --------------------------------------------------------------------
#
# The control that makes every check above mean what it says. Read off run 4's
# card — the run the stub was demonstrably live in.
card_mf=$OUT/mfinstall-card-mf.rom
rm -f "$card_mf"
if mcopy -o -n -i "$img4@@$part_off" "$MF_PATH" "$card_mf" 2>/dev/null; then
    if cmp -s "$card_mf" "$stock"; then
        pass "I6 the card's enNextMf.rom is untouched: it was config mode, not a file write"
    else
        fail "I6 the card's enNextMf.rom CHANGED ($(python3 "$ROMSUM" "$card_mf")): a file was written"
    fi
else
    fail "I6 no enNextMf.rom on the card after the run"
fi

# --- I7 --------------------------------------------------------------------
#
# THE CONTROL THAT ATTRIBUTES THE WHOLE FIX TO ONE ASSEMBLER CONSTANT, and
# without it this bench shows only that the tool works — never WHY.
#
# `DIVMMC_OFF=0` builds mfwin.asm with the two instructions that take DivMMC
# away removed, and NOTHING else: same relocation to 0x5000, same MMU0, same
# layer-2 clear, same NR 0x81, same config-mode entry and exit, same compare and
# the same verify. That is the ORDINARY context a dot command runs in — DivMMC
# page0 and page1 are enabled together (divmmc.vhd:94-95), so the DivMMC ROM is
# necessarily at 0x0000, where it is read-only (:100) — and config mode's own
# override value "110" (zxnext.vhd:3050) deliberately leaves DivMMC eligible in
# the second arbiter (:3084). The write is therefore SILENTLY DISCARDED.
#
# So this asserts both halves, and neither implies the other:
#
#   - the tool NOTICES. The window compares what it wrote against what it meant
#     to write, still inside config mode, and reports "Write blocked". Without
#     that read-back a discarded write is indistinguishable from a successful
#     one, which is precisely how a naive dot command reports success for doing
#     nothing at all. A bench that only checked the screen would pass a tool
#     that lied.
#   - and the ROM really did not change: the M1 button brings up the STOCK
#     monitor. This is the half that cannot be faked by a message.
#
# Judged against the same stock reference I3 uses, so a probe that somehow DID
# install would show up as the stub exactly as run 4 does.
i7=0
screen_has "$dmoff0" "Write blocked" \
    || { i7=1; log "      run 9: the probe did not report the write as blocked"; }
i7_pct=$(diff_pct "$stocknmi" "$dmoff0nmi")
if over "$i7_pct" "$MENU_PCT"; then
    i7=1; log "      run 10: something other than the stock monitor came up ($i7_pct%)"
fi
if [ "$i7" -eq 0 ]; then
    pass "I7 with DivMMC left on the write is blocked, reported, and the stub does not come up"
else
    fail "I7 the DIVMMC_OFF=0 probe did not behave as a blocked write ($i7_pct% unlike stock)"
fi

# --- I8 --------------------------------------------------------------------
#
# THE ROUND TRIP, and it is the only check that closes it: --configure writes
# the file, and this program's OWN parser then reads it back and acts on it. A
# writer that emitted something read_config() cannot parse — a stray byte, the
# wrong separator, a line pushed out of the 511-byte window — goes red here and
# nowhere else, because every other use of that file in this bench is a file the
# bench itself wrote.
#
# It asks for UART deliberately. The image starts with the shipped default,
# wifi, so a --configure that silently did nothing would leave the file saying
# wifi and --auto would install the WiFi ROM; requiring UART means the check can
# only pass if the WRITE happened.
#
# IT ASSERTS NOTHING ABOUT THE SCREEN, and the reason is NOT the NMI — a first
# version of this comment said it was, and a reviewer disproved it by running
# the same two commands with no NMI at all and finding the message already
# gone. The eraser is `--auto` itself: load_rom() borrows the display file at
# 0x4000 as its read buffer and blank_pixels() afterwards, which
# tools/mfinstall/mfinstall.c already documents where it explains why the
# identity line is printed AFTER the install and not before. So --configure's
# message cannot survive any run that goes on to install, NMI or no NMI.
#
# That also makes this a DIFFERENT mechanism from I7's two-run split, which the
# same wrong comment claimed was the same one: there a blocked write leaves the
# STOCK monitor to paint over the message, which really is the NMI.
#
# The message is judged in run 12, which installs nothing — see I9.
i8=0
cfg_back=$OUT/mfinstall-card-conf.yml
rm -f "$cfg_back"
if mcopy -o -n -i "$img11@@$part_off" ::/mfselect/mfinstall.yml "$cfg_back" 2>/dev/null; then
    case "$(tr -d '\r' < "$cfg_back")" in
        "install: uart") ;;
        *) i8=1; log "      the file on the card says: $(tr -d '\r\n' < "$cfg_back")" ;;
    esac
else
    i8=1; log "      no mfinstall.yml could be read back off the card"
fi
i8_pct=$(diff_pct "$stocknmi" "$configured")
if ! over "$i8_pct" "$TAKEOVER_PCT"; then
    i8=1; log "      --auto did not then install the UART stub ($i8_pct% unlike stock)"
fi
if [ "$i8" -eq 0 ]; then
    pass "I8 --configure uart writes the file and --auto then installs the UART stub"
else
    fail "I8 --configure uart did not round-trip through --auto"
fi

# --- I9 --------------------------------------------------------------------
#
# WHAT THE WRITER EMITS IS WHAT THE BUILD SHIPS, byte for byte — a question no
# screenshot can answer and the one thing that stops the two drifting apart.
# They are separate sources: tools/mfinstall/mfinstall.yml is a checked-in file
# the Makefile copies, and write_config() is C that composes the same line. A
# user who runs --configure wifi and a user who copies build/deploy/ must end up
# with the same file, or one of them is following documentation written for the
# other.
#
# The image starts at `none`, so `install: wifi` here cannot be the file that
# was already there.
# It also carries the MESSAGE check for both runs, because run 12 is the only
# --configure run whose screen survives to the screenshot (I8 says why).
i9=0
cfg_wifi=$OUT/mfinstall-card-conf-wifi.yml
rm -f "$cfg_wifi"
if ! screen_has "$configuredw" "Boot default is now WiFi"; then
    i9=1; log "      --configure did not report writing the WiFi default"
fi
if mcopy -o -n -i "$img12@@$part_off" ::/mfselect/mfinstall.yml "$cfg_wifi" 2>/dev/null; then
    if ! cmp -s "$cfg_wifi" "$CONF_WIFI"; then
        i9=1
        log "      written: $(od -c "$cfg_wifi" | head -1)"
        log "      shipped: $(od -c "$CONF_WIFI" | head -1)"
    fi
else
    i9=1; log "      no mfinstall.yml could be read back off run 12's card"
fi
if [ "$i9" -eq 0 ]; then
    pass "I9 --configure wifi says so, and writes exactly the file the build ships"
else
    fail "I9 --configure wifi did not write the shipped default"
fi

log ""
if [ "$failures" -eq 0 ]; then
    log "mfinstall bench: $checks/$checks checks passed"
else
    log "mfinstall bench: $failures check(s) FAILED"
    exit 1
fi
