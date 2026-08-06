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

**M1 is built; M2 is not.** The tree builds **two** ROMs — `make` gives the serial one, byte for
byte upstream's behaviour, and `make TRANSPORT=wifi` gives one that brings the ESP-01 up as a TCP
server and speaks DZRP through it (`src/transport_esp.asm`). A DZRP client talks to the WiFi build
under jnext and gets correct answers: `make test-dzrp-stub`. The two ROMs now also **draw different
screens**: WiFi mode reports the ESP's own baud rate and the address to connect to
(`AT+CIFSR` → `Connect at <ip>:11000`) where UART mode keeps upstream's cable baud rate and
joy-port selector. What is **not** built yet is M2's asynchronous break.

**It has now run on a real ZX Spectrum Next**, 2026-08-04 — the stub takes the M1 NMI and paints
its UI on core 03.02.01, and mfselect installed it. That single evening found **two bugs no
emulator here could ever have found**, both because jnext's values sit on the safe side of ours:
a connection id of 0 (jnext numbers from 1, real ESP-AT from 0) that made the stub discard every
reply, and a 15-character IP address (jnext's is 12) that the connect-string parser refused. See
MEMORY.md and ERRORS.md.

**What has NOT run on hardware is a DZRP session.** The listener comes up and answers a TCP
connect; no client has yet completed the conformance suite against a Next, and nothing has resumed
a debuggee there. Do not read "it runs on hardware" as more than the entry path.

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
- Upstream design: `doc/legacy/Design.md` — memory choreography, AltROM, breakpoints. Written
  for the serial variant; everything except the transport still applies.
- **`doc/legacy/` is upstream's documentation, frozen — `doc/` is ours.** Don't edit `doc/legacy/`
  to reflect our changes; record those in `doc/` or in the code.
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
```

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
3. **`make test`** — six headless jnext runs, judged on screenshots (`test/run-headless.sh`):
   - T1 the bench boots a Next at all
   - T2 our `enNextMf.rom` does not perturb the NextZXOS boot
   - T3 **control** — the software-NMI fixture really fires the Multiface NMI, shown against the
     SD image's stock MF ROM. If T3 fails the bench is broken and T4 means nothing.
   - T4 our stub **declines** that NMI and leaves the screen alone — see below
   - T5 a two-instruction **Copper** list raises the Multiface NMI on its own, at a chosen
     raster line, with no CPU involvement. That is M2's break mechanism, and it is now known
     to work headless rather than assumed to. Shown against the stock MF ROM for T3's reason:
     our stub declines it, and would decline it whether or not the Copper worked.
   - T6 our stub **takes over on a real M1 button NMI** and paints its own screen (~90%
     repainted, against the stock monitor's 91%). **The only check here that proves the stub is
     alive** rather than proving it correctly ignores something. It exercises Multiface paging,
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
   Screen comparison is a **percentage of differing pixels** (`test/screen-diff.py`), not a byte
   compare: NextZXOS idling changes 0.01% of the screen and that once produced a false PASS.
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
   jnext run of `build/ut-headless.nex`, 5 checks. **28 of the 64 test cases run; 36 cannot and
   are reported as `UT-SKIP` on every run.** Those 36 need ports invented by `src/simulation/uart.js`,
   a JavaScript peripheral DeZog's zsim loads as `customCode` — the Z80 cannot trap its own I/O,
   so they are unreachable from inside the guest, and a project-specific peripheral does not
   belong in jnext. **Do not read a green run as "the unit tests pass"**; read it as
   "the 28 that can run, pass". What they cover is the banking and breakpoint code — all of
   `ut_backup.asm`, all of `ut_breakpoints.asm`, all of `ut_utilities.asm` — not the DZRP command
   layer, whose gate is `test-dzrp-stub`. The count is pinned in **two** places (the Makefile,
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
4g. **`make test-client-status`** — WiFi mode's session line (issue #14), 3 headless jnext runs,
   and the **only bench here that reads the screen back as TEXT** rather than comparing it with
   another picture. **N1** a client connects over TCP and says nothing: the line must still read
   `No debug session yet.`, because the line reports a DZRP session and a socket is not one — that
   is the honesty check, not a baseline. **N2** after `CMD_INIT` it reads `Session opened
   (CMD_INIT).`; **N3** after `CMD_CLOSE` it reads `Session closed (CMD_CLOSE).`, with the client
   sending one further command first, because `cmd_close` answers *before* it reaches `show_ui` and
   so its response proves nothing about the screen.
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
   **Scope**: it covers what `CMD_INIT`/`CMD_CLOSE` prove and nothing else. A client that vanishes
   without `CMD_CLOSE` leaves the line at "opened" — that needs `<id>,CONNECT`/`<id>,CLOSED`
   tracking, which is M3. **UART mode draws no such line at all**, deliberately: over a cable there
   is no connection event to observe, so there is nothing here to test. **It says nothing about
   hardware.**
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
5. **`build/ut.nex`** — the same tests, **DeZog-driven** (`"unitTests": true` + zsim + the
   `customCode` plugin) in VS Code. Still a manual layer, and still the only way to exercise the
   36 that 4d must skip. `make unit-tests` assembles it; nothing here runs it.
6. **Real hardware** — the only truth for ESP timing, WiFi behaviour and anything the emulator
   models rather than is.

**A verdict line is one short sentence; the reasoning lives here and in the script's own header.**
Every `PASS`/`FAIL` line a bench prints is **at most twenty words** (user, 2026-08-05), across all
nine `test/run-*.sh` benches and the two Python ones. That is a rule about *output*, not about
evidence: the substance did not go anywhere, it moved into the block comment above each assertion,
into these §Testing entries, and into `doc/DZRP-TESTING.md`, `doc/HARDWARE-TESTING.md`,
`doc/MFSELECT.md` and `doc/UNIT-TESTS.md`. A caveat that scrolls past at the end of every run is
read once; a document can be revised, cited and diffed.

Two things the shortening may **never** touch, because they are interface rather than prose:

- **The check id.** `T1`-`T6`, `M1`-`M10`, `E1`-`E4`, `U1`-`U5`, `W1`-`W5`, `C1`-`C15`, `B1`-`B2`,
  `P1`-`P3`, `N1`-`N4`, `H1`-`H5` are cited by every document and issue, and two things match on
  them: `run-dzrp-stub.sh`'s W3 greps `^FAIL  C10 `, and `test/hardware-check.py` takes the code
  from field 2 of every `FAIL` line. Shorten the prose after the id; never the id, and never
  renumber.
- **A clause a reviewer put there to stop the line overclaiming.** Some of these lines are long
  precisely because an earlier version said more than the run had shown. Where the clause still
  fits it stays on the line — `test-no-hang`'s N4 says the *mechanism* fired and calls it "not a
  repair"; `test-client-status`'s reader failure says the session line was **not judged**, so a
  broken reader is not reported as a wrong screen. Where it does not fit it moves into the comment
  above the assertion and is not deleted — W2-W5's contamination lines no longer spell out that a
  contaminated run is worthless *in either direction* (it can come out **green**), and that,
  with the `pgrep -x jnext` recovery, is now three lines above them in `run-dzrp-stub.sh`. If a
  clause cannot survive either move, keep the long line and say so out loud.

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
invert deliberately, instead of one that vanished the day the button check arrived.

**This is a live constraint on M2, not a testing detail.** The plan's asynchronous break is a
Copper `MOVE $02,$08`, which sets the same latch through the same signal (`nmi_gen_nr_mf` covers
CPU and Copper alike, `zxnext.vhd:3832`). It will be filtered by that same check until `nmi66h`
is taught to accept a software cause — and then T4's assertion must be inverted, deliberately and
in the same change.

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
