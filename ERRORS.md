# ERRORS.md — failed approaches worth not repeating

Anything that took more than two attempts to build or work. Check this before
attempting similar logic.

---

## `git checkout <file>` to undo an experiment, on a file holding uncommitted work

**Symptom.** An hour of uncommitted edits to `src/transport_esp.asm` gone, in
one command, with no error and nothing to undo it — `git checkout` writes no
reflog entry for the working tree.

**Cause.** The ASSERT added with the change had to be *watched to fail*, which
this project rightly insists on, so the bounded string was temporarily length-
ened with `sed -i`, built twice — 24 assembles, 25 goes red, exactly as intended
— and then the experiment was reverted with

```sh
git checkout src/transport_esp.asm
```

That restores the file from the **index**, and the index held `HEAD`'s version,
because none of the real work had been staged. So it did not undo the `sed`; it
undid everything since the last commit, of which the `sed` was the last two
characters.

**Fix, and it is a habit rather than a command.** **Commit before running any
destructive experiment on a file you are editing.** The work was redone from
the conversation's own record in ten minutes, which was luck: a longer session
or a file edited by hand would have lost more.

Where a commit is genuinely unwanted, `cp file file.bak` before the `sed` and
`mv` it back is two words longer and cannot reach anything else. `git stash`
also works and, unlike `checkout`, is recoverable.

**Lesson.** `git checkout -- <path>` is the one common git command that
**destroys uncommitted work silently and irrecoverably**; `reset`, `rebase` and
even `reset --hard` all leave something in the reflog. Treat it as `rm`, not as
"undo", and never point it at a file that is mid-change. And note what made it
tempting: the experiment and the real work were **in the same file**, so there
was no revert that could tell them apart. If a check needs a file mutilated,
mutilate a copy.

---

## A pre-flight check that answered "no" *because* the answer was yes

**Symptom.** Every bench in this repository refused to start against jnext
0.99.127, each with a message blaming the emulator for a flag it has:

```
ERROR: this jnext has no --esp-listen-address (need >= 0.99.118); rebuild it
```

`jnext --help | grep -- '--esp-listen-address'` prints the option. `make test`,
`make test-unit`, `make test-dzrp-stub` — all of them dead, all of them pointing
at the wrong component.

**Cause, and it is three ordinary things that are only wrong together.** The
check was

```sh
"$JNEXT" --help 2>&1 | grep -q -- '--flag' || die "..."
```

jnext writes its help in **block-buffered chunks**; `grep -q` exits the moment
it matches, inside an early one; jnext's next write then takes **SIGPIPE** and
dies with **141**; and `set -o pipefail` — which every one of these scripts sets,
correctly — carries that 141 out as the pipeline's status.

So `|| die` fired on a pipeline whose grep had **succeeded**, and it fired
precisely when the flag was PRESENT and not in the final chunk of output. Absent flags were reported correctly — `grep -q`
must read to EOF to conclude "no match", so it never closes the pipe early —
which is why the check looked sound for months.

*(An earlier version of this entry said the help was written "a line at a time".
A reviewer straced it and it is wrong: **three writes of 4096, 4096 and 1765
bytes**, not 134 per-line ones, with the matched flag at byte **5786 of 10005** —
inside the second. The conclusion is untouched, because all that matters is that
the writer is still writing when the reader has gone, at whatever granularity.)*

*(And the FIRST correction of it got the third figure wrong — 1382 — which is
worth more than the number. `strace -f` follows forks, and jnext spawns an
ffmpeg-derived child whose own 4096/4096/**1382** banner lands in the same trace;
that child's output never reaches the stdout a bench pipes through, which
`"$JNEXT" --help > file` proves: 9957 bytes, containing `--esp-listen-address`
and no "ffmpeg version" at all. So the trace was real and read off the wrong
process. **A measurement is not evidence until you know whose it is** — the same
disease as this file's `pgrep -f` entry, one tool along, and it was caught by a
reviewer re-running the trace rather than trusting the number.)*

**Not a pipe-buffer race, and that was the first guess.** The help is 10 KB
against a 64 KB pipe buffer, so nothing ever blocked on a full pipe. The buffer
is irrelevant: once the reader is *gone*, any further write raises SIGPIPE
however much room there is. Measured 10 runs of 10, all 141 — deterministic, not
flaky.

**Why it appeared now**, and this is the part worth carrying: nothing in this
repository changed. The check's correctness depended on **where the match falls
in another program's output** — the matched flag at byte 5786 of 10005, inside
the second of three chunks — a property jnext is free to alter in any release,
and did.

**Fix.** One helper in `test/bench-jnext.sh`, not thirteen repaired call sites,
for the reason issue #17 already paid for. It reads to EOF, so there is no early
close to signal:

```sh
help=$("$1" --help 2>&1 || true)
case "$help" in *"$2"*) return 0 ;; *) return 1 ;; esac
```

**Lesson.** `set -o pipefail` and any early-exiting reader (`grep -q`, `head`,
`grep -m1`) are a trap whenever the writer is slower than the reader's first
match — which is most of the time and is not under your control. If you need an
answer *about* a command's output rather than a stream of it, **capture the
output and test the string**; a pipe is for data you intend to read all of. And
when a tool insists it lacks something you can see it has, suspect the question
before the tool.

---

## A signal that was never delivered, and then one that arrived and waited

**Symptom.** Probe B (issue #15) adds one `iptables` chain and removes it from an
`EXIT` trap. Testing the interrupt path: SIGINT was sent, and the chain was still
hooked into `OUTPUT` afterwards with its DROP rules intact. Read at face value
that is a firewall teardown that does not work — the one failure this script
exists to make impossible.

**It took three goes, and only the third was the script's fault.**

**1. The signal was never delivered.** The script runs under `sudo`, so both it
and its child are **root**, and `kill -INT <pid>` from uid 1000 fails with
`EPERM`. Worse, the liveness loop watching for the process to go was
`kill -0 "$pid" 2>/dev/null || break` — which fails with `EPERM` too, so it broke
out immediately and the test reported "gone, and the chain survived". **`kill -0`
is a lie across a uid boundary**: it cannot distinguish "no such process" from
"not yours". `ps -eo pid,args` showed the script and its python child both
running the whole time.

**2. Delivered properly with `sudo kill`, bash DEFERRED it.** A trapped signal is
not acted on until the running **foreground** command returns, and the foreground
command was the probe, with minutes left. The trap then ran perfectly — several
minutes late, with the blackhole in place throughout. In a terminal this never
shows, because Ctrl-C signals the whole process **group**, so the child dies too
and the trap runs at once; anything scripted signals one pid and gets the
deferral.

**3. The real fix.** The probe is backgrounded and the wrapper `wait`s on it.
`wait` is interruptible, so the handler fires immediately, kills the child (which
is the only thing that could still add rules) and then removes the chain.
Measured: cleanup completes in **under 0.5 s** where it had taken minutes, and
SIGTERM exits 143 with nothing left behind.

**The honest limit, demonstrated rather than asserted.** SIGKILL cannot be
trapped, so it leaves the chain. That is why the chain shape was chosen in the
first place — the leftovers are inert once unhooked, `--clean` removes them, and
the next run's startup teardown removes them too. Both were run.

**A fourth shape, found while writing the caveat, and it cost the shell again.**
`pgrep -f sigprobe.sh | head -1` to find the process under test returned **this
shell's own pid**, because the Bash tool's command line contains the script name;
`kill -INT` on it then killed the shell mid-command, and the first `/proc` bitmap
read was of the wrong process entirely — and it read plausibly, which is the
dangerous part. `pgrep -f` matching itself is already written down in
`test/bench-jnext.sh` and in the mutex entry below; it is worth restating that
the lie it tells is not "no match" but **"a match that looks right"**. The fix is
the same one that file uses: exact process name, then the command line read out
of `/proc/<pid>/cmdline` and compared.

**What the corrected measurement then said**, and it is now a caveat in the
wrapper's header rather than a defect: a script backgrounded by a
**non-interactive shell with no job control** (`sh -c './script &'`) is entered
with SIGINT already `SIG_IGN` — `SigIgn: 0000000000000006`, bits for SIGINT and
SIGQUIT, against `SigCgt: 0000000000014000` for SIGTERM and SIGCHLD — and a
signal ignored at exec cannot be trapped. It does not kill the process either, so
the teardown is not at risk; only the early abort is unavailable, and SIGTERM
works in every shape tested.

**Lesson, and this file already carries its cousin.** ERRORS.md's `cp --reflink`
entry records two attempts that tested the wrong *process*; this is the same
disease one layer down — a test that never delivered its *signal*, and a liveness
check that could not have told. **Before concluding a handler is broken, prove
the signal arrived**: `ps` for the process, and remember that `kill -0` answers
"is it mine" as well as "is it there". And when it did arrive and nothing
happened, ask what the shell was busy with before rewriting the handler.

---

## Deleting the ROMs is NOT enough before a pinned hash comparison

**Symptom.** A test-only branch — no file under `src/` touched, `git diff main --
src/ Makefile` empty — reported that the **WiFi ROM had changed**:
`fb9b5e92…` before, `5fd2d3d7…` after. Taken at face value that is a test-only
change that moved a ROM, which is impossible, and it would have meant a `make
bump` for a build nobody had altered.

**Cause.** The comparison ran

```sh
rm -f build/enNextMf.rom build/enNextMf-wifi.rom
make BUILD_TIME=1700000000 mf-rom-wifi
```

The ROM is `cat build/mf_nmi-wifi.bin build/main-wifi.bin`, and **the two `.bin`
files were not deleted**. Their sources had not changed, so make left them alone
— and they had been assembled minutes earlier by a bench run at the *unpinned*
`BUILD_TIME`. The "pinned" build therefore concatenated an unpinned image, and
`BUILD_TIME` is stamped into the ROM.

**Fix.** Delete the intermediates too, or do not hand-roll it at all:

```sh
rm -f build/*.bin build/enNextMf*.rom      # then build pinned
make check-reproducible                    # or this, which builds its own
```

The comparison was then byte-identical both ways, and confirmed a third way by
`git stash`ing the branch and rebuilding from clean `main`.

**This CORRECTS a rule already written down, which is why it is here rather than
in a commit message.** MEMORY.md 2026-08-05 (the identity-line entry) **used to
say** *"Delete the outputs before any pinned comparison"* — and that is exactly
what was done, and it was not sufficient. The output is not the thing make
decides about; **its prerequisites are.** Read "outputs" as "everything
derived", `.bin` files included.

**The correction was announced here before it was MADE there, and that is its
own small lesson.** This entry claimed to correct that wording and edited
nothing, so for one commit the insufficient instruction stood unqualified in the
place a reader actually follows instructions from — MEMORY.md is long and nobody
reads it top to bottom, so a retraction filed only in ERRORS.md reaches nobody
standing at the wrong rule. Fixed in place on 2026-08-06. **Announcing a
correction is not making one**; go and edit the sentence.

**Lesson, and it generalises past this Makefile.** When you pin a variable that
is consumed *inside* a build step, deleting that step's product does not
invalidate the products of the steps before it. Ask what the final artefact is
assembled *from*, and delete that. A build system whose inputs did not change
will cheerfully hand you yesterday's answer to today's question — and here the
answer was a hash, i.e. the one kind of answer that looks unarguable.

---

## A control that would not reproduce the old behaviour — and it was right

**Symptom.** Issue #16's bench needed a client to sit quietly in `cmd_loop`'s
wait so a screenshot could show whether the stub had noticed. The negative
control was a ROM built with `TRANSPORT_WAIT_RX_SECONDS=0` — the loop with no
bound at all, which by construction can never leave. It left anyway: its screen
carried the same 848 bright-red pixels and the same black border as the bounded
build, so N1 and N2 were indistinguishable and neither meant anything.

**The first instinct was that the control was broken**, and two plausible
stories were available — the keypress landing before the exchange, or the frame
counter being mis-tuned. Both were wrong, and both would have been "fixed" by
turning knobs until the numbers looked right.

**Cause, and it was a real defect in the stub.** `esp_flush_chunk` matched
`"SEND OK"` where the module answers `"\r\nSEND OK\r\n"`, so two bytes were left
in the RX FIFO after every reply. `transport_wait_rx` ends on **any** byte from
the module, so it returned at once and `receive_bytes` asked for a command that
was not there. That is why the control could not hold the state: nothing could.

**How it was settled: by making the control's claim impossible to dodge.** A
wait with `WAIT_SECS=0` *cannot* expire, so an "RX Timeout" on that ROM cannot
be the wait. That left one candidate, and the CRLF fix took the same run from
848 bright-red pixels to 0.

**THEN A SECOND MISTAKE, ON TOP OF THE FIRST, AND IT IS THE ONE WORTH THE
ENTRY.** The write-up said the defect cost a `drain_main` "after every single
response". That was never measured — it was inferred from the one client that
had exposed it, which sent a command and then went silent for thirty seconds.
It is also flatly incompatible with C10/C11 passing, since `drain_main` resets
`prgm_state`, and nobody noticed the contradiction until a reviewer asked how
both could be true.

**Measured properly the second time**, with a counter on the timeout path drawn
on the stub's own screen and the inter-command gap swept: **it depends on the
gap, and there are three regimes** — the scan catches a fast follow-up and
nothing happens at all; a follow-up landing in the 100 ms drain is **read off
the wire and discarded**, which is a silent hang; a later one is answered but
costs the reset. A full conformance run: **2** drains, not dozens. The full
table is in MEMORY.md.

So the original claim was wrong in the direction that flattered it, and the real
finding — a band of inter-command gaps in which a command is swallowed — was
strictly worse and had been missed entirely by asserting the scope instead of
sweeping it.

**Two lessons, and the second is the expensive one.**

**When a REMOVAL does not reproduce the old behaviour, that is a measurement,
not a broken control.** This file keeps saying a fix untested by removing it is
a correlation; this is the mirror image. Ask what else could be producing the
symptom before adjusting the harness — the harness is the thing you have not yet
questioned, but it is also the thing you are about to bend until it agrees with
you.

**A measurement establishes its own scope and nothing wider.** 848 pixels from
one client proves a fault occurred in that client's pattern. Turning it into
"every response" needed a second variable — the gap between commands — that was
never varied. **When a finding is stated as a frequency, ask what was swept to
get it**; if the answer is "nothing", the honest claim is the single point that
was actually observed. The correct answer here was not a frequency at all but a
threshold, and it hid a silent command loss that the overstated version would
never have led anyone to look for.

---

## A correctly-held mutex that does not exclude, because the emulator outlived it

**Symptom.** Mid-session, with three agents working in parallel, a bench run
taken **inside** `flock $HOME/tmp/dezogif_ng-bench.lock` found a foreign jnext
alive and holding `127.0.0.1:11000`. Every bench here is wrapped in that lock
precisely so that cannot happen, and a run answered by somebody else's stub can
come out **green** — the failure this project already has an entry for.

**The first diagnosis was wrong, and it was the comfortable one.** "The other
agent skipped the lock." It had not: its script carries the same flock block,
above anything that copies an image or starts an emulator, and both of its
invocations used the outer `BENCH_LOCK_HELD=1 flock …`. The exclusion was in
place the whole time.

**The actual cause is in the shared bench scripts.** `run-dzrp-stub.sh` launches

```sh
timeout "$RUN_TIMEOUT" "$JNEXT" … &
jnext_pid=$!
```

so `jnext_pid` is the **`timeout` wrapper's** pid, not the emulator's. Teardown
kills and `wait`s on the wrapper and then declares the run over, with **no check
that jnext itself has exited and released the port**. A bench can therefore drop
the flock while its emulator is still bound to 11000, and the next lock holder
inherits it. `run-tx-patience.sh`, `run-esp.sh` and `run-ip-boundary.sh` share
the pattern.

**That is the worst shape this failure has**: the mutex is held correctly by
everyone and still does not exclude, because the contaminating process belongs
to a run that has already finished. No amount of discipline at the lock fixes
it.

**Working practice until the scripts are fixed** (filed separately; deliberately
not patched from a branch, because three agents were in those files at once):
check `pgrep -x jnext` **and** `ss -ltn | grep ':11000'` **before and after**
every bench run, not only before, and kill and wait for anything that survives.
Note `pgrep -f jnext` matches its own command line and will lie to you.

**The mechanism was NOT reproduced, and the fix is shaped for that.** Killing
the `timeout` wrapper directly was measured and jnext died in under two
seconds — so this is not a repair of a known propagation failure, it is a refusal
to *proceed* on an assumption. `test/run-client-status.sh`'s teardown now blocks
until the emulator is really gone, escalating `kill` → `kill -9`, and `die`s
naming the surviving PIDs and saying which port they are holding for whom. Each
run also re-checks that nothing is listening on 11000 before it starts, rather
than only once at pre-flight.

**And the sweep that looks for survivors must not match itself.** The first
version used `pgrep -f <image basename>`, which matches **any** process whose
command line merely mentions the image — including the diagnostic command typed
to look for one. Measured: it reported a hit with no jnext running at all. It is
now `pgrep -x jnext` filtered by the image read out of `/proc/<pid>/cmdline`,
which is exact in both directions — it cannot miss our emulator and cannot reach
another agent's.

**Lesson, and it generalises past this repository.** A lock protects a critical
section; it does not protect a **resource** that a process can still hold after
leaving the section. When the thing being excluded is a port, a file or a
device, the release has to be *observed* — the resource seen to be free — and
not inferred from the fact that the code that took it has returned. And when a
mutex appears to have failed, suspect a leaked holder before suspecting a
participant: the second explanation is easier to believe and was, here, a false
accusation.

**CLOSED, issue #17, and three things came out of the fixing that the paragraphs
above did not know.**

**1. The orphan could not be produced even by taking the forwarding away.** The
entry above records that killing the `timeout` wrapper reaches jnext in under two
seconds. It also survives the stronger test: **`kill -9` on the wrapper**, which
`timeout` cannot forward at all, and jnext still died with it — twice, with no
`PR_SET_PDEATHSIG` anywhere in jnext's source to explain it. So the state that
was *observed* cannot be *staged* by any manoeuvre available here, and a survivor
has to be **injected** to be tested at all. What is injected is the condition
that was seen — a jnext belonging to a run that had already finished — and not a
mechanism for it, because the check does not care how the survivor got there and
neither does the invariant.

**2. Fixing it in one script is what made it a repository-wide defect.** The
teardown above was written into `run-client-status.sh` alone. Six other benches
carried the same launch pattern and none of them got it, which is the whole of
issue #17. It is now one sourced file, `test/bench-jnext.sh`, that every bench
calls — because forty lines of reasoning copied seven times is seven places for
the next correction to miss, and this entry is the evidence for that rather than
the argument.

**3. The scope of the sweep needed to be narrower than "the image path", and the
reason is worktrees.** `$OUT` defaults to the relative `build`, so two agents
running the same bench in two different worktrees both put
`--sdcard build/sd-dzrp.img` on the command line: **identical strings naming
different files**. A substring match — which is what the first implementation
used — would have swept the other worktree's emulator, i.e. done precisely what
`pkill jnext` was rejected for. The comparison is now against the **absolute**
path, resolved per process from `/proc/<pid>/cwd`. The general form: when a
pattern identifies "our" process by a path, ask whether that path is relative,
and to *whose* directory.

---

## Clearing a flag in the obvious routine, which one caller bypasses

**Symptom.** Issue #11's fix, first version: two commands queued back to back
were now both answered — and then the *next* client's `CMD_INIT` was silently
ignored, 2 trials in 4. The frame arrived, the stub sent nothing, the client
timed out. Exactly the symptom being fixed, reintroduced by the fix.

**Cause.** The transport can now serve a command out of a held buffer, so
`esp_rx_from_hold` says which source the current chunk comes from. It was
cleared in `esp_require_payload`, which is where the next chunk is asked for —
and that is one of **two** ways a chunk becomes current. `transport_byte_available`
polls through `esp_sync_ipd` **directly**, bypassing it. A chunk taken by the
poll therefore arrived with the flag still set from the previous command, and
the payload was read out of a buffer that had already been consumed.

**Fix.** Clear it in `esp_sync_ipd` — the one routine that makes a *wire* chunk
current, and therefore the one place both paths pass through.

**Lesson, and it is a grep rather than an insight.** When state describes "which
of several sources is current", put the clear where the *source* is selected,
not where a caller asks for more. Before choosing, list the callers:
`grep -n "call esp_sync_ipd"` takes a second and would have shown two. This file
already carries the same shape for control flow — enumerating a routine's exits
from the ones you happened to read — and this is the state-machine version of
it.

**What found it: running the thing.** The bug is invisible in the diff and
obvious in a 4-trial probe. Both versions assemble, both pass the whole
conformance suite (which uses one connection at a time, so it never asks for a
chunk through the poll while a hold is spent), and the difference shows only in
a client that opens a new connection after a collision.

---

## A bench that failed 2 runs in 8 — and the build was fine

**Symptom.** While building `make test-tx-patience` (issue #11), the *control*
started failing: a WiFi ROM at the **shipped** budget, which every other bench
in this repository passes, lost `CMD_INIT` in 2 of 8 probe runs. Taken at face
value that would have destroyed the whole demonstration, because the bench's
contrast is "the injected budget breaks it" and a baseline that breaks on its
own measures nothing.

**Cause, and it is in the harness rather than the stub.** The probe connected
the instant the listening port appeared. The port exists as soon as
`AT+CIPSERVER` is accepted, but the guest then sends `AT+CIFSR` and scans the
answer for `OK` (`esp_query_address`, the tail that swallows the STAMAC line).
A client landing inside that window puts `1,CONNECT` / `1,CLOSED` into the same
scan, and its first command is eaten. The two failing runs are visible in
jnext's own log as a connection accepted **15 ms** after `AT+CIFSR` was
answered, against ~140 ms in the passing ones.

**Fix.** Settle after the listener appears, before the DZRP client connects, and
say in the bench why. The underlying property of bring-up is real and is left
alone: closing it needs `<id>,CONNECT` tracking, which belongs with M3.

**Two wrong mechanisms were asserted before that, both by reasoning.** First,
that the FIFO depth made the `SEND OK` wait unreachable — the depth is 64
(`jnext src/peripheral/uart.h:131`), which nobody had looked up. Second, that a
particular failing run had timed out on the prompt rather than on `SEND OK`;
what actually settled *that* was not the log at all but the controlled
comparison — P1 and P2 differ only in `ESP_TX_PASSES`, so the lost reply can
only be one of the two waits that constant governs. **The arithmetic that came
out of it is the useful part**: the module owes `SEND OK` only once it has taken
the whole chunk, so a 25-byte reply costs ~2 ms and a 240-byte one ~21 ms, which
is why an injected 3.9 ms budget loses the big reply every time and the small
one only sometimes.

**Lesson, and this file already carries two shaped like it.** Before a bench's
*contrast* is evidence, its *baseline* has to be measured — repeatedly, on the
unmodified build. Eight runs cost four minutes and turned "the fix is
load-bearing" from a claim into one. A bench whose control is assumed rather
than run is the same defect as a fix never tested by removing it.

---

## A bound the emulator can never reach is a bound with no test

**Symptom.** None here, and that is the whole entry. `esp_query_address` copied
the address out of `AT+CIFSR`'s answer with

```asm
    ld b,ESP_IP_MAX             ; 15
.char:
    call esp_try_read_raw
    cp 34                       ; the closing quote ends the address
    jr z,.end_of_address
    ld (de),a
    inc de
    djnz .char
    ret                         ; too long: refuse
```

`DJNZ` bounds the number of **passes**, so a 15-character address spends the
15th pass on its 15th character and falls out of the loop **before the pass
that would have read the closing quote**. An address of exactly `ESP_IP_MAX`
characters was refused as too long, and the screen told the user to go and set
up WiFi on a machine that was working perfectly.

Not an edge case: the user's own Next is `192.168.100.136`. Any address with
all four octets in 100-255 is fifteen characters.

**Cause of the DEFECT**, one line: the bound counted passes when the thing that
must be bounded is **stores**. B now counts characters stored and the bound is
tested before storing, so the quote stays readable at every length up to the
maximum. The empty-address test was the same mistake in miniature —
`cp ESP_IP_MAX` against a pass count — and went with it.

**Cause of the MISS, which is the transferable part.** jnext's emulated module
answers `AT+CIFSR` with `192.168.1.50`, and that is a `static constexpr STA_IP`
in `esp01/include/esp01/esp_at.h` with **no command-line option behind it**.
Twelve characters never reach a bound of fifteen. So the boundary was not
"undertested" — it was **unreachable by construction**, and every bench in this
repository was green through the bug, exactly as it would have been through any
other defect at that bound.

**Fix for the miss: move the BOUND, not the input.** `ESP_IP_MAX` is
`IFNDEF`-guarded and the Makefile's `IP_MAX` overrides it, giving each probe
ROM its own name. `test/run-ip-boundary.sh` then builds one at 12 — where
jnext's own answer *is* the maximum-length case — and one at 11, where it is
one too long. Same Z80 code, same emulator, same real `AT+CIFSR` reply over the
same real UART; one build-time constant differs. Shown failing first: against
the old loop the accepting case reports 1044 bright-red pixels of `No WiFi
address`.

A host-side simulation of the loop was the alternative and was rejected: it
would have tested a **transcription** of the routine rather than the routine,
and this file already carries an entry about a mechanism that was reasoned
rather than executed.

**Three sums that had been done in comments are now `ASSERT`s** — the buffer
holds the longest address plus the port, the drawn line fits 32 columns, the
status table has an entry per state. Each was checked to fail when violated,
because an assertion nobody has watched fire is a comment with a keyword in
front of it.

**Lesson, and it is the THIRD time this file has recorded this shape** — after
the `+IPD` reassembly that no payload was ever large enough to trigger, and the
connection id that no test ever let go stale. **When a bound is a constant, ask
what in the test environment could ever produce a value at it.** If nothing
can, no amount of testing will reach it, and the answer is to make the constant
movable rather than to test harder. The number was in a header file the whole
time — again.

---

## A sentinel value that a real peer can legitimately send

**Symptom.** On a real ZX Spectrum Next: the stub came up, the TCP listener
appeared (hardware bench H1 passed, 295 ms), the client connected, and DZRP
commands were consumed and executed — and **every single reply vanished**. No
error on the Next's screen, no bytes on the socket, every check timing out with
`timed out after 0 of 1 bytes`. The WiFi debugger was unusable.

**Cause.** `transport_flush` used `esp_conn_id == 0` to mean "there is nobody to
send to". **Real ESP-AT firmware assigns link id 0 to the first inbound
connection**, so the one thing a working client is guaranteed to look like was
indistinguishable from no client at all.

**The warning was already written down, in this repository, and was overridden
by the code anyway.** MEMORY.md's entry on jnext's ESP server says inbound ids
start at 1 because jnext reserves slot 0 for the guest's outbound
`AT+CIPSTART`, and then says explicitly: that is a **jnext design choice**, do
not promote it to a hardware fact without measuring it. The `+IPD` parser obeyed
— it reads the id and never assumes one. The *sentinel* did not, and nobody
noticed that picking 0 as "impossible" was the same assumption in a second
place.

**Fix.** Not a different magic value. `esp_conn_valid` now carries "is there a
client" and `esp_conn_id` carries only what arrived. `0xFF` was proposed first
and rejected by the user on the right grounds: **the defect was reserving a
value at all**, and reserving a different one just moves the collision somewhere
it does not happen to hurt yet.

**Why no test caught it and no test ever will.** jnext never issues id 0, so
`make test-dzrp-stub` was green before the fix and is green after it. Every
layer of this project's CI is an emulator, and this is a class of bug the
emulator is structurally blind to — not because the bench is weak, but because
the emulator's own numbering is what hid it.

**What did work, and it is the transferable part.** Forcing the parsed id to 0
in a throwaway tree makes jnext reproduce the hardware symptom exactly:
`main`'s code framed 18 inbound commands and issued **zero** `AT+CIPSEND`; the
fixed code framed 16 and issued **8**, as `AT+CIPSEND=0,25`. So when the
emulator cannot reach a state, **inject the state** — a negative control in a
tree you throw away is available even when a committed test is not. It also
executed `esp_put_decimal` with 0 for the first time ever, a path every previous
run had skipped because jnext's ids are 1 and 2.

**Lesson.** A sentinel is a claim that some value can never arrive from outside.
Write that claim down where the value enters, and check it against the *peer's*
specification rather than against the one implementation you can run. "The
emulator never sends it" is not "it cannot arrive" — and when your only test
harness is the thing whose behaviour you assumed, agreement between them is not
evidence.

---

## "These two differ" is not "this one is right"

**Symptom.** A green check that could not fail on the bug it was written for.
The mfselect bench's M9 was added to prove the program names the installed
transport correctly on screen (issue #5). It compared the WiFi-installed run's
status row against the UART-installed run's and required them to differ in
exactly the four columns of the transport name. It passed. An independent
reviewer then **swapped** the two strings in `installed_name()` — every ROM
labelled as the other variant — rebuilt, and the bench passed **9/9, M9
included**.

**Cause.** The check knew nothing about *either* row on its own. Two labels
exchanged differ in exactly the columns it demanded, so the assertion was
satisfied by the bug. No other check covered it: the file-based ones (M3, M8)
assert on the bytes of the installed ROM, which say nothing about what the
screen claims about them.

**And the control that was run did not reveal it, which is the transferable
part.** The author's control made `installed_name()` return **one** string for
both variants, and M9 duly went red. That is the *degenerate* break — the labels
collapsing — and passing it says nothing about the *adversarial* one, the labels
crossing. Two directions, and only one was probed.

**Fix.** Ground truth per screenshot, needing no OCR and no committed reference
bitmap: mfselect's menu renders `dezogif_ng WiFi (ESP-01)` and
`dezogif_ng UART (joy port)` whatever is installed, in the same ROM font and the
same attribute as the status row, so **both** correct labels are already in
every picture. M9 now requires each run's status field to match the *right* menu
entry and to differ from the other, judged inside one image. Verified against
both breaks: swap → M9 red; one-label-for-both → M9 red; restored → green.
`test/cell-diff.py` grew a `cells` mode for it, and the old cross-run assertion
survives as M10, which still earns its place by covering the other 28 columns.

**Lesson.** When a check compares two observations, ask what it establishes
about *either one alone*. If the answer is "nothing", it is a **consistency**
check and not a **correctness** check, whatever its name says — and it will stay
green through any bug that keeps the two consistently wrong. Related, and this
file already carries both: "the screen changed" is not "the stub took over", and
a guard tested only in its easy case is a guard whose hard case is untested.

---

## A checksum answers "which build", never "whose ROM"

**Symptom.** None visible, again — and again it was the *guard* that failed
silently rather than the thing being guarded.

mfselect refuses to capture **our** ROM as the user's `original.rom`, because
anyone who installed dezogif_ng by hand already has our ROM at the official
path, and saving it as "the original" loses the stock Multiface ROM with no
copy left anywhere. That guard compared the installed ROM's CRC against the
`dezogif.sum` shipped beside it.

**Cause.** `BUILD_TIME` is stamped into every ROM, so the CRC changes on
**every build**. A card only has a matching pair until the stub is next built.
After any upgrade the comparison failed, the guard did not fire, and mfselect
captured the debug stub as the stock ROM — exactly the loss it exists to
prevent.

The mistake is one level up from the code: **identity and integrity were being
answered by the same value.** A checksum is an excellent answer to "did these
bytes land intact" and a hopeless one to "is this ours", because it is
deliberately sensitive to every byte — including the ones that are *supposed*
to change between releases.

**Fix.** A magic string at a fixed offset (`DeZoGiFnG_UART_0001`), matched on
its prefix and variant and never on its build number. The CRC keeps the
integrity job it was always right for.

**What made this findable, and it is the transferable part.** The existing
bench check M4 tested the guard with a *matching* `.sum` — the easy case, and
not the one any user is in. Adding M6, which ships a deliberately stale
`.sum`, then **reverting the fix to see M6 fail**, showed both that the bug was
real and that M4 could never have caught it: with the old guard restored, M4
still passed while M6 destroyed the backup.

**Lesson.** When a guard has a test, ask what *state* the test puts the system
in, not just what it asserts. M4 asserted the right thing about a state users
are almost never in. A guard tested only in its easy case is a guard whose hard
case is untested, and the hard case is the one that ships.

---

## `cp --reflink=auto` is a gigabyte when `auto` says no

**Symptom.** Mid-session, every shell command started returning exit code 1 —
including `true`. It read as a broken tool, and two independent agents lost
time to it before anyone read the stderr, which said what was wrong all along:

```
/bin/bash: line 1: pwd: write error: Disk quota exceeded
```

**Cause, and there are two of them stacked.**

1. The benches copy the 1 GB reference SD image into `build/` before each run,
   deliberately, so the reference is never written. `--reflink=auto` makes that
   free — **on a filesystem with reflink support**. It falls back to a real,
   full copy *silently*, and `tmpfs` always takes the fallback.
2. **The scratchpad was under `/tmp`, which on this machine is a tmpfs.** So
   every leaked gigabyte was a gigabyte of **RAM**, not of disk. About **22 GB**
   of abandoned `sd-*.img` had accumulated there, mostly under the pre-rename
   `dezogif-esp` path, and it filled the quota.

The second is the root cause and the more general one: **nothing belongs under
`/tmp` on this machine.** Scratchpads go to `$HOME/tmp/scratchpads/`, which is
real disk — see CLAUDE.md, beside the worktree rule. The harness's own default
scratchpad path points into `/tmp` and must be overridden.

**Fix.** `test/run-esp.sh` deletes its working image when the run ends. Nothing
is lost: the diagnostics it leaves are the screenshot and the jnext log, and
the image is a byte-for-byte copy of a file still sitting where it was.

**The first version of that fix did not work, and only measuring found it.**
Deleting the image at the end of the happy path leaves it behind on every other
path, so the trap now does it — and the trap has to be armed **before the
copy**, not next to the emulator pid it also has to kill. The copy is the
slowest step and therefore the likeliest one to be interrupted: killing the
script during it left a 777 MB partial image with no handler in scope.
`jnext_pid` is declared empty beforehand and the handler tolerates that,
because under `set -u` an unset variable inside a trap aborts the handler
*before* it reaches the `rm` — a leak fix that leaks.

**Two attempts to test that interrupt path both tested the wrong process**,
once by the reviewer and once here, which is why the hole survived a round.
`cmd && ./script &` backgrounds the **whole `&&` chain**: `$!` is a wrapper
subshell, so the signal never reaches the script and its trap never runs. The
run then completes normally and looks like a pass. Launch the script alone,
take `$!`, and signal that.

**THAT SAME FORM BIT AGAIN ON ISSUE #17, in a third way, and it faked a whole
measurement.** `cd <worktree> && python3 squatter.py &` backgrounds the chain
including the **`cd`**, so the shell never left its own directory — and the
`make` and `./test/…` that followed ran in the **main repository checkout**
rather than in the worktree under test. The bench being measured was therefore
`main`'s copy of the script, not the branch's, and it duly behaved like code that
had never been changed. Two hypotheses were offered for that before anything was
traced (a `grep -E "\b"` portability doubt, then an errexit-suspension theory),
both plausible, both wrong; what settled it in one step was `bash -x` and reading
the *first twelve* trace lines, where the variables being set were visibly the
old ones. **When a change appears to have no effect, prove which file ran before
theorising about why it did not work** — `bash -x`, `md5sum`, or an echo of
`$PWD` costs seconds. And put `cd` on a line of its own.

The accident was not wasted: that run is the honest "before" control for the port
check, since it *was* `main`'s script against a squatted port, and it reported a
verdict rather than refusing.

**And getting the signal to the right process still was not enough — a bash
trap does not stop a script.** `trap cleanup EXIT INT TERM`, with a handler
that simply returns, makes the shell defer the signal until the running
foreground command finishes, run the handler once, and then **carry on with the
next line**. So the bench cleaned up and then completed the whole run as if
nothing had happened, exiting 0. From the outside that is indistinguishable
from a working interrupt, because the image is gone either way — which is
exactly why it was reported as "verified at three interrupt points" when
nothing had been interrupted at all. The fix is `trap cleanup EXIT` plus
`trap 'exit 130' INT` / `trap 'exit 143' TERM`, so the handler *exits* and the
EXIT trap does the cleaning on the way out.

**The test that finally settled it asserts the run did NOT finish** — no
`All checks passed` in the output, and exit 143 — rather than only that the
image is gone. Checked against the old trap to be sure it discriminates: old
exits 0 having completed, new exits 143 having stopped. Four wrong mechanisms
were asserted on this one bench script before that test existed. **Every one of
them was caught by measuring, none by reasoning.**

**~~Still outstanding, deliberately untouched:~~ CLOSED, 2026-08-06.**
`run-headless.sh` left `sd-stock.img` *and* `sd-ours.img` per run, and
`run-mfselect.sh` its own **six** — same mechanism, and `make clean` was the
only thing that reclaimed them. They were the bulk of the 22 GB. Both now
remove their working images from the same `cleanup` the departure check already
runs from, unlinking **before** `bench_await_departure`, because that call can
`exit` and an exit that skipped the `rm` would reintroduce this very leak.

**Kept per-script rather than moved into `bench-jnext.sh`, and the reason is
that file's own invariant.** What carries the four wrong attempts is the *trap
wiring* — armed before the copy, tolerant of a variable the handler has not
seen, `exit 130`/`exit 143` rather than a handler that returns — and issue #17
already put all of it in both scripts. It cannot move into the helper either,
which documents itself as defining functions and doing **nothing else**: no
`set`, no traps, no top-level state. What was left to share is a single
`rm -f`, and wrapping that would put mutable state into the one file whose
value is that it has none. So the code is one line in each script and the
*reasoning* stays shared where it already lived — `run-esp.sh`'s comment block
and this entry — cited from both rather than restated.

**The negative control is what makes this more than "the file is gone".** An
image that is absent after a run that *completed* proves nothing: it is absent
either way. So the interrupt test asserts the run did **not** finish — no
success line in the output, exit 143 — as well as that the image went. And the
script is launched **alone**, with `$!` taken from it directly: `cmd && ./script
&` backgrounds the whole `&&` chain, so `$!` is a wrapper subshell and the
signal never reaches the script. That mistake has now been made three times in
this repository by three different people, and every time the run completed
normally and looked like a pass.

**Lesson.** An `auto` flag that degrades silently is a landmine on a
filesystem you did not anticipate — and a quota failure disguises itself as a
tool failure, because the tooling reports the exit code and swallows the
stderr. When something impossible happens (`true` returning 1), read the
stderr before believing the impossible thing.

---

## Three tries to explain one failing test run, because nobody measured it

**Symptom.** Not a build failure — a *diagnosis* failure, which is why it is
here: the code was right all along and the explanation of a deliberately broken
control run was wrong twice before it was right.

The run: `make test-esp` with the `+IPD` connection id hardcoded to `0`, a
negative control for M0(b). Observed result — E2 fails with an empty reply,
E3 fails, and E4a fails with `Connection refused`.

**The two wrong mechanisms, in order.**

1. *"The guest parked in its failure loop, so it refused the second
   connection."* Impossible. The listening socket belongs to the **emulator**,
   not to the guest: jnext's ESP accepts TCP on the host side and only then
   hands `+IPD` to the Z80. A wedged guest CPU cannot make the OS refuse a
   `SYN`. Asserted by the independent reviewer, and it sounded entirely
   reasonable.
2. *"Each check waits out its 20-second socket timeout, and the frame-bounded
   emulator run ends underneath the client."* The second half is right and the
   first half is not. The whole failing run takes **~9 s**; two 20 s timeouts
   alone would need 40. Asserted while correcting (1), by the author.

**What is actually true**, from the run's own log and a stopwatch. jnext's
`--delayed-automatic-exit-frames` is a **frame** budget, so the process exits
on its own schedule regardless of what the guest is doing — about 4 s after
accepting the connection. The client's blocked `recv` then returns **EOF**, not
a timeout, because the process died and the socket was torn down; the next
`connect` is refused because nothing is listening any more.

**Fix.** Two things, and the second is the general one:

- The client detects a completely silent guest and says the checks below it
  cannot be read as independent evidence, instead of printing three failures
  that look like three findings.
- **A test that can fail for a reason outside its own subject has to say so.**
  Three of the four checks in that run were reporting the harness, not the
  fixture.

**Lesson, and it is the third variant of one this file already carries.**
ERRORS.md already says "a fix that is never tested by *removing* it is a
correlation" and "do not paraphrase a paraphrase". This is the same disease in
a third organ: an *explanation* asserted instead of measured. Both wrong
mechanisms were plausible, internally consistent, and offered confidently — and
the thing that settled it was one timed run and four lines of log. The tell is
the same every time: if the account of *why* something failed was reasoned
rather than observed, it is a hypothesis, and this project has now paid for
that three times in one file.

---

## A boundary the test data never reached, and a resource never released

Two findings from one review of the ESP transport. Different bugs, the same
blind spot: **the evidence only ever visited the easy half of the state space.**

**1. Every payload arrived in one piece, so reassembly was never run.** jnext
frames inbound TCP into `+IPD` chunks of at most 2048 bytes
(`esp01/include/esp01/esp_at.h:448`). The conformance sweep's largest loopback
was 1024. So the code that stitches a command back together across several
headers — the most novel code in the change — was executed by nothing, and the
suite was green. It happened to be correct (2000/2048/2049/3000/4096/8192 all
round-tripped when someone finally tried them), which is worse rather than
better: a green suite that cannot reach the interesting case will stay green
through the change that breaks it.

**Fix.** Sizes that straddle the boundary — 2047, 2048, 2049 — plus 4096 for
more than one split. **Lesson: when a layer below you has a magic number, put
test data on both sides of it.** The number was in a header file the whole time.

**2. `esp_conn_id` was set and never cleared.** Replies are addressed to the
connection the last `+IPD` came from. Nothing reset that when the peer went, so
after any disconnect the id of a dead connection persisted for the rest of the
session, and every *unprompted* notification — the M1 button, or a leftover
`RST 0` — was aimed at it. `AT+CIPSEND` on a closed cid answers `ERROR`; the
code waited only for `>`, so it timed out, reset the call stack via
`drain_main`, discarded the notification, and reported **"Last Error: TX
Timeout"** on a machine with nothing wrong with it.

Every test passed, because every test was a client that connected, spoke, and
whose *responses* therefore always had a live id to go to. Nothing exercised
"the stub speaks first, and to nobody".

**Fix.** Treat the module's `ERROR` as what it is — the peer has gone — clear
the id, drop the message, and return quietly. Chosen over parsing
`<id>,CLOSED` because `ERROR` covers every reason a connection stops working at
one point in the code, rather than the one case a parser was written for.

**Lesson: for any handle taken from a peer, write down where it is released
before writing where it is used.** And for the test: the failing case is the one
where *nothing external is driving* — those are the states a
request/response test suite can never enter, and they need a check of their own.

---

## Enumerating a control flow's exits by reading the ones you expected

**Symptom.** With the ESP transport, `CMD_LOOPBACK` produced no reply — and then
the *next* DZRP check, on a fresh connection, received that reply with the wrong
sequence number. Two failures, one cause, one check apart.

**Cause.** Outgoing bytes are buffered and sent as one `AT+CIPSEND`, so
something has to say "the message is finished". `TRANSPORT_END_MESSAGE` was put
at the top of `cmd_loop` and of `main`, from a list of exits that looked
complete: a command's response returns to `cmd_loop`, `NTF_PAUSE` is followed by
`jp cmd_loop` in both `mf.asm` and `breakpoints.asm`, `CMD_CLOSE` ends
`jp main`, and `CMD_CONTINUE` already called `transport_flush` in
`backup.asm`. **`cmd_loopback` does none of those**: it ends `pop af` /
`jp main_loop.continue` and re-enters the *main* loop, not the command loop. Its
reply therefore stayed buffered until the next command arrived and was flushed
to whatever connection that one came from.

**Fix.** A third `TRANSPORT_END_MESSAGE`, at `main_loop.continue`. The rule that
actually holds is not "every response returns to `cmd_loop`" but **"flush
wherever the debugger goes idle"**, and there are three such places.

**Lesson, and it is not "read more carefully".** The list of exits was built
from the handlers that were *read*, and `cmd_loopback` was not one of them —
`grep -nE "^\s+jp (main|drain_main|restore_registers|main_loop)" src/commands.asm`
takes one second and answers the question exhaustively. When a change depends on
"every path through X", enumerate the paths with a tool, not from memory of the
ones you happened to open. Found from jnext's own `--log-level esp01=trace`
output, which showed the `AT+CIPSEND` arriving five seconds late and addressed
to the wrong connection id — the emulator's log named the failure again, as it
did in the entry below.

---

## "The backup file exists" is not "a backup exists"

**Symptom.** None visible — which is the point. Found by the independent
reviewer of the mfselect branch, who reproduced it rather than arguing it.

**Cause.** `mfselect`'s first-run capture asked `esx_f_stat(ORIG_ROM, &es) == 0`
— does the file exist — and skipped the capture if so. But `esx_f_open` with
`ESX_MODE_OPEN_CREAT_TRUNC` creates the directory entry *before* the first byte
is written, so a capture interrupted by a power cut leaves a **short**
`original.rom`. Every later run then saw the file, decided the backup was done,
and skipped the capture **silently and permanently**. The user would go on to
install the stub believing the stock ROM was safe, with no copy of it anywhere
on the card — the exact loss the program's guard exists to prevent, reached
through a different door.

**Fix.** Two changes, and the second is the general one:

- `backup_valid()` tests size and a readable `.sum`, not existence.
- **Every ROM write is atomic**: write a temporary in the same directory,
  verify it, then unlink the destination and rename. Nothing that another
  component depends on — a backup, or the Multiface ROM the firmware loads at
  boot — is destroyed before its replacement is known good.

**Lesson.** `CREAT_TRUNC` is a destructive operation that happens *before* the
constructive one. Any file opened that way is already lost when the write
begins, so the truth of "is this file good" can never be its existence. The
author's own bench had four checks and none of them covered a partially written
file; the reviewer's first question was what happens on power loss mid-copy.

---

## Running a NEX headless: `jnext prog.nex` does NOT boot NextZXOS

**Symptom.** `mfselect.nex` printed its banner and then froze. Identical
screenshot at frame 400 and at frame 1500, so not slowness.

**Cause.** The jnext log says it outright:

```
--load: will load 'build/mfselect.nex' after 0 frame(s)
Machine ROM loaded from SD '/MACHINES/NEXT/48.rom': Next 48K fallback
```

The NEX is injected at frame 0 with **NextZXOS never booted**. mfselect's every
file access is the esxdos API, so the first `RST $08` had nothing to call and
hung. The program was correct; the harness was not running it under the OS it
requires. There is no `--load-delay` to fix this.

**Fix.** Boot NextZXOS, then type the launch command, exactly as jnext's own
regression suite does it (`test/00regression/scripts/nextsync-func.sh`):
`--delayed-keypress-frames 400 space / 470 down / 500 enter` reaches the command
line, then `.nexload /mfselect/mfselect.nex` one keypress at a time. `/` is
SYMBOL SHIFT + V, so the key name is `sym+v`.

**Lesson.** When a guest program hangs, read the emulator's own log before
reading the guest. It stated the machine configuration in two lines and would
have saved the whole investigation.

---

## z88dk's zxn console cannot position or colour text

**Symptom.** `printf("\x0c")` to clear the screen printed `?`. So did every
other ZX control code.

**Three approaches that did not work**, in order:

1. `printf("\x0c")` — prints `?`. A probe then showed 12 (cls), 22 (AT), 16
   (INK) and 17 (PAPER) *all* print as `?`: the console is a plain character
   sink.
2. `#include <conio.h>` for `clrscr()` — `file 'conio.h' not found`. conio
   exists only for the classic clib, not `-clib=sdcc_iy`.
3. `-pragma-redirect:fputc_cons=fputc_cons_native`, to route printf through the
   ROM print routine — `undefined symbol: fputc_cons_native`. No such driver for
   the `zxn` target.

**Fix.** Write the display file directly: ~40 lines giving `put_char`,
`print_at`, `attr_run` and `cls`, taking the font from the address in the
`CHARS` system variable (0x5C36) rather than assuming 0x3D00. This also drops
stdio entirely.

**Lesson.** One 15-line probe program settled what three rounds of guessing had
not — and it answered four questions at once (cls, AT, INK, PAPER) because it
tested them all in one screenshot. When a library's behaviour is unknown,
probing is cheaper than the first wrong guess.

---

## Firing a Multiface NMI headless — and what actually blocked it

**Symptom.** Injected guest code wrote NR `0x02` bit 3 ("generate Multiface
NMI"). Nothing happened: the screen never changed.

**What was concluded at the time, and it was wrong.** That the NMI was gated
off by NR `0x06` bit 3 (`zxnext.vhd:2090`), because adding a read-modify-write
of that bit "fixed" it. Both observations were real; the causal link was not.

**Why that link does not hold.** More than one thing differed between the
failing run and the working one — the Multiface ROM in the SD image as well as
the register write — and the ad-hoc runs were never committed, so which
difference mattered is no longer recoverable from this repo. What *is*
verifiable is that under the injection timing this bench now uses the register
is already set by the time anything runs, so it cannot be what a same-timing
attempt saw differ (see the table below); and that a sufficient alternative
cause exists and is still in the tree: `nmi66h` (`src/mf_rom.asm:41-60`) masks NR `0x02` with
`00011100b` and returns unless the result is zero, so dezogif's ROM declines a
software NMI whatever NR `0x06` says. Do not read the paragraph above as
"the ROM was the cause" — read it as "the experiment could not tell", which
is the actual failure.

**Measured properly, 2026-08-04**, with the Copper fixture against the stock
ROM, one variable at a time:

| NR `0x06` bit 3 | result |
|---|---|
| set by the fixture | NMI fires, 91.41% repaint |
| left untouched | NMI fires, 91.41% repaint |
| explicitly cleared | **no NMI**, 0.00% |

So the gate in `zxnext.vhd:2090` is real and jnext models it faithfully — and
**NextZXOS leaves NR `0x06` bit 3 set after boot**, which is why a guest that
never touches it still gets its NMI. The register's *power-on* value is 0
(`zxnext.vhd:1110`); by the time anything runs under NextZXOS it is 1.

**Consequences.**

- The fixtures still set the bit, deliberately: it costs seven bytes and makes
  them independent of what the firmware happened to leave behind.
- For the stub, the risk is not "must set it" but "**the debuggee may clear
  it**" — and if it does, M2's asynchronous break stops working silently.
  Re-asserting it from the poll is cheap insurance.

**Lesson, and it is not the one this entry used to teach.** Two variables
changed between the failing run and the working one, and the conclusion picked
the interesting one. A fix that is never tested by *removing* it is a
correlation. The three-row table above took one extra emulator run.

---

## "The screen changed" is not "the stub took over"

**Symptom.** The headless bench's T4 reported PASS. The screenshot was, to the
eye, the untouched NextZXOS welcome screen.

**Cause.** The assertion was `cmp -s boot.png nmi.png` — any byte difference
counted. The actual difference was **24 pixels in a 26×2 box**: NextZXOS
idling, not a takeover. For comparison, the stock Multiface monitor repaints
**91.41%** of the screen.

**Fix.** `test/screen-diff.py` reports the percentage of differing pixels and
the bench requires ≥25%. T4 then correctly went red — and stayed red until the
real cause was found (`nmi66h` serves button NMIs only), at which point T4 was
rewritten to assert the *decline*, which is what actually should happen today.

**Lesson.** A green test whose assertion cannot distinguish success from
noise is worse than no test. Always check what the *positive* case actually
measures (T3 exists for exactly this reason).

---

## Deriving a hardware fact instead of reading the VHDL — got it backwards

**Symptom.** A plan-document note explaining why PC-initiated break cannot
work in UART mode claimed that handing the joy ports back to the debuggee
"re-points UART0's RX **at** the joystick pin". Exactly inverted.

**What is actually true**, and all three sources agree:

- `zxnext.vhd:3340` — `uart0_rx <= joy_uart_rx when joy_iomode_uart_en = '1'
  and nr_0b_joy_iomode_0 = '0' else i_UART0_RX`. The joystick pin is selected
  only when the enable is `'1'`; otherwise RX is `i_UART0_RX`, the ESP pin.
- `zxnext.vhd:3536` — `joy_iomode_uart_en <= '1' when nr_0b_joy_iomode_en =
  '1' and nr_0b_joy_iomode(1) = '1'`.
- `src/backup.asm:63` — resuming the debuggee writes
  `REG_JOYSTICK_IO_MODE,0`, comment "Disable joy port IO mode to enable the
  joysticks". That is the enable going to `'0'`.

So while the debuggee runs, RX is pointed **away** from the joystick pin —
where the serial cable physically is — and onto the ESP pin. The conclusion
(no PC byte can arrive while running, in UART mode) was right; the mechanism
was backwards.

**Cause.** The fact was derived from a summary of §3.1 rather than read from
the VHDL, in a document whose own first hard rule is that the VHDL is the
authority. A plausible-sounding derivation is indistinguishable from a
correct one until someone checks the source.

**Lesson.** For any claim about UART/ESP routing, NMI generation, Multiface
paging or MMU behaviour, open the VHDL and quote the line. Do not paraphrase
a paraphrase. Caught by the independent reviewer; the author had already
written it into the plan.

---

## "sjasmplus is not installed"

**Symptom.** `which sjasmplus` fails; CLAUDE.md recorded installing it as the
project's first blocker.

**Cause.** `~/bin/direnv-spectrum.sh` had

```bash
export PATH="~/src/spectrum/sjasmplus:$PATH"
```

The tilde is inside double quotes, so the shell never expands it and the PATH
entry is the literal string `~/src/spectrum/sjasmplus`. sjasmplus 1.23.1 was
installed the whole time.

**Fix.** `$HOME` instead of `~` inside the quotes.
