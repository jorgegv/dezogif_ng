#!/usr/bin/env bash
#
# Headless bench for mfselect (issue #1), run by `make test-mfselect`.
#
# Unlike the stub, mfselect is genuinely testable headless, and the assertions
# are file contents rather than pixels: what ends up on the SD image is the
# whole point of the program, so nothing here depends on a screenshot.
#
#   M1  the first run captures the stock ROM, byte-identical, and writes a
#       .sum for it
#   M2  the CRC mfselect computes on the Next equals the one tools/romsum.py
#       computes on the host — the two implementations are independent and the
#       .sum files are worthless if they disagree
#   M3  selecting the dezogif_ng ROM installs it byte-identically at the
#       official path
#   M4  THE GUARD. On a card where our ROM is already installed and no backup
#       exists, the first run must NOT capture it as "the original". This is
#       the failure mode the whole design exists to prevent: capturing the
#       debug stub as the stock ROM loses the real one with no copy anywhere.
#   M5  a backup left SHORT by an interrupted capture is detected as unusable
#       and recaptured, rather than being trusted because the file exists
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
ROM=${ROM:-$OUT/enNextMf.rom}
SUM=${SUM:-$OUT/dezogif.sum}
ROMSUM=${ROMSUM:-tools/romsum.py}

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
[ -f "$ROM" ]      || die "ROM not built: $ROM (run 'make mf-rom')"
[ -f "$SUM" ]      || die "checksum not built: $SUM (run 'make mfselect')"
command -v mcopy >/dev/null || die "mtools (mcopy) is required"

# Partition offset from the MBR rather than assumed, as run-headless.sh does.
part_lba=$(od -An -tu4 -j 454 -N 4 "$SD_IMAGE" | tr -d ' ')
[ -n "$part_lba" ] && [ "$part_lba" -gt 0 ] || die "cannot read partition table"
part_off=$((part_lba * 512))

ours_sum=$(cat "$SUM")

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

# prepare_image <image> <rom-to-install-at-official-path> [sum-file]
#
# The third argument overrides the dezogif.sum shipped beside our ROM. It
# exists for M6, which needs a .sum that does NOT match the installed ROM —
# the state every card is in after the stub is rebuilt, since BUILD_TIME
# changes the checksum on every build.
prepare_image() {
    local image=$1 mf_rom=$2 sum_file=${3:-$SUM}
    cp --reflink=auto -f "$SD_IMAGE" "$image"
    mmd -i "$image@@$part_off" ::/mfselect
    mcopy -o -i "$image@@$part_off" "$NEX" ::/mfselect/mfselect.nex
    mcopy -o -i "$image@@$part_off" "$ROM" ::/mfselect/dezogif.rom
    mcopy -o -i "$image@@$part_off" "$sum_file" ::/mfselect/dezogif.sum
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

mkdir -p "$OUT/screenshots"
shots=$OUT/screenshots

# The stock ROM as it exists on the reference image, for the byte compares.
stock=$OUT/mfselect-stock.rom
get_file "$SD_IMAGE" "$MF_PATH" "$stock" || die "no stock MF ROM on the reference image"
stock_sum=$(python3 "$ROMSUM" "$stock")

log "== mfselect bench (4 headless runs, ~3min)"
log "   stock MF ROM CRC $stock_sum, dezogif_ng ROM CRC $ours_sum"
[ "$stock_sum" != "$ours_sum" ] \
    || die "stock and dezogif_ng ROMs have the same CRC; the bench cannot tell them apart"

# --- run 1: stock installed. Capture the backup, then install ours ---------
img1=$OUT/sd-mfselect-1.img
prepare_image "$img1" "$stock"
run_mfselect "$img1" "$shots/mfselect-install.png" \
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

# M3 — our ROM is now at the official path, byte for byte.
got_mf=$OUT/mfselect-installed.rom
if get_file "$img1" "$MF_PATH" "$got_mf"; then
    if cmp -s "$got_mf" "$ROM"; then
        pass "M3 dezogif_ng ROM installed at the official path byte-identically"
    else
        fail "M3 the installed ROM is not ours ($(python3 "$ROMSUM" "$got_mf"))"
    fi
else
    fail "M3 no ROM at the official path after the run"
fi

# --- run 2: OUR rom already installed, no backup. The guard must hold ------
#
# Answering Y here is deliberate: the point is that mfselect refuses before it
# ever asks, so a Y that arrives anyway must change nothing.
img2=$OUT/sd-mfselect-2.img
prepare_image "$img2" "$ROM"
run_mfselect "$img2" "$shots/mfselect-guard.png" \
    --delayed-keypress-frames 1500 y \
    --delayed-keypress-frames 2000 space \
    --delayed-screenshot-frames 2600 \
    --delayed-automatic-exit-frames 2700

guard=$OUT/mfselect-guard-original.rom
rm -f "$guard"
if get_file "$img2" ::/mfselect/original.rom "$guard"; then
    fail "M4 GUARD BREACHED: mfselect saved the dezogif_ng ROM as the original ($(python3 "$ROMSUM" "$guard"))"
else
    pass "M4 guard held: our own ROM was not captured as the original"
fi

# --- run 3: a previous capture was interrupted, leaving a short backup ------
#
# Added after a review found this: existence of original.rom was being taken as
# proof of a backup. Opening with CREAT_TRUNC creates the directory entry
# before any byte is written, so an interrupted capture leaves a SHORT file —
# and treating that as "already backed up" makes every later run skip the
# capture silently, leaving the stock ROM with no copy anywhere. The stock ROM
# is installed here, so a correct mfselect must notice the backup is unusable
# and capture it again.
img3=$OUT/sd-mfselect-3.img
prepare_image "$img3" "$stock"
: >"$OUT/mfselect-truncated.rom"
mcopy -o -i "$img3@@$part_off" "$OUT/mfselect-truncated.rom" ::/mfselect/original.rom
run_mfselect "$img3" "$shots/mfselect-recapture.png" \
    --delayed-keypress-frames 1500 y \
    --delayed-keypress-frames 2000 space \
    --delayed-screenshot-frames 2600 \
    --delayed-automatic-exit-frames 2700

recap=$OUT/mfselect-recaptured.rom
rm -f "$recap"
if get_file "$img3" ::/mfselect/original.rom "$recap"; then
    if cmp -s "$recap" "$stock"; then
        pass "M5 a truncated backup is detected and recaptured from the stock ROM"
    else
        fail "M5 backup still not the stock ROM after recapture ($(wc -c <"$recap") bytes)"
    fi
else
    fail "M5 original.rom vanished entirely"
fi

# --- run 4: OUR rom installed, but the .sum beside it is from another build --
#
# M6 — THE REGRESSION ISSUE #4 EXISTS FOR, and M4 cannot catch it.
#
# M4 proves the guard holds when dezogif.sum matches the installed ROM. That is
# the easy case and it is not the one users are in. BUILD_TIME is stamped into
# every ROM, so the checksum changes on EVERY build: the moment a user upgrades
# the stub, the ROM on the card and the .sum beside it come from different
# builds and no longer agree.
#
# The old guard compared those two checksums. On a skew the comparison failed,
# the guard fell silent, and mfselect captured OUR ROM as the user's
# original.rom — losing the stock ROM entirely, which is the exact loss the
# guard was written to prevent, reached through a different door.
#
# So this run ships a deliberately WRONG dezogif.sum, which is what an upgraded
# card looks like, and answers Y to the capture prompt as M4 does. The magic
# string in the ROM does not change with the build, so identity survives and
# the guard must still hold.
img4=$OUT/sd-mfselect-4.img
stale_sum=$OUT/mfselect-stale.sum
# A syntactically valid CRC that is not our ROM's. Derived from the real one so
# it cannot accidentally equal it.
printf '%04X\n' $(( (0x$ours_sum ^ 0xFFFF) & 0xFFFF )) > "$stale_sum"
log "   M6 ships a stale dezogif.sum ($(cat "$stale_sum")) against our ROM ($ours_sum)"

prepare_image "$img4" "$ROM" "$stale_sum"
run_mfselect "$img4" "$shots/mfselect-skew.png" \
    --delayed-keypress-frames 1500 y \
    --delayed-keypress-frames 2000 space \
    --delayed-screenshot-frames 2600 \
    --delayed-automatic-exit-frames 2700

skew=$OUT/mfselect-skew-original.rom
rm -f "$skew"
if get_file "$img4" ::/mfselect/original.rom "$skew"; then
    fail "M6 GUARD BREACHED ON A VERSION SKEW: our ROM was captured as the original ($(python3 "$ROMSUM" "$skew")) — identity is checksum-dependent again"
else
    pass "M6 guard held with a mismatched dezogif.sum: identity comes from the ROM's magic, not its checksum"
fi

log ""
if [ "$failures" -eq 0 ]; then
    log "mfselect bench: $checks/$checks checks passed"
else
    log "mfselect bench: $failures check(s) FAILED"
    exit 1
fi
