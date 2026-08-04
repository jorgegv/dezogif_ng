# ERRORS.md — failed approaches worth not repeating

Anything that took more than two attempts to build or work. Check this before
attempting similar logic.

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

**Still outstanding, deliberately untouched:** `run-headless.sh` leaves
`sd-stock.img` *and* `sd-ours.img` per run, and `run-mfselect.sh` its own —
same mechanism, and `make clean` is the only thing that reclaims them. They
were the bulk of the 22 GB. Not changed here because they are outside this
change's scope, but they are the next occurrence waiting to happen.

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
