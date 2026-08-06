#!/usr/bin/env bash
#
# The Z80 unit tests, headless — issue #3. Invoked by `make test-unit`.
#
# The tests under src/unit_tests/ are upstream's and were written for DeZog's
# z80-unit-test framework, in which the DRIVER is the VS Code extension: it
# enumerates the test labels from the SLD file, patches UNITTEST_CALL_ADDR to
# point at each one, runs the machine, and decides pass or fail by which
# breakpoint is hit. build/ut.nex is inert on its own, so for the whole life of
# this fork those 64 test cases have gated nothing.
#
# Here the guest drives itself. build/ut-headless.nex contains the same test
# bodies with the assertions compiled into Z80 (see
# src/unit_tests/headless/ut_headless.inc), plus a runner that walks a
# generated table and reports to jnext's magic debug port. ONE headless jnext
# run prints a full test report on stderr, and this script judges it.
#
# WHAT IT CHECKS, and why each one is here rather than "did it exit 0":
#
#   U1  the runner started, exactly once. Zero UT-RUN lines means nothing ran
#       and the emulator would still have exited 0; more than one means the
#       machine reset and restarted the suite, which would double-count.
#   U2  the run REACHED THE END (UT-DONE). This is the check that makes a hang
#       or a crash a failure. jnext's run is frame-bounded, so a wedged guest
#       ends the run quietly and on time; without U2 that is indistinguishable
#       from success. The last UT-BEGIN line names the test that wedged.
#   U3  the pinned counts. The suite must contain UT_EXPECTED_TESTS cases and
#       exclude exactly UT_EXPECTED_SKIPPED of them. A suite that silently
#       shrinks and reports "all passed" is the failure mode this project has
#       already hit twice (ERRORS.md), so the numbers are pinned in two
#       independent places — here, and in the Makefile, which passes them to
#       the generator.
#   U4  the report is internally consistent: the counted UT-PASS / UT-FAIL /
#       UT-SKIP lines must agree with the totals UT-DONE claims. A runner that
#       miscounts its own results could otherwise report 1C passes having
#       printed three.
#   U5  no test failed.
#
# WHAT IT DOES NOT COVER. 36 of the 64 test cases are EXCLUDED, and that is not
# a shortcut — see doc/UNIT-TESTS.md. They drive the debugger through a DZRP
# command and read its response back through ports invented by
# src/simulation/uart.js, a JavaScript peripheral DeZog's zsim loads as
# `customCode`. Those ports exist on no real machine and in no other emulator,
# and the Z80 cannot trap its own I/O, so they cannot be provided from inside
# the guest. Every excluded test is named on the output as UT-SKIP.
#
# It also proves nothing about hardware: this is jnext, and the tests it does
# run include ones about MMU paging that jnext models rather than is.
#
# Environment (all set by the Makefile, all overridable):
#   JNEXT      path to the jnext binary
#   SD_IMAGE   reference SD card image — opened READ-ONLY and never copied
#   OUT        build directory
#   UT_NEX     the headless unit-test image
#   UT_MANIFEST  generated list of test cases, for cross-checking the counts

set -euo pipefail

JNEXT=${JNEXT:-$HOME/src/spectrum/jnext/build/gui-release/jnext}
SD_IMAGE=${SD_IMAGE:-$HOME/.jnext/sdcard/cspect-next-1gb-fixed.img}
OUT=${OUT:-build}
UT_NEX=${UT_NEX:-$OUT/ut-headless.nex}
UT_MANIFEST=${UT_MANIFEST:-$OUT/ut_headless/ut_manifest.txt}

# Pinned counts. Also passed to tools/ut-headless-gen.py by the Makefile, which
# fails the BUILD if the source disagrees; this is the second, independent
# statement of the same numbers, checked against what actually ran.
UT_EXPECTED_TESTS=64
UT_EXPECTED_SKIPPED=36
UT_EXPECTED_RUN=$((UT_EXPECTED_TESTS - UT_EXPECTED_SKIPPED))

# jnext's magic debug port: guest writes appear on the emulator's stderr.
# 0xCAFE is jnext's own convention (its test/00regression/scripts/
# magic-port-func.sh), and must match UT_MAGIC_PORT in ut_runner.asm.
MAGIC_PORT=0xCAFE

# Frame budget. MEASURED: the whole suite completes inside 200 frames, so this
# is six times what it needs. It is not a timeout to be tuned down — it is the
# thing that ends the run when a test hangs, and every frame of headroom here
# is headroom for a future test that is merely slow rather than wedged.
EXIT_FRAMES=1200

# Wall-clock guard. The run above takes ~2s.
RUN_TIMEOUT=120

failures=0

log()  { printf '%s\n' "$*"; }
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; failures=$((failures + 1)); }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# Sourced for bench_jnext_supports alone. This bench takes none of the other
# functions — it runs the REFERENCE image read-only and synchronously with
# --no-esp, so the departure check is deliberately not its business — and
# sourcing costs it nothing either way: the file defines functions and does
# nothing else, which is the property that makes it safe to pull in here.
# shellcheck source=test/bench-jnext.sh
. "$(dirname "$0")/bench-jnext.sh"

# --- pre-flight ------------------------------------------------------------

[ -x "$JNEXT" ]    || die "jnext binary not found or not executable: $JNEXT"
[ -f "$SD_IMAGE" ] || die "SD card image not found: $SD_IMAGE"
[ -f "$UT_NEX" ]   || die "unit-test image not built: $UT_NEX (run 'make ut-headless')"

bench_jnext_supports "$JNEXT" '--magic-port' \
    || die "this jnext has no --magic-port; the runner has no way to report"

mkdir -p "$OUT"
raw=$OUT/unit-tests.log

# --- the run ---------------------------------------------------------------
#
# The SD image is opened READ-ONLY and is NOT copied. Every other bench here
# reflink-copies it because it installs a ROM into it; this one does not touch
# it at all — jnext only needs it for the machine ROMs — and a `cp --reflink=
# auto` that silently falls back to a full 1 GB copy is how ~22 GB leaked into
# a tmpfs and took a session's shell down (ERRORS.md).

log "Running the Z80 unit tests headless (${EXIT_FRAMES} frames)..."
log ""

timeout "$RUN_TIMEOUT" "$JNEXT" \
    --headless --silent --no-esp \
    --sdcard "$SD_IMAGE" --sdcard-readonly \
    --magic-port "$MAGIC_PORT" --magic-port-mode line \
    --delayed-automatic-exit-frames "$EXIT_FRAMES" \
    "$UT_NEX" > "$raw.out" 2> "$raw" || true

# The guest's report, separated from jnext's own logging.
report=$OUT/unit-tests-report.txt
grep -E '^UT-' "$raw" > "$report" || true

sed 's/^/  /' "$report" || true
log ""

# --- U1: the runner started, exactly once ----------------------------------

n_run=$(grep -c '^UT-RUN ' "$report" || true)
if [ "$n_run" -eq 1 ]; then
    pass "U1 the runner started exactly once"
elif [ "$n_run" -eq 0 ]; then
    fail "U1 the runner never started: no UT-RUN line, so the image did not run at all"
else
    fail "U1 the runner started $n_run times — the machine reset mid-suite, so the results below are duplicated"
fi

# --- U2: the run reached the end -------------------------------------------
#
# THE CHECK THAT MAKES SILENCE A FAILURE. A test that hangs or crashes never
# emits PASS or FAIL and never gets here; jnext then exits on its frame budget
# with an exit status of 0 and a partial report that, without this check, would
# read as "everything that ran, passed".

done_line=$(grep '^UT-DONE ' "$report" | tail -1 || true)
if [ -n "$done_line" ]; then
    pass "U2 the suite ran to completion ($done_line)"
else
    last_begin=$(grep '^UT-BEGIN ' "$report" | tail -1 || true)
    if [ -n "$last_begin" ]; then
        fail "U2 the suite did NOT finish — it hung or crashed in: ${last_begin#UT-BEGIN }"
    else
        fail "U2 the suite did NOT finish and never entered a test; see $raw"
    fi
fi

# --- U3: the pinned counts -------------------------------------------------

declared=$(grep '^UT-RUN ' "$report" | tail -1 | awk '{print $2}' || true)
declared_dec=$((16#${declared:-0}))
n_skip=$(grep -c '^UT-SKIP ' "$report" || true)
n_pass=$(grep -c '^UT-PASS ' "$report" || true)
n_fail=$(grep -c '^UT-FAIL ' "$report" || true)

count_ok=1
[ "$declared_dec" -eq "$UT_EXPECTED_TESTS" ] || count_ok=0
[ "$n_skip" -eq "$UT_EXPECTED_SKIPPED" ] || count_ok=0
[ "$((n_pass + n_fail))" -eq "$UT_EXPECTED_RUN" ] || count_ok=0

if [ "$count_ok" -eq 1 ]; then
    pass "U3 counts as pinned: $UT_EXPECTED_TESTS cases, $UT_EXPECTED_RUN run, $UT_EXPECTED_SKIPPED excluded"
else
    fail "U3 counts do NOT match the pins: $declared_dec cases / $((n_pass + n_fail)) run / $n_skip excluded, pinned $UT_EXPECTED_TESTS/$UT_EXPECTED_RUN/$UT_EXPECTED_SKIPPED"
fi

# The generator's own manifest is a third statement of the same numbers, from
# the source rather than from the run. It disagreeing with the pins means the
# image and the sources are out of step — a stale build.
if [ -f "$UT_MANIFEST" ]; then
    m_total=$(grep -cE '^[0-9A-F]{2} (RUN|SKIP) ' "$UT_MANIFEST" || true)
    m_skip=$(grep -cE '^[0-9A-F]{2} SKIP ' "$UT_MANIFEST" || true)
    if [ "$m_total" -ne "$UT_EXPECTED_TESTS" ] || [ "$m_skip" -ne "$UT_EXPECTED_SKIPPED" ]; then
        fail "U3 the generated manifest says $m_total cases / $m_skip excluded — the image in $UT_NEX is stale, rebuild"
    fi
fi

# --- U4: the report is internally consistent -------------------------------

if [ -n "$done_line" ]; then
    set -- $done_line
    d_pass=$((16#$3)); d_fail=$((16#$4)); d_skip=$((16#$5))
    if [ "$d_pass" -eq "$n_pass" ] && [ "$d_fail" -eq "$n_fail" ] && [ "$d_skip" -eq "$n_skip" ]; then
        pass "U4 the runner's totals match the lines it printed ($n_pass passed, $n_fail failed, $n_skip excluded)"
    else
        fail "U4 the runner claims $d_pass/$d_fail/$d_skip pass/fail/skip but printed $n_pass/$n_fail/$n_skip"
    fi
else
    fail "U4 cannot check the totals: no UT-DONE line"
fi

# --- U5: nothing failed ----------------------------------------------------

if [ "$n_fail" -eq 0 ] && [ "$n_pass" -gt 0 ]; then
    pass "U5 all $n_pass tests that ran passed"
else
    fail "U5 $n_fail of $((n_pass + n_fail)) tests FAILED"
    grep '^UT-FAIL ' "$report" | while read -r _ idx addr; do
        name=$(awk -v i="$idx" '$1==i {print $3}' "$UT_MANIFEST" 2>/dev/null || true)
        log "        test $idx ${name:-?} — assertion at 0x$addr"
    done
    log "      Map an address to its source line with:"
    log "        grep -n ' <ADDR> ' $OUT/ut-headless.list"
fi

# --- verdict ---------------------------------------------------------------

log ""
checks=5
if [ "$failures" -eq 0 ]; then
    verdict="$checks/$checks checks passed  ($n_pass tests passed, $n_skip excluded as zsim-dependent)"
else
    verdict="$failures of $checks checks FAILED"
fi
log "$verdict"
log "  report:    $report"
log "  jnext log: $raw"

exit "$((failures > 0 ? 1 : 0))"
