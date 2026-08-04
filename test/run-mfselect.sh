#!/usr/bin/env bash
#
# Headless bench for mfselect (issues #1 and #5), run by `make test-mfselect`.
#
# Unlike the stub, mfselect is genuinely testable headless, and the assertions
# are file contents rather than pixels: what ends up on the SD image is the
# whole point of the program, so almost nothing here depends on a screenshot.
# M9 is the one exception, and it says why.
#
#   M1  the first run captures the stock ROM, byte-identical, and writes a
#       .sum for it
#   M2  the CRC mfselect computes on the Next equals the one tools/romsum.py
#       computes on the host — the two implementations are independent and the
#       .sum files are worthless if they disagree
#   M3  selecting the WiFi ROM installs it byte-identically at the official path
#   M4  THE GUARD, against our WiFi ROM. On a card where our ROM is already
#       installed and no backup exists, the first run must NOT capture it as
#       "the original". This is the failure mode the whole design exists to
#       prevent: capturing the debug stub as the stock ROM loses the real one
#       with no copy anywhere.
#   M5  a backup left SHORT by an interrupted capture is detected as unusable
#       and recaptured, rather than being trusted because the file exists
#   M6  the guard again, with a dezogif .sum from a DIFFERENT build — the state
#       every card is in after the stub is rebuilt. M4 cannot catch what this
#       catches; see the note at the run itself.
#   M7  THE GUARD, against our UART ROM. Issue #5 put a second ROM of ours on
#       the card, and a guard that refuses one of them and captures the other
#       is not a guard. M4 and M7 differ only in which of our ROMs is installed.
#   M8  selecting the UART ROM installs it byte-identically — the fourth menu
#       entry reaches the file it names, which M3 says nothing about
#   M9  mfselect names the installed variant CORRECTLY on screen — the status
#       row's transport field must match the menu's own rendering of that same
#       label, in the same screenshot, and differ from the other one. Judged
#       per screenshot on purpose: comparing the two runs against each other
#       cannot tell a correct pair from a swapped pair
#   M10 and nothing else on that row differs between the two runs, which is
#       what M9 alone does not cover
#
# mfselect must run under a booted NextZXOS — every file access is the esxdos
# API, and `jnext prog.nex` injects at frame 0 with NextZXOS never booted, so
# the first RST $08 hangs. Hence the keypress choreography: boot to the command
# line (space/down/enter, as jnext's own regression suite does it) and type
# `.nexload <path>`. There is no --load-delay to shortcut this.
set -euo pipefail

JNEXT=${JNEXT:-$HOME/src/spectrum/jnext/build/gui-release/jnext}
SD_IMAGE=${SD_IMAGE:-$HOME/.jnext/sdcard/cspect-next-1gb-fixed.img}
OUT=${OUT:-build}
NEX=${NEX:-$OUT/mfselect.nex}
ROM_UART=${ROM_UART:-$OUT/enNextMf.rom}
SUM_UART=${SUM_UART:-$OUT/dezouart.sum}
ROM_WIFI=${ROM_WIFI:-$OUT/enNextMf-wifi.rom}
SUM_WIFI=${SUM_WIFI:-$OUT/dezowifi.sum}
ROMSUM=${ROMSUM:-tools/romsum.py}
CELLDIFF=${CELLDIFF:-test/cell-diff.py}

MF_PATH='::/machines/next/enNextMf.rom'
RUN_TIMEOUT=300

failures=0
checks=0
log()  { printf '%s\n' "$*"; }
# Derived, never hardcoded: a count written by hand keeps saying 5/5 after a
# sixth check is added, which is a lie in the one line a reader trusts. The
# headless bench was fixed for exactly this and the same rule applies here.
pass() { printf 'PASS  %s\n' "$*"; checks=$((checks + 1)); }
fail() { printf 'FAIL  %s\n' "$*"; failures=$((failures + 1)); checks=$((checks + 1)); }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ -x "$JNEXT" ]    || die "jnext binary not found or not executable: $JNEXT"
[ -f "$SD_IMAGE" ] || die "SD card image not found: $SD_IMAGE"
[ -f "$NEX" ]      || die "mfselect not built: $NEX (run 'make mfselect')"
[ -f "$ROM_UART" ] || die "UART ROM not built: $ROM_UART (run 'make mfselect')"
[ -f "$SUM_UART" ] || die "UART checksum not built: $SUM_UART (run 'make mfselect')"
[ -f "$ROM_WIFI" ] || die "WiFi ROM not built: $ROM_WIFI (run 'make mfselect')"
[ -f "$SUM_WIFI" ] || die "WiFi checksum not built: $SUM_WIFI (run 'make mfselect')"
[ -f "$CELLDIFF" ] || die "cell-diff helper not found: $CELLDIFF"
command -v mcopy >/dev/null || die "mtools (mcopy) is required"

# Partition offset from the MBR rather than assumed, as run-headless.sh does.
part_lba=$(od -An -tu4 -j 454 -N 4 "$SD_IMAGE" | tr -d ' ')
[ -n "$part_lba" ] && [ "$part_lba" -gt 0 ] || die "cannot read partition table"
part_off=$((part_lba * 512))

uart_sum=$(cat "$SUM_UART")
wifi_sum=$(cat "$SUM_WIFI")

# Emit --delayed-keypress-frames flags spelling out a string. '/' is SYMBOL
# SHIFT + V on a Spectrum keyboard; jnext takes that as sym+v.
type_keys() {
    local frame=$1 str=$2 step=${3:-14} i c k
    for (( i = 0; i < ${#str}; i++ )); do
        c=${str:i:1}
        case "$c" in
            /)   k="sym+v" ;;
            " ") k="space" ;;
            *)   k="$c" ;;
        esac
        printf -- '--delayed-keypress-frames %d %s ' "$frame" "$k"
        frame=$((frame + step))
    done
}

# prepare_image <image> <rom-to-install-at-official-path> [uart-sum] [wifi-sum]
#
# BOTH of our ROMs go on every card, because mfselect offers both (issue #5)
# and a menu entry whose file is missing is not a scenario any user is in after
# `make mfselect`.
#
# The trailing arguments override the .sum files shipped beside our ROMs. They
# exist for M6, which needs sums that do NOT match the ROMs — the state every
# card is in after the stub is rebuilt, since BUILD_TIME changes the checksum
# on every build.
prepare_image() {
    local image=$1 mf_rom=$2 usum=${3:-$SUM_UART} wsum=${4:-$SUM_WIFI}
    cp --reflink=auto -f "$SD_IMAGE" "$image"
    mmd -i "$image@@$part_off" ::/mfselect
    mcopy -o -i "$image@@$part_off" "$NEX" ::/mfselect/mfselect.nex
    mcopy -o -i "$image@@$part_off" "$ROM_UART" ::/mfselect/dezouart.rom
    mcopy -o -i "$image@@$part_off" "$usum"     ::/mfselect/dezouart.sum
    mcopy -o -i "$image@@$part_off" "$ROM_WIFI" ::/mfselect/dezowifi.rom
    mcopy -o -i "$image@@$part_off" "$wsum"     ::/mfselect/dezowifi.sum
    [ -n "$mf_rom" ] && mcopy -o -i "$image@@$part_off" "$mf_rom" "$MF_PATH"
    return 0
}

# get_file <image> <sd-path> <local-path>; 0 if it exists
get_file() {
    mcopy -o -i "$1@@$part_off" "$2" "$3" 2>/dev/null
}

# run_mfselect <image> <shot> <extra keypress flags...>
run_mfselect() {
    local image=$1 shot=$2
    shift 2
    local keys
    keys=$(type_keys 560 ".nexload /mfselect/mfselect.nex")
    rm -f "$shot"
    # shellcheck disable=SC2086
    timeout "$RUN_TIMEOUT" "$JNEXT" --headless --machine next \
        --sdcard "$image" --rtc "2026-01-01 12:00:00" \
        --delayed-keypress-frames 400 space \
        --delayed-keypress-frames 470 down \
        --delayed-keypress-frames 500 enter \
        $keys \
        --delayed-keypress-frames 1000 enter \
        "$@" \
        --delayed-screenshot "$shot" \
        >/dev/null 2>&1 || die "jnext run failed or timed out (image=$image)"
}

# A run that only needs mfselect to reach its menu: answer the capture prompt,
# dismiss the report, and screenshot the menu. Used by M4, M6 and M7.
#
# Answering Y is deliberate wherever the guard is under test: the point is that
# mfselect refuses before it ever asks, so a Y that arrives anyway must change
# nothing.
run_to_menu() {
    run_mfselect "$1" "$2" \
        --delayed-keypress-frames 1500 y \
        --delayed-keypress-frames 2000 space \
        --delayed-screenshot-frames 2600 \
        --delayed-automatic-exit-frames 2700
}

mkdir -p "$OUT/screenshots"
shots=$OUT/screenshots

# The stock ROM as it exists on the reference image, for the byte compares.
stock=$OUT/mfselect-stock.rom
get_file "$SD_IMAGE" "$MF_PATH" "$stock" || die "no stock MF ROM on the reference image"
stock_sum=$(python3 "$ROMSUM" "$stock")

log "== mfselect bench (6 headless runs, ~5min)"
log "   stock MF ROM CRC $stock_sum, dezogif_ng UART $uart_sum, WiFi $wifi_sum"
[ "$stock_sum" != "$uart_sum" ] && [ "$stock_sum" != "$wifi_sum" ] \
    || die "stock and dezogif_ng ROMs have the same CRC; the bench cannot tell them apart"
[ "$uart_sum" != "$wifi_sum" ] \
    || die "the two dezogif_ng ROMs have the same CRC; the bench cannot tell them apart"

# --- run 1: stock installed. Capture the backup, then install the WiFi ROM ---
img1=$OUT/sd-mfselect-1.img
prepare_image "$img1" "$stock"
run_mfselect "$img1" "$shots/mfselect-install-wifi.png" \
    --delayed-keypress-frames 1500 y \
    --delayed-keypress-frames 2000 space \
    --delayed-keypress-frames 2500 down \
    --delayed-keypress-frames 2600 enter \
    --delayed-screenshot-frames 3300 \
    --delayed-automatic-exit-frames 3400

log ""

# M1 — the backup is the stock ROM, byte for byte.
got_orig=$OUT/mfselect-original.rom
if get_file "$img1" ::/mfselect/original.rom "$got_orig"; then
    if cmp -s "$got_orig" "$stock"; then
        pass "M1 first run captured the stock ROM byte-identically"
    else
        fail "M1 original.rom is not the stock ROM"
    fi
else
    fail "M1 no original.rom was captured"
fi

# M2 — the on-Next CRC agrees with the host's. mfselect wrote original.sum
# from its own computation; romsum.py computes it here, independently.
got_sum=$OUT/mfselect-original.sum
if get_file "$img1" ::/mfselect/original.sum "$got_sum"; then
    on_next=$(tr -d '\r\n' <"$got_sum")
    if [ "$on_next" = "$stock_sum" ]; then
        pass "M2 on-Next CRC matches tools/romsum.py ($on_next)"
    else
        fail "M2 CRC disagreement: mfselect wrote $on_next, romsum.py says $stock_sum"
    fi
else
    fail "M2 no original.sum was written"
fi

# M3 — the WiFi ROM is now at the official path, byte for byte. One Down from
# the top selects it, so this also pins the menu order.
got_mf=$OUT/mfselect-installed-wifi.rom
if get_file "$img1" "$MF_PATH" "$got_mf"; then
    if cmp -s "$got_mf" "$ROM_WIFI"; then
        pass "M3 WiFi ROM installed at the official path byte-identically"
    else
        fail "M3 the installed ROM is not our WiFi build ($(python3 "$ROMSUM" "$got_mf"))"
    fi
else
    fail "M3 no ROM at the official path after the run"
fi

# --- run 2: our WIFI rom already installed, no backup. The guard must hold ---
img2=$OUT/sd-mfselect-2.img
prepare_image "$img2" "$ROM_WIFI"
run_to_menu "$img2" "$shots/mfselect-guard-wifi.png"

guard=$OUT/mfselect-guard-original.rom
rm -f "$guard"
if get_file "$img2" ::/mfselect/original.rom "$guard"; then
    fail "M4 GUARD BREACHED: mfselect saved our WiFi ROM as the original ($(python3 "$ROMSUM" "$guard"))"
else
    pass "M4 guard held against our WiFi ROM"
fi

# --- run 3: our UART rom installed, no backup. The guard must hold for it too -
#
# M7 — added with issue #5, and it is not M4 with a different file. Before #5
# there was one ROM of ours; now there are two, and a guard that recognises the
# variant it was written against while capturing the other is worse than no
# guard, because it destroys the stock ROM only for the users who chose the
# other transport. The identity check keys off the magic string's PREFIX, so
# both must be refused; this is what says so.
img3=$OUT/sd-mfselect-3.img
prepare_image "$img3" "$ROM_UART"
run_to_menu "$img3" "$shots/mfselect-guard-uart.png"

guard_uart=$OUT/mfselect-guard-uart-original.rom
rm -f "$guard_uart"
if get_file "$img3" ::/mfselect/original.rom "$guard_uart"; then
    fail "M7 GUARD BREACHED: mfselect saved our UART ROM as the original ($(python3 "$ROMSUM" "$guard_uart"))"
else
    pass "M7 guard held against our UART ROM"
fi

# M9 — the label on screen is the RIGHT one, judged inside each screenshot on
# its own. This is the check that must survive a swap, and the earlier version
# of it did not: it only compared the two runs against each other, so two labels
# **exchanged** — each run showing the other's — differed in exactly the columns
# it demanded and passed. An independent reviewer swapped the two strings in
# installed_name(), rebuilt, and got 9/9. Two runs disagreeing is not either of
# them being right, and nothing else on this bench reads the screen at all: M3
# and M8 assert on the bytes of a file, which say nothing about what was
# displayed about them.
#
# The ground truth is already in the picture. mfselect's menu draws
# "dezogif_ng WiFi (ESP-01)" on row 6 and "dezogif_ng UART (joy port)" on row 7
# whatever is installed, in the same ROM font and the same attribute as the
# status row — so each screenshot contains a correct rendering of BOTH labels,
# and the status row can be checked against them without OCR and without a
# committed reference bitmap.
#
# All four columns are derived from one fact — every one of these strings starts
# with the 11 characters "dezogif_ng " — so the transport field sits 11 cells
# into each of them:
#
#   status row  print_at(12, ROW_STATUS, "dezogif_ng WiFi")  -> cols 23-26, row 2
#   menu WiFi   print_at(2,  ROW_MENU+1, "dezogif_ng WiFi …") -> cols 13-16, row 6
#   menu UART   print_at(2,  ROW_MENU+2, "dezogif_ng UART …") -> cols 13-16, row 7
#
# Cells are compared as raw pixels, so the attributes have to match too. They do:
# the status row and the unselected menu rows are both ATTR_BODY, and the
# selected row — the inverse-video one — is row 5 in these runs, because neither
# sends an arrow key. If that ever changes this check goes red rather than quiet.
STATUS_FIELD=2:23-26
MENU_WIFI_FIELD=6:13-16
MENU_UART_FIELD=7:13-16

# label_ok <screenshot> <own-menu-field> <other-menu-field>
label_ok() {
    local shot=$1 own=$2 other=$3
    [ "$(python3 "$CELLDIFF" cells "$shot@$STATUS_FIELD" "$shot@$own")" = "same" ] &&
    [ "$(python3 "$CELLDIFF" cells "$shot@$STATUS_FIELD" "$shot@$other")" = "differ" ]
}

wifi_shot=$shots/mfselect-guard-wifi.png
uart_shot=$shots/mfselect-guard-uart.png
if [ -f "$wifi_shot" ] && [ -f "$uart_shot" ]; then
    m9=0
    label_ok "$wifi_shot" "$MENU_WIFI_FIELD" "$MENU_UART_FIELD" \
        || { m9=1; log "      WiFi run: status field is not the WiFi menu label"; }
    label_ok "$uart_shot" "$MENU_UART_FIELD" "$MENU_WIFI_FIELD" \
        || { m9=1; log "      UART run: status field is not the UART menu label"; }
    if [ "$m9" -eq 0 ]; then
        pass "M9 each run's status row carries the CORRECT transport label, matched against the menu's own rendering of it"
    else
        fail "M9 the status row is mislabelled (a swap, or a name that is not one of the two)"
    fi
else
    fail "M9 a guard-run screenshot is missing"
fi

# M10 — and nothing ELSE on that row differs between the two runs. M9 reads four
# cells; this one covers the other twenty-eight, so a name of a different length
# (which shifts the build number that follows it), a changed prefix or a row that
# was never drawn cannot hide behind a correct transport field.
expect_cols="23 24 25 26"
if [ -f "$wifi_shot" ] && [ -f "$uart_shot" ]; then
    got_cols=$(python3 "$CELLDIFF" rows "$wifi_shot" "$uart_shot" 2)
    if [ "$got_cols" = "$expect_cols" ]; then
        pass "M10 the status rows differ in columns [$got_cols] and nowhere else"
    else
        fail "M10 status rows differ in columns [$got_cols], expected [$expect_cols]"
    fi
else
    fail "M10 a guard-run screenshot is missing"
fi

# --- run 4: a previous capture was interrupted, leaving a short backup ------
#
# Added after a review found this: existence of original.rom was being taken as
# proof of a backup. Opening with CREAT_TRUNC creates the directory entry
# before any byte is written, so an interrupted capture leaves a SHORT file —
# and treating that as "already backed up" makes every later run skip the
# capture silently, leaving the stock ROM with no copy anywhere. The stock ROM
# is installed here, so a correct mfselect must notice the backup is unusable
# and capture it again.
img4=$OUT/sd-mfselect-4.img
prepare_image "$img4" "$stock"
: >"$OUT/mfselect-truncated.rom"
mcopy -o -i "$img4@@$part_off" "$OUT/mfselect-truncated.rom" ::/mfselect/original.rom
run_to_menu "$img4" "$shots/mfselect-recapture.png"

recap=$OUT/mfselect-recaptured.rom
rm -f "$recap"
if get_file "$img4" ::/mfselect/original.rom "$recap"; then
    if cmp -s "$recap" "$stock"; then
        pass "M5 a truncated backup is detected and recaptured from the stock ROM"
    else
        fail "M5 backup still not the stock ROM after recapture ($(wc -c <"$recap") bytes)"
    fi
else
    fail "M5 original.rom vanished entirely"
fi

# --- run 5: our rom installed, but the .sums beside it are from another build -
#
# M6 — THE REGRESSION ISSUE #4 EXISTS FOR, and M4 cannot catch it.
#
# M4 proves the guard holds when the .sums match the installed ROM. That is the
# easy case and it is not the one users are in. BUILD_TIME is stamped into every
# ROM, so the checksum changes on EVERY build: the moment a user upgrades the
# stub, the ROM on the card and the .sum beside it come from different builds
# and no longer agree.
#
# The old guard compared those two checksums. On a skew the comparison failed,
# the guard fell silent, and mfselect captured OUR ROM as the user's
# original.rom — losing the stock ROM entirely, which is the exact loss the
# guard was written to prevent, reached through a different door.
#
# So this run ships deliberately WRONG .sums for both of our ROMs, which is what
# an upgraded card looks like, and answers Y to the capture prompt as M4 does.
# The magic string in the ROM does not change with the build, so identity
# survives and the guard must still hold.
#
# It installs the WIFI ROM deliberately, and that is not arbitrary. It used to
# install the UART one, and a control that broke the guard for UART alone then
# turned M6 red as well as M7 — a check failing for a reason outside its own
# subject, which this project's ERRORS.md calls a defect in the check. M6's
# subject is checksum skew and M7's is the UART guard; they must not be able to
# fail together.
img5=$OUT/sd-mfselect-5.img
stale_uart=$OUT/mfselect-stale-uart.sum
stale_wifi=$OUT/mfselect-stale-wifi.sum
# Syntactically valid CRCs that are not our ROMs'. Derived from the real ones so
# they cannot accidentally equal them.
printf '%04X\n' $(( (0x$uart_sum ^ 0xFFFF) & 0xFFFF )) > "$stale_uart"
printf '%04X\n' $(( (0x$wifi_sum ^ 0xFFFF) & 0xFFFF )) > "$stale_wifi"
log "   M6 ships stale sums ($(cat "$stale_uart")/$(cat "$stale_wifi")) against our ROMs ($uart_sum/$wifi_sum)"

prepare_image "$img5" "$ROM_WIFI" "$stale_uart" "$stale_wifi"
run_to_menu "$img5" "$shots/mfselect-skew.png"

skew=$OUT/mfselect-skew-original.rom
rm -f "$skew"
if get_file "$img5" ::/mfselect/original.rom "$skew"; then
    fail "M6 GUARD BREACHED ON A VERSION SKEW: our ROM was captured as the original ($(python3 "$ROMSUM" "$skew")) — identity is checksum-dependent again"
else
    pass "M6 guard held with mismatched .sums: identity comes from the ROM's magic, not its checksum"
fi

# --- run 6: stock installed, capture, then install the UART ROM ------------
#
# M8 — the fourth menu entry, and the only check that follows it to a file. Two
# Downs from the top, so it also pins the UART entry's position: with the entry
# missing this selects Exit and no ROM is installed at all.
img6=$OUT/sd-mfselect-6.img
prepare_image "$img6" "$stock"
run_mfselect "$img6" "$shots/mfselect-install-uart.png" \
    --delayed-keypress-frames 1500 y \
    --delayed-keypress-frames 2000 space \
    --delayed-keypress-frames 2500 down \
    --delayed-keypress-frames 2600 down \
    --delayed-keypress-frames 2700 enter \
    --delayed-screenshot-frames 3400 \
    --delayed-automatic-exit-frames 3500

got_uart=$OUT/mfselect-installed-uart.rom
if get_file "$img6" "$MF_PATH" "$got_uart"; then
    if cmp -s "$got_uart" "$ROM_UART"; then
        pass "M8 UART ROM installed at the official path byte-identically"
    else
        fail "M8 the installed ROM is not our UART build ($(python3 "$ROMSUM" "$got_uart"))"
    fi
else
    fail "M8 no ROM at the official path after the run"
fi

log ""
if [ "$failures" -eq 0 ]; then
    log "mfselect bench: $checks/$checks checks passed"
else
    log "mfselect bench: $failures check(s) FAILED"
    exit 1
fi
