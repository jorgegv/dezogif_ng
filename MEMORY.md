# MEMORY.md — decision log

Architecture, logic and format decisions, newest first. Each entry: what was
decided, why, and what was rejected. Read this at the start of every session.

---

## 2026-08-04 — Merging to `main` is standing-authorized; pushing still is not

**Decided (user), 2026-08-04.** The manager session may merge to `main` without
asking each time, on four conditions, all of which must hold:

1. the issue or task is **finished**;
2. the branch is **ready**;
3. it has been **independently reviewed** by an agent that did not write it,
   with a binary APPROVE;
4. it has been **validated** at the highest testing layer that applies.

Short of all four, ask.

**What this does not change, and the distinction is the point of writing it
down.**

- **Pushing is still per-request, every time.** The entry below records that a
  push was authorized on 2026-08-04 and that it was not standing; this grant
  does not quietly extend it. A merged `main` sits local until the user asks
  for a push. Two permissions, granted separately, still separate.
- **Spawned agents still never write to `main`**, and
  `DEZOGIF_ALLOW_MAIN_WRITE=1` is not theirs to set. The grant is to the
  manager doing the merge, which is already how §Merging step 4 assigns it.
- It is not permission to edit `main` directly. Step 1 — dedicated branch and
  worktree, never edit `main` — is untouched.

**Why record it rather than just act on it.** The failure mode this project
already warns about is a future session reading history and inferring a
permission nobody granted. An unexplained run of merges in the log invites
exactly that; so does a standing grant that quietly grows to cover pushing.
Both are now written down with their edges.

**House form.** `main`'s history is linear — no merge commits before today —
so `git merge --ff-only` is the default, and a conflict means rebase or resolve
deliberately rather than silently minting a merge commit.

---

## 2026-08-04 — mfselect is z88dk C, and its first run is guarded

**Decided (user).** `mfselect` — the on-Next switcher between the stock
Multiface ROM and ours ([issue #1]) — is written in **z88dk C**, not sjasmplus,
and assumes NextZXOS is present at all times.

**Why this does not contradict the sjasmplus decision below.** That decision is
about the *stub*, and its reason is specific: DeZog cannot do banking with
z88dk, and the stub is nothing but banking. mfselect is a standalone NextZXOS
utility DeZog never sees, so the constraint does not reach it. z88dk also ships
the esxdos API bindings (`esx_f_open`/`read`/`write`/`stat`), which removed the
one genuine unknown — the `RST $08` calling convention — from the task. The
stub stays sjasmplus.

**The design decision worth keeping, and it is not the language.** The obvious
first-run rule — "no backup yet, so save whatever is installed as the original"
— **destroys the stock ROM for exactly the people most likely to run this
first**. Anyone who followed Appendix B.1 step A3 already has *our* ROM at the
official path; capturing that as "the original" labels the debug stub as the
stock Multiface ROM and leaves no copy of the real one on the card. So the
capture refuses when the installed ROM matches `dezogif.sum`, and asks before
capturing anything else — "not ours" is not proof of "stock". Bench check M4
asserts the refusal, answering Y anyway to prove the guard fires before the
question.

**Consequences that shaped the rest.**

- The guard needs our ROM's checksum, and it is read from `dezogif.sum` **at
  run time**, not compiled in. `BUILD_TIME` is stamped into the ROM, so every
  build changes it; a compiled-in constant would silently stop matching the
  moment the stub was rebuilt. The `.sum` is a *build* product for the opposite
  reason: computing it on the card would bless an already-corrupt file.
- CRC-16/CCITT, in two independent implementations (`tools/romsum.py` on the
  host, `crc16()` on the Next). Bench check M2 requires them to agree — the
  `.sum` files are worthless if they do not.
- Every install reads the copy back and re-checksums it. A short write on a
  tired card is the failure this must not hide.

**Not decided.** Whether a soft reset suffices instead of a power cycle. The
on-screen advice says power-cycle, which is safe either way, but nothing has
established that a soft reset is insufficient. It is a tbblue firmware
question, so the project's "read the VHDL" rule gives no answer.

**Rejected.** sjasmplus (the user's call, and the banking constraint does not
apply); a compiled-in checksum constant; 8.3-unsafe names like
`enNextMf.orig.rom` from the issue draft, in favour of `original.rom` /
`dezogif.rom`.

[issue #1]: https://github.com/jorgegv/dezogif_ng/issues/1

---

## 2026-08-04 — jnext's ESP server: inbound connection ids start at 1, not 0

**Recorded from the jnext implementer**, relayed by the user 2026-08-04, about
the server mode delivered by [jnext#210]. Not a decision of ours — a constraint
we have to build against, written down before it is needed.

**The fact.** Inbound connection ids start at **1**. Slot 0's transport is the
only object that can serve an outbound `AT+CIPSTART`, so handing slot 0 to a
peer would cost the guest its outbound capability. That leaves **four** inbound
slots rather than ESP-AT's five, and the numbering is visible to anything
reading `<id>,CONNECT`.

**Why this is not cosmetic.** M1's WiFi transport parses `+IPD,<id>,<len>:` and
prefixes every reply with `AT+CIPSEND=<id>,<len>`. A parser written from the
Espressif documentation would naturally expect the first inbound connection to
be id 0 — and against jnext it will never see one. The dangerous version is
worse than the obvious one: a stub that *assumes* 0 and hardcodes it will send
its replies to the outbound slot, producing no error, no data, and a debug
session that looks like a DZRP bug. Plan §10 already lists `+IPD` framing as
the risk that "looks like a protocol bug"; this is its specific shape.

**What to do.** Take the id from the `+IPD` header and echo that value back on
`AT+CIPSEND`. Never assume, never hardcode. M0(b)'s spike exists precisely to
isolate the parser, so that is where this gets proven.

**Deliberately not claimed.** Whether real ESP-AT firmware also starts inbound
ids at 1. The explanation given is a consequence of reserving slot 0 for
outbound, which is a **jnext design choice**, so hardware may well number
differently. Do not promote this to a hardware fact without measuring it — the
same mistake ERRORS.md records for the UART/ESP mux, where a plausible
derivation was exactly backwards.

[jnext#210]: https://github.com/jorgegv/jnext/issues/210

---

## 2026-08-04 — WiFi mode's UI is a connect string, not a selector

**Decided (user).** In WiFi mode the stub's screen shows a line of the shape:

    dezogif_ng remote debugger active. Connect at: 192.168.1.23:10000

**Why this closes something.** Extracting the transport interface left one
thing still leaking above it, and it was UI rather than protocol: the joy-port
selector (`uart_joyport_selection` in `data.asm`, `read_key_joyport` in
`ui.asm`, the 1/2/N key handling in `main.asm`) and the baud-rate display
(`BAUDRATE`, and the strings in `data_const.asm`). Those are meaningful in UART
mode and meaningless in WiFi mode, so the question was never "how do we hide
them" but "what replaces them". This answers it.

**What follows, for whoever implements it.**

- The two modes need *different* UI, not a shared one with blanks. UART mode
  keeps upstream's selector unchanged; WiFi mode draws a connect string. That
  makes `show_ui` a third thing the assembly-time switch selects, alongside the
  byte stream and the lifecycle — the transport interface grows a UI half.
- The IP is **not** known at assembly time. It comes from the ESP at run time
  (`AT+CIFSR`), so the string is composed, not a constant, and the ESP bring-up
  has to happen before the UI can be drawn — which orders M1's WiFi work:
  bring-up first, then UI, not the reverse.
- The port is ours to choose and belongs with the other build-time settings.
  DeZog's `cspect` remote defaults to 11000; the example above says 10000
  (ZEsarUX's). Pick one deliberately and write it in both the ROM and the
  `launch.json` example in Appendix B, because a mismatch there fails as a
  silent connection refusal.

**Port: 11000** (decided 2026-08-04). DeZog's `cspect` remote default, so a
`launch.json` that omits `port` still works. Must match Appendix B's example.

**What actually changes on that screen, read from `ui.asm` / `data_const.asm`
rather than assumed.** The connect string replaces exactly two things:

- `ESP UART Baudrate: 921600` → the connect string
- the joy-port selector — the `1 = Joy 1` / `2 = Joy 2` / `3 = No joystick
  port` key list and the "Using Joy 2 (right)" status line

Everything else on `show_ui` is mode-independent and stays: the title (minus
"UART"), the program and DZRP versions, `Video timing:`, `R = Reset`,
`B = Border`, and two that are load-bearing —

- **`Core: xx.xx.xx`.** Not decoration. `show_ui` compares it against 03.01.10
  and raises `ERROR_CORE_VERSION_NOT_SUPPORTED` below that. Stackless NMI needs
  it, and that is just as true over WiFi.
- **The red-on-black error area** (bottom 9 rows). It matters *more* in WiFi
  mode, because the connect string can only be drawn after the ESP has
  associated and answered `AT+CIFSR`. Before that there is no IP; if bring-up
  fails there never will be. The screen has to be able to say so rather than
  sit blank — plan §M3's "clear failure reporting on the Next's screen when
  the transport cannot come up", on the same real estate.

**Not decided here.** Exact wording and layout, and what the screen shows
during the window between "stub is up" and "ESP has an IP".

---

## 2026-08-04 — Pushing is authorised per request, and 2026-08-04's was not standing

**Recorded so it is not over-read later.** The user authorised a push on
2026-08-04, covering the five commits pending at that moment (through
`9ccaa93`). That was permission for that push, not a standing grant.

CLAUDE.md's rule is unchanged and still absolute: **never push without
explicit authorisation**, every time. A future session finding pushes in the
history must not infer that pushing is now routine. The same applies to
`DEZOGIF_ALLOW_MAIN_WRITE=1` — every merge to `main` in this history was
individually authorised.

---

## 2026-08-03 — The transport interface: subroutines, plus one macro

**Decided.** The seam M1 needs is `src/transport.asm`, which includes an
implementation (`src/transport_uart.asm`, upstream's serial path). The
interface is seven subroutines for the byte stream — `transport_read_byte`,
`transport_write_byte`, `transport_byte_available`, `transport_wait_rx`,
`transport_flush`, `transport_drain`, `transport_drain_with_timeout` — plus
`transport_init` / `transport_activate`, and **one macro**,
`TRANSPORT_DEACTIVATE`.

**Why a macro for that one.** Its single caller is inline in `backup.asm`'s
resume path, where a `CALL` costs bytes and a stack slot the routine does not
have. As a macro it also expands to *nothing* in a transport with nothing to
hand back, which is what an assembly-time mode switch should do. Subroutines
everywhere else, because upstream already paid for the `CALL` there.

**The gate was byte-identity, and it held.** With `BUILD_TIME` pinned,
`enNextMf.rom`, `main.bin` and `mf_nmi.bin` are byte-for-byte identical before
and after — the whole change is label renames, an include split and one macro
that expands to the instruction it replaced. That is the strongest available
evidence that a refactor of ~60 call sites across eight files changed no
behaviour, and it is worth preserving as the standard for the next one.

**What still leaks, and it is not what I expected.** After the extraction,
`commands.asm`, `message.asm` and `breakpoints.asm` — the three files
CLAUDE.md's rule names — are clean. What remains is **UI**, not protocol:

- `uart_joyport_selection` (`data.asm`), written by `main.asm` and displayed
  by `ui.asm`; `read_key_joyport` in `ui.asm` — the 1/2/N joy-port selector.
- `BAUDRATE` in `constants.asm`, and the on-screen strings in
  `data_const.asm` ("ZX Next UART DeZog Interface", "ESP UART Baudrate: ").

Deliberately **not** resolved tonight: what WiFi mode shows instead of a
joy-port selector is a design question (an IP address and a port, presumably)
and improvising it at 1am would produce the wrong shape. It is the next
decision M1 needs, not a leftover.

**Not done, still deliberately.** No `-DTRANSPORT=…` switch. `transport.asm`
is where it goes and says so, but with one implementation a switch can only
select that one; the reasoning in the entry below still applies.

---

## 2026-08-03 — Renamed `dezogif_esp` → `dezogif_ng`

**Decided.** The project is `dezogif_ng`. Documentation and `.claude/` config
were renamed; **the Z80 sources were deliberately not touched.**

**Why.** `_esp` named a transport, and the transport turned out to be one of
two build modes rather than the identity of the fork ([[#Two build modes]]).
`_ng` names the relationship to upstream instead, which is what actually
distinguishes this project and does not go stale when the transport story
changes again.

**What did not change: the sources.** No string in `src/` carries the project
name in a way a user sees, and churning 8,600 lines of mostly-upstream
assembly for a rename would cost every future `git blame` against
maziac/dezogif for nothing.

**The move, completed the same day.** The GitHub repo, the `origin` remote,
the checkout on disk and the auto-memory directory were all renamed by the
user; the three stale strings left in `.claude/` (WORKTREES.md's layout and
"stay in the worktree" rule, worktree-launch's briefing footer, handover's
memory path) were flipped, and the paragraph explaining the name/path mismatch
was deleted rather than reworded, because it only existed while they disagreed.

**Two things worth knowing from doing it.**

- The **auto-memory directory** was the item flagged as a data-loss risk,
  since Claude Code derives its name from the on-disk path and a move points
  it at a new, empty one. In the event nothing was lost: that directory had
  never had a `memory/` subdirectory, because no handover had ever been saved.
  The hazard is real and simply had not fired yet — it will, the first time
  this repo is moved after handovers exist.
- **`git worktree` registrations do not survive a move.** A leftover review
  worktree's `.git` file still pointed at the old repo path, and
  `git worktree remove` refused it ("not a .git file, error code 7").
  `git worktree repair <path>` fixes the pointer and removal then works. Move
  with no worktrees registered and the problem does not arise.

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
power-on value is 0 — though NextZXOS leaves it set, so a guest inherits it
(measured 2026-08-04; see [[ERRORS.md]], which used to credit that gate with a
failure dezogif's own cause check had caused).

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
