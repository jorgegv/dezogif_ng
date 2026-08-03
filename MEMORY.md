# MEMORY.md — decision log

Architecture, logic and format decisions, newest first. Each entry: what was
decided, why, and what was rejected. Read this at the start of every session.

---

## 2026-08-03 — Renamed `dezogif_esp` → `dezogif_ng`

**Decided.** The project is `dezogif_ng`. Documentation and `.claude/` config
were renamed; **the Z80 sources were deliberately not touched.**

**Why.** `_esp` named a transport, and the transport turned out to be one of
two build modes rather than the identity of the fork ([[#Two build modes]]).
`_ng` names the relationship to upstream instead, which is what actually
distinguishes this project and does not go stale when the transport story
changes again.

**Two things that did NOT change, on purpose.**

- The **checkout on disk** is still `/home/jorgegv/src/spectrum/dezogif_esp`.
  So is the auto-memory directory derived from it,
  `-home-jorgegv-src-spectrum-dezogif-esp`. Anything in `.claude/` naming
  those paths still says `dezogif_esp` and is correct.
- The **sources**. No string in `src/` carries the project name in a way a
  user sees, and churning 8,600 lines of mostly-upstream assembly for a rename
  would cost every future `git blame` against maziac/dezogif for nothing.

**Rejected.** Renaming the on-disk directory as part of this — but see below,
because the user has since said they will move it.

### Pending: when the on-disk directory is renamed

The user intends to move the checkout to `dezogif_ng` and will say when. At
that point exactly these have to change, and nothing else — the sweep has
already been done, so this is a checklist, not a search:

1. `.claude/docs/WORKTREES.md` — the layout diagram, the "Stay in the
   worktree" rule, and the paragraph explaining the mismatch, which stops
   being true and should be deleted rather than reworded.
2. `.claude/skills/worktree-launch/SKILL.md` — the "Do NOT touch …" line in
   the agent briefing footer.
3. `.claude/skills/handover/SKILL.md` — the auto-memory path. **This one is
   not cosmetic.** Claude Code derives that directory name from the on-disk
   path, so after the move it becomes
   `-home-jorgegv-src-spectrum-dezogif-ng`, a *different, empty* directory.
   Existing handover memories stay behind in the old one and will silently
   not be found. Move the contents across, or accept losing them.

Also worth a thought at the same time, though neither is in this repo: the
`git worktree` registrations under `.git/worktrees` (none exist right now, so
move while that stays true), and anything in `~/.claude/settings*.json` with a
path-scoped permission for the old location.

The git remote and the GitHub repo name are the user's, and independent of
this.

---

## 2026-08-03 — Two build modes (UART / WiFi), not a transport replacement

**Decided.** The stub keeps upstream's joy-port serial transport and gains an
ESP-01 WiFi one beside it. The mode is chosen **at assembly time**; one mode
per ROM.

**Why.** The serial path works today and costs nothing to keep. It is the
answer for a debuggee that owns the ESP itself — the ESP-contention risk in
plan §10 stops being a limitation and becomes a build choice. It also keeps
upstreaming plausible, since upstream's own transport is still there.

**Consequence, and it is the useful part.** The transport interface is now
load-bearing rather than tidy: `commands.asm`, `message.asm` and
`breakpoints.asm` must be assemblable against either mode without knowing
which. **That makes the UART build a free regression check on the
abstraction** — if a change breaks serial mode, the ESP assumptions leaked.
M1's success criterion now has two halves, WiFi working *and* UART still
equivalent to upstream.

**Not done yet, deliberately.** No `-DTRANSPORT=…` switch, no second Makefile
target, no stub `wifi.asm`. There is no WiFi code to select between, and
scaffolding ahead of the thing it scaffolds is how the switch ends up shaped
wrong. This entry records the decision; M1 implements it.

**Rejected.** Replacing the serial transport outright (the original plan, and
what every document said until now); carrying both modes in one ROM, selected
at runtime. The second was rejected on complexity — a runtime switch buys
nothing a rebuild does not, and it puts a branch in the hot path of every
transport call. A capacity argument is *available* but has not been made: the
~3.3 KB free is measured (`main_end` 0xF1B6 to image end 0xFEC0), the size of
an AT-command stack is not, because none has been written. Do not cite the
budget as though it settled this.

---

## 2026-08-03 — The combined work is GPLv3; upstream's MIT notice is kept

**Decided.** `LICENSE` is the GPLv3 text and covers this project as a whole.
Upstream's MIT licence moved to `NOTICE`, unchanged, with a header explaining
the relationship.

**Why.** MIT is GPL-compatible in one direction: a derivative may be
distributed under GPLv3 provided the MIT notice is preserved. Keeping the
notice in `NOTICE` satisfies that, and aligns this project with jnext, which
is GPLv3.

**Consequence, and it is not small.** Contributing the transport back to
dezogif — §6 of the plan, and milestone M4 — is now a *licensing* problem as
well as a technical one, because GPLv3 code cannot be merged into an MIT
project. Anything genuinely intended for upstream has to be written with the
intent of offering it under MIT too, decided at the time it is written.

**Rejected.** Dual-licensing the whole repo (complexity with no demonstrated
need); staying MIT (the user's call, and GPLv3 matches the rest of the
workspace).

---

## 2026-08-03 — Continue in this fork; do not start a new repo

**Decided.** Keep `dezogif_ng` as a fork of maziac/dezogif (359 upstream
commits, last 2023-06-13) and adapt it, rather than starting a fresh project
that borrows ideas.

**Why.** It builds clean today (0 errors, 0 warnings, 8192-byte ROM) with the
sjasmplus already on this machine. The upstream history is the only existing
documentation of *why* the memory choreography is shaped the way it is, and
~2,600 lines of Z80 unit tests come with it. Adding a second transport is
genuinely localised: `read_uart_byte`/`write_uart_byte` have ~60 call sites but are two
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

**Decided.** Agent worktrees go to `~/tmp/worktrees/dezogif_ng/<name>`.

**Why.** User instruction, 2026-08-03. Never inside the repo (that was the
old `.claude/worktrees/` layout inherited from jnext's docs, which also
contradicted CLAUDE.md's own rule).
