# MEMORY.md — decision log

Architecture, logic and format decisions, newest first. Each entry: what was
decided, why, and what was rejected. Read this at the start of every session.

---

## 2026-08-03 — Continue in this fork; do not start a new repo

**Decided.** Keep `dezogif_esp` as a fork of maziac/dezogif (359 upstream
commits, last 2023-06-13) and adapt it, rather than starting a fresh project
that borrows ideas.

**Why.** It builds clean today (0 errors, 0 warnings, 8192-byte ROM) with the
sjasmplus already on this machine. The upstream history is the only existing
documentation of *why* the memory choreography is shaped the way it is, and
~2,600 lines of Z80 unit tests come with it. The transport swap is genuinely
localised: `read_uart_byte`/`write_uart_byte` have ~60 call sites but are two
functions, and every DZRP response already computes its length up front
(`send_length_and_seqno`), which is exactly what `AT+CIPSEND=<id>,<len>`
needs. ~3.3 KB of the 8 KB ROM is free (`main_end` 0xF1B6, image ends 0xFEC0).

**Rejected.** A new repo: it would discard the history and the tests and buy
nothing — MIT imposes no obligation beyond the attribution we keep anyway.

---

## 2026-08-03 — sjasmplus, not z88dk

**Decided.** The assembler stays sjasmplus. This is not a preference.

**Why.** DeZog's own `documentation/Usage.md:505`: "Although z88dk can create
object code for banked memory, the .map and .lis files lack this information.
As a consequence, DeZog can not use any banking with z88dk." This stub is
nothing but banking (slot 6 SWAP, slot 7 MAIN, AltROM, MMU), and the SLD
format that carries bank info is sjasmplus-only. Verified against the
installed DeZog 3.7.4.

**Rejected.** z88dk (the usual toolchain elsewhere in this workspace) —
foreclosed by the client, not by taste.

---

## 2026-08-03 — Testing is local, headless, jnext; no CI service, no VS Code

**Decided.** `make test` runs jnext headless and judges screenshots. No
GitHub Actions, no VS Code or DeZog in the loop.

**Why.** A hardware-targeted stub can never have a hosted CI, and the DeZog
unit-test path needs VS Code driving zsim, which is not automatable here.
What *is* automatable is: does it assemble, is the ROM 8192 bytes, is the
build reproducible, does the ROM boot, does the stub take the screen on NMI.

**Rejected.** GitHub Actions (nothing to gain, sjasmplus + a 1 GB SD image to
provision); leaving `src/unit_tests/` as the only test layer (it cannot run
without VS Code, so it gates nothing).

---

## 2026-08-03 — Headless NMI is the software NMI, not the M1 button

**Decided.** `test/nmi_trigger.asm` enters the stub by writing NR `0x02`
bit 3 from guest code, after setting NR `0x06` bit 3.

**Why.** jnext exposes the M1 button only as the F9 *host* key, so
`--delayed-keypress` (which injects Spectrum membrane keys) cannot reach it.
`zxnext.vhd:3832` makes a CPU write of NR `0x02` bit 3 an MF NMI source, and
`zxnext.vhd:2090` ANDs every MF NMI source with NR `0x06` bit 3, whose
power-on value is 0. See [[ERRORS.md]] for the two attempts this took.

**Consequence for the design.** §3.3 of the plan claimed the Copper NMI was
"ungated". It is not. M2's Copper break must set NR `0x06` bit 3 itself and
cope with the debuggee clearing it. The plan has been corrected.

**Rejected.** Driving the GUI with xdotool (unreliable under Wayland); asking
for a jnext CLI flag before proving we need one.

**What it exposed.** The stub does not respond to that NMI, and the reason is
in `mf_rom.asm` `nmi66h`: it reads NR `0x02`, masks `00011100b` and returns
unless the result is zero — *button presses only*. NR `0x02` bit 3 reads back
as `nr_02_generate_mf_nmi`, latched by `zxnext.vhd:3843-3848` on any accepted
bit-3 write and cleared only by an explicit write of bit 3 = 0. So a software
NMI is filtered by design, and the bench's T4 asserts the decline. **M2's
Copper break hits the same gate** (`nmi_gen_nr_mf` covers CPU and Copper
alike, `zxnext.vhd:3832`), so M2 must modify `nmi66h` and invert T4 in the
same change. Found by the independent reviewer of this branch, not by the
author.

---

## 2026-08-03 — Build directory is `build/`, Makefile is semantic

**Decided.** `out/` → `build/`; bare `make` lists targets; the two output
paths in the sources come from the Makefile as `MAIN_BIN` / `MF_NMI_BIN`.

**Why.** Project convention (jnext). The old main target was
`out/dezogif.nex`, a file no build has ever produced, so make re-assembled
everything every time.

**Rejected.** Adding a `SAVENEX` to `main.asm` to make the `.nex` real — the
deliverable is the ROM; a NEX of the debugger has no consumer.

---

## 2026-08-03 — Worktrees live under `~/tmp/worktrees`

**Decided.** Agent worktrees go to `~/tmp/worktrees/dezogif_esp/<name>`.

**Why.** User instruction, 2026-08-03. Never inside the repo (that was the
old `.claude/worktrees/` layout inherited from jnext's docs, which also
contradicted CLAUDE.md's own rule).
