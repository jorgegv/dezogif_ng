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

**None of that exists yet.** Today the tree builds exactly one ROM, behaviourally upstream's
serial stub; there is no ESP code and no mode switch. What this fork has actually added so far is
the build system, the headless test bench and the documentation.

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
- **DeZog's division of labour is a contract.** Instruction-length calculation, storage of the
  original opcode under a breakpoint, the temporary breakpoints used to step off a breakpoint, and
  breakpoint-condition evaluation all live in **DeZog**. Do not move any of them into the stub —
  the client already does them and will fight you.
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

The assembler is **sjasmplus** (1.23.1, at `~/src/spectrum/sjasmplus/`). It reaches `PATH` via
`~/bin/direnv-spectrum.sh`; the Makefile falls back to the absolute path, so a build works
without direnv loaded. Override with `make SJASMPLUS=/path/to/sjasmplus`.

`BUILD_TIME` is stamped into the ROM. Pin it (`make BUILD_TIME=1700000000`) to compare two builds
byte for byte — `make check-reproducible` does exactly that.

## Testing

CI for this project is **local, headless and jnext-driven**. No hosted CI (a hardware target can
never have one) and no VS Code in the loop. `make test` is the gate. The layers, weakest to
strongest:

1. **It assembles** — necessary, proves nothing. Enforced by the in-source `ASSERT`s
   (`main_end` within budget) plus the Makefile's 8192-byte ROM size check.
2. **`make check-reproducible`** — the same source gives the same ROM.
3. **`make test`** — four headless jnext runs, judged on screenshots (`test/run-headless.sh`):
   - T1 the bench boots a Next at all
   - T2 our `enNextMf.rom` does not perturb the NextZXOS boot
   - T3 **control** — the software-NMI fixture really fires the Multiface NMI, shown against the
     SD image's stock MF ROM. If T3 fails the bench is broken and T4 means nothing.
   - T4 our stub **declines** that NMI and leaves the screen alone — see below
   Screen comparison is a **percentage of differing pixels** (`test/screen-diff.py`), not a byte
   compare: NextZXOS idling changes 0.01% of the screen and that once produced a false PASS.
4. **`build/ut.nex`** — the upstream Z80 unit tests under `src/unit_tests/`. These are
   **DeZog-driven** (`"unitTests": true` + zsim) and therefore need VS Code; they are a manual
   layer and gate nothing. Making them headless would need a driver we do not have.
5. **Real hardware** — the only truth for ESP timing, WiFi behaviour and anything the emulator
   models rather than is.

**Why T4 expects a decline, and what M2 has to change.** `mf_rom.asm`'s `nmi66h` reads NR `0x02`
on entry, masks `00011100b` and returns immediately unless the result is zero — it serves *button*
NMIs only. NR `0x02` bit 3 reads back as `nr_02_generate_mf_nmi`, which `zxnext.vhd:3843-3848`
latches on any accepted NR `0x02` bit-3 write and clears only on an explicit write of bit 3 = 0.
So a software NMI is filtered by design, and the bench asserts that.

**This is a live constraint on M2, not a testing detail.** The plan's asynchronous break is a
Copper `MOVE $02,$08`, which sets the same latch through the same signal (`nmi_gen_nr_mf` covers
CPU and Copper alike, `zxnext.vhd:3832`). It will be filtered by that same check until `nmi66h`
is taught to accept a software cause — and then T4's assertion must be inverted, deliberately and
in the same change.

The bench never writes the reference SD image; it reflink-copies it into `build/`.

Two known jnext gaps this project will hit, both deliberate absences with no consumer until now:
`AT+CIPSERVER` (with `AT+CIPMUX=1`, which jnext currently **refuses** with `ERROR`) and
`AT+CIPMODE` passthrough. File them as jnext issues **with this project as the demonstrated
consumer** — never speculatively. See the plan §8.2.

## Constraints for development

- Do not include Co-Authored-by headers in commit messages
- Keep commit messages terse but insightful
- **Agents must NOT write to the `main` branch, ever.** Only on their own branches and worktrees.
  A `PreToolUse` hook enforces this; the override is `DEZOGIF_ALLOW_MAIN_WRITE=1`, and it is for
  the user's explicit authorization only.
- **NEVER push to origin without explicit user authorization.** This applies to the manager AND
  every spawned agent. `git push`, `git push -u`, `git push --force` and `gh pr create` are all
  forbidden unless the user explicitly says "push" or "open a PR". Enforced by a hook; the
  override is `DEZOGIF_ALLOW_PUSH=1`.
- **Never `git commit --amend`** — always a new commit. Enforced by a hook
  (`DEZOGIF_ALLOW_AMEND=1` to override).
- **Git worktrees live OUTSIDE the repository directory**, at
  `~/tmp/worktrees/dezogif_ng/<name>`. Never inside the repo, not even gitignored.
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
4. Merge on APPROVE, one branch at a time. The manager does the merge, not the author.
5. Never push to origin — local commits and merges stay local until the user says otherwise.

## ChangeLog

`CHANGELOG.md` is inherited from upstream. Keep our entries clearly separated from upstream's
history, terse, one line per change, and only for changes a *user of the stub* would notice.
Update it only when the user asks.
