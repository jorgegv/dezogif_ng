# DZRP conformance testing

`make test-dzrp REMOTE=…` speaks DZRP to a remote and judges the exchange against the protocol
specification. Issue [#2](https://github.com/jorgegv/dezogif_ng/issues/2).

It is the only layer in this repository that exercises the wire. `make test` judges screenshots,
`make test-mfselect` judges files on an SD image, and the Z80 unit tests need VS Code — so until
this existed, the protocol, which is the entire deliverable, had no test.

## Running it

    make test-dzrp-stub                                 # OUR OWN WiFi stub, in jnext
    make test-dzrp REMOTE=tcp:192.168.1.42:11000        # a real Next over WiFi
    make test-dzrp REMOTE=tcp:127.0.0.1:11000           # anything listening locally
    make test-dzrp REMOTE=serial:/dev/ttyUSB0:921600    # UART mode (needs pyserial)

`make test-dzrp-stub` is the self-contained one and the reason the rest exists: it builds the
WiFi ROM, installs it as the Multiface ROM on a copy of the reference SD image, boots a headless
Next, presses M1 to bring the debugger up, waits for the stub's own `AT+CIPSERVER` listener to
appear on `127.0.0.1:11000` (that wait is check **W1**, and nothing else in this repository has
ever shown the ESP being brought up by the stub rather than by a fixture), and then runs the
suite against it.

It then does a **second** emulator run for check **W2**, which is about the transport rather than
the protocol: a client connects, sends `CMD_CONTINUE` and closes in the same breath, the debuggee
runs into a stray `RST 0`, and the stub tries to send an `NTF_PAUSE` to a connection that is
already gone. W2 asserts three things — that the module really did refuse the `AT+CIPSEND`
(read from jnext's own log, so a run where the situation did not arise fails instead of passing
vacuously), that the stub still serves a new client afterwards, and that **its screen reports no
error**, counted as bright-red pixels. Before the fix that count was 824: `Last Error: TX Timeout`.
Its own run because it deliberately crashes the debuggee and because the suite would repaint the
screen its verdict is read from.

**W2's `CMD_CONTINUE` is not evidence that the resume path works, and must never be cited as
such.** It resumes registers that were never saved — all zero — so the machine crashes on purpose.
That is a way of provoking an unprompted notification. C10 and C11 are where resuming is tested.

A **third** run is check **W3**, the negative control for C10: the same fixture, the same registers,
and only the `CMD_CONTINUE` withheld (`--only C10 --no-continue`). C10 must go **red**. Without it,
"C10 passed" would say nothing about whether C10 can fail — the same reason T3 exists for T4 in
`make test`.

A **fourth** run is check **W4**, and it is the only check here whose subject is two clients at
once. Two connections are opened and initialised one at a time, and then both write a
`CMD_LOOPBACK` at the same instant, through a barrier — so the module emits two `+IPD` frames back
to back. **Both must be answered.**

Until issue #11 exactly one of them was, every time. The stub reads the first frame, executes it
and issues `AT+CIPSEND`; the second frame is then sitting in the RX FIFO **ahead of the module's
`OK\r\n> `**, and the wait for that prompt skipped it exactly as it skips the module's unsolicited
lines — read off the wire and discarded. No error, nothing sent, the client waiting for ever.

**It then adds a third client**, connected in advance and speaking the moment the first reply
lands, so its frame arrives while the stub is still answering the *other* command out of its hold
buffer. That is a different bug from the collision and a single collision cannot reach it: the
next command normally comes off the wire through the idle poll, which frees the buffer on the way
past. The held command is a five-byte `CMD_READ_MEM` returning 1 KB — five `AT+CIPSEND` chunks —
because with everything small the window is about a millisecond and the check stops
discriminating, measured against a ROM known to have the defect.

**W4 asserts its own precondition, as W2 does**, and here it is load-bearing rather than
belt-and-braces: it greps jnext's log for two `+IPD` frames emitted with nothing sent between them.
A race that did not race is not a test, and without that line W4 would pass whenever the two writes
happened not to collide.

**It was shown red first, against two different ROMs, and each half of it fails on its own one:**

| ROM | W4 |
|---|---|
| `main` | **FAIL** — *"exactly one of the two was answered"* |
| the fix's first version, which freed the hold buffer only when the wire next spoke | **FAIL** — *"the client that arrived while the stub was answering a HELD command was lost"* |
| the fix as merged | **PASS** |

The middle row is the one that matters: that defect was found in review, reproduced 11 times out
of 11, and the first version of W4 was **green** over it.

**The same defect's other window is NOT reachable here**, and that is worth knowing before anyone
reads W4 as covering issue #11 whole. The wait for `SEND OK` loses a frame the same way, but jnext
answers instantly so there is no window to land in; on a real Next it is **20-50 ms** wide,
measured, and it is hardware bench **H3**. One fix covers both; only one half of it has a check on
this side of the line.

A **fifth** run is check **W5**, the other two-client check, and its subject is issue #13: a
command whose payload does **not** all arrive in one `+IPD` frame, while a second client speaks.
`cmd_get_tbblue_reg`, `cmd_set_breakpoints` and `cmd_restore_mem` all send their response header
and **then** read payload, so those reads reach `esp_require_payload`, which used to take the next
frame off the wire whoever it belonged to — and write `esp_conn_id` on the way past.

Connection A writes the six header bytes of a `CMD_GET_TBBLUE_REG` and stops; connection B writes a
whole `CMD_LOOPBACK`; A then writes the one byte it withheld, the register number.
`CMD_GET_TBBLUE_REG` is the reproducer because it makes both failures observable in one byte: its
payload is a register **number** and its answer is that register's **value**, so a spliced payload
comes back on the wire as the wrong register's value rather than corrupting something out of sight.
The byte B's frame would supply is B's own length LSB, which the fixture chooses and reads cleanly
beforehand — so the two possible answers are known in advance and are asserted to differ.

**It was shown red on two ROMs, and the two failure modes are separately visible:**

| ROM | W5 |
|---|---|
| `main` | **FAIL** — *"connection A … was never answered"* and *"connection B received a reply carrying connection A's sequence number"* |
| the latch alone (`esp_tx_conn_id`, no ownership) | **FAIL** — A is answered on its own connection, *"with NextREG 0x09's value instead of 0x00's"*, and B's own command is eaten |
| the fix as merged | **PASS** — `AT+CIPSEND=2,6` to A and `AT+CIPSEND=1,14` to B, in that order |

The middle row is the one that matters: **the latch fixes addressing and does nothing at all for
payload adoption**, and a check that only asserted "the reply reached the right socket" would have
been green over a debuggee still being patched with breakpoint addresses built from two clients'
bytes.

**W5 asserts its own precondition from the module's log**, as W2 and W4 do: three `+IPD` frames of
6, 15 and 1 bytes, consecutive, with the middle one from a different connection. The three writes
are **8 ms** apart and that number is bounded on both sides, measured rather than chosen — below
~2 ms the module frames A's header and A's payload as one `+IPD` and there is no split left to
test; above ~20 ms the stub's own RX budget expires while it waits (`ESP_RX_WAIT` is ~100 ms of
*emulated* time, and this emulator runs several times faster than real time). Drifting out of that
window fails the precondition rather than passing vacuously.

**What W5 does not reach.** The hold buffer holds one frame, so a *third* client speaking inside
the same window still loses its command — framed and dropped rather than spliced, which is
`esp_hold_frame`'s existing documented loss. And nothing here is evidence about hardware: real TCP
segmentation is not jnext's chunking, and DeZog itself opens one connection and is strictly
request/response, so no client this project has can reach any of this.

Extra arguments go through `DZRP_ARGS`:

    make test-dzrp REMOTE=tcp:127.0.0.1:11000 \
         DZRP_ARGS="--require INIT,LOOPBACK --expect-preamble none"

| Flag | Meaning |
|---|---|
| `--require CMD,…` | absence of these commands is a FAILURE, not UNSUPPORTED |
| `--expect-preamble report\|a5\|none` | assert the frame preamble instead of only reporting it |
| `--start-byte auto\|a5\|none` | what the remote prefixes frames with (default: autodetect) |
| `--only C10,C11` | run only the named checks |
| `--no-continue` | **negative control**: do everything the execution-control checks do except send `CMD_CONTINUE`. They must then fail |

## Validating the suite before trusting it

Point it at **CSpect and its bundled DeZog plugin**, which is a working DZRP remote. A red result
against our own stub then means the stub, not the harness.

    pgrep -f CSpect >/dev/null || ( cd ~/src/spectrum/CSpect3_1_0_0 &&
        timeout 180 mono ./CSpect.exe -w2 -zxnext -mmc=./ -brk -tv -r -debug & )
    make test-dzrp REMOTE=tcp:127.0.0.1:11000

Result on 2026-08-04, CSpect 3.1.0.0 / DeZogPlugin v2.3.0.20958 / DZRP 2.0.0 — **6 passed, 0
failed, 2 unsupported of 8**. That was the **eight**-check suite: **C9 has never been measured
against CSpect**, so it is validated only by having been shown failing against our own pre-fix ROM.

**Check that nothing else holds the port before believing a run of this.** Every check opens its
own connection, so a remote that comes and goes on 11000 — another jnext, a bench in a second
worktree — can serve *different checks of one suite run*. That is not hypothetical: an attempt to
measure C9 here produced three mutually contradictory results, and the tell was C1 reporting
`dezogif v2.2.1` / DZRP 2.1.0, which is our own stub, in a run aimed at CSpect. `make
test-dzrp-stub` refuses to start in that situation; `make test-dzrp` cannot, because it has no idea
what it was pointed at. `ss -ltn | grep 11000` first, and `pgrep jnext` too — a stale emulator of
your own counts, and it is what fooled a reviewer.

**C10-C12 have not been measured against CSpect either**, for the same reason as C9. C10's
fixture is written for the memory map `cmd_init` leaves on a Next and would need checking before
any CSpect result meant anything.

## Result against our own stub

**2026-08-05, `CMD_CLOSE` gets a check — `make test-dzrp-stub`: W1-W5 pass, and 15 passed, 0 failed,
0 unsupported of 15.** C15 is new. **No ROM byte moved**: this is a test-only change, so both ROMs
hash the same as `main`'s with `BUILD_TIME` pinned, and there is no `make bump`.

**C15 was shown able to fail, twice, against deliberately broken scratch ROMs** — neither committed,
both built from `main`'s sources with one edit:

1. **`cmd_close` routed to `cmd_not_supported`** (the jump-table shape issue #8 fixed for
   `CMD_PAUSE`): C15 red on the *first* assertion, `no response within 25s; remote still serving`.
   That is the pre-#8 defect reproduced on a different command.
2. **`cmd_close` answering and then never returning to service** — `TRANSPORT_END_MESSAGE`
   followed by `jr $` in place of `jp main`, so the response really is flushed and the stub then
   goes nowhere: C15 red on the *second* assertion, the one that matters, with
   `answered, but the next command was not; remote stopped answering`. A stub that acknowledges a
   close it did not complete is exactly what a green C15 must not tolerate — the same shape as
   C10's `ret`-instead-of-resume control (MEMORY.md, 2026-08-05).

**A third variant was run and C15 PASSED it, which is reported because it bounds the check.**
With `jp main` replaced by `jp cmd_loop` the stub answers `CMD_CLOSE` and goes on serving without
ever running `main`'s prologue — and C15 cannot tell. That is the limitation stated in its
docstring, measured rather than asserted: **C15 sees "answered, and still serving", not "the session
state was reset"**, because `prgm_state` and the backup fields are not observable over a socket.

**One consequence of the WiFi transport is worth knowing before reading control 1.** In WiFi mode
`cmd_close`'s response is *buffered*, and the `TRANSPORT_END_MESSAGE` that flushes it lives at
`main_redraw` — so on that build the response reaches the wire **because of** `jp main`. The two
assertions are therefore not independent there, which is why control 2 has to flush explicitly
before hanging: without that it would go red on the response and prove nothing about serving on.

**Not yet asserted: `--require CLOSE`.** `test/run-dzrp-stub.sh` passes `--require CONTINUE` so that
a stub which started *refusing* the resume could not be excused as a partial remote. The same
argument applies to `CMD_CLOSE` and the flag is not passed, so a stub that began closing the socket
on command 2 would report `UNSUP` and the target would still exit 0. Left alone deliberately: that
file was being edited for issue #17 at the time.

**2026-08-05, a reply belongs to one connection and a command to one connection's frames (issue
#13) — `make test-dzrp-stub`: W1-W5 pass, and 14 passed, 0 failed, 0 unsupported of 14.** W5 is
new and was red on `main`'s ROM and red again on a ROM carrying only half the fix.

**Since 2026-08-05 every run of this bench settles two seconds between the listener appearing and
the first client connecting** (issue #10). The port exists as soon as `AT+CIPSERVER` is accepted,
and the stub then sends `AT+CIFSR` and scans the answer for `OK`; a client landing inside that scan
loses its first command, which showed up as W2 failing its own precondition about one run in three.
Measured: 6 of 6 runs with the settle, 5 of 6 without. `test/run-tx-patience.sh` settles for the
same reason. **It is the bench declining to race the stub, not the stub being fixed** — the window
in bring-up is real, and it is the one case issue #11's fix deliberately cannot capture from,
because that scan's own pattern begins with `+`.

**2026-08-05, the sprite commands are answered (issue #9) — `make test-dzrp-stub`: W1-W4 pass, and
**14 passed, 0 failed, 0 unsupported of 14**. C13 and C14 are new and were red on the commit
before them, with the diagnosis in the check's own words: *"the remote is still serving, so it
swallowed the command and carried on"*.

`CMD_GET_SPRITES` and `CMD_GET_SPRITE_PATTERNS` cannot return real data from a Next — ports `0x57`
and `0x5B` have no read decode in the FPGA — so the stub answers `count*5` and `count*256` **zero
bytes**. The length is not a choice: DeZog asserts it client-side and slices the reply into
fixed-size records, so a short answer is a desync rather than a refusal. **An emulator-side remote
can answer these for real** (its sprite state is host memory), and C13/C14 accept either, asserting
only the length and that the session survives.

**2026-08-05, no scan discards an inbound frame (issue #11) — `make test-dzrp-stub`: W1, W2, W3
**and W4** pass, and 12 passed, 0 failed, 0 unsupported of 12.** W4 is new and was red on the
commit before it.

**2026-08-05, `CMD_PAUSE` answered (issue #8) — `make test-dzrp-stub`: W1, W2 and W3 pass, and
12 passed, 0 failed, 0 unsupported of 12. The target exits 0 for the first time.** Every check
this suite has is green against our own stub in the emulator.

That matters beyond the tally: **a red on real hardware is now a hardware finding by
construction.** `test/hardware-check.py`'s `KNOWN_RED` table is empty, so there is no longer a
known-red for a bench-top failure to hide behind — which is exactly what that table was built to
make legible.

The immediately preceding result, kept because it is what the entries below were written against:
**11 passed, 1 failed of 12**, the red being **C12**, `CMD_PAUSE` — a pre-existing stub behaviour
this suite was the first thing to look at, not a regression.

**The headline is C10 and C11: the stub resumes a debuggee, and the debuggee runs.** That had
never been shown anywhere in this project — not on hardware, not in the emulator — and until it
was, the exit path, `backup.asm`'s restoration and the AltROM patch were code nothing had ever
executed. C10's fixture runs after `CMD_CONTINUE`, writes its marker, stops on the temporary
breakpoint at 0x8016, and the `NTF_PAUSE` names that address (reason 0, bank 5). C11 adds that
`BC`/`IX` reached the *running program* as `CMD_SET_REGISTER` set them, and that
`PC`/`SP`/`AF`/`BC`/`DE`/`HL`/`IX` came back as the program left them, with `SP` returned to
0x9F00 after an `RST 0` moved it.

**A consequence worth naming separately: the AltROM patch is exercised.** The fixture's breakpoint
is an `RST 0`, which can only reach the debugger through the modified code `copy_altrom` installs
at 0x0000/0x0066 in the Alt ROM.

**2026-08-04, issue #7 fixed — the same bench was then 9 passed, 0 failed, 0 unsupported of 9**,
with W1 and W2 passing: version negotiation, the absent preamble, both length checks, loopback
round-trips exact at 0/1/255/256/1024/2047/2048/2049/4096 bytes, sequence echo across five
commands, a 37-byte register block, and a 64-byte memory write/read round trip.

**C2 was red until then, and it was never a transport defect.** `cmd_init` read the remote's
program name from the stream **until a NUL**, ignoring the frame's length field entirely, so a
frame whose length disagreed with its payload was consumed and answered — and the stream stayed
desynchronised for the rest of the session. Three things showed it was pre-existing rather than
introduced by the WiFi work: `src/commands.asm` was untouched by it, the UART ROM was
byte-for-byte identical to the one `main` shipped, and the frame-reading path (`cmd_loop`,
`receive_bytes`, `cmd_init`) is common code shared by both builds. It was [issue
#7](https://github.com/jorgegv/dezogif_ng/issues/7), and fixing it changed the serial ROM's bytes,
which is why it took its own branch and its own build-number bump.

`cmd_init.inner` now consumes exactly the payload the frame declared, like every other handler in
that file. **C9 is the other half of the same fix**, and it exists because C2 cannot reach it: C2
over-declares the length and requires silence, which proves the remote reads *at least* as far as
it was promised. C9 sends an honest length whose payload carries four bytes past the name's NUL,
then a second ordinary `CMD_INIT` behind it — a remote that frames on the NUL leaves those four
bytes to become the next command's header, and the second command comes back wrong or not at all.

**The first result against our own stub, for the record (2026-08-04):** W1 and W2 pass, 7 passed,
1 failed, 0 unsupported of 8 — the failure being C2, above.

**Not ZEsarUX.** ZEsarUX speaks ZRCP, its own protocol, reached by DeZog's `zrcp` remote type. It
is not a DZRP endpoint and cannot serve as a reference.

**Kill CSpect by PID, not `pkill -f CSpect`.** The pattern matches the command line of the shell
running it, so the shell kills itself — this cost two aborted commands before it was spotted.

## What the checks cover

| | |
|---|---|
| C1 | `CMD_INIT` negotiates a version |
| C2 | the length conventions are as specified — an over-declared length must not be answered |
| C3 | the frame preamble, reported and optionally asserted |
| C4 | `CMD_LOOPBACK` round-trips 32 bytes unchanged |
| C5 | `CMD_LOOPBACK` is exact at 0, 1, 255, 256, 1024, **2047, 2048, 2049** and 4096 bytes |
| C6 | sequence numbers echo back across consecutive commands |
| C7 | `CMD_GET_REGISTERS` returns a register block DeZog can index |
| C8 | memory write/read round-trip |
| C9 | `CMD_INIT` consumes exactly the declared payload, so the next command is still in sync |
| C10 | **`CMD_CONTINUE` resumes the debuggee and it runs**, stopping on a temporary breakpoint that raises `NTF_PAUSE` |
| C11 | **the debuggee's state survives the resume**, in both directions — see below |
| C12 | `CMD_PAUSE` while stopped is answered — see below |
| C13 | `CMD_GET_SPRITES` is answered at `count*5` bytes, the length DeZog asserts client-side — see below |
| C14 | `CMD_GET_SPRITE_PATTERNS` is answered at `count*256` bytes, likewise |
| C15 | **`CMD_CLOSE` is answered, and the remote goes on serving afterwards** — see below |
| C16 | a full 8192-byte bank goes in with `CMD_WRITE_BANK` and reads back byte-identical |
| C17 | **16 KB in one `CMD_WRITE_MEM`**, the largest single inbound payload there is, across a slot boundary |
| C18 | an oversize payload is declined and **the remote goes on serving** — see `MEMORY.md` |
| C19 | **a breakpoint in ROM space is written to memory** — and can be taken out again — see below |
| C20 | **a breakpoint in ROM space stops the debuggee** — see below |
| C21 | **a breakpoint spares the debugger's own trampoline**, which C19 makes reachable — see below |
| C22 | **a 64K-form breakpoint above `0xE000` reaches the debuggee's bank**, not the debugger's — see below |
| C23 | the same for `CMD_RESTORE_MEM`, whose byte is the client's as well as its address — see below |

### C19, C20 and C21: breakpoints where ROM is mapped (issue #27)

**A DZRP breakpoint is a byte patched into memory**, and `0x0000-0x3FFF` on a stopped Next is not
writable. Every fixture in this suite lives at `0x8000` in a RAM bank, so until these two checks
existed nothing here had ever asked.

**The mechanism is one line of the FPGA.** In the normal ROM-serving branch of the slot-0/1 decode,
`sram_pre_rdonly <= not (nr_8c_altrom_en and nr_8c_altrom_rw)` (`zxnext.vhd:3056`) — NR `0x8C`
bits 7 and 6 — and `sram_pre_rdonly` gates the physical SRAM cycle at `:3154`. `src/altrom.asm:55`
leaves NR `0x8C` at `10000000b` for the whole debug session: **bit 7 set so the patched Alt ROM
serves reads, bit 6 clear so a write is discarded outright.** Nothing is mismapped and nothing is
corrupted — the byte never reaches memory, and the stub reports success because no breakpoint path
reads back what it wrote.

**Two checks, and they are not the same check twice.** C19 asks whether the byte lands, which
localises the fault to the write; C20 asks whether the breakpoint **fires**, which is what a user
suffers. A fix that made writes land but broke the restore passes C20 and fails C19; one that
patched the wrong image passes C19 and fails C20.

**Each carries its own control, in the same run, and that is what makes them believable.** A
breakpoint that does not fire is indistinguishable from a resume that never worked — that confound
is what wrecked the one attempt to test this at the machine — so both do the identical thing at a
RAM address alongside and report a **Precondition**, not a verdict, if the RAM half misbehaves.
Both also assert that MMU slot 0 really holds the ROM (read back out of `CMD_GET_REGISTERS`, whose
byte 28 is the slot *count* and byte 29 is slot 0), so a run in which `0x1234` was not ROM space at
all cannot be reported as a ROM finding.

**C20's fixture is built so that BOTH outcomes are positive observations**, which is why it needs no
timeout. The ROM address it uses is one whose byte is `0xC9` — a `RET` — **found by reading the
machine** rather than hardcoded, so nothing depends on which ROM is paged in. The debuggee `call`s
it: if the breakpoint landed the `RST 0` runs and the debugger is entered there; if it was discarded
the `RET` runs and control falls through to a `nop` one instruction later, which is the control.
An `NTF_PAUSE` arrives either way and its address says which happened — so a *silence* is a third
outcome again, and means the resume itself failed rather than the breakpoint.

#### C21, and why the fix could not land without it

**Making the write work is what creates the danger C21 guards.** `copy_modify_altrom` patches two
blocks into the Alt ROM — 8 bytes at `0x0000` (the `RST 0` entry and the return path) and 14 at
`0x0066` (`dbg_enter`) — and they are the only reason an `RST 0` reaches the debugger at all. While
ROM writes were discarded a breakpoint aimed at them was harmless; the moment they land, an `RST 0`
written over `dbg_enter`'s first byte makes every breakpoint re-enter itself and walk the stack down
through memory. **That is the mechanism the original report guessed at, and it is a consequence of
the fix rather than of the bug** — so `bp_hits_trampoline` refuses those 22 bytes, and the two
halves are one change.

A refused breakpoint is simply not planted. The client is still told what opcode was at the address,
so it is not lied to; it just gets no breakpoint — **which is exactly what it got before the write
was able to land at all**, so the trampoline's behaviour is unchanged and only the rest of ROM moves.

**`cmd_restore_mem` is guarded with the same predicate; `clear_tmp_breakpoint` is not.** The
difference is who chose the address. A restore is a **client-controlled write of a client-chosen
byte**, and until this fix it could not reach ROM space at all — so leaving it open reopens C18's
defect one command along. Guarding it can never strand a legitimate un-patch, because
`bp_hits_trampoline` is a pure function of the address: anything it refuses here is something
`cmd_set_breakpoints` refused to patch in the first place. `clear_tmp_breakpoint`'s address comes
from `tmp_breakpoint_X.bp_address`, which only `set_tmp_breakpoint.store` writes and only where that
same guard already passed, so a trampoline address cannot get in there.

#### C21 asserts the EXTENT, because constraining two addresses is not constraining a guard

The first version of C21 checked `0x0000` and `0x0066` and nowhere else, and that is **not enough in
either direction**:

* a guard refusing *only those two exact bytes* plants `RST 0` on `0x0001-0x0007` and
  `0x0067-0x0073` — and passed green;
* the guard that actually shipped refused **116 bytes**, `0x0000-0x0073`, because a `ret c` returned
  with the carry its own contract reads as "refuse". That swallowed `RST 8`, the `RST 0x10`-`0x30`
  vectors and **`0x0038`, the IM1 handler** — and, because `set_tmp_breakpoint` shares the guard,
  **made stepping run away** there. C21 could not see it.

So C21 now requires **every byte of both blocks refused** *and* the bytes immediately outside —
`0x0008`, `0x0065`, `0x0074` — **taken**. `0x0065` earns its place by being below the *second*
block, so a guard that got only the first boundary right still fails. Its control remains a
precondition: on a remote where ROM writes are discarded the trampoline is untouched *for the wrong
reason*, so an ordinary ROM address goes in the same `CMD_SET_BREAKPOINTS` and must have taken the
breakpoint.

| ROM under test | C19 | C20 | C21 |
|---|---|---|---|
| before the fix | FAIL, `0x1234` still reads `0xED` | FAIL, the RAM control fired instead | **PRECONDITION** — not a vacuous green |
| writability, **no guard** | PASS | PASS | FAIL — *planted at 0x0000-0x0007 0x0066-0x0073* |
| writability, guard **too narrow** | PASS | PASS | **FAIL** — *planted at 0x0001-0x0007 0x0067-0x0073* |
| writability, guard **too wide** | PASS | PASS | **FAIL** — *the guard also refused 0x0008 0x0065, which is ordinary ROM* |
| as merged | PASS | PASS | PASS |

The two middle rows are the ones that had to be earned. A control that only collapses the cases
together proves only that direction — `ERRORS.md`'s "these two differ is not this one is right",
which mfselect's M9 and bench N6's scanline-0 have each already cost this project once.

**The extent is verified over the wire, not read.** The refusal set as merged, measured by sweeping
`CMD_SET_BREAKPOINTS` across `0x0000-0x010F` and reading every byte back:

```
PLANTED : 0x0008-0x0065 0x0074-0x010F 0x1234 0x1FFF-0x2000 0x3FFF
REFUSED : 0x0000-0x0007 0x0066-0x0073
```

Re-measure it that way after any change to the guard. Reading the code is what missed the defect.

### C22 and C23: the 64K address form, at an address in the debugger's own slot (issue #38)

**DZRP gives an address two forms and this suite had only ever sent the second one low.**
`CMD_SET_BREAKPOINTS` and `CMD_RESTORE_MEM` each carry a 16-bit address plus a **bank+1** byte:
non-zero names a bank outright; zero means "the 64K address as the debuggee currently sees it". The
stub answers the second form by asking whether the address is at or above `0xE000`, because that
range is `MAIN_SLOT` — where the debugger itself is executing — so reaching the *debuggee's* memory
there means paging its bank into the swap window at `0xC000` first.

**Both handlers made that decision on the wrong register.** The `cp HIGH MAIN_ADDR` ran with `A`
still holding the bank+1 byte, which on that path is **zero by definition** — it is what the branch
above tested — so the comparison was always `0 < 0xE0` and the direct-write branch always won. A
64K-form address at `0xE000` or above therefore wrote into `MAIN_BANK`: the bank the debugger is
running out of, at a **client-chosen offset**, and in `cmd_restore_mem` with a **client-chosen
byte**. That is C18's family one command along, and it is upstream's, in both ROMs, since the fork.

**It survived because nothing had ever sent that input.** DeZog sends long addresses. C19 and C21
*do* send the 64K form — `_set_bps` has always used it — but only at `0x1234` and `0x8000`, where
the direct branch is the **correct** one. So the defect lived in the one input nobody sent, and a
green suite stayed green by construction. It was found by reading, by the independent reviewer of
issue #27, and the second site by grepping for the pattern rather than trusting the first was alone.

**The population is five sites and the enumeration is mechanical.** `MAIN_ADDR` has exactly two
spellings of this boundary in the tree — `cp HIGH MAIN_ADDR` and `cp MAIN_SLOT*0x20` — and
`grep -rn 'MAIN_ADDR' src/` plus `grep -rn 'MAIN_SLOT\*0x20' src/` finds every one:

| site | loaded before the `cp` | |
|---|---|---|
| `commands.asm` `cmd_set_breakpoints.handle_64k_address` | nothing — `A` is the bank byte | **was broken** |
| `commands.asm` `cmd_restore_mem.handle_64k_address` | nothing — `A` is the bank byte | **was broken** |
| `breakpoints.asm` `clear_tmp_breakpoint` | `ld a,d` — the address is in `DE` | correct |
| `breakpoints.asm` `set_tmp_breakpoint` | `ld a,h` | correct |
| `backup.asm` `memory_loop` | `ld a,h` | correct |

The fix is `ld a,h`, twice, matching the three that already got it right rather than inventing a
fourth idiom.

#### The verdict is a positive observation, not a wait to see whether the stub dies

A one-byte write into the running debugger may or may not be fatal depending on where it lands, so
"it crashed" is a weak and flaky signal for this defect. Instead: seed the debuggee's slot-7 bank at
the probe address through `CMD_WRITE_MEM`, drive the handler, and read the address back through
`memory_loop`'s own — correct — swap window. **Three outcomes, and each says a different thing:**

| the read-back | |
|---|---|
| the written byte (`RST 0`, or C23's value) | the write went where the client asked |
| **the seed** | it went somewhere else, and the only other place a 64K address at `0xE000+` can land is `MAIN_BANK` — **the defect** |
| anything else | a third thing, reported as a third thing |

C22 has a **second, independent** observation of the same routing for free: `CMD_SET_BREAKPOINTS`
replies with the opcode the remote *found*, which on the swap path is the seed. It is judged after
the read-back because it is the weaker of the two — a defective remote reads an uninitialised byte
out of `MAIN_BANK` and could match the seed one time in 256 — where the read-back is deterministic
whichever branch ran.

**Survival is asserted in band** rather than on a fresh connection as C18 does: the read-back is
itself an exchange the remote must serve *after* the offending write.

#### Two checks, and a probe address chosen so the red is a reading

**Two and not one**, because the two handlers carry **separate copies** of the decision: a fix to
either alone must still leave a red naming the other. A single check covering both would go red
either way and would not say which.

The probe address is **`0xFF80`**, and every part of that is chosen. It is in `MAIN_SLOT`, or there
is no wrong branch to take. It is **above any byte the debugger occupies in `MAIN_BANK`** — only
`main_end-MAIN_ADDR` bytes are ever copied into that bank (`mf_rom.asm`'s `MEMCOPY`), `main.asm`
`ASSERT`s `main_end <= ROM_MAGIC_ADDR`, and the identity block ends at `0xFEB4`, which only ever
moves **down** as the MF ROM half grows — so a defective remote writes into **dead space**, the red
is a repeatable reading rather than a crash somewhere in the debugger's own code, and every check
below it still runs. And it is not `0xFFFF`, so nothing rests on the last byte of a bank.

Shown red first, and the red is the *precise* branch rather than a timeout:

```
FAIL  C22 ... — 0xFF80 is untouched: the RST 0 went to the debugger's own bank
FAIL  C23 ... — 0xFF80 is untouched: the byte went to the debugger's own bank
```

byte-identical across two full runs, with all 21 other checks green in the same runs — which is
also what says the mis-routed write really is inert.

#### What C22 and C23 do NOT establish

**`memory_loop` is a shared dependency of the seed and of the verdict.** Were it broken the same
way, the seed would round-trip through `MAIN_BANK` and both checks would pass against a defective
remote. Nothing observable from a socket separates those; what rules it out is the source
(`backup.asm:325`, `ld a,h` before the compare), enumerated above, and **not** this run. The
`slot7 == MAIN_BANK` precondition covers the other vacuous case — if the debuggee's slot 7 held the
debugger's own bank, both branches would write one place and no observation could tell them apart.

**Neither has run on hardware**, and the defect has never been observed anywhere but here: it is
traced from the source and now measured in the emulator.

### A verdict line is one sentence; this file is where the reasoning is

Every check prints **one short verdict of about twenty words.** That is a deliberate change
(2026-08-05, at the user's request) from details that ran to three and four clauses each. The
substance was not deleted: it is in each check's **docstring**, which is documentation that
happens to live in the source, and in this file.

**WHAT THE BUDGET COUNTS IS THE `detail` — the sentence a check writes about what happened — and
NOT the label.** The label is the check's fixed title from the `CHECKS` table, written once and
never varying at run time; it is not prose the check chose, so it is not charged to the check's
budget. Two things force that reading, and an earlier version of this section got it wrong in a
way that cost two review rounds:

- `hardware-check.py` renders `"  %-4s %s %s" % (tag, paint(status), detail)`, where the tag is a
  bare `H3`. Its one long-agreed exception — H3's failure composite at ~25 words — is therefore a
  count of a **detail**, because there is no label there to count.
- the labels here run **3 to 9 words** (`C3 frame preamble` … `C15 CMD_CLOSE is answered and the
  remote serves on`). Charging them to the budget would allow C3 seventeen words of prose and C15
  eleven, for the same nominal rule. That is not one rule.

Measured mechanically on 2026-08-06 — every reachable detail in both harnesses, **81** of them,
representative values substituted and worst-case joins expanded — single-cause details run **1 to
14 words, median 8**. The longest is **14**, `main()`'s REQUIRED-refusal branch, so the budget is
comfortably kept and **there is no single-cause exception anywhere**.

**Four branches exceed it on purpose, every one a join of several INDEPENDENT faults**, each
marked at its call site with why: C11's at **58 words**, `hardware-check.py`'s two H2 composites at
**38** and **27**, and C10's at **29**. They are not truncated, because each joined fault is
separately load-bearing — a resume path that is badly broken is precisely the one that fails on
several axes at once, and *which* axes is the diagnosis. Cutting a compound diagnostic returns the
reader to the bare "no reply" that cost this project eight hours on 2026-08-05, which is the same
argument that keeps H3's composite long.

Two conventions follow from it and both are load-bearing:

- **The id never changes.** `test/run-dzrp-stub.sh`'s W3 asserts its negative control with
  `grep '^FAIL  C10 '`, and `test/hardware-check.py`'s `classify()` takes the code from field 2 of
  every `FAIL` line. Shorten the prose after the id; never the id.
- **A silence still says which kind it was.** C12, C13, C14 and C15 report a missing answer as
  `no response within Ns; <liveness>`, where the tail is **three words**, one of:

  | tail | what it means |
  |---|---|
  | `remote still serving` | it swallowed the command and carried on, so a client blocks for ever — issue #8's shape, and the interesting case |
  | `remote stopped answering` | this run cannot separate "no reply" from "the command killed it" |
  | `liveness not probed` | `--remote` was not set, so we do not know |

  Collapsing those three into "no response" would be a check failing for a reason outside its own
  subject, which ERRORS.md says has to be said out loud. Three words rather than five because every
  caller pays for the tail inside its own budget, so a longer phrase spends words in four checks at
  once.

- **`the connection failed mid-check:` means the remote went AWAY, not that it answered wrongly.**
  It is `main()`'s `except OSError` arm (issue #33), and it is deliberately a separate verdict from a
  `DzrpError`: that one is the remote answering incorrectly, this one is a peer that reset, closed,
  or died part-way through a send. **A check that provokes a disconnect on purpose catches it
  locally and never produces this line** — `chk_oversize_payload` is the one that does — so a line
  reading this way is always an unexpected disconnect and always a FAIL, never an `UNSUPPORTED`.
  Before that clause existed such a check did not fail at all: it escaped `main()` as a traceback
  and **took every check below it with it, C15 included**, so the suite silently stopped covering
  `CMD_CLOSE`.

- **`PRECONDITION:` is a one-word label with a documented meaning.** It prefixes a C10/C11 failure
  where the *setup* broke — the fixture did not land in memory, the marker area did not clear, the
  register block was too short to index — before the check's own subject was ever reached. **Nothing
  on such a line is evidence about the resume**; report it as a memory or register fault, not as a
  resume fault. The long form spelled that out on every occurrence and pushed three branches past
  the budget, which is what measuring the **failure** paths turned up: the first pass measured a
  healthy run's PASS lines only, and a rule checked on the happy path is a rule half checked.

### C10 and C11: the execution-control fixture

A 30-byte program is written to 0x8000 with `CMD_WRITE_MEM`, the debuggee's `PC`/`SP`/`BC`/`IX`
are set with `CMD_SET_REGISTER`, and `CMD_CONTINUE` carries a **temporary breakpoint** — the
mechanism DeZog itself uses on every step, and therefore the one this suite is allowed to use.
The program leaves four independent traces:

- `ld (0x9800),bc` / `ld (0x9802),ix` as its **first two instructions**, so what is read back
  afterwards is what the *resumed debuggee* held, not what the debugger remembers being told;
- a progress marker at 0x9804, which can only be there if the debuggee executed;
- a byte at 0x9805 written **only by the instruction after the breakpoint**, which must stay
  zero, separating "stopped on it" from "ran past it";
- registers loaded while running (`HL`=0x1234, `DE`=0x5678, `BC`=0x9ABC, `A`=0x5A), read back
  with `CMD_GET_REGISTERS`, so the capture on re-entry is checked as well as the restore on the
  way out.

The marker area is cleared and read back **before** the run: a stale byte from an earlier check
would otherwise let "the debuggee ran" pass without it running. A failure of that setup is
reported under the `PRECONDITION:` label described above, so a memory fault is never filed as a
resume fault.

Everything lives in 0x8000-0x9FFF, which `CMD_INIT` maps to bank 4, clear of the ROM and of the
debugger's own slots 6 and 7.

**Both negative controls were run against the build 0006 tree, and both discriminate.**
`--no-continue` (bench check W3, which withholds only the `CMD_CONTINUE`) turns C10 red. And so
does a deliberately broken ROM whose `cmd_continue` **answers** the command and returns to
`cmd_loop` instead of jumping to `restore_registers`: C10 and C11 both go red against it, which is
the failure that matters — a stub that acknowledges the resume and does not perform it. In a
narrower run of that control, C9 stayed **green** on the same sabotaged ROM, which is the useful
part: the machine is healthy and answering, and only the resume is gone.

### C12: `CMD_PAUSE`, and what it does NOT test

**It is not a test of PC-initiated break.** Breaking into a *freely running* program is milestone
M2 and is not built: `mf_rom.asm`'s `nmi66h` serves button NMIs only, which bench check T4 asserts
deliberately, so while the debuggee runs there is nothing polling the link and no `CMD_PAUSE` can
be received at all. No check can pass that until M2 changes it, and none is written.

What C12 asks is the narrow protocol question that *is* answerable today: the specification gives
`CMD_PAUSE` a Length=1 response — the sequence number alone — with no exemption for a remote that
is already stopped. **It is answered since issue #8, and C12 is green.** `cmd_pause`
(`src/commands.asm`) sends that response and returns to `cmd_loop`.

**It was red until then, and the shape of the defect is worth keeping.** `commands.asm`'s jump
table mapped command 7 to `cmd_not_supported`, which stores an error and jumps to `drain_main`, so
the frame was consumed, the stub returned to `main` and repainted, and the client waited forever.
Measured rather than read off the source: the check timed out and a second connection confirmed
the stub was still serving. It was **pre-existing** — that jump-table entry is upstream's, dated to
its own 2023 commit and untouched by the WiFi work or by issue #7 — so both builds had always done
it, and fixing it moved both ROMs' bytes.

**Acknowledging is the whole of the fix, deliberately.** `cmd_loop` runs only while the debugger is
stopped, so command 7 cannot arrive in any other state and there is nothing to stop. It must not
touch `prgm_state`: a client may legitimately send `CMD_PAUSE` before the first `CMD_CONTINUE` —
check C12 does exactly that — so it can arrive while `prgm_state` is `PRGM_LOADING`, and
overwriting that with `PRGM_STOPPED` would make the next `cmd_continue` skip its "loading finished"
branch and leave the flashing border on. Nor does it send an `NTF_PAUSE` — that notification
reports a *transition* into the stopped state and there is none here. CSpect's plugin does the
same: `Pause()` stops the CPU and calls `SendResponse()`, and the notification is emitted later
and only if the state actually changed.

**Why upstream never saw it.** DeZog's `ZxNextSerialRemote` overrides `sendDzrpCmdPause()` to throw
*"To pause execution use the yellow NMI button of the ZX Next"*, so over the serial remote command
7 never reaches the wire. WiFi mode is driven by the `cspect` remote, which does **not** override
it and inherits `DzrpRemote`'s `await this.sendDzrpCmd(7)` — it sends the command and blocks on the
response. Verified against the installed DeZog 3.7.4.

### C15: `CMD_CLOSE`, and the destructive prologue behind it

**Nothing in this suite sent command 2 until 2026-08-05.** C1-C14 each take a fresh connection and
simply drop it, which is a TCP event and not a DZRP one — the remote is never told the session
ended, so the one command DeZog uses to say so had no coverage at all.

**Two assertions, and the second is the reason this is a check rather than a teardown.**

The response first. The specification gives `CMD_CLOSE` a **Length=1 response** — the sequence
number and nothing else, exactly as `CMD_PAUSE` has — and DeZog's `DzrpRemote` awaits it:
`sendDzrpCmdClose()` is `await this.sendDzrpCmd(2, undefined, this.initCloseRespTimeoutTime)` in the
installed 3.7.4. Silence there blocks the client, which is issue #8's shape exactly.

Then that the remote is **still there**. `CMD_CLOSE` is the only command our stub answers and then
leaves through **`jp main`** (`src/commands.asm`), and `main`'s prologue is destructive by design:
`prgm_state` to `PRGM_IDLE`, `backup.speed`, `backup.interrupt_state` and `slot_backup.slot0` all
reset, then `transport_activate` and `show_ui`, and only then `main_loop` again. **The response is
written before all of that and therefore proves none of it.** Only a further command, answered,
shows the stub came out of the other side.

**The follow-up is `CMD_INIT`, for two reasons.** It is what DeZog's own driver does — the first
entry of its stress `cmdList` is `sendDzrpCmdClose()` immediately followed by `sendDzrpCmdInit()`,
on the same remote — and no remote is entitled to refuse it, so a failure there cannot be a
capability difference wearing this check's name.

**It is sent without `talk()`, deliberately.** `talk()` maps a closed connection onto `Unsupported`,
and this check's command name is `CLOSE`; a remote that answered `CMD_CLOSE` perfectly and then hung
up would otherwise be reported as *not implementing the command it had just implemented*. The
hang-up gets its own verdict instead — DZRP is silent on whether the transport survives `CMD_CLOSE`,
so it is reported as the distinct observation it is rather than folded into "no answer".

**What C15 deliberately does not claim.** Not that any of that state was actually reset:
`prgm_state` and the backup fields are **not observable over a socket**, and all C15 sees is that
the remote answers again. Not the repaint either — that `CMD_CLOSE` redraws the screen is
`test/run-client-status.sh`'s **N3**, read off the Next's own display, and the ordering argument
there (`cmd_close` answers *first* and reaches `show_ui` afterwards, so only a later command proves
the repaint) is the same one this check rests on.

**It runs last, and must stay last**, because it is the one check that deliberately resets the
debugger. Anything below it would be talking to a re-initialised stub — a different subject from the
one it thinks it is testing. The suite runs `CHECKS` strictly in order and never in parallel, and
`--only C15` works standalone: the check opens its own connection and sends its own `CMD_INIT`
first, like every other.

**C5's sizes straddle a transport boundary, and that is the point of three of them.** jnext frames
inbound TCP into `+IPD` chunks of at most **2048** bytes
(`src/esp01/include/esp01/esp_at.h:448`), so anything larger reaches the remote as *several*
headers and has to be reassembled. The first version of this sweep stopped at 1024, which meant
every payload in the WiFi transport's evidence had arrived in a single frame and the reassembly
path — the most novel code in that transport — was never executed by a committed test. Real
traffic crosses it constantly: DeZog pushes 8-16 KB per `CMD_WRITE_BANK` when it loads a `.nex`.
2047/2048/2049 pin the boundary itself and 4096 forces more than one split, so a remote that
handles exactly one is not mistaken for one that handles any number.

**A partial remote is legitimate.** DZRP has 29 commands and remotes implement different subsets —
CSpect's plugin does not implement `CMD_LOOPBACK` at all, and closes the connection when it sees
one. An unimplemented command is therefore reported UNSUPPORTED rather than failed, unless named
in `--require`. Every check runs on its own connection so one refused command cannot take the rest
of the suite down; the suite retries briefly on connect, because a remote serving one client at a
time needs a moment to start listening again.

**What it deliberately does not test.** DeZog owns instruction-length calculation, the original
opcode under a breakpoint, the temporary breakpoints used to step off one, and condition
evaluation. Asserting those against the remote would encode the wrong contract and push whoever
tried to satisfy it into building the thing that fights DeZog at runtime. C10 plants its own
temporary breakpoint for exactly that reason: it behaves the way the client behaves.

## What resuming a debuggee still does NOT cover

C10 and C11 close the largest hole this suite had. Three things next to it stay open, and the
distinction is fine enough to be worth writing down rather than left to be inferred.

1. **The stackless-NMI return *address* is still not exercised.** C10 sets `PC` itself with
   `CMD_SET_REGISTER`, so `backup.pc` never comes from `save_nmi_return_address`, which is the
   routine that reads NR `0xC2`/`0xC3`. Reaching it needs an M1 press while `prgm_state` is
   `PRGM_RUNNING`, i.e. a *second* NMI timed to land after a `CMD_CONTINUE` — jnext's
   `--delayed-nmi` counts emulated frames while the client counts wall clock, and the emulator's
   frame rate collapses under DZRP traffic, so that is a race rather than a check. What C10 does
   prove is the half either way depends on: `restore_registers` really hands a machine back and
   the program really runs.
2. ~~**The M1 button has never broken a *running* debuggee.**~~ **Done on hardware, 2026-08-05**,
   by a human during a real DeZog session — see the plan's M1. It remains true that **this suite**
   cannot do it, for the reason in (1).
3. ~~**The resume has never happened on hardware.**~~ **Done**: `make test-hardware` runs this suite
   against a real Next, **12 of 12, C10/C11 included**. Struck rather than deleted, because the
   sentence "every result on this page is jnext's" was true when written and is the reason the
   hardware bench exists.

   **The suite has since grown to 15 checks, and all 15 have passed on a real Next — 15 of 15,
   2026-08-08 12:37**, at `192.168.100.136`, with H1-H3 green and H4-H6 measured. Earlier revisions
   of this page and of [HARDWARE-TESTING.md](HARDWARE-TESTING.md) disagreed about whether the checks
   added after the 12-check run had ever been driven at hardware; that is settled. Individual totals
   below remain records of the run that produced them.

4. ~~**C15 has not run on hardware.**~~ **It has**: 2026-08-08, in the 15-of-15 run above, with the
   Length=1 response and a `CMD_INIT` answered in sync afterwards. Its expectation was that it would
   pass — `cmd_close` is common code and `hardware-check.py`'s `KNOWN_RED` table is deliberately
   empty — and it did. Note also what the real client does with this command: DeZog's
   `CSpectRemote.disconnect()` sends `CMD_PAUSE` and `CMD_CLOSE`, and the 2026-08-05 tap shows
   **both answered** on a Next, so the response half had been seen by a person watching a session
   before any check covered it.

## Two things this established that were not obvious

### The two directions use different length conventions

- A **command**'s length counts the **payload only** — neither the sequence number nor the
  command ID.
- A **response**'s (and a notification's) length counts **from the sequence number**.

The spec's two tables say exactly this, in wording easy to skim past. Sending `CMD_INIT` with a
symmetric length produced **no reply at all**: CSpect sat waiting for the two bytes it thought it
was still owed. Assuming symmetry costs a silent hang, not an error.

### Our stub's `0xA5` preamble is serial-only, and deliberately so

`src/message.asm` defines `MESSAGE_START_BYTE: equ 0xA5` and emits it before every response
(`send_4bytes_length_and_seqno`) and every notification (`send_ntf_pause`). It is emitted but
never expected — the receive path reads length/seq/command with no preamble.

That asymmetry is **by design, and documented upstream**. `doc/legacy/Design.md:30-31`:

> the DZRP protocol was extended by one byte which is sent as first byte of a message (only in
> direction from ZX Next to PC). This is the MESSAGE_START_BYTE (0xA5). DeZog will wait on this
> byte before it recognizes messages coming from the Next.

The reason is the paragraph above it: a game that takes the joy port leaves the Next transmitting
endless zeroes, and the preamble is how DeZog resynchronises. DeZog implements exactly that split
— `ZxNextSerialRemote` scans for and strips byte 165, `CSpectRemote` does not
(verified against the installed DeZog 3.7.4, `out/extension.js`), and `make test-dzrp`
against CSpect confirms the socket side emits none.

**So the byte is required in UART mode and must be absent in WiFi mode.** It is a property the
transport contributes, not a defect to delete. Removing it in both modes would break
interoperability with DeZog's real `zxnext` remote — the UART regression CLAUDE.md's hard rule
exists to prevent. See MEMORY.md for what M1 has to do about it.
