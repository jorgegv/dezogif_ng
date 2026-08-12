# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose

`dezogif_ng` is a **Z80 debug stub that runs on real ZX Spectrum Next hardware**, intended to be
debugged from a PC over the Next's **ESP-01 WiFi module**. It is a fork of
[maziac/dezogif](https://github.com/maziac/dezogif), whose transport is a serial cable on the
joystick port.

The goal is to **add a WiFi transport alongside that serial one and select between them at
assembly time**, so the ROM can be built in either UART mode or WiFi mode, and to add
PC-initiated break in WiFi mode. The serial transport will be kept, not replaced.

**M1 and M2 are both built.** The tree builds **two** ROMs — `make` gives the serial one, byte for
byte upstream's behaviour, and `make TRANSPORT=wifi` gives one that brings the ESP-01 up as a TCP
server and speaks DZRP through it (`src/transport_esp.asm`). A DZRP client talks to the WiFi build
under jnext and gets correct answers: `make test-dzrp-stub`. The two ROMs now also **draw different
screens**: WiFi mode reports the ESP's own baud rate and the address to connect to
(`AT+CIFSR` → `Connect at <ip>:11000`) where UART mode keeps upstream's cable baud rate and
joy-port selector.

**M2 IS BUILT TOO, since 2026-08-11 — a freely running debuggee is stopped by `CMD_PAUSE` from
the PC, with no button press and no breakpoint** (bench **W8**). ~~What is not built yet is M2's
asynchronous break — evaluated 2026-08-08 before any code, and the evaluation changed its shape:
it is feasible and must be **opt-in**, because the Copper instruction list is write-only and
enabling the break therefore destroys any Copper program the debuggee had.~~ **The opt-in half of
that is retracted**: the user's call (2026-08-10) is that the **debuggee's own program** installs
the two Copper instructions, so the debugger installs nothing, destroys nothing, and needs no
switch. The write-only fact is unchanged and is precisely *why* the program owns the list. See
@doc/ASYNCHRONOUS-BREAK-DESIGN.md for the design and
@doc/ASYNCHRONOUS-BREAK-USER-HOWTO.md for what a user has to add to their program (44 bytes) and
the five states in which the break will not fire. ~~**Nothing in M2 has run on hardware.**~~
**IT HAS, 2026-08-11, AND IT PASSED** — bench check **H7** on the user's own Next: a freely
running debuggee, resumed with no breakpoint, stopped by `CMD_PAUSE` from the PC, with its control
run silent. `PC` came back at the fixture's spin and `SP` at the fixture's own stack, and NR `0xC0`
read `0x0A`, so the **stackless** branch of `save_nmi_return_address` is now established on silicon
rather than in the emulator alone. **AND DeZog ITSELF HAS NOW DRIVEN IT**, 2026-08-11 on the same machine: the transparency fixture
loaded as an ordinary program, Continue, **Pause**, `Manual break` reported, registers and source
view populated, Continue and Pause again, clean `CMD_CLOSE`. So the `NTF_PAUSE`-arrives-before-its
own-`CMD_PAUSE`-response ordering — the last thing in M2 that was read off CSpect's plugin rather
than observed — is observed.

**It has now run on a real ZX Spectrum Next**, 2026-08-04 — the stub takes the M1 NMI and paints
its UI on core 03.02.01, and mfselect installed it. That single evening found **two bugs no
emulator here could ever have found**, both because jnext's values sit on the safe side of ours:
a connection id of 0 (jnext numbers from 1, real ESP-AT from 0) that made the stub discard every
reply, and a 15-character IP address (jnext's is 12) that the connect-string parser refused. See
MEMORY.md and ERRORS.md.

**A FULL DZRP SESSION HAS SINCE RUN ON HARDWARE**, and this paragraph said the opposite until
2026-08-08. On 2026-08-05 a real Next answered **12 of 12** conformance checks at build `000A`,
H3 included; **C10/C11 passed there, so a debuggee was resumed on silicon**; and **DeZog itself**
drove the stub — attach, disassemble, registers, memory, single-step, an M1 **manual break** that
came back `MANUAL_BREAK` with the right `PC` on an uncorrupted stack, clean disconnect, reattach.
Measured rather than estimated: median **13.0 ms** round trip, 8192 bytes in 1.01 s = **71%** of
what 115200 8N1 can carry. **The bench has since passed at its full size — 15 of 15 conformance on
a real Next, 2026-08-08** (`doc/HARDWARE-TESTING.md`), with the median down to 11.2 ms and the
stub's error area clean.

**What has NOT run on hardware**, stated so "it runs on hardware" is still not over-read:
`.mfinstall --unload` has never run there, and every ESP timing constant remains a judgement call
that only a real module can settle. The reset path of issue #26 **was** confirmed
there (2026-08-07, build `00.12`), the press-while-stopped half of it was not.

It is deployed by replacing `machines/next/enNextMf.rom` on the Next's SD card — the stub *is* the
Multiface ROM. The PC-side client is **DeZog** in VS Code, speaking **DZRP**.

**This is not an emulator project.** jnext is a *development bench* and a validation target, not a
component. Nothing here belongs in the jnext repository, and nothing there needs to change for this
to work.

## Reference files

- **Project plan, architecture and workflow: @doc/ZXNEXT-REMOTE-DEBUG-STUB.md** — read this first.
  It carries the scope decision, the VHDL-verified hardware facts with citations, the transport
  design, the milestone roadmap, the end-to-end workflow (Appendix B) and the reverse-debugging
  analysis (Appendix C). Appendix A records which claims are verified and which are estimates.
- **@MEMORY.md** — the decision log (what was decided, why, what was rejected). Read it at the
  start of every session; add to it after any architecture/logic/format decision.
- **@ERRORS.md** — approaches that failed and the fix. Check it before attempting anything it
  covers; add to it whenever something takes more than two attempts to work.
- **@doc/ASYNCHRONOUS-BREAK-DESIGN.md** — M2 (issue #22). Evaluated 2026-08-08 before any code
  and **built 2026-08-11**; the evaluation's own verdict of "**opt-in**, because the Copper
  instruction list is write-only and so enabling asynchronous break **destroys** any Copper
  program the debuggee had" is **superseded and annotated in place**: the debuggee's program
  installs the two instructions now, so the debugger installs nothing and there is nothing to opt
  into. Still true and still load-bearing: open question 5b (a Copper-caused NMI cannot be
  distinguished from a CPU-caused one — and a poll-shaped handler does not need to), the Copper
  being the **only** periodic NMI source on the machine, the NR `0x02` read-modify-write reset
  landmine, and — answered while building it — **open question 5**: any live DivMMC automap
  session blocks every Multiface NMI, poll and M1 button alike, for its whole duration.
- **@doc/ASYNCHRONOUS-BREAK-USER-HOWTO.md** — the user's half of M2: the 44 bytes a program adds
  to make itself breakable from DeZog's Pause, what the poll costs (**1288 T-states/frame**,
  measured; the plan estimate it retired was 6-13× low, which is recorded in the design doc §5
  rather than here), and the five states in which the break
  will not fire. Read it before answering "why does Pause do nothing" — the first of the five is
  that this is a **WiFi-mode feature in practice**, and the second is that esxDOS file I/O
  suppresses it.
- **@KNOWN-ISSUES.md** — faults that are real, reproduced, understood and deliberately **WONTFIX**,
  each with what causes it, what does *not*, what to do about it, and what would reopen it. Read it
  before investigating odd behaviour on hardware: two of the states it describes look exactly like
  a wedged stub from the PC side and are not one.
- Upstream design: `doc/legacy/Design.md` — memory choreography, AltROM, breakpoints. Written
  for the serial variant; everything except the transport still applies.
- **`doc/legacy/` is upstream's documentation, frozen — `doc/` is ours.** Don't edit `doc/legacy/`
  to reflect our changes; record those in `doc/` or in the code.
- **@doc/CONFIG-MODE-ROM-REPLACEMENT.md** — issue #21: writing the Multiface ROM at run time
  through config mode (NR `0x03`/`0x04`) instead of swapping the file on the SD card, as input to a
  dotcommand design. VHDL-verified mechanism, and it corrects both of the contradictory third-party
  accounts the issue was filed from. **It HAS been run**: the tool it was input to is `.mfinstall`
  (`make test-mfinstall`, `doc/MFINSTALL.md`), and it has installed a ROM on a real Next both from
  the command line and from `AUTOEXEC.BAS`. The document's own table says which claims are jnext's,
  which are the VHDL's and which came off hardware.
- DZRP spec: https://github.com/maziac/DeZog/blob/main/design/DeZogProtocol.md
- FPGA VHDL source (authoritative hardware spec):
  `/home/jorgegv/src/spectrum/ZX_Spectrum_Next_FPGA/cores/zxnext/src/`

## Hard rules specific to this project

- **The VHDL is the authority for hardware behaviour.** UART/ESP pin routing, NMI generation,
  Multiface paging, MMU slots, Copper. When behaviour is ambiguous, read the VHDL — not the wiki,
  not a forum, not another emulator. Use the `vhdl` skill or the `vhdl-oracle` agent.
- **DeZog's division of labour is a contract.** Instruction-length calculation, **deciding** where
  the temporary breakpoints used to step off a breakpoint belong, and breakpoint-condition
  evaluation all live in **DeZog**. Do not move any of them into the stub — the client already
  does them and will fight you.
  This rule used to say "storage of the original opcode under a breakpoint" as well, and that was
  wrong: `TMP_BREAKPOINT`/`BREAKPOINT` (`src/breakpoints.asm:29-40`) store the byte the `RST 0`
  replaced, necessarily, because the stub is what patches memory and so the only thing that can
  un-patch it. **Substitution bookkeeping is the stub's; the decisions are DeZog's.** See plan
  §4.4.
- **DZRP has no history/trace/replay command.** Reverse debugging is entirely PC-side and stores
  registers and stack only. Never plan around a remote-side history feature.
- **A stub that assembles is not a stub that runs.** Any change to the transport, the NMI path or
  bank handling needs evidence from an actual run — in jnext at minimum, on hardware for anything
  touching the ESP.
- **Licensing.** The combined work is **GPLv3** (`LICENSE`). Upstream's MIT notice is retained
  verbatim in `NOTICE`, as the MIT licence requires, and still governs Maziac's original code.
  The attribution to Maziac and to Chris Kirby (NDS-NextDevSystem) stays. Never remove or
  reword the MIT block in `NOTICE`.
- **Two transports, one interface** (design rule for M1 onwards; not yet built). The ROM will be
  assembled in either UART mode or WiFi mode, and upstream's serial path is never deleted.
  `commands.asm`, `message.asm` and `breakpoints.asm` must not be able to tell which mode they
  were assembled against — no ESP
  assumption may leak above the transport interface. **UART mode is the regression check on that
  boundary**: if a change breaks the serial build, the abstraction leaked, and that is a bug in
  the change, not in the serial path.
- **Fork hygiene.** Keeping upstream's transport intact also keeps upstreaming plausible. Note
  that contributing anything back to dezogif is now a
  **licensing** question as well as a technical one: GPLv3 code cannot simply be merged into an
  MIT project, so anything genuinely intended for upstream must be written to be offered under
  MIT as well, and that decision has to be made when it is written, not afterwards.

## Building

The Makefile is semantic: **bare `make` lists every target with its description.** Build outputs
go to `build/`.

**Two variants, chosen with `TRANSPORT`:**

```
make mf-rom                    build/enNextMf.rom       UART  (default)
make TRANSPORT=wifi mf-rom     build/enNextMf-wifi.rom  WiFi
make mf-rom-wifi               the same, spelled shorter
make mfselect                  BOTH, + build/dezouart.sum, build/dezowifi.sum, mfselect.nex
make mfinstall                 the .mfinstall dot command + everything it installs
```

**`build/deploy/` is what actually goes on the card**, and it mirrors the card's own layout —
`dot/` and `mfselect/` — so deployment is `cp -r build/deploy/* <card>/` with nothing renamed and
nothing placed by hand. `make mfselect` fills the `mfselect/` half; `make mfinstall` adds
`dot/mfinstall` and a default `mfselect/mfinstall.yml`. The build prints the listing when it
finishes.

**`make mfselect` is the one target that builds both**, whatever `TRANSPORT` it is invoked with,
by recursing once per variant with a single shared `BUILD_TIME`. That is not a convenience: since
#5 mfselect installs either ROM from the machine, so shipping a card with only the variant that
happened to be selected leaves a menu entry pointing at a file that is not there. Everything else
here builds exactly one variant, deliberately.

The names differ on purpose: a shared path would let `make TRANSPORT=wifi` leave a WiFi ROM where
`make test` reads one, and make would then find nothing newer than its output and test the wrong
file without saying so. The switch reaches the sources as `-DTRANSPORT_WIFI` and lands in
`ROM_VARIANT` (`src/constants.asm`), which selects the implementation in `src/transport.asm` **and**
the variant field of the magic string below — so a ROM cannot behave as one variant and identify
as the other.

**The UART build's bytes are a standing gate.** With `BUILD_TIME` and the build number pinned, the
serial ROM must hash the same before and after any transport change; that is the project's proof
that a refactor changed no behaviour, and it is how the M1 transport interface was landed in the
first place (MEMORY.md 2026-08-03). If it differs, find out why — do not explain it away.

The assembler is **sjasmplus** (1.23.1, at `~/src/spectrum/sjasmplus/`). It reaches `PATH` via
`~/bin/direnv-spectrum.sh`; the Makefile falls back to the absolute path, so a build works
without direnv loaded. Override with `make SJASMPLUS=/path/to/sjasmplus`.

`BUILD_TIME` is stamped into the ROM. Pin it (`make BUILD_TIME=1700000000`) to compare two builds
byte for byte — `make check-reproducible` does exactly that.

**The ROM carries an identity block**, at a fixed offset that is a permanent contract
(`src/constants.asm`; ROM file offset `0x1FE0`, address `0xFEA0`):

```
DeZoGiFnG_UART_0001      DeZoGiFnG_WIFI_0001
\________/ \__/ \__/
 identity    |   build number, from version.yaml
             transport variant
```

**Identity is the magic; integrity is the CRC**, and conflating them was a data-loss bug — see
`ERRORS.md`. Anything asking "is this ROM ours?" matches the `DeZoGiFnG_` prefix and the variant
field, and **never the build number**, which changes and is only ever displayed.

**AS OF ISSUE #26 THE MF ROM HALF IS EXACTLY FULL — AND IT GROWS IN 16-BYTE STEPS, WHICH AN EARLIER
VERSION OF THIS PARAGRAPH DENIED.** *(**M2 HAS SINCE TAKEN THREE OF THOSE STEPS**, issue #22:
`mf_nmi.bin` is **368 bytes (`0x170`)** and `ROM_MAGIC_ADDR` is **`0xFE70`**. The numbers below are
the pre-M2 ones and the arithmetic is unchanged — the file offset is still `0x1FE0`, which is the
whole point.)* `mf_nmi.bin` is `ALIGN 16`-ed to 320 bytes (`0x140`), the ROM is
that followed by `main.bin`, and the block's file offset is `0x140 + (0xFEA0 - 0xE000)` = `0x1FE0`.
One byte over the boundary moves `main_prg_copy` to `0x150` — **and moving `ROM_MAGIC_ADDR` down by
the same 16 keeps the file offset at `0x1FE0`**, which is the thing `tools/mfselect/mfselect.c`
actually parses. The `ASSERT` in `main.asm` enforces exactly that relationship, so it is a build
error and never a silently misplaced block. **Probed 2026-08-08**: +16 bytes with the constant moved
builds clean, the ROM stays 8192 bytes and the block still reads at `0x1FE0`.

**THE HEADROOM IS THE ONE NUMBER HERE MOST WORTH GETTING RIGHT, AND IT WAS WRONG UNTIL 2026-08-09.**
This paragraph used to end "the WiFi build has over a kilobyte of headroom, i.e. many such steps".
It had **119 bytes**, because of a 768-byte buffer nothing declared. Issue #31 removed the buffer;
the figures then were **UART 3201, WiFi 818** free to the identity block.

**SINCE M2 (issue #22) THEY WERE UART 2946 AND WiFi 216, AND SINCE ISSUE #41 THEY ARE UART 2908 AND
WiFi 178**, measured, and the WiFi number is the one
to plan against. M2 spent it twice over, which is exactly what this section warns about: 48 bytes of
the MF ROM half (three `ALIGN` steps) cost 48 bytes of the debugger half as well, because
`ROM_MAGIC_ADDR` came down with `main_prg_copy`, and the poll's own code in `mf.asm` and the
transports cost the rest. **Anything further that grows the MF ROM half should expect to pay 32
bytes per byte** and should put its code in the debugger half instead, as `mf_nmi_poll` does.

- **`ROM_MAGIC_ADDR` really is the ceiling again** — it had not been since the fork.
  `main_bank_entry` used to copy the ZX font into the top of the bank at `0xFD00 -
  MF.main_prg_copy` = `0xFBC0`, 736 bytes lower, and **nothing in the source emitted a byte there**,
  so the assembler could not see it and the asserts on `main_end` were all far too loose. Growth
  past it aliased the debugger's variables onto the space and `!` glyphs — silently, in both
  directions. The font is now read live from the ROM (`text.init`, `text.font_map`), so the buffer
  is gone rather than guarded. **Do not reintroduce a buffer at the top of this bank without an
  `ASSERT` naming its start address.**
- **Growing the MF ROM half still spends 16 bytes of the debugger half**, and that is unchanged by
  #31: the image ends at `0xE000 + 0x2000 - MF.main_prg_copy`, so a step moves `ROM_MAGIC_ADDR` down
  by 16 as well. The two halves share **one** budget. M2 grows both, so plan against 818, not 3201.

*(This paragraph previously said the half "CANNOT GROW" and called the address the contract. That was
wrong and would have told a future session that M2's entry path is blocked when it is not — see
[doc/ASYNCHRONOUS-BREAK-DESIGN.md](doc/ASYNCHRONOUS-BREAK-DESIGN.md) §4.5. What remains true is that
growth is not free: it costs 16 bytes of the debugger half and a deliberate edit to a constant that
guards a permanent contract, which is why issue #26's second fix still put its one byte of state in
**MF RAM**, where it costs no ROM at all.)*

**The block stores four BARE hex digits; every place a person reads the number shows `NN.NN`**
— high byte, dot, low byte (issue #20). So the ROM above is `00.01` on the debugger's banner and
in mfselect, and `0001` in the block those two are spelled from. That is one stored form with one
display transform, not two stored forms: the block's format is a contract `tools/mfselect/mfselect.c`
parses, and `0010` read by someone who was not told it is hex means ten.

The build number lives in **`version.yaml`**, stored as a quoted four-hex-digit string, and is
bumped with **`make bump`** — the low byte — or **`make bump-major`** — the high byte, resetting
the low one to `00`. Never by hand: the targets are what validate the range. `bump` does **not**
carry into the high byte; at `xx.FF` it refuses and says to use `bump-major`, because a new series
is a decision rather than an overflow. `version.yaml` is a
prerequisite of the assembly rule, so a bump really does reach the next build; without that it
would rewrite the file, change nothing, and ship the old number silently. **House rule: one bump
per merge to `main` that changes a ROM** — docs-only and test-only merges leave every ROM byte
identical and must not bump. Done by the manager as part of the merge, with the mechanical check
in step 4 below. It is deliberately not derived from `BUILD_TIME` or the git hash:
`make check-reproducible` must keep passing, so identity must not change on every build.

## Testing

CI for this project is **local, headless and jnext-driven**. No hosted CI (a hardware target can
never have one) and no VS Code in the loop. `make test` is the gate. The layers, weakest to
strongest:

1. **It assembles** — necessary, proves nothing. Enforced by the in-source `ASSERT`s
   (`main_end` within budget) plus the Makefile's 8192-byte ROM size check.
2. **`make check-reproducible`** — the same source gives the same ROM.
3. **`make test`** — ten headless jnext runs, judged on screenshots (`test/run-headless.sh`):
   - T1 the bench boots a Next at all
   - T2 our `enNextMf.rom` does not perturb the NextZXOS boot
   - T3 **control** — the software-NMI fixture really fires the Multiface NMI, shown against the
     SD image's stock MF ROM. If T3 fails the bench is broken and T4 means nothing.
   - T4 our stub **declines** that NMI and leaves the screen alone. **M2 DID NOT INVERT THIS, and
     everything in this file used to say it would** — see below
   - T5 a two-instruction **Copper** list raises the Multiface NMI on its own, at a chosen
     raster line, with no CPU involvement. That is M2's break mechanism, and it is now known
     to work headless rather than assumed to. Shown against the stock MF ROM for T3's reason:
     our stub declines it, and would decline it whether or not the Copper worked.
   - T6 our stub **takes over on a real M1 button NMI** and paints its own screen (~90%
     repainted, against the stock monitor's 91%). **The only check here that proves the stub is
     alive BY TAKING OVER**, rather than proving it correctly ignores something — T8 judges
     liveness too and judges it differently: not that the stub arrives, but that it is still
     answering its own keyboard afterwards. It exercises Multiface paging,
     the relocation of `MAIN` into a RAM bank at slot 7, `show_ui`, and the core-version check,
     in one run. Needs jnext ≥ 0.99.118 for `--delayed-nmi`; the bench checks for it and says so.
     **Scope limit, do not over-read it: T6 never resumes.** No DZRP client attaches, so
     the stub idles in `main_loop`, whose `transport_byte_available` poll returns immediately and
     whose `jp nz,cmd_loop` therefore never fires — `cmd_loop` and its blocking `transport_wait_rx`
     are never reached. ("Returns immediately" is a statement about the **serial** build, which T6
     runs. The ESP transport's poll can spend up to ~100 ms synchronising when the module puts an
     unsolicited line on the wire — see `transport_esp.asm`.) The frame limit ends the run. The
     exit path, `backup.asm` and the AltROM are therefore untested **by T6** — only the entry side
     is. Closing that took issue #2's protocol suite rather than another screenshot, and it is now
     closed: `make test-dzrp-stub`'s C9/C10 resume a debuggee and it runs (§4c). Neither is still
     untested: on 2026-08-05 a real DeZog session on a Next ran a fixture free, **the M1 button was
     pressed while it was running**, and the `NTF_PAUSE` came back `MANUAL_BREAK` with `PC` at the
     spin address on an uncorrupted stack — so `save_nmi_return_address` ran and its **outcome** is
     verified. **Which of its two branches ran is not**: NR `0xC2`/`0xC3` and the debuggee's own
     stack would both give that answer, and nothing read NR `0xC0` back. No bench here can do this
     — `--delayed-nmi` counts frames and a client counts wall clock — so it stays a human's job.
   - T7 a second M1 press after a **soft reset** re-initialises the debugger instead of
     declining (issue #26). **The only check that presses the button twice WITH A RESET BETWEEN**
     — T8 is the other one in `make test` that presses twice — which is why five
     years of upstream and every earlier bench missed the defect it guards: the NMI dispatch
     read "magic number and build time match, no debuggee running" as "the debugger is
     executing" and declined — an inference a soft reset falsifies, since RAM survives one and
     the same evidence then means a stale image with NextZXOS executing. The decline also
     leaked MMU slot 7, which the entry path had already pointed at `MAIN_BANK` and the
     immediate return never restored, so the machine hung shortly afterwards. The fix keys the
     decline on `slot_backup.slot7` — the bank slot 7 held at the moment of the press. Two
     runs, differing only in the second press, shot at the same frame; preconditions are
     asserted from jnext's own log (both queued NMIs really delivered — `--delayed-nmi-frames`
     queues, and a dropped first press would make run 8 a *first* press that passes vacuously)
     and from the reset run really leaving the stub's screen.
     **T7's subject is one of the few things here CONFIRMED ON A REAL NEXT** (build `00.12`,
     2026-08-07): reset→NMI re-initialises the debugger repeatably, and — the half **no bench here
     covered until T8** — a press with the stub *already up* correctly does **nothing** while `R`
     still works, so both arms of the discriminator were seen on silicon. `reported on hardware`:
     one machine, one reporter, no re-runnable artefact.
     **T7 TESTS ONE ARM OF THAT GUARD, AND T8 TESTS THE OTHER — the one M2 edits first.** The
     dispatch branches on the bank slot 7 held: not `MAIN_BANK` → re-initialise, which is T7;
     `MAIN_BANK` → decline, which is T8. A regression that sent *every* press to `init_main_bank`
     would destroy live debug sessions and **T7 would still pass** — measured, not argued: against
     exactly that ROM, T1-T7 are all green and T8 is the only red.
   - T9 **THE ASYNCHRONOUS-BREAK POLL (issue #22, M2), and the only check anywhere that runs
     the software-cause path** — about 400 times in one run, where every other check here fires
     an NMI once. A Copper list installed by the **debugged program** raises the Multiface NMI
     every frame; three runs. **Run 11** is the precondition, T3's shape: the same fixture against
     the stock MF ROM must take over, or a fixture that installed nothing would leave runs 12 and
     13 passing having polled nothing. **Run 12 is the transparency verdict** — no button is
     pressed, so no debugger exists, every poll pages `MAIN_BANK` in, finds somebody else's bytes
     where the magic should be, and must decline **and put MMU slot 7 back**; that is issue #26 on
     a 50 Hz timer, and it is the only run in which the interrupted program cares what slot 7
     holds. **Run 13 is liveness**: the stub is brought up and then polled thousands of times while
     stopped, judged byte-identical to T8's one-press screen **and** black-bordered, because
     "nothing changed" is also what a wedged machine looks like. Run 13 reuses T8's schedule
     unchanged so the pair differ only by the Copper list. Shown red: a build with the slot-7
     restore removed takes run 12 red, against the shipped ROM green three times.
     **THE POLL'S MEASURED COST IS 0.230% OF A FRAME AT 28 MHz — ≈1288 T-states, and 1.84% of a
     3.5 MHz frame, which is the number a contended-memory or beeper program pays.** Measured by
     `make measure-poll-cost`, an instrument rather than a gate: a fixed-length counting loop, two
     builds one assembler constant apart, HL differenced across nine frames, bit-identical over
     three runs, with the clock read off the machine (NR 0x07 = 0x33). **That retires plan §10's
     "~100-200 T-states/frame", which was 6-13 times low**; the 3.5 MHz figure is arithmetic from
     the 28 MHz measurement, and it covers the DECLINE path only.
     **AND THE POLL EXTINGUISHES AN RX-OVERFLOW DIAGNOSTIC**: reading the UART status register
     clears the sticky overflow and framing bits (`serial/uart.vhd:530-539`), so an overflow during
     a free run is wiped ~50 times a second before anything can report it and
     `Last Error: RX Buffer overflow` will never be seen for one. A lost *diagnostic*, not a lost
     guarantee — the byte loss still surfaces as a desync or a timeout. `mf_nmi_poll`'s
     prgm_state-first ordering fixes the *race* with the debugger's own reads and not this.
     **NOT covered**: it never breaks in (no client, so `transport_poll_traffic` answers "quiet"
     every time — that is W8); it cannot discriminate the `prgm_state` test, since with no traffic
     a build omitting it would decline anyway; **nothing stages an RX overflow while a debuggee
     runs**, so neither the extinction above nor its harmlessness has been observed; and **it does
     not cover the NextREG latch restore**,
     which was found by building that red-first and watching it come out **green** — the poll's own
     `.save_slot7_page_in` leaves port 0x243B selecting exactly the register the fixture reads.
     ~~**AND IT IS PADDED AROUND A PRE-EXISTING DEFECT**: a software NMI, taken repeatedly and
     returned from, does not reliably put the CPU back on the instruction it interrupted —
     reproduced on `main`'s OWN ROM, measured at ~2 NMIs, absorbed by eight NOPs either side of the
     check. Cause unresolved.~~ **RETRACTED 2026-08-11, and every clause of it was wrong.** It was
     **jnext's `--inject`**, which sets PC/SP/IFF1/IFF2 and never clears the CPU's HALTED flag
     (`src/core/emulator.cpp:6683`); NextZXOS idles in a `halt`, so an injected fixture running DI'd
     inherits `halted = 1` and can never clear it, and the first NMI alone takes jnext's
     `z80.halted ? pc+1 : pc` branch (`src/cpu/z80_cpu.cpp:636`) and captures PC **plus one**.
     Exactly ONE late return, which sixteen NOPs were merely wide enough to hide. **The padding is
     gone**: the fixture starts `ei : halt : di`, and with no padding at all a `jr $` under this
     Copper list is returned to **402 times out of 402**. Nothing about the stub, upstream's handler
     or the Next's NMI path was ever implicated. See `test/copper_poll.asm`, ERRORS.md and
     MEMORY.md 2026-08-11.
   - T8 a second M1 press with **no reset** is **declined**, and the stub is still alive
     afterwards (issue #36). Two runs differing only in that press, shot at the same frame; the
     screen must be **byte-identical** and the border **black**. Both halves are required,
     because **"nothing changed" is also what a machine that HUNG on the press looks like** — the
     stub's screen is already painted and a wedged Z80 repaints nothing, which is ERRORS.md's "the
     screen changed is not the stub took over" in its mirror image. Liveness is `test-no-hang`'s
     N1/N2 trick: press a key the stub polls and judge the border, black when `main_loop` was
     reached and whatever the cycle last wrote when it was not.
     **THE THIRD KEY IS NOT DECORATION AND WAS MEASURED RATHER THAN REASONED.** A "3" is pressed
     *before* the second press, retargeting the joy port — state `main_bank_entry` resets. Without
     it the check goes **green against the regression it exists to catch**: a re-initialisation
     followed by the liveness key reproduces the reference screen *exactly*, because the re-init
     resets `slow_border_change` and "B" then turns it off again. So the joy-port row is **read**
     with `test/screen-text.py` rather than compared — ERRORS.md's "these two differ is not this
     one is right" — which is also what says the press landed at all. Measured over three ROMs on
     one choreography: shipped `No joystick port used.` / black / **0.00%**; every-press-init
     `Using Joy 2 (right)` / black / **0.33%**; decline-spins `No joystick port used.` / **red** /
     **40.03%**. **The three event frames are asserted to be in order**, because
     `NORESET_NMI_FRAME=1500` — past the screenshot — came out **8/8 having pressed the button
     after the picture was taken**, which is W6's fail-green window in a new organ. Each frame is
     overridable so all three preconditions have a re-runnable red. **The border NAMES a wedge and
     the byte comparison CATCHES it**: a wedge freezes the border wherever `change_border_color`
     left it and that cycles 0..7, so about one run in eight it freezes on black — the comparison
     is phase-independent and still fires, 104 pixels, all in row 13, where the reference's "B"
     repainted `B = Border off` to `on`. **NOT covered**: the press-while-stopped case, which is
     W6's; anything on hardware — both arms *were* seen on a real Next at `00.12`, and T8 does not
     upgrade that, it makes the emulator half re-runnable; and **a WiFi ROM** — the discriminator
     is `uart_joyport_selection`, which exists only under `IF ROM_VARIANT == ROM_VARIANT_UART`.
     `make test` builds the UART ROM and `src/mf_rom.asm` is common to both, so the coverage claim
     holds; pointing T8 at the WiFi build would need different state to move before the press.
   Screen comparison is a **percentage of differing pixels** (`test/screen-diff.py`), not a byte
   compare: NextZXOS idling changes 0.01% of the screen and that once produced a false PASS.
   **T8 is the exception and asserts byte-identity**, which it can because the stub owns the
   screen there and NextZXOS is not idling behind it.
4. **`make test-mfselect`** — the mfselect bench, 6 headless runs, 10 checks, asserting on files
   pulled back off the SD image rather than on pixels. Deliberately **not** part of `make test`:
   mfselect is separate tooling and is not in `make all` either. Since #5 it covers **both** of our
   ROMs: each installs (M3, M8) and the first-run guard refuses **each** (M4, M7) — a guard that
   recognised only one variant would destroy the stock ROM for whoever chose the other, and no
   file-based check sees that. **M9 and M10 are the bench's only pixel assertions** and neither is
   a percentage, which could not separate four characters from noise. **M9 asks whether the label
   is right, not merely whether the two runs disagree** — the status row's transport field must
   match the *menu's own rendering* of that same label, in the same screenshot, and differ from the
   other entry. The distinction is not academic: an earlier M9 compared the two runs against each
   other, and two labels **swapped** passed it. M10 keeps the cross-run half — nothing else on that
   row may differ. Both use `test/cell-diff.py`. See `doc/MFSELECT.md`.
4b. **`make test-esp`** — the M0(b) ESP server bench: one headless jnext run with
   `test/esp_server.asm` injected, and a TCP client (`test/esp-echo-client.py`) connecting to the
   port the *guest* opened through the emulated ESP-01. Four checks, and they assert on **bytes
   over a socket**, which no other layer here does — E1 the AT chain came up and something is
   listening, E2/E3 payloads echo back byte-identically, E4 a second simultaneous connection
   echoes too. E4 is not redundant: with the `+IPD` connection id hardcoded to `1` the first
   three checks pass and only E4 fails, which was demonstrated rather than argued. Separate from
   `make test` for two structural reasons — it needs a client running *concurrently* with the
   emulator, and it binds a host TCP port, so it cannot make `make test`'s promise of no external
   dependencies. **It proves nothing about hardware**: jnext has no `AT+CWJAP=` setting form, so
   the emulated module is permanently associated, and it models baud as timing only.
4c. **`make test-dzrp-stub`** — the DZRP conformance suite against **our own WiFi stub**, and the
   strongest check here: one headless jnext run with `build/enNextMf-wifi.rom` installed as the
   Multiface ROM, an emulated M1 button press, and `test/dzrp/conformance.py` speaking DZRP over
   TCP through the emulated ESP-01. Every other layer judges a proxy — pixels, files, or bytes
   echoed by a fixture that is not the debugger. **W1** is the wait for the stub's own
   `AT+CIPSERVER` listener to appear, which can only happen after the NMI was taken, `MAIN` was
   relocated, UART0 came up at 115200 and `AT+CIPMUX=1` / `AT+CIPSERVER=1,11000` were accepted.
   Then the suite's own checks — whose loopback sweep runs past jnext's 2048-byte `+IPD` split, so
   the transport's reassembly across frames is covered rather than assumed. A second run adds
   **W2**: an unprompted `NTF_PAUSE` aimed at a client that has gone must leave the stub quiet
   (no error on its screen) and still serving, instead of parking on a TX timeout. A third run is
   **W3**, the negative control for C10 (below): the same run with only the `CMD_CONTINUE`
   withheld, which C10 must go red on. A fourth run is **W4** (issue #11): two clients write a
   command at the same instant, so the module emits two `+IPD` frames back to back, and **both
   must be answered** — until the fix exactly one was, because the frame sitting in the FIFO ahead
   of `AT+CIPSEND`'s `>` was skipped by the wait for that prompt, as though it were one of the
   module's unsolicited lines. It asserts the collision really happened from jnext's own log, so
   it cannot pass vacuously, and it was shown red on the commit before the fix. **The same
   defect's other window — the wait for `SEND OK` — is unreachable here** (jnext answers
   instantly) and is hardware bench H3 — **confirmed green on a real Next, 3 runs of 3, build 000A**,
   which is the symmetric answer to the 3 failures of 3 that opened the issue.
   A sixth run is **W6** (issue #26): the M1 button pressed while the debugger is **stopped**, which
   used to overwrite the debuggee's saved slot-7 bank with `MAIN_BANK` — the NMI entry path saved
   the bank it found on every press, and while the debugger executes that bank is its own, so the
   next `CMD_CONTINUE` would have paged the debugger into the debuggee's slot 7. It is visible over
   the socket because `CMD_GET_REGISTERS` reports slot 7 from that byte rather than from the MMU:
   `CMD_SET_SLOT` puts a known bank there, the press lands, and the same read must still see it.
   Shown red first, `before=30 after=94`. **The press has to land between the two reads, and the two
   edges of that window are held by different means** — a distinction that cost a review round,
   because getting it wrong makes this check fail **green**. The **right** edge is guaranteed: the
   bench waits for jnext's own `Delayed NMI button` line and only then releases the client through a
   sentinel, so the second read cannot precede the press. (`--delayed-nmi-frames` counts emulated
   frames while a client counts wall clock, so a sleep would be a guess.) That line is
   `platform`/`info`, so this run alone raises the log level; at the bench's usual `warn` it reported
   0 of 2 presses against a stub that had taken one. The **left** edge — the press must not precede
   `CMD_SET_SLOT` — is a frame margin **plus an assertion**, never "by construction": at the original
   600 frames it measured 149 ms in one run and **2 ms** in the next, and inverted it would let
   `CMD_SET_SLOT` overwrite what a corrupting press wrote, leaving `before=30 after=30` on a broken
   ROM. So the margin is 3000 frames (17.2 s measured) *and* the bench requires **`W6_SETUP_FRAMES`
   `+IPD` frames before the press** — every setup command the client sends, nine since W7 joined
   the run — failing red as a precondition otherwise. **`SECOND_NMI_FRAMES` is overridable so that control is re-runnable**:
   `SECOND_NMI_FRAMES=901 make test-dzrp-stub` puts the press before the client speaks, the client
   reports the exact green a corrupting ROM gives, and the precondition catches it. It is a *bench*
   seam, not one of the `IP_MAX` / `RX_WAIT` / `LINK_IDS` build-constant family — no probe ROM is
   built — but it exists for their reason: a red nobody can re-run is a story about a scratch tree.
   **W6's subject has NOT run on hardware and is not going to**: it needs an M1 press timed against
   a live DeZog session at the machine, and the user declined (2026-08-07). Unlike T7's, whose
   subject *was* confirmed on a Next, this defect's whole evidence is this emulator check — so read
   "issue #26 is fixed on hardware" as covering the decline and **not** the press-while-stopped.
   **W8 IS MILESTONE M2's ACCEPTANCE CRITERION.** A freely running debuggee is stopped from the
   PC — the thing dezogif has never been able to do, and which nothing in this project had ever
   shown. The debuggee installs the two Copper instructions itself, is resumed with **no temporary
   breakpoint** (so nothing the debugger planted can bring it back), left running a whole second,
   and then sent `CMD_PAUSE`. Its own run 8 is the **control**, `PAUSE_RUNNING_CONTROL=0` to
   disable: identical up to the pause, which is withheld, and nothing may come back — W3's
   argument, and without it a green W8 would not say the *pause* caused the break rather than the
   debuggee stopping by itself or never running.
   **THE VERDICT IS `CMD_GET_REGISTERS`, NOT THE NOTIFICATION, AND READING IT FROM THE WRONG PLACE
   IS WHAT MADE THIS A STANDING RED FOR A DAY.** `NTF_PAUSE`'s payload is
   `[id][reason][bp_addr][bank+1][string]` (`src/message.asm:342-362`) and `bp_addr` is the address
   of the **breakpoint** that stopped the program; `mf_nmi_button_pressed` passes `ld hl,0`
   (`src/mf.asm:169`), because a manual break — button or poll — has none. So those two bytes are
   `0x0000` by design on every remote, which the 2026-08-05 hardware capture of a real M1 press
   recorded verbatim (`payload=01 01 00 00 00 00`, with the PC arriving separately as
   `CMD_GET_REGISTERS` → `0x801C`). The first version of W8 asserted that field was the PC, reported
   `PC 0x0000`, and the number was **honest and about the wrong field**. It now reads the PC where
   the PC is, asserts `bp_addr` is zero as a check in its own right, and asserts `SP` — which is
   what says the stackless NMI pushed nothing onto the debuggee's stack.
   **SO IT IS THE FIRST CHECK ANYWHERE TO EXERCISE `save_nmi_return_address`'s STACKLESS BRANCH.**
   `backup.pc` on this path can only be that routine's, NR `0xC0` is read back to show bit 3 set,
   and C10 sets `PC` itself — so MEMORY.md 2026-08-05's "which branch ran is NOT established"
   is closed in the emulator. Measured: `PC=0x802D SP=0x9F00`, the spin and the fixture's own stack.
   **NR `0xC2`/`0xC3` are printed and must NEVER be judged**: the poll keeps firing against the
   stopped debugger and every acknowledge overwrites the pair, so a healthy stub always shows a
   *debugger* address there. Shown red two ways — a ROM whose stackless branch reports zero
   (`PC 0x0000`, i.e. the old symptom reproduced from a genuinely broken stub) and one that puts
   `0x1234` in the breakpoint field.
   **W7 RIDES ON W6's PRESS AND IS THE SAME DEFECT TWO BYTES ALONG** (issue #37): the entry path
   saved the clock speed and the `IO_NEXTREG_REG` latch into `backup.*` on every press too, two and
   eleven instructions after the slot-7 byte #26 fixed, so a press while stopped handed the debuggee
   back at the debugger's **28 MHz**. **It is NOT observable over DZRP** — `CMD_GET_REGISTERS`
   reports neither — which is why #37 shipped with no check at all where #26 had one from the
   day it was fixed. So W7 reads `backup.speed` and `backup.io_next_reg` **directly out of
   `MAIN_BANK`**, borrowing MMU slot 5 exactly as C22/C23 do, before and after the same press.
   **The addresses come from the build, not from the bench**: they move with every change to the
   debugger's data, so `run-dzrp-stub.sh` greps them out of sjasmplus's own label table
   (`--lstlab`) and a miss fails the run — a constant would go stale in silence and point the check
   at a byte nothing writes, which is the "green check that cannot fail" this project has shipped
   three times. Shown red first, in the same run that showed W6 green: `speed=0x00/0x33`.
   **`0x33` AND NOT `0x03`, WHICH FALSIFIED THE FIRST VACUITY GUARD**: `REG_TURBO_MODE` does not
   read back what was written — bits 5:4 are the *actual* speed and 1:0 the *programmed* one
   (`zxnext.vhd:5903`), while a write takes only 1:0 (`:5789`) — so the guard masks, and refuses to
   render a verdict at all if `backup.speed` already selects 28 MHz. **The `io_next_reg` half turned
   out to discriminate too, for a reason nobody was looking for**: `nmi66h`'s own cause check selects
   NR `0x02` *before* the instruction that claims to back the latch up reads it, so what is saved is
   always `REG_RESET` and the debuggee's real latch is destroyed on every press regardless
   (`0x00/0x02`, measured). That is a **second, pre-existing** defect in the same three instructions,
   deliberately out of #37's scope and harmless in practice — any code that writes a NextREG selects
   it first — and W7 asserts only that the byte is unchanged. **NOT covered**: hardware, for W6's
   reason and the same user decision; and the `.break_into_debuggee` half of the fix, since no run
   here presses M1 against a *running* debuggee.
   **C2** was the standing red
   until issue #7 landed: `cmd_init` read the remote's program name until a NUL and ignored the
   frame's length field, so a length that disagreed with the payload desynchronised silently
   instead of being rejected — pre-existing behaviour of the *serial* build, in common code the
   WiFi work never touched. It now consumes exactly the declared payload, and **C9** covers the
   half C2 cannot see: an honest length whose payload runs past the name's NUL, with a second
   command behind it that must still be answered in sync. That fix changed both ROMs' bytes, by
   design, and it is the one merge to date that legitimately broke the UART byte-identity gate.
   **C10-C12 are where the stub is shown to RESUME a debuggee**, which nothing before them
   had ever shown anywhere — the exit path, `backup.asm`'s restoration and the AltROM patch were
   code no test executed. C10 loads a fixture, sets `PC`/`SP`/`BC`/`IX`, continues onto a temporary
   breakpoint and reads the `NTF_PAUSE`; C11 adds that the registers reached the running program
   and came back as it left them. **Still not covered**: the stackless-NMI *return address*
   (C10 sets `PC` itself, so `save_nmi_return_address` is never involved) and the M1 button
   breaking a *running* debuggee — both need a second NMI timed against live traffic.
   **C16-C18 ARE THE SIZES A REAL SESSION MOVES, AND UNTIL THEY EXISTED THE SUITE STOPPED AT 4096
   WHILE THE PRODUCT'S LARGEST INBOUND FRAME WAS FOUR TIMES THAT** — DeZog pushes 8 KB per
   `CMD_WRITE_BANK` on every F5, and nothing had ever sent one. **C16** is a full 8192-byte bank in
   and read back; **C17** is **16 KB in one `CMD_WRITE_MEM`**, the largest single inbound payload
   reachable at all, and the only check that writes across a slot boundary in one command. They are
   deliberately not an extension of C5's loopback sweep: a loopback exercises receive **and** send,
   where these are receive-only — and the receive path alone is what brackets the UART ceiling
   (MEMORY.md, issue #25). **C5 does now end at 8192**, which is the largest legal loopback there
   is, because `cmd_loopback` buffers the whole payload into one 8 KB bank before replying.
   **C18 IS THE OTHER SIDE OF THAT BOUNDARY AND IT GUARDS A CLIENT-CONTROLLED WRITE OVER THE
   RUNNING DEBUGGER.** `cmd_loopback` and `cmd_write_bank` both walked upward from `SWAP_ADDR` for
   as many bytes as the **frame declared** — a number the client chooses — and one slot further on
   is `MAIN_SLOT`. Unbounded since the fork, in upstream code, in both ROMs. It survived five years
   because nothing ever sent a big enough frame, and **writing C16/C17 is what found it**. Both
   handlers now refuse before reading and report `Payload too big for swap bank`; C18 asserts only
   that the remote **survives and serves on**, because DZRP has no error response for either command
   and a reply of the wrong length would desynchronise everything after it. A remote that answers
   instead passes too — what C18 refuses is one that stops serving.
   **C15 is the only check that sends `CMD_CLOSE`** — every other one takes a fresh connection and
   simply drops it, which is a TCP event and not a DZRP one. It asserts the Length=1 response
   **and** that a `CMD_INIT` after it is answered, because `cmd_close` answers first and only then
   tears the session down — it sets `prgm_state` itself (`src/commands.asm:239-240`) and then leaves
   through `jp main`, whose prologue resets the debuggee's saved state: the
   response is written before all of that and proves none of it. It runs **last**, and must, since
   it re-initialises the stub. What it cannot see is that any of that state really was reset —
   none of it is observable over a socket.
   **Every check prints one short verdict, about twenty words**; the reasoning is in each check's
   docstring and in `doc/DZRP-TESTING.md`. **The budget counts the `detail` — the sentence a check
   writes about what happened — and NOT the label**, which is the check's fixed title from the
   `CHECKS` table and is not prose the check chose. (`hardware-check.py` prints only a bare tag
   plus a detail, and H3's long-agreed ~25-word exception is a detail; and labels here run 3-9
   words, so charging them would buy different checks different amounts of prose for one rule.)
   Measured mechanically 2026-08-06 over all **81** reachable details: single-cause details run
   **1-14 words, median 8**, longest **14** — so **no single-cause exception exists**. **Four**
   branches exceed the budget deliberately, all joins of several *independent* faults, each marked
   at its call site: C11's (**58**), `hardware-check.py`'s two H2 composites (**38** and **27**),
   and C10's (**29**). They are not truncated, because each joined fault is separately load-bearing
   and a badly broken resume is exactly what fails on several axes at once — the same argument that
   keeps H3's composite long.
   The **id** is interface, not prose: `run-dzrp-stub.sh`'s
   W3 greps `^FAIL  C10 ` and `hardware-check.py` takes the code from field 2 of every `FAIL` line.
   **Result 2026-08-05: W1-W5 pass, 15 passed / 0 failed of 15 — the target exits 0.**
   **C19-C21 ARE ISSUE #27: EVERY BREAKPOINT ANYWHERE ROM WAS MAPPED WAS SILENTLY DISCARDED.** A
   DZRP breakpoint is a byte patched into memory, and `0x0000-0x3FFF` on a stopped Next is **not
   writable** — `sram_pre_rdonly <= not (nr_8c_altrom_en and nr_8c_altrom_rw)` (`zxnext.vhd:3056`)
   gates the SRAM cycle at `:3154`, and `copy_modify_altrom` leaves NR `0x8C` at `ALTROM_ENABLED`
   (bit 7 set, **bit 6 clear**) for the whole session, which serves reads from the patched Alt ROM
   and discards writes. So the `RST 0` never arrived and the stub reported success, because no
   breakpoint path reads back what it wrote. Upstream's, in both ROMs, since the fork. **C19 is the
   mechanism** (the byte does not land), **C20 the consequence** (the breakpoint never fires), and
   **C21 the guard the fix required** (see below). Each carries its own control **in the same run**,
   because a breakpoint that does not fire is otherwise indistinguishable from a resume that never
   worked — the confound that wrecked the one attempt to test this at the machine. Measured red:
   `0x1234` read back `0xED` after a `CMD_SET_BREAKPOINTS` that took at `0x8000`, and a debuggee
   that `call`ed a ROM `RET` ran straight through to the RAM control.
   **THE FIX AND ITS GUARD ARE ONE CHANGE AND NEITHER MAY LAND ALONE.** `write_debuggee_byte` sets
   bit 6 for the write alone, which lands it in the Alt ROM — the image the debuggee executes.
   Reads must **not** be taken in that state: with bit 6 set the *real, unpatched* ROM serves reads
   (`:3078`), so the opcode kept for un-patching is read before the call, as every caller already
   did. But making writes land turns the original report's other mechanism from impossible into
   live: `copy_modify_altrom` patches 8 bytes at `0x0000` and 14 at `0x0066`, and an `RST 0` over
   `dbg_enter` makes every breakpoint re-enter itself. So `bp_hits_trampoline` refuses those 22
   bytes — leaving them behaving exactly as they did before, since nothing reached them then
   either. **THE GUARD SHIPPED WRONG AND THE REVIEW MEASURED IT**: a `ret c` returned with the carry
   its own contract reads as "refuse", so it took `0x0000-0x0073` — **116 bytes**, including `RST 8`,
   the `RST 0x10`-`0x30` vectors and **`0x0038`, the IM1 handler** — and, since `set_tmp_breakpoint`
   shares it, **stepping ran away** in that window, which is #27's own failure recreated by its fix.
   **So C21 asserts the EXTENT**, every byte of both blocks refused *and* `0x0008`/`0x0065`/`0x0074`
   taken: a version constraining only `0x0000` and `0x0066` passed green against a guard planting
   `RST 0` at `0x0001-0x0007`. Shown red four ways — unfixed → Precondition; no guard, guard too
   narrow, and guard too wide → three different C21 reds. **Measured over the wire, not read**:
   refusal set `0x0000-0x0007 0x0066-0x0073`, and `0x0052` now stops on its breakpoint.
   **`cmd_restore_mem` is guarded too**, and the first version was not: a client put its own byte on
   `0x0000`/`0x0066` through it — C18's defect one command along. `bp_hits_trampoline` is a pure
   function of the address, so guarding a restore can never strand a legitimate un-patch.
   `clear_tmp_breakpoint` stays unguarded because its address is the stub's, not a client's.
   **NOT covered**: `CMD_WRITE_MEM` into ROM space is still discarded (`memory_loop`'s per-byte path
   is the receive path the baud ceiling is about, so it is deliberately not bracketed).
   ~~and none of this has run on hardware~~ — **it has, 2026-08-11, 23 of 23 on a real Next**: C19
   set and removed a breakpoint at `0x1234` in ROM, C20's debuggee **stopped on the ROM breakpoint
   at `0x0280`**, and C21 measured the guard's extent there. So the AltROM write path and its
   trampoline guard are executed code on silicon. See `doc/DZRP-TESTING.md`.
   **C22 AND C23 ARE THE 64K ADDRESS FORM AT AN ADDRESS IN THE DEBUGGER'S OWN SLOT** (issue #38).
   `cmd_set_breakpoints` and `cmd_restore_mem` decide whether a 64K-form address needs the swap
   window by comparing against `0xE000` — and did it **with `A` still holding the bank+1 byte**,
   which on that path is zero by definition, so the test was always `0 < 0xE0` and the direct write
   always won. An address at `0xE000` or above therefore landed in `MAIN_BANK`, the bank the
   debugger executes from, at a client-chosen offset and — in `cmd_restore_mem` — with a
   client-chosen byte. Upstream's, in both ROMs since the fork; **C18's family, one command along**.
   It survived because **nothing had ever sent that input**: DeZog uses long addresses, and C19/C21
   do send the 64K form but at addresses from `0x0000` to `0x8000` — C21 covers `0x0000`-`0x0008`,
   `0x0065`-`0x0074` and `0x1234`, and `0x8000` is C19's RAM control — where the direct branch is
   the *correct* one.
   The verdict is a **positive read-back**, not a wait to see whether the stub dies — a one-byte
   write into the running debugger may or may not be fatal, so "it crashed" would be a weak and
   flaky signal. The debuggee's slot-7 bank is seeded through `CMD_WRITE_MEM`, the handler is
   driven, and the address is read back through `memory_loop`'s own (correct) swap window: the
   written byte means the write went where it was asked, **the seed means it went to `MAIN_BANK`**,
   anything else is a third thing. **`MAIN_BANK` IS ALSO READ DIRECTLY, BY A SECOND ROUTE**, which
   is what turns "the write went where asked" into *"the debugger's own bank was not written"* — the
   property the issue is about: MMU slot 5 is borrowed to put `MAIN_BANK` at `0xA000`-`0xBFFF`, so
   `0xBF80` is the same physical byte **below** `0xE000`, i.e. reached by `memory_loop`'s *phase 2*
   rather than the swap window the verdict depends on. Slot 5 and not slot 4, since slot 4 is where
   the fixture, the marker area and `BIG_MEM_ADDR` live — C17 *does* span slot 5, so the argument is
   ordering: it has finished, the borrow only reads, and no later check reads that region. **The
   restore is asserted, not assumed**: C23 opens with one `CMD_GET_REGISTERS` **before its own
   `CMD_INIT`** (which would erase the evidence) and refuses if slot 5 still holds `MAIN_BANK` —
   without it a failed restore is invisible, since the next borrow reads `was` as `MAIN_BANK` and
   still reports correct before/after values. Survival is asserted **in band** — the read-back is
   an exchange the stub has to serve *after* the offending write. **Two checks and not one**, because
   the two handlers carry separate copies of the decision, so a fix to either alone must still leave
   a red naming the other. The probe address is `0xFF80`, **above the SAVEBIN image itself**
   (`0xFEC0`) let alone `main_end`, which `main.asm`'s `ASSERT` pins at or below `ROM_MAGIC_ADDR`
   (`0xFEA0`, and it only ever moves down) — so a defective stub writes into dead space, the red is a
   repeatable reading, and C18 and C15 below still pass. No new `ASSERT` is needed; the existing ones
   pin it structurally with 224 bytes of margin. Shown red first, and the red **demonstrates** the
   defect rather than inferring it: *"the debugger's own bank was written: MAIN_BANK 0xFF80 went 0x00
   to 0xC7"*.
   **NOT covered**: ~~neither check has run on hardware~~ — **both did, 2026-08-11**, and each
   reported its 64K-form write reaching the debuggee's bank on a real Next. The defect itself has
   still never been observed anywhere but here. What is **no longer** a gap is the `memory_loop`
   vacuity — see
   `doc/DZRP-TESTING.md`; the second route closes it in-suite, and the red-first pair closed it
   independently.
   **The suite is 25 since C24-C25 landed (issue #41 — the honest refusal of `CMD_ADD_BREAKPOINT`
   and `CMD_REMOVE_BREAKPOINT`, which DeZog's `cspect` remote sends whenever a breakpoint is set in
   the editor and which the stub had answered with SILENCE), was 23 since C22-C23, 21 since
   C19-C21, and 18 since C16-C18**; the 2026-08-05 figure is left as the measurement it was
   rather than restated, and the hardware run of 2026-08-08 that reports 15 of 15 was also taken at
   the suite's size then. **C16-C18 HAVE now run on hardware — 2026-08-09, build `00.19`, 18 of 18
   with the whole bench at 6 of 6.** And C18 carries the strongest evidence in this project's
   history for any single fix, because **the red was taken on the same machine an hour earlier**:
   against build `00.16`, which predates the bound, the same check **destroyed the stub** — border
   yellow and frozen, `B` and `R` both dead, power cycle required — where `00.19` reports *"a
   12288-byte payload was declined and the remote served on"*. One build apart, same Next, same
   client. See `doc/HARDWARE-TESTING.md`.
   **C12 was the last red and issue #8 closed it**: `CMD_PAUSE` was mapped to `cmd_not_supported`,
   which stores an error and jumps to `drain_main`, so the stub sent **no response at all** where
   the spec requires a Length=1 one and a client waited forever. Same shape as C2 — common code
   the WiFi work never touched, upstream's own 2023 jump-table entry — so the fix changed both
   ROMs' bytes and carried a bump. It is `cmd_pause`, and it acknowledges and does nothing else:
   `cmd_loop` runs only while stopped, so there is nothing to pause, and writing `prgm_state`
   would clobber `PRGM_LOADING` and break the next `cmd_continue`'s "loading finished" branch.
   **Every check in this suite is now green in the emulator**, which is also why
   `test/hardware-check.py`'s `KNOWN_RED` table is empty: a red on a real Next is now a hardware
   finding by construction, with no known-red to hide behind.
   See `doc/DZRP-TESTING.md`. Like `test-esp`, not part of `make test`: it binds a host TCP port.
   **It says nothing about hardware.**
4d. **`make test-unit`** — the Z80 unit tests under `src/unit_tests/`, headless (issue #3). One
   jnext run of `build/ut-headless.nex`, 5 checks. **28 of the 66 test cases run; 38 cannot and
   are reported as `UT-SKIP` on every run.** Those 38 need ports invented by `src/simulation/uart.js`,
   a JavaScript peripheral DeZog's zsim loads as `customCode` — the Z80 cannot trap its own I/O,
   so they are unreachable from inside the guest, and a project-specific peripheral does not
   belong in jnext. **Do not read a green run as "the unit tests pass"**; read it as
   "the 28 that can run, pass". What they cover is the banking and breakpoint code — all of
   `ut_backup.asm` (9), all of `ut_breakpoints.asm` (8), all of `ut_utilities.asm` (4) — **plus
   seven the older wording of this sentence denied**: `ut_uart.UT_transport_read_byte_timeout`,
   and six of `ut_commands` (`UT_get_cmd_pointer`, `UT_04_cmd_set_register`'s `UT_SP_to_HL2` /
   `UT_A_to_IR` / `UT_im` / `UT_wrong_register`, and `UT_07_pause`). 21 + 7 = 28.
   ~~not the DZRP command layer, whose gate is `test-dzrp-stub`~~ — **that clause was the wrong
   shape**: the command layer's gate really is `test-dzrp-stub`, and it is not true that *no*
   `ut_commands` case runs here. **Enumerated from a run, 2026-08-11**, not from the source and
   not from this sentence, which is how the discrepancy was found in the first place — the
   totals were right and pinned in two places the whole time, so nothing here could drift; what
   drifted was the prose describing where the 28 come from. The count is pinned in **two** places (the Makefile,
   checked against the sources at build time; the bench, checked against what ran), because
   pinning only the total would let a test slide from the runnable set into the excluded one
   unnoticed. **Silence is a FAIL**: jnext's run is frame-bounded, so a hang ends it quietly with
   status 0, and check U2 requires an explicit end-of-run marker — the last `UT-BEGIN` names the
   test that wedged. Not part of `make test`, for consistency with every other bench here rather
   than for the usual reason: this one has no external dependency and binds no port. See
   `doc/UNIT-TESTS.md`. **It says nothing about hardware.**
4e. **`make test-ip-boundary`** — the `AT+CIFSR` address-length boundary, 2 headless jnext runs,
   and the only bench here that **moves a build-time constant to reach its subject**. jnext's
   module answers with `192.168.1.50` and that is a `static constexpr` with no option behind it,
   so the shipped `ESP_IP_MAX` of 15 is unreachable by any run: a bound that no input can ever
   touch has no test, however many benches are green. So `ESP_IP_MAX` is `IFNDEF`-guarded and
   `IP_MAX=` builds probe ROMs under their own names — one at 12, where jnext's own answer *is*
   the maximum-length case (**B1**, must be accepted), one at 11, where it is one too long
   (**B2**, must be refused). Same Z80 code, same emulator, same real reply; one constant
   different. **B1 is the discriminating half** — B2 passes against the broken parser too, and is
   there so a "fix" that stopped bounding anything cannot pass. Verdict is bright-red pixels on
   the stub's own screen, as in W2. It exists because that boundary shipped broken and every
   other layer stayed green: see ERRORS.md. **The maximum-length line is still never RENDERED** —
   no bound setting makes jnext produce a 15-character address — so the 32-column fit is held by
   an assembler `ASSERT` instead. **It says nothing about hardware.**
4f. **`make test-tx-patience`** — the budget `esp_flush_chunk` gives the module to answer an
   `AT+CIPSEND`, 3 headless jnext runs, and the **second** bench that moves a build-time constant
   to reach its subject, for the same reason as 4e: jnext answers instantly, so the timeout arm is
   dead code in the emulator and stayed green right through issue #11's hardware failure.
   `ESP_RX_WAIT` and `ESP_TX_PASSES` are `IFNDEF`-guarded and `RX_WAIT=` / `TX_PASSES=` build probe
   ROMs under their own names. **P1** the shipped `ESP_TX_PASSES=10` against a module slower than
   one pass — `CMD_INIT` and a 1024-byte loopback both complete, screen clean. **P2** the pre-fix
   single budget, same module — a reply is lost and the screen shows **824 bright-red pixels**, the
   count W2 measured pre-fix, i.e. `Last Error: TX Timeout`, which is exactly what the user read
   off the Next. **P3** the same `TX_PASSES=1` build at the *shipped* `ESP_RX_WAIT` completes — so
   P2's red is the injected budget, not `TX_PASSES=1` by itself. P1 and P2 differ **only** in
   `TX_PASSES`, which is what attributes the lost reply to the two waits the fix scopes. Not part
   of `make test`: it binds a host TCP port. **It says nothing about a real ESP-01** — the value 10
   is a judgement call, and only H3/H5 on hardware can settle it.
4g. **`make test-client-status`** — WiFi mode's session line (issues #14, #23 and #28), 8 headless
   jnext runs, and the **only bench here that reads the screen back as TEXT** rather than comparing
   it with another picture. **N1** a client connects over TCP and says nothing: the line must still read
   `No debug session yet.`, because the line reports a DZRP session and a socket is not one — that
   is the honesty check, not a baseline. **N2** after `CMD_INIT` it reads `Session opened
   - CMD_INIT`; **N3** after `CMD_CLOSE` it reads `Session closed - CMD_CLOSE`, with the client
   sending one further command first, because `cmd_close` answers *before* it reaches `show_ui` and
   so its response proves nothing about the screen.
   **N4 and N5 are issue #23**: the client **vanishes** — drops its socket with no `CMD_CLOSE` —
   and the line must read `Session lost - client gone`, which the stub can only say because it now
   watches the module's own `<id>,CLOSED`. **A fourth string and not N1's**, deliberately: reusing
   `No debug session yet.` would make this state indistinguishable from one where `CMD_INIT` was
   never seen, so the check would go green against a ROM that had simply failed to light the line —
   mfselect's M9 again. **N5 is not a second copy of N4**, and the difference is which code redraws
   the row: N4's client vanishes with the stub inside `cmd_loop`, so the scan that meets the
   `<id>,CLOSED` finds no header, times out and reaches `drain_main`, whose `show_ui` draws it;
   N5 waits for that wait's own bound to expire into `main_loop` first, where nothing times out and
   `drain_main` is never reached, so the only thing that can have drawn it is
   `esp_refresh_client_line`. That is **asserted rather than reasoned** — N5 requires the error
   area to be **clean**, which a run through `drain_main` could not be, since it carries
   `RX Timeout`. Without that line the two runs would exercise one path and claim two.
   Shown red first: N4 and N5 both red against `main`'s ROM, N1-N3 green in the same run.
   **N6, N7 and N8 are judged over the SOCKET rather than off the screen, and all three are about
   memory rather than text.** N5's repaint is autonomous and network-triggered, and it writes at
   `0x4000` — which is the display file only while the debugger's own **MMU slot 2** is mapped
   there. `CMD_SET_SLOT 2,<bank>` is an ordinary DZRP command that retargets it, so N6 is N5 with
   one command in between: a 2 KB probe is parked where row 8's eight scanlines land, the client
   vanishes, and the probe must read back **unchanged** over a fresh connection. Its **third**
   outcome is a precondition and not a verdict: all-zeros means `show_ui`'s `MEMCLEAR` reached that
   bank, i.e. the run went through `drain_main` and never stood in the state under test — which is
   why the probe is not all zeros and why the second connection sends no `CMD_INIT` (that
   would put bank 10 back). **Two corrections to that, made under #28 and changing nothing the
   check does**: the probe is *not* zero-**free**, as this paragraph used to say — eight of its
   2048 bytes are `0x00`, which is why a red reports 2040 changed — and the all-zeros outcome
   **cannot fire at all**, because any run reaching `show_ui` also draws glyphs into character rows
   8-15, which is exactly the probed `0x4800`-`0x4FFF`, so it reports `CORRUPT` instead.
   **Shown red against this branch's own first commit**, which has the writer and not the
   guard: `96 of 2048 bytes changed, first at 0x4908`. **The first version of
   N6 was 32 bytes at `0x4800` and passed against that same ROM** — scanline 0 is the one scanline
   two text strings cannot differ on, because the top row of essentially every ZX glyph is blank.
   Measured against the font, not reasoned.
   **N7 is the same question one slot along** (issue #31): the glyphs are read from the ROM now, so
   `text.font_map` pages ROM into **slot 1** for the duration of a paint, and slot 1 has no backup
   anywhere either — it is read back with `CMD_GET_REGISTERS`, which reports slots 0-6 live from
   the MMU.
   **N8 IS THE SAME DEFECT IN `show_ui` ITSELF, AND IT IS THE BIG ONE** (issue #28). N6's painter
   writes one row; `show_ui` opens with `MEMCLEAR SCREEN, SCREEN_SIZE` and then fills 1248 more
   bytes of attributes before it prints a character, so through a retargeted slot 2 that is
   `0x4000`-`0x5CDF` — **7392 bytes** — of the client's bank destroyed rather than 96 bytes of it.
   (The issue says 8 KB; that is the size of the *slot*, not of the write.) Upstream's, in
   **both** builds, and the fix is the opposite shape to N6's: `show_ui` **forces** the window and
   restores it (`ui.asm`'s `screen_map`), because abandoning the debugger's own screen would leave
   the machine showing whatever was there and `last_error` unreported. **Its trigger is
   `CMD_CLOSE`, not the "B" key issue #28 names** — the same `main_redraw` either way, but a
   client ordering its own commands over a socket carries **no margin at all**, where an injected
   keypress is scheduled in emulated frames against a client counting wall clock (W6's mismatch,
   and N5's `IDLE_WAIT` is still a margin). That also **widens** the defect the issue describes:
   `CMD_CLOSE` is what DeZog sends on every Shift+F5 and `drain_main` reaches the same `show_ui`
   on any RX timeout, so nobody need be at the machine — which is the state N6's `WIPED` wording
   *describes* while being unable to reach it (above). The precondition is `N3`'s ordering proof
   reused: `cmd_close` answers **before** `show_ui`, so only a reply to a *further* command shows
   the repaint happened. Slot 2 is read back **before** the bank so "left the window forced" and
   "wrote through the client's bank" are two verdicts and not one. **Shown red first**, against
   `main`'s ROM: `2040 of 2048 bytes changed, first at 0x4800` — 2040 and not 2048 because eight
   bytes of the probe are themselves `0x00`. **What it does not cover**: a "B" press with slot 2
   retargeted, and the return of a *post-press* `show_ui` — `test-no-hang`'s N2 presses "B", but
   its black border is written by `check_key_border` itself before `jp z,main_redraw` is taken, so
   it shows the shell was **entered** and says nothing about its returning. Nor does N8 check
   `SCREEN_BANK`'s **value**: a `SCREEN_BANK=11` build spares the client's bank too and would pass
   it. N1-N5 cover the number, by reading row 8 back as text.
   **Why not a cross-run comparison**: the two interesting states are adjacent lines of similar
   length, so **swapping them** is the obvious bug and is exactly what sailed through mfselect's
   first M9 (ERRORS.md). `cell-diff.py`'s answer there — find the correct glyphs elsewhere in the
   same image — is unavailable here, because these words appear nowhere else on that screen. So
   `test/screen-text.py` decodes the row with the ZX ROM font taken off the same SD image the
   machine boots, and each run is judged on what it *says*. Shown red first three ways: `main`'s
   ROM 0/3, the labels swapped N2+N3 red, `cmd_close`'s setter removed N3 red.
   The reader is validated **inside each image** before its verdict is used (row 12 must read
   `R = Reset`), and the capture's mtime is checked against the client's own timestamp, so a
   screenshot that came too early reports a harness fault rather than a wrong line.
   **Scope**: it covers what `CMD_INIT`, `CMD_CLOSE` and the module's `<id>,CLOSED` prove, and
   nothing else. **NOT covered**: a client that stops answering *without* its socket closing — the
   module emits no line for that, so nothing can see it (KNOWN-ISSUES.md #2); a `<id>,CLOSED` that
   lands inside a `transport_drain`, which reads with raw `in` and hands the bytes to nobody; and
   what the stub *does* about a departed client, which is nothing at all — the observation touches
   the session line and none of the transport's own state, on purpose, and reconnect and recovery
   policy are issues #24 and #25. **UART mode draws no such line at all**, deliberately: over a
   cable there is no connection event to observe, so there is nothing here to test. **It says
   nothing about hardware.**
4h. **`make test-no-hang`** — issue #16: waits that end, sends that are not abandoned, and a
   module the stub can bring back up by itself. 4 headless jnext runs, and the **third and fourth**
   benches to move a build-time constant to reach their subject. **N1** the loop as it was
   (`WAIT_SECS=0`) — a client that speaks once and then goes quiet **without hanging up** leaves
   the stub in `cmd_loop`'s wait; **N2** the *shipped* ROM, one constant away, where the bound
   expires. **The verdict is a keypress, not a reply, and that is load-bearing**: the wait ends on
   **any** byte from the module, so a second command — or a disconnect, whose `<id>,CLOSED` the
   module emits — un-sticks even the unbounded build, and asserting "can it still serve" would have
   produced a check that passes either way. That is a *hardware* measurement, not a reading: a
   client killed mid-command on a real Next, next connection answered in 4 ms. So "B" is pressed
   during the silence and the border is judged — yellow when `main_loop` was never reached and the
   key was never polled, black when it was. **N3** an `AT+CIPSEND` whose `>` arrives later than the
   stub will wait (`RX_WAIT=400 TX_PASSES=1`): the announced `<len>` bytes must still be written,
   or the module counts them off against whatever it is told next. jnext holds that state **by
   construction** — `esp_at.cpp:496` enters payload mode with the prompt, `:181` counts, no timeout
   between — so it was **shown red on the commit before the fix**: both clients unanswered at 20 s,
   against both answered in 0.01 s after. Its precondition is 824 bright-red pixels of
   `TX Timeout`, because jnext's log cannot show *our* budget expiring. **N4** the self-recovery
   with `FAULT_LIMIT=1`: the chain really re-runs (`AT+CIPSERVER=0`, then one more `— listening`
   than a bring-up alone) and a client is served afterwards. **N4 shows the mechanism fires and
   nothing more** — no run here can make the emulated module unresponsive, so what it
   re-initialises is a module that was never broken.
   **None of this fixes issue #15 and none of it may be described as doing so**: four candidate
   triggers driven at a real Next on 2026-08-05, including both mechanisms this bench covers, all
   recovered within ~3 s. **NOT covered**: the serial build's half of the bound (identical code,
   and nothing here can drive that transport headless — T6 attaches no client, so it never reaches
   `cmd_loop`), the recovery at its shipped limit, and anything about a real ESP-01. Not part of
   `make test`: it binds a host TCP port.
4i. **`make test-screen-agreement`** — the DZRP **screen reader**, 2 headless jnext runs, and the
   only bench here that judges one artefact against **two independent views of it**.
   `test/dzrp/screen.py` fetches the stub's own display file with `CMD_READ_MEM 0x4000,6912`, so
   `doc/HARDWARE-TESTING.md`'s S1-S4 — the error area, the connect block, the session line — stop
   being a photograph a human interprets and become text in the bench output. **G1** a clean
   screen, **G2** the same shipped ROM with a real error painted on it. Each is checked three ways:
   every one of the 49152 pixels rendered from the DZRP bytes must equal jnext's own screenshot
   (**P1**, an exact match, not a percentage — both views are of the same frame's memory, so there
   is no noise to threshold), the bright-red counts must agree (**P2**), and the border must
   contribute none, since the whole-image count P2 compares against would otherwise not be the
   error text alone (**P3**).
   **The two views share nothing but the machine** — one is the emulator's ULA renderer, the other
   is the Z80 answering over an emulated UART and ESP-01 — which is what makes agreement evidence
   rather than a restatement. It is available only in the emulator, and that is precisely why the
   reader is earned here and believed on hardware.
   **G2 is the discriminating half**: a reader checked only against a blank error area is checked
   against the case where every wrong answer agrees with the right one on zero — mfselect's M9
   again (ERRORS.md). Its lever is command 42, which `cmd_not_supported` turns into
   `Last Error: / Command not supported`, deliberately **not** the tx-patience bench's injected TX
   budget: that reddens the screen by crippling the transport this bench must read 6912 bytes back
   through.
   **Two facts it established that are now load-bearing elsewhere.** The figures this project
   quotes (824, 848, 1044 bright-red pixels) are **physical** pixels in a PNG jnext renders at
   scale 2, so `824 of TX Timeout` is **206** logical — P2 checks that relationship instead of
   leaving it to be rediscovered. And **a client disconnect can paint `RX Timeout`** — measured a
   second after a clean close and persisting, issue #16's `<id>,CLOSED` reaching `drain_main` —
   though **not unconditionally**: probe A's own A5/A6 read clean after three closes, so it depends
   on what arrives next. What a probe asks is therefore whether the text is something *other* than
   that, which only a decoded area can answer.
   **Not part of `make test`**: it binds a host TCP port. **It says nothing about hardware** — but
   what it validates is the display-file addressing, attribute decoding and palette, which are the
   same silicon either way. The reader **cannot see the border** in either place.
4j. **`make test-slot-recovery`** — whether anything gives the module's inbound slots back, and
   whether it reaps anyone it should not (issues #19, **#24** and **#40**), **7 headless jnext runs,
   9 checks**, and the **fifth, eighth and tenth**
   benches to move a build-time constant to reach their subject. Nothing in the stub had ever closed an established connection:
   `AT+CIPSERVER=0` retires the *listener* and leaves live connections alone, so a peer that wedged
   rather than closing kept its slot until the **module** reaped it, and enough of them left
   the module refusing every new client while `esp_recover` went on reporting success — **issue
   #15's outward signature reached by a mechanism that is entirely ours**. `esp_recover` now sweeps
   every link id with `AT+CIPCLOSE=<id>`. (That read "for the rest of the power-on session" until
   2026-08-08, when the module's `AT+CIPSTO` idle timeout was measured **enforced** on a real Next
   at its 180 s default — so the leak is bounded, not held until the power switch. **The bound is
   ~180 s on that default, and ~1800 s only from build `00.21`**: issue #24 set that value at
   bring-up from `00.14`, but sent `AT+CIPSTO` one step BEFORE `AT+CIPSERVER` and a real module
   **refuses it with no server running**, silently — so `00.14`-`00.20` were ~180 s too. Measured in
   `.UART` 2026-08-11; invisible to `make test-cipsto`, which jnext passes in either position
   (jnext#249).
   `KNOWN-ISSUES.md` #2 and `doc/HARDWARE-TESTING.md` carry the runs. The same clause survived in
   `src/transport_esp.asm`'s `esp_recover` header as a known stale comment, because that change
   deliberately touched no `src/` file; **issue #29 has since corrected it**, comments only and with
   both ROMs proven byte-identical.)
   **S1** fills every inbound slot with connections that were *answered* and are then held —
   answered, because a refusal at the ceiling otherwise has two indistinguishable causes, "the
   module is full" and "the stub is wedged", which is the position #15 was reported from — confirms
   the module stops granting them, injects one truncated command so the fault count reaches its
   limit, and requires a **fresh client to be served afterwards**. **S2** counts the sweep's own
   `AT+CIPCLOSE` lines out of jnext's log, **per recovery rather than in total**: a module that
   freed slots for some other reason would satisfy S1 and say nothing about this code. **S3** is
   the control, `LINK_IDS=0`, which assembles `esp_recover` exactly as it was — measured: 5
   `AT+CIPCLOSE` and served on the 2nd attempt against **0** and **refused 40 times in 40 s**, one
   constant apart.
   The trigger connection is **left open on purpose**: a client that hangs up hands its slot back,
   which is the thing being measured. Both ROMs are `FAULT_LIMIT=1`, N4's seam, since five
   consecutive faults cannot be produced against an emulator that answers everything.
   **Writable only because jnext#211 landed** — #16 declined this fix precisely because
   `AT+CIPCLOSE=<id>` did not exist in any bench here, which would have meant shipping Z80 nothing
   could execute. Needs jnext ≥ 0.99.127 and binds a host TCP port, so it is not part of
   `make test`. **It says nothing about a real ESP-01**, whose ceiling is 5 where jnext's is 4
   (measured on the user's Next, 2026-08-06) — the sweep is written not to care, and no run here
   can check that it was right to be. It also does not reproduce a **wedged** peer, only an
   occupied slot, and it is **not** a fix for #15.
   **S4-S7 ARE THE TRIGGER, WHICH IS THE HALF #19 NEVER HAD** (issue #24). `esp_recover` fires on
   `ESP_FAULT_LIMIT` consecutive faults, and the state that strands a user **raises none** — a new
   client never completes the module's handshake so the stub sees no bytes to time out, the leaked
   peers are silent by construction, and an unprompted send to a stale id takes
   `esp_wait_prompt`'s `ERROR` arm and returns quietly. The sweep was **structurally unreachable**
   from the one thing that could call it. `esp_idle_tick` reaches it from a quiet stub: idle this
   long with no DZRP session and nothing arriving, sweep once. **S4** the sweep fires with
   **no fault anywhere** — nobody connects at all, `AT+CIPCLOSE` appears and `AT+CIPSERVER=0` does
   not, which is what attributes it to the idle trigger rather than to a recovery, and a fresh
   client is served afterwards (the listener is never retired, unlike a recovery's sweep).
   **S5** it fires **once** per idle period, not every period for ever: exactly `LINK_IDS` closes
   over many periods, or the shipped ROM would open a refusal window every five minutes for as
   long as the machine was switched on. **S6** it does **not** fire while a DZRP session is open —
   a client at a breakpoint is silent and healthy, and #24 forbids closing on suspicion —
   **and its own control is in the same run**: the client disconnects and a sweep must follow,
   which is what shows the timer was live throughout rather than the run merely being short.
   **S7** the control, `IDLE_SWEEP=0`, the trigger assembled out. Measured: `during_session=0`
   against `after_disconnect=1`, and `closes=5 recoveries=0` for S4/S5 against `closes=0` for S7.
   **S6'S FIRST VERSION FAILED A STUB THAT WAS BEHAVING**, and the reason is worth keeping: it
   counted every `AT+CIPCLOSE` in the run and charged them all to the hold, but the stub is idle
   from the moment it comes up and headless jnext runs several emulated seconds per wall second,
   so with a ten-second probe period it had **already swept before the client connected** — the
   sweep at 18:31:38.96 against the client's first frame at 18:31:39.54. The baseline is now taken
   at the moment the session opens, through a sentinel the client writes. It failed in the
   direction that goes **red**, which is the only reason it was caught rather than believed.
   **What a green idle check does NOT establish**: that the sweep repaired anything. No emulator
   run can leak a slot or make the module unresponsive, so what is shown is that the **mechanism
   fires** from a quiet stub, which is what issue #24's acceptance criteria ask to be said out loud.
   **S8-S9 ARE THAT TRIGGER'S OWN SIDE EFFECT** (issue #40), and it is the sweep reaping a client
   rather than a leak. Only a parsed `+IPD` restarted `esp_idle_ticks`, and **a bare TCP connect
   never reaches one** — so a socket the module accepted while the stub was idle sat inside a period
   it had not started and was closed after whatever was left of it, down to nothing. The module's own
   `<id>,CONNECT` restarts the timer now, which buys such a socket a **whole** period; the cost,
   accepted, is that a genuinely leaked one holds its slot one period longer, which the module's
   `AT+CIPSTO` bounds regardless. **S8** a client connects, says nothing, and must still be there
   and still be served past the deadline the run's own previous period had set, with **no sweep in
   the log** in between; **S9** the control, `CONNECT_RESET=0`, where the same client is closed
   before it speaks. Measured: `at_speak=10` against a base of 10 for S8, `14` for S9, closed 0.69 s
   into a 1.2 s silence.
   **THE GRACE IS EXACTLY ONE PERIOD, SO THE CHECK HAS TO STAGE A LATE CONNECT** — a client that
   connects at the *start* of a period survives on either ROM, and a check that did not notice would
   be green against the defect. So each run measures its own period first (arm the timer with one
   `CMD_LOOPBACK`, time the sweep that follows), arms again, waits 0.65 of it, connects the silent
   client and lets it speak 0.60 of a period later. Three preconditions stop a mis-staged run
   reporting a verdict at all: a sane period, a connect inside a band around 0.65, and no sweep
   before the connect. **The check rests on the period holding WITHIN a run and not on any
   particular number** — which is why each run measures its own. The absolute figure is machine-
   and load-dependent: five consecutive periods in one run gave 1.737-1.797 s, and an independent
   reviewer on the same machine under different load measured 2.002-2.059 s. Both are ~3% within
   themselves, against margins of 28% or better, and `connect_at` lands at 0.674-0.677 either way.
   **IT DOES NOT BLOCK #19's RECOVERY, and that was checked rather than assumed**: jnext closes a
   connection refused at the ceiling **before** queueing its `CONNECT` line (`esp_at.cpp:959-993`),
   so in the state where every slot is leaked a client retrying in a loop emits none, the timer is
   not restarted, and the sweep still fires. That is jnext's source and not hardware.
   **NOT covered**: that a real client was ever bitten. DeZog sends `CMD_INIT` the moment it
   connects, so its own window is milliseconds against a shipped period of 300 seconds — #40 stages
   a reachable state, not an observed one, and says so itself.
4k. **`make test-mfinstall`** — the `.mfinstall` dot command (issue #21), **12 headless jnext runs,
   9 checks**, and the only bench here that drives a program from the **NextZXOS command line**
   rather than through a socket or a screenshot alone: every run boots NextZXOS, types the command
   and judges what happened. `.mfinstall` writes a ROM into Multiface **SRAM** through config mode,
   so **no ROM ever reaches the SD card** — which is what **I6** asserts, byte for byte, and
   without it every other check here is equally satisfied by a tool that simply wrote the file,
   which is mfselect's job and not this one's.
   **I2 is the strongest**: an M1 press straight after an install must bring up the stub's own
   screen with **no soft reset**, which is what says the bytes are LIVE. **I7 is the control that
   attributes the mechanism to one constant** — a probe built `DIVMMC_OFF=0`, with DivMMC left
   mapped as it is for any ordinary dot command, must report the write **blocked**; that is the
   seventh seam of the `IP_MAX` family and the reason "relocate above 0x4000" is known **not** to be
   the load-bearing half of the fix. **I8/I9** cover `--configure`, which writes the config file and
   installs nothing: I8 is the round trip through `--auto`, I9 requires what it writes to be
   byte-identical to the default the build ships — two separate sources, and a question no
   screenshot can answer.
   Not part of `make test`, for `test-mfselect`'s reason rather than the usual one: it binds no port
   and needs no external dependency, it is simply separate tooling. See `doc/MFINSTALL.md` and
   `doc/CONFIG-MODE-ROM-REPLACEMENT.md`. **Its subject has also run on a real Next**, which most of
   what is benched here has not: `--load`, `--auto` from `AUTOEXEC.BAS` and `--configure` have all
   been exercised there (mfselect has too — MEMORY.md 2026-08-04). What has not is `--unload`, and
   an interrupted config write.
4l. **`make test-cipsto`** — the module's own idle timeout (issue #24), 4 headless jnext runs,
   4 checks, and the **sixth** bench to move a build-time constant to reach its subject. `AT+CIPSTO`
   is the ESP's TCP-server idle timeout: a client silent for `<time>` seconds is hung up on **by the
   module**, with no involvement from the guest. The stub had never sent the command, so the
   firmware default governed — and it is **180 seconds**, measured on a real Next at 182.5 s and
   181.8 s, which is **a DeZog session parked at a breakpoint while its user reads code**. Confirmed
   with the real client at the machine: the views and the debug toolbar vanished, the stub was
   perfectly healthy with its border still cycling, and nothing on the Next said anything had
   happened. The stub now sends `AT+CIPSTO=1800` on every bring-up — the value is re-sent because
   the command does not persist to flash — and **reads the answer**, because a module too old for it
   answers `ERROR` and that is not a reason to refuse to debug. **SINCE `00.21` IT IS SENT AFTER
   `AT+CIPSERVER`, AND UNTIL THEN A REAL MODULE REFUSED IT EVERY TIME** — `AT+CIPSTO=` is rejected
   with no server running, and the lenient wait swallowed that by design, so the value was never in
   force on hardware from `00.14` to `00.20` (measured in `.UART`, 2026-08-11).
   **The shipped value cannot be watched to work**: half an hour per run. So `SERVER_TIMEOUT` moves
   it — **K1** at 10 drops the silent client at 10 s, **K2** is the *shipped* ROM over the same
   window and does not, and they differ in that one constant, which is what attributes the ten
   seconds to the value **this ROM sent**. **K3** is the refusal arm, reachable only because a
   value above 7200 is refused: the stub must still listen, serve DZRP and report no fault.
   **K4 is K3's controlled removal** and the second seam, `CIPSTO_STRICT=1`, which assembles that
   step with `esp_command_ok` — waiting for `OK` alone — after which the refusal abandons bring-up.
   **Its discriminator MOVED with the `00.21` fix, in the same change**: the step now follows
   `AT+CIPSERVER`, so the listener is up either way and `.no_bringup` does not retire it. K4 now
   asserts that `AT+CIFSR` — the step *after* — is never reached. Left alone it would have gone red
   against a correct fix, which is what `test-baud`'s L3 did when that default moved.
   **Every check asserts its precondition from jnext's own log**, because a ROM that never sent the
   command satisfies K2, K3 and K4 by accident — which is exactly what `main`'s ROM does, and all
   four go red against it. **What it CANNOT see is whether the stub read the answer at all**:
   measured, a fire-and-forget build passes 4 of 4, because every check observes the *module*. What
   reading the answer really buys is that the rest of the chain's scans keep matching their own
   replies, and no run here can show that.
   **It says nothing about a real ESP-01**: jnext models this command *from* the hardware
   measurement above (jnext#240, needs ≥ 0.99.141), so a green run shows the stub sends it, not that
   a module obeys. **That half HAS been run** — the ROM held a silent client for **400 s** on the
   user's own Next against the shipped ROM's ~182 s, `reported on hardware`. Binds a host TCP port,
   so not part of `make test`.
4m. **`make test-baud`** — the link negotiated up from 115200 (issue #25), 5 headless jnext runs,
   5 checks, and the **seventh** bench to move a build-time constant to reach its subject. The stub
   asks the module to move with `AT+UART_CUR=`, moves its own prescaler in step, verifies, and comes
   back down if the module refuses or the link does not survive. **SINCE 2026-08-09 `ESP_BAUD_HIGH`
   DEFAULTS TO 460800, SO THE SHIPPED WiFi ROM NEGOTIATES** — earned on the user's own Next against
   the six criteria written beside the constant, not on emulator evidence. It defaulted to
   `ESP_BAUDRATE` before that, and the reason it is 460800 and not higher is still the bench's own
   finding: **1000000 fails the conformance suite**. A `CMD_LOOPBACK` of 1 KB or
   more overflows the UART's 512-byte Rx FIFO. **The cost is the PER-BYTE RECEIVE PATH, not the
   send path** — `cmd_loopback` drains the whole payload into the swap bank before it sends anything
   (`commands.asm:959-1018`), and L5's own log shows the first dropped byte 2 ms after the `+IPD`
   header with **zero guest TX in the window**. **The limit is the Z80 and not the module**, which
   is why jnext, counting the same T-states a Next does, is entitled to this one: one byte time is
   prescaler x 10 T-states at 28 MHz, and the sweep brackets the per-byte cost **above 470 and at
   most 610** — clean at 230400 and 460800, overflowing at 600000, 750000, 921600 and 1000000.
   460800 also passes 15 of 15 with W1-W6. **It is not an echo problem**: any large *inbound*
   payload is affected, and `CMD_WRITE_BANK` pushes 8-16 KB per bank on every DeZog `.nex` load, so
   whoever raises this ceiling must optimise the receive path. **L1** the negotiation at 460800,
   **L2** a refused rate where the stub must NOT move alone, **L3** a `BAUD_HIGH=115200` build
   sending no `AT+UART` at all — it was the *shipped* ROM until the default moved, and L1's
   attribution needs that control whichever ROM provides it, **L4** `esp_recover`'s `jp transport_init` re-running the whole chain, and
   **L5 the ceiling — a check that PASSES when C5 fails**, W3's shape, kept so that whoever raises
   the default has to make it go green by changing the thing it measures.
   **THE DISCRIMINATING ASSERTIONS ARE ON jnext's UART LOG, NOT ON BEHAVIOUR**, and that is forced:
   jnext's AT engine stores the baud it is asked for and never reads it again, so a stub that told
   the module and forgot its own side is byte-for-byte indistinguishable from a correct switch. The
   log records every prescaler the guest programs — including the transient **mixture** the two
   7-bit half-writes pass through, which L1 asserts. Shown: with the refusal guard removed the stub
   programmed divisor 5 after an `ERROR` and **still served DZRP perfectly**. **What no run here
   reaches**: the rate itself, the half-switched link (structurally unreachable), and the bring-up
   probe — jnext's module answers the first greeting every time, so that branch is dead code here.
   Binds a host TCP port, so not part of `make test`. **This bench says nothing about a real
   ESP-01** — but the rate it defaults to no longer rests on it: 460800 was measured on hardware
   (five `make test-hardware` runs at 15/15, and the bring-up probe shown to fire), and the probe
   this bench calls dead code **has now executed there**. See `doc/HARDWARE-TESTING.md`.
4n. **`make test-wifi-assoc`** — the Next losing and regaining its WiFi association (issue #32),
   7 headless jnext runs, 8 checks, and the **ninth** build seam — one of the few whose *shipped*
   value needs no moving to be watchable, since 60 seconds is 3000 frames (`ESP_LINK_IDS` is
   another: its shipped 5 is exactly what S1/S2 measure).
   `AT+CIFSR` was asked exactly **once**, at the end of `transport_init`, so `Connect at
   <ip>:11000` was decided at bring-up and never revisited: a Next that dropped off the WiFi went
   on naming an address that no longer reached it, and one switched on before its router was ready
   went on telling its owner to run `wifi2.bas` on a machine that was already correct. Both needed
   an M1 press, and from the PC side both look exactly like #15, #18 and #19.
   **IT WAS BLOCKED RATHER THAN UNTESTED**: jnext's module used to be permanently associated
   (`AT+CWJAP?` query-only, no `AT+CWQAP`, `STA_IP` a `static constexpr`), which is ERRORS.md's
   "a bound the emulator can never reach is a bound with no test" one layer out. **jnext#246**
   (0.99.148) gave the outage and **jnext#247** (0.99.151) gave the address the right to come back
   **different** — and the second is load-bearing rather than convenient: with #246 alone the only
   stageable sequence is `A → 0.0.0.0 → A`, on the far side of which the stub's cached `A` is
   *correct*, so **every wrong answer agrees with the right one** — mfselect's M9 again.
   Every verdict is the stub's own connect block, **screen rows 6 and 7, read back as text**
   (`test/screen-text.py`), with the reader validated inside each image on row 12 first.
   **D1** the address **moves** across the outage and the screen must name the new one — the
   discriminating check, and the one #247 exists for; **D2** its control, `ADDR_CHECK=0`, which
   must keep the stale address; **D3** the address goes and stays gone, so the screen must change
   to the *"no address"* block rather than merely to a different number — a different branch and a
   different string; **D4** that control; **D5** it goes and comes back **unchanged**, the case a
   real Next produced; **D6** the stub still answers `CMD_INIT` afterwards; **D7** with **no `--esp` at all** the
   *"ESP-01 setup failed"* screen must **not** be downgraded to *"No WiFi address"*; **D8** the
   timed repaint gives **MMU slot 1** back to the client.
   **D7 GUARDS THIS FIX AGAINST RECREATING THE DEFECT IT REMOVES.** `esp_query_address` writes
   `ESP_LINK_NO_ADDRESS` on **entry** and clears it only on success, so an unguarded re-query
   overwrites `ESP_LINK_FAILED` at the first tick — and **permanently**, since only
   `transport_init` sets it again and `esp_recover` cannot fire in that state — not because nothing
   there reaches `rxtx_error` (`esp_send_raw` does, via `tx_timeout`), but because neither path can
   **fire**: the TX FIFO always drains with flow control off (`uart_tx.vhd:180`), and nothing
   arrives to overflow the RX FIFO when no module is answering. **Measured at frame 40000**, not
   deduced. A machine whose ESP
   is absent, disabled or not answering at 115200 would stop saying so after a minute and start
   telling a correctly set-up user to run `wifi2.bas`. Those two screens are `doc/WIFI-SETUP.md`'s
   user diagnostic. Measured one build apart with the base pinned by hash: `main` keeps *"setup
   failed"* at frames 3000, 9000 and 40000; the unguarded build says *"No WiFi address"* from 9000
   on. It is the cheapest run here — no `--esp`, so no listener, so not through `start_run` — and
   **no other check can see it**, since every other run has a module.
   **D8 is N7's class one painter along**: since #31 the glyphs come from ROM, so `text.font_map`
   pages ROM into **slot 1, which has no backup anywhere**, and this is a new *autonomous* painter
   that maps it on a **timer**. Stageable only because `CMD_SET_SLOT` does **not** set
   `esp_session_valid` — so the slot can be armed with the session gate left clear — and judged
   over the socket, since `cmd_get_registers` reads slots 0-6 live from the MMU.
   **D5 CANNOT DISCRIMINATE ON ITS OWN AND THAT IS MEASURED, NOT ARGUED**: against the pre-fix ROM
   this bench reports D1 and D3 red and **D5 green**, because the address a stub cached at bring-up
   is the address the module ends up back on. What gives D5 a subject is D3 — the two runs are
   identical up to `$UP_FRAMES`, which is where D3's screenshot is taken.
   **D6 IS THE PROPERTY A "FIX" COULD EASILY BREAK.** Hardware says the happy path is that *nothing*
   breaks: a real Next survived a five-minute AP outage with its `AT+CIPSERVER` listener intact and
   passed a full 6/6 hardware bench afterwards with no M1 press and no reset (jnext#246, `reported
   on hardware`). The emulated module agrees — probed before any Z80 was written, a new TCP
   connection was accepted and an already-open DZRP session answered `CMD_LOOPBACK` across **both**
   edges. So re-acquisition is **not needed**, and a fix that retired the listener and rebuilt it
   would be a regression D6 catches. Timing is in **frames** and never wall clock; D6's client waits
   on the screenshot *file*, so it cannot perturb D1's verdict by arriving early with a `CMD_INIT`
   that would stop the stub's idle clock.
   Not part of `make test`: D6 binds a host TCP port. **IT SAYS NOTHING ABOUT REAL HARDWARE, and
   rather less than most benches here** — every association fact in it is **modelled by the
   emulator**, told what to do by the bench's own command line, and jnext#247 records that an
   address **changing** across an outage has **never been observed on an ESP-01 at all**: it is
   inferred from how DHCP works. What a green run shows is that the stub *notices* a change the
   emulator was told to make. **Also not covered**: the unsolicited `WIFI DISCONNECT` /
   `WIFI CONNECTED` / `WIFI GOT IP` lines (jnext models none, so the stub polls rather than
   watching); whether a *real* module's listener survives (measured once, one machine, no
   re-runnable artefact); how long a real re-association takes, which is what would decide whether
   60 seconds is the right period; and the outage arriving **while a DZRP session is open**, which
   the stub deliberately does not re-query through. See `test/run-wifi-assoc.sh`.
5. **`build/ut.nex`** — the same tests, **DeZog-driven** (`"unitTests": true` + zsim + the
   `customCode` plugin) in VS Code. Still a manual layer, and still the only way to exercise the
   38 that 4d must skip. `make unit-tests` assembles it; nothing here runs it.
6. **Real hardware** — the only truth for ESP timing, WiFi behaviour and anything the emulator
   models rather than is. `make test-hardware NEXT_IP=<ip>` is the bench (H1-H7), and **H7 is
   milestone M2's acceptance criterion on silicon**: it delegates to `pause-running.py`, which is
   W8, and runs the control first. Two things sit beside it and are not in it —
   `make test-pause-transparency` runs a debuggee free under the poll for minutes rather than W8's
   one second, with a fixture that watches MMU slot 7 **and** the NextREG select latch (the half
   T9's fixture is measured to be unable to see) and was shown red one instruction apart on each;
   and `make pause-transparency` builds the `.nex` + `.sld` for **DeZog's own Pause button**, which
   **has now driven it on a real Next** (2026-08-11): Pause, `Manual break`, Continue, Pause again,
   clean close. That was the last path in M2 nothing had exercised. Procedure in `doc/HARDWARE-TESTING.md` steps 4a and 4b.

**A verdict line is one short sentence; the reasoning lives here and in the script's own header.**
Every `PASS`/`FAIL` line a bench prints is **at most twenty words** (user, 2026-08-05), across all
nine `test/run-*.sh` benches and the two Python ones. That is a rule about *output*, not about
evidence: the substance did not go anywhere, it moved into the block comment above each assertion,
into these §Testing entries, and into `doc/DZRP-TESTING.md`, `doc/HARDWARE-TESTING.md`,
`doc/MFSELECT.md` and `doc/UNIT-TESTS.md`. A caveat that scrolls past at the end of every run is
read once; a document can be revised, cited and diffed.

Two things the shortening may **never** touch, because they are interface rather than prose:

- **The check id.** Every verdict a bench prints carries one, and two things **match** on them:
  `run-dzrp-stub.sh`'s W3 greps `^FAIL  C10 `, and `test/hardware-check.py` takes the code from
  field 2 of every `FAIL` line. Shorten the prose after the id; never the id, and never renumber —
  the reason is below and is stronger than convention.

  **THE REGISTER IS id → THE FILE THAT PRINTS THE LINE**, and that is not always the `run-*.sh`
  that drives it: **seven of the twenty-two ranges are printed by a Python file**, which is exactly
  where a target-shaped search looks and finds nothing. Enumerated mechanically from `test/`,
  2026-08-10.

  | ids | printed by | run it with |
  |---|---|---|
  | `T1`-`T9` | `test/run-headless.sh` | `make test` |
  | `M1`-`M10` | `test/run-mfselect.sh` | `make test-mfselect` |
  | `E1`-`E4` | `test/esp-echo-client.py` | `make test-esp` |
  | `U1`-`U5` | `test/run-unit-tests.sh` | `make test-unit` |
  | `W1`-`W8` | `test/run-dzrp-stub.sh` | `make test-dzrp-stub` |
  | `C1`-`C25` | `test/dzrp/conformance.py` | `test-dzrp-stub`, `test-dzrp`, `test-hardware` |
  | `B1`-`B2` | `test/run-ip-boundary.sh` | `make test-ip-boundary` |
  | `P1`-`P3` | `test/run-tx-patience.sh` | `make test-tx-patience` |
  | `N1`-`N8` | `test/run-client-status.sh` | `make test-client-status` |
  | `N1`-`N4` | `test/run-no-hang.sh` | `make test-no-hang` |
  | `G1`-`G2` | `test/run-screen-agreement.sh` | `make test-screen-agreement` |
  | `P1`-`P3` | `test/screen-agreement.py` | the same target |
  | `I1`-`I9` | `test/run-mfinstall.sh` | `make test-mfinstall` |
  | `S1`-`S9` | `test/run-slot-recovery.sh` | `make test-slot-recovery` |
  | `K1`-`K4` | `test/run-cipsto.sh` | `make test-cipsto` |
  | `L1`-`L5` | `test/run-baud.sh` | `make test-baud` |
  | `D1`-`D8` | `test/run-wifi-assoc.sh` | `make test-wifi-assoc` |
  | `H1`-`H7` | `test/hardware-check.py` | `make test-hardware` |
  | `A0`-`A6` | `test/slot-ceiling-probe.py` | `make probe-slots` |
  | `B0`-`B5` | `test/vanished-peer-probe.py` | `make probe-vanished` |
  | `R0`-`R5` | `test/idle-drop-probe.py` | `make probe-idle-drop` |
  | `V1`-`V2` | `test/run-probes-jnext.sh` | `make probe-jnext` |

  Two printed forms the ranges flatten, because a grep for a bare id meets them: **`E4` prints as
  `E4a` and `E4b`**, two rows for one check; and **`screen-agreement.py`'s `P1`-`P3` are never
  printed bare** — they carry the run's `G1`/`G2` label as a prefix (`--label`), so the line reads
  `PASS  G1 P1 …` and field 2 there is the G.

  **THREE IDS MEAN TWO DIFFERENT THINGS EACH, and that is now DECIDED rather than open** (user,
  2026-08-10): **documentation only.** They are recorded here; nothing is renamed and no printed
  line changes.

  | one side | the other | how bad |
  |---|---|---|
  | `N1`-`N4`, `run-no-hang.sh` — **gate** | `N1`-`N8`, `run-client-status.sh` — **gate** | worst |
  | `P1`-`P3`, `run-tx-patience.sh` — **gate** | `P1`-`P3`, `screen-agreement.py` — **gate**, G-prefixed | full overlap |
  | `B1`-`B2`, `run-ip-boundary.sh` — **gate** | `B0`-`B5`, `vanished-peer-probe.py` — **instrument** | mildest |

  `N` is worst because both sides are PASS/FAIL gates over the same four numbers with nothing in
  the printed line to separate them. `B` is mildest because a probe renders no verdict at all —
  `MEAS`/`NOTE` rows only, and it prints *"There is no PASS here"* every run — so a `PASS B1` can
  only be the gate. **`P` is the one that has ALREADY caused the confusion this register exists to
  prevent**: `screen-agreement.py`'s own docstring has to write *"the injected TX budget that
  **P2 of the tx-patience bench** uses"* to disambiguate its own neighbour's id.

  **WHY THEY COST NOTHING TODAY, and it is a property of the two consumers rather than of the
  ids.** Both read **`conformance.py`'s output and nothing else** — W3 greps the C10 control run
  (`run-dzrp-stub.sh:544`), and `classify()` has exactly one caller, fed by the one
  `subprocess.Popen` that runs `conformance.py` (`hardware-check.py:444`, `:462`) — so neither
  ever sees an `N`, `B` or `P` id at all. **The residual risk is HUMAN**: somebody writing "N2 is
  green" in an issue or a commit message and meaning the other bench. Nothing here catches that.

  **RENAMING WAS CONSIDERED AND REJECTED, which is why the collisions are documented rather than
  fixed, and it is also the reason for "never renumber".** The ids are cited by number throughout
  `MEMORY.md`, `doc/` and closed issues, and much of `MEMORY.md` is **deliberately frozen** —
  those entries record what was measured on the day, and this project's standing rule is that
  evidence is annotated rather than edited to match a later rendering. A renumbering would
  therefore either strand every citation or require editing records that must not be edited.

  **AND THE LESSON THIS LIST KEEPS PRODUCING ABOUT ITSELF.** It has gone stale **four times in
  three review rounds** — `N1`-`N6`, `S1`-`S3`, `H1`-`H5`, and `S1`-`S7` again, which issue #40's
  S8/S9 falsified on 2026-08-10 without the line moving with them — which is *the enumeration is
  a grep, not a memory* turned on the register itself: **check it against what the benches print,
  not against what this table says.**
- **A clause a reviewer put there to stop the line overclaiming.** Some of these lines are long
  precisely because an earlier version said more than the run had shown. Where the clause still
  fits it stays on the line — `test-no-hang`'s N4 says the *mechanism* fired and calls it "not a
  repair"; `test-client-status`'s reader failure says the session line was **not judged**, so a
  broken reader is not reported as a wrong screen. Where it does not fit it moves into the comment
  above the assertion and is not deleted — W2-W5's contamination lines no longer spell out that a
  contaminated run is worthless *in either direction* (it can come out **green**), and that,
  with the `pgrep -x jnext` recovery, is now three lines above them in `run-dzrp-stub.sh`. If a
  clause cannot survive either move, keep the long line and say so out loud.
  **W5's guard is TWO-SIDED since 2026-08-11 and the "it comes out green" rule is only half of it
  there**: a *deficit* of connections means the fixture reached somebody else's listener, so its
  frames are in that run's log and not in ours — and the precondition arm then reports *"the
  precondition never happened"*, which is **red with a plausible wrong reason**, the worse of the
  two outcomes. Four is exact for that run, not a margin, and a genuine issue-#13 red still makes
  four; the reasoning is at the assertion. **W5 also keeps its jnext log on EVERY failing arm**,
  timestamped, because it is the one check here that fails intermittently and both 2026-08-10
  failures were overwritten before anyone read them. *("Every" is load-bearing and was earned in
  review: the first version skipped the "the stub never listened" arm, which made this sentence a
  guarantee the code did not deliver — in the change whose whole subject is unreadable evidence.)*
  **AND ITS COMMONEST RED NOW NAMES ITSELF, from a mechanism OBSERVED rather than inferred**
  (2026-08-11): the trio comes out **15/6/1** instead of 6/15/1 — jnext's `frame_ipd()` emits one
  chunk per quiet moment and scans connections **in cid order**, and the fixture opens B first, so
  when A's header and B's whole command are both buffered at one quiet moment B is framed ahead of
  A's header and there is no split left to see. It needs the wire busy for longer than the
  fixture's **8 ms** gap — which is the budget, **not** the 100 ms RX timeout — so the check
  measures and prints the latency since the stub last went quiet. First capture: **10 ms**. That is
  a bench timing outcome and still FAILS, because nothing was tested; **do not raise
  `DZRP_SPLIT_GAP` to make it green**, which is tuning a race until it passes.
  **What IS legitimate is retrying the STAGING, and W5 does — the whole emulator run, up to
  `W5_TRIES` (3)**, re-attempting the setup while leaving the assertion untouched. **The unit of
  retry is the RUN and not the fixture, from ONE observation rather than a controlled comparison**:
  a run that collapsed did so on all three *in-run* fixture attempts at 11 ms each, seconds apart,
  while the next emulator run staged first time. Read as: the stub's flush timing is near constant
  within a run and varies between them — n=1, and **nothing rests on it being right**, since a
  transient collapse would make retrying the run merely slower than necessary rather than wrong.
  `W5_TRIES=1` is the control that restores the single-attempt behaviour.

**M2 IS BUILT (2026-08-10) AND IT DID NOT INVERT T4.** The paragraphs below were written before
any M2 code existed and predicted that teaching `nmi66h` to accept a software cause would make T4
assert a takeover. It does not, and the prediction rested on an assumption about the shape of the
fix rather than on anything measured: the poll path accepts the cause and then **declines** unless
our image is in `MAIN_BANK` *and* a debuggee is running. In T4's run no debugger has ever been
started, so the magic check fails, the screen is untouched, and T4's verdict is unchanged — what
changed is its reason, which is now "the software cause is SERVED and correctly declines". T8's
expectations were likewise re-examined and are unchanged: the branch M2 edits first is the *cause*
check, not the slot-7 discriminator T8 asserts. Where the software cause being served is asserted
is **T9**. The original text follows, annotated rather than deleted.

**Why T4 expects a decline, and what M2 has to change.** `mf_rom.asm`'s `nmi66h` reads NR `0x02`
on entry, masks `00011100b` and returns immediately unless the result is zero — it serves *button*
NMIs only. NR `0x02` bit 3 reads back as `nr_02_generate_mf_nmi`, which `zxnext.vhd:3843-3848`
latches on any accepted NR `0x02` bit-3 write and clears only on an explicit write of bit 3 = 0.
So a software NMI is filtered by design, and the bench asserts that.

**jnext's `--delayed-nmi` shipped in 0.99.118, and the bench uses it — as T6, not as a
replacement for T4.** A *button* NMI is a cause `nmi66h` accepts, so T6 asserts the takeover and
gets 90.28%. An earlier version of this section said T4 "should become" that assertion; that was
wrong, and the two are not alternatives. They send **different causes** to the same cause check:
T6 one it accepts, T4 one it rejects. Keeping both is what leaves M2 a regression check it has to
re-examine deliberately, instead of one that vanished the day the button check arrived.
**M2 re-examined it and did NOT invert it** (2026-08-11): the poll accepts the software cause and
then declines unless our image is in `MAIN_BANK` *and* a debuggee is running, which in T4's run it
is not — so T4's verdict is unchanged and only its reason moved. **T9** is where the software cause
being SERVED is asserted.

**This is a live constraint on M2, not a testing detail.** The plan's asynchronous break is a
Copper `MOVE $02,$08`, which sets the same latch through the same signal (`nmi_gen_nr_mf` covers
CPU and Copper alike, `zxnext.vhd:3832`). It will be filtered by that same check until `nmi66h`
is taught to accept a software cause — ~~and then T4's assertion must be inverted, deliberately and
in the same change~~. **It was not, and did not need to be** (2026-08-11); see the paragraph above. **T8's expectations belong in that same change too**: it asserts that a
*button* press taken while the debugger executes is declined, which is the branch M2 edits first
and reuses `MF.nmi_slot7` from, so whatever M2 makes that branch do, T8 is where it is written
down.

The bench never writes the reference SD image; it reflink-copies it into `build/`.

Two known jnext gaps this project will hit, both deliberate absences with no consumer until now:
`AT+CIPSERVER` (with `AT+CIPMUX=1`, which jnext currently **refuses** with `ERROR`) and
`AT+CIPMODE` passthrough. The server-mode triad is filed as
[jnext#210](https://github.com/jorgegv/jnext/issues/210) (v1.0); `AT+CIPMODE` deliberately is
not, because server mode forbids passthrough. File anything further as jnext issues **with this
project as the demonstrated consumer** — never speculatively. See the plan §8.2.

## Constraints for development

- Do not include Co-Authored-by headers in commit messages
- Keep commit messages terse but insightful
- **Agents must NOT write to the `main` branch, ever.** Only on their own branches and worktrees.
  A `PreToolUse` hook enforces this; the override is `DEZOGIF_ALLOW_MAIN_WRITE=1`. This is
  unchanged for **spawned agents**: they never touch `main`, whatever they think they have been
  told.
- **Merging to `main` is standing-authorized for the manager session** (user, 2026-08-04), and
  only when all four hold: the issue or task is **finished**; the branch is **ready**; it has been
  **independently reviewed** with an APPROVE; and it has been **validated** at the highest testing
  layer that applies (§Testing). Short of all four, ask. This authorizes the *merge* — it is not a
  licence to edit `main` directly, which step 1 below still forbids.
- **It does NOT authorize pushing.** See the next rule; the two were granted separately and remain
  separate.
- **NEVER push to origin without explicit user authorization.** This applies to the manager AND
  every spawned agent. `git push`, `git push -u`, `git push --force` and `gh pr create` are all
  forbidden unless the user explicitly says "push" or "open a PR". Enforced by a hook; the
  override is `DEZOGIF_ALLOW_PUSH=1`.
- **Never `git commit --amend`** — always a new commit. Enforced by a hook
  (`DEZOGIF_ALLOW_AMEND=1` to override).
- **Git worktrees live OUTSIDE the repository directory**, at
  `~/tmp/worktrees/dezogif_ng/<name>`. Never inside the repo, not even gitignored.
- **Scratchpads and temporary files NEVER go under `/tmp`** — put them in
  `$HOME/tmp/scratchpads/`. On this machine `/tmp` is a **tmpfs**, so everything written
  there consumes **RAM**, and the harness's own default scratchpad path points into it.
  Use `$HOME/tmp/scratchpads/` regardless of what that default says. This is not
  housekeeping: on 2026-08-04 ~22 GB of leaked 1 GB SD-card images under `/tmp` exhausted the
  quota and took the shell down mid-session, with every command — `true` included — returning
  exit code 1. See ERRORS.md. Anything gigabyte-scale (SD images, emulator captures) must live
  on `/home`, which is real disk.
- For git commands against another directory, always `git -C /abs/path <cmd>` rather than
  `cd /abs/path && git <cmd>`.
- **When a feature or fix is developed, ALWAYS schedule an independent agent for code review.**
  The review must NEVER be done by the agent that wrote the code. Verdict is **binary
  APPROVE / REJECT** — "approve with nits" is not a verdict.
- When launching agent teams, the manager agent does NOT write code.
- Each independent piece of work gets its own branch, to avoid agents trashing each other.
- When the user asks to prepare for a session handover, save memories immediately.

## Merging a completed change to `main`

1. Dedicated branch + worktree off current `main` — never edit `main` directly.
2. Builds clean, unit tests pass, and the change is exercised at the highest layer that applies
   (§Testing).
3. Independent code review by an agent that did not write the change, in its own worktree.
4. Merge on APPROVE, one branch at a time. The manager does the merge, not the author. No further
   permission is needed once steps 1-3 genuinely hold — see the standing authorization above.
   `git merge --ff-only` is the house form: a conflict means rebase or resolve deliberately,
   rather than silently minting a merge commit. (This used to be justified by "`main`'s history
   is linear", which was never true — `857a1df` is a merge commit. The rule stands on its own.)
   **Then `make bump` and commit `version.yaml` — but only if the merge changed a ROM.** Check
   mechanically rather than by judgement, before the merge:

   ```sh
   git diff --name-only main..<branch> -- src/ Makefile   # empty => no bump
   ```

   Anything listed there can reach a ROM, so bump. Nothing listed means no ROM byte moved and a
   bump would mint a **new identity for an unchanged ROM** — asserting a difference that does not
   exist, which is the opposite of what the number is for. When two variants exist (#5), the rule
   is *any* of them: they build from the same sources, so the same check covers both.

   The check is deliberately conservative. A touched `Makefile` may well leave the ROM identical;
   bumping anyway costs nothing, whereas *not* bumping when a ROM did change is the failure that
   matters — it leaves two different ROMs claiming to be the same build. If you want certainty
   rather than a conservative answer, build both sides with `BUILD_TIME` **and** `BUILD_NUMBER`
   pinned and compare the bytes.

   One bump per merge, not per commit: the number answers "which build is on my card", and a user
   only ever has a merged one.
5. Never push to origin — local commits and merges stay local until the user says otherwise.
   **Merging and pushing are separate permissions**: a merged `main` sits local until the user asks
   for a push, every time.

## ChangeLog

`CHANGELOG.md` is inherited from upstream. Keep our entries clearly separated from upstream's
history, terse, one line per change, and only for changes a *user of the stub* would notice.
Update it only when the user asks.
