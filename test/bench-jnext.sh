# shellcheck shell=bash
#
# Shared teardown for every bench here that starts jnext — issue #17.
#
# WHAT THIS IS FOR, and it is not tidiness.
#
# Every bench records the PID of the `timeout` WRAPPER, not of the emulator:
#
#     timeout "$RUN_TIMEOUT" "$JNEXT" ... &
#     jnext_pid=$!
#
# so `kill "$jnext_pid"; wait "$jnext_pid"` reaps the wrapper. `wait` returns
# when the WRAPPER has gone — not when jnext has gone, and not when port 11000
# is free. `timeout` does forward SIGTERM to its child and that has been
# measured to work here in well under 2 s; nothing in the script REQUIRED it to,
# and nothing noticed if it did not.
#
# The consequence is the worst failure mode this repository has. The `flock`
# mutex serialises SCRIPTS, and the thing that binds the port is a PROCESS that
# can outlive one — so a bench could drop the lock with its own emulator still
# listening on 11000, and the next lock holder's client would be answered by it.
# Observed on 2026-08-05 with three agents all correctly holding the lock: a
# jnext belonging to a run that had already FINISHED, by its own artefact
# mtimes, was alive and bound to 127.0.0.1:11000. MEMORY.md's standing warning
# applies — a contaminated run can come out GREEN, answered by somebody else's
# healthy stub, and a green light nobody can trust silently threatens every
# conclusion resting on it.
#
# So the departure is CHECKED rather than assumed, and a bench that cannot
# confirm it fails loudly instead of reporting a verdict it cannot stand behind.
#
# THE PROPAGATION FAILURE HAS NEVER BEEN REPRODUCED HERE. This is not the repair
# of a known mechanism; it is a refusal to proceed on an assumption. Read it as
# that and nothing more.
#
# WHY A SHARED FILE RATHER THAN A COPY IN EACH SCRIPT. Because a per-script copy
# is exactly what produced issue #17: the fix was written once, in
# run-client-status.sh, and the other six benches never got it. Six copies of
# forty lines of reasoning is six places for the next correction to miss. This
# file DEFINES FUNCTIONS AND DOES NOTHING ELSE — no `set`, no traps, no
# side effects — so sourcing it cannot disturb a caller's `set -euo pipefail` or
# its own trap wiring, which ERRORS.md's `cp --reflink` entry spent four wrong
# mechanisms getting right.
#
# Usage, in a script that has already armed its own traps:
#
#     . "$(dirname "$0")/bench-jnext.sh"
#     ...
#     kill "$jnext_pid"; wait "$jnext_pid"    # the wrapper, as before
#     bench_await_departure "$sd"             # and now the emulator, for real

# bench_die <message> — the loud failure. Named apart from each script's own
# `die` so sourcing this cannot silently redefine one.
bench_die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# bench_jnext_supports <binary> <flag> — does this jnext's --help mention <flag>?
#
# NOT `"$JNEXT" --help | grep -q -- <flag>`, WHICH IS WHAT EVERY BENCH HERE USED
# TO DO AND WHICH REPORTS THE OPPOSITE OF THE TRUTH. jnext writes its help in
# block-buffered CHUNKS — strace says three writes of 4096, 4096 and 1765 bytes,
# not 134 per-line ones; `grep -q` exits the moment it matches, inside an early
# chunk; jnext's next write then gets SIGPIPE and dies with 141; and
# `set -o pipefail` — which every bench sets — makes the pipeline carry that 141
# even though the match SUCCEEDED. So the check failed exactly when the flag was
# present and not in the final chunk of output.
#
# Measured rather than inferred: 10 runs of 10 returned 141, and every bench in
# this repository that takes this path refused to start against jnext 0.99.127,
# each blaming the emulator for a flag it has. It is not a pipe-buffer race —
# the help is 10 KB against a 64 KB buffer; the writer is simply still writing
# when the reader has gone.
#
# The command substitution reads to EOF, so there is no early close to signal,
# and `|| true` keeps a jnext that exits non-zero on --help from tripping the
# caller's errexit before the answer can be given.
bench_jnext_supports() {
    local help
    help=$("$1" --help 2>&1 || true)
    case "$help" in
        *"$2"*) return 0 ;;
        *)      return 1 ;;
    esac
}

# _bench_abs <path> [cwd] — <path> in absolute form, WITHOUT requiring it to
# exist. The working image is usually unlinked before departure is checked, so
# anything that stats the file (realpath, readlink -f) would be wrong here.
_bench_abs() {
    case "$1" in
        /*) printf '%s\n' "$1" ;;
        *)  printf '%s/%s\n' "${2:-$PWD}" "$1" ;;
    esac
}

# bench_jnext_pids <image>... — the PIDs of running jnext processes whose
# --sdcard is one of <image>. Nothing else, ever.
#
# THE SCOPING IS LOAD-BEARING AND IS NOT A PREFERENCE. A bare `pkill jnext`
# would make issue #17 WORSE than the bug it fixes: it would kill a correctly
# serialised concurrent run belonging to another agent. Each bench copies the
# reference SD image to a path of its own, so "our emulator" has an exact
# definition and a sweep can never reach past it.
#
# AND THE MATCH MUST NOT MATCH ITSELF. run-client-status.sh's first version used
# `pgrep -f <image basename>`, which matches ANY process whose command line
# merely mentions the image — including the diagnostic command you typed to look
# for survivors. Measured: a plain `pgrep -f sd-client-status` reported a hit
# with no jnext running at all (ERRORS.md). So: exact process name, our own uid,
# and then the argument read out of /proc.
#
# The image is compared as an ABSOLUTE path, resolved against each process's own
# /proc/<pid>/cwd rather than against ours. $OUT defaults to the relative `build`,
# so two agents running the same bench in two different WORKTREES both put
# `--sdcard build/sd-dzrp.img` on the command line — identical strings naming
# different files. A substring match would sweep the other worktree's emulator,
# which is the thing this whole file exists to prevent.
bench_jnext_pids() {
    [ "$#" -gt 0 ] || return 0

    local p raw cwd tok prev hit want
    local -a wanted=()
    for tok in "$@"; do
        wanted+=("$(_bench_abs "$tok")")
    done

    for p in $(pgrep -x -u "$(id -u)" jnext 2>/dev/null || true); do
        # A process that exits between the pgrep and here is a process that has
        # departed, which is what we were waiting for.
        cwd=$(readlink "/proc/$p/cwd" 2>/dev/null) || continue
        raw=$(tr '\0' '\n' <"/proc/$p/cmdline" 2>/dev/null) || continue

        prev=""
        hit=""
        while IFS= read -r tok; do
            if [ "$prev" = "--sdcard" ]; then
                tok=$(_bench_abs "$tok" "$cwd")
                for want in "${wanted[@]}"; do
                    if [ "$tok" = "$want" ]; then
                        hit=$p
                    fi
                done
            fi
            prev=$tok
        done <<<"$raw"

        if [ -n "$hit" ]; then
            printf '%s ' "$hit"
        fi
    done
    return 0
}

# bench_await_departure <image>... — block until no emulator of OURS is running
# on <image>, escalating, and DIE naming the survivors rather than returning.
#
# The caller has already killed the `timeout` wrapper and reaped it; this is
# what turns "the wrapper is gone" into "the emulator is gone". The escalation
# is deliberately patient before it is violent: ~2 s for the forwarded SIGTERM
# to land, then SIGTERM straight at the emulator, then SIGKILL at ~6 s, then a
# loud failure at ~10 s.
#
# Safe to call from an EXIT trap: `exit` inside one sets the script's final
# status, so a surviving emulator turns a green run red, which is the point.
bench_await_departure() {
    [ "$#" -gt 0 ] || return 0

    # Every caller of this is reached twice on the failing path — once where the
    # run ends, and again from the EXIT trap that the resulting `exit` fires. A
    # second full budget would double the wait and print the same wall of text
    # twice, which reads as two faults. Report once, then refuse in one line.
    if [ -n "${_bench_departure_failed:-}" ]; then
        printf 'ERROR: still refusing to continue — see the departure failure above.\n' >&2
        exit 1
    fi

    command -v pgrep >/dev/null 2>&1 || bench_die \
        "pgrep is not available, so this bench cannot confirm its own emulator has exited. Refusing to report a verdict it cannot stand behind (issue #17)."

    local i left
    for i in $(seq 40); do
        left=$(bench_jnext_pids "$@")
        if [ -z "$left" ]; then
            return 0
        fi
        # shellcheck disable=SC2086
        if [ "$i" -eq 8 ]; then
            kill $left 2>/dev/null || true
        fi
        # shellcheck disable=SC2086
        if [ "$i" -eq 24 ]; then
            kill -9 $left 2>/dev/null || true
        fi
        sleep 0.25
    done

    _bench_departure_failed=1
    bench_die "an emulator this bench started is STILL RUNNING after being killed (PIDs $(bench_jnext_pids "$@"); images: $*). Refusing to go on or to report a result: while it lives it can hold port 11000, and the next bench to take the lock would be answered by it. Kill it by hand and re-run."
}

# bench_require_port_free <port> <context...> — refuse to start a run when
# something else is already listening.
#
# The pre-flight check every bench already has covers the moment the script
# starts. This is the same question asked again immediately before each
# individual run, because a foreign listener — another agent's stale process,
# CSpect — can appear between two runs of one script, and the run that inherits
# it can come out GREEN on somebody else's answers.
bench_require_port_free() {
    local port=$1
    shift
    command -v ss >/dev/null 2>&1 || return 0
    # `grep -c` and not `grep -q`, for the reason bench_jnext_supports above
    # exists — and here the failure DIRECTION is the dangerous one: a pipeline
    # made non-zero by an early-exiting reader would be read as FALSE, i.e. as a
    # free port while one was occupied, which is the contaminated-and-GREEN run
    # the message below is about. -c must read to EOF to count, so it cannot
    # close early. (`ss` is measured to write its whole output in ONE syscall,
    # so the hazard was never live here — a property of ss, not of this code,
    # which is exactly how the jnext one arrived with nothing here changing.)
    #
    # THE `|| true` IS NOT PART OF THAT, and an earlier comment said it was:
    # `grep -c` exits 1 when it counts zero, which is the ORDINARY case for a
    # free port, and under `set -e` an assignment carrying that status kills the
    # script silently — every time the check passes. Demonstrated by removing it.
    #
    # And the test is written to fail CLOSED. An empty or non-numeric capture —
    # `ss` absent, a broken pattern — must read as "occupied" and stop the run,
    # never as "free": ${hits:-1} makes anything that is not exactly 0 die.
    # Unreachable while $port is a numeric literal at every call site, which it
    # is; written this way because the asymmetry was found by review, not
    # because it fired.
    local hits
    hits=$(ss -ltn 2>/dev/null | grep -cE "127\.0\.0\.1:$port\b" || true)
    if [ "${hits:-1}" != "0" ]; then
        bench_die "something is listening on 127.0.0.1:$port $* — a run started now would be answered by it, and a contaminated run can come out GREEN (issue #17)"
    fi
}
