#!/usr/bin/env bash
#
# The Next losing and regaining its WiFi association — issue #32.
#
# Invoked by `make test-wifi-assoc`. Five headless jnext runs with the WiFi ROM
# installed as the Multiface ROM and an emulated M1 button press. Each takes the
# module off its network at a chosen frame, some put it back, and every verdict
# is the stub's OWN CONNECT BLOCK — screen rows 6 and 7 — READ BACK AS TEXT.
#
#   D1  the address MOVES across the outage  ->  row 7 names the NEW address
#   D2  ... the control, ADDR_CHECK=0        ->  row 7 still names the OLD one
#   D3  the address GOES and stays gone      ->  rows 6/7 say there is no address
#   D4  ... the control, ADDR_CHECK=0        ->  rows 6/7 still advertise one
#   D5  it goes and COMES BACK unchanged     ->  rows 6/7 advertise it again
#   D6  the stub still serves DZRP afterwards
#
# THE DEFECT. AT+CIFSR is asked exactly ONCE, as the last step of
# transport_init, so esp_link_state and the `Connect at <ip>:11000` line are
# decided at bring-up and never revisited. If the Next drops off the WiFi
# afterwards — or comes up before its router does — the screen goes on saying
# whatever was true at bring-up, and nothing on the machine ever says otherwise.
#
# WHY THIS BENCH COULD NOT EXIST UNTIL NOW, and it is the reason issue #32 was
# filed blocked rather than merely untested. jnext's module used to be
# PERMANENTLY associated: AT+CWJAP? in query form only, no AT+CWQAP, and STA_IP
# a `static constexpr` with no option behind it. No headless run could produce
# "the address went away", which is ERRORS.md's "a bound the emulator can never
# reach is a bound with no test" one layer out. jnext#246 (0.99.148) gave the
# outage and jnext#247 (0.99.151) gave the address the right to come back
# DIFFERENT, and this bench needs both.
#
# WHY --esp-ip-address-after IS LOAD-BEARING AND NOT A CONVENIENCE. With #246
# alone the only sequence stageable is
#
#     A  ->  0.0.0.0  ->  A
#
# on the far side of which the stub's CACHED `A` is correct. A check asserting
# "the screen says A" then passes against a stub that re-queries and against one
# that has never heard of the outage — every wrong answer agreeing with the
# right one, which is the failure this project has shipped three times and has a
# name for (mfselect's M9 with swapped labels; N6's scanline-0 probe; ERRORS.md).
# D1 is the discriminating check precisely BECAUSE the address moves.
#
# WHAT THE OTHER FOUR ARE FOR. D3 is a different branch and a different string:
# an unassociated module answers 0.0.0.0, which esp_query_address refuses as a
# host address, so the screen must change to the "no address" block rather than
# merely to a different number. D5 is the case a REAL Next produced (the address
# survived a five-minute outage), and it is the one that CANNOT discriminate on
# its own — it is exactly the A -> 0.0.0.0 -> A shape above. What earns it is D3:
# the two runs are identical up to frame $UP_FRAMES, D3's screenshot is taken AT
# that frame and shows the screen saying there is no address, and D5 then
# re-associates at that instant and ends up advertising it again. Neither run
# alone says that; the pair does.
#
# THAT IS MEASURED AND NOT ARGUED. Against the ROM as it was before issue #32 —
# no re-query anywhere — this bench reports D1 and D3 red and D5 GREEN. A stub
# that has never heard of an association passes D5, because the address it
# cached at bring-up is the address the module ends up back on. So D5 on its own
# is worth nothing whatever, and the only thing that gives it a subject is the
# run beside it.
#
# D2 AND D4 ARE THE BUILD SEAM, one constant away — ESP_ADDR_CHECK_SECS=0
# assembles the re-query out and leaves transport_init's single bring-up query
# as the only one, which is the shipped behaviour before this issue. Same Z80
# everywhere else, same emulator, same schedule. This is the ninth seam of the
# ESP_IP_MAX / ESP_RX_WAIT / ESP_TX_PASSES / TRANSPORT_WAIT_RX_SECONDS /
# ESP_FAULT_LIMIT / ESP_LINK_IDS / ESP_SERVER_TIMEOUT / ESP_IDLE_SWEEP_SECS
# family, and for the same reason every time: the behaviour a check must be
# shown red against has to be reachable by a BUILD, or the red is a story about
# a scratch tree nobody can re-run.
#
# D6 IS THE PROPERTY A "FIX" COULD EASILY BREAK. Hardware says the happy path is
# that NOTHING breaks — a real Next survived a five-minute AP outage with its
# AT+CIPSERVER listener intact and answered a full 6/6 hardware bench afterwards
# with no M1 press and no reset (jnext#246, reported on hardware). The same is
# true of the emulated module, measured here before any Z80 was written: a TCP
# connection could be made throughout the outage and an ALREADY-OPEN DZRP
# session went on answering CMD_LOOPBACK across both edges. So a fix that tore
# the listener down and rebuilt it would be a REGRESSION against measured
# behaviour, and D6 is what would catch it.
#
# THE SUBJECT IS THE SHIPPED ROM, not a probe build, which is unusual here and
# is deliberate: ESP_ADDR_CHECK_SECS is 60 seconds, and 60 emulated seconds is
# 3000 frames, which a headless run sits out in well under a minute of wall
# clock. Nothing has to be moved to make the shipped behaviour watchable, so
# nothing is — the seam exists only for the two controls.
#
# TIMING IS IN FRAMES AND NEVER IN WALL CLOCK, which is the mistake this project
# has been caught by before (W6's SECOND_NMI_FRAMES). Every edge is a
# --esp-delayed-*-frames option and every verdict is a --delayed-screenshot at a
# frame, so the schedule is exact whatever speed the emulator runs at. The one
# wall-clock wait is D6's client, and it waits for the SCREENSHOT FILE to appear
# rather than for a duration — an event jnext itself produces at the frame D1's
# verdict is taken, so the client provably cannot perturb that verdict by
# arriving early with a CMD_INIT that would stop the stub's own idle clock.
#
# HOW THE SCHEDULE IS DERIVED, so that changing one number does not silently
# break a check. The stub's clock starts when its UI first paints, a little
# after $BOOT_FRAMES; the re-query then fires every ESP_ADDR_CHECK_SECS * 50
# frames while the stub is idle with no DZRP session. With the shipped 60
# seconds that is every 3000 frames from roughly frame 1200, i.e. at about
# 4200, 7200, 10200, 13200 and 16200. So:
#
#   $DOWN_FRAMES  = 5000    two queries (7200, 10200) fall inside the outage
#   $UP_FRAMES    = 11000   two more (13200, 16200) fall after it
#   D3's shot     = $UP_FRAMES, the last instant D3 and D5 are the same run
#   D1/D5's shot  = $SHOT_FRAMES, after two post-outage queries
#
# Every one of those margins is a whole query period wide, and every one of them
# FAILS RED if it is lost: a query that has not fired yet leaves the screen
# saying what it said before, which is exactly what each check refuses. None of
# them can fail green.
#
# THE READER IS VALIDATED INSIDE EACH RUN before its verdict is used — row 12
# must read "R = Reset", drawn by the same code with the same font and not in
# question — so a broken instrument reports itself instead of a wrong line. Same
# device as run-client-status.sh, which is where the argument for reading text
# rather than comparing pictures is written out.
#
# WHAT THIS SAYS ABOUT REAL HARDWARE: NOTHING, and rather less than most benches
# here. Every association fact in it is MODELLED BY AN EMULATOR and not observed
# on a module. jnext was told what to do at each edge by this bench's own
# command line, and jnext#247 records that the address CHANGING across an outage
# has never been seen on an ESP-01 at all — it is inferred from how DHCP works.
# What a green run shows is that the stub NOTICES a change the emulator was told
# to make, and that is the whole of it.
#
# ALSO NOT COVERED, and none of it is hidden:
#   * the unsolicited WIFI DISCONNECT / WIFI CONNECTED / WIFI GOT IP lines a
#     real module puts on the wire at these edges. jnext models none of them
#     (jnext#246 left them out deliberately, unobserved), and neither does the
#     stub — it polls, because there is nothing to watch.
#   * whether a real module's listener survives. Measured once, on one machine,
#     with no re-runnable artefact; the emulator's does, which is not the same
#     claim.
#   * how long a real re-association takes, which is what decides whether 60
#     seconds is the right period. Unmeasured anywhere.
#   * the outage arriving while a DZRP SESSION is open. The stub deliberately
#     does not re-query then (esp_check_address's session guard), so there is
#     nothing to check; what a user sees in that case is unchanged.
#   * UART mode, which has no association to lose and gets none of this.
#
# The check ids are D1-D6. The plan's Appendix B.4 numbers three WORKFLOW STEPS
# D1-D3; those are not check ids, nothing greps them, and no script matches on
# them. The ids here are interface — run-*.sh and hardware-check.py match on
# field 2 of a FAIL line — so they are never renumbered.
#
# Environment (all set by the Makefile, all overridable):
#   JNEXT         path to the jnext binary
#   SD_IMAGE      reference SD card image; NEVER written, only copied
#   OUT           build directory
#   ROM           the SHIPPED WiFi enNextMf.rom — the subject
#   ROM_CONTROL   the same built ADDR_CHECK=0 — the seam

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
ROM_CONTROL=${ROM_CONTROL:-$OUT/enNextMf-wifi-addr0.rom}

PORT=11000
BOOT_FRAMES=900

# The two addresses. IP_BEFORE is what the module reports until the outage and
# IP_AFTER what it reports from the re-association onwards; D5 passes IP_BEFORE
# for BOTH, so D1 and D5 differ in exactly one value on one command line.
IP_BEFORE=192.168.1.50
IP_AFTER=192.168.1.77

# The schedule. See the derivation in the header before moving any of these.
DOWN_FRAMES=${DOWN_FRAMES:-5000}
UP_FRAMES=${UP_FRAMES:-11000}
SHOT_FRAMES=${SHOT_FRAMES:-17000}
EXIT_FRAMES=$((SHOT_FRAMES + 6000))

RUN_TIMEOUT=900
LISTEN_TIMEOUT=60
SHOT_TIMEOUT=300

# The rows the connect block is drawn on — the two `defb AT, 0, 6*8` / `7*8` in
# esp_text_connect and its two alternatives (src/transport_esp.asm).
LINK_ROW_A=6
LINK_ROW_B=7
# A line drawn by the same code, in the same font, whose text is not in
# question. It is what validates the reader before its verdict is trusted.
CONTROL_ROW=12
CONTROL_TEXT="R = Reset"

MF_ROM_PATH='::/machines/next/enNextMf.rom'
FONT_ROM_PATH='::/machines/next/48.rom'
SCREENTEXT=$(dirname "$0")/screen-text.py

# shellcheck source=test/bench-jnext.sh
. "$(dirname "$0")/bench-jnext.sh"

log()  { printf '%s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# --- pre-flight ------------------------------------------------------------

[ -x "$JNEXT" ]        || die "jnext binary not found or not executable: $JNEXT"
[ -f "$SD_IMAGE" ]     || die "SD card image not found: $SD_IMAGE"
[ -f "$ROM" ]          || die "WiFi ROM not built: $ROM (run 'make mf-rom-wifi')"
[ -f "$ROM_CONTROL" ]  || die "control ROM not built: $ROM_CONTROL"
[ -f "$SCREENTEXT" ]   || die "screen reader not found: $SCREENTEXT"
python3 -c 'import PIL' 2>/dev/null || die "python3 Pillow is required to read the screen"
command -v mcopy >/dev/null || die "mtools (mcopy) is required to reach the SD image"

# Both ROMs must really be WiFi builds: the UART one draws no connect block at
# all, and this bench would then report a missing feature where the truth is the
# wrong file. Issue #4's magic string is what answers that.
for r in "$ROM" "$ROM_CONTROL"; do
    variant=$(dd if="$r" bs=1 skip=8160 count=19 2>/dev/null | tr -d '\0')
    [ "${variant#DeZoGiFnG_WIFI_}" != "$variant" ] \
        || die "$r does not identify itself as a WiFi build (magic: '$variant')"
done

bench_jnext_supports "$JNEXT" '--delayed-nmi' \
    || die "this jnext has no --delayed-nmi (need >= 0.99.118); rebuild it"
bench_jnext_supports "$JNEXT" '--esp-delayed-disassociate-frames' \
    || die "this jnext cannot drop the association (need >= 0.99.148, jnext#246); rebuild it"
bench_jnext_supports "$JNEXT" '--esp-ip-address-after' \
    || die "this jnext cannot move the address (need >= 0.99.151, jnext#247); rebuild it"

if command -v ss >/dev/null 2>&1; then
    # `grep -c` and not `-q`. -q exits at its first match, and the SIGPIPE that
    # would give `ss` comes back as 141 under pipefail — which `!` then reads as
    # "free", starting a run against an occupied port.
    [ "$(ss -ltn 2>/dev/null | grep -cE "127\.0\.0\.1:$PORT\b" || true)" -eq 0 ] \
        || die "something is already listening on 127.0.0.1:$PORT — stop it first"
fi

part_lba=$(od -An -tu4 -j 454 -N 4 "$SD_IMAGE" | tr -d ' ')
[ -n "$part_lba" ] && [ "$part_lba" -gt 0 ] || die "cannot read partition table from $SD_IMAGE"
part_off=$((part_lba * 512))

mkdir -p "$OUT" "$OUT/screenshots"

# --- the run ---------------------------------------------------------------

sd=$OUT/sd-wifi-assoc.img
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
    bench_await_departure "$sd"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

cp --reflink=auto -f "$SD_IMAGE" "$sd"

# The font the stub prints with. Taken from the SAME image the machine boots, so
# the reader cannot be reading one font while the Next draws another.
mcopy -o -i "$sd@@$part_off" "$FONT_ROM_PATH" "$font" \
    || die "cannot read $FONT_ROM_PATH out of the SD image"

failures=0
CHECKS=0
pass() { CHECKS=$((CHECKS + 1)); printf 'PASS  %s\n' "$*"; }
fail() { CHECKS=$((CHECKS + 1)); printf 'FAIL  %s\n' "$*"; failures=$((failures + 1)); }

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

# start_run <rom> <logfile> <shotfile> <shotframes> <up-frames|none> <ip-after>
#
# Boot a Next with <rom> as the Multiface ROM, press M1, take the association
# away at $DOWN_FRAMES, optionally give it back at <up-frames> reporting
# <ip-after>, and screenshot at <shotframes>.
start_run() {
    local rom=$1 logfile=$2 shotfile=$3 shotframes=$4 upframes=$5 ipafter=$6
    rm -f "$shotfile"
    mcopy -o -i "$sd@@$part_off" "$rom" "$MF_ROM_PATH"

    # Per-run, not just at pre-flight: an emulator that appeared between two of
    # this script's own runs would otherwise answer D6's client.
    if command -v ss >/dev/null 2>&1; then
        [ "$(ss -ltn 2>/dev/null | grep -cE "127\.0\.0\.1:$PORT\b" || true)" -eq 0 ] \
            || die "something is listening on 127.0.0.1:$PORT before this run started"
    fi

    local assoc=()
    if [ "$upframes" != none ]; then
        assoc=(--esp-delayed-associate-frames "$upframes"
               --esp-ip-address-after "$ipafter")
    fi

    # --log-level carries platform=info so that the association edges and the
    # screenshot line are in the log; every check asserts its own precondition
    # off them rather than trusting the schedule to have happened.
    timeout "$RUN_TIMEOUT" "$JNEXT" \
        --headless --machine next \
        --sdcard "$sd" \
        --rtc "2026-01-01 12:00:00" \
        --log-level "warn,esp01=info,platform=info" \
        --esp --esp-listen-address 127.0.0.1 \
        --esp-ip-address "$IP_BEFORE" \
        --esp-delayed-disassociate-frames "$DOWN_FRAMES" \
        "${assoc[@]}" \
        --delayed-nmi-frames "$BOOT_FRAMES" nmi \
        --delayed-screenshot "$shotfile" --delayed-screenshot-frames "$shotframes" \
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
            return 0
        fi
        sleep 0.25
    done
    return 1
}

# await_shot <shotfile> — block until jnext has written the screenshot.
await_shot() {
    local i
    for i in $(seq $((SHOT_TIMEOUT * 2))); do
        [ -s "$1" ] && { sleep 0.3; return 0; }
        kill -0 "$jnext_pid" 2>/dev/null || { [ -s "$1" ] && return 0; return 1; }
        sleep 0.5
    done
    return 1
}

read_row() { python3 "$SCREENTEXT" --font "$font" "$1" "$2"; }

# reader_ok <shot> — the instrument, checked inside the image it is about to be
# used on. A wrong font or wrong geometry must report itself rather than come
# back as a wrong connect line.
reader_ok() {
    [ "$(read_row "$1" "$CONTROL_ROW")" = "$CONTROL_TEXT" ]
}

# link_rows <shot> — rows 6 and 7, trailing blanks stripped, joined by " / ".
link_rows() {
    local a b
    a=$(read_row "$1" "$LINK_ROW_A")
    b=$(read_row "$1" "$LINK_ROW_B")
    printf '%s / %s' "$a" "$b"
}

# The three things the connect block can say. Composed here from the same
# pieces the ROM composes them from, so a reworded string moves one line.
connect_line() { printf 'Remote debugger ACTIVE / Connect at %s:%d' "$1" "$PORT"; }
NO_ADDRESS_ROWS='No WiFi address. Set the Next / up first: run wifi2.bas'

# assert_edges <log> <expect-regained: yes|no> — the run really did what the
# command line asked for. Without this every check below could pass vacuously
# against a jnext that ignored the options, which is exactly what the whole
# bench rests on.
assert_edges() {
    local logfile=$1 want_up=$2 lost regained
    lost=$(grep -c 'association LOST' "$logfile" || true)
    regained=$(grep -c 'association REGAINED' "$logfile" || true)
    [ "$lost" -eq 1 ] || return 1
    if [ "$want_up" = yes ]; then [ "$regained" -eq 1 ] || return 1
    else [ "$regained" -eq 0 ] || return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# D1 / D6 — the address MOVES, and the stub still serves afterwards.
# ---------------------------------------------------------------------------
log "--- D1/D6: the address moves from $IP_BEFORE to $IP_AFTER ---"
shot=$OUT/screenshots/wifi-assoc-moved.png
runlog=$OUT/wifi-assoc-moved.log
if ! start_run "$ROM" "$runlog" "$shot" "$SHOT_FRAMES" "$UP_FRAMES" "$IP_AFTER"; then
    fail "D1 the stub never listened, so nothing below could be measured"
    fail "D6 not reached: D1's run never started"
    stop_all
else
    if ! await_shot "$shot"; then
        fail "D1 no screenshot: the run ended before frame $SHOT_FRAMES"
        fail "D6 not reached: D1's run produced no screenshot"
    elif ! assert_edges "$runlog" yes; then
        fail "D1 precondition: the emulator did not stage one outage and one recovery"
        fail "D6 not reached: D1's precondition failed"
    elif ! reader_ok "$shot"; then
        fail "D1 the screen reader failed its own row-$CONTROL_ROW check, so the line was NOT judged"
        fail "D6 not reached: D1's reader is broken"
    else
        got=$(link_rows "$shot")
        want=$(connect_line "$IP_AFTER")
        if [ "$got" = "$want" ]; then
            pass "D1 the moved address reached the screen: $got"
        else
            fail "D1 the screen still advertises the old address: $got"
        fi

        # D6 rides this run because its client MUST NOT arrive before D1's
        # verdict is taken: a CMD_INIT sets esp_session_valid, which stops the
        # stub's idle clock and would prevent the very re-query D1 measures.
        # await_shot above is that ordering, anchored on a file jnext writes at
        # the screenshot FRAME rather than on any wall-clock guess.
        if python3 - <<PY
import socket, sys
sys.path.insert(0, "$(dirname "$0")/dzrp")
import dzrp
try:
    t = dzrp.TcpTransport("127.0.0.1", $PORT, 20.0)
    d = dzrp.Dzrp(t, start_byte="none", base_timeout=20.0)
    d.command(1, dzrp.init_payload())
    d.close()
except Exception as e:
    print("%s: %s" % (type(e).__name__, e), file=sys.stderr)
    sys.exit(1)
PY
        then
            pass "D6 the stub answered CMD_INIT after the outage: the listener survived"
        else
            fail "D6 the stub did not answer CMD_INIT after the outage"
        fi
    fi
    stop_all
fi

# ---------------------------------------------------------------------------
# D2 — the control, one constant away.
# ---------------------------------------------------------------------------
log "--- D2: the same run against the ADDR_CHECK=0 build ---"
shot=$OUT/screenshots/wifi-assoc-moved-control.png
runlog=$OUT/wifi-assoc-moved-control.log
if ! start_run "$ROM_CONTROL" "$runlog" "$shot" "$SHOT_FRAMES" "$UP_FRAMES" "$IP_AFTER"; then
    fail "D2 the control stub never listened"
elif ! await_shot "$shot"; then
    fail "D2 no screenshot: the control run ended before frame $SHOT_FRAMES"
elif ! assert_edges "$runlog" yes; then
    fail "D2 precondition: the emulator did not stage one outage and one recovery"
elif ! reader_ok "$shot"; then
    fail "D2 the screen reader failed its own row-$CONTROL_ROW check, so the line was NOT judged"
else
    got=$(link_rows "$shot")
    want=$(connect_line "$IP_BEFORE")
    if [ "$got" = "$want" ]; then
        pass "D2 the control build kept the stale address, as it must: $got"
    else
        fail "D2 the control build moved the address without the re-query: $got"
    fi
fi
stop_all

# ---------------------------------------------------------------------------
# D3 — the address goes and does NOT come back.
# ---------------------------------------------------------------------------
log "--- D3: the association is lost and never regained ---"
shot=$OUT/screenshots/wifi-assoc-gone.png
runlog=$OUT/wifi-assoc-gone.log
if ! start_run "$ROM" "$runlog" "$shot" "$UP_FRAMES" none ""; then
    fail "D3 the stub never listened"
elif ! await_shot "$shot"; then
    fail "D3 no screenshot: the run ended before frame $UP_FRAMES"
elif ! assert_edges "$runlog" no; then
    fail "D3 precondition: the emulator did not stage exactly one outage and no recovery"
elif ! reader_ok "$shot"; then
    fail "D3 the screen reader failed its own row-$CONTROL_ROW check, so the line was NOT judged"
else
    got=$(link_rows "$shot")
    if [ "$got" = "$NO_ADDRESS_ROWS" ]; then
        pass "D3 the screen stopped advertising an address the module had lost"
    else
        fail "D3 the screen still advertises an address the module has lost: $got"
    fi
fi
stop_all

# ---------------------------------------------------------------------------
# D4 — the control for D3.
# ---------------------------------------------------------------------------
log "--- D4: the same run against the ADDR_CHECK=0 build ---"
shot=$OUT/screenshots/wifi-assoc-gone-control.png
runlog=$OUT/wifi-assoc-gone-control.log
if ! start_run "$ROM_CONTROL" "$runlog" "$shot" "$UP_FRAMES" none ""; then
    fail "D4 the control stub never listened"
elif ! await_shot "$shot"; then
    fail "D4 no screenshot: the control run ended before frame $UP_FRAMES"
elif ! assert_edges "$runlog" no; then
    fail "D4 precondition: the emulator did not stage exactly one outage and no recovery"
elif ! reader_ok "$shot"; then
    fail "D4 the screen reader failed its own row-$CONTROL_ROW check, so the line was NOT judged"
else
    got=$(link_rows "$shot")
    want=$(connect_line "$IP_BEFORE")
    if [ "$got" = "$want" ]; then
        pass "D4 the control build went on advertising the lost address, as it must"
    else
        fail "D4 the control build noticed the loss without the re-query: $got"
    fi
fi
stop_all

# ---------------------------------------------------------------------------
# D5 — it goes and comes back UNCHANGED, which is what a real Next did.
#
# Identical to D1's run but for the address the module reports afterwards, and
# identical to D3's run up to frame $UP_FRAMES — which is the instant D3's
# screenshot is taken. So D3 is what says the screen really had stopped
# advertising an address by then, and this is what says it came back.
# ---------------------------------------------------------------------------
log "--- D5: the association is lost and regained at the SAME address ---"
shot=$OUT/screenshots/wifi-assoc-back.png
runlog=$OUT/wifi-assoc-back.log
if ! start_run "$ROM" "$runlog" "$shot" "$SHOT_FRAMES" "$UP_FRAMES" "$IP_BEFORE"; then
    fail "D5 the stub never listened"
elif ! await_shot "$shot"; then
    fail "D5 no screenshot: the run ended before frame $SHOT_FRAMES"
elif ! assert_edges "$runlog" yes; then
    fail "D5 precondition: the emulator did not stage one outage and one recovery"
elif ! reader_ok "$shot"; then
    fail "D5 the screen reader failed its own row-$CONTROL_ROW check, so the line was NOT judged"
else
    got=$(link_rows "$shot")
    want=$(connect_line "$IP_BEFORE")
    if [ "$got" = "$want" ]; then
        pass "D5 the address came back and the screen advertises it again"
    else
        # Kept short deliberately: $got here can be the eleven-word "no address"
        # block — this branch's guard admits it, unlike D2's and D3's — and the
        # longer prose this line used to carry took the detail to 22 words.
        fail "D5 the returned address did not reach the screen: $got"
    fi
fi
stop_all

# --- verdict ---------------------------------------------------------------

log ""
if [ "$failures" -eq 0 ]; then
    log "All $CHECKS checks passed."
    exit 0
fi
log "$failures of $CHECKS checks FAILED."
exit 1
