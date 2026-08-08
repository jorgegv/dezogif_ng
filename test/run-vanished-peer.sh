#!/usr/bin/env bash
#
# PROBE B — the vanished-peer probe. Issue #15 / issue #19.
#
#     sudo test/run-vanished-peer.sh --host 192.168.1.42
#     sudo test/run-vanished-peer.sh --host X --no-lift --recover 210
#     sudo test/run-vanished-peer.sh --clean        # remove everything, do nothing else
#     test/run-vanished-peer.sh --host X --dry-run  # print the plan, touch nothing
#
# ===========================================================================
# EXACTLY WHAT THIS CHANGES ON YOUR MACHINE — READ THIS BEFORE RUNNING IT
# ===========================================================================
#
# It creates ONE custom iptables chain in the filter table and hooks it into
# OUTPUT, then puts one DROP rule in that chain per abandoned connection:
#
#     iptables -N DEZOGIF_PROBE
#     iptables -I OUTPUT 1 -j DEZOGIF_PROBE
#     iptables -A DEZOGIF_PROBE -p tcp -d <NEXT_IP> --sport <P> --dport 11000 -j DROP
#
# and removes all of it on the way out, in this order:
#
#     iptables -D OUTPUT -j DEZOGIF_PROBE      # unhook FIRST: traffic is normal again
#     iptables -F DEZOGIF_PROBE                # then empty it
#     iptables -X DEZOGIF_PROBE                # then delete it
#
# `iptables -S` is printed before and after, so the change and its removal are
# both in the run's own transcript.
#
# WHY A DEDICATED CHAIN RATHER THAN RULES IN `OUTPUT` DIRECTLY. Because cleanup
# has to be right even when the script dies badly, and this is the shape where
# it can be:
#
#   * Teardown is three fixed commands that do not depend on what was added, so
#     a rule this script never got to record cannot survive it.
#   * Every deletion is BY SPECIFICATION (`-D OUTPUT -j DEZOGIF_PROBE`), never
#     by index. Indices shift under you; the spec does not.
#   * UNHOOKING IS THE FIRST STEP AND IS SUFFICIENT ON ITS OWN. The moment the
#     jump is gone, nothing in the chain can affect a packet — so even if the
#     flush and the delete both fail, the user's network is already back to
#     normal and what is left behind is an unreferenced, inert chain.
#   * A leftover chain is HARMLESS and self-announcing, where a leftover
#     `-A OUTPUT ... -j DROP` silently blackholes the user's own Next.
#   * `--clean` removes it wholesale, whatever a previous run left, and this
#     script runs the same teardown at startup before it creates anything.
#
# WHY EACH DROP RULE IS SCOPED TO ONE SOURCE PORT, which is the other half of
# keeping this contained. The blackhole must STAY UP while the measurement runs
# — remove it and our own kernel answers the module's retransmissions with a
# RST, which frees the slot and destroys the thing being measured. A rule
# written as "drop everything to the Next's port 11000" would therefore also
# blackhole the probe's own later connections, and there would be nothing left
# to measure with. Binding each doomed socket to a known local port and scoping
# its rule to that port is what lets one connection vanish while every other
# connection to the same machine keeps working.
#
# ===========================================================================
# TWO LIMITS OF THE TEARDOWN, BOTH MEASURED RATHER THAN REASONED ABOUT
# ===========================================================================
#
# 1. SIGKILL CANNOT BE TRAPPED, so `kill -9` at this script leaves the chain —
#    which is precisely why the chain shape was chosen: what survives is inert
#    the moment it is unhooked, and `--clean` removes it wholesale.
#
#    AND THE PROBE OUTLIVES IT. Killed with -9, this script cannot reap its
#    child, so the Python probe goes on running and goes on ADDING rules to the
#    surviving chain until it finishes. It can only ever touch the chain it was
#    given, so nothing outside is at risk — but "the chain survives, --clean
#    fixes it" is not the whole picture. After a `kill -9`, do both:
#
#        sudo pkill -f vanished-peer-probe.py
#        sudo test/run-vanished-peer.sh --clean
#
# 2. SIGINT IS UNAVAILABLE IN ONE INVOCATION SHAPE, and it is not this one.
#    A script backgrounded by a NON-INTERACTIVE shell with no job control —
#    `sh -c './script &'` — is entered with SIGINT (and SIGQUIT) already set to
#    SIG_IGN, and a signal ignored at exec cannot be trapped afterwards.
#    Measured here, from /proc/<pid>/status rather than from the specification:
#    `SigIgn: 0000000000000006`, bits 2 and 3, against `SigCgt: 0000000000014000`
#    for SIGTERM and SIGCHLD.
#
#    THE FIREWALL IS NEVER LEFT BROKEN BY IT. An ignored signal does not kill
#    the process: the run simply carries on and its EXIT trap still cleans up
#    when it finishes or is asked to stop. What is unavailable is the
#    early-abort route, not the teardown. SIGTERM is caught in every shape
#    tested, so use that from a harness.
#
# ===========================================================================
# WHAT IT MEASURES
# ===========================================================================
#
# Issue #19: the module holds a small number of inbound connections and nothing
# in the stub ever freed one. (Since #19's fix esp_recover sweeps every link id
# with AT+CIPCLOSE, so one CAN be reclaimed — on a recovery, which needs
# ESP_FAULT_LIMIT consecutive faults. This probe produces none: its peers are
# blackholed, the stub stays healthy, and nothing here ever reclaims. The
# measurement is unchanged.) Issue #15: a real Next stopped serving anyone and
# needed a power cycle, with TCP accept latency degrading 83 ms -> 389 ms ->
# timeout beforehand. The hypothesis is that #15 IS #19.
#
# A cleanly closed connection is already measured NOT to leak a slot (#15's
# E-C: 12 rounds of connect + abortive RST, accept latency flat at 4-12 ms).
# An RST frees the slot; so does a FIN. The leak needs a peer that goes away
# with NEITHER — which is what this produces, and which no client can produce
# from userspace alone. That is the entire reason this one needs root.
#
# So it answers: is an abandoned slot EVER reclaimed without a power cycle?
#
# ===========================================================================
# --no-lift, AND WHY IT IS A DIFFERENT QUESTION RATHER THAN A LOUDER ONE
# ===========================================================================
#
# By default phase 2 takes the blackhole down and THEN waits. That order is
# what bounds the claim: our kernel starts answering the module's
# retransmissions the instant the rule goes, so a fresh client served
# afterwards says the slot comes back once the module is TOLD.
#
# --no-lift leaves the rule up across that wait. Nothing of ours — no FIN, no
# RST, no retransmission — reaches the module about those peers, so a fresh
# client served afterwards is the module reclaiming a slot BY ITSELF. That is
# the question an enforced AT+CIPSTO idle timeout raises and the default path
# structurally cannot ask.
#
# THE TEARDOWN IS UNCHANGED AND UNCONDITIONAL. The rules still come down in the
# same EXIT trap, in the same three commands, whatever happens and whatever
# flags were passed. What --no-lift changes is only WHEN inside the run they
# stop being the last word: never, rather than at the start of phase 2.
#
# The probe's wait then runs from the LAST peer going silent rather than from
# the lift, since with nothing lifted there is no lift to time from — and
# because the peers vanish one at a time, so timing from anywhere earlier would
# give the last of them less than --recover seconds.
#
# ===========================================================================
# WHAT IT CANNOT ESTABLISH
# ===========================================================================
#
# * It cannot show that a vanished peer is what happened on 2026-08-05. It
#   shows what a vanished peer COSTS. Issue #15 must not be closed on it.
# * Its phase 2 recovery, ON THE DEFAULT PATH, is not the module recovering by
#   itself: taking the blackhole down lets our own kernel RST the module's
#   retransmissions, which is new information arriving from outside. Read it as
#   "the slot comes back once the module is TOLD", never as "it comes back on
#   its own". Under --no-lift that reading inverts — and still does not say
#   WHICH slot came back or WHAT freed it.
# * Nothing here reads the Next's screen.
#
# ===========================================================================

set -euo pipefail

CHAIN=DEZOGIF_PROBE
HOST=""
PORT=11000
PEERS=6
RECOVER=20
TIMEOUT=10
PEER_SETTLE=0.5
# Only the emulator harness ever passes this. Against a Next the number of
# vanished peers the module tolerates is the UNKNOWN BEING MEASURED, and a probe
# that insisted on an answer would not be an instrument.
EXPECT_CEILING=0
DRY_RUN=""
CLEAN_ONLY=""
# An ARRAY rather than a string, so the flag is passed through as one argv
# element or as nothing at all — no word splitting, and no second copy of the
# probe's long command line under an `if`. Empty-array expansion under `set -u`
# is safe from bash 4.4 and this repository's benches are bash 5.
NO_LIFT=()
PROBE=$(dirname "$0")/vanished-peer-probe.py

usage() {
    cat <<EOF
usage: sudo $0 --host <ip> [options]
       sudo $0 --clean
       $0 --host <ip> --dry-run

  --host <ip>      the Next (or 127.0.0.1 for a headless jnext)
  --port <n>       default $PORT
  --peers <n>      how many peers to make vanish, default $PEERS
  --recover <s>    seconds to wait before asking one last time, default $RECOVER.
                   Measured from the LIFT by default, and from the LAST peer
                   going silent under --no-lift
  --no-lift        do NOT take the blackhole down before that wait. Nothing of
                   ours then tells the module the peers are gone, so a fresh
                   client served afterwards is the module reclaiming a slot BY
                   ITSELF rather than being told. The teardown below is
                   unchanged and still removes every rule
  --peer-settle <s>
                   seconds between one iteration's fresh client closing and the
                   next doomed peer connecting, default $PEER_SETTLE. A module
                   needs a moment to notice a clean close, and a slot counted as
                   still-in-use because we did not wait reads as a leak
  --timeout <s>    seconds per DZRP exchange, default $TIMEOUT
  --expect-ceiling <n>
                   emulator harness only: exit 3 unless fresh clients survived
                   exactly <n> vanished peers. NEVER pass this for hardware
  --dry-run        print the firewall plan and exit; needs no root
  --clean          remove the chain this probe uses and exit

Read the header of this file first: it states every rule this adds.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --host)    HOST=$2; shift 2 ;;
        --port)    PORT=$2; shift 2 ;;
        --peers)   PEERS=$2; shift 2 ;;
        --recover) RECOVER=$2; shift 2 ;;
        --peer-settle) PEER_SETTLE=$2; shift 2 ;;
        --timeout) TIMEOUT=$2; shift 2 ;;
        --expect-ceiling) EXPECT_CEILING=$2; shift 2 ;;
        --no-lift) NO_LIFT=(--no-lift); shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --clean)   CLEAN_ONLY=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'ERROR: unknown argument %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
done

die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log()  { printf '%s\n' "$*"; }

IPT="iptables -w"

# --- the plan, always printed before anything happens ----------------------

print_plan() {
    cat <<EOF
PROBE B will make these firewall changes, and undo them on the way out:

  $IPT -N $CHAIN
  $IPT -I OUTPUT 1 -j $CHAIN
  $IPT -A $CHAIN -p tcp -d ${HOST:-<host>} --sport <local-port> --dport $PORT -j DROP   (x$PEERS)
EOF
    # The mid-run flush is a firewall change like any other and belongs in the
    # plan, so that "what --no-lift does" is visible here rather than only in
    # the prose. It is the ONE line that differs between the two paths.
    if [ ${#NO_LIFT[@]} -eq 0 ]; then
        cat <<EOF

  ...then, at the start of phase 2, the blackhole comes down mid-run:

  $IPT -F $CHAIN
EOF
    else
        cat <<EOF

  ...and with --no-lift there is NO mid-run flush. Every DROP above stays in
  place through phase 2's wait, so nothing of ours tells the module its peers
  are gone. They come down only in the teardown below.
EOF
    fi
    cat <<EOF

  ...then, always:

  $IPT -D OUTPUT -j $CHAIN
  $IPT -F $CHAIN
  $IPT -X $CHAIN

Nothing outside the chain $CHAIN is touched, and unhooking it is the first
thing the teardown does — so even a failed teardown leaves your traffic alone.
That teardown runs from an EXIT trap and is not affected by --no-lift.
EOF
}

if [ -n "$DRY_RUN" ]; then
    print_plan
    log ""
    log "--dry-run: nothing was changed."
    exit 0
fi

# --- teardown, used at startup, at exit, and by --clean --------------------
#
# Idempotent by construction: every step is guarded and a missing chain is not
# an error. Unhooking is FIRST and is what actually matters.

teardown_chain() {
    local i
    for i in 1 2 3 4 5 6 7 8; do
        $IPT -C OUTPUT -j "$CHAIN" 2>/dev/null || break
        $IPT -D OUTPUT -j "$CHAIN" 2>/dev/null || break
    done
    $IPT -F "$CHAIN" 2>/dev/null || true
    $IPT -X "$CHAIN" 2>/dev/null || true
}

chain_present() {
    $IPT -S 2>/dev/null | grep -qE -- "(^-N $CHAIN\$|-j $CHAIN\$)"
}

# The loud failure the header promises. Named commands, not a description of
# them: somebody reading this at 2am must be able to paste it.
report_leftovers() {
    printf '\n'
    printf '*** THE FIREWALL WAS NOT FULLY CLEANED UP. RUN THIS BY HAND, NOW: ***\n' >&2
    printf '\n' >&2
    printf '    sudo %s -w -D OUTPUT -j %s\n' iptables "$CHAIN" >&2
    printf '    sudo %s -w -F %s\n' iptables "$CHAIN" >&2
    printf '    sudo %s -w -X %s\n' iptables "$CHAIN" >&2
    printf '\n' >&2
    printf 'Until the first of those runs, traffic from this host to %s:%s may be\n' \
           "${HOST:-the target}" "$PORT" >&2
    printf 'blackholed. What is present now:\n' >&2
    $IPT -S 2>/dev/null | grep -- "$CHAIN" >&2 || true
    printf '\n' >&2
}

[ "$(id -u)" -eq 0 ] || die "this probe needs root to add and remove a firewall rule. Run it with sudo, or pass --dry-run to see exactly what it would do."
command -v iptables >/dev/null 2>&1 || die "iptables is not installed"

if [ -n "$CLEAN_ONLY" ]; then
    log "Before:"; $IPT -S | sed 's/^/  /'
    teardown_chain
    log ""
    log "After:"; $IPT -S | sed 's/^/  /'
    if chain_present; then
        report_leftovers
        exit 1
    fi
    log ""
    log "$CHAIN is gone."
    exit 0
fi

[ -n "$HOST" ] || { usage >&2; exit 2; }
[ -f "$PROBE" ] || die "probe not found: $PROBE"
command -v python3 >/dev/null 2>&1 || die "python3 is required"

print_plan
log ""
log "=== iptables -S, BEFORE ==="
$IPT -S | sed 's/^/  /'
log ""

# --- traps, armed BEFORE the first change ---------------------------------
#
# The order here is the whole safety argument and it is not decoration.
# ERRORS.md records four wrong attempts at exactly this shape in run-esp.sh:
#
#  * the trap is armed BEFORE anything is created, because the window between
#    creating and arming is precisely where an interrupt leaves a rule behind;
#  * `chain_created` is declared EMPTY first, because under `set -u` an unset
#    variable inside a handler aborts it before it reaches the cleanup;
#  * a handler that merely RETURNS does not stop a bash script — the shell
#    defers the signal, runs the handler and carries on — so INT and TERM get
#    handlers that EXIT, and the EXIT trap does the cleaning on the way out.
#
# AND A FOURTH, MEASURED HERE RATHER THAN INHERITED. Bash DEFERS a trapped
# signal until the running FOREGROUND command returns. With the probe run in
# the foreground, `kill -INT` at this script reached it and then sat on it for
# as long as the probe had left to run — observed, with the chain still hooked
# into OUTPUT throughout, and the teardown eventually running perfectly several
# minutes later. In a terminal that never shows: Ctrl-C signals the whole
# process GROUP, so the probe dies too and the trap runs at once. Anything
# scripted — a harness, a timeout, a CI runner — signals one pid and gets the
# deferral.
#
# So the probe runs in the BACKGROUND and this script `wait`s for it. `wait` is
# interruptible: the trap fires immediately, and the handler kills the child
# before the chain comes down. For a teardown whose failure mode is blackholing
# the user's own network, "it cleans up eventually" is not good enough.

chain_created=""
probe_pid=""
cleanup() {
    # The child first: it is the only thing that can still ADD rules, and it
    # must not be alive to do that while the chain is being removed.
    if [ -n "$probe_pid" ] && kill -0 "$probe_pid" 2>/dev/null; then
        kill "$probe_pid" 2>/dev/null || true
        # Bounded, then violent. A probe that will not go must not turn a
        # firewall teardown into a hang.
        for _ in $(seq 20); do
            kill -0 "$probe_pid" 2>/dev/null || break
            sleep 0.1
        done
        kill -9 "$probe_pid" 2>/dev/null || true
        wait "$probe_pid" 2>/dev/null || true
    fi
    if [ -n "$chain_created" ]; then
        teardown_chain
    fi
    if chain_present; then
        report_leftovers
        exit 1
    fi
    if [ -n "$chain_created" ]; then
        printf '\n=== iptables -S, AFTER (chain %s removed) ===\n' "$CHAIN"
        $IPT -S | sed 's/^/  /'
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# A previous run that died badly, or a chain somebody left: same teardown,
# before anything of ours exists.
teardown_chain

$IPT -N "$CHAIN"
chain_created=1
$IPT -I OUTPUT 1 -j "$CHAIN"

log "Chain $CHAIN created and hooked into OUTPUT. Teardown is armed."
log ""

# BACKGROUNDED AND WAITED FOR, so a signal reaches the teardown at once — see
# the fourth bullet above. The probe's stdout is this script's, so nothing about
# the output changes.
#
# `|| rc=$?` and not `rc=$?` on the next line: `set -e` would kill the script at
# the `wait` itself, so the assignment would never run and the EXIT trap would
# report the probe's status as the shell's. The cleanup happens either way —
# that is what the EXIT trap is for — but the exit code would be wrong, and an
# instrument that mis-states whether it ran is worse than one that fails.
python3 "$PROBE" \
    --host "$HOST" --port "$PORT" \
    --chain "$CHAIN" --peers "$PEERS" \
    --recover "$RECOVER" --timeout "$TIMEOUT" \
    --peer-settle "$PEER_SETTLE" \
    --expect-ceiling "$EXPECT_CEILING" \
    "${NO_LIFT[@]}" &
probe_pid=$!

rc=0
wait "$probe_pid" || rc=$?
probe_pid=""

exit "$rc"
