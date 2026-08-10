# MEMORY.md — decision log

Architecture, logic and format decisions, newest first. Each entry: what was
decided, why, and what was rejected. Read this at the start of every session.

---

## 2026-08-10 — The debugger's own screen was drawn through whatever window the client last asked for

**Built, issue #28.** `show_ui` maps the display file under `0x4000` for the
duration of a paint and puts back what was there — `ui.asm`'s `screen_map` /
`screen_unmap`, plus `SCREEN_BANK` in `constants.asm`. Bench check **N8**, shown
red first.

**THE DEFECT IS A 7392-BYTE WIPE OF A CLIENT-CHOSEN BANK, IT IS UPSTREAM'S, IT
IS IN BOTH ROMS, AND NOBODY HAS TO BE AT THE MACHINE.** `show_ui_body` opens
with `MEMCLEAR SCREEN, SCREEN_SIZE` — 6144 bytes — and then fills **1248** more
with attributes before it prints a character: `0x4000`-`0x5CDF`, **7392 bytes**,
plus the glyphs drawn inside that range. (The *slot* is 8 KB and the write is
not, which the issue and the first version of this entry both said. Corrected
rather than propagated.) All of it through `0x4000`, which is the display file
**only while MMU slot 2 says so**. `CMD_SET_SLOT 2,<bank>` is an ordinary DZRP
command a client sends to look at a bank, and `cmd_set_slot` writes the MMU
register directly for every slot but 7, telling the UI nothing. Nothing backs a
bank up — `slot_backup` holds slots 0 and 7 — so the write is permanent and the
debuggee is handed the wreckage on its next `CMD_CONTINUE`.

**THE ISSUE SAYS IT NEEDS "SOMEONE PRESSING B AT THE MACHINE". IT DOES NOT, AND
THAT IS THE FINDING RATHER THAN THE FIX.** `check_key_border` reaches
`main_redraw`, and so does `jp main` from **`cmd_close`** — which is what
DeZog's `CSpectRemote.disconnect()` sends on every Shift+F5 — and so does
`drain_main`, on any RX timeout. `show_ui` sits below all three. The keypress is
the *rarest* of the triggers, not the only one.

**AND #23 WROTE THIS DEFECT DOWN AS AN OUTCOME WITHOUT RECOGNISING IT.** N6's
third outcome is `WIPED`, worded as *"show_ui's MEMCLEAR reached that bank, so
this run reached drain_main and tested nothing"* — a precondition failure. That
sentence describes this defect firing. It was correct as a statement about
**N6's** subject and it meant the check could never be the one to report it.

**BUT IT HAS NEVER FIRED AND CANNOT, WHICH AN EARLIER VERSION OF THIS ENTRY GOT
WRONG** by saying N6 had been "quietly reporting" it all along. `WIPED` requires
`after == bytes(2048)` exactly, and any run that reaches `show_ui` also draws
glyphs into character rows 8-15 — which is precisely the probe's
`0x4800`-`0x4FFF`. So the outcome would be `CORRUPT`, and N6 would blame the
**refresh** for `show_ui`'s damage. Measured, not argued: this branch's own red
against `main`'s ROM reports `overwritten`, never `zeroed`.

**FORCE AND RESTORE, NOT CHECK AND ABANDON, and the two are right in different
places rather than one being better.** `esp_refresh_client_line` (issue #23)
reads NR `0x52` back and **abandons** a redraw whose window has moved. That is
right there: it keeps one row current, and skipping it costs a stale row until
the next full repaint. It is wrong for `show_ui`, which **is** the debugger's
screen — a "B" press or a `CMD_CLOSE` that drew nothing would leave the machine
showing whatever happened to be on it, and `last_error` unreported in the one
place a user is told to look. So this forces the window and puts the original
back, which leaves debuggee-visible state identical and needs no caller to be
told anything.

**IT ALSO CLOSES AN OLDER AND LARGER CASE FOR FREE, WHICH THE ISSUE DOES NOT
MENTION.** An M1 press against a debuggee whose own slot 2 was not the screen
used to paint the UI **into that debuggee's memory** and leave the display
untouched — which from the outside reads as a stub that failed to come up. That
needs no `CMD_SET_SLOT` at all, only a program that banks at `0x4000`. It is not
staged by any run here; it falls out of forcing the window.

**THE MECHANISM IS A REGISTER READ, WHICH IS WHAT KEEPS IT OUT OF COMMON CODE'S
WAY.** NR `0x52` reads back the live MMU2 (`zxnext.vhd:6059-6081`, returning the
same `MMUn` that decodes CPU addresses at `:2952-2964`; slot 2's decode is
untouched by the Multiface and config-mode overrides, which are scoped to slots
0/1 at `:3029-3066`). Same mechanism `send_ntf_pause` and #23 already use. The
alternative — a macro invoked from `cmd_set_slot` — was rejected by #23 for two
reasons that both still apply: it puts state into `commands.asm`, which
CLAUDE.md's hard rule says must not be able to tell which transport it was
assembled against, and it is correct only while an enumeration of **forty**
`nextreg REG_MMU...` sites stays correct.

**`SCREEN_BANK` IS A VHDL FACT AND NOT A COPY OF `cmd_init`'s 10.** An MMU value
of `0x0A`/`0x0B` is bank 5 (`zxnext.vhd:2961`), and `show_ui_body`'s own
`nextreg REG_DISPLAY_CONTROL,0` is what makes bank 5 the *displayed* one, since
NR `0x69` bit 6 drives port `0x7FFD` bit 3 (`:3658-3660`), the shadow-screen
select (`:3768`). So `show_ui` already forced the ULA onto bank 5 and this
forces the CPU's window onto the same place. `cmd_init`'s 10 agrees and says
something else — it is restoring the ZX128 default layout.

**A PREDICTION IN THIS FILE SAID THIS COULD NOT BE DONE, AND IT IS ANNOTATED
RATHER THAN REWRITTEN.** The 2026-08-09 issue-#31 entry rejects "forcing slot 2
in `show_ui`" because *"`esp_ui_bank` would always record the forced bank, so
`esp_refresh_client_line` would always abandon and N5/N6 would go red"*. The
first clause is true and the consequence does not follow: the refresh compares
that byte against NR `0x52` **at refresh time**, i.e. against what
`screen_unmap` put back, and in the ordinary case both are 10.

**AND THE REFUTATION IS SOUND BY CONSTRUCTION, NOT MERELY BY MEASUREMENT**,
which is stronger than the first version of this paragraph argued: `esp_ui_bank`
is now **invariantly** `SCREEN_BANK` — every writer of it runs either inside
`screen_map`'s window (`show_ui`) or behind a comparison that has just proved
equality (`esp_refresh_client_line`) — so the guard reduces to "is `0x4000` the
screen right now", and that abandons **exactly** when the window is elsewhere
and proceeds **exactly** when it is not. Both directions, from the invariant
rather than from three runs. The runs agree: **N5, N6 and N7 all green in the
same run as N8**. See the annotation in place.

**AND THE GUARD IT WAS FEARED TO BREAK IS STRONGER NOW.** `esp_ui_bank` is read
inside the forced window, so it always holds `SCREEN_BANK`, and the comparison
has become *"is `0x4000` the screen right now"* instead of *"has the mapping
moved since I drew"*. The second was the weaker question and it had the same
case as above: an M1 press against a banked debuggee used to record the
**debuggee's** bank there, after which a redraw would match it and XOR the
session line into the program being debugged.

**Evidence: `make test-client-status`, 8 runs, 8 checks, N8 shown red first.**

| | ROM | verdict |
|---|---|---|
| **red** | `main`'s | `SHOW_UI CORRUPT bank 60 overwritten: 2040 of 2048 bytes changed, first at 0x4800` — **7 of 8** |
| **green** | as built | `SHOW_UI OK bank 60 unchanged across 2048 bytes from 0x4800` — **8 of 8** |

**N8'S TRIGGER IS `CMD_CLOSE` AND NOT THE "B" KEY THE ISSUE NAMES**, which is a
deliberate departure. Same routine either way, but a client ordering its own
commands over a socket carries **no margin at all**, where `--delayed-keypress`
is scheduled in emulated **frames** against a client counting wall clock — W6's
mismatch, and N5's own `IDLE_WAIT` is documented as still being a margin rather
than a proof. The cost is stated rather than hidden: nothing here presses a key,
so `check_key_border`'s `jp z,main_redraw` is uncovered.

**THE PRECONDITION IS N3's ORDERING PROOF REUSED**, not invented: `cmd_close`
answers **before** it reaches `show_ui`, so its own response proves nothing, and
only a reply to a *further* command shows the repaint happened. And the
read-back deliberately does **not** re-issue `CMD_SET_SLOT`, which is what makes
N8 cover the restore half too — a `show_ui` that forced the window and forgot to
put it back would leave `0x4000` addressing the screen, and the probe read would
catch it. Slot 2 is read out of `CMD_GET_REGISTERS` first so that "left the
window forced" and "wrote through the client's bank" are two verdicts.

**Rejected.** *Check and abandon*, `esp_refresh_client_line`'s shape — cheaper
by ~10 bytes and already precedented here, and it makes a "B" press or a
`CMD_CLOSE` after any `CMD_SET_SLOT 2` draw **nothing at all**, which is a
different defect wearing a politer hat and would hide `last_error` in the only
place it is displayed. *Forcing slot 2 and not restoring it* — that is issue #26
one slot along and #31's own hazard: `cmd_get_registers` reports slots 0-6 live
from the MMU, so DeZog would be told the wrong bank and the debuggee would
resume with it. *A macro from `cmd_set_slot`* — above, and #23's reasons.
*Putting `SCREEN_BANK` in `zx/zx.inc` beside `SCREEN`* — that file is upstream's
and this is a Next MMU fact, so it went in our own `constants.asm`. *Changing
`cmd_init` to use it* — the two numbers agree and say different things, and
conflating them is what this project refuses. *Making
`esp_refresh_client_line` force the window too* — #23 decided abandoning is
right there and the reasoning holds; out of scope.

**Cost: +27 bytes in BOTH ROMs, which is correct for common code.** `main_end`
UART `0xF296` → **`0xF2B1`**, WiFi `0xFCAD` → **`0xFCC8`** — 3055 and **472**
bytes free to the identity block. Pinned: UART `49a1f363…` → `34af567a…`, WiFi
`f8786a14…` → `808dbc60…`, with `build/*.bin` deleted before each build.
**The UART byte-identity gate is EXPECTED to break here** — `ui.asm`,
`constants.asm` and `data.asm` are all common code — as it did for #7, #8, #9,
#12, #20, #27 and #31. **`transport_esp.asm`'s change is comment-only, and what
says so is a grep**: its diff has zero changed lines that are not a comment or
blank. The two variants moving by exactly the same 27 bytes **corroborates**
that and does not prove it, which an earlier version of this paragraph got
wrong — equal deltas prove **net-zero**, and a +3/−3 edit gives the same number.
**This changes a ROM, so the merge carries a `make bump`.**

**Regression: `test-client-status` 8/8, `make test` 8/8 (T8 included),
`test-dzrp-stub` 21/21 with W1-W6, `test-unit` 5/5, `test-screen-agreement` all
green (all 49152 pixels agree in both G1 and G2, which is the check that judges
what `show_ui` actually draws), `test-no-hang` 4/4, and both variants
`check-reproducible`.**

**NOT COVERED, and none of it is hidden.**

**A "B" PRESS WITH SLOT 2 RETARGETED, AND A POST-PRESS `show_ui` RETURN.** The
first version of this paragraph claimed more than that from `test-no-hang`'s N2,
and the claim was false in the direction that overstates coverage — in this
file, which `CLAUDE.md` designates read-first. It said N2's **black** border
"can only happen by way of `check_key_border` → `main_redraw` → `show_ui` →
`main_loop`, so the key path runs through the new shell **and returns**".
**`check_key_border` writes the black itself** — `xor a` / `out (BORDER),a`,
`src/ui.asm:83-84` — *before* it returns Z and therefore before `main.asm:231`'s
`jp z,main_redraw` is taken; and `change_border_color` then returns immediately
while `slow_border_change` is 0 (`transport_esp.asm:2935-2938`,
`transport_uart.asm:223-226`), so nothing later disturbs it. **The bench I cited
says exactly this in its own header** (`test/run-no-hang.sh:49-51`). So the
black is identical whether the post-press `show_ui` returned or hung, which is
precisely the half that was claimed.

What N2 does establish, and it is worth having: `jp z,main_redraw` is
unconditional on the Z `check_key_border` returns, so black says the key was
polled and therefore that `main_redraw` and the new shell were **entered**; and
black-rather-than-yellow says `main_loop` was reached at all, which requires the
**boot** `show_ui` to have returned through the shell. Neither is the
post-press return, and no run here presses "B" with slot 2 pointing elsewhere.

**`drain_main`'s path to the same `show_ui`**, which is how this most often
fires in the field and which no check stages deliberately. N6's `WIPED` outcome
is *not* the nearest thing, and an earlier version of this entry said it was:
**`WIPED` cannot fire at all**. It needs `after == bytes(2048)` exactly, and any
run that reaches `show_ui` also draws glyphs into character rows 8-15 — which is
exactly the probe's `0x4800`-`0x4FFF` — so the outcome is `CORRUPT`. Measured
rather than argued: this branch's own red reports **`overwritten`**, never
`zeroed`. The same reasoning makes `close_slot`'s `"zeroed"` sub-label
unreachable today; it is kept as a cheap discriminator against a future partial
fix and labelled as unreachable where it is written.

**A TRADE THE FIX MAKES AND THE FIRST VERSION OF THIS ENTRY DID NOT NAME: the
debugger now destroys BANK 5 unconditionally**, where before it destroyed
whatever slot 2 happened to hold. It is the right trade — `show_ui_body` already
forces the ULA onto bank 5 (NR `0x69` bit 6) and `main_redraw` blanks Layer 2,
so the debugger is taking the display either way — but it is a trade and not a
free win: a debuggee holding data in bank 5 with slot 2 pointed somewhere else
used to survive a repaint and now does not. That includes `0x5B00`-`0x5CDF`,
which `show_ui_body`'s attribute `MEMFILL` overruns into and which is not the
picture at all.

**`SCREEN_BANK`'s VALUE IS NOT CHECKED BY N8.** A `SCREEN_BANK=11` build would
pass it — the client's bank is spared either way — so N8 covers the guard and
not the number. What covers the number is elsewhere in the same bench: N1-N5
read row 8 back **as text**, which a window pointed at the wrong half would
leave blank.

**The debuggee-banked case** the fix closes for free: nothing stages an M1 press
against a program holding a non-screen bank in slot 2, so that improvement is
reasoned from the code and not measured. **The shadow screen**: `SCREEN_BANK` is
right because `show_ui` clears NR `0x69` bit 6 in the same routine, which is
read from the VHDL and not from a run — no bench here boots a guest using bank
7. **Real hardware**: nothing here has run on a Next, as with every bench in
this repository.

---

## 2026-08-10 — Every breakpoint anywhere ROM was mapped was silently discarded, and fixing it arms the other mechanism

**Built, issue #27.** Breakpoint writes into `0x0000-0x3FFF` now land, and the
debugger's own trampoline is refused. Checks **C19**, **C20** and **C21**, all
shown red first.

**THE DEFECT IS UPSTREAM'S, IN BOTH ROMS, SINCE THE FORK, AND IT IS NOT THE ONE
THE ISSUE WAS OPENED FOR.** A DZRP breakpoint is a byte patched into memory.
`copy_modify_altrom` leaves NR `0x8C` at `10000000b` for the whole debug session
— bit 7 set so the patched Alt ROM **serves reads**, bit 6 clear — and the
ROM-serving branch of the slot 0/1 decode computes `sram_pre_rdonly <= not
(nr_8c_altrom_en and nr_8c_altrom_rw)` (`zxnext.vhd:3056`), which gates the
physical SRAM cycle at `:3154`. So **the `RST 0` never reached memory at all**,
and every breakpoint path reported success because **none of them reads back what
it wrote**. Nothing is mismapped and nothing is corrupted; the byte is simply
discarded. The trampoline breakpoint the issue was filed about is one instance of
a defect covering the whole of `0x0000-0x3FFF` — a quarter of the address space,
and the quarter every ROM call goes to.

**MEASURED BEFORE ANYTHING WAS WRITTEN, AND THAT IS THE WHOLE POINT OF THIS
BRANCH.** This issue had already cost **two retracted mechanisms**, each
plausible, internally consistent, traced through real code, and wrong. So the
first action was a probe, not a third story:

| | measured, first run |
|---|---|
| `CMD_SET_BREAKPOINTS` at `0x1234` | reads back `0xED` — **discarded** |
| the same command at `0x0066` | reads back `0xF5` — **discarded** (and that `0xF5` is `dbg_enter`'s `push af`, so the Alt ROM really is serving reads) |
| the same command at `0x8000` | reads back `0xC7` — **landed** |
| MMU slot 0 during `cmd_loop` | **255**, the ROM |

**C20 IS THE HALF THAT MATTERS TO A USER AND ITS FIXTURE IS THE PART WORTH
COPYING.** "The breakpoint did not fire" and "the resume never worked" are the
same observation, and that confound is what wrecked the one attempt to test this
at the machine. Rather than waiting out a timeout, the ROM address it uses is one
whose byte is `0xC9` — a `RET` — **found by reading the machine** rather than
hardcoded, and the debuggee `call`s it. A landed breakpoint stops there; a
discarded one returns and falls through to a RAM trap one instruction later.
**Both outcomes are positive observations**, an `NTF_PAUSE` arrives either way,
and a *silence* becomes a third outcome meaning the resume failed. Measured red:
*"the ROM breakpoint at 0x0280 never fired; the RAM control did"*.

**THE FIX ARMS THE ORIGINAL REPORT'S OTHER MECHANISM, SO THE GUARD IS NOT
OPTIONAL.** `write_debuggee_byte` sets bit 6 for the write alone, landing it in
the Alt ROM — the image the debuggee executes, which is why C20 then goes green.
But `copy_modify_altrom` patches 8 bytes at `0x0000` and 14 at `0x0066` into that
same image, and they are the only reason an `RST 0` reaches the debugger at all.
While writes were discarded a breakpoint aimed at them was harmless; the moment
they land, an `RST 0` over `dbg_enter`'s first byte makes every breakpoint
re-enter itself and walk the stack down through memory. **That is mechanism A
from the original report — impossible today, live the moment mechanism B is
fixed.** `bp_hits_trampoline` refuses those 22 bytes. Its bounds come from the
labels `copy_modify_altrom` itself copies with, so the **constants** cannot
drift — which is not the same as the comparison being right, and the next
paragraph is what that cost.

**READS MUST NOT BE TAKEN WITH BIT 6 SET, and it is the trap in this fix.** The
two settings are complementary rather than a level and a flag (`:3078`): with bit
6 set it is the **real, unpatched ROM** that serves reads. So an opcode read in
that state would be the wrong byte to keep for un-patching — at `0x0000` and
`0x0066` it would be the original ROM's rather than our own trampoline's. Every
caller already read the opcode before writing, which is the order that works, and
the helper writes only.

**THE GUARD SHIPPED WRONG AND THE REVIEW MEASURED IT, WHICH IS THE MOST USEFUL
THING IN THIS ENTRY.** `bp_hits_trampoline`'s `ret c` below the `0x0066` test
returned **with carry set** — which the routine's own contract three lines above
defines as *"refuse, it is ours"*. Assembled `D8`. So the guard refused
`0x0000-0x0073`: **116 bytes, not 22**, of which 94 are ordinary ROM — `RST 8`,
`RST 0x10` through `RST 0x30`, and **`0x0038`, the IM1 handler**, which are the
addresses a Spectrum developer breaks on most.

**And because `set_tmp_breakpoint` shares the guard, STEPPING RAN AWAY there.**
Measured with C20's fixture aimed at `0x0052`, the one `RET` in the window: the
debuggee ran straight past a temporary breakpoint the client had asked for and
stopped at the RAM control. **That is the exact user-visible failure #27 exists
to fix, recreated by the fix for it in a 94-byte window.** Corrected to
`ccf` / `ret nc` / `cp` / `ret`, and re-measured over the wire rather than
re-read: refusal set now `0x0000-0x0007 0x0066-0x0073`, exactly 22, with `0x0052`
stopping on its breakpoint.

**THE LESSON IS ABOUT THE COMMENT, NOT THE FLAG.** The bounds are taken from the
labels `copy_modify_altrom` copies with, and the comment said they therefore
"cannot drift". That is true of the **constants** and says nothing about the
**comparison** — and the constants were right the whole time. A claim of
correctness attached to the half that was not in question. What holds the extent
now is C21 measuring it over the wire, and the comment says so instead.

**RESTORES: `cmd_restore_mem` IS GUARDED, `clear_tmp_breakpoint` IS NOT, AND THE
FIRST VERSION HAD THAT BACKWARDS.** It left both unguarded, arguing that "a
breakpoint that can be set and not removed is worse than one that never
happened". **That argument does not survive the guard's own existence**:
`bp_hits_trampoline` is a pure function of the address, so an address refused on
the restore is one that was refused on the set, and guarding can never strand a
legitimate un-patch. Measured on the merged ROM: a client `CMD_RESTORE_MEM` put
its own `0x00` on `0x0000`, `0x0003`, `0x0066` and `0x0070` — **C18's defect
reopened one command along**, a client-controlled write over the running
debugger, in a command where `main` discarded it. Now refused, with the same
command still landing on ordinary ROM. `clear_tmp_breakpoint` stays unguarded
because the difference is **who chose the address**: its comes from
`tmp_breakpoint_X.bp_address`, written only by `set_tmp_breakpoint.store` and
only where this same guard already passed.

**A REFUSED BREAKPOINT IS SILENT, AND THIS IS THE ONE JUDGEMENT CALL HERE.** DZRP
has no "cannot place a breakpoint there" response, and a reply of the wrong length
desynchronises everything after it — the argument that already governs
`error_payload_too_big`. The decisive reason is narrower and is about behaviour
rather than protocol: **refusing leaves the trampoline behaving exactly as it does
today**, since nothing reached it then either. So this change moves the rest of
ROM and moves the trampoline not at all, which is the smallest claim the fix can
make.

**THE FIRST VERSION JUSTIFIED THAT SILENCE WITH A CLAIM THE GUARD BUG
FALSIFIED**, and it is corrected rather than deleted: it said refusal only bites
when "the debuggee's PC is inside the stub's own trampoline, which only happens
when the session is already broken". While the guard covered 116 bytes that was
simply untrue — `0x0038` and every `RST` vector are ordinary places a healthy
session steps into. The claim is only defensible for the 22 bytes actually
refused, so it now rests on the **measured extent** rather than on an assertion
about the code, which is the whole reason C21 asserts that extent. Issues #8 and
#9 call silence a defect where a real client legitimately sends the command; 22
bytes of our own trampoline is not that, and 116 bytes of the RST vectors would
have been.

**Evidence: `make test-dzrp-stub` 21/21 with W1-W6, exit 0**, and every check
shown red first — **in both directions for C21**, which is the half a degenerate
control cannot reach:

| ROM under test | C19 | C20 | C21 |
|---|---|---|---|
| before the fix | FAIL | FAIL | **PRECONDITION**, not a vacuous green |
| writability, **no guard at all** | PASS | PASS | FAIL — *planted at 0x0000-0x0007 0x0066-0x0073* |
| writability, guard **too narrow** (0x0000 and 0x0066 only) | PASS | PASS | **FAIL** — *planted at 0x0001-0x0007 0x0067-0x0073* |
| writability, guard **too wide** (the shipped `ret c`) | PASS | PASS | **FAIL** — *the guard also refused 0x0008 0x0065, which is ordinary ROM* |
| as merged | PASS | PASS | PASS |

**THE MIDDLE TWO ROWS ARE THE ONES THAT HAD TO BE EARNED, AND THE FIRST VERSION
OF C21 FAILED BOTH.** It constrained the guard at `0x0000` and `0x0066` and
nowhere else, so it passed green against a guard that plants `RST 0` on
`0x0001-0x0007` and `0x0067-0x0073`, and it could not see the 116-byte over-refusal
that actually shipped. **This is mfselect's M9 and N6's scanline-0 for the third
time in this project**: a control that only collapses the cases together proves
only that direction. C21 now asserts the **extent** — every byte of both blocks
refused, and `0x0008`, `0x0065` and `0x0074` taken — which is what makes all four
reds reachable. `0x0065` is in there because it is the byte below the *second*
block, so a guard that got only the first boundary right still fails.

**Rejected.** Bracketing `memory_loop`'s inner write instead, which would fix
`CMD_WRITE_MEM` into ROM as well (it is the **per-byte receive path** whose cost
brackets the UART ceiling at 470-610 T-states — two `nextreg`s per byte on a
16 KB transfer, for a case DeZog does not exercise); a read-modify-write of NR
`0x8C` rather than the two literals (`copy_modify_altrom` has always written
these exact values, and naming them in `constants.asm` and using them in both
places is one rendering rather than two); guarding the restore paths (above);
fixing issue #27's third strand here (below); and leaving the reproduction with
no fix, which was the fallback if the mechanism had not been demonstrable —
it was, on the first probe ROM.

**Cost: +59 bytes in BOTH ROMs, which is correct for common code.** `main_end`
UART 0xF25B → **0xF296**, WiFi 0xFC72 → **0xFCAD**, leaving **499** free to the
identity block. Pinned: UART `ab06656e…` → `14eea03f…`, WiFi `d500eea0…` →
`ea13c33e…`. (+51 and `4ee1a593…`/`016b6bec…` were the first, rejected version;
the review's guard and restore fixes are the other 8 bytes.) **The UART byte-identity gate breaks by design** —
`breakpoints.asm`, `commands.asm`, `constants.asm` and `altrom.asm` are all
common code — as it did for #7, #8, #9, #12, #20 and #31. **This changes a ROM,
so the merge carries a `make bump`.**

**NOT COVERED, and none of it is hidden.**

* **THE HANG DOES NOT REPRODUCE IN THE EMULATOR, AND ISSUE #27'S THIRD STRAND IS
  UNTOUCHED.** `CMD_CONTINUE` from the uninitialised `backup.pc`/`backup.sp` was
  driven both ways the issue reports — a step with breakpoints at `0x0002`/`0x0066`,
  and a plain Continue with none — and jnext **never wedges**: it answers an
  `NTF_PAUSE` in ~0.02 s, reason 2, at `0x6417`, and a fresh client is served
  immediately. Ten successive steps reach the identical fixed point every time.
  So the *tens of seconds of unresponsiveness* the user saw is **not reproducible
  here**, nothing was measured about what ends it, and **no mechanism is offered**
  — this issue has already cost two. The garbage the resume executes depends
  entirely on what is in memory, which is exactly what differs between a booted
  NextZXOS under jnext and the user's machine.
* **Hardware.** Nothing here has run on a Next. Every emulator result rests on
  jnext modelling NR `0x8C` bit 6, which it demonstrably does — the write lands
  and the byte is then *fetched* by the CPU, which is the full round trip — but
  that is jnext's model of `zxnext.vhd:3056`, not silicon.
* **`CMD_WRITE_MEM` into ROM space is still silently discarded**, and so is
  `write_debugged_prgm_mem` if a debuggee's SP points there. Same defect class,
  deliberately out of scope (above), and no check covers it.
* **A SECOND, SEPARATE UPSTREAM DEFECT WAS FOUND AND NOT FIXED.**
  `cmd_set_breakpoints.handle_64k_address` does `cp HIGH MAIN_ADDR` with **A = 0**
  — the bank+1 byte it has just tested — instead of `ld a,h` first, so the
  comparison always carries and a 64K address is *always* taken as `.normal`.
  `set_tmp_breakpoint` gets this right. A plain 64K breakpoint at `0xE000` or
  above therefore writes directly into whatever slot 7 holds, which while the
  debugger is stopped is `MAIN_BANK` — the debugger itself. **`cmd_restore_mem`
  has the identical defect** (`commands.asm`, its own `.handle_64k_address`), so
  it is two sites and not one — found by grep after the review pointed out the
  first count was short, which is the enumeration lesson this file keeps
  recording. Unreachable from DeZog, which sends long addresses, and **unchanged
  by this branch** since neither is a ROM write. The manager is filing it.
* **The refusal's user-facing behaviour** is exercised by nothing but C21: no
  real client sends a breakpoint at the trampoline, and what DeZog does about
  getting no breakpoint there is unknown.

## 2026-08-10 — The NMI decline arm gets a check, and the obvious version of it passes the bug

**Built, issue #36.** Bench check **T8** in `make test`: the M1 button pressed
**twice with no reset between**, asserting that the second press does **nothing**
while proving the machine is still alive. Ten headless runs now, eight checks.

**IT IS T7'S OTHER ARM, AND THAT ARM IS THE ONE M2 EDITS FIRST.** `mf_rom.asm`'s
dispatch branches on the bank slot 7 held at the press: not `MAIN_BANK` →
re-initialise, which is T7; `MAIN_BANK` → decline, because the debugger itself
was executing, which was guarded by one hardware observation (2026-08-07, build
`00.12`) and nothing else. Teaching `nmi66h` to accept a software cause — M2's
first act — edits that routine and reuses the same `MF.nmi_slot7` byte.

**Measured rather than argued**: against a scratch ROM whose dispatch sends
**every** press to `init_main_bank`, **T1-T7 are all green and T8 is the only
red**. That is issue #36's whole premise, produced rather than reasoned.

**THE DESIGN DECISION IS THE THIRD KEYPRESS, AND THE FIRST VERSION OF THE CHECK
WOULD HAVE PASSED THE BUG.** The issue specifies two presses plus a liveness key
— press "B", judge the border, black when `main_loop` was reached. Built exactly
that way, and then measured against the regression ROM: **it comes out green.** A
re-initialisation resets `slow_border_change`, the liveness "B" then turns it off
again, and the screen is **byte-identical** to the one-press reference. So some
state has to be moved away from its default **before** the second press, or a
re-init leaves no trace at all; in the UART build the joy-port selector is the
one a keypress can reach, and `main_bank_entry` sets it back to 2. Three ROMs,
one choreography:

| ROM | row 6 | border | vs the one-press run |
|---|---|---|---|
| shipped | `No joystick port used.` | black | **0.00%**, byte-identical |
| every press → `init_main_bank` | `Using Joy 2 (right)` | black | 0.33% |
| the decline arm spins for ever | `No joystick port used.` | **red** | 40.03% |

**The row is READ, not compared** (`test/screen-text.py`), for ERRORS.md's
reason — "these two differ" is not "this one is right" — and because reading it
is also what says the "3" press landed at all. Without that assertion the
discriminator could vanish silently and the re-init would pass.

**AND WITHOUT A KEYPRESS AT ALL THE 0.00% IS LUCK, WHICH IS WORTH RECORDING
BECAUSE THE REVIEW MEASUREMENT OF 2026-08-07 IS EXACTLY THAT RUN.** Reproduced:
one press against two presses, no keys, comes out 0.00% — and **both** broken
ROMs come out **40.00%**, which is the border and *only* the border, the paper
being byte-identical in all three. The border is cycling, so that discriminator
is a phase coincidence at one frame. Pressing "B" is what turns it into a
property: it blacks the border **and** stops `change_border_color` touching it.

**THE ORDER OF THE THREE EVENTS IS ASSERTED, AND THAT GUARD WAS EARNED BY AN
ACCIDENTAL GREEN.** While checking that the preconditions fire, moving the second
press to frame 1500 — past the screenshot at 1466 — produced **8/8**, with the
button pressed after the picture was taken. The NMI-count precondition says both
presses were *delivered* and nothing about *when*. Same shape as W6's window
(CLAUDE.md §4c): get an edge wrong and it fails **green**. Two edges have runtime
preconditions instead — a joy-port key landing before the stub is up is never
polled, a "B" landing after the picture leaves the border uncycled — so only the
chain itself needs a static check. Unlike W6 this really is by construction:
these are emulated frames, not a client's wall clock.

**All three preconditions have a re-runnable red**, the seam being the three
frame numbers rather than a build constant — `NORESET_JOY_FRAME=850`,
`NORESET_KEY_FRAME=1500`, `NORESET_NMI_FRAME=1500`, each taking a different guard
red on the **shipped** ROM. `NORESET_JOY_FRAME=950` does *not*, which is a
measurement worth keeping: the stub is in `main_loop` and polling within 50
frames of the press.

**Rejected.** The two-key design the issue specifies (above — it passes the
regression); pressing "B" *before* the second press instead (it catches the
re-init and makes a **wedged** stub look alive, which is the other half of the
same trap); judging the joy-port row by comparing the two runs rather than
reading it (mfselect's M9, ERRORS.md); a percentage threshold instead of
byte-identity (the stub owns the screen here, NextZXOS is not idling behind it,
and the good pair really is byte-identical); factoring `border_rgb` out of
`run-no-hang.sh` into `bench-jnext.sh` (that file earns its keep by defining
jnext teardown and nothing else, and sharing ten lines of pixel sampling would
mean editing a second bench this change has no business touching).

**Cost: test infrastructure only.** `git diff main..HEAD -- src/` is **empty**;
the `Makefile` appears only for its `# 8 checks` help line, so the **certain**
answer was taken rather than the conservative one — both ROMs hash identically to
`main`'s with `BUILD_TIME` pinned and `build/*.bin` deleted first (`1e94d54b…`,
`20e48a0f…`). **No `make bump`.**

**Regression: `make test` 8/8, twice**, plus a clean-tree run.

**NOT COVERED, and none of it is hidden.** **Hardware** — nothing here has run on
a Next. Both arms of this discriminator *were* seen on one (build `00.12`,
`reported on hardware`), and T8 does not upgrade that; it makes the emulator half
re-runnable so a regression is caught before it reaches silicon. **The
press-while-stopped case**, which is W6's and is emulator-only by the user's
decision (2026-08-07). **The NMI-count precondition itself**, which no knob can
provoke now that the schedule is checked — the same position T7's is in. **A
stub that wedges only AFTER the liveness key is polled** would pass both halves.
**A WiFi ROM**: the discriminator is `uart_joyport_selection`, which with its key
handler and its row sits under `IF ROM_VARIANT == ROM_VARIANT_UART`. `make test`
builds the UART ROM and `src/mf_rom.asm` — the routine under test — is common, so
the coverage claim holds; aiming T8 at the WiFi build would need other state.
**And the BORDER half is phase-dependent where the byte comparison is not**: a
wedge freezes the border wherever `change_border_color` left it, and it cycles
0..7, so roughly one run in eight it freezes on black and the WEDGED branch does
not fire. Measured: the comparison still goes red, **104 pixels, every one of
them in row 13**, because the reference's "B" repaints `B = Border off` to `on`
and the wedged run never does. The border **names** a wedge; the comparison
**catches** it.
And **M2's own change**: when `nmi66h` learns to accept a software cause, T4 must
be inverted deliberately and T8's expectations re-examined in the same change —
they are about the same routine.

---

## 2026-08-09 — One check's dead connection took the whole suite with it, and the loss was SILENT

**Built, issue #33**, filed by the user from a finding the independent reviewer
of the swap-window branch made while reviewing something else. `main()`'s
per-check loop in `test/dzrp/conformance.py` caught `Unsupported`, `Precondition`
and `dzrp.DzrpError` — and **not bare `OSError`**.

`TcpTransport.write` is a plain `sock.sendall`, so a peer that resets or closes
mid-send raises `BrokenPipeError` or `ConnectionResetError`, **neither of which
is a `DzrpError`**. The exception escaped `main()` entirely.

**THE FAILURE MODE IS NOT A RED, IT IS SILENCE, and that is the whole of why this
was worth fixing.** Everything below the raising check never runs, and **C15 is
last by design** — it is the only check that sends `CMD_CLOSE`. So the suite
stops covering command 2 and reports nothing at all about having stopped. A run
that lost its most fragile check would look like a run that was shorter.

**Demonstrated rather than argued**, with a scratch check raising
`BrokenPipeError` from the position immediately before C15, against two
otherwise-identical trees:

| tree | what happened |
|---|---|
| pre-fix | `Traceback ... BrokenPipeError`, and **C15 absent from the output entirely** |
| fixed | `FAIL CXX INJECTED oserror control — the connection failed mid-check`, then **`PASS C15`**, totals `18 passed, 1 failed, of 19` |

**It is its own `except` clause rather than folded into `DzrpError`**, because the
two say different things and the detail line should too: `DzrpError` is the remote
**answering wrongly**; this is the remote **not being there**. And it is **FAIL
rather than UNSUP**: a check that provokes a disconnect deliberately catches it
locally — `chk_oversize_payload` does, which is what `62d4009` fixed one level
down — so anything reaching this clause did not expect it.

**A SECOND HOLE, ONE LAYER ALONG, FOUND WHILE FIXING THE FIRST.**
`SerialTransport.close()` did not guard `OSError` where `TcpTransport.close()`
does, and `conformance.py` closes through it from a **`finally:`** — so a raising
close escapes the handler that has just caught the real fault and takes the suite
down anyway. Same defect, reached differently. Fixed here rather than filed,
because leaving it would have meant shipping a fix whose own escape hatch leaked.

**What the review established that the fix did not.** `hardware-check.py` runs
`conformance.py` as a **subprocess**, so H2 inherits this automatically and needs
no parallel change; no exception class here derives from `OSError`, so there is
no ordering hazard in the `except` chain; and all 18 check bodies do only
transport I/O, so a bare `except OSError` is not over-broad.

**Rejected.** A blanket `except Exception` (it would swallow assertion errors and
bugs in the checks themselves, which must fail loudly); catching at the call site
of each check instead of in the loop (that is the convention that already existed
and already failed — it is unenforced, and the next check written in that shape
brings the defect back); and filing the `SerialTransport` half separately.

**Test infrastructure only.** No `src/`, no `Makefile`, no ROM byte moves,
**no `make bump`** — checked mechanically. Regression: `make test-dzrp-stub`
**18/18 with W1-W6, exit 0**, on a clean re-run after the injection was removed.

**NOT COVERED.** **The clause has still never fired for a real cause anywhere** —
jnext drains fast enough that no peer resets mid-send, and C16-C18's hardware run
declined the oversize frame in-band without a disconnect. It is
correct-by-construction and exercised only by an injected fault. And `main()`'s
loop is now robust to `OSError` **specifically**; any future check raising
something else unexpected still takes the suite down, which is the same class of
defect waiting for a different exception.

---

## 2026-08-09 — The swap-window fix has a RED-FIRST PAIR ON SILICON, and the red was a Next we destroyed

**Measured, not decided** (user's own Next, `192.168.100.136`), and it is the
strongest evidence this project has ever had for a single fix: the same check,
on the same machine, with the same client, **one build apart**.

| build | C18 — a 12288-byte `CMD_LOOPBACK` | the machine afterwards |
|---|---|---|
| **`00.16`**, before the bound | **FAIL** — *left the remote not serving* | **stub destroyed**: border yellow and **not cycling**, `B` and `R` both dead, **power cycle required** |
| **`00.19`**, as merged | **PASS** — *a 12288-byte payload was declined and the remote served on* | healthy; whole bench **6 of 6**, conformance **18 of 18** |

**THAT RED IS WORTH MORE THAN THE GREEN, because no bench here could ever have
produced it.** The defect — `cmd_loopback` and `cmd_write_bank` walking out of
the 8 KB window at `SWAP_ADDR` into `MAIN_SLOT`, the bank the debugger executes
from — was upstream's since 2020 and had only ever been *measured in jnext*. A
real Next has now been wedged by it, and recovered by the fix, an hour apart.

**The hung state is diagnostic and was read off the machine rather than
inferred.** Yellow is the colour `transport_read_byte` leaves while waiting — the
value bench **N1** asserts (`182,182,0`) — and *not cycling* means `main_loop` was
never reached, which is why the key poll was dead. **`B` and `R` being dead was
PREDICTED from the border colour before it was checked**, and held.

**AND THE FIRST DIAGNOSIS OF IT WAS WRONG, FOR THE REASON THIS FILE KEEPS
RECORDING.** I read the red as *"the bound holds but the stub cannot survive its
own refusal on hardware"*, wrote a mechanism for it (backpressure, `drain_main`'s
100 ms not covering ~267 ms of wire time at 460800), and filed it as
[#35](https://github.com/jorgegv/dezogif_ng/issues/35). **The build under test was
assumed.** A photograph of the screen then showed `build 00.16` in its first line
— the pre-fix ROM, which has no bound at all, so the walk was expected and the
hypothesis was about a code path that build does not contain.

**#35 SHOULD NOT HAVE BEEN OPENED AT ALL** (user, 2026-08-09), and that is the
sharper reading of the same mistake: the build was not merely unverified before
the *diagnosis*, it was unverified before an **outward-facing, public** claim that
shipped code was defective. It is closed as `not planned`, carrying the
retraction, rather than deleted — the correction is worth more visible than
absent. **Verify before you file, not only before you conclude.**

**The lesson is one this project already owns and I had applied twice the same
evening in a different organ**: ERRORS.md's *prove which file ran*. Hours earlier
a bench reporting **15 checks instead of 18** had revealed a run executing in the
wrong worktree, and every bench invocation after it was pinned with `make -C`. The
identical discipline was then not applied to the hardware — where the build number
is **the first line of the screen**, free to read. **Ask for the banner before
interpreting a hardware run.**

**Measurements, and they reproduce the 460800 figures for a fourth time**: H1 in
**30 ms** (against 242-1037 ms across the evening's runs), H4 median **6.3 ms**,
H5 **20.0 KB/s** round trip. C16's 8192-byte `CMD_WRITE_BANK` and C17's
**16384-byte** `CMD_WRITE_MEM` both round-trip intact — and that was the
scheduled question, because C17 is **four times** the largest payload that
established the rate ceiling, on the same per-byte receive path whose cost the
sweep bracketed at 470-610 T-states. **The margin is there.**

**`Error: payload too big for databank` WAS DRAWN ON A REAL NEXT AND READ BY A
HUMAN** — `ERROR_PAYLOAD_TOO_BIG` (`src/ui.asm:28`, text at
`src/data_const.asm:195`), the code this branch added, on its first hardware
outing. **H6 nevertheless reports the error area CLEAN, and that is not a
contradiction**: `cmd_init` clears `last_error`, and C15's follow-up `CMD_INIT`
runs before the bench reads the screen. Recorded because a future reader meeting
`H6 clean` could otherwise conclude no error was ever raised.

**NOT COVERED, and none of it is hidden.** **The `OSError` arm of
`chk_oversize_payload` was still never taken** — the oversize send completed and
the remote declined it in-band, so the fix for that (issue #33's sibling) remains
correct-by-construction rather than exercised anywhere. **The UART build's half**
of the same common-code path: `commands.asm` is shared, but no hardware run has
ever driven the serial ROM. **`00.18`'s idle sweep** was in the same ROM and
nothing here exercises it — its 300 s period has still never been watched
anywhere, and no bench stages the vanished peer it exists for. **One machine, one
ESP-01, one reporter**, as ever. And the **two red dots** seen mid-right on the
destroyed `00.16` screen are **still unexplained**; they did not survive the power
cycle and H6 read clean afterwards, which is consistent with transient damage from
the overwrite but does not establish it.

**Cost: documentation only.** No `src/` change, no ROM byte moves, **no `make
bump`** — checked mechanically.

---

## 2026-08-09 — A client could hand itself the running debugger to overwrite, and adding a big-transfer check is what found it

**Built.** `cmd_loopback` and `cmd_write_bank` refuse a declared length that
would run past the 8 KB swap window; the conformance suite gains **C16**, **C17**
and **C18**, and C5's sweep now ends at **8192**.

**THE DEFECT IS AN UNBOUNDED, CLIENT-CONTROLLED WRITE OVER THE DEBUGGER'S OWN
BANK, AND IT IS UPSTREAM'S, IN BOTH ROMS, SINCE THE FORK.** Both handlers buffer
into a bank paged at `SWAP_ADDR` — `SWAP_SLOT*0x2000` = **`0xC000`**, an **8 KB**
window — and walk upward for as many bytes as the FRAME DECLARED. `cmd_loopback`
counts `receive_buffer.length` down with `ldi (hl),a` counting up; `cmd_write_bank`
hands the same number to `receive_bytes`. Neither bounded it. One byte past the
window is `0xE000`, which is `MAIN_SLOT`: `MAIN_BANK`, the bank the debugger is
**executing out of**. So a `CMD_LOOPBACK` of 8193 or more overwrites the running
debugger with the client's own payload.

**MEASURED, NOT REASONED — and the control is the whole of the evidence.** The
same 18 checks against `main`'s WiFi ROM:

| | main's ROM | as built |
|---|---|---|
| C5 at **8192** | pass | pass |
| C16, C17 | pass | pass |
| **C18** at **12288** | **FAIL — "left the remote not serving"** | pass |
| C15 behind it | **FAIL — timed out after 0 of 1 bytes** | pass |

C15's red is a **consequence and not a second finding**: the stub is dead by
then. And C16/C17 passing on both sides is what says C18's red is the guard
rather than the new checks — one variable.

**IT SURVIVED FIVE YEARS BECAUSE NOTHING EVER SENT A BIG ENOUGH FRAME, AND THAT
IS THE PART WORTH KEEPING.** DeZog's loopback is a handful of bytes and this
suite stopped at **4096**, so every payload in every green run had been
comfortably inside the window. The one thing that would have found it is a suite
pushing 8 KB — which is exactly what C16 and C17 were added for, and they found
it on their first run. **The check was not written to look for this**; the bound
became reachable and the bug fell out. That is the same shape as
[[ERRORS.md]]'s "a bound the emulator can never reach is a bound with no test",
one layer up: a bound no *test data* can reach is equally untested, and the fix
is the same — make the input reach it.

**C16 AND C17 ARE NOT AN EXTENSION OF THE LOOPBACK SWEEP, DELIBERATELY.** A
`CMD_LOOPBACK` exercises receive **and** send; **C16** (a full 8192-byte
`CMD_WRITE_BANK`, which is what DeZog sends on every F5) and **C17** (16384
bytes in one `CMD_WRITE_MEM`) are **receive-only**, which is the path that
brackets the UART ceiling at 470-610 T-states per byte and the reason the
2026-08-09 baud entry says whoever raises that ceiling must optimise it. C17 is
also the only check that writes **across a slot boundary** in one command, which
is `memory_loop`'s banking.

**WHY THE STUB ANSWERS NOTHING RATHER THAN AN ERROR, which is the one decision
here that is a judgement rather than a fact.** DZRP has no error response for
either command — `CMD_LOOPBACK`'s reply IS the data, and `CMD_WRITE_BANK`'s error
field cannot be reached without consuming a payload we have just refused to
read — and a reply of the wrong length **desynchronises the stream for every
command after it**. So `error_payload_too_big` takes `error_write_main_bank`'s
established route: report on the Next's own screen, `jp drain_main`, let the
client time out. **That is the same silence issues #8 and #9 called a defect**,
and the difference is stated in the source: there the stub refused a command a
real client legitimately sends, here the frame cannot be honoured by any means
and the alternative on offer is not a better answer but a corrupted debugger.
C18 accordingly asserts **survival, not an answer** — a remote that replies
passes too; what it refuses is one that stops serving.

**A SECOND DEFECT FELL OUT, IN THE TEST CLIENT, AND IT IS THE SAME DISEASE ONE
LAYER OUT.** `dzrp.py`'s `MAX_FRAME = 9000` refused C17's own correct 16385-byte
response as a desync. Its comment justified the number from **`CMD_LOOPBACK`'s**
8192 cap — reasoning that never covered `CMD_READ_MEM`, which is bounded by its
own 16-bit size field. One number was doing **two jobs**: a *discriminator*
deciding whether a leading `0xA5` was a preamble or a length's low byte, where
smaller is sharper; and a *sanity bound* on a length whose framing is already
settled, which must admit the largest legal frame. Split into `MAX_PROBE_FRAME`
(9000, unchanged) and `MAX_FRAME` (70000, above the largest useful
`CMD_READ_MEM`).

**Rejected.** Reading C17 back in 8 KB chunks to dodge that bound (it would have
hidden a client defect that will bite the next person to read a large region);
raising `MAX_FRAME` globally (it blunts the start-byte discriminator, which is
the one place a small bound is load-bearing); making `cmd_loopback` **stream**
rather than buffer, which removes the bound entirely (it would make it a fourth
member of issue #13's interleaving family, where a response flushing mid-message
while its own payload is still owed is the one window in which payload reaches
`esp_watch_line`); a short reply for the refused case (desync); reusing
`ERROR_RX_OVERFLOW` to save the string bytes (it means a UART FIFO overflow, and
conflating two faults in the one place a user looks is what the error area is
for); and filing the bound as its own issue while landing only the checks —
offered, and the user's call was to fix it here.

**Cost: +60 bytes in BOTH ROMs, which is correct for common code.** `main_end`
UART 0xF21F → **0xF25B**, WiFi 0xFBF4 → **0xFC30**. Pinned: UART
`e2818821…` → `e9f0a0d3…`, WiFi `9c4abc1d…` → `661094ed…`. **The UART
byte-identity gate is EXPECTED to break here** — `commands.asm`, `constants.asm`,
`data_const.asm` and `ui.asm` are all common code — as it did for issues #7, #8,
#9, #12, #20 and #31. **This changes a ROM, so the merge carries a `make bump`.**

*(**CORRECTION, and it is about this branch's own record rather than its code.**
The bump commit for it — `00.19` — says "issue #33-class". **THAT REFERENCE IS
INVENTED.** This work never had an issue at all: it was found by adding C16/C17,
not by anyone filing it, and the repository stopped at #32 when the message was
written. The house rule being no `--amend`, it cannot be taken back, so it is
retracted here, in the file CLAUDE.md designates read-first.*

*(**AND THE RETRACTION WENT STALE WITHIN THE HOUR, WHICH IS THE PART WORTH
KEEPING.** Its first version said "there is no issue #33" and told a reader to
stop. **There is now**: filing this session's two review follow-ups minted
[#33](https://github.com/jorgegv/dezogif_ng/issues/33) — `conformance.py`'s
`main()` not catching bare `OSError` — and #34. So the dangling reference became
a **resolving** one that points at something else entirely, which is strictly
worse than a dead link: a reader who follows it finds a real, plausible issue and
has no reason to doubt it. **The invented number was falsified by my own next
action**, an hour later, in a correction whose whole subject was inventing
references. Two lessons, and the second is the one that generalises: a specific
reference is a claim, and inventing one is cheapest in the place nobody reviews —
a commit message; and **a correction that asserts a fact about the world can go
stale exactly like the claim it corrects**, so retract by saying what was written
and why it was wrong, not by asserting what a reader will find.)*

**Regression: `make test-dzrp-stub` 18/18 with W1-W6, exit 0**, re-run **on the
rebased tree**, which is not the same thing as the pre-rebase green: branch A's
idle tick sits underneath this branch now, so the earlier runs described a tree
that no longer existed. Measured after the rebase: **18/18 with W1-W6 twice**,
`test-slot-recovery` **7/7** — the first run anywhere of #24's sweep and this
bound in one ROM — and `make test` **7/7**.

**W5 FAILED ITS PRECONDITION TWICE ON THIS TREE BEFORE PASSING TWICE**, and that
is recorded rather than smoothed over. The `+IPD` collision it races for did not
arise in runs 1 and 3; it did in 4 and 5, and `main` passed it in between. So the
2026-08-07 note that W5 is flaky stands, now at 2 of 4 rather than 1 of 3 — but
note the flake was **not** dismissed on that precedent: the tally was gathered
first, because branch A's idle tick had just been added to `main_loop`, which is
exactly where the stub sits between the fixture's 8 ms-spaced writes, and a
plausible mechanism for a real regression existed. `DZRP_SPLIT_GAP` would have
made it pass on demand and was deliberately not used — tuning a race until it is
green is weakening a check to make it pass.

**NOT COVERED, and none of it is hidden.** ~~**Hardware** — C16, C17 and C18 have
never run on a Next, and C17's 16 KB is the largest inbound payload this project
has ever sent anywhere.~~ **CLOSED THE SAME DAY, AND WITH A RED-FIRST PAIR ON
SILICON** — see the entry at the top of this file: `00.19` answers all three on a
real Next, and `00.16` was **destroyed** by C18 on the same machine an hour
earlier. C17's 16 KB remains the largest inbound payload this project has ever
sent anywhere, and it now survives at 460800. **The other users of a client-declared
length WERE audited, and the scoping is narrower than it needed to be.** Every
consumer of `receive_buffer.length` in `commands.asm` was enumerated
mechanically, and the rest are immune for a structural reason rather than by
luck — **but by TWO mechanisms rather than one, and an earlier version of this
paragraph named only the first and attached it to all four handlers.**

* `cmd_read_mem` (`commands.asm:594`) and `cmd_write_mem` (`:630`) go through
  **`memory_loop`** (`backup.asm:321-338`), which splits a transfer at `0xE000`
  and runs the high phase through `SWAP_SLOT`.
* `cmd_set_breakpoints` (`:873-890`) and `cmd_restore_mem` (`:955-970`) do not
  call it **at all**. Each carries its own dot-local `.page_in_bank` making the
  same decision per address — `cp HIGH MAIN_ADDR`, then `slot_backup.slot7` into
  `SWAP_SLOT`.

**AND IT TAKES TWO DIFFERENT THINGS TO MAKE THEM SAFE, WHICH THE FIRST VERSION
OF THIS CORRECTION ALSO GOT WRONG** — by naming `and 0x1F` / `add HIGH
SWAP_ADDR` as load-bearing in both copies. That pair establishes a correct
**starting address**; it is not what bounds a **count**, and the distinction
falls exactly where this branch's defect lives:

* In `cmd_set_breakpoints` and `cmd_restore_mem` the pair really is the whole of
  it, because each entry is a fixed-size record carrying its **own** fresh
  16-bit address, re-masked every entry (`commands.asm:886-887`, `:966-967`).
  No growing entry count can escape the window.
* In `memory_loop` the pair runs **once**, on first entry to phase 1
  (`backup.asm:331-332`). Every later phase-1 re-entry sets `ld hl,SWAP_ADDR`
  outright (`:356-357`) and never re-masks. What stops an unbounded client
  `DE` from walking HL out of the window is a **separate** check the citation
  above does not reach: `.inner_loop`'s own `cp 0x20*(SWAP_SLOT+1)`
  (`backup.asm:377-380`). And `DE` genuinely is unbounded on the way in —
  `payload_read_mem.mem_size` (`commands.asm:581`, `:591`) and
  `cmd_write_mem`'s computed length (`:619-624`) both come straight off the
  wire with no cap.

So the routine among the four that is actually exposed to an unbounded declared
count is protected by the one mechanism the sentence did not name.
`cmd_exec_asm` already carried its own bound against `PAYLOAD_EXEC_ASM`. What
made `cmd_loopback` and
`cmd_write_bank` the two is that they buffer **straight into `SWAP_ADDR`** with a
plain `receive_bytes` loop and no address translation at all. So the fix is
exactly as wide as the defect.

**THE CORRECTION IS WORTH MORE THAN THE CLAIM IT REPLACES.** It was found by the
independent reviewer doing mechanically what the first version merely *said* it
had done: `grep -n memory_loop src/commands.asm` returns **two** call sites, not
four. Left standing it would have told a future session that `memory_loop` is the
single point of protection for all four handlers — so a change to it would be
audited and the duplicated copy would silently not be. A plausible mechanism
stated instead of a traced one, with a specific but inapplicable line citation,
in the one file every session is told to read first and treat as ground truth.
[[ERRORS.md]] names the disease; this is the instance. **The safety conclusion is
unchanged** — both handlers really are immune — which is exactly what makes this
kind of error survive.

**AND THE FIRST ATTEMPT TO CORRECT IT REPEATED THE DISEASE ONE LAYER DOWN**,
which is the part most worth keeping. Having been caught naming the wrong
*function*, I named the wrong *instructions* — a masking pair that is genuinely
load-bearing in two of the three copies and merely sets a starting address in the
third, the third being the only one exposed to the unbounded count this whole
branch is about. Both errors were found the same way, by a reviewer tracing the
control flow instead of reading the claim; and both were plausible precisely
because the conclusion they supported was true. **A correction is not exempt from
the standard it is correcting.** **The error
text itself** is drawn by no check; nothing reads row 15 back for this code, and
the 32-column fit is by inspection. And **what a real client does with the
silence**: DeZog has never sent an oversize frame and there is no reason it
would, so the refusal path's user-facing behaviour is unexercised by anything
but C18.

---

## 2026-08-09 — The slot sweep gets a trigger a quiet stub can reach, and it is NOT the one the issue asked for

**Built, issue #24's second half.** `esp_idle_tick` runs once per turn of
`main_loop` and, after `ESP_IDLE_SWEEP_SECS` of the stub being idle with **no
DZRP session and nothing arriving**, calls the `AT+CIPCLOSE` sweep issue #19
built. Once per idle period, not once per period for ever.

**THE MECHANISM ALREADY EXISTED AND COULD NOT BE REACHED, which is the whole
of what this closes.** `esp_recover` fires on `ESP_FAULT_LIMIT` consecutive
faults counted in exactly one place, `rxtx_error` — and the state that strands
a user raises **none**: a new client never completes the module's handshake so
the stub sees no bytes to time out, the leaked peers are silent by
construction, and an unprompted send to a stale id takes `esp_wait_prompt`'s
`ERROR` arm and returns quietly. Structurally unreachable rather than merely
unlikely, and #19 shipped a sweep nothing could call.

**THE ISSUE ASKED FOR A CONNECT-TIME TRIGGER AND IT CANNOT BE BUILT.** #24 and
`KNOWN-ISSUES.md` #19 both name it as the cheaper option. Two reasons, either
sufficient. It closes the OTHER link ids when a client arrives, and
this suite deliberately holds several at once — `test/dzrp/queued-commands.py`
opens **three** and INITs every one, `split-command.py` holds **two** across its
exchange, and hardware H3 two — so bench checks W4 and W5, and H3, would go red
for a change that broke nothing they were written to measure, retiring the
multi-client coverage issues #11 and #13 exist for. And
it **cannot reach the terminal state anyway**: by then no client can connect,
so nothing triggers it. `KNOWN-ISSUES.md` says that second half in as many
words and nobody had joined it to the first.

**A PERIODIC TRIGGER CAN REACH IT, and that is the reason to prefer it rather
than a preference.** The terminal state leaves the stub sitting in `main_loop`
with nothing able to get to it, which is the one place a timer still runs.

**WHAT MAKES A TIMER LEGAL where "close on suspicion" is forbidden** (#24's own
*What NOT to do*, and `KNOWN-ISSUES.md` #19): it does not run while a session
is open. `esp_idle_tick` returns before counting for as long as
`esp_session_valid` is set, so a DeZog session parked at a breakpoint — silent
for minutes and perfectly healthy — can never add up to a sweep. With no
session there is nothing to close on suspicion *of*.

**THE CLOCK IS NR `0x1E` BIT 0** — bit 8 of the active video line counter — and
one tick is one frame, taken on its 1→0 edge. Free-running and ungated: no
IFF1/IFF2, no DI, no NMI, which is what makes it the only usable clock in a
debugger that runs with interrupts off and the ROM's `FRAMES` sysvar dead. One
byte, which also avoids the tearing a two-byte read of NR `0x1E`/`0x1F` has at
that rollover. **The border-colour countdown is NOT reused** — it counts
*iterations*, and `transport_byte_available` can spend ~100 ms inside one.

**IT WAS NR `0x1F`'s LOW BYTE AND THE CALIBRATION WAS WRONG BY NEARLY A FACTOR
OF TWO — caught by the independent reviewer, with a VHDL citation already
attached to the wrong answer.** I counted a tick as 256 lines, on the reading
that the low byte wraps only on an 8-bit overflow, and derived 61 a second from
the length of a line. But `cvc` does not run to 511: it **resets at `c_max_vc`**
(`video/zxula_timing.vhd:457-470`), which is 319, 311, 310 or 263
(`:168,204,238,270,298`) — **never a multiple of 256** — so the low byte
decreases **twice** per frame, once at line 256 and once at the reset. The real
rate was ~100 a second against a constant built for 61, and the shipped 300
seconds would have fired at about **180**.

**The fix is a better tick rather than a corrected multiplier**: bit 8 gives
exactly one edge per frame **by construction**, because every value the counter
can be reset to is below 256 (0 at the maximum, and NR `0x64`'s 8-bit offset at
the vactive anchor) while `c_max_vc` is at least 263. So it holds for every
timing mode and every value of NR `0x64`, with no arithmetic to get wrong.
50 a second at 50 Hz and 60 at 60, i.e. a period five sixths of nominal on 60 Hz
timing — **a real spread, said out loud**, where the old comment claimed 3%.

**THE BENCH CANNOT CATCH THIS AND THAT IS THE LESSON**, which the reviewer
pointed out and is worth more than the arithmetic: S4-S7 assert that a sweep
*happens* within a generous wall-clock window, so they pass whether the constant
is right or wrong. A calibration is not behaviour, and nothing here observes it.
The only check on it is the derivation, which is exactly why it had to be
correct and was not. **A citation next to a number is not a check of the
number** — [[ERRORS.md]] carries "a citation is not a quotation"; this is its
arithmetic cousin.

**300 seconds, bounded from both sides rather than picked.** It must be well
under the module's own `AT+CIPSTO` reap — 1800 since this same issue's first
half — or the module gets there first and this buys nothing; and far longer
than any gap in a live session, which the session guard already covers. Five
minutes is an order of magnitude inside both.

**THE SWEEP DOES NOT RETIRE THE LISTENER, and that is the one difference from
`esp_recover`'s.** In the state this exists for the listener is still up and
simply has no slots to hand out, so taking it down would remove the only thing
that can bring a user back. It costs one client's connection if it lands
mid-sweep, bounded by one sweep, which is why the trigger fires once per idle
period. `esp_close_all_links` is factored out of `esp_recover` so both callers
run the identical loop — measured: the control build is **+8 bytes**, exactly
the two calls and two rets, and S1-S3 are unchanged.

**Evidence: `make test-slot-recovery`, now 5 runs and 7 checks, 7/7.**

| | subject | measured |
|---|---|---|
| **S4** | fires with no fault anywhere | `closes=5 recoveries=0`, fresh client served |
| **S5** | fires **once** over many periods | exactly 5, one per link id |
| **S6** | does **not** fire while a session is open | `during_session=0`, `after_disconnect=1` |
| **S7** | the control, `IDLE_SWEEP=0` | `closes=0` |

**S4'S ATTRIBUTION IS THE ABSENCE OF `AT+CIPSERVER=0`**, which is what
separates the idle trigger from a recovery that swept for its own reasons — and
it is why the two idle ROMs keep the **shipped** fault limit rather than S1's
`FAULT_LIMIT=1`. S6 carries **its own control in the same run**: the client
disconnects and a sweep must follow, without which a run that was simply too
short would pass.

**S6'S FIRST VERSION FAILED A STUB THAT WAS BEHAVING, and it is only in this
file because it failed in the direction that goes RED.** It counted every
`AT+CIPCLOSE` in the run and charged them all to the hold — but the stub is
idle from the moment it comes up and headless jnext runs several emulated
seconds per wall second, so with a ten-second probe period it had **already
swept before the client connected**: the sweep at 18:31:38.96 against the
client's first frame at 18:31:39.54, read out of jnext's own log rather than
guessed. The baseline is now taken when the session opens, through a sentinel
the client writes. **The log was consulted before the code was touched**, which
is what stopped this being "adjust the bench until it is green" — [[ERRORS.md]]
carries that as its own entry, and the tell is that the failing check was
*mine* and the ROM was not.

**IDLE_SWEEP is the EIGHTH build seam** of the `ESP_IP_MAX` / `ESP_RX_WAIT` /
`ESP_TX_PASSES` / `TRANSPORT_WAIT_RX_SECONDS` / `ESP_FAULT_LIMIT` /
`ESP_LINK_IDS` / `ESP_SERVER_TIMEOUT` / `ESP_CIPSTO_STRICT` family, for the
same reason every time: five minutes per check is not a bench anyone runs, and
the behaviour a check must be shown red against has to be reachable by a
**build**.

**`TRANSPORT_IDLE_TICK` is a new macro on the transport interface**, and a
macro rather than a call because `main.asm` is common code and the UART build
must not pay for an empty subroutine on every turn of the idle loop. It joins
`TRANSPORT_DEACTIVATE` and the framing and session macros. UART mode expands it
to nothing, deliberately: there is no module under a joy-port cable and no
per-connection resource to leak.

**Rejected.** The connect-time trigger (above — unbuildable, and it cannot
reach the terminal state); building nothing at all and closing #24 on the
`AT+CIPSTO` half (defensible, and it was offered — the module does reap on its
own — but this same issue's first half stretched that self-heal from ~3 minutes
to ~30, which is what makes a stub-side trigger worth its bytes again); calling
`esp_recover` wholesale from the idle path rather than the sweep alone (it
retires the listener and re-runs the whole AT chain, so a periodic action could
paint "ESP-01 setup failed" over a module that was fine); resetting the tick
counter when a session opens rather than freezing it (freezing means a client
that vanishes is swept for that much *sooner*, which is the case this exists
for); and a repeating sweep (a refusal window every five minutes for as long as
the machine is switched on).

**Cost: WiFi +66 bytes** (`main_end` 0xFBF4 → 0xFC36, **618** free to the
identity block). **The UART ROM is byte-identical** to `main`'s pinned
(`e2818821…` both sides, `build/*.bin` deleted first), which is what says
nothing leaked across the transport boundary: `esp_idle_tick` is in the WiFi
build only and the macro expands to nothing in the other. **This changes a ROM,
so the merge carries a `make bump`.**

**NOT COVERED, and none of it is hidden.** **The tick rate itself** — no run
anywhere measures it, and S4-S7 would pass against any calibration, so the 50
a second rests on the VHDL argument above and nothing else. **A connection with
no session on it**: `esp_session_valid` is set by `CMD_INIT`, so a peer that
connected and never introduced itself is swept once nothing at all has arrived
for the whole period. Deliberate — "a socket is not a session" is bench check
N1's position and issue #23's — and narrower than it sounds, since **any**
inbound frame from **any** connection restarts the timer.

**AND THE CONVERSE, WHICH IS THE LIMIT ON WHAT THIS BUYS AND WHICH THE FIRST
VERSION OF THIS ENTRY NEVER NAMED: the sweep cannot fire for KNOWN-ISSUES.md
#19's own headline case.** `esp_session_valid` is cleared by exactly two things —
`CMD_CLOSE`, and the module reporting `<id>,CLOSED` for that same session — and a
peer that **vanishes** sends neither, which is what "vanishes" means. So when the
connection that went silent is the one that most recently sent `CMD_INIT`, the
gate stays set, `esp_idle_tick` never counts a tick, and **no sweep ever happens**
until the module's own ~1800 s reap produces a `<id>,CLOSED` — if it announces
one, which is unverified. What the trigger reaches is the other shapes: a socket
that never introduced itself, and one superseded by a later session that closed
cleanly. Both are real, and both are what S4-S7 stage — `--mode hold` ends in a
plain `t.close()`, i.e. a FIN and an immediate `<id>,CLOSED`, so **no bench here
stages a vanished peer at all**.

**That is the guard working rather than a hole in it**, and it must not be
"fixed": sweeping while a session looks open is the close-on-suspicion that
KNOWN-ISSUES.md #19 and #24's own acceptance criteria both forbid. It does mean
the five minutes is not a general replacement for the module's thirty, and
KNOWN-ISSUES.md's "What to do" and "What would reopen it" are written against the
thirty for that reason — a reopen criterion built on five would have fired on
correct behaviour every time the vanished peer held the session, which is the
common shape rather than an exotic one. Found by the independent reviewer, from
the three writer sites of one byte; I had documented the exposure and not its
mirror image. **That the sweep
REPAIRS anything** —
no emulator run can leak a slot to a peer that vanished or make the module
unresponsive, so every green check here shows the *mechanism fires* and never
that it recovered a module in trouble, which is the wording #24's acceptance
criteria ask for. **Real hardware**: nothing here has run on a Next, and the
five-minute period has never been watched anywhere — the shipped value is
reasoned from the module's 1800, and every bench runs at 10. **The shipped
`ESP_IDLE_SWEEP_SECS` itself**, for the same reason `ESP_SERVER_TIMEOUT`'s 1800
is unmeasured as a policy. **A fault raised INSIDE the idle sweep** escalates to
`esp_recover` through `rxtx_error` exactly as a fault from
`transport_byte_available` already can from the same loop — deliberate, and not
staged by any run. And **association loss**, which #24 also listed: split out
into its own issue, because jnext's module is permanently associated
(`AT+CWJAP?` is query-only, `STA_IP` is a `static constexpr`) so no headless run
can produce it.

---

## 2026-08-09 — The shipped link is 460800 now, and the criteria were met rather than waived

**Decided (user) and built.** `ESP_BAUD_HIGH` defaults to **460800** instead of
`ESP_BAUDRATE`, so the shipped WiFi ROM greets the module at 115200 and then
negotiates the link up. The entry below this one decided the opposite on
2026-08-09 and is annotated rather than rewritten: **what changed is the
evidence, not the reasoning** — its case for *why not higher* is untouched and is
why this is 460800 and not the 1000000 the work was commissioned for.

**THE SIX CRITERIA WERE WRITTEN BEFORE THE MEASUREMENT AND WERE MET, WHICH IS THE
ONLY REASON THIS IS A DECISION AND NOT A PREFERENCE.** All on the user's own Next
at build `00.16`, and **the build is load-bearing**: at 460800 an earlier ROM
draws its own screen wrong (issue #31, the undeclared font buffer), so criterion
1 — "the screen must read 460800" — could not have been read honestly off it.

| | criterion | result |
|---|---|---|
| 1 | screen reads 460800 | yes, and **clean** |
| 2 | H2 = 15/15 on **three** runs | **five** runs, 15/15 every time |
| 3 | H6 clean, not `RX Overflow` | 0 bright-red pixels, all five |
| 4 | H5 median >= 2x the 8.3 KB/s baseline | **20.3 KB/s = 2.45x** |
| 5 | H4 not materially **worse** | **6.6 ms against 11.2 — 41% better** |
| 6 | M1, `R`, M1 | came back up, **and the probe was shown to fire** |

**CRITERION 5 CARRIED A PREDICTION AND THE PREDICTION WAS WRONG**, which is worth
more than the criterion passing: it said to expect latency *unchanged* because
11.2 ms is WiFi round trip rather than wire time. It nearly halved. A material
part of that figure was the wire after all, and the same mistake — reasoning
about where a cost lives instead of measuring it — is what this file records
against the 1 Mbps ceiling one entry down.

**CRITERION 6 IS THE ONE THAT COULD NOT HAVE BEEN FAKED, and it is the first time
that code has run anywhere.** The bring-up probe is structurally dead in jnext,
whose module answers the first greeting every time. It matters because a soft
reset leaves **both ends** at the raised rate — the prescaler survives
(`zxnext.vhd:3361-3367`) and the `R` key's `nextreg REG_RESET,01b`
(`src/ui.asm:52`) has bit 7 clear, so the ESP is not reset either — while a fresh
`esp_uart_init` assumes 115200. Without the probe that press paints "ESP-01 setup
failed" on a healthy module, power-cycle only.

**And it was shown to have FIRED rather than assumed, which behaviour alone
cannot do**: a module still at 460800 reaches the screen's "460800" through the
probe, and a module back at 115200 reaches the identical screen by ordinary
greeting plus negotiation. The discriminator was `.UART` getting **no answer** at
115200 between the reset and the second press, against `OK` after a power cycle.
**That rests on one cited premise** — that `.UART` sets the link to 115200 itself
rather than inheriting the prescaler (`doc/WIFI-SETUP.md:148`) — and is labelled
as a premise rather than smuggled in as an observation, which took two review
rounds to get right.

**THE BENCH HAD TO MOVE WITH THE DEFAULT, AND THAT IS THE PART THAT IS NOT ONE
LINE.** `test-baud`'s **L3** asserts "the negotiation assembled OUT" and was
pointed at the *shipped* ROM. Flipping the default makes the shipped ROM
negotiate, so **L3 would have gone red against its own subject** — a check whose
meaning changed silently under it. It now builds and uses an explicit
`BAUD_HIGH=115200` ROM, which is also the escape hatch to ship a machine that
cannot sustain the rate. Everything else that uses the shipped WiFi ROM now runs
at 460800 and was re-run for that reason, not as a formality.

**Rejected.** Leaving it off with 460800 as a documented opt-in (the criteria
were written precisely so that meeting them would settle this, and waiving them
after they were met would make the list decoration); flipping to 921600 as well
(it needs the per-byte **receive** cost below 300 T-states from a figure
bracketed only as 470 < C <= 610 — an optimisation, not a constant); pointing L3
at the shipped ROM and weakening its assertion (that is weakening a check to make
it pass); and `AT+UART_DEF=`, still, for the reason one entry down — it persists
into flash, so a rate that turns out not to work hands the user a module the stub
can no longer greet.

**Cost: the UART ROM is byte-identical to `main`'s pinned** (`f6158368…`), which
is what says nothing leaked — `ESP_BAUD_HIGH` reaches the WiFi build only. WiFi
moves, **so the merge carries a `make bump`**.

**Regression: `test-baud` 5/5, `test-dzrp-stub` 15/15 with W1-W6,
`test-client-status` 7/7, `test-no-hang` 4/4, `test-tx-patience` 3/3,
`test-screen-agreement` all green, `test-cipsto` 4/4, `make test` 7/7,
`test-unit` 5/5, both variants `check-reproducible`** — plus `test-ip-boundary`
2/2 and `test-slot-recovery` 3/3 re-run by the reviewer.

**NOT COVERED, and it is thinner than the green suggests.** **One machine, one
ESP-01, one reporter** — there is no second Next anywhere in this evidence. **A
marginal link that ACCEPTS the rate and then corrupts bits**, which is named
separately because "a second module" does not convey it: every failure the six
criteria cover is a *clean* one, where the module refuses or goes quiet and the
fallback catches it; a unit with a worse crystal or more RF noise could take the
command and misbehave on the wire, surfacing as DZRP desynchronisation rather
than as a rate fault. **The DeZog `.nex` load**, which was done and is the
weakest item on the page: it worked and felt faster, with no timing captured and
no artefact. And **`test-esp`, `test-mfselect` and `test-mfinstall` were not
re-run** — judged unaffected, not shown to be.

---

## 2026-08-09 — The bank had a 768-byte buffer nothing declared, and the assembler could not see it

**Built, issue #31 — and the headline is that the baud rate had nothing to do
with it.** `main_bank_entry` copied the 0x300-byte ZX font into the top of
`MAIN_BANK` at `0xFD00 - MF.main_prg_copy` = **`0xFBC0`**, and `text.init`
pointed `font_address` 0x100 lower so a character code indexed it directly.
**Nothing in the source emitted a byte into that region**, so the assembler had
no idea it was occupied, and all three `ASSERT`s on `main_end` guarded `0x10000`,
`0xFF00` and `ROM_MAGIC_ADDR` — **every one of them 736 bytes too loose**.

Past `0xFBC0` the debugger's variables and the glyph bitmaps for **space** and
**`!`** are the same memory, in both directions: the font copy destroys the
variables at boot, and every later write to one of them draws itself into the
glyph. `BAUD_HIGH=460800` costs 145 bytes, which took `main_end` to `0xFBCF` —
**15 bytes over** — and that is the whole of why the rate appeared to matter.

**EVERY CAPTURED BYTE IS ACCOUNTED FOR, WHICH IS WHAT MAKES THIS A MECHANISM
RATHER THAN A STORY.** The corrupt space glyph read `00 30 00 00 00 00 30 33`:

| offset | address | symbol | value |
|---|---|---|---|
| 1 | `0xFBC1` | `text_one_char.char` | `0x30` = `'0'` |
| 3-5 | `0xFBC3` | `text_core_version`'s `AT` prefix | zeroed by the font copy at boot, never rewritten |
| 6-7 | `0xFBC6` | `text_core_version.major` | `"03"` — the machine's own core version |

And the corrupt `i` of "WiFi" at row 0 column 14 is **the real `i` XOR the real
`0`**, checked against the font read off the user's own machine: the font copy
zeroed `text_one_char`'s **y coordinate** (it sits at `0xFBC0`), so it printed
its `'0'` at row 0. **That retires the previous session's "it is not correct
glyph XOR junk"** — it is exactly that, and the junk is the `'0'` glyph. The
earlier test looked for the other operand in the font and the operand was there.

**THE FIX RECLAIMS THE BUFFER RATHER THAN GUARDING IT** (user's call, offered
against two cheaper options). `text.init` points at `ROM_FONT` and the `MEMCOPY`
is gone, so the bank gets its top 768 bytes back: **WiFi headroom 119 → 818,
UART 2496 → 3201**, and the `BAUD_HIGH` probe ROMs assemble again — the first
`ASSERT` I wrote, at the true bound, had made `make test-baud` unbuildable, which
is what the independent review rejected it for.

**WHAT IT COSTS IS THAT PRINTING NOW DEPENDS ON MACHINE STATE A COPY MADE IT
IMMUNE TO**, held by `text.font_map` / `text.font_unmap`:

* **MMU slot 1** must map ROM. It has **no backup anywhere** — `slot_backup`
  holds slots 0 and 7 only, and `cmd_get_registers` reads slots 0-6 **live from
  the MMU** — so a slot left wrong is both reported wrong to DeZog and handed to
  the debuggee on its next `CMD_CONTINUE`. **Issue #26, one slot along.**
* **NR `0x8C` bit 5** locks the Alt ROM to its 48K half, which is the only half
  `copy_modify_altrom` ever writes. Without it the half served follows port
  `0x7FFD` bit 4 (`zxnext.vhd:2981-3006`). **That is also, mechanically,
  upstream's "your program cannot use any of the other ROMs" constraint** — the
  patched image carrying the `RST 0` hooks is in that one half too. One cause.

**AND NR `0x8E` IS DELIBERATELY NOT USED, WHICH THE VHDL HAD TO SETTLE.** Writing
it — or ports `0x7FFD`/`0x1FFD`/`0xDFFD`/`0xEFF7` — **re-derives MMU0 and MMU1
from scratch** (`zxnext.vhd:3811-3814`, `:4619-4645`) and would silently undo the
slot just set. `copy_altrom` survives only because it writes NR `0x8E` *before*
its MMU writes. NR `0x8C` is in no such list and reads back exactly
(`:6155-6156`), unlike NR `0x04`. Two exposures needed **nothing**: Layer 2 is
already off for the session (`save_layer2_rw`), and DivMMC outranks the Alt ROM
in the same arbiter but the `RST 0` breakpoint path already depends on it being
absent.

**`show_ui` IS WRAPPED AS A SHELL, NOT GIVEN A PROLOGUE AND EPILOGUE**, because
its body has **two** exits — an early `ret z` and a tail `jp` into
`print_string`. A restore written at "the end" runs on one of them, which is
[[ERRORS.md]]'s "Enumerating a control flow's exits by reading the ones you
expected" twice over. Wrapping a `call` cannot miss an exit nobody thought of.

**Evidence: bench check N7, shown red first**, and it is judged over the socket
because `cmd_get_registers` reads the MMU live. With `font_unmap` deleted from
`esp_refresh_client_line`: **slot 1 reads 255 (`ROM_BANK`), was 62.** It targets
the **autonomous** painter deliberately — `show_ui` is reached from `cmd_init`,
which resets slot 1 itself and would mask the answer.

**CONFIRMED ON THE USER'S REAL NEXT, AND IT CLOSES #31 WHERE IT WAS FOUND.** At
`BAUD_HIGH=460800`: the link negotiates, **the screen is perfectly clean**, and
`make test-hardware` passes **5 runs of 5** — 6/6 with 15/15 conformance and H6
clean (0 bright-red pixels) every time. Median **6.6 ms** latency against the
115200 baseline's 11.2, and **20.3 KB/s** against 8.3, i.e. **2.45x**.

**THE HEADROOM CORRECTION IS THE HALF THAT OUTLIVES #31.** `CLAUDE.md` and
[doc/ASYNCHRONOUS-BREAK-DESIGN.md] both told the next session the WiFi build had
"over a kilobyte of headroom, i.e. many such steps". It had **119 bytes**, and
M2 grows this bank. Both are corrected; `MEMORY.md`'s two sites are annotated
rather than rewritten. What survives unchanged is that a 16-byte step of the MF
ROM half still **spends 16 bytes of the debugger half**, because the image ends
at `0xE000 + 0x2000 - MF.main_prg_copy` — probed, one step moved the old buffer
to `0xFBB0` with `main_end` unmoved. **The two halves share one budget.**

**Rejected.** Keeping the `ASSERT` alone (it is the diagnosis, and it left
`make test-baud` unbuildable); freeing ~17 bytes in the negotiation instead (it
buys the probe ROMs and leaves the trap for the next person); **locking ROM1
permanently at init** rather than per paint (it changes what the debuggee sees,
where the per-paint save/restore leaves debuggee-visible state identical);
save/restore inside `show_ui`'s body (two exits, above); and **fixing #28 in the
same change**, which was offered and is wrong: forcing slot 2 in `show_ui` would
make `esp_ui_bank` always record the forced bank, so `esp_refresh_client_line`
would always abandon and N5/N6 would go red. #28 needs a design that accounts for
#23 and stays its own issue.

*(**CORRECTED 2026-08-10 — THE CONCLUSION HELD AND THE REASON WAS FALSE, WHICH IS
THE WORSE HALF TO GET WRONG in the file every session is told to read first.**
#28 was built by doing exactly this, and `make test-client-status` came back
**8 of 8 with N5, N6 AND N7 GREEN**. The first clause is right — `esp_ui_bank`
does now always record the forced bank — and "would always abandon" simply does
not follow from it. The refresh compares that byte against **NR `0x52` read at
refresh time**, i.e. against the value `screen_unmap` put back, and in the
ordinary case those are the same number: `cmd_init` writes bank 10 into slot 2
and `SCREEN_BANK` **is** 10. What the guard does after the change is abandon
exactly when slot 2 has been moved off the screen — which is when it must, and
is N6. The prediction was never run; three emulator runs settle it either way,
and this file carries "where a claim is mechanical, mechanise the check" under
four other names. The **verdict** — that #28 stays its own issue — is untouched,
and was right for a different reason: it moves both ROMs.)*

**Cost: UART `main_end` 0xF200 → 0xF21F, WiFi 0xFB49 → 0xFB6E** — the guards are
~37 bytes against 768 recovered. **Both ROMs move, by design**: `text.asm`,
`main.asm`, `ui.asm` and `data.asm` are common code, so the UART byte-identity
gate breaks deliberately, as it did for #7, #8, #9, #12 and #20. **This changes a
ROM, so the merge carries a `make bump`.**

**Regression: `make test` 7/7, `test-dzrp-stub` 15/15 with W1-W6,
`test-client-status` 7/7 with the new N7, `test-baud` 5/5 (it builds again),
`test-unit` 5/5, both variants `check-reproducible`** — every one re-run
independently by the reviewer, who also re-derived the overlap, the byte budget
and the N7 red.

**NOT COVERED.** The **`show_ui` half** of the guard has no check of its own —
N7 exercises the autonomous painter, and `cmd_init` resets slot 1 itself, so the
synchronous path's restore is reasoned from the shell's shape rather than
measured. **A debuggee that has selected the 128K ROM** is handled by the NR
`0x8C` lock but no run stages it. **#28 is still open** and `show_ui` can still
`MEMCLEAR` 8 KB through a retargeted slot 2. And the **M1 → `R` → M1 recovery at
460800** — the sixth of the criteria written beside `ESP_BAUD_HIGH`, and the one
no bench anywhere covers — has not been run.

[doc/ASYNCHRONOUS-BREAK-DESIGN.md]: doc/ASYNCHRONOUS-BREAK-DESIGN.md

---

## 2026-08-09 — The baud negotiation is built and is switched OFF, because 1 Mbps is past what the Z80 can carry

**Built, issue #25 — and the headline is a measurement that contradicts the
thing the work was commissioned for.** The stub can now ask the module to move
up from 115200 with `AT+UART_CUR=`, move its own prescaler in step, verify, and
come back down. `ESP_BAUD_HIGH` is the seam. **It defaults to `ESP_BAUDRATE`, so
the shipped ROM does not negotiate**, and that default is the decision.

*(**SUPERSEDED 2026-08-09: the default is now 460800** — see the entry at the top
of this file. The six criteria this entry writes out were met on the user's own
Next, so what changed is the evidence and not the reasoning. Everything below
about **why not higher** stands unaltered, and is why the new default is 460800
rather than the 1000000 this work was commissioned for.)*

**ONE MEGABIT DOES NOT WORK, AND THE LIMIT IS OURS RATHER THAN THE MODULE'S.**
At 1000000 the conformance suite goes red on **C5**, the loopback sweep: a
`CMD_LOOPBACK` of 1024 bytes or more overflows the UART's 512-byte Rx FIFO.
Measured, one build-time constant apart, one byte time being prescaler x 10
T-states at 28 MHz:

| rate | prescaler | T-states/byte | C5 | Rx FIFO overflows |
|---|---|---|---|---|
| 230400 | 122 | 1220 | pass | 0 |
| **460800** | **61** | **610** | **pass** | **0** |
| 600000 | 47 | 470 | FAIL | 2 |
| 750000 | 37 | 370 | FAIL | 2 |
| 921600 | 30 | 300 | FAIL | 2 |
| 1000000 | 28 | 280 | FAIL | 3 |

460800 also passes the whole suite, **15 of 15 with W1-W6**.

**THE MECHANISM I FIRST ATTACHED TO THAT RESULT WAS FICTION, AND THE REVIEWER
CAUGHT IT.** I wrote that `cmd_loopback` interleaves — reads a byte, buffers it,
and stops reading for a whole `AT+CIPSEND` every `ESP_TX_CHUNK` bytes. **It does
not interleave at all**: `commands.asm:959-1018`, upstream and unmodified,
drains the entire payload into the swap bank in `.rcv_loop` before it ever
reaches `send_length_and_seqno`, and `ESP_TX_CHUNK` is referenced only by the
transmit path. I described a loop I had not read, in a file I had not changed.

**What the log says**, which is what I should have done first: in
`build/baud-l5.log` the previous response's `SEND OK` is fully delivered, the
1030-byte `+IPD` header goes out, and the first dropped byte follows **2 ms
later with zero guest TX writes and zero `AT+CIPSEND` in the window**. The
overflow is entirely inside a *receive*.

**So the cost is the per-byte RECEIVE path**: `transport_read_byte` — two border
writes, `esp_require_payload`'s guard, the 16-bit `esp_rx_remaining` decrement,
the held-vs-wire source test — plus `esp_try_read_raw` re-arming its retry and
pass counters on every byte, plus the caller's own store loop. The sweep
brackets it: **above 470 T-states (600000 fails) and at most 610 (460800
passes)**.

**AND THAT IS WORSE THAN THE STORY IT REPLACES, which is the reason this
mattered rather than being a tidy-up.** An echo-specific cost would have been a
conformance curiosity; a receive-side cost applies to **any large inbound
payload**, and `CMD_WRITE_BANK` pushes 8-16 KB per bank every time DeZog loads a
`.nex`. Left in the shipped ROM's comments, the wrong mechanism would have sent
whoever next tries to raise the ceiling to optimise the **send** path, which is
not in it. This file names "a plausible mechanism instead of a traced one" as a
recurring disease; this is that, in a comment that will outlive the branch.

**THE ISSUE'S OWN FEASIBILITY COMMENT SAID THIS COULD NOT BE SEEN HERE, and it
was wrong in the direction that matters.** It reasoned that jnext paces the
module from the guest's own prescaler and "can never outrun it", so no emulator
run would surface an Rx overflow. It does outrun it, because the thing that
fails to keep up is the **Z80**, not the wire — and jnext counts the same
T-states a Next does. So this is one of the few hardware claims in this project
that the emulator is entitled to make. What it still **understates** is the
size: a real module takes tens of milliseconds over an `AT+CIPSEND` where jnext
takes none, and every one of those is more backlog. Hardware can only be worse.

**SO THE DEFAULT IS OFF, AND THAT IS NOT CAUTION FOR ITS OWN SAKE.** 1000000
cannot ship: it fails the strongest gate here, and weakening a check to make it
pass is the one thing this project's testing culture refuses. 460800 is green
everywhere and would be a real fourfold gain — **but no Next has run any of
this**, and "anything touching the ESP needs hardware" is a hard rule that has
already been paid for twice (a connection id of 0, a 15-character address).
Changing the rate the shipped ROM runs the peripheral at, on emulator evidence
alone, is exactly that move. `make TRANSPORT=wifi BAUD_HIGH=460800 mf-rom` is
the ROM to try; flipping the default afterwards is one line.

**THE HARD PART WAS NEVER THE SWITCH, IT WAS COMING BACK.** A rate survives
everything the machine can do to itself: the UART's prescaler is restored only
by `i_reset_hard`, which `zxnext.vhd:3361-3367` ties to the constant `'0'`
(`serial/uart.vhd:313-320` for the gate), so the stub's own `R` key leaves BOTH
ends up there.

**AND I GOT THE OTHER HALF OF THAT WRONG, IN THE WAY THIS PROJECT'S FIRST HARD
RULE EXISTS TO PREVENT.** I wrote — in four places, and reported it up as an
established *correction* closing what issue #25 called its highest-value open
question — that no software reset for the ESP exists. It does. `nextreg.txt`
37-49, NR `0x02` **(W)**: *"bit 7 = Assert and hold reset to the expansion bus
and the esp wifi"*. Corroborated at `zxnext.vhd:60` (`o_RESET_PERIPHERAL ...
asserted under sw control for esp / exp bus reset`), `:1579`, `:5119`, and by
**this repository's own `src/mf_rom.asm:72`**, which has said `Preserve
esp/expbus bit` since the fork — one grep away the whole time.

**How the error was made, because that is the transferable part.** I traced
`o_RESET_PERIPHERAL` to `bus_rst_n_io` in the three board files, read "bus" in
the *derived signal's name*, and concluded expansion-bus-only — without reading
what the **register's own spec** says the bit does. The board line even carries
the disproof in its trailing comment, *"makes more sense if exp bus reset and
esp reset are separated"*, which only parses because they are **not**. A
citation is not a quotation, and a signal name is not a specification: when an
issue flags something as the thing most worth finding out, the primary reference
gets quoted rather than paraphrased.

**THE PROBE IS STILL RIGHT, AND NOW FOR REASONS THAT SURVIVE.** Three, none of
which is "no reset exists": the reset **cannot be aimed at the ESP alone** — one
line on every board revision, so a pulse resets whatever the user has plugged
into the expansion bus, which this stub knows nothing about; the module then
**reboots and must re-associate**, and nothing here has measured how long, during
which there is no address and so no connect string; and **no bench here can
execute it**, since jnext models no path from NR `0x02` to its ESP, which would
make it Z80 nothing could run — the trade issue #19 refused. So a bit-7 pulse is
a real escape hatch *behind* the probe, wanting its own issue and a jnext model,
rather than a thing that does not exist.

Without a fix, the M1 press after a reset would have run `esp_uart_init`, dropped
**our** side to 115200 alone, and painted "ESP-01 setup failed" on a healthy
module — power cycle only — and `esp_recover`, which ends `jp transport_init`,
would have repeated it for every fault. **The answer is a probe at bring-up
rather than a guard at the switch**: greet the module at 115200 and, on silence,
at `ESP_BAUD_HIGH` before giving up. That converts every way this goes wrong from
"power-cycle the Next" into "press M1 again", and it is the only recovery this
stub **ships**.

**AND IT IS DEAD CODE IN THE EMULATOR, WHICH IS SAID OUT LOUD RATHER THAN
FILED UNDER "COVERED".** jnext's module answers the first greeting every time, so
nothing here has ever executed the probe.

*(**IT HAS NOW, ON A REAL NEXT — 2026-08-09, build `00.16`, and this is the first
time that code has run anywhere.** Sequence: M1 (stub up, 460800), `R`, M1 — the
stub came back up with row 3 reading 460800. Between the reset and the second
press, `.UART` sent `AT` and **got no answer**; power-cycling then returns the
module to its 115200 firmware default, and `.UART`'s `AT` there got **`OK`**.
Tier: `reported on hardware`.

**THE CONCLUSION RESTS ON ONE CITED PREMISE, AND CALLING IT "OBSERVED" WOULD
OVERSTATE IT** — which is what the independent review of this entry caught. It is
that **`.UART` puts the link at 115200 itself**, rather than inheriting whatever
prescaler was there: `doc/WIFI-SETUP.md:148` records that it sends `ATE0` and
`AT+UART=115200,8,1,0,0` on entry. The premise is load-bearing because the
prescaler **survives a soft reset** (this entry's own finding), so a `.UART` that
inherited it would have been at 460800 too — and a still-460800 module would then
have answered, not gone quiet. Given the premise, the silence says the module was
**not** at 115200, so the stub's own 115200 greeting must have failed and
`ESP_BAUD_HIGH` is the only other rate it tries.

**Behaviour alone cannot discriminate, which is why the `.UART` step was needed at
all**: a module still at 460800 reaches the screen's 460800 through the probe, and
a module back at 115200 reaches the same screen by being greeted normally and then
negotiated up. Both end identically. And the power-cycle control is what makes the
silence mean anything — without it "no answer" had two causes, the rate and a
broken tool.)*

**THE SWITCH IS MADE ATOMIC WITH THE FRAME REGISTER, and the bench watched the
hazard it closes.** There is no double buffering anywhere in `serial/uart.vhd`:
the divisor's two 7-bit halves go through separate writes to `0x143B` and each
lands immediately, so between them the live value is a **mixture** of old and
new. Bit 7 of `0x163B` holds the transmitter at `S_IDLE` and the receiver at
`S_PAUSE` (`uart_tx.vhd:166-172`, `uart_rx.vhd:216-224`), empties **both** FIFOs
(`uart.vhd:385`, `:570`), and **does not touch the prescaler** — `uart_frame_wr`
appears in neither prescaler process. All three verified.

The mixture is not theoretical: jnext logs after every write, so **L1 asserts the
sequence `243 189 61`**, where 189 is the old high half with the new low half.
The bench computes it the way the hardware does rather than hard-coding it.

**WHAT THE BENCH CAN AND CANNOT SEE, and the split is the whole design of it.**
jnext's AT engine stores the baud it was asked for and **never reads it again**,
so a stub that told the module and forgot its own side is byte-for-byte
indistinguishable from a correct switch by any behavioural check. The
half-switched link — the failure this design is shaped around — is structurally
unreachable. So the discriminating assertions are on **jnext's uart log**, which
records every prescaler the guest programs. Demonstrated: with the refusal guard
removed, the stub programmed divisor **5** after an `ERROR` and **still served
DZRP perfectly**, because the emulated module cannot tell. L2 caught it; nothing
behavioural could have.

**Five checks, each shown red first**, `make test-baud`:

| | subject | shown red by |
|---|---|---|
| L1 | the negotiation happens, both ends | pointing it at the non-negotiating ROM |
| L2 | a refusal does **not** move our side | a scratch ROM with the guard removed |
| L3 | the shipped ROM does not negotiate | pointing it at a negotiating ROM |
| L4 | `esp_recover` re-runs the whole chain | the shipped `FAULT_LIMIT` of 5 |
| L5 | **the ceiling**, and it PASSES when C5 fails | — |

**L5 IS A CHECK WHOSE PASS IS A FAILURE**, W3's shape, and it is there so that
whoever raises the default has to come and make it go green — which means having
changed the thing it measures, not the constant. It asserts the Rx FIFO really
overflowed as well as that the loopback died, because "C5 failed" has other
causes.

**The screen had to change, and not for decoration.** Row 3's `ESP Baudrate:`
was a constant assembled from `ESP_BAUDRATE`. A ROM that negotiated up would
have gone on stating the rate its own peripheral was **not** running at — the
exact defect MEMORY.md 2026-08-05 records this line being fixed for, one issue
later. It is now drawn from `esp_baud_state`, which `esp_uart_init` and
`esp_uart_init_high` write and **nothing else does** — they are also the only
writers of the prescaler, so the byte cannot disagree with the hardware without
somebody adding a third writer of one and not the other. It is also the only
thing on the machine that says whether the negotiation took, because behaviour
cannot: a stub that fell back serves exactly as well as one that did not.

**A correction to the issue's arithmetic, checked rather than repeated.** Its
comment says 921600 is "worse than 1,000,000 at every single timing". It is not:
1000000 is exact at six of eight where 921600 is exact at none, but at Fsys
28571429 and 29464286 — NR `0x11` states 1 and 2 — 921600 lands on +0.006% and
-0.091% against 1000000's -1.48% and +1.60%. The conclusion survives, the reason
does not.

**The tables round now** — `(Fsys + baud/2)/baud`, free assembler arithmetic —
which moves two 115200 entries: Fsys 29464286 from 255 (+0.301%) to 256
(-0.091%), and 32000000 from 277 (+0.281%) to 278 (-0.080%). Both old values
worked. **No bench here covers either**, because the reference image boots at
video timing 0 where truncation and rounding agree.

**WHAT WOULD JUSTIFY FLIPPING THE DEFAULT TO 460800 is written out beside the
constant**, because "run the bench and see" is not an acceptance criterion and
the interesting failure does not look like a bad number — it looks like a
working debugger with one extra word on its screen. Six results on a real Next:
the screen must actually say 460800 (otherwise the module refused and the
fallback worked, and there is nothing to measure); **H2 = 15 of 15 on three
runs**, three because issue #11's cost measurement needed three before an
outlier could be discounted, and **C5 is the check that matters** since it is
what L5 shows going red; **H6 clean on all three and specifically not `RX
Overflow`**, which is disqualifying even against passing checks because it is
the margin gone, and which is a different string from `RX Timeout`; **H5 median
at least twice the 8.3 KB/s baseline**, below which the module's stack is the
limit and the rate buys nothing; **H4 latency explicitly NOT the criterion** —
11.2 ms is WiFi round trip, not wire, so expect it unchanged and treat a
material worsening as the red flag; and **M1, `R`, M1 again**, which no bench
anywhere covers and which is the only recovery this stub ships.

*(**ALL SIX WERE MET ON 2026-08-09, build `00.16`** — the ROM that carries issue
#31's fix, without which the 460800 screen is visibly corrupt and criterion one
cannot honestly be read. Measured on the user's own Next: the screen says 460800
and is **perfectly clean**; `make test-hardware` **5 runs of 5** at 6/6 with
**15/15** conformance each, so C5 passed five times; **H6 clean every run**, 0
bright-red pixels, no `RX Overflow`; **H5 median 20.3 KB/s = 2.45x** the 8.3
baseline; **H4 median 6.6 ms against 11.2**, i.e. 41% BETTER — and note that
contradicts this entry's own prediction that latency would be unchanged because
11.2 ms is "WiFi round trip", which was wrong; and **M1, `R`, M1** with the probe
shown to have fired, see the annotation above.
**SO THE DEFAULT IS NOW A DECISION AND NOT A MEASUREMENT.** Two things are still
unmeasured and neither is on the list, which is why the list is not sufficient on
its own: a **DeZog `.nex` load**, whose `CMD_WRITE_BANK` pushes 8-16 KB per bank
and is far larger than C5's 4096 bytes on the very receive path the ceiling
governs; and any rate behaviour on a **second machine or module**.)*

**Rejected.** Defaulting to 1000000 (it fails the gate); defaulting to 460800
(green here, unmeasured there, and this project's rule is explicit); using
`AT+UART_DEF=` (it persists into flash, so a rate that turns out not to work
hands the user a module the stub can no longer greet — "press M1 again" against
"take the card to a PC"); `esp_command_ok_or_error` for the `AT+UART_CUR` step
(it reports which arm it took to nobody, and the refusal is precisely the arm
this has to act on); a near-copy of it that does report (the coordinator's call,
and unnecessary — `esp_command_ok` conflates refusal with silence, and the
conservative reading is right for both); a verifying `AT` on the fallback path
(the four chain steps after it are the verification, which is also why the
negotiation sits before `AT+CIPMUX` rather than at the end); switching after the
listener is open (the switch empties both FIFOs, which with a client attached
would silently destroy a command — issue #11's family).

**NOT COVERED, and none of it is hidden.** ~~**The rate itself** — no run here
says anything about what a real ESP-01 will take.~~ ~~**The probe** — dead code in
the emulator.~~ ~~And **the 460800 recommendation rests on emulator runs
alone**.~~ **All three were closed on hardware on 2026-08-09** — see the two
annotations above; 460800 runs, and the probe has executed. **The half-switched
link** — structurally unreachable, and still is. **The bring-up probe's
interaction with a module at a rate this ROM was not built for** — the probe only
tries the two rates it knows, and nothing has staged that. **A DeZog `.nex`
load at 460800**, which is the largest inbound payload the stub ever sees and
bigger than anything C5 covers. And **a second machine or module**: every rate
result is one Next, one ESP-01, one reporter.

**A CAVEAT THIS DOES NOT INHERIT, checked rather than assumed.** Issue #24's
`esp_command_ok_or_error` header names #25 as its second caller and warns that
its matcher is naive rather than exact. **This step does not use it**: the
`AT+UART_CUR=` wait is `esp_command_ok`, one pattern, because the refusal is
precisely the arm that has to be acted on and the two-pattern routine reports
which arm it took to nobody. And the hole there is a CROSS-pattern one —
`ERROR[3]` is `OK[0]`. A single "OK\r\n" has no proper border, so its failure
function is all zeros and naive restart is exactly correct against ANY input,
which is stronger than the clean-window argument CIPSTO rests on. That matters
because this window is not always quiet: a re-init through Symbol Shift + M1 or
`esp_recover` re-enters with a listener up.

**Cost: +9 bytes in the shipped WiFi ROM** (`main_end` 0xFB40 → 0xFB49, 855 free
to the identity block), which is the frame-register hold in `esp_uart_set_rate`
plus the two rounded table entries — proved to be the whole of it by comparing
symbol tables: of **922 symbols common to both**, 648 are unmoved and 274 sit at
exactly +9; **none was removed and exactly two were added**, `ESP_BAUD_HIGH` and
`esp_uart_set_rate`, which are the constant and the entry point this change
introduces.

*(The first version of that sentence said "609 symbols ... none added or
removed", and was wrong twice over: the extraction matched only listing lines of
the form `0xNNNN␣␣␣name` and so **silently dropped 315 symbols** — every
`X`-flagged one, every EQU with a five-digit value and every dot-local — and
"none added" was an artefact of the two new names being among them. The
reviewer's independent count differs again in the totals (840/603/237) because
its filter differs again; all three agree on what matters, which is zero removed,
exactly two added and every survivor at 0 or +9. A count over a hand-written
pattern is an estimate, and this file already carries that lesson under three
other names.)* At `BAUD_HIGH=460800` it is +145 (0xFBCF, 710 free). **The UART ROM is
byte-identical** to the base pinned (`87965fea…`), so nothing leaked across the
transport boundary. **This changes a ROM, so the merge carries a `make bump`.**

*(**CORRECTED 2026-08-09: "free to the identity block" was the wrong ceiling, and
for the 460800 build the true figure is NEGATIVE.** The usable region ends at the
RAM font buffer, `0xFBC0`, not at `ROM_MAGIC_ADDR`. So the shipped WiFi ROM's 855
is really **119**, and `BAUD_HIGH=460800`'s 710 is **−15**: `main_end` 0xFBCF sits
**inside** the font buffer, aliasing `text_one_char` and `text_core_version` onto
the space and `!` glyphs. That is issue #31 — the screen artefacts seen on real
hardware at 460800 — and it means **the 460800 measurements in this entry, and the
15/15 hardware runs at that rate, were taken against a ROM with a live memory
overlap**. The rate results (latency, throughput, the C5 ceiling) are unaffected,
because none of them reads that memory; the *screen* was wrong the whole time.
Every other "free to the identity block" figure in this file is loose by 736 bytes
for the same reason and is left as measured.)*

**Regression: `make test` 7/7, `test-dzrp-stub` 15/15 with W1-W6, `test-cipsto`
4/4, `test-client-status` 6/6, `test-baud` 5/5, both variants
`check-reproducible`.**

---

## 2026-08-09 — Probe C: the expected value is an ARGUMENT, and a survival is a lower bound

**Built.** `test/idle-drop-probe.py` — a third instrument in the probe A/B
family, promoting a scratch script that had already produced three hardware
results nobody but its author could reproduce. It opens one connection, gets a
`CMD_INIT` answered, **says nothing and never closes it**, and times how long the
remote leaves it alone. Rows `R0`-`L5`, no PASS, and `make probe-idle-drop`.

**WHY IT EXISTS AT ALL, given that #24 has its own bench.** `make test-cipsto`
shows the **stub sends** `AT+CIPSTO=1800` and reads the answer, against a jnext
that models the command **from our own hardware measurement**. Nothing in that
loop can show a real module OBEYS the value. Probe C is the only thing that can,
and it is also the only PC-side check that would catch #24 silently regressing —
a current ROM dropping a silent client at ~182 s.

**THE DECISION: `--expect-timeout` HAS NO DEFAULT.** The probe cannot read
`AT+CIPSTO?` — that needs `.UART` at the machine — so any number baked in would
be the tool asserting a property of a module it never asked. Given one, `L2`
says whether the two agree; given none, the number is printed and **nothing is
attributed to it**. It changes the WORDING of one row and never the exit code:
there is no verdict here, and a disagreement is a *finding*, not a failure.

**AND A SURVIVAL IS WORDED AS A LOWER BOUND, EVERY TIME.** A connection still
open at the deadline says the timeout is *longer than the deadline*; it never
says there is none, and no finite wait can. The three survival branches
distinguish "past the expectation — the expectation is NOT met" from "inside the
tolerance band — inconclusive" from "well short of it — consistent, confirms
nothing", and a deadline too short for a survival to mean anything is said **up
front** rather than learned four minutes later.

**FIVE DEFECTS IN THE DRAFT, and the first three are one disease.** It

1. printed `module reports +CIPSTO:180` **unconditionally**, as though read from
   the module;
2. concluded from it — against a stub that had raised the value it announced
   that **no timeout existed**, a conclusion printed without consulting what
   happened, which is the defect `--no-lift` had been rejected for days earlier;
3. hardcoded its match window to `150.0 <= x <= 220.0`, so any other configured
   value would have been mislabelled.

The two found while rewriting are of a different kind and both would have
survived review by reading:

4. it put **`/home/jorgegv/src/spectrum/dezogif_ng/test/dzrp` on `sys.path`** — a
   committed tool importing the MAIN checkout's modules from any worktree, which
   is [[ERRORS.md]]'s cross-worktree hazard in a new organ;
5. it reached **behind the transport** into `.sock.recv()`, re-implementing the
   EOF/timeout distinction `TcpTransport.read` already makes, and reported the
   **nominal `--deadline`** as the survival figure rather than the elapsed
   silence measured. A lower bound must be the number actually reached.

**L5 IS AN ADDITION AND IT ANSWERS A COMPLAINT THIS FILE ALREADY CARRIES.** The
2026-08-08 entry records "NOT captured: the build number" as a limit of hardware
testing, because DZRP's `PROGRAM_NAME` reports upstream's `dezogif v2.2.1` for
every ROM we ship. The stub prints `dezogif_ng <variant> NN.NN` at screen row 0,
and the screen reader can see it — so a probe C result names the build that
produced it.

**Evidence: three hardware runs, recorded in [doc/HARDWARE-TESTING.md].**
Dropped at **182.5 s** and **181.8 s** with the module's own default governing;
**survived 400 s** once the stub set 1800. The third is stated as the lower bound
it is — it did not measure 1800, it measured "longer than 400" — and **neither
says whether the module announces a reap**: the 2026-08-09 close was our own
clean FIN, and the 2026-08-08 reaps were against a build that predates #23's
observer.

**The wordings are checked rather than asserted**, which for a tool whose whole
subject is wording is the only evidence that counts. `test/idle-drop-fake-peer.py`
has one property — an **idle** timer, settable or off — so all twelve branches run
in seconds instead of the minutes hardware costs. It is **not** a stub and proves
nothing about one.

**THERE IS NO `probe-jnext` VALIDATION FOR C, AND THAT IS SAID RATHER THAN
PATCHED OVER.** A and B are pointed first at a ceiling jnext is known to have.
Whether jnext models `AT+CIPSTO` at all is unknown, so there is no known answer
for C to be checked against — and a probe pointed at a module with no timeout
reports the same survival as a broken probe. What stands in is in-band: `R0` and
the closing screen read bracket the wait with two working exchanges.

**A HARNESS FAULT CAUGHT THE TOOL OUT, AND IT IS FILED IN [[ERRORS.md]] RATHER
THAN HERE.** A stale fake peer with a different delay was still on the port; the
replacement failed to bind into an unread log; the probe measured the stale one's
6 s and `L2` reported it as matching an expectation of 12. **A plausible number,
blessed.** It is the sharpest available illustration of that row being
consistency rather than attribution — produced by the tool against itself, on the
day it was written.

**Rejected.** A default `--expect-timeout` of 180 (it was the defect); making a
mismatch exit non-zero (that is a gate, and this is an instrument); reusing check
ids `C*` (the conformance suite's) or `K*` (issue #24's, added the same day) —
`R` for *reap* was free in both directions; sending `CMD_CLOSE` at teardown as
probes A and B do (`cmd_close` repaints through `jp main`, and the **session
line is part of this probe's subject** — `screen-client.py`'s reasoning); and a
second screen read to get the canonical `observe()` wording, since one read keeps
all three rows of the same moment.

**Cost: no `src/` change.** Both ROMs byte-identical to `main`'s with
`BUILD_TIME` pinned and `build/*.bin` deleted first — the certain answer rather
than the conservative one — so **no `make bump`**, even though the mechanical
check lists `Makefile`.

[doc/HARDWARE-TESTING.md]: doc/HARDWARE-TESTING.md
---

## 2026-08-09 — The module was hanging up on idle debug sessions, and we had never told it not to

**Built, issue #24.** `transport_init` sends **`AT+CIPSTO=1800`** between
`AT+CIPMUX=1` and `AT+CIPSERVER`, and reads the answer. Twenty bytes of AT
command and a wait; the whole of the interest is in the value and in the wait.

**THE DEFECT IS THE MODULE'S, AND IT WAS MEASURED BEFORE ANY CODE WAS WRITTEN,
WHICH IS UNUSUAL HERE AND IS WHY THIS ONE DID NOT COST A HARDWARE EVENING.**
`AT+CIPSTO` is the ESP's TCP-**server** idle timeout: a client silent for
`<time>` seconds is hung up on by the module, with no involvement from the guest
at all. The stub had never sent the command, so the firmware default governed
us — and on the user's Next (AT 1.2.0.0 / SDK 1.5.4.1) `AT+CIPSTO?` answers
**`+CIPSTO:180`** and it is **enforced**: a client that connected, sent
`CMD_INIT` and then said nothing was dropped after **182.5 s** and **181.8 s**
on two runs.

**That is a DeZog session parked at a breakpoint.** Neither side transmits while
the user reads code — this stub never speaks unprompted, DeZog sends only when a
panel asks — and on ESP8266 our **own replies do not re-arm the timer**
(esp-at v2.2.0.0_esp8266 says so outright; v1.5.4, which matches this firmware,
is silent, and jnext models the reading the requirement forces). Confirmed with
the real client at the machine: the registers view, the memory view and the
debug toolbar all vanished — DeZog had ended the session, and 3.7.4 has no
reconnect logic of any kind — while the stub was **perfectly healthy**, border
still cycling. **Nothing on the Next said anything had happened**, and the
screen still read `Session opened - CMD_INIT`, which is issue #23's subject
seen in the field.

**WHY 1800 AND NOT 0 OR 7200, WHICH IS THE ONE THING A FUTURE READER WILL
QUESTION.** All three are legal; the range is 0..7200 inclusive.

| `CIPSTO` | an idle debug session | a vanished peer's inbound slot |
|---|---|---|
| **180**, the firmware default | **dropped after 3 min** — the defect | self-heals in ~3 min |
| **0** | never dropped | **never freed** — permanent, until a power cycle |
| **7200** | safe for 2 h | **leaks for 2 h** |
| **1800**, chosen | safe for 30 min | self-heals in ~30 min |

`0` was rejected because it would **deliberately create** the permanent fault
KNOWN-ISSUES.md #19 describes, and Espressif's own documentation attaches "we
don't recommend that" to it. **7200 was chosen first and a measurement moved
it**, which is the part worth keeping: that choice rested on the leak being
already permanent, so that stretching the timer cost nothing. It is not.
`make probe-vanished PROBE_ARGS="--no-lift --recover 210"` on the user's Next
has a fresh client **SERVED** after four vanished peers with the blackhole still
**up** throughout — nothing of ours told the module its peers had gone — and the
identical run at `--recover 100` comes back **REFUSED**. One constant apart, so
the reclaim is a **timer of roughly 180 s**, and not our own `esp_recover`
sweep, which has no timer and cannot fire on a quiet stub. So 7200 would have
turned a three-minute fault into a two-hour one. 1800 keeps the whole practical
benefit — nobody reads code for half an hour without touching the debugger —
and leaves the leak self-healing on a human timescale.

**IT IS RE-SENT ON EVERY BRING-UP**, because `AT+CIPSTO` is absent from v1.5.4's
list of commands that write to flash: the module's 180 is a compiled-in default,
not something a previous session left behind.

**THE WAIT IS THE DESIGN, NOT THE COMMAND.** `esp_command_ok_or_error` accepts
`OK` **or** `ERROR` and treats neither as a bring-up failure. Three reasons, and
the third is the one that made it a routine rather than a line:

1. `esp_command_ok` matches `OK` alone, so a refusal is indistinguishable from
   silence **and costs the full read budget** — the whole of `ESP_INIT_PASSES`,
   ~2 s — before saying so;
2. and then says the wrong thing: its `jr c,.no_bringup` abandons a module that
   answered perfectly clearly. **Measured, as bench check K4**: with that wait,
   `AT+CIPSERVER` is never sent and **nothing listens at all**. A firmware too
   old for the command would have turned this fix into "the debugger will not
   start";
3. **it keeps the chain synchronous.** Fire-and-forget leaves the module's
   answer in the RX FIFO, so `AT+CIPSERVER`'s own wait for `"OK\r\n"` matches
   the OK belonging to `AT+CIPSTO` and every reply for the rest of bring-up is
   off by one — the desynchronisation class this transport has been bitten by
   twice.

**THE MATCHER IS THE NAIVE RESTART SHAPE GENERALISED TO TWO PATTERNS BY
COMMITTING ON THE FIRST CHARACTER.** One cursor, because `esp_read_scan`
preserves only HL and a second would have had to live in memory.

**I CLAIMED IT WAS EXACT, AND IT IS NOT — THE INDEPENDENT REVIEWER DISPROVED IT
RATHER THAN DOUBTING IT**, by simulating the routine's control flow in Python.
My argument was that neither pattern repeats its own first letter, so a restart
always recovers, and my worked example was `"ERROK\r\n"` still matching OK. That
input **returns a TIMEOUT**. The hole is **cross**-pattern, which is precisely
what a self-overlap argument cannot see: `"ERROR"`'s fourth character is `O`,
the leading character of `"OK\r\n"`, and once it has been consumed as a body
match at `ERROR[3]` it is never re-offered. (`"EOK\r\n"` *does* match, because
there the mismatch falls at `ERROR[1]` — which is why the wrong claim looked
right when I checked it by eye.)

**What makes it safe is the WINDOW, not the matcher**: between this command and
its answer the module sends exactly one clean line and nothing else, confirmed
from jnext's own esp01 log. So the comment now says "naive, usually right", in
the register `esp_wait_string` already uses, and spells the counter-example out
— because the routine is written to be reusable, **issue #25 is the second
caller**, and a formal-sounding proof is the worst thing to hand someone who is
about to use it in a noisier window.

**The lesson is this file's oldest in a new organ.** A property checked by
constructing one example that confirms it is not checked; I had a *disproof*
available for the cost of a second example and did not look for one. The
reviewer wrote a simulator. **Where a claim is mechanical, mechanise the check.**

**A BYTE RECORDING WHICH ARM WAS TAKEN WAS BUILT, AND THEN DROPPED, AND THE
DELETION IS THE MORE USEFUL HALF OF THIS ENTRY.** `esp_sto_state` held
SET / REFUSED / SILENT, on the reading that "not fire-and-forget" means "keep
the answer". It was written by the transport and read by **nothing**, and
nothing here *can* read it: no bench reads the debugger's own RAM, and the value
was drawn nowhere. So the distinction it existed to preserve was one that
nothing could make, and **the manager was right to ask whether it earned its
byte**: a byte with no reader is residue, and residue outlives its reason.
Dropped, ~15 bytes back.

**WHAT SETTLED IT WAS A MEASUREMENT, NOT THE ARGUMENT.** A scratch build whose
CIPSTO step is `call esp_send_string` and nothing else — genuinely
fire-and-forget — **passes the whole bench, 4 of 4**. Every check here observes
the *module*, and the module behaves identically either way. So the byte was not
what distinguished the two cases, and neither is anything else we have.

**Which leaves the honest justification for reading the answer at all, and it is
NOT the one the issue's wording suggests.** It is synchrony (above), a real
property that a real module would punish and jnext does not — the same "the
emulator sits on the safe side of us" shape as the connection id and the
15-character address. That is now written into the routine, the bench header and
the NOT COVERED list rather than left as an implication.

Raising a refusal into `last_error` was rejected separately, on byte-identity:
the error table is in `data_const.asm`, which is **common code**, so a new code
would move the UART ROM for a WiFi-only condition — the argument that kept
bring-up failure reporting as `RX Timeout` (MEMORY.md 2026-08-04). **The WiFi
status block is not common code**, so putting a refusal on the screen there
costs no UART bytes and is the way to make this observable. It needs new text, a
row, and a check of its own, so it is a separate issue and not this one.

**Ordering: BEFORE `AT+CIPSERVER`, and that buys two things.** No client can be
accepted while the firmware's 180 still governs it; and, since nothing is
listening yet, no `<id>,CONNECT` can land inside the wait for this command's
answer.

**A STALE CLAIM THIS FALSIFIES, corrected in place.** The file header's
"what this does NOT do" list said a re-init while already listening reports a
spurious error, and that clearing it "needs a wait that accepts OK *or* ERROR,
**which nothing else here needs**". That wait now exists. Pointing the
`AT+CIPSERVER` step at it is a one-line change and is **deliberately not made
here**: it would move the meaning of a failed bring-up, and that wants its own
issue and its own check.

**Evidence: `make test-cipsto`, 4 runs, 4 checks, and ALL FOUR SHOWN RED FIRST
AGAINST `main`'s ROM.**

| | ROM | verdict |
|---|---|---|
| **K1** | `SERVER_TIMEOUT=10` | the silent client is **dropped at 10.00 s** |
| **K2** | the **shipped** ROM | the same client **survives 25.03 s**; the log says we sent 1800 |
| **K3** | `SERVER_TIMEOUT=7201` | **refused** by the module, and the stub listens, serves and reports no fault |
| **K4** | the same, `CIPSTO_STRICT=1` | waiting for `OK` alone: `AT+CIPSERVER` never sent, **nothing listens** |

`SERVER_TIMEOUT` is the **sixth** seam of the `IP_MAX` / `RX_WAIT` /
`TX_PASSES` / `WAIT_SECS` / `FAULT_LIMIT` / `LINK_IDS` family and exists for the
fifth time's reason: the shipped 1800 is **half an hour per run**, so no bench
anyone will run can watch it work. K1 and K2 differ in that one constant, which
is what attributes the ten seconds to the value **this ROM sent** rather than to
clients being dropped for some other reason. `CIPSTO_STRICT` is the seventh, and
is K3's controlled removal — ERRORS.md's standing complaint is that a fix never
tested by removing it is a correlation.

**EVERY CHECK ASSERTS ITS PRECONDITION FROM jnext's OWN LOG**, and without that
three of the four would pass vacuously: a ROM that never sent the command also
comes up, serves DZRP, reports nothing and keeps a silent client for 25 s.
Measured against `main`'s ROM — no `AT+CIPSTO` line anywhere, client alive at
25.03 s, **4 of 4 red**. Two sharper reds were taken as well, each with the
message it was written for: K3 against the `CIPSTO_STRICT=1` ROM
(*"nothing listened: the refused AT+CIPSTO stopped bring-up, which is the
defect"*) and K4 against the lenient one (*"the strict build carried on past the
refusal"*).

**Rejected.** `AT+CIPSTO=0` and `=7200` (above); `esp_command_ok` (above);
sending it fire-and-forget (above); a DeZog-side keepalive — it would work,
since any client→server command re-arms the timer, but it needs every user to
upgrade DeZog, protects none of this project's own probes or conformance suite,
and is somebody else's repository; putting the step **after** `AT+CIPSERVER`
(it leaves a window in which a client is accepted under the firmware default,
and puts `<id>,CONNECT` inside the wait); a new `ERROR_*` code for the refusal
(it moves the UART ROM — above); matching `"ERROR\r\n"` with a string of its own
(eight bytes to consume two, and the next step in the chain is a scan, which
steps over CR and LF without matching either — the same reason `esp_wait_prompt`
leaves them).

**Cost: WiFi +62 bytes** (`main_end` 0xFB02 → 0xFB40), **864 bytes still free**
to the identity block at 0xFEA0. **The UART ROM is byte-identical** pinned
(`87965fea…` both sides, `build/*.bin` deleted first), which is what says
nothing shared moved: `transport_esp.asm` is in the WiFi build only and the new
constants live there rather than in `constants.asm`. WiFi `ffd2878f…` →
`cfd0fe8a…`. **This changes a ROM, so the merge carries a `make bump`.**

*(Those are the figures for the branch as merged. The first commit was +80 and
`65662d39…`; dropping `esp_sto_state` in the second gave 18 bytes back. An
earlier version of this paragraph quoted the first commit's numbers in an entry
attached to the second — the reviewer caught it, and it is the worse kind of
stale claim, because this is the file every session is told to read first and
trust. I had the corrected figures in my own report and did not carry them
here.)*

**IT HAS SINCE RUN ON THE USER'S REAL NEXT, AND THE VALUE IS OBEYED.** This
branch's ROM held a silent client for **400 s with no drop**, against the
**182.5 s** and **181.8 s** the shipped ROM was measured at. So `AT+CIPSTO=1800`
reaches a real ESP-01 and the module honours it — which is the one thing no
bench here could establish, since jnext models this command *from* those very
measurements. **Tier: `reported on hardware`** — one machine, one reporter, no
re-runnable artefact — against a `verified` baseline of two re-runnable probe
runs. The NOT COVERED item below is narrowed by it, not removed: what is shown
is that the module obeys, not that any of the emulator's other modelling does.

**NOT COVERED, and none of it is hidden.**

* **A real ESP-01, beyond the single run above.** jnext models `AT+CIPSTO`
  **from** the hardware measurement this issue rests on (jnext#240, needs
  ≥ 0.99.141), so a green bench shows the stub sends the command and reads the
  answer, **not that a module obeys** — that is the hardware run's contribution
  and nothing here inherits it. The refusal arm in particular has never been
  seen on silicon.
* **The value as a POLICY.** 1800 is a judgement resting on the two hardware
  measurements above; no emulator run can weigh 30 minutes of session against 30
  minutes of leaked slot.
* **The refusal on real firmware.** K3's `ERROR` comes from an out-of-range
  value, which is not the same event as a firmware with no `AT+CIPSTO` at all.
  The stub cannot tell them apart and does not try; nothing here has met the
  second.
* **WHETHER THE STUB READ THE ANSWER AT ALL.** Measured: a fire-and-forget
  build passes 4 of 4. Nothing on the machine or in the bench observes which arm
  was taken, and the byte that used to has been dropped precisely because it did
  not close this. K4 is the nearest guard — a build that waits for `OK` alone
  stops dead — so the step's answer is consumed by *something*, which is weaker
  than it sounds.
* **KNOWN-ISSUES.md #19's bound.** This change lengthens it from ~3 minutes to
  ~30, and the entry is **not edited here**: branch `known-issues-19-bounded`
  owns that correction and already names #24 and the figure. Two branches
  editing one section is how a correction gets applied twice and reconciled
  never.

---

## 2026-08-09 — The screen stops claiming a session that ended; and a redraw learned to ask where it is writing

**Built, issue #23.** `esp_watch_line` watches the module's unsolicited
`<id>,CONNECT` and `<id>,CLOSED` lines and matches the id against the connection
`CMD_INIT` arrived on. A client that vanishes without `CMD_CLOSE` now takes row 8
to **`Session lost - client gone`** instead of leaving it reading `Session opened
- CMD_INIT` for the rest of the session — the honest half issue #14's acceptance
criterion offered and this project deliberately did not build then.

**THE OBSERVER'S SAFETY IS ITS POSITION, NOT ITS LOGIC.** A second pattern in the
RX hot path is what #11 and #16 both declined to add, #11 being the record of a
scan eating an inbound `+IPD` and leaving a client answered by nothing at all. So
it never reads the wire: `esp_read_scan` hands it each byte it has **already**
read and gets the byte back untouched. It cannot consume, desynchronise or lose a
frame whatever it concludes, and that argument survives its logic being wrong.

**AND IT WRITES ONLY THREE BYTES, NONE OF WHICH THE BYTE STREAM READS.** Not
`esp_conn_id`, not `esp_conn_valid`, not the tx latch, not `esp_cmd_*`. **One of
those abstentions was measured rather than chosen**: clearing `esp_conn_valid` on
a `<id>,CLOSED` is the obvious next step and it **breaks bench W2**, whose own
precondition is that an `AT+CIPSEND` really was refused — a stub that had already
forgotten the connection never issues one, so W2 would go red having tested
nothing. The fact is still learned one round trip later in `.no_client`.

**CONNECT IS NOT REDUNDANT WITH CLOSED, AND IT IS NOT ADOPTED EITHER.** A
`<id>,CONNECT` on the session's own id proves the previous holder is gone just as
well, and it is the only witness left when the CLOSED landed inside a
`transport_drain`. What it does **not** do is become the current connection:
unconditional adoption lets a second client's CONNECT redirect a reply to a
command already received, which is W5's exact subject, and adoption guarded on
`esp_conn_valid` misses the case it exists for. That is #24's.

### The blocker: an autonomous writer that did not know where 0x4000 pointed

**The first version of this was REJECTED in review, and the defect was mine.**
The redraw is triggered by the network, from `main_loop`'s poll, and it writes at
`0x4000`. I guarded it with `esp_ui_shown` — "show_ui has run since the debuggee
last had the machine" — and wrote in the header that this made *"our screen is
up"* and *"0x4000 is the screen"* **the same fact**, because `show_ui` MEMCLEARs
through that same window.

**That is false, and the counterexample is an ordinary DZRP command.**
`CMD_SET_SLOT 2,<bank X>` retargets the debugger's own MMU slot 2 — `cmd_set_slot`
self-modifies a `nextreg REG_MMU+<slot>` and writes it directly for every slot but
7 — and touches nothing this transport reads. So: `CMD_INIT`, `CMD_SET_SLOT`, then
the client's connection is reported `<id>,CLOSED` while the stub is idle. The
guard still read 1 and the session line was XORed **into bank X**, permanently:
no per-bank backup exists, only `slot_backup.slot0` and `.slot7`, and the
debuggee gets that bank back corrupted.

**THE FIX ASKS THE MACHINE INSTEAD OF TRACKING EVENTS THAT IMPLY THE ANSWER.**
`esp_show_client_line` records what NR `0x52` said at the moment it drew, and the
refresh compares NR `0x52` again before writing a byte. **Verified in the VHDL
first, not assumed**: NR `0x50`-`0x57` have real read cases in the NextREG read
multiplexer (`zxnext.vhd:6059-6081`) returning the live `MMUn` — the same signal
that decodes CPU addresses (`:2952-2964`) — and slot 2's decode is immune to the
Multiface and config-mode overrides, which are structurally scoped to slots 0/1
(`:3029-3066`). The negative control validating that method is NR `0x04`, which
has no read case at all. It is also not a new mechanism here: `send_ntf_pause`
already reads a slot's bank back the same way to report it.

**THE BANK IS CAPTURED, NOT A CONSTANT.** `cp 10` would work today, because
`cmd_init` maps bank 10 there — and it would be `transport_esp.asm` encoding a
number that lives in `commands.asm`, which is how two renderings of one fact
drift apart. What is wanted is "the window still points where it pointed when the
row was drawn", and that is answerable without knowing which bank it was.

**REJECTED — a macro invoked from `cmd_set_slot`**, which was the reviewer's own
first preference and is the shape issue #14 established. Two reasons, and the
second decided it. It puts transport-specific state into `commands.asm`, which
CLAUDE.md's hard rule says must not be able to tell which transport it was
assembled against. And it is correct only for as long as an enumeration stays
correct: there are **forty** `nextreg REG_MMU...` sites across eight files here,
one of them self-modifying and able to write any slot, and a macro must be
invoked from every present and future one that can leave slot 2 elsewhere.
[[ERRORS.md]] carries that failure twice already — "Enumerating a control flow's
exits by reading the ones you expected" and "Clearing a flag in the obvious
routine, which one caller bypasses". A register read cannot be forgotten by the
next person to add an MMU write. Also rejected: dropping the poll redraw
altogether, which removes the writer and with it the case the feature exists for.

**NOT FIXED, AND OLDER THAN THIS BRANCH: `show_ui` HAS THE SAME HAZARD.**
`check_key_border`'s "B" reaches `main_redraw` with slot 2 wherever
`CMD_SET_SLOT` left it, and its `MEMCLEAR` then wipes 8 KB of that bank. It is
common code, it needs a human at the machine, and it is recorded rather than
fixed on a branch scoped to #23.

*(**FIXED 2026-08-10 by issue #28, and two of the three clauses above were
wrong.** The write is **7392 bytes**, not 8 KB — `MEMCLEAR`'s 6144 plus the
attribute `MEMFILL`'s 1248, `0x4000`-`0x5CDF`; 8 KB is the size of the *slot*.
And it does **not** need a human at the machine: `jp main` from `cmd_close`
reaches the same `main_redraw`, and `CMD_CLOSE` is what DeZog sends on every
Shift+F5 — which is the trigger bench N8 uses, with no key pressed. "Common
code" was right, and is why the fix moves both ROMs. See the entry at the top of
this file.)*

### The check, and the reason it was watched to go red twice

**N6**, and it is the only check in that bench judged **over the socket** rather
than off the screen. `CMD_INIT`, `CMD_SET_SLOT 2,60`, a probe parked where row
8's scanlines land, vanish as N5 does, and read the probe back over a fresh
connection that sends **no** `CMD_INIT` — one would put bank 10 back and hide the
answer. Its **third** outcome is a precondition rather than a verdict: all-zeros
means `show_ui`'s `MEMCLEAR` reached that bank, i.e. the run went through
`drain_main` and never stood in the state under test, which is why the probe
contains no zero byte.

*(**CORRECTED 2026-08-10, issue #28, and neither correction changes what N6
does.** The probe is not zero-**free**: `(i*7+1)&0xFF` is `0x00` at i = 73, 329,
585, 841, 1097, 1353, 1609 and 1865, so **eight** of its 2048 bytes are zero —
true when this probe was 32 bytes, and lost silently in this same branch when it
was widened. The outcome test only needs the probe not to be **all** zeros,
which holds. And the third outcome **cannot arise at all**: any run reaching
`show_ui` draws glyphs into character rows 8-15, which is exactly the probed
`0x4800`-`0x4FFF`, so it reports `CORRUPT` — as this branch's own red does,
`96 of 2048`, and as #28's does, `2040 of 2048 ... overwritten`.)*

**Red-first against this branch's own first commit**, which has the writer and
not the guard — a re-runnable control rather than a scratch tree: **96 of 2048
bytes changed, first at 0x4908**.

**AND THE FIRST N6 PASSED AGAINST THAT SAME ROM, which is the lesson worth more
than the fix.** It probed 32 bytes at `0x4800`. Character row 8's eight scanlines
sit at `0x4800`, `0x4900` … `0x4F00`, so that is scanline 0 alone — and measured
against the very font the stub prints with, XORing `Session opened - CMD_INIT`
off and `Session lost - client gone` on differs in 12-17 columns on scanlines 1-6
and in **none** on scanline 0, because the top row of essentially every ZX glyph
is blank. **I had picked the one scanline on which two different strings cannot
differ.** The probe now covers the whole 2 KB the row can reach, which needs no
argument about which byte is safe to sample and survives any rewording of those
strings. The 96 is exactly 12+16+16+16+16+17+3, so the check measures precisely
what it claims to.

**A green check that cannot fail is worth less than no check**, and this one was
green for two runs. What caught it was refusing to accept the green: the control
was *known* to be a broken ROM, so a pass was a fact about the instrument.

**Also fixed, MINOR, and it is this file's own rule pointed at a parser.**
`esp_watch_line` kept only the last digit of an id, so `10,CONNECT` would have
recorded 0. Not reachable today — ESP-AT ids are 0-4 — but the 2026-08-05 entry
below says in terms that no value of a connection id is special and that this
transport must "encode nothing anywhere about its range, its first value or how
the module allocates it", and a single-digit parse **is** an encoding of range.
It accumulates now and refuses what will not fit a byte, exactly as
`esp_read_decimal` already does for a real `+IPD` header.

**Cost: WiFi +310 bytes**, `main_end` `0xF9CC` → `0xFB02`, 926 free to the
identity block. **The UART ROM is byte-identical** pinned (`b6ab6a13…`), which is
what says nothing shared moved — no common-code file was touched at all. **This
changes a ROM, so the merge carries a `make bump`.**

**Regression: `test-client-status` 6/6, `test-dzrp-stub` 15/15 with W1-W6,
`make test` 7/7, `test-unit` 5/5, `test-no-hang` 4/4, `test-screen-agreement`
all green, both variants `check-reproducible`.**

**NOT COVERED, and none of it is hidden.** A peer that stops answering *without*
its socket closing — the module emits no line, so nothing here can see it, and
that is KNOWN-ISSUES.md #2. A `<id>,CLOSED` eaten by a `transport_drain`; the
`<id>,CONNECT` fallback executes on every run but never as the *only* witness.
Payload **can** reach the observer in one window — a response filling
`ESP_TX_CHUNK` mid-message while its own payload is still owed (#13's three
handlers) — where nine specific bytes would give a wrong line and nothing else;
the first version of that comment claimed it could not. The `show_ui` hazard
above. And **real hardware**: nothing here has run on a Next, and the two line
spellings are jnext's.

---

## 2026-08-08 — The module gives a vanished peer's slot back by itself, in ~3 minutes

**Measured, not decided** (user's own Next), and it **overturns a belief three
other entries in this file assert**: that nothing but a power cycle ever
reclaims an inbound slot from a peer that vanished. The module reclaims it
itself, on `AT+CIPSTO`, and `KNOWN-ISSUES.md` #2 told users to power-cycle for
two days on the strength of a probe that had never asked the question.

**Five sites are annotated in place and NOT rewritten**: 2026-08-06's
`esp_recover` sweep entry, twice — its opening paragraph ("kept its inbound slot
for the rest of the power-on session") and its hardware run ("consumed
permanently per peer", "nothing giving one back"); the #15 probes entry ("a power
cycle is the only thing that does", and separately its jnext expectation "keeps
its slot for ever"); and **2026-08-05's issue #16 entry**, a different entry
again ("keeps its slot for the rest of the power-on session"). Each keeps its
original wording and carries a `CORRECTED 2026-08-08` parenthetical pointing
here, because this file records what was measured *then* and editing evidence to
match a later reading is the thing this project refuses. **This mattered more
than housekeeping: `MEMORY.md` is the file every session is told to read first,
so leaving them would have handed the next session precisely the belief this
work removed everywhere else.**

**IT TOOK THREE SWEEPS TO FIND FIVE SITES, AND THE REASON IS A NEW VARIANT OF
THIS FILE'S OLDEST DISEASE.** The first sweep was repo-wide and correct — it
found every site in `CLAUDE.md`, `doc/` and `test/` — but against `MEMORY.md` I
searched *around the three sites already known* instead of across the whole file,
so a fourth entry nobody had named survived. The second missed a site **in the
very entry it was annotating**, because the phrase *"kept its inbound slot for
the rest of the / power-on session"* **wraps across a line break**, and a
line-oriented `grep` cannot match a phrase that spans two lines.

So the rule this file already states needs one more clause. It said: the grep
must be for the thing being corrected, not for the words you think you wrote —
after markdown emphasis (`**any**` vs `*any*`) defeated a pattern in the M2
entry. Now: **and prose is line-wrapped, so the grep must be
whitespace-insensitive too.** What worked was normalising the file's whitespace
and searching the flattened text; it found all five in one pass, plus four
lookalikes about waits and budgets that correctly stay. A one-line `grep` over
wrapped prose is a sweep that silently under-reports.

**THE MEASUREMENT.** Two `--no-lift` runs of probe B, identical but for one
argument, with the firewall blackhole left **up** across the wait — so no FIN,
no RST and no retransmission of ours ever reached the module about those peers:

| `--recover` | phase 1 | walk | B3 |
|---:|---|---:|---|
| **210 s** | 4 vanished, the 5th refused | 13 s | **SERVED in 56 ms** |
| **100 s** | 4 vanished, the 5th refused | 13 s | **REFUSED, timed out** |

And the module names the mechanism when asked. Read off the machine with
`.UART`, on an Ai-Thinker ESP-01 at `AT version:1.2.0.0`:

    AT+CIPSTO?
    +CIPSTO:180

**`AT+CIPSTO` is the server's idle timeout, it defaults to 180 s, and this
module ENFORCES it** — which had been taken for a setting nothing acted on.
Cross-checked from the other direction: a DZRP client that connected, sent
`CMD_INIT` and then went quiet was dropped after **182.5 s** and **181.8 s**.
The reap is **per connection**, so the first slot back is the *oldest* peer's,
and what B3 really brackets is that peer's age: **(113 s, 223 s]**, the walk
being 13 s. 180 sits inside.

**It is not `esp_recover`, and that is excluded rather than waved away.** The
sweep is fault-counted — `ESP_FAULT_LIMIT` consecutive faults through
`rxtx_error` — with no timer anywhere in it. During phase 2 nothing transmits
and the blackholed peers are silent, so no fault can be raised. **A
fault-counted mechanism cannot produce a result that changes with elapsed time
alone**, and elapsed time was the only variable between the two runs.

**THE METHOD FAILURE IS THE TRANSFERABLE PART, AND IT IS NOT "NOBODY WAITED".**
Two independent defects in the instrument, and the interesting one is the first:

- **The ordering.** Probe B lifted the blackhole and *then* waited, so from that
  moment our own kernel was RSTing the module and any recovery was the module
  being **told**. "Does it give the slot back unprompted" was not answered badly
  — it was **unaskable**.
- **The horizon.** `--recover` defaults to 20 s against a 180 s timer.

**Fixing either alone leaves the question unanswered, and the horizon half is
subtler than it looks**: at the default 20 s the lift-first run came back
**served, in 71 ms** (2026-08-06). So the old path was never returning `no`; it
was returning an answer to a *different question*, which is a far better
disguise. A longer wait alone would have changed nothing.

**And the limitation was documented, correctly, the whole time.** Probe B's own
text said its recovery meant *"the slot comes back once the module is **told**"*,
and `doc/HARDWARE-TESTING.md` repeated it. Nobody read that true sentence as
*"therefore this instrument cannot answer the other question at all"*. **A
stated limitation is not a noticed one** — a new shade of this file's oldest
disease, and the mirror of its usual form: not a claim asserted beyond its
evidence, but a correctly-bounded claim whose bound nobody acted on.

**WONTFIX STANDS, ON FIRMER GROUND THAN WHEN IT WAS TAKEN.** #19 now declines to
spend Z80 bytes and the transport's multi-client behaviour on a fault that
clears itself in about three minutes, where before it was declining to fix one
that needed the power switch. The cost side is unchanged; the benefit side
shrank by two orders of magnitude. The compounding worry shrinks with it: five
leaks must now land within roughly **three minutes** of each other rather than
"between two power-ons", which on a machine left running was a window of days.
The **rate is still unmeasured** — narrowing the window is not measuring the
rate.

**AND IT RETIRES A WISH THIS PROJECT HAD WRITTEN DOWN.** `KNOWN-ISSUES.md` #2's
"why this is not fixed" asked for a module-side liveness mechanism — *"if it
exists, the module's own stack would decide liveness and the stub would need no
guesswork at all"* — and said only the real firmware or its documentation could
settle it, since no bench here could. `AT+CIPSTO` is that mechanism, present all
along and already doing the job.

**IT ALSO CUTS AGAINST "#15 IS #19", which is the first evidence pointing that
way.** A #19 exhaustion self-heals in ~3 minutes; #15 was two wedges the user
power-cycled out of. It **refutes nothing** — nobody recorded how long they
waited, and three minutes of a dead debugger is longer than most people's
patience — but the hypothesis now has something to answer.

**Interaction with #24, and both halves are measured rather than argued.**
Setting `AT+CIPSTO=1800` at bring-up buys an idle debug session that survives 30
minutes instead of dying at 3 — the fault a user actually meets, since a session
stopped at a breakpoint while somebody reads code is silent for minutes and
perfectly healthy. It costs exactly this self-heal, stretched to ~30 minutes.
Same timer, read from both ends.

**Rejected.** Rewriting the three stale entries below rather than annotating
them (this file records what was decided and measured *then*; editing evidence
to match a later rendering is what this project refuses); reopening #19 (the
fault is unchanged, only its recovery is); a follow-up comment on the closed
issue (docs are #19's home — one fact, one home); touching
`src/transport_esp.asm`'s `esp_recover` header, which carries the same stale
clause and is **issue #29**.

**NOT ESTABLISHED.** Which slot came back — no PC-side check sees connection
ids, and a 13 s walk cannot separate the candidates. That **180 is the number on
any other module**: `AT+CIPSTO` is settable 0-7200 and **`0` disables it
entirely**, on which module the old advice would be correct again. Whether the
module emits `<id>,CLOSED` when it reaps — nobody looked, and it bears on #23's
session line. And anything about a **wedged-but-reachable** peer: `AT+CIPSTO` is
an idle timeout so the same reaping is expected, but probe B stages only the
vanished case.

**Cost: documentation and one bench comment. No `src/`, no `Makefile`, no
`make bump`** — checked mechanically.

---

## 2026-08-08 — H1 closes its connection as a SESSION, not as a socket

**Decided (user) and built.** The hardware bench's first check opened a TCP
connection, confirmed the socket, and dropped it. That is a TCP event and not a
DZRP one, so the module emits `<id>,CLOSED`, the idle stub's `cmd_loop` wait
ends on it, it fails to parse as a `+IPD` header, and `drain_main` paints
**`Last Error: RX Timeout`** — making the bench's own first act put a fault on
the screen of a machine with nothing wrong with it. H1 now sends `CMD_INIT` and
`CMD_CLOSE` on that same connection before it goes.

**CONFIRMED ON REAL HARDWARE, both directions**, on the user's Next, with a
reader that sends no `CMD_INIT` of its own — because `cmd_init` clears
`last_error` and would erase the thing being measured:

| what the bench did | the stub's error area, read back over DZRP |
|---|---|
| bare connect, drop the socket (**old H1**) | `Last Error:` / `RX Timeout` |
| `CMD_INIT` then `CMD_CLOSE` (**new H1**) | **empty** |

**That also upgrades an emulator finding to hardware.** MEMORY.md 2026-08-06
recorded a client disconnect painting `RX Timeout` in jnext, and was careful to
say it is **not unconditional** — probe A read a clean area after three closes.
It is now seen on silicon, and the discriminator is visible: what leaves the
error is a close with **no DZRP session**, which is exactly what the old H1 did.

**THE SAME CONNECTION IS THE FIX, and a second one would not be.** Opening a
fresh connection to close tidily would leave the first one's bare drop, and the
error, exactly where they were.

**H1 still FAILS only on the connect**, deliberately. Its subject is "is
anything listening" and it gates the whole bench — a red H1 skips everything
below. A stub that accepts TCP but will not speak DZRP is a real finding that
belongs to H2, which has fifteen checks and a vocabulary for it; failing H1
instead would skip H2 and report the one thing as the other. So a failed
`CMD_INIT` here prints and passes, with the verdict line saying to see H2.

**The timing still measures the connect alone**, taken before any DZRP traffic,
so the number stays comparable with earlier runs.

**Evidence: `make test-hardware NEXT_IP=192.168.100.136` — 6/6 unchanged**,
15/15 conformance, H6 clean, and H1 now reads *"session opened and closed
cleanly"*. Test-harness only: no `src/`, no bump.
## 2026-08-08 — The whole suite passes on real hardware: 15 of 15

**Measured** (user's own Next, `192.168.100.136`, 12:37), and it retires a
contradiction three documents were carrying.

    H1  PASS  connected in 242 ms
    H2  PASS  15 of 15 conformance, 0 failed, 0 unsupported
    H3  PASS  two simultaneous connections each got their own payload
    H4  MEAS  20 samples: min 10.8, median 11.2, max 13.4 ms
    H5  MEAS  4096 bytes in 0.97 s — 8.3 KB/s round trip, 4.1 KB/s one way
    H6  MEAS  error area CLEAN, 0 bright-red pixels
    3 passed, 0 failed, 3 measured, 0 skipped of 6

**THE FIRST RUN CARRYING C13, C14 AND C15.** The 2026-08-05 run was 12 checks
because that was the suite's size then; #9 added C13/C14 and `CMD_CLOSE` added
C15 afterwards. Every check in the conformance suite has now executed on
silicon, which four documents said had not happened.

**What it corrects.** `CLAUDE.md`'s NOT-run list, `doc/HARDWARE-TESTING.md`'s
summary and two places in `doc/DZRP-TESTING.md` all claimed the newest checks
had never been driven at a Next. All four are fixed, and
`doc/HARDWARE-TESTING.md` now carries this run as its own results table beside
the 2026-08-05 one.

**A FORENSIC PARAGRAPH WRITTEN HOURS EARLIER IS DELETED, and that is the
process lesson.** A review had found `doc/DZRP-TESTING.md` claiming "12 of 12
and then 14 of 14" against `HARDWARE-TESTING.md`'s "never run on silicon"; I
removed the unsupported half and wrote a careful paragraph reconstructing which
sentence to believe, then asked the user to adjudicate. **The answer was that
the question was irrelevant** — the suite is 15 now and it runs. Preserved
*history* earns its place in this file; a preserved *argument about which of two
stale sentences was right* does not, once a measurement settles it. **When a
contradiction can be resolved by running the thing, run the thing rather than
reasoning about which document to trust.**

**The measurements agree with the post-#11 figures**, not with 2026-08-05's:
median 11.2 ms against 11.3-11.5 then and 13.0 before, 8.3 KB/s against 8.3. So
the `+IPD` capture fix still costs nothing measurable, now at the suite's full
size.

**NOT captured: the build number.** DZRP's `PROGRAM_NAME` reports upstream's
`dezogif v2.2.1`, not our identity block, which is only readable off the stub's
screen. So this run cannot be tied to a build the way the `000A` one can, and
the docs say so rather than assuming it was `0012`.

**Cost: documentation only**, no `src/`, no bump.

---

## 2026-08-08 — M2 is feasible, is the only mechanism, and costs the debuggee its Copper

**Evaluated before writing any code** (user's ask), and written up as
[doc/ASYNCHRONOUS-BREAK-DESIGN.md]. **Verdict: buildable, and OPT-IN rather
than default.** The evaluation moved three things and added two.

**ANSWERED — open question 5b, which the plan said to settle before writing
M2's entry path: a Copper-caused NMI CANNOT be told from a CPU-caused one.**
`zxnext.vhd:4775-4777` muxes both onto one bus with no tag before
`nmi_gen_nr_mf` computes, and the latch is one untagged bit; nothing in NR
`0x02`, NR `0xC0`, NR `0xDA`, `nmi_state` or `device/multiface.vhd` records a
source. **But the question presumed a need the design does not have**: if the
handler's contract is "poll, and break only if there is traffic", a debuggee's
own write costs one wasted poll. Shape the entry path around the poll and the
impossibility stops mattering. That reframing is the decision; the VHDL is just
the fact.

**THE COST THE PLAN UNDERSTATED: the Copper list is WRITE-ONLY.** Both
instruction RAMs discard their CPU-side read output (`data_a_o => open`,
`zxnext.vhd:3959-3976`, `:3980-3998`) and NR `0x60`/`0x63` have no read decode
(`:6286-6287`). So the debugger cannot save and restore a debuggee's Copper
program — installing ours **destroys** it. "Consumes the Copper, which the
debuggee may want" is now struck in §4.3. The same asymmetry as the sprite
ports (#9), and just as easy to miss because `ram/dpram2.vhd` *does* offer a
port-A read; the instantiation throws it away.

**AND THE BREAK CAN BE SWITCHED OFF SILENTLY, WITH NO WAY BACK.** NR `0x06`
bit 3 gates every MF NMI source, and a write of NR `0x62` that **changes** the
mode bits restarts the list from index 0 (`device/copper.vhd:69-78`) — not just
a disable, though not every write either: the guard is `last_state_s /=
copper_en_i` and the reset sits inside a further test for mode `01`/`11`. The plan's
mitigation was "re-assert from the poll", and that **cannot work**: once the
Copper stops, the poll is the thing that would have re-asserted it. Recovery is
an M1 press, i.e. the button the feature exists to remove. Best-effort, and the
user documentation has to say so.

**No fallback exists, which raises the stakes on accepting those costs.** Every
other candidate was traced to where it lands: the line interrupt (NR
`0x22`/`0x23`), the UART RX interrupt and the DMA/CTC sources all terminate in
the **maskable** INT bus and never reach `nmi_activated`; the I/O trap fires on
a debuggee access rather than on time; the expansion-bus NMI needs hardware
plugged in. **The Copper is the only periodic NMI source on the machine.**

**A landmine found on the way, and upstream's code survives it by one mask.**
NR `0x02` bits 1:0 *written* trigger a soft/hard reset (`zxnext.vhd:6370-6371`)
while *read* they are reset history and are non-zero in ordinary operation
(`:1306`, `:1732-1739`). The handler clears the cause latch every frame, so
read-modify-write of that register would reset the machine 50 times a second.
`nmi66h`'s existing `and 10000000b` is what prevents it — **load-bearing, and
M2 must not lose it**.

**A CLAIM OF MINE FROM YESTERDAY, CORRECTED BY EXPERIMENT.** I recorded that
the MF ROM half "cannot grow". It grows in 16-byte steps: moving
`ROM_MAGIC_ADDR` down by the same 16 keeps the identity block at file offset
`0x1FE0`, and **the offset is the contract, not the address** — mfselect parses
the file. Probed: builds clean, ROM still 8192, block still readable, 76 steps
available in the WiFi build. Left standing, that claim would have told the next
session M2's entry path was blocked when it is not. Corrected in place in
CLAUDE.md and beside the original here.

**Two things this hands M2 for free, both from #26.** `MF.nmi_slot7` is exactly
the state the poll's exit needs — the poll fires while the *debuggee* runs, so
unlike the existing immediate return it must restore slot 7, and getting that
wrong is #26 again. And MF RAM is established as the place for NMI-entry state
that must be readable before `MAIN_BANK` is paged in, which is where the
"is a debuggee running" flag belongs.

**Rejected.** Making async break default (it destroys the Copper silently);
using the UART RX interrupt as the poll (it is maskable and depends on the
debuggee's IM2 setup — the plan already ranks it third, and the trace confirms
why); trying to preserve the debuggee's Copper list (there is no read path, so
this is not a trade-off but an impossibility); leaving 5b open (it is answerable
and the answer changes the design's shape).

**NOT ESTABLISHED, and §6 of the document says so at length.** No M2 code
exists; the ~0.3%/frame figure is unmeasured and the current entry path is 82
instructions, far larger; the unsolicited-`+IPD` decision in §4.3 is unmade and
has a user-visible cost either way; **jnext's Copper model has not been checked
against the NR `0x62` restart behaviour** the silent-failure claim rests on,
which a headless M2 bench would need; and DMA as a third writer of NR `0x02` was
not traced.

**Cost: two source files touched, COMMENTS ONLY, and no `make bump`.** The
mechanical check lists `src/constants.asm` and `src/main.asm` because the
byte-budget correction had to reach the two comments that contradicted it —
`NEVER MOVE THIS` sat directly above the constant M2's entry path may have to
move, which is precisely the reader it would have misled. So the **certain**
answer was taken rather than the conservative one, as on 2026-08-07: both ROMs
hash identically to `main`'s pinned with `build/*.bin` deleted first
(`b6ab6a13…`, `14c82d7f…`). Comments do not assemble.

**Three review findings, and the one that matters is a lesson this file already
carries.** A claim of "any write of NR `0x62` restarts the list" reached the
plan's Appendix A **verified** ledger; the VHDL guards it on the mode bits
*changing*, and on the new mode being `01`/`11` (`device/copper.vhd:69-78`) —
and my own document said the correct thing one line below the wrong headline.
The reviewer also found the two contradicting source comments above, which my
"corrected in three places" had missed, and a signal name (`im2_int_source`)
that exists nowhere in the VHDL — invented while paraphrasing a correct line
citation. **A citation is not a quotation**, and the ledger tier is exactly
where that distinction has to hold.

**AND THE FIX FOR THAT OVERCLAIM MISSED A FIFTH SITE, WHICH IS A NEW AND
NAMEABLE VARIANT OF THIS FILE'S OLDEST DISEASE.** I reported "reworded in all
four sites"; the plan's **M2 milestone paragraph** — the most prominent thing
anyone picking up M2 reads — still said *any* write. It survived two greps, mine
and the reviewer's first pass, because the other four sites wrote it `**any**`
and this one wrote it `*any*`: **markdown emphasis defeated the pattern**. The
enumeration that worked was to grep for the *subject* (`0x62`) and read every
hit, rather than for the *phrasing* I remembered using. Same for the stale
`copper.vhd:70-83` citation, which was found by grepping the line range instead
of the claim.

So the rule this file keeps restating needs one more clause: a correction is not
finished until a grep says so, **and the grep must be for the thing being
corrected, not for the words you think you wrote.**

[doc/ASYNCHRONOUS-BREAK-DESIGN.md]: doc/ASYNCHRONOUS-BREAK-DESIGN.md

---

## 2026-08-07 — The reset path is fixed ON A REAL NEXT, and the run tested both arms

**Measured, not decided** (user's own machine, build `00.12`), and it closes
issue #26. `.mfinstall --auto` in `AUTOEXEC.BAS` throughout, so a soft reset
reinstalls whatever the config says:

| | action | result |
|---|---|---|
| 2 | power cycle — autoexec installs WiFi | |
| 3 | NMI | stub appears |
| 4 | **R** — the stub's own soft reset | machine reboots |
| 5 | NextZXOS boots, autoexec reinstalls | |
| 6 | NMI | **stub appears** |
| 7 | `.mfinstall --configure none` | autoexec will install nothing |
| 8 | NMI | stub appears |
| 9 | NMI **again** | **nothing happens** |
| 10 | **R** | reboots; autoexec installs **nothing** |
| 11 | NMI | **stub appears** |
| 12-13 | R, NMI | **stub appears**, repeatably |

Before this fix, step 6 was the reported failure: the press did nothing and the
machine locked up shortly afterwards, recoverable only by power-cycling.

**STEP 9 IS THE MOST VALUABLE LINE IN THE RUN, AND IT IS NOT A DEFECT.** With
the stub already up, the debugger *is* executing and slot 7 genuinely holds
`MAIN_BANK`, so the guard takes the immediate return and does nothing — which
is upstream's intent. **The risk in this change was always the other
direction**: a test that sent *every* press to `init_main_bank` would have
destroyed live sessions, which is why the ordering against `PRGM_RUNNING` was
called the whole risk when it was written. Step 9 shows it declines correctly
while 6/11/13 show it re-initialises correctly: **both arms of the
discriminator, on silicon**, which **no bench here does today** — T7 presses
twice with a reset between, and nothing presses twice without one.

*(**CORRECTED 2026-08-10, and ONE CLAUSE ONLY: "nothing presses twice without
one" is now false.** Bench check **T8** does exactly that — two presses, no
reset between — and is in `make test`; issue #36, and the entry at the top of
this file. So the follow-up the paragraph below leaves open is **built**, and
with the liveness control that paragraph correctly says it needed: the border,
after a "B" pressed AFTER the second press. **Everything else in this passage
was true when written and is why T8 exists at all** — the decline arm really was
guarded by one hardware observation and nothing else, and a regression sending
*every* press to `init_main_bank` really would have left T7 passing, which was
measured against exactly such a ROM when T8 was built: T1-T7 green, T8 the only
red. This is annotated rather than rewritten because a reader landing here by
grep or by following a citation would otherwise meet the falsified half with
nothing attached to it — MEMORY.md's own 2026-08-08 rule, this file being the
one every session is told to read first.)*

**"No bench here CAN do it" is what this entry said first, and the reviewer
disproved it by running it.** Two headless jnext runs, both shot at the same
absolute frame, one with a single NMI at 900 and one with a second at 950:
**byte-identical, 0.00%**. So the decline arm is perfectly producible with
`--delayed-nmi-frames` — which queues, as this repository already knew — and
the honest claim is about what is *written*, not about what is *possible*. It
is a small addition to `run-headless.sh`'s existing machinery and is left as a
follow-up rather than bolted onto a documentation commit, since a check whose
PASS is "nothing changed" needs a control designed for it before it is worth
anything. (The reviewer's first two attempts compared shots taken hundreds of
frames apart and showed a spurious 40%, from a border artefact; shooting both
at the same frame is what isolates the variable — the FLASH-alignment rule T7
already follows, met again from the other side.)

Step 9 also proves the machine was **alive**, not wedged: step 10's `R` worked.
That is the discriminator KNOWN-ISSUES.md leans on for telling a live stub from
a dead one, applied by hand.

**STEPS 10-13 ARE THE CONFOUNDER-FREE HALF, and the user spotted the confounder
before I did.** At step 6 `autoexec` reinstalls the ROM, so a sceptic could
credit the reinstall. After `--configure none` nothing rewrites anything and the
result is unchanged. (The reinstall was never a real confounder — `--load`
writes Multiface SRAM while the stale state lives in bank 94, which it never
touches — but 10-13 removes the argument rather than answering it.)

**WHAT IS NOT VERIFIED ON HARDWARE, and it is a decision rather than an
oversight.** The **second** defect — the M1 press taken while the debugger is
stopped at a breakpoint, which used to overwrite the debuggee's saved slot-7
bank — is **emulator-only**, by the user's call (2026-08-07): testing it needs a
DeZog session driven proficiently, and they declined to learn DeZog for it. Its
evidence is bench W6 and nothing else. The **stale `PRGM_RUNNING`** residual is
untouched by this run too; nothing ran a debuggee.

**Tier: `reported on hardware`.** One machine, one reporter, no artefact anyone
can re-run — the rung this project added on 2026-08-04 for exactly this. It is
the strongest evidence obtainable for the question and still weaker than a
re-runnable check, and the distinction is kept because the emulator has twice
sat on the safe side of us (a connection id of 0, a 15-character address).

**Cost: nothing.** Documentation only — no `src/` file changed, so no `make
bump`, checked mechanically.

---

## 2026-08-07 — One byte answered two questions; issue #26's second defect

**Built, issue #26, and it is the defect the independent reviewer of the first
fix found by reading the routine the fix was in.** `mf_rom.asm`'s NMI entry
path read the bank in `MAIN_SLOT` and wrote it to `slot_backup.slot7` on
**every** button press, before the dispatch had decided anything. Two different
questions were being answered from that one byte, and they only have the same
answer on one of the three paths out:

| asked by | means | true when |
|---|---|---|
| the dispatch (#26's first fix) | *who was executing?* | every press |
| `restore_registers` | *which bank does the debuggee get back?* | a **running** debuggee was interrupted |

While the **debugger** executes, slot 7 holds `MAIN_BANK`. So an M1 press taken
while the debugger was **stopped at a breakpoint** overwrote the debuggee's
bank — saved by `dbg_enter` when the `RST 0` was taken — with the debugger's
own, and the next `CMD_CONTINUE` would page `MAIN_BANK` into the debuggee's
slot 7 (`backup.asm:144` reads it, `breakpoints.asm:66` installs it).

**THE FIX SEPARATES THE TWO QUESTIONS RATHER THAN CONDITIONALISING THE WRITE,
and that ordering matters because the first fix reads the same byte.** The
entry path now stores into `MF.nmi_slot7`; the dispatch tests *that*; and only
`.break_into_debuggee` — the one path on which the value really is the
debuggee's bank — copies it into `slot_backup.slot7`. Conditionalising the
original write instead (`skip it when the value is MAIN_BANK`) was tried first
in the design and is **wrong**: it would have left `slot_backup.slot7` holding
the debuggee's bank at the moment the dispatch reads it, so #26's own guard
would have seen "not MAIN_BANK" and sent every press taken while stopped
through `init_main_bank`, destroying the live session. Two fixes in one routine
reading one byte for opposite purposes is exactly how that goes wrong.

**It lives in MF RAM, and that is a byte-budget decision as much as a semantic
one.** `MF.nmi_slot7` sits beside `MF.backup_sp` at `0x2000+`, which is
Multiface RAM and **not part of the 8192-byte ROM image**, so the storage is
free. It also *is* NMI-entry-scoped state, like `backup_sp`, rather than
debug-session state.

**THE MF ROM HALF IS NOW EXACTLY FULL, and the next person needs to know
before they try.** `mf_nmi.bin` is `ALIGN 16`-ed to `0x140`; the identity
block's file offset is `0x140 + (0xFEA0 - 0xE000)` = `0x1FE0`, a permanent
contract (#4). #26's first fix took the padding from 15 bytes to 6, and this
one takes it to **0**. One byte more moves `main_prg_copy` to `0x150` and the
block to `0x1FF0`. `main.asm`'s `ASSERT` catches it at assembly time, so the
failure is loud — but "add a check to `nmi66h`" is no longer a free action, and
that is now in CLAUDE.md §Building beside the contract it protects.

*(**CORRECTED 2026-08-08, and the correction matters because this paragraph
would otherwise have blocked M2.** It reads as though the half cannot grow at
all. It can: moving `ROM_MAGIC_ADDR` down by the same 16 keeps the identity
block at file offset `0x1FE0`, which is what mfselect parses — the **address**
is not the contract, the **offset** is, and the `ASSERT` enforces precisely the
relationship that preserves it. Probed rather than argued: +16 bytes with the
constant moved builds clean, the ROM stays 8192 and the block still reads.
The WiFi build has over a kilobyte of headroom, i.e. many such steps. "No longer a free action" stands;
"cannot" was wrong. See [doc/ASYNCHRONOUS-BREAK-DESIGN.md] §4.5.)*

*(**CORRECTED 2026-08-09, and the corrected sentence is the one above's own correction — which is
why it is annotated here rather than quietly fixed.** "Over a kilobyte of headroom, i.e. many such
steps" is wrong twice. The ceiling is not the identity block at `0xFEA0` but the **RAM font buffer at
`0xFBC0`**, 736 bytes lower, which `main_bank_entry` fills and which nothing in the source emits a
byte into — so the WiFi build's real headroom was **119 bytes**. **Issue #31 then removed that
buffer**, reading the glyphs from the ROM instead, which puts the ceiling back at the identity block
and the WiFi figure at **818**. What survives is the other half of the error: a 16-byte step still
spends 16 bytes of the debugger half, because the image ends at `0xE000 + 0x2000 - MF.main_prg_copy`
and `ROM_MAGIC_ADDR` moves down with it — probed, one step put the old buffer at `0xFBB0` with
`main_end` unmoved. So "many such steps" was wrong either way.)*

[doc/ASYNCHRONOUS-BREAK-DESIGN.md]: doc/ASYNCHRONOUS-BREAK-DESIGN.md

**Evidence: bench check W6, a sixth run of `make test-dzrp-stub`, shown red
first — and the red is the trace turned into a measurement.**

| | slot 7 before the press | after |
|---|---|---|
| `main`'s ROM | 30 | **94** (`MAIN_BANK`) |
| as built | 30 | **30** |

**It is observable over a socket at all because `CMD_GET_REGISTERS` reports
slot 7 from `slot_backup.slot7` rather than from the MMU** — the last byte of
its payload. `CMD_SET_SLOT` for slot 7 is the mirror image: it writes only the
saved value and touches no MMU register. So the whole check is DZRP in and DZRP
out, with no screenshot and no emulator introspection.

**THE PRESS IS LOCATED IN TIME BY jnext's OWN LOG, NOT BY A SLEEP.** It has to
land between the two reads; `--delayed-nmi-frames` counts emulated frames while
the client counts wall clock, and the frame rate collapses under DZRP traffic —
the same mismatch that makes an NMI against a *running* debuggee unschedulable
here (2026-08-05, below). So the bench waits for the delivery line and only then
releases the client through a sentinel, and asserts the count afterwards as W4
does.

**AND THAT COVERS ONE EDGE OF THE WINDOW, WHICH THE FIRST VERSION CLAIMED WAS
BOTH.** The sentinel stops the press arriving *after* the second read. Nothing
but a frame count stopped it arriving *before* the setup — and that is the
direction that fails **green**, because `CMD_SET_SLOT` would overwrite whatever
a corrupting press had just written and no second press would remain to observe.
The reviewer found it by **measuring** rather than reading: across two runs of
the identical script on an idle machine the margin was **149 ms** and **2 ms**.
So the schedule is wider now (3000 frames, free — the client is idle while they
elapse) *and* the ordering is asserted from the log: three commands must have
arrived before the press, or the run fails red as a precondition. Measured
after: the margin is **17.2 s** and exactly 3 commands precede the press.

**AND THE PRECONDITION WAS WATCHED TO FIRE, ON THE FAILURE IT EXISTS FOR.**
`SECOND_NMI_FRAMES` is `?=`-overridable — the seam the `IP_MAX` / `RX_WAIT` /
`LINK_IDS` family already uses, so the control is re-runnable rather than a
story about a scratch tree. At `SECOND_NMI_FRAMES=901` the press lands before
the client has spoken, and **the client duly reports `before=30 after=30`** —
the exact green a corrupting ROM would produce — while the precondition goes
red with *"0 commands had arrived, needed 3"*. That is the reviewer's scenario
reproduced, and the demonstration that without the assertion this check would
have passed on a broken stub.

A margin nobody measured, called "by construction", is this file's recurring
disease in its harness costume.

**Two harness bugs, both found by the red-first run rather than by reading it**,
and both worth recording because each would have produced a *wrong verdict*
rather than an error:

1. `CMD_GET_REGISTERS`'s **payload is 37 bytes**, not the 38 in
   `commands.asm` — that 38 is the *response length*, which counts from the
   sequence byte. The two directions' length conventions have now cost this
   project twice (the first is [[#DZRP's two length conventions]]).
2. **The bench's own log level hid the evidence.** `--log-level warn,esp01=debug`
   suppresses the `platform`/`info` line that reports a delivered NMI, so the
   first run reported **0 of 2 presses** against a stub that had demonstrably
   taken one. Raised for the runs that schedule a second press, and only those.

**A VHDL LOOKUP MADE THE FIRST FIX'S DISCRIMINATOR STRONGER THAN IT WAS
ARGUED.** #26's guard rests on slot 7 not being `MAIN_BANK` after a reset, which
was justified as "whatever NextZXOS left there". It is better than that: a soft
reset restores **all eight MMU slots unconditionally**, slot 7 to bank `0x01`
(`zxnext.vhd:4610-4618`). So the guard is hardware-guaranteed on that path, not
dependent on firmware habit.

The same lookup **disproved** a candidate this session generated: NR `0x06`
bit 3 is **not** cleared by a soft reset. It is untouched by **either** kind of
runtime reset — the synchronous `if reset = '1'` block covering NR `0x06`
resets `nr_06_hotkey_cpu_speed_en` and `nr_06_hotkey_5060_en` and does not
mention bit 3 at all, and that `reset` is the same combined
`reset_hard or reset_soft` the MMU reset above uses — so only FPGA
configuration or power-on puts it back to its declared initial value. An M1
press after a soft reset therefore still generates an NMI, which is what makes
#26 reachable at all.

*(A first version of this paragraph said bit 3 "goes only on the
flashboot/hard-reset path", which overstates what a hard reset does and was
caught in review. The conclusion is unchanged — a fortiori — but this project's
first hard rule is that the VHDL is the authority, and a paraphrase that is
directionally right and specifically wrong is exactly what [[ERRORS.md]]
exists for.)*

**A THIRD VARIANT IS REAL, UNFIXED, AND NOT FIXABLE IN THE BYTES AVAILABLE.**
If `prgm_state` is stale **`PRGM_RUNNING`** — a machine reset while a debuggee
was running — the dispatch still takes `.break_into_debuggee` and breaks into
NextZXOS with stale state. It is **milder** than what #26 fixed (the debugger
legitimately owns slot 7 on that path, so the fatal "MAIN_BANK left mapped
under NextZXOS" mechanism is absent) and it is **unverified**: jnext has no
headless reset button, so staging it needs a debuggee that resets the machine
itself, which nothing here does. The VHDL offers one usable discriminator —
`NR 0x8C`'s reset copies bits 3:0 into 7:4, and `altrom.asm` only ever writes
the high nibble, so a soft reset effectively clears the AltROM enable the
debugger sets and never removes. Not implemented: it needs ~8 bytes the MF ROM
does not have, and this project does not put unverified mechanisms in the NMI
path. Recorded on #26 instead.

**Rejected.** Conditionalising the entry-path write (above — it breaks #26's
own guard); a new byte in the debugger's data image rather than MF RAM (costs
ROM the MF half no longer has); a unit test instead of a bench check
(`ut_nmi.asm` patches `nmi66h.is_button_cause` precisely to avoid running the
entry path, and running it for real under `MF_FAKE` would take
`init_main_bank`'s `MEMCOPY` from an empty `main_prg_copy` and destroy the
debugger under the test); asserting the press with a sleep (fails green).

**Also observed, and it is NOT this branch's:** W5's precondition — the
deliberately-raced `+IPD` collision — failed to arise in **1 of 3** runs today,
on both the pre-fix and the fixed ROM. It reports that honestly as a FAIL
rather than passing vacuously, which is the bench working as designed, but it
is flaky and somebody will meet it.

**Cost: +6 bytes of ROM, both variants, `main.bin` and `main-wifi.bin`
byte-identical pinned** (`413f5172…`, `2748b387…` either side at build `0011`)
— so nothing outside `mf_rom.asm` moved. ROMs: UART `92624073…` → `ea1379a2…`,
WiFi `47435c37…` → `305fbd33…`. **This changes a ROM, so the merge carries a
`make bump`.**

**Regression: `make test` 7/7, `test-dzrp-stub` all green with W1-W6 and 15/15
conformance, `test-unit` 5/5, both variants `check-reproducible`.**

**HARDWARE, added the same day and split deliberately.** The ROM this entry
produces was run on a real Next and the **first** defect's path is confirmed
there — see the entry at the top of this file. **This entry's own defect, the
press taken while stopped, was NOT**: it needs a DeZog session driven at the
machine, and the user declined (2026-08-07), so W6 in the emulator is the whole
of its evidence and this paragraph is what stops a reader inferring otherwise
from the run that happened.

---

## 2026-08-07 — The NMI decline is keyed on who was EXECUTING, not on what RAM holds

**Built, issue #26 — a five-year-old upstream defect, diagnosed the day before
and fixed as specified there.** On a button NMI, `mf_rom.asm`'s dispatch read
"magic number and build time match in `MAIN_BANK`, and no debuggee is running"
as *"the debugger is already executing — decline"*. A soft reset falsifies that
inference without touching its evidence: RAM survives one, so the same two
facts then mean **a stale image with NextZXOS executing**. And the decline was
not merely useless there — the entry path had already paged `MAIN_BANK` into
slot 7, and `mf_nmi_button_pressed_immediate_return` restores the NextREG
select, the turbo mode and the MF paging but **never slot 7** — correct when
the debugger really was executing (slot 7 already held `MAIN_BANK`),
catastrophic when NextZXOS was, which got its machine back with the debugger's
bank at `0xE000` and hung as soon as anything touched it.

**THE FIX IS SIX INSTRUCTIONS AND ONE ORDERING CONSTRAINT.** When
`prgm_state` is not `PRGM_RUNNING`, the decline is now gated on
`slot_backup.slot7` — the bank slot 7 held at the moment of *this* press,
which the entry path saved five instructions earlier. The debugger executes
**from** `MAIN_BANK` in slot 7, so any other value proves it was not
executing, and the dispatch falls through to `init_main_bank`, which recopies
the image and comes up fresh. **The test MUST stay after the `PRGM_RUNNING`
one**: while a debuggee runs, slot 7 holds the *debuggee's* bank, and testing
slot 7 first would send every manual break — the path verified on real
hardware 2026-08-05 — through `init_main_bank`. That ordering is the entire
risk in the change, and the comment in the source says so.

**Cost: +9 bytes, entirely inside the MF ROM's ALIGN padding.** The dispatch
lives in the 8 KB image's first `0x140` bytes, whose end is pinned by the
identity-block contract (`main_prg_copy` must sit at `0x140` or the block
leaves ROM offset `0x1FE0`). Padding was 15 bytes; it is now 6. `main.bin`
and `main-wifi.bin` are **byte-identical pinned** (`0a0676d4…`, `1caa298d…`
unchanged) — the debugger image itself did not move — but both ROMs' bytes
change with their `mf_nmi` halves: UART `efc73695…` → `8aa20230…`, WiFi
`f065776c…` → `d117e122…`, **so the merge carries a `make bump`**.

**Evidence: bench check T7, shown red first.** `make test` gains two runs and
one check — the only one that presses the button twice, which is why five
years of upstream and every bench here missed the defect: nothing ever put a
reset *between* two presses. Both new runs boot, NMI (the stub comes up),
press the stub's own `R` (a soft reset), and let NextZXOS boot again; the
second run alone presses NMI once more, and both shoot at the same frame —
`SHOT_FRAMES + 36*32`, keeping every compared pair at one point in the FLASH
cycle. Against `main`'s ROM: T1-T6 green, **T7 red, `0.00% changed`** — the
decline, byte-identical screens. With the fix: **7/7, T7 at 90.32%
repainted** and byte-identical to the stub's own screen from run 6 (the probe
measured C vs A at exactly 0.00%).

*(**CORRECTED 2026-08-10, four words of it: "the only one that presses the
button twice".** **T8** presses twice as well, with no reset between — issue
#36. Checked rather than assumed to be safe, because the rest of this paragraph
is a **record of what was run** and stands untouched: the two runs, the frame
arithmetic, `7/7`, and `T7 red at 0.00%` against `main`'s ROM all describe the
bench as it was on 2026-08-07 and are not claims about today. The explanation
attached to the stale clause also stands — nothing before T7 ever put a reset
*between* two presses, which really is why the defect survived five years. And
`make test` is **8/8** now, not 7/7, which is the other number here a reader
should not carry forward.)*

**T7's preconditions are what keep it from passing vacuously, and one is
asserted from jnext's own log.** `--delayed-nmi-frames` QUEUES rather than
overrides (its help says so; discovered the day before) — but a jnext that
dropped the first press would make run 8 a *first* press, whose takeover
passes the pixel diff while never touching the path under test. So T7 counts
the `Delayed NMI button` lines out of the run's log and requires exactly 2,
W4's pattern. The second precondition is that run 7 differs from the stub
screen at all — i.e. the `R` key really reset the machine — without which
"the decline survived a reset" was never staged. And the takeover must *look
like* run 6's stub screen, T6's lesson that a difference measure does not
know what it is looking at.

**Rejected.** Testing `slot_backup.slot7` before `prgm_state` (breaks manual
break, above); a separate bench target for the probe (T7's subject is the NMI
path, it binds no port and needs nothing external — `make test` is exactly
its home); asserting only that runs 7 and 8 differ, with no log precondition
(vacuous-pass hazard, above); keeping the scratch probe as the only evidence
(a red nobody can re-run is a story about a scratchpad).

**NOTICED, TRACED, AND DELIBERATELY NOT FIXED HERE — a second defect of the
same family, upstream's as well.** `mf_rom.asm`'s entry path writes
`slot_backup.slot7` on **every** button NMI, before any decision. Press M1
while the debugger is **stopped at a breakpoint** and that write clobbers the
debuggee's saved bank with `MAIN_BANK` (slot 7's content while the debugger
executes), so the next `CMD_CONTINUE` restores the *debugger's* bank into the
debuggee's slot 7. The immediate-return path this branch fixes is exactly the
path such a press takes, and the fix keeps it correct — the clobber is the
save it reads. **This is a trace, not a run**: nothing has executed it, no
bench presses M1 while stopped, and the hardware manual break of 2026-08-05
was against a *running* debuggee. It is **not fixed here** — this branch is
scoped to #26's decline — and, as of this commit, **not filed either**: it
needs its own issue, and a GitHub write needs the user's go-ahead, which was
not available. Whoever reads this next should check that it was filed.

*(An earlier version of this paragraph said "filed as its own issue", which
was **false** — no such issue existed, and the independent reviewer rejected
the branch over it. A decision log this project tells every session to read
as ground truth is the worst place to assert an action nobody took. The
lesson is this file's oldest: **do not write down a thing as done because it
is the thing that ought to happen next.**)*

*(**RESOLVED the same day, and not by filing it.** The user's call was that it
is part of getting the reset hang fixed and therefore stays on #26 rather than
becoming a new issue — so "check that it was filed" above is answered: it was
not, deliberately. It is **fixed**, with bench check W6, in the entry at the
top of this file.)*

**NOT COVERED — the first clause of this paragraph was OVERTAKEN the same day;
see the entry at the top of this file.** ~~The fixed ROM has not been through
reset-then-NMI on **hardware**~~ — it has, on the user's own machine at build
`00.12`, repeatably and with the autoexec reinstall removed as a confounder.
The 2026-08-07 hardware breakage that opened #26 was build
`0010`, and T7's green is jnext's word. The testable prediction that
upstream's own released `enNextMf.rom` fails the probe identically remains
un-run. And T7 resets from the stub's `R` key only; a reset from NextZXOS's
own menus between two presses is the same mechanism by inspection, but no run
stages it.

---

## 2026-08-07 — `.mfinstall --configure` writes the config; the YAML loses its comments

**Decided (user) and built.** `.mfinstall --configure wifi|uart|none` writes
`/mfselect/mfinstall.yml` and **does nothing else** — no ROM is loaded, unloaded
or touched — and the shipped file is now one line, `install: wifi`, with no
comments at all.

**IT EXISTS BECAUSE THE FILE CANNOT BE EDITED ON A STOCK NextZXOS** (user,
2026-08-07, from using it). A config file only reachable by putting the card in
a PC defeats the point of a tool whose whole argument is not needing one: #21's
case against the file swap was that `AUTOEXEC.BAS` is changeable from the
machine, and a config the machine cannot change puts the PC back in the loop one
step along.

**THE VERB IS ORTHOGONAL TO THE OTHER TWO, and that is the decision rather than
the name.** `--load` installs now; `--auto` obeys the file; `--configure`
decides what `--auto` will do at the **next** boot. It was offered as
`--install` and the user renamed it — rightly, since `--install` next to
`--load` reads as a second way to install, which is the one thing it does not
do. It is handled in the argument loop and **returns there**, the way `--help`
does, so `--configure wifi --load uart` has no meaning to argue about.

**Comments are gone by decision, and the reason is mechanical rather than
aesthetic.** `read_config()` reads 511 bytes **once** and scans only those, so a
preamble is a thing that grows until `install:` falls out of the window and the
file becomes unreadable to the program that wrote it. Documentation lives in
[doc/MFINSTALL.md]; the file carries the value. The Makefile's 511-byte guard
stays and now aims at a file a **user** has edited by hand, which is the only
way a preamble can get in.

**THE WRITE IS NOT ATOMIC, AND THAT IS A PROPORTIONALITY JUDGEMENT rather than
an oversight.** `ESX_MODE_OPEN_CREAT_TRUNC` destroys before it constructs — the
exact shape [[ERRORS.md]] records as a data-loss bug in mfselect's backup — so
an interrupted write leaves a file that is present, short and unreadable to
`--auto`. The ROM writes answer that with write-temp-then-rename, worth its
complexity for 8192 bytes that cannot be recreated; this is **fifteen bytes we
have in hand**, so the proportionate answer is to **notice** instead: the file
is read back through `read_config()` and a mismatch is reported. Rejected:
temp+rename for fifteen bytes; and saying nothing, which is what makes a
truncated config look like a missing one.

**A CLAIM THIS FALSIFIES, AND THE FIRST SWEEP FOR IT MISSED ONE.** "The SD card
is never written" was this tool's headline safety property — in the module
docstring, in [doc/MFINSTALL.md], in `README.md`, **on the Next's own `--help`
screen**, and — found by the reviewer, not by me — in
[doc/CONFIG-MODE-ROM-REPLACEMENT.md]'s Appendix A status table, where it was a
whole row. `--configure` makes it false as stated. It is now "no ROM is ever
written to the SD card", with `--configure` named as the exception in each
place, because what the claim was ever protecting is the ROM images and that is
unchanged.

**I asserted "four places" in the commit message while the fifth was still
there**, which is this file's most-repeated lesson wearing its usual costume: I
greped the files I was thinking of rather than the repository. The count is not
restated here on purpose — a `grep` for the phrase is the record, and a number
in prose is a thing that goes stale the moment somebody writes the sentence
again.

The `--help` rewrite is the one that had to fit 32 columns, and **the
compile-time `FITS()` assert caught a 33-character line** on the first attempt —
an assertion watched to fire rather than assumed.

**Evidence: `make test-mfinstall` 9/9, two new checks, each shown red first and
each blind to the other's fault.** That last part is what makes them two checks
rather than one:

| control | I8 | I9 |
|---|---|---|
| writer emits **LF** instead of CRLF | **green** | **RED** — `\n` against `\r\n` |
| writer **ignores its argument**, always writes `wifi` | **RED** — the card says `install: wifi` | green |

**I8 is the round trip** — `--configure uart`, then `--auto`, and the UART stub
has to come up — and UART is deliberate: the image starts at the shipped `wifi`
default, so a `--configure` that did nothing would pass on a value it never
wrote. Its *install* half passed under the second control, which is what says
the **file-content** assertion is the load-bearing one. **I9 is byte-identity
with the shipped default**, a question no screenshot can answer, between two
genuinely separate sources — a checked-in file the Makefile copies, and C that
composes the same line.

**I8 asserts nothing about the screen, and MY REASON FOR THAT WAS WRONG.** I
wrote that the M1 press paints over `--configure`'s message, "forced rather than
chosen", and cited I7's two-run split as the same mechanism. The reviewer ran
the same two commands **with no NMI at all** and the message was already gone.
The eraser is `--auto` itself: `load_rom()` borrows the display file at 0x4000
as its buffer and blanks it, which `mfinstall.c` **already documents** thirty
lines from where I was reading, in the comment explaining why the identity line
is printed after the install rather than before. So the message cannot survive
any run that installs, NMI or not — and I7's split really is the NMI, so the two
are different mechanisms and I had claimed they were one.

A plausible mechanism asserted instead of a traced one, in a comment whose whole
job is to say why a check does not assert something. It cost nothing here
because the *conclusion* — I8 cannot judge that screen — is true either way,
which is exactly what makes this kind of error survive. The message is judged in
run 12, which installs nothing, and that is why I9 carries it.

[doc/CONFIG-MODE-ROM-REPLACEMENT.md]: doc/CONFIG-MODE-ROM-REPLACEMENT.md

**CONFIRMED ON A REAL NEXT the same day** (user), and all three settings: `wifi`,
`uart` and `none` each written and each obeyed. So the file `--configure` writes
is one a real NextZXOS has read, which every bench here can only model — and it
lands on the rung this project reserves for one machine, one reporter, no
re-runnable artefact.

**NOT COVERED.** An **interrupted** write, which is the case the read-back
exists for, is not produced by any test and was not produced on hardware
either — what ran there is the happy path three times.

**No `make bump`: both ROMs are byte-identical to `main`'s** pinned with
`build/*.bin` deleted first (`efc73695…`, `f065776c…`), and
`git diff --name-only main..HEAD -- src/` is empty — nothing here reaches a ROM.

[doc/MFINSTALL.md]: doc/MFINSTALL.md

---

## 2026-08-07 — `.mfinstall` boots the debugger from AUTOEXEC.BAS on a real Next; issue #21 closes

**Measured, not decided** (user's own machine), and it takes issue #21's last
open question with it. `AUTOEXEC.BAS` calling `.mfinstall --auto` installs the
stub at boot, the M1 press brings the debugger up, and no reset of any kind is
involved. That was the **one invocation path nothing had ever exercised** — the
bench and both hardware runs before it typed the command at the NextZXOS command
line — and it is the path the whole design exists for.

**WHAT IT DOES NOT ESTABLISH, and the distinction is one this project has been
made to pay for before.** Nobody read port `0xE3` back on that path. So §1.2c's
`0xE3 = 0x82` — a dot command is CONMEM-mapped, not automapped — is still a
statement about **one typed invocation**, and `mfwin.asm`'s `rst 8` automap
bridge is still six bytes covering a case nobody has observed rather than six
bytes now known to be dead. "The sequence survived that path" and "we know which
mapping it ran under" are different claims and the comments say so in place.

**AND THE SAME EVENING PRODUCED THE ANSWER NOBODY WANTED, which is why #21
closes and #26 does not.** After a **soft reset** the machine is broken: the NMI
does nothing and NextZXOS locks up shortly afterwards, recoverable only by
power-cycling. **`--auto` re-ran and reinstalled the ROM in between**, and that
is the load-bearing part — the bytes were freshly written and verified inside the
window, so **the damage is not in the Multiface ROM**, and no amount of
reinstalling reaches it. Together with the stub's own `R` key producing the same
state (#26, filed before any of this), that points away from `.mfinstall`
entirely and towards state a soft reset does not clear. `MAIN_BANK EQU 94`, taken
on the first NMI and never given back, remains #26's live candidate; this run
does not confirm it, it removes a competitor.

**Two things a user needs that the documentation did not say**, found the
expensive way — the user's `autoexec.bas` worked when run by hand and never at
boot. From the NextZXOS Guide on the card (`/docs/guides/NextZXOS.gde`, node
`AUTOEXEC`): the file must be **`c:/nextzxos/autoexec.bas`**, not the card root,
and it must be **SAVEd with an auto-run line** (`SAVE "…" LINE 10`) or it loads
without starting. Both now in [doc/MFINSTALL.md]. Corroborated rather than
quoted: the card's own `/nextzxos/autoexec.1st` carries `LINE 10` in bytes 18-19
of its `PLUS3DOS` header, which is where a reader can check their own file from
a PC.

**A claim of ours that could NOT be sourced, and is now qualified rather than
repeated.** `doc/MFINSTALL.md` carried Xalior's argument that an `AUTOEXEC.BAS`
change "can be undone by holding the key that skips `AUTOEXEC.BAS`". **No such
key is documented anywhere in the NextZXOS guide.** BREAK stopping a running
NextBASIC program is the obvious candidate and nothing here has verified it
applies at boot. It came into our docs from #21's discussion and was never
checked — the same shape as the taylorza misquote, and caught the same way, by
going to the primary source instead of the issue body.

**NOT COVERED.** `--unload` has still never run on hardware; every hardware run
is an install. And one machine, one reporter, no re-runnable artefact — the
`reported on hardware` rung, not `verified`.

[doc/MFINSTALL.md]: doc/MFINSTALL.md

---

## 2026-08-07 — The deploy directory IS the card, and the config file it ships is one a run has parsed

**Decided (user) and built.** `build/deploy/` mirrors the layout its contents
take on the Next — `dot/` and `mfselect/` — so deployment is
`cp -r build/deploy/* <card>/` and nothing is renamed or placed by hand. And
`make mfinstall` ships a **default `mfselect/mfinstall.yml`** saying
`install: wifi`, where before the user wrote that file themselves.

**THE FLAT VERSION HAD TO PRINT A RULE, AND A RULE BESIDE A LISTING IS A RULE
SOMEBODY READS PAST.** Since issue #21 one of the six files goes to `/dot/` and
the other five to `/mfselect/`, so `deploy_listing` mapped basename to
destination with an awk conditional and the recipe printed *"/dot/mfinstall is
the ONLY file here that does not go in /mfselect/"* underneath. That is a second
copy of a fact the build already knows, in the one line a user follows
literally. The listing is now `find -printf '    /%P\n'` over the tree: the
**directory answers the question and the listing only reads it back**, which is
the same move as `build/deploy/` itself — the ROMs wear one name for the
firmware (`enNextMf.rom`) and another for mfselect (`dezouart.rom`), and that
was made the build's problem rather than the user's for exactly this reason.

**THE CONFIG FILE'S NAME IS `mfinstall.yml` AND THE REQUEST SAID
`mfselect.yml`.** `tools/mfinstall/mfinstall.c:102` hardcodes
`CONF_FILE "/mfselect/mfinstall.yml"`, so a default under any other name would
be **inert** — shipped, copied to the card, and never opened. Renaming the
constant instead was considered and rejected by the reviewer as well as here:
`mfselect` the program reads no config file at all, so `mfselect.yml` would
misname *which* program it configures, and the rename would move the C source,
the dot command, the bench and four documents for a filename that appears
nowhere in the repository.

**"IT CAN BE READ" IS TWO CHECKABLE THINGS, AND NEITHER IS AN ASSERTION.**

1. **The build refuses a config over 511 bytes.** `read_config()` reads
   `CHUNK-1` = 511 bytes **once** and scans only those, so an `install:` line
   pushed past that by a longer preamble is a file the dot command reports as
   unreadable — and nothing else here bounds it. The key is therefore written
   **first**, and the guard is a proxy for the real bound rather than the bound
   itself, which is said where it is used. Shown red: 64 bytes appended, `make
   mfinstall` fails with the message, exit 2.
2. **The bench parses the file that SHIPS.** `test-mfinstall`'s I5 used to
   `printf 'install: wifi'` into a scratch file, which would have left the
   shipped default checked by nothing at all — the classic shape this file
   records under other names. It now `mcopy`s `build/deploy/mfselect/mfinstall.yml`
   onto the card image, so what a user copies is what a run has read: CRLF,
   comment block, long-filename entry and all. Shown red: a shipped
   `install: none` turns I5's wifi half red at 0.00%, restored green.

**CRLF, because that is what NextZXOS's own config files are** —
`/nextzxos/browser.cfg` and `/nextzxos/enBrowsext.cfg`, both checked on the
reference image rather than assumed. The parser takes either ending; the editor
on the machine is the reason to pick one. **The 64-column wrap is OURS and
nothing confirms it**: those two files are machine-parsed action specs with no
prose in them at all and lines running to 127 characters, so there is no column
convention there to follow. It is a choice about reading the file on a Next.
*(A first version of this paragraph said "CRLF and 64 columns, both checked" —
one measurement's authority lent to a second claim taken from the same
sentence, which is this file's oldest disease. `doc/MFINSTALL.md`, written in
the same change, made only the narrow claim and was right.)*

**The nine-character name needs a long-filename entry, and that is ordinary
here**: NextZXOS reads `enBrowsext.cfg` itself and looks dot commands up by
names like `DISPLAYEDGE`. The reviewer confirmed independently that `mcopy`
writes the same `MFINST~1.YML` + LFN pair a PC would and that it round-trips
byte-identical.

**Rejected.** Generating the yml in the recipe with `printf` (it is data a user
edits on the card, not a build product, and a generated file cannot be the one
the bench parses); `rm -rf $(DEPLOY)` to clear the old flat files (the recipe's
existing comment refuses a recursive delete of a variable-built path, and there
is nothing here it buys); leaving the pre-hierarchy flat names in place (a tree
built before this would list six loose files as instructions to copy something
to the card's root — the five ROM/`.sum`/`.nex` names and `mfinstall` itself).

**A REVIEW FINDING AND A GREP FINDING, AND THEY ARE THE SAME DISEASE.** The
reviewer rejected the first commit because `doc/MFSELECT.md` still tabulated the
flat copy — five files, a From/To table, by hand — while `README.md` links to it
for "full detail" on the procedure this branch exists to delete. Enumerating
mechanically rather than from the review's list then found a **third** site, the
plan's Appendix B A2/A3, which cited that very table. `MEMORY.md`'s own "the
five files a card needs" is left alone deliberately: it records what was decided
then, and editing evidence to match a later rendering is what this project
refuses.

The same review's second finding is the sweep above being **one name short**,
and it was found the way this project asks for: by **making the stale tree**
rather than by reading the list. `make mfselect` alone is a supported build, so
a pre-hierarchy `mfinstall` left at the top of `build/deploy/` would be printed
as `/mfinstall` beside the correct `/dot/mfinstall` — by the very listing whose
recipe had just claimed there was nothing left to get wrong.

**Evidence: `test-mfinstall` 7/7 and `test-mfselect` 10/10**, each re-run
independently by the reviewer. **Both ROMs are byte-identical to `main`'s** with
`BUILD_TIME` and the build number pinned and `build/*.bin` deleted first — the
trap [[ERRORS.md]] records — re-derived by the reviewer as well, **so no `make
bump`** even though the mechanical check lists `Makefile`.

**NOT COVERED.** Nothing here has run on **real hardware**: no Next has opened
this file. `mcopy` writing an LFN entry is not proof that NextZXOS's
esxdos `f_open` will read one, only that the entry is the kind NextZXOS reads
elsewhere. *(One line of this paragraph was overtaken within the day: it said
`--auto` from `AUTOEXEC.BAS` remained unmeasured, and the entry below records
it running on a real Next. The rest stands — that run used a config file the
user wrote, not this one.)* And `CLAUDE.md`'s §Testing catalogue still has **no entry for
`test-mfinstall`** where every other bench has one, which is its own small
branch and now has one more thing to say.

---

## 2026-08-07 — A dot command cannot write the Multiface ROM, BECAUSE it is a dot command

**Measured, issue #21**, and written up late: this is the finding `.mfinstall`
was built on, and the decision log had no record of it while
`doc/CONFIG-MODE-ROM-REPLACEMENT.md` carried it in full. The mechanism is not
the one that document originally described, and the difference is structural
rather than a detail it got wrong.

**THE FINDING.** Config mode (`NEXTREG 3,7` / `NEXTREG 4,5`) is the **only**
door to the Multiface ROM's SRAM page — `mmu_A21_A13 <= page + 32`
(`zxnext.vhd:2964`), so `NEXTREG 0x50` at any value lands at physical page 32 or
above and page `0x0A` is unreachable from the MMU. And a **NextZXOS dot command
cannot use that door**: it executes at `0x2000` out of DivMMC RAM,
`divmmc.vhd:94-95` enables DivMMC's two halves **together** on the same
`conmem or automap`, and page0 is unconditionally read-only there (`:100`). So
`0x0000-0x1FFF` is DivMMC ROM whenever the command exists to ask, and the write
is **silently discarded**.

**There is no state in which your code is at `0x2000` and `0x0000` is free —
given that DivMMC, and not an MMU RAM page, is what serves the command's own
code.** That premise is a NextZXOS fact rather than an FPGA one and is confirmed
only in jnext; the hedge belongs on the sentence rather than four paragraphs
below it, which is where a first version of this entry put it.

**AND CONFIG MODE OPTS BACK INTO BEING OVERRIDDEN, which is the part I would not
have predicted.** Its own branch sets `sram_pre_override <= "110"` (`:3050`) —
bit 2 leaves DivMMC eligible, bit 1 Layer 2 — and the second arbiter consults
DivMMC **first** (`:3084`). Fourteen lines above, the Multiface branch sets
`"000"` (`:3036`) and shuts every later override off. So the branch that hands
you writable ROM-SRAM is the one that deliberately lets DivMMC take it back.

**WHY FIVE ROUNDS OF VHDL REVIEW COULD NOT HAVE FOUND IT.** Every mechanical
claim in that document was right. Whether a dot command runs out of DivMMC RAM
or an MMU-mapped page is a fact about the **NextZXOS runtime**, not about the
FPGA, and no amount of reading `zxnext.vhd` answers it. **The hardware spec
bounds what can happen; the software you are running inside decides which of
those you are standing in.** This project's first hard rule is that the VHDL is
the authority for hardware behaviour — and this is the shape of question that
rule does not reach. It was settled by a throwaway dot command in one evening.

**THE FIX IS NOT THE OBVIOUS HALF OF ITSELF.** Relocate the copy above `0x4000`
**and** turn DivMMC off. A control build identical in every respect except
leaving DivMMC on — still relocated to `0x5000` — is **blocked**, reading back
the esxdos ROM. So **relocating is not what fixes it; turning DivMMC off is, and
relocating is only what makes turning it off survivable**, since otherwise you
unmap the code you are executing. That control is the `DIVMMC_OFF` build seam
and bench check **I7**, the seventh seam of the `IP_MAX` / `RX_WAIT` /
`TX_PASSES` / `WAIT_SECS` / `FAULT_LIMIT` / `LINK_IDS` family and for the same
reason: a red nobody can re-run is a story about a scratch tree.

**A MEASUREMENT MADE IT CHEAPER THAN FEARED.** Port `0xE3` reads back — it is
readable (`:2727`, `:2815`, `:4190`), unlike NR `0x04` — and gave **`0x82`**:
CONMEM set, bank 2. **A dot command is CONMEM-mapped, not automapped**, so a
byte-exact restore of `0xE3` brings DivMMC back and the `rst 8` automap re-arm
reasoned out beforehand is unnecessary. **It is kept anyway**, and the reason is
a limit of the measurement: `0x82` is what *that* invocation gave, and nobody
has read `0xE3` back on any other. If a dot command is ever automapped with
CONMEM clear, the bare restore leaves DivMMC **off** and the return to `0x2000`
lands nowhere. Six bytes covers both.

**TWO CORRECTIONS TO THE DOCUMENT, both from reading it again with a run in
hand.** Leaving config mode is **read back and write back**, not "write back the
machine type you want" (§1.3): NR `0x03` is readable (`:5894`) and
`nr_03_machine_type` is only ever `001`/`010`/`011`/`100` (`:1103`,
`:5139-5142`), never `000`, so the value read is always a valid exit **by
construction**. And the `LDIR` writes *through* `0x0000`, `0x0008`, `0x0038`,
`0x0066` — every automap entry point — but cannot re-trigger automap: the `_q`
inputs are cleared whenever `cpu_m1_n = '1'` (`:4115-4119`) and `automap_hold`
updates only on an M1 fetch (`divmmc.vhd:126-131`). Worth recording because the
live `automap` expression at `divmmc.vhd:148` has had its `not i_cpu_m1_n` term
**commented out**, so the gating is not where a reader looks for it.

**THE SOFT RESET IS NOT REQUIRED, and this entry's first version got the
attribution wrong on its way to saying so.** Bench **I2** paints the stub after
`--load wifi` with no `NEXTREG 2,1` anywhere, and hardware has since agreed
twice over. That first version called it "the opposite of taylorza's account
that the reset was what made the replacement take" — **he never claimed that**.
He said a reset "gave me the best results" and added "I am not sure what the
actual clean-up should be so I just left my iterations in". The word *needed*
came from this project's own issue body and propagated from there into a public
write-up he objected to, rightly. This entry was the last carrier.

**Rejected.** The MMU (`NEXTREG 0x50`) instead of config mode — unreachable,
above; chunking the copy into windows small enough to avoid a buffer, which
multiplies the DivMMC off/on transitions rather than paying the risk once;
leaving CONMEM set on the way out instead of restoring `0xE3` exactly — the
reason recorded here was that "esxdos keeps its own shadow of that register and
would be lied to", which is **unsourced and is not what `mfwin.asm` says**; the
justification that survives is the one in the code, that an exact restore needs
no theory about who else is reading the register. A host-side model of the
sequence instead of a dot command (it would have tested a transcription, which
[[ERRORS.md]] already carries an entry about). And idempotence by identity
block, replaced on the user's call by a **full 8 KB compare** — "would this
write change anything" is a different question from "is this ours", and issue
#4's block is for the latter.

**The doc sweep found more stale sites than the review named**, and the extra
ones were load-bearing: one was the sentence saying the MMU state "must be
established rather than assumed", which survived the measurement that
established it — a document still arguing for work it had already done. No count
is given, because the artefact that would settle one no longer exists; what is
reproducible is the rule. **A correction is not finished until the claim is gone
from everywhere it was used as a premise, and the enumeration is a grep, not a
memory.**

**Cost: no `src/` file changed and both ROMs are byte-identical to `main`'s**
pinned, verified with `build/*.bin` deleted first. **So no `make bump`** — the
certain answer rather than the conservative one, taken deliberately (user,
2026-08-07).

**NOT COVERED AS OF THE DAY THIS DESCRIBES.** Every hardware item in that list
has since been answered and the entries above this one carry the results, which
is why they are not restated here. What is still open is the 8 KB copy with
**anything thrown at the window** — it is ~1 ms and nothing has been aimed at
it — and the Multiface handler's own behaviour if it ever ran with config mode
active.

---

## 2026-08-06 — Three WiFi screen lines reworded (user)

**Decided by the user, and it is aesthetics rather than correctness**, so it is
recorded for the coupling rather than for the reasoning:

    Remote debugger active.      ->  Remote debugger ACTIVE
    Session opened (CMD_INIT).   ->  Session opened - CMD_INIT
    Session closed (CMD_CLOSE).  ->  Session closed - CMD_CLOSE

Capitals, a dash instead of brackets, no full stop. `No debug session yet.` was
not in the request and is **untouched**.

**WHAT MAKES THIS MORE THAN A STRING EDIT: A BENCH ASSERTS ON THESE WORDS.**
`make test-client-status` decodes row 8 with the ZX font and judges each run on
what it **says** (issue #14), precisely so that swapping two labels cannot pass
— so the expected text in `run-client-status.sh` had to move with the source, in
the same commit, or N2 and N3 would have gone red for a change that broke
nothing. Re-run and green: N1-N3 read the new lines off the screen.

**The past-tense honesty the wording carries is unaffected**, which is the one
thing that could not have been traded away here: each line still names the DZRP
command it observed, so it reports an event rather than claiming a live socket
the transport cannot see. That was the whole argument for the wording in the
first place.

Four further sites named the old strings in prose — `screen.py`,
`hardware-check.py` twice, `CLAUDE.md`, `doc/HARDWARE-TESTING.md`'s screen
mock-up and the plan's "as built" note — all updated by grep rather than from
memory. The plan's **2026-08-04 decision sketch** and this file's own history
keep the old spelling deliberately: they record what was decided and measured
then, and editing evidence to match a later rendering is the thing this project
refuses.

**Cost: WiFi −3 bytes**, one per line, `main_end` 0xF9CF → **0xF9CC** — so the
branch's net against `main` is **+54**, not the +57 the entry below quotes for
its own commit. **The UART ROM is still byte-identical** pinned (`9755e3fa…`):
these strings live in `transport_esp.asm` and UART mode draws no session line at
all, deliberately (issue #14 — over a cable there is no connection event to
report).

---

## 2026-08-06 — The stub closes connections now, blindly, and only when it has given up

**Built, issue #19.** `esp_recover` sweeps every link id with `AT+CIPCLOSE=<id>`
— after retiring the listener, before re-running the AT chain. Until this,
**nothing in this program had ever closed an established connection**, so a peer
that wedged rather than closing kept its inbound slot for the rest of the
power-on session.

*(**CORRECTED 2026-08-08, at the top of this entry because it is the first thing
a reader meets.** "For the rest of the power-on session" is false: the module
reaps an idle inbound connection itself at `AT+CIPSTO`, ~180 s, measured enforced
on real hardware — see the 2026-08-08 entry at the top of this file. The clause
that survives is the one this paragraph is really about, and it is unaffected:
**nothing in this program** frees one. The entry's own later paragraph carries
the same correction; it is repeated here because 90 lines is too far to expect a
reader to carry a doubt.)*

**THE FAILURE IT REMOVES WEARS ISSUE #15'S FACE, WHICH IS WHY IT IS NOT
HOUSEKEEPING.** Four or five such peers and the module refuses every new client
while `esp_recover` goes on reporting success — **five, measured on a real
Next**. How a peer comes to vanish in the field is deliberately not claimed;
nothing here has measured that. TCP connects, nothing answers, power cycle. **It is NOT a fix
for #15**, which was closed on other evidence and never reproduced deliberately;
it removes one mechanism that produces the same outward signature, which is a
smaller claim and the only one earned.

**THE SWEEP IS BLIND, AND THAT IS THE DECISION.** The stub does not know which
ids are open: learning that means tracking `<id>,CONNECT` / `<id>,CLOSED`, which
is M3's work and a second pattern in the RX hot path. `AT+CIPCLOSE=<id>` on an
id with nothing behind it is answered `ERROR` — jnext refuses that case
deliberately rather than answering OK, so that a guest "cannot believe it had
freed a slot that was never taken" — at the cost of one line of RX. **Asking
about all five is cheaper than knowing which one to ask about.**

**And blind is what keeps it NUMBERING-AGNOSTIC, which matters more than the
saving.** jnext's inbound ids start at 1, real firmware's first inbound
connection is 0, and this project has already lost a hardware evening to
encoding one of those (`esp_conn_valid`, [[ERRORS.md]]). Measured this week:
jnext's ceiling is **4**, a real ESP-01's is **5**. Nothing in the sweep encodes
which end of the range is real.

**WHAT IT COSTS, STATED RATHER THAN DISCOVERED LATER.** One AT line and one
drain per id — five drains — paid only on a recovery, which already runs the
whole AT chain at bring-up budgets. And **a healthy client's connection goes
with the wedged ones**. That is deliberate: `ESP_FAULT_LIMIT` consecutive faults
means nothing got through in between, so a connection surviving that is not a
session worth preserving. Sparing it would need per-id state the program does
not have.

**A first version of that said "and DeZog reconnects", and the reviewer asked
for a citation. There is none, because it is FALSE**: DeZog 3.7.4 has no
reconnect logic at all — no `reconnect` symbol anywhere in its bundle, and
`CSpectRemote`'s socket close handler only logs. The session ends and the user
starts another. The trade is unchanged and is arguably clearer stated honestly:
one recovery now costs what a power cycle used to.

**Answers are DRAINED, not matched**, which is why the routine is nine lines
rather than a scan. The caller has no decision to make either way: an id that
was already free is the expected case, not a fault. A wait for `OK` would sit
out its whole budget on every free id — most of them, every time — and would
then have to be told not to read that as the failure it looks like. A drain also
cannot destroy an inbound frame the way a scan can (issue #11), and there is
nothing inbound to protect: no listener is up and every connection is about to
be closed.

**WRITABLE ONLY BECAUSE jnext#211 LANDED, and #16 declined it for exactly that
reason.** Then, jnext's `AT+CIPCLOSE` took no argument and acted on the outbound
slot only, so the Z80 would have been unexecutable by every bench here — the
trade this project refuses. The dependency was filed with this project as the
demonstrated consumer, it shipped, and the code is now exercised rather than
reasoned about.

**Evidence: `make test-slot-recovery`, 3/3, and the control is the point.**
S1 and S3 differ in one assembler constant:

| | slots filled | 5th | `AT+CIPCLOSE` | held sockets closed | fresh client |
|---|---|---|---|---|---|
| **S1** shipped | 4 | DROPPED | **5** | 4 of 4 | **served, attempt 2** |
| **S3** `LINK_IDS=0` | 4 | DROPPED | **0** | 0 of 4 | **refused 40× in 40 s** |

`LINK_IDS` is the **fifth** build seam of the shape `IP_MAX`, `RX_WAIT`,
`TX_PASSES`, `WAIT_SECS` and `FAULT_LIMIT` already have, and for the fourth
time's reason: the state a check must be shown red against has to be reachable
by a **build**, or the red is a story about a scratch tree nobody can re-run.

**S2 counts per recovery, not in total**, and that is not pedantry — "at least
five" would pass a sweep that ran once for two recoveries.

**The held peers are ANSWERED before they go silent**, deliberately. A slot can
be occupied by a socket that never speaks, but then a refusal at the ceiling has
two indistinguishable causes — "the module is full" and "the stub is wedged" —
which is the position #15 was reported from. Probe A's A1 lesson, applied to a
gate instead of an instrument.

**Two comments in `esp_recover` were still asserting the claim its own header
retracts** — that stopping the listener closes connections, and that the drain
eats `<id>,CLOSED` lines it produces. It produces none. Thirty lines below the
paragraph correcting it, inside one routine: the same shape as the
screen-reader commit's, and the reason this file keeps saying **a correction is
not finished until a grep says it is**. The grep also found four prose sites
elsewhere — `doc/HARDWARE-TESTING.md` twice, `slot-ceiling-probe.py` and
`run-vanished-peer.sh` — all saying nothing ever frees a slot, all now qualified
rather than deleted: **neither probe is retired by this fix**, because both keep
the stub healthy and so neither ever triggers a recovery.

*(**CORRECTED 2026-08-08**: "nothing ever frees a slot" is false of the module,
whatever it is of the stub. The ESP reaps an idle inbound connection itself at
`AT+CIPSTO`, ~180 s, measured enforced on real hardware — see the entry of that
date at the top of this file. What survives here is the narrower claim these
sites were really making, and which is still true: **nothing on the Z80's side
of the UART frees one**, and neither probe triggers a recovery.)*

**Rejected.** Tracking `<id>,CONNECT`/`<id>,CLOSED` so only live ids are closed
(M3's work, a second pattern in the hot path, and it buys nothing here — an
`ERROR` costs one line); `AT+CIPCLOSE=5`, which real firmware reads as "close
everything" and jnext refuses on purpose, so it would be a promise no engine
here makes; sweeping *before* `AT+CIPSERVER=0` (a client could take a slot
between the sweep and the re-listen); sweeping *after* `transport_init` (the
re-listen would land on a module still full); a scratch tree instead of the
`LINK_IDS` seam (a red nobody can re-run).

**MEASURED ON A REAL NEXT THE SAME DAY, AND IT CONFIRMS THE PREMISE WHILE
LIMITING THE FIX.** `make probe-vanished` against the user's machine at build
`00.0F`: four vanished peers are survivable, **the fifth stops the module
serving anyone** — one slot consumed permanently per peer, nothing giving one
back, which cross-checks against probe A's hardware ceiling of 5. The terminal
symptom is a **timeout at 10009 ms**, not a refusal, and the stub's error area
was **clean throughout**. So the leak this fixes is real on silicon and was an
inference from jnext's source until now.

*(**CORRECTED 2026-08-08, and "permanently" is the word the whole power-cycle
conclusion rested on.** **Two** clauses of that sentence go, not one: the slot is
not consumed *"permanently"*, and it is not true that there was *"nothing giving
one back"* — the module reaps it itself at `AT+CIPSTO`, ~180 s. This run could
not have seen either: its phase 2 lifted the blackhole before waiting, and
waited 20 s. So the ceiling of 5, the 10009 ms timeout and the clean error area
all stand exactly as measured — they do not depend on the recovery mechanism —
and it is only the sentence's two claims about *permanence* that were never this
run's to make. See the 2026-08-08 entry at the top of this file.)*

**AND THE SAME RUN SAYS THE FIX CANNOT RESCUE THAT STATE AT ALL — not "is
unlikely to", CANNOT.** The sweep runs from `esp_recover`, which fires on
`ESP_FAULT_LIMIT` consecutive faults, and `esp_fault_count` is incremented in
exactly one place, `rxtx_error`. Trace every source of traffic in the terminal
leaked state and none of them can reach it: a **new** client never completes the
module's handshake (V5, 10009 ms), so the stub sees zero bytes and cannot time
one out; the **leaked peers** are silent by construction, having sent neither FIN
nor RST; and an **unprompted send** to a stale id takes `esp_wait_prompt`'s
`ERROR` arm to `.no_client`, which clears the validity flag and returns quietly,
after which `transport_flush` discards without asking. So there is no ordinary
mechanism left by which the stub can fault again, and the trigger is
**structurally unreachable** rather than merely improbable.

**A first version of this paragraph said the fix helps in "the case a user
retrying a hang produces", and the reviewer REJECTED the branch over it.** Twice
wrong: an unverified claim about user behaviour, the same species as "DeZog
reconnects" one entry up — and, worse, contradicted by the measurement three
sentences above it. Retrying describes the **lead-up** to leaking, while the
module can still be reached and a truncated exchange can still make the stub
fail; it says nothing about the **aftermath**, which is the state that paragraph
had just admitted is unrescued. The tell was that the sibling paragraph in
[doc/HARDWARE-TESTING.md], written in the same commit, did not make the claim —
**two renderings of one fact disagreed, and the careful one was right**.

So what #19 buys is narrower than it first appears: it reclaims slots on the way
INTO trouble, while the transport is still failing loudly. It is not a general
reclaim, and a module already full of vanished peers gives the sweep nothing to
trigger on. Closing that needs a trigger the stub can reach from a quiet
state — a periodic or connect-time sweep — which is not this branch.

**NOT COVERED, and none of it is hidden.** The case above — a healthy stub that
never faults. **Which ids were freed** — no PC-side check can see them, so S2
counts commands. A genuinely **wedged** peer in the bench: those are answered and
then silent, which occupies a slot the same way but is not the same thing. The
sweep at its **shipped** `ESP_FAULT_LIMIT` of five, since jnext cannot produce
five consecutive faults. And a fault raised **inside** the sweep aborts it and
leaves `esp_fault_count` unreset — so the next single fault triggers another
recovery rather than needing five. That is the pre-existing shape of
`esp_recover` rather than something #19 introduces (`AT+CIPSERVER=0` could
already fail the same way), and the reviewer and I agree it is worth recording
rather than fixing here.

[doc/HARDWARE-TESTING.md]: doc/HARDWARE-TESTING.md

**Regression, on the merged branch: `test-dzrp-stub` 15/15 with W1-W5,
`test-no-hang` 4/4, `make test` 6/6, `test-unit` 5/5, both variants
`check-reproducible`.**

**Cost: WiFi +57 bytes** (`main_end` 0xF996 → 0xF9CF), 1233 free to the identity
block. **The UART ROM is byte-identical** pinned (`9755e3fa…`), which is what
says nothing shared moved: `transport_esp.asm` is in the WiFi build only. **This
changes a ROM, so the merge carries a `make bump`.**

---

## 2026-08-06 — Asking a program what it supports is not the same as reading its output

**Built.** `bench_jnext_supports` in `test/bench-jnext.sh`, replacing the
`"$JNEXT" --help | grep -q -- '--flag' || die` in **thirteen** places across
**ten** benches — and then the same early-exiting-reader shape in **nine** more,
which the independent review is what turned up.

**IT WAS NOT A TIDY-UP: EVERY BENCH IN THIS REPOSITORY WAS DEAD.** Against jnext
0.99.127 all of them refused to start, each blaming the emulator for a flag it
has. `make test`, `make test-unit`, `make test-dzrp-stub` — the whole gate.
`grep -q` exits at its match, jnext's next write takes SIGPIPE and exits 141,
and `set -o pipefail` carries that 141 out of a pipeline that had **succeeded**.
Full mechanism and the measurement in [[ERRORS.md]] — including the correction a
reviewer's strace forced on it: the help is written in ~4 KB **chunks**, not a
line at a time, which changes the picture and not the conclusion.

**SHARED, NOT COPIED — the same decision as issue #17 and for the same reason.**
Thirteen repaired call sites would be thirteen places for the next correction to
miss, which is exactly how #17's departure check became a repository-wide defect
after being fixed correctly in one file. The helper goes in the file that
already exists for this, and which **defines functions and does nothing else**,
so `run-unit-tests.sh` could source it for this one function without inheriting
a teardown it deliberately does not want.

**What makes the new form correct is that it reads to EOF**, not that it avoids
`grep`. A command substitution consumes all the output, so there is no early
close to signal, and `grep -c` does as well — which is what the port checks now
use, since they need the regex.

**THE REVIEW FOUND THE CLASS WAS WIDER THAN THE FIX, AND ONE OF THE SURVIVORS
FAILED IN THE DANGEROUS DIRECTION.** Every bench's port pre-flight was
`! ss -ltn | grep -qE "…:$PORT" || die`, and `bench_require_port_free` the same
shape: a SIGPIPE there makes the pipeline non-zero, `!` reads that as **free**,
and the run starts against an occupied port — the contaminated-and-GREEN outcome
that check exists to prevent. Measured inert today (`ss` writes its small output
in ONE syscall, where jnext takes three), so this is a property of *another*
program's buffering rather than of our code, which is the same reason the
original defect appeared without anything here changing. The contrast is
narrower than the first version of this sentence claimed — jnext is not per-line,
it is 4096/4096/1765 — but one write cannot be interrupted by a departing reader
and three can, which is the whole of it. Nine sites, now
`grep -c`, verified both ways against a real listener.

**THE PROPERTY THAT BROKE IS NOT OURS, WHICH IS THE TRANSFERABLE PART.** Nothing
in this repository changed. The old check's correctness depended on **where the
match falls in another program's output** — byte 5786 of 10005, inside the second
of three write() chunks — and jnext is free to reorder its own help in any
release. A check resting on a property no test of
ours can see is a check that will fail on somebody else's schedule.

**Rejected.** Repairing each call site in place (above); dropping the version
checks altogether (they are what turns "the bench behaved oddly" into "your
jnext is too old", and one of them — `AT+CIPCLOSE=<id>` — is the whole
precondition of issue #19's bench); parsing `jnext --version` instead of the
help text (it answers a different question, and a flag's presence is the thing
actually depended on).

**Evidence: `make test` 6/6 and `make test-unit` 5/5 on this branch**, neither
of which would start before it. Red-first is trivially available and was taken:
`test/run-unit-tests.sh` on unmodified `main` dies with *"this jnext has no
--magic-port"*. The helper was also checked in both directions — five runs of
five say yes for a flag that exists, and it correctly says no for one that does
not, which is the half a fix like this can most easily lose.

**Test-only: `git diff --name-only main..HEAD -- src/ Makefile` is EMPTY, so no
`make bump`.** No ROM byte moves.

---

## 2026-08-06 — The Next's screen is readable over the wire, and it must never say hello first

**Built.** `test/dzrp/screen.py` fetches the stub's own display file with
`CMD_READ_MEM 0x4000,6912`, so `doc/HARDWARE-TESTING.md`'s **S1-S4** — the
error area, `Core:`, the connect block, the session line — become **text in
bench output** instead of a photograph a human interprets. `make read-screen
NEXT_IP=<ip>`, plus rows **A5**/**A6** in probe A, **B4** in probe B and **H6**
in the hardware bench. The doc has carried "nobody has written that" since the
first hardware session.

**IT WAS WRITTEN BECAUSE AN OBSERVATION WAS LOST.** Probe A ran against a real
Next on 2026-08-06, found the ceiling — 5 on hardware against jnext's 4 — and
nobody watched the screen. Asked afterwards, the user reported no red errors,
and **that answer could not carry the weight for a mechanical reason**: the
probe's own reclaim phase opens fresh connections after the ceiling, each
sending `CMD_INIT`, and `cmd_init` does `xor a` / `ld (last_error),a` and then
repaints. Anything the walk raised was wiped by the instrument.

**SO THE RULE IS THE DESIGN: A READER SENDS NO `CMD_INIT`.** Not a style
preference — a reader that introduced itself the way every other client here
does would destroy the thing it was run to read, then report the blank screen
it had just created.

**The obvious objection is that the screen is only mapped BECAUSE of
`CMD_INIT`**, and the doc's own wording invites it: it cites `cmd_init`'s
`REG_MMU+2,10` / `REG_MMU+3,11` as the reason 0x4000 is the display file.
**Measured instead of argued**, against jnext with a connection that sent no
`CMD_INIT` ever: the read is answered in 256 ms; the 768 attribute bytes are
exactly `{7: 480, 66: 288}`, which is `show_ui`'s own MEMFILL (15 rows
`WHITE+(BLACK<<3)`, 9 rows `RED+BRIGHT`) and nothing else's; and a `CMD_INIT`
sent afterwards changed **one display row — row 8, the session line — and not
one attribute byte**. Those writes RESTORE a mapping already in place, which is
also why `show_ui` is visible on the first M1 press with no client attached.
`cmd_loop` has no session gate at all: it reads a header and dispatches through
`cmd_call`.

**The font comes off the wire too, and that is better than the fallback it
replaced.** Decoding needs the ZX character set, and `test/screen-text.py` takes
it from the 48.rom on the SD image — unavailable for a Next across a WiFi link.
It does not have to be: slot 0 holds `ROM_BANK` while the debugger is stopped,
so `CMD_READ_MEM 0x3D00,768` fetches the font **out of the machine under
test's own ROM**. Verified byte-identical to the 48.rom on the image jnext
booted. A local file is kept only as `load_font_file`, and a wrong font is
self-announcing — every glyph decodes to `?`, not to a plausible other letter.

**HAZARD: A READER THAT DIALS IN IS AN INSTRUMENT HOLDING A SLOT IN THE WINDOW
IT IS MEASURING**, which is the defect `a057d51` had just fixed in probe A's own
control socket. So every read goes over a connection the caller **already
holds**: probe A reads over `held[0]`, the connection A1 has just used, at the
moment the ceiling is hit — zero slots. Probe B has nothing live at its
interesting moment (its peers are behind a blackhole, its fresh clients are
opened and closed inside `fresh_client`), so it reads at teardown, where the
slot is spent **after** the counting, and its "AT THE MACHINE" block still asks
a human for phase 1's screen. The same for `hardware-check.py`, whose teardown
connection was already being opened to send `CMD_CLOSE` — the read is folded
onto it, before the close, because `cmd_close` leaves through `jp main` and
repaints.

**THE INSTRUMENT IS EARNED, NOT ASSERTED, AND THE MECHANISM IS AVAILABLE ONLY
IN THE EMULATOR.** `make test-screen-agreement` puts **two independent views of
the same 6912 bytes** against each other: jnext's PNG, drawn by the emulator's
own ULA renderer from its own memory through no code of ours, and the DZRP
read, produced by the Z80 answering over an emulated UART and ESP-01. They
share nothing but the machine, either can be right while the other is wrong,
and **all 49152 pixels agree** — in both a clean run and one with a real error
on the screen. That is what makes the reader believable on hardware, where
there is nothing to check it against.

**G2 is the half that discriminates**, and its lever was chosen against the
project's usual one. A reader checked only on a blank error area is checked
where every wrong answer agrees with the right one on zero — mfselect's M9
again. The obvious way to redden this screen is `run-tx-patience.sh`'s injected
TX budget (824 pixels of `TX Timeout`), but it works **by crippling the
transport this bench must read 6912 bytes back through**, so it would measure
the injection. Command 42 instead: `cmd_not_supported` paints `Last Error: /
Command not supported` on the **same shipped ROM**, leaving G1 and G2 one
command apart.

**TWO FINDINGS FELL OUT OF BUILDING IT, AND BOTH ARE NOW LOAD-BEARING
ELSEWHERE.**

**1. A client disconnect CAN paint `RX Timeout`.** Measured deliberately after
a screenshot suggested it: a first-ever connection sees a clean area; a second
client sends `CMD_INIT` and closes cleanly; the area reads `Last Error: /
RX Timeout` at 1, 3, 6 and 10 s and again from a third connection. Known
behaviour, not a new defect — the `<id>,CLOSED` the module emits ends
`cmd_loop`'s wait and then fails to parse as a `+IPD` header, reaching
`drain_main` (issue #16, deferred to M3).

**It is NOT unconditional, and I wrote that it was before checking.** Probe A's
own A5 and A6 read a CLEAN area in the same emulator, on a run that had closed
a refused connection and two reclaim ones. So it depends on what arrives next
and when: the sweep left the stub idle for a second with nothing coming, the
probe does not. Recorded as the two measurements rather than as a rule, because
a caller told "expect `RX Timeout`" who then sees a clean screen would distrust
the instrument. The useful question is whether the text is something *other*
than that — answerable only because the area is decoded rather than counted —
and it is deliberately not treated as noise, since a failed AT chain reports the
same string.

**2. Every bright-red figure this project quotes is in PHYSICAL pixels.** jnext
renders at an integer scale, 2 in practice, so the 824 of `TX Timeout` and the
1044 of `No WiFi address` are **206** and **261** logical pixels. A reader
printing 206 against a bench printing 824 would look broken while being right,
so the agreement check asserts `whole == ours * scale²` instead of leaving it
to be rediscovered.

**THE AGREEMENT CHECK CAUGHT TWO BUGS IN ITSELF ON ITS FIRST RUN, which is the
argument for having built it.** The scale conflation above was one. The other
was worse and was invisible to reasoning: the client disconnected as soon as it
had the bytes, so **the screenshot was of a later screen** — both runs failed
with the picture reading `RX Timeout` where the read had shown a clean area
(G1) and `Command not supported` (G2). The read was right and the ordering
assumption was wrong. "The capture came after the read" is not "the capture is
of the screen that was read": the client now **holds its connection open** until
the bench signals that the screenshot has landed, so nothing repaints in
between. A third, quieter one: the first sentinel was an empty file and the
client required a non-zero size, so it never saw it and held for its full 300 s
timeout — the right answer, with a broken handshake hidden behind it, and the
bench was ignoring the client's exit code.

**THE REVIEW FOUND THAT THE COMMIT LEFT PROSE CONTRADICTING ITS OWN CODE, AND
THE GREP FOUND MORE OF IT THAN THE REVIEW NAMED.** Two sites were reported —
`doc/HARDWARE-TESTING.md`'s "Neither probe can read the Next's screen", and
"Not a check; it adds no row" sitting above the new `report.add`/`row` calls in
both probes. Enumerating mechanically instead of from that list turned up two
more: **probe A's own module docstring** (`It cannot read the Next's screen`, in
its WHAT THIS PROBE CANNOT ESTABLISH list) and, worse, **step 3's own preamble**
— "the script cannot see any of it", fifteen lines above the paragraph this
commit added saying S1-S4 can now be read. A contradiction inside one section
of one document, introduced by the change that corrected it.

This is the rule this file already states, paid for again: **a correction is not
finished until the claim is gone from everywhere it was used as a premise, and
the enumeration is a grep, not a memory.** The same sweep is what confirmed the
surviving "cannot see" lines are all about the BORDER or a broken reader, which
are true.

**The ~20-word budget was also checked across every branch rather than the one
reported**, which is the other rule this project keeps re-learning. Three lines
were over, not one: the degraded-reader message, `observe()`'s failure text and
A5's NOTE. The degraded-reader line is now **bounded by construction** — it no
longer interpolates what row 12 said, because that is up to 32 characters of
arbitrary text, and a first attempt measured 19 words against a one-token
placeholder and 21 against the real thing. A line whose length depends on its
data cannot be held to a word budget at all; the diagnostic moved to
`validate_reader()`, which `screen-client.py` prints in full.

**Rejected.** Sending `CMD_INIT` and accepting the wipe (it is the whole
defect); marking the over-budget line as a deliberate exception the way H3's is
(it was reducible without losing a fact, and an exception is for text that is
not); opening a connection per reading (it perturbs the slot count — the
`a057d51` mistake); OCR (the attributes already say which cells are error text,
and `ui.asm` fills them itself); a committed reference bitmap (the font is on
the machine); comparing the two views as a *percentage* like `screen-diff.py`
(both views are of the same frame's memory, so there is no noise and anything
but an exact match is a defect); reimplementing `screen-text.py`'s font
decoding (`glyph_table` is the shared piece and the PNG sampling is not needed
when the bytes are in hand); folding this into `make test` (it binds a host TCP
port).

**Test-only: `git diff --name-only main..HEAD -- src/` is EMPTY, so no `make
bump`.** Checked mechanically, not by judgement. Both ROMs are byte-identical
to `main`'s with `BUILD_TIME` and the build number pinned, and the comparison
was made after deleting the `.bin` intermediates as well as the ROMs — the
mistake ERRORS.md records.

**NOT COVERED, and none of it is hidden.** The **BORDER**, which is not in the
display file and which no `CMD_READ_MEM` can ever reach — it stays in every
probe's "AT THE MACHINE" block, along with **S5** and "did anything change
*during* the run", since every reading is a point sample. A client that has
remapped 0x4000 with `CMD_SET_SLOT` would be read wrongly; nothing here sends
command 10, and `validate_reader()`'s row-12 check is the backstop. And
**nothing here is evidence about a real ESP-01** — what the agreement check
validates is display-file addressing, attribute decoding and palette, which are
the same silicon either way.

---

## 2026-08-06 — Two INSTRUMENTS for #15, and a firewall change shaped so that dying badly is harmless

**Built, issue #15.** `make probe-slots` (probe A, no root) and
`make probe-vanished` (probe B, sudo) measure the one thing the standing
hypothesis about issue #15 rests on: how many clients the ESP module will hold,
and whether an abandoned slot is ever given back.

**They are INSTRUMENTS, NOT GATES, and that is the first decision.** They print
numbers and render no verdict, they are not in `make test` and must not be, and
**neither can close #15.** Issue #15 has never been reproduced deliberately; a
probe that said PASS or FAIL would be asserting a conclusion nobody has. The
Makefile block says so, both scripts say so on every run, and
[doc/HARDWARE-TESTING.md] carries the limits.

**The hypothesis is that #15 IS #19, and it comes from what 000E did NOT
explain.** The CRLF `SEND OK` swallow band accounts for the `RX Timeout`, the
frozen border and the hung client — but a swallowed command is **transient**, so
it accounts for neither the **power cycle** nor the **accept latency measured
degrading 83 ms → 389 ms → timeout**. That degradation is on the *module's* side
of the UART, where the Z80 cannot reach. #19 says nothing ever frees an inbound
slot and a power cycle is the only thing that does. Probe A measures the
ceiling; probe B produces a peer that never gives its slot back.

*(**CORRECTED 2026-08-08, and it weakens the hypothesis this paragraph is
building.** A power cycle is not the only thing that reclaims a slot — the
module does it itself at `AT+CIPSTO`, ~180 s, measured on hardware. So a #19
exhaustion **self-heals in about three minutes**, while #15 was two wedges the
user power-cycled out of. That is the first evidence pointing away from
"#15 IS #19"; it refutes nothing, because nobody recorded how long they waited
before reaching for the switch. The probes and their reasoning are otherwise
untouched. See the 2026-08-08 entry at the top of this file.)*

**A1 is the line that earns probe A**, and without it the probe would be worth
little. At the first connection that is not served it asks the **earliest
still-open** one whether it still answers. "The fifth client got nothing" has two
causes that are indistinguishable from the client that got nothing — the module
is full (stub healthy) or the stub is wedged — and that is exactly the position
#15 was reported from. One extra exchange separates them.

**THE EXPECTED NUMBERS ARE DERIVED FROM jnext'S OWN SOURCE, NOT CHOSEN**, and
`make probe-jnext` runs first, always. `MAX_CONNECTIONS` 5 minus
`FIRST_INBOUND_CID` 1 is **4** inbound slots (`esp_at.h:437`/`:452`,
`esp_at.cpp:894-902`); probe A must find 4, and probe B must see fresh clients
survive **3** — a vanished peer keeps its slot for ever and the client after it
needs one of its own.

*(**ANNOTATED 2026-08-08 for consistency rather than because the expectation
moved.** "For ever" is false of a real module — `AT+CIPSTO` reaps an idle
inbound connection at ~180 s — and the identical sentence in
`doc/HARDWARE-TESTING.md`'s expectation table was softened to "for the length of
the walk" on the same day. **Two renderings of one fact must not disagree**,
which is why this is written down rather than left as a silent decision. The
number is unaffected either way: the walk is seconds long, far inside any such
timer, so 3 survivals stands. What it now depends on is the walk staying short —
and that dependency was invisible while "for ever" was believed. jnext is
reported to have gained `AT+CIPSTO` itself on 2026-08-08; nothing here has
checked that, and if true it makes the walk-length caveat live rather than
theoretical.)*

**Real firmware should be 5**, by jnext's own comment
("ours is one lower because slot 0 is reserved"), and *that difference is itself
a check*: a probe reporting 4 at a Next would be reproducing an emulator
artefact. `--expect-ceiling` is passed by the emulator harness and **never** at
hardware, where the number is the unknown. Measured: **V1 ceiling 4, V2 three
survivals, both green, 0 bright-red pixels on the stub's screen throughout** —
so jnext reproduces #15's rows 1, 4 and 5 (listener alive, screen intact, TCP
refusing) with the stub perfectly healthy.

**Validating first is not ceremony.** A probe that never worked reports a
negative indistinguishable from a real one, and this project has already been
handed one: the first hardware sweep of the swallow band reported a *refutation*
produced by a harness that misread a DZRP response length ([[ERRORS.md]]).

**PROBE B USES A DEDICATED iptables CHAIN, NOT RULES IN `OUTPUT`, and this is
the decision most worth keeping.** The brief proposed the direct rule; a chain
is strictly safer and the argument is about *how it dies*, not how it runs:
teardown is three fixed commands that do not depend on what was added, so a rule
the script never recorded cannot survive it; every deletion is **by
specification**, never by index; **unhooking is the first step and is sufficient
on its own**, so if the flush and the delete both fail the user's traffic is
already normal and what is left is an inert, unreferenced chain; and a leftover
chain is harmless and self-announcing where a leftover `-A OUTPUT … -j DROP`
silently blackholes the user's own Next. `--clean` removes it wholesale, and the
same teardown runs at startup.

**And each DROP is scoped to ONE SOURCE PORT**, which is the other half. The
blackhole must stay up for the whole measurement — lift it and our own kernel
answers the module's retransmissions with a RST, freeing the slot and destroying
the subject — so a rule saying "drop everything to the Next's 11000" would
blackhole the probe's own later connections and leave nothing to measure with.
Binding each doomed socket to a known local port is what lets one connection
vanish while every other keeps working.

**Phase 2's recovery is deliberately reported narrowly**, in the probe's own
output and not only in the document: lifting the rule lets our kernel finally
answer the module, which is news arriving from *outside*. A client served
afterwards says the slot comes back once the module is **told** — never that the
module heals on its own.

**One change was forced by measurement rather than reasoning, and it is in
[[ERRORS.md]]**: the probe now runs in the **background** with the wrapper
`wait`ing on it, because bash defers a trapped signal until the running
foreground command returns. Demonstrated: SIGINT at the wrapper left the chain
hooked into OUTPUT for as long as the probe had left to run. After the change,
cleanup completes in **under 0.5 s**, and SIGTERM exits 143 with the chain gone.
Also demonstrated: the loud failure path (forced by planting a second reference
so `-X` must fail) exits 1 and names the three commands to paste; SIGKILL cannot
be trapped, so it leaves the chain, and both `--clean` and the next run's
startup teardown remove it.

**THE CONTROL ATTEMPT MUST NOT HOLD A SLOT OF ITS OWN, and the first version
did.** `open_one` returns a *live* conversation for `SILENT` — connected but
unanswered — and `walk()` left it open across the 2 s sleep and across the
control attempt, because `conv` is rebound only at the top of the next
iteration (after the control, on the continue path) and never at all on the
break path. So the control ran with **one fewer slot than the state it exists to
characterise**, which can turn a transient into a false ceiling or move the
number by one — and the discriminating result of this whole probe is a single
integer, 4 against 5. It is closed explicitly now, before the sleep, so the
existing 2 s doubles as the settle and no time was added. Caught by the manager
session, filed MINOR by the reviewer on a refcounting argument that does not
hold. **It did not fire in jnext**, whose over-ceiling answer is `DROPPED` (that
path already closed), which is exactly the point: it would have fired on
hardware if a real module answers by accepting and staying silent.

**Rejected.** Rules inserted directly into `OUTPUT` (above); a comment-match
sweep (`-m comment`) to find orphans (it works, but deleting by a parsed `-S`
line means reconstructing a spec from text, where a chain needs no parsing at
all); a network namespace for the vanishing peer (more root surface and more to
leave behind, for the same effect); making the peer vanish without root
(impossible — the kernel always sends FIN or RST, and both are measured to free
the slot, #15's E-C); folding either probe into `make test` or giving them
PASS/FAIL verdicts (they would then be asserting a conclusion about an
unreproduced fault); asserting the ceiling at hardware.

**NOT ESTABLISHED, and it is written into both scripts and the document.**
Neither probe reproduces #15. Probe A's ceiling is a ceiling under *cleanly
closed* connections, which are measured not to leak. Probe B shows what a
vanished peer **costs**, not that one is what happened on 2026-08-05, and
nothing here says what made a peer vanish in the field. No PC-side check can see
connection ids. And a green `make probe-jnext` says the instruments work in an
emulator whose ceiling is four integers in a header file.

**Test-only: no `src/` file and no ROM logic in the `Makefile` changed, so no
`make bump`.** Checked mechanically rather than by judgement — see the report.

[doc/HARDWARE-TESTING.md]: doc/HARDWARE-TESTING.md

---

## 2026-08-06 — The build number is stored once and rendered twice; and a row that was already exactly full

**Decided (user) and built, issue #20.** `version.yaml` holds four uppercase hex
digits, quoted; everywhere a **person** reads the number it is `NN.NN` — high
byte, dot, low byte; and `make bump-major` moves the high byte, resetting the
low one to `00`.

**THE MAGIC STRING DOES NOT CHANGE, and the rest hangs off that.** The identity
block at ROM offset `0x1FE0` still reads `DeZoGiFnG_UART_000E`, four bare digits.
Its format is a contract `tools/mfselect/mfselect.c` parses (issue #4), it is not
what a user reads, and the dot is a *rendering*. So there is **one stored form
and one display transform**, rather than two stored forms with a convention about
keeping them equal — which is the conflation issue #4 was about, one field along.

**Where the transform lives is what keeps it single-source.** The Makefile
derives `BUILD_NUMBER_SHOWN` from `BUILD_NUMBER_HEX` **on the line below it**, by
a textual `sed 's/../&./'`, and hands both to sjasmplus. `IDENTITY_LINE` takes
the dotted one and `rom_magic` the bare one, so both spellings are emitted by one
assembler pass from one value and cannot disagree within a build. A second
`$(shell awk …)` reading `version.yaml` again would have been two sources with a
rule between them.

**Why the split is not done in the assembler, which would have needed no second
`-D`.** sjasmplus has no substring operator for a `-D` string:
`-DBUILD_NUMBER_HEX="000E"` is a textual token and `defb BUILD_NUMBER_HEX`
becomes `defb "000E"`. Splitting it means passing the number as an *integer* and
rendering four hex digits with per-nibble assembler arithmetic — more code, in
the language with the least room, to avoid one `-D`.

**`make bump` DOES NOT CARRY INTO THE HIGH BYTE**, and that is a decision the
issue left open rather than one it made. At `xx.FF` it refuses and names
`bump-major`. The stated acceptance criterion is only that both stay inside
`0000`-`FFFF`, which a carry satisfies — but the reason the high byte exists is
that it says *series*, moved deliberately for a release or a milestone, and a
256th merge silently minting `01.00` would assert a decision nobody made. Both
targets also reject a `version.yaml` that is not four hex digits, **including the
decimal value this change replaces**, so a half-migrated tree fails loudly
instead of bumping `14` to `15`.

**THE FINDING THE ISSUE DID NOT ANTICIPATE: mfselect's status row was already
exactly full.** `Installed: ` at column 1, a 15-character name at 12, a space,
four digits at 28 — columns 1 to 31, nothing to spare, and the source comment
said as much. The dotted number is **one character wider**, and `print_at()`
clips at column 32, so the fifth character would have been dropped **in
silence**: the row would have read `00.0` and nothing anywhere would have
complained. The row now starts at column 0, where the title and footer bars
already do, and `Installed: dezogif_ng UART 00.0E` is exactly the 32 columns
there are — **read back off the screenshot** with `test/screen-text.py`, not
inferred from the source.

That moved M9/M10's status field from columns 23-26 to 22-25. The bench is what
would have caught a silent shift and is also the thing that had to move with it.
Rejected: shortening `Installed:` or the ROM names to buy the column — both
change what the screen says to pay for a rendering detail, and the names are
exactly what M9 matches against the menu's own copy of them.

**The 32-column `ASSERT` was watched to fail, and at the boundary as well.** Both
branches of `INTRO_TEXT`: five characters injected makes the line exactly 32 and
it assembles; six makes it 33 and `src/data_const.asm(118)` (UART) and `(79)`
(WiFi) both go red. The real line is 27 of 32. This file's neighbours carry three
entries about bounds nothing checked, and an assertion nobody has watched fire is
a comment with a keyword in front of it.

**Both ROMs move by exactly one byte, and that is correct for common code** — the
banner is shared, so the UART byte-identity gate is *expected* to differ, as it
was for issues #7, #8, #9 and #12. `main_end` UART `0xF1FF` → `0xF200`, WiFi
`0xF995` → `0xF996`; 3232 and 1290 bytes still free to the identity block. Pinned
at `BUILD_TIME=1700000000`: UART `49d92c15…` → `57b88fd3…`, WiFi `fb9b5e92…` →
`e6b45d9f…`, with `build/*.bin` deleted before each pinned build — the trap
[[ERRORS.md]] records, since make would otherwise reuse intermediates assembled at
an unpinned time.

**Evidence: `make test-mfselect` 10/10, `make test` 6/6, `make test-dzrp-stub`
15/15 with W1-W5, and both variants `check-reproducible`.** T6's repaint moved
90.28% → 90.31%, which is the extra character and nothing else.

**Rejected.** Putting the dot in the block (above); a `bump` that carries
(above); a bench check that the two renderings agree — they come from one symbol
in one assembler pass, so there is nothing there for a test to observe that the
build has not already settled.

**Not touched, deliberately:** the historical `build 000A` / `build 0006`
references in this file and under `doc/`. They record what was measured on
particular builds, and respelling them would be editing evidence to match a new
format. New entries use the dotted form.

---

## 2026-08-06 — The verdict rule reaches the shell benches; and a fourth count of the same thing

**Decided (user, 2026-08-05) and built.** The twenty-word verdict rule now
covers the **shell** benches, not only the two Python harnesses it was written
for ([[#C15 sends CMD_CLOSE]]). Every `PASS`/`FAIL` line the nine
`test/run-*.sh` benches print is at most twenty words, and the reasoning that
used to ride in the printed line moves into a **block comment above its own
assertion** — where the reader who needs it is already standing.

**The shell benches were the anomaly, not an exception.** `make test` is the
gate, so these are the first verdicts anybody reads; the rule's own
justification — a verdict a reviewer scrolls is a verdict nobody reads — applied
*least* where it was needed *most*. Eight scripts changed. The ninth,
`run-esp.sh`, prints no verdict of its own: its E1-E4 come from
`esp-echo-client.py`, which is why it appears in the rule and not in the diff.

**`CLAUDE.md` carries the rule with two carve-outs, both interface rather than
taste.** **The check id never changes** — `T1`-`T6`, `M1`-`M10`, `W1`-`W5`,
`C1`-`C15` and the rest are cited by every document and issue, and two things
*match* on them: `run-dzrp-stub.sh`'s W3 greps `^FAIL  C10 `, and
`hardware-check.py` takes the code from field 2 of every `FAIL` line. Shorten
the prose after the id; never the id. And **a clause a reviewer added to stop a
check overclaiming is never trimmed**: some of these lines are long precisely
because an earlier version claimed more than the run had shown. N4 still says
the *mechanism* fired and is "not a repair"; `test-client-status`'s reader
failure still says the session line was **not judged**, so a broken reader is
never reported as a wrong screen. Where such a clause will not fit it moves into
the comment and is not deleted — and if it survives neither move, the long line
stays and says so.

**THE MEASUREMENT, AND ONLY HALF OF IT IS SAFE TO QUOTE.** Four independent
counts were taken of the same eight files:

| source | strings | over 20 before | longest |
|---|---|---|---|
| the commit message | 137 | 45 | 46 |
| the independent reviewer | 139 | 43 | 46 → 19 |
| the manager | 139 | 42 | 46 → 19 |
| this entry, re-measured | **139** | 42-43 | **46 → 19** |

**Reproduced by every count and safe to assert**: **139** verdict strings; the
longest fell from **46 words to 19** — or to **20** under the substitution model
described below, so the exact maximum is model-dependent in the same way the
before-count is, and only the bound is not; and **none now exceeds 20** — which
is the only claim the rule actually makes, and the one figure on which all four
agree exactly.

**Parser-sensitive, and NOT to be quoted as a precise figure**: how many were
over budget *before*. Four counts gave 42, 43, 45 and 42-43. The spread is
entirely in how each parser models `$(...)` and `${var}` inside the strings, and
a substituted value's real word count is **unknowable statically** — so the
honest statement is *roughly forty*, and this entry deliberately does not
improve on it.

**THE MECHANISM WAS FOUND THIS TIME, AND IT IS WORTH THE SPACE.** Counting the
same 139 strings under three substitution models gives three answers, and one of
them *manufactures* words: replacing a substitution with **nothing** turns
`($ours_pct%)` into `( %)`, two tokens where the source had one, so that model
scores 24 strings *higher* than the model that replaces it with a single token.
It reports the post-change maximum as 20 rather than 19. Neither is a wrong
count of a real thing; they are counts of different assumed expansions.

**THE LESSON, AND THIS RULE HAS NOW PRODUCED IT THREE TIMES IN ONE DAY.** Each
time the disagreement looked like arithmetic and was the **instrument**:

1. the **unit** was never written down — one measurement counted `label — detail`
   and another counted the detail, and a convention dispute was mistaken for an
   off-by-two ([[#C15 sends CMD_CLOSE]]);
2. a script substituted a **one-word token for a multi-word `%s`**, scoring
   C13/C14 at 17 where the literal strings give 20;
3. and now `$(...)` in shell, above.

**A word count over interpolated text is an estimate, and the only figures worth
asserting are the ones that survive a different parser.** Where a figure does
not survive one, say the band and say why — as this entry does for "roughly
forty". See [[ERRORS.md]], which carries the same disease under three other
names.

**Rejected.** Leaving the shell benches outside the rule (they are the first
verdicts a developer reads, so exempting them would have kept the rule where it
mattered least); **deleting** the reasoning rather than moving it into comments
(this project has decided repeatedly that a check's reasoning is load-bearing
and belongs in the source — it is what `doc/DZRP-TESTING.md` and the C15 entry
both rest on); and pinning the before-count to one number by picking a
favourite parser, which would assert a precision the input does not have.

**Verification, and it is narrower than the change may look.** Eight benches run
serially and green by the independent reviewer — `test` 6/6, `test-dzrp-stub`
15/15 with W1-W5, `test-no-hang` 4/4, `test-client-status` 3/3,
`test-tx-patience` 3/3, `test-ip-boundary` 2/2, `test-unit` 5/5,
`test-mfselect` 10/10 — with W3's negative control demonstrated firing live; and
a static audit showing the diff is **string literals only**, apart from two new
comment blocks. **It says nothing about hardware and nothing about `src/`.**

**Test-only: no `src/` file and no `Makefile` change, so no `make bump`** —
checked mechanically, `git diff main..HEAD -- src/ Makefile` is empty, so no ROM
byte moves.

---

## 2026-08-05 — C15 sends CMD_CLOSE; a check says WHAT HAPPENED and the docs say what it means

**Decided (user) and built.** Three things landed together, and the last is a
standing rule rather than a one-off.

**1. C15, and the half of it that is not obvious.** Nothing in the conformance
suite had ever sent **command 2**: C1-C14 each take a fresh connection and drop
it, which is a TCP event and not a DZRP one, so the remote was never told a
session ended. C15 asserts the specified **Length=1 response** *and* that a
`CMD_INIT` after it is answered. The second is the point — `cmd_close` answers
**first** and only then does the destructive part: it sets `prgm_state` to
`PRGM_IDLE` itself (`commands.asm:239-240`) and leaves through `jp main`, whose
prologue resets `backup.speed`, `backup.interrupt_state`, `backup.layer_2_port`
and `slot_backup.slot0` — and sets `prgm_state` a second, redundant time
(`main.asm:129-143`) — before `transport_activate` and `show_ui`. **The response
is written before all of that and proves none of it.**

The follow-up is `CMD_INIT` because DeZog's own stress driver does exactly that
— `cmdList`'s first entry is `sendDzrpCmdClose()` immediately followed by
`sendDzrpCmdInit()` on the same remote — and because no remote may refuse
`CMD_INIT`, so a failure there cannot be a capability difference wearing this
check's name. It is sent **without `talk()`**: `talk()` maps a closed connection
onto `Unsupported`, and C15's command name is `CLOSE`, so a remote that answered
perfectly and then hung up would have been reported as *not implementing the
command it had just implemented*.

**WHAT CONTROL (C) PROVED C15 CANNOT SEE, and it belongs here rather than only
in a docstring.** Three scratch ROMs, one edit each, none committed. (A)
`cmd_close` routed to `cmd_not_supported` → red on the response. (B) `cmd_close`
flushing and then hanging → red on serving on, which is the half that matters.
**(C) `jp cmd_loop` in place of `jp main` → C15 PASSES.** That stub answers and
goes on serving *without ever running `main`'s prologue*, and C15 is blind to
it, because the backup fields are **not observable over a socket**. So the
honest statement of what C15 establishes is "answered, and still serving" —
never "the session state was reset". A check bounded by measurement rather than
by assertion.

**WHAT (C) SKIPS IS NOT WHAT THE FIRST VERSION OF THIS ENTRY SAID, and the
correction narrows the control rather than weakening it.** That version listed
`prgm_state` → `PRGM_IDLE` among the things (C) fails to do. It is not:
`cmd_close` sets `prgm_state` **itself, unconditionally, before the `jp`**
(`commands.asm:239-240`), so (C) leaves it at `PRGM_IDLE` exactly as the shipped
ROM does — `main`'s write of it (`main.asm:133-134`) is redundant. What (C)
genuinely skips is `backup.speed`, `backup.interrupt_state`,
`backup.layer_2_port` and `slot_backup.slot0`, plus the `di` and stack reset.
**The conclusion is untouched**: none of those is observable over a socket
either, so C15 still cannot see the difference and its scope is still "answered,
and still serving". The mechanism was attributed to the wrong routine, which is
the failure this file names repeatedly — a plausible mechanism stated instead of
a traced one, in an entry whose whole subject is what a check can and cannot
see.

**(B) needed an explicit `TRANSPORT_END_MESSAGE` before its hang, and that is a
real fact about the WiFi build**: `cmd_close`'s response is buffered and the
flush lives at `main_redraw`, so on that build the response reaches the wire
*because of* `jp main`. Without the added flush, (B) would have gone red on the
response and proved nothing about serving on.

**2. `UNCOVERED` moved out of `hardware-check.py` into
[doc/HARDWARE-TESTING.md].** A thirty-line block printed after every run is read
once and then scrolled past; a document can be revised, cited and diffed.

**THE BRIEF FOR THIS WAS WRONG ABOUT ITS PREMISE, and the near-miss is the
transferable part.** It said the doc did not carry the content. It did — a
section called *"What a green run does NOT establish"*, with the stackless-NMI
paragraph in a **fuller** form than the harness had. Following the instruction
literally would have minted a second section duplicating the first. Only three
things were genuinely missing and were folded in: the screen paragraph
(`CMD_READ_MEM 0x4000,6912` fetches the stub's own screen, so S1-S5 could be
assertions), the UART "this gap has GROWN" (byte-identity has answered nothing
four times — #7, #8, #9, #12), and the interleaved-commands bullet, which still
described #13 as an open defect when it is fixed with W5 as its check.

**And the deletion nearly cost a correction.** The `UNCOVERED` block carried the
sentence recording that *"AltROM on hardware, never on silicon"* had become
untrue. `hardware-check.py`'s **module docstring still held the uncorrected
version**, so removing the block would have left the wrong claim as the only
surviving one — a retraction deleted while the thing it retracted stayed. **When
deleting prose, check whether it is the only place a correction lives.**

**3. A check line says what happened; the documents say what it means.** Every
verdict `conformance.py` and `hardware-check.py` print is one sentence of
**about twenty words**. Ids are untouched and are interface, not prose:
`run-dzrp-stub.sh`'s W3 greps `^FAIL  C10 ` and `classify()` takes the code from
field 2.

**THE UNIT IS THE `detail`, NOT THE LABEL, AND NOT WRITING THAT DOWN COST TWO
REVIEW ROUNDS** (adjudicated by the user, 2026-08-06). The label is the check's
fixed title from the `CHECKS` table — written once, never varying at run time,
not prose the check chose — so it is not charged to the check's budget. Two
things force the reading, and both are checkable:

- `hardware-check.py` prints `"  %-4s %s %s" % (tag, paint(status), detail)`,
  where the tag is a bare `H3`. Its one long-agreed exception, H3's failure
  composite at **~25 words**, is therefore a count of a *detail* — there is no
  label there to count. That single fact settles it.
- the labels in `conformance.py` run **3 to 9 words**. Charging them would give
  C3 seventeen words of prose and C15 eleven under the same nominal rule, which
  is not one rule.

**Measured mechanically under that definition**: every reachable detail in both
harnesses, **81** of them, representative values substituted and worst-case
joins expanded. Single-cause details run **1 to 14 words, median 8**; the
longest is **14**, `main()`'s REQUIRED-refusal branch. **So the budget is
comfortably kept and there is NO single-cause exception anywhere** — the
"longest single-cause line is 22 words" ceiling asserted a commit earlier was an
artefact of counting `label — detail`, and the exception it created has been
withdrawn from all six places it was stated.

**Four** branches do exceed it, all joins of several *independent* faults:

| branch | worst-case detail | why it is long |
|---|---|---|
| C11 `chk_continue_state`'s `"; ".join(problems)` | **58 words** | nine independent faults — BC/IX inward, six registers outward, A |
| `hardware-check.py`'s H2 novel composite | **38 words** | names every failing check by id; worst case is all 15 red |
| C10 `chk_continue_resumes`'s join | **29 words** | wrong address, no marker, ran past the breakpoint, illegal reason |
| `hardware-check.py`'s H2 known-red composite | **27 words** | same, 15 ids |

**They are deliberately NOT truncated, and the fix was to the CLAIM rather than
to the output.** Each joined fault is separately load-bearing: "the state was
corrupted" is not a finding, "SP came back elsewhere while everything else
survived" is. And the compounding is not a rare tail — **a badly broken resume
path is precisely the thing that fails on several axes at once**, which is what
C10/C11 exist to catch, so the longest lines belong to the most important
failure. Cutting them returns the reader to the bare "no reply" that cost this
project eight hours on 2026-08-05, which is exactly the argument that already
kept H3's composite long. Every one of the four is now marked at its call site
with why, in H3's style.

**Measured on the PASS path only the first time, and that was the review's
finding.** "All 15 lines comply, max 19" was true of a *healthy* run and said
nothing about the failure branches — where a 25-word C15 line lived, quoted
verbatim in our own documentation, produced by our own control. Re-measuring
across **every** branch then found three more, the `PRECONDITION` ones on
C10/C11. **A rule checked on the happy path is a rule half checked**, and the
paths a test bench exists for are the unhappy ones.

**AND THAT RE-MEASUREMENT WAS ITSELF DONE BY HAND AND ITSELF MISSED THINGS** —
the second occurrence of one disease in one commit. It caught the branches it
went looking for and never enumerated the rest, so four compound joins survived
under a claim that said there were none. The `PRECONDITION` fix it made was
real (that branch's detail measures **11** words, comfortably inside the
budget); the *claim* it attached to the fix was not. **A rule about output is a
rule about every branch of that output, and the only way to know is to enumerate
them with a script** — `ast`, representative values, worst-case joins expanded.
Eyeballing produced both wrong measurements.

**THE THIRD ROUND WENT ON AN OFF-BY-TWO, AND THE REAL FAULT WAS THAT NOBODY HAD
SAID WHAT WAS BEING COUNTED.** One measurement said the REQUIRED-refusal branch
was 22 words, a re-measurement said 24, and both were counting
`label — detail` — a unit the rule had never named and which the H3 exception
already contradicted. The true figure is **14**, and there was never anything to
mark. **A measurement is not reproducible until the thing being measured is
defined**, and "re-measured mechanically" buys nothing when the script measures
the wrong unit — it only makes the wrong answer more precise, which is how a
disagreement about a convention got mistaken for a disagreement about
arithmetic. The definition now leads the rule in `conformance.py` and in
[DZRP-TESTING.md], so the next person cannot pick the other reading.

*(One supporting claim in that adjudication does not survive checking, and it is
recorded because the conclusion stands without it: the suggestion that "several
routine lines already breach" under the label+detail reading. Measured — **no**
`PASS` line exceeds 20 that way, and **three** sit at exactly 20: C13, C14 and
C15. Only two lines breached at all, both the REQUIRED-refusal FAIL at 22. The
decision rests on the H3 rendering and the 3-to-9-word label spread, which do
hold.*

*That count read "exactly one" when this footnote was written — **a figure
asserted without measurement, inside the footnote about figures asserted without
measurement**, and the fourth uncorroborated number in this chain caught by
someone other than its author. The mechanism is the instrument, not the
arithmetic: the enumerating script substitutes a **one-word** token for every
`%s`, and C13/C14's detail interpolates `"sprite attributes"` and `" of zeros"`
— multi-word values — so it scored them 17 where the literal strings are 20.
**A representative value is an approximation, and an approximation cannot settle
a boundary case.** Caught by a reviewer measuring against the real strings.)*

**H3's exception stands unchanged.** `hardware-check.py`'s H3 *failure*
composite runs to ~25 words, because it joins which connection got no reply,
which other connection holds the payload, and whether a pause fixes it — and
that combination is what discriminates the `SEND OK` window from an id bug. The
**user narrowed the exception explicitly** to the failure line: H3's PASS line
lost its `— the +IPD id is read from the header, not assumed` tail, which is
explanation, and it now lives in the doc.

**Rejected.** Keeping the reasoning in the printed lines (a verdict a reviewer
scrolls is a verdict nobody reads); a per-check verbosity flag (two renderings to
keep in step, for output nobody reads twice); `--require CLOSE` in
`run-dzrp-stub.sh` — *wanted*, by the same argument as the existing
`--require CONTINUE`, but that file was being edited for issue #17 and is
recorded as a follow-up instead.

**Test-only: both ROMs are byte-identical to `main`'s** with `BUILD_TIME` pinned
(`49d92c15…`, `fb9b5e92…`), so **no `make bump`**. Getting that comparison right
took two goes and the failure is in [[ERRORS.md]]: deleting the ROMs is not
enough, because make reuses `main-wifi.bin`/`mf_nmi-wifi.bin` assembled at an
unpinned `BUILD_TIME`. **That corrects the wording of the 2026-08-05 identity
entry below**, which said to delete "the outputs" — the outputs are not what make
decides about; their prerequisites are. *(That entry was left unedited by this
commit and carried the insufficient instruction for one more commit; corrected
in place 2026-08-06.)*

**`make test-dzrp-stub`: W1-W5 pass, 15 passed / 0 failed of 15, exit 0.**
C15 has **not** run on hardware; the next hardware run is 15 checks, not 14.

[doc/HARDWARE-TESTING.md]: doc/HARDWARE-TESTING.md
[DZRP-TESTING.md]: doc/DZRP-TESTING.md

---

## 2026-08-05 — A bench observes its emulator leave; the check is shared, not copied

**Decided and built, issue #17.** The invariant is: **no bench may release the
flock mutex while anything it started still holds port 11000**, and a bench that
cannot confirm departure **fails loudly rather than exiting 0**. Every bench that
starts jnext now confirms it, through one shared file, `test/bench-jnext.sh`.

**The defect it closes is a lock that excludes correctly and still does not
exclude.** Each bench records `jnext_pid=$!` from `timeout … "$JNEXT" … &` — the
**wrapper's** pid — so `kill`/`wait` reap the wrapper and say nothing about the
emulator or the port. `flock` serialises *scripts*; the thing that binds 11000 is
a *process that can outlive one*. Observed 2026-08-05 with three agents all
holding the lock: a jnext from a run that had already finished, by its artefact
mtimes, alive on the port. ERRORS.md carries the incident.

**SHARED, NOT COPIED, AND THAT IS THE DECISION WORTH RECORDING.** The fix already
existed — in `run-client-status.sh`, written the day it was seen — and the other
six benches never got it. That is *why* this was a repository-wide defect rather
than a one-file one, so six more copies of forty lines of reasoning would be six
more places for the next correction to miss. The helper **defines functions and
does nothing else** — no `set`, no traps, no top-level assignments — so sourcing
it cannot disturb a caller's `set -euo pipefail` or its own trap wiring, which
ERRORS.md's `cp --reflink` entry spent four wrong mechanisms getting right.
`run-client-status.sh` was converted to it too: leaving the original as a second
implementation would have preserved exactly the drift being fixed.

**Scoping the sweep is load-bearing and the issue says so: a bare `pkill jnext`
would make this WORSE than the bug**, by killing a correctly serialised
concurrent run. So a sweep only ever reaches jnext processes running **the
bench's own SD image**.

**And that comparison is by RESOLVED ABSOLUTE PATH, against each process's own
`/proc/<pid>/cwd` — not by substring.** `$OUT` defaults to the relative `build`,
so two agents running the same bench in two different **worktrees** both put
`--sdcard build/sd-dzrp.img` on the command line: identical strings naming
different files. A substring match would have swept the other worktree's
emulator, which is the precise thing this exists to prevent. The reference
implementation matched the substring; that is the one place this deviates from
it, deliberately.

**Two ordering details, each with a failure behind it.** The working image is
unlinked **before** departure is confirmed, because the confirmation can `exit`
and an exit that skipped the `rm` would reintroduce the abandoned-gigabyte leak
ERRORS.md records. And a departure failure is reported **once**: the failing path
reaches the check twice — where the run ends, and again from the EXIT trap the
resulting `exit` fires — so the first version waited out a second ten-second
budget and printed the same wall of text again, which reads as two faults.

**THE PROPAGATION FAILURE WAS NEVER REPRODUCED, and the change is shaped for
that.** It is not the repair of a known mechanism; it is a refusal to proceed on
an assumption. Measured here, and the second measurement is new: killing the
wrapper reaches jnext in well under 2 s, **and so does `kill -9` on the wrapper**
— which `timeout` cannot forward at all. jnext was orphaned deliberately, twice,
and died with its wrapper both times, with no `PR_SET_PDEATHSIG` anywhere in its
source to explain it. So no available manoeuvre produces the orphan that was
nonetheless *seen*. The survivor therefore has to be injected to be tested, and
the injected condition is the observed one: a jnext belonging to a run that had
already finished.

**What the evidence is, and what it is not.** Demonstrated: a squatted port makes
a bench refuse to start a run instead of reporting a verdict (`run-ip-boundary.sh`
had **no** port check at all before, and with 11000 held it ran both checks and
printed `0/2 checks passed` — a verdict about the parser from a stub that could
not bind); an injected stale emulator is detected and killed by the escalation in
2.22 s; one that will not die makes the bench print the surviving PID and exit 1
with none of its six checks run; the same emulator is invisible to a sweep scoped
to another image; an interrupted bench exits 143 without finishing and leaves
nothing behind. **Not** demonstrated: an emulator actually outliving its script,
for the reason above.

**`run-headless.sh` and `run-mfselect.sh` get the check with a SMALLER claim
attached, written into the scripts.** Neither passes `--esp`, so neither binds
11000 and neither takes the lock; the "a survivor answers the next agent's
client" failure cannot originate there. What can is an emulator left running
after a `timeout` fired or an interrupt landed, competing for the machine and
holding a gigabyte image open. Saying that in the script is cheaper than letting
a reader infer the larger claim from the identical code.

**Rejected.** A per-script copy of the teardown (defensible on the surgical-change
rule, and it is what produced the issue); `pkill jnext` (kills other agents' runs
— the issue names this); polling only the port (it cannot name a PID, cannot
distinguish our listener from a foreign one, and says nothing about the two
benches that bind no port); a helper that also removes the working images left by
`run-headless.sh` and `run-mfselect.sh` (a real leak, recorded in ERRORS.md, and a
different change); deriving the sweep from `$SD_IMAGE` for `run-unit-tests.sh`
(it runs the **reference** image read-only and synchronously with `--no-esp`, so
scoping to that basename would be the cross-run hazard this entry refuses — it is
left uncovered, and this says so).

**Test-only: no `src/` file and no `Makefile` change, so no `make bump`.** Checked
rather than assumed — both ROMs hash identically to the branch point with
`BUILD_TIME` pinned (`c21a73ba…` UART, `d3aa0e4e…` WiFi). All eight benches green
afterwards: `test` 6/6, `test-esp` 5/5, `test-ip-boundary` 2/2,
`test-tx-patience` 3/3, `test-dzrp-stub` 14/14 with W1-W5, `test-client-status`
3/3, `test-no-hang` 4/4, `test-mfselect` 10/10.

---

## 2026-08-05 — A wait that ends must end somewhere harmless; and a CRLF that could swallow a command

**Decided and measured, issue #16.** Three changes plus one accident, and the
accident is the largest of them.

**THE ACCIDENT FIRST, because it was in front of everybody for a month and it
is worse than a cosmetic fault.** `esp_flush_chunk` waited for `"SEND OK"` and
the module answers `"\r\nSEND OK\r\n"`, so the trailing CRLF stayed in the RX
FIFO. `cmd_loop`'s `transport_wait_rx` ends on **any** byte from the module, so
it returned at once and `receive_bytes` asked for a command that was not there.

**WHAT FOLLOWS DEPENDS ENTIRELY ON WHEN THE CLIENT SPEAKS AGAIN, and the first
version of this entry said "after every single response", which is WRONG.**
`esp_sync_ipd` does not fail on seeing `\r\n` — it keeps scanning for a full
`ESP_RX_WAIT` pass, ~97 ms at 28 MHz — and `rx_timeout` then runs a 100 ms
`transport_drain`, whose whole job is to empty the FIFO. Three regimes, not one:

| when the next command arrives | what happens |
|---|---|
| inside the ~97 ms scan | the scan finds it and answers it. Nothing lost, nothing reported |
| after the scan, inside the 100 ms drain | **read off the wire and discarded.** The client is never answered and waits for ever |
| after the drain | answered, but via `drain_main`: "RX Timeout" on a healthy machine, `prgm_state` back to `PRGM_IDLE`, the backup fields re-initialised |

**Measured, not reasoned, and the instrument was built because the claim was
challenged.** Two ROMs differing in that one string, both carrying a counter on
`esp_next_wire_chunk`'s timeout rendered on the stub's own screen, ten
`CMD_INIT`s at a fixed gap. Wall clock; headless jnext advances emulated time
~5.5x faster than real (274-284 frames/s measured against 50), so these gaps are
roughly a fifth of the stub's own budgets:

| gap | without the CRLF | with it |
|---|---|---|
| 0, 5, 10, 20 ms | 10/10 answered, 1 drain | 10/10, **0** drains |
| **25, 30, 40 ms** | **1/10 answered**, 1 drain | 10/10, **0** drains |
| 60, 80, 100, 500 ms | 10/10 answered, **1 drain per command** | 10/10, **0** drains |

**A DEAD BAND IN WHICH COMMANDS ARE SILENTLY SWALLOWED** is a hang, not a
blemish, and it was nowhere in the first write-up. On hardware, where there is
no emulator speed-up, the band is the stub's own budgets: **roughly 97-197 ms
between commands**.

**PREDICTED IN THE EMULATOR, THEN CONFIRMED ON SILICON — the strongest single
result on this branch.** The manager session ran it on a real Next, build 000B,
four trials per gap: **0 of 4 answered at 120 ms**, then 1/4, 2/4, 3/4 at 140,
160 and 180 ms, and clean at 100 ms and at 250 ms. Predicted 97-197, **measured
120-200**. A quantitative prediction derived from two constants and a swept
emulator run, landing on hardware to within the width of the measurement — and
it says the defect on `main` today is not cosmetic, it eats commands at
inter-command gaps a real client produces.

**The first hardware sweep reported a REFUTATION and was wrong**, which is worth
recording because it nearly buried the result: the harness read a DZRP
*response* length as payload-only where it counts from the sequence byte, so
every trial died on its first command and the verdict logic scored that as
"answered". A negative result from an instrument that never worked is not a
negative result. The numbers above are the corrected run.

**And it reconciles C10/C11, which is what the challenge was about.** A full
14-check conformance run against the broken ROM costs **2** drains, not dozens,
with C10 and C11 green: the suite pipelines, so it lives in the first row of
that table and `drain_main` almost never runs. The 848 bright-red pixels that
started this stand unchanged — that probe sent one command and went silent for
thirty seconds, which is the third row.

**The lesson is the correction itself.** The pixels were real and the scope
attached to them was invented. "After every response" was never measured; it
was inferred from one client's behaviour and generalised. See ERRORS.md.

**A — the bound, and where expiry goes is the whole decision.**
`transport_wait_rx` was the only unbounded wait in either transport. BC and DE
are untouched between the two layer-2 writes either side of the loop, so the
counter lives in registers: the no-CALL/no-PUSH rule was never the obstacle it
had been taken for.

**Expiry does NOT report and does NOT go through `drain_main`.** The issue asked
for `jp rx_timeout` and that would have been wrong. `cmd_loop` ends
`jr cmd_loop`, so this wait **is** the debugger's idle state once a client has
attached — what it waits for is the next thing the user does in DeZog, and
someone reading code for a minute before pressing F10 is the normal session.
Any finite bound therefore fires on healthy sessions, and `drain_main` falls
into `main`, which re-initialises `prgm_state`, `backup.speed`,
`backup.interrupt_state`, `backup.layer_2_port` and `slot_backup.slot0` — the
**debuggee's** saved state. That trade is "convert a hang nobody has reproduced
into silent corruption of the program being debugged", and it was caught by the
manager session tracing it rather than by the author. It restores the layer-2
port, resets SP and jumps to `main_idle` instead.

Nothing is half-received at that moment, provably: the loop can only get there
with `esp_rx_remaining` zero, no frame held and the FIFO empty — its own
conditions — and `cmd_loop`'s `TRANSPORT_END_MESSAGE` already flushed the
outgoing buffer. **That is what makes leaving safe from THIS wait and would not
from a wait for bytes already owed**, and it is the sentence to keep.

It also **removes** a hazard rather than trading one. Parked in that wait, an
unsolicited `<id>,CONNECT` or `<id>,CLOSED` ends it and then fails to parse as
a `+IPD` header — reaching the same destructive reset. The WiFi build does that
today, every time a client disconnects while idle.

**Landing in `main_loop` made a destructive key reachable, and `main` is split
because of it.** `check_key_border`'s `jp main` (and the UART build's joy-port
keys) now go to `main_redraw`, which does everything except that state reset.
Before the bound, those keys could only be polled while `PRGM_IDLE`, so the
reset was a no-op; afterwards "B" — a border toggle — would have discarded a
stopped debuggee's saved state. Also caught in review, not by the author.
`main_idle` is the timer init, so an expiry cannot arrive with garbage in the
border-colour counter.

**Five seconds**, `WAIT_SECS`-overridable. The long-bound argument evaporates
once expiry is non-destructive: the only cost of a short bound is bouncing into
a poll loop the debugger already runs whenever no client is attached.

**B — a send that has announced its length is completed, whatever happens.** On
the prompt-timeout arm the payload now goes out anyway and the fault is
remembered and reported afterwards; the payload loop uses a bounded
`esp_send_try` so a byte that could not be written can no longer stop the frame
half-way. The **real** payload, not filler: if the module was merely slow its
prompt arrives while the bytes are still being shifted and the client gets its
reply, which is measurably what happens under the injected budget.

**C — five consecutive faults bring the AT chain back up.** `esp_fault_count`
is incremented by `rxtx_error` and cleared by `transport_init` and by a
`SEND OK`. `esp_recover` stops the listener first, because `AT+CIPSERVER=1` is
refused while one is running and a re-init without it would paint "ESP-01 setup
failed" over a working module.

**IT DOES NOT RECLAIM A WEDGED PEER'S SLOT, AND A FIRST VERSION OF THIS CLAIMED
IT DID.** The comment asserted that `AT+CIPSERVER=0` closes established
connections. It does not: jnext says so outright (`esp_at.cpp:619-621`,
"Established connections are deliberately left alone: the guest asked to stop
ACCEPTING"), and that is real ESP-AT behaviour rather than a jnext
simplification — ESP-AT's own `AT+CIPSERVER=0,<close_all>` argument is
**refused rather than ignored** (`esp_at.cpp:601-607`, test SRV-12) exactly so a
caller cannot believe it asked for closure and quietly not get it. Caught by the
independent reviewer, who also traced the `1,CLOSED` in N4's log to
`note_peer_close` — the bench client hanging up its own socket — rather than to
this command. **An assertion about the module, made without reading the
module's model**, which is the first hard rule in CLAUDE.md pointed at ESP-AT
instead of the VHDL.

**So the residual is a slot leak and it is not small.** Four inbound slots
(`esp_at.h:425`/`440`), connections past them dropped (`esp_at.cpp:830-838`,
"Real firmware refuses past its own ceiling too"), and nothing in this program
frees one. A peer that wedges rather than closing keeps its slot for the rest of
the power-on session; four of them — which is what a user retrying a hang
produces — and the module refuses every new client while `esp_recover` goes on
reporting success. **Issue #16's claim that part C "subsumes the stale link
slots problem" is FALSE and is contradicted here rather than left to be
discovered.**

*(**CORRECTED 2026-08-08**: "keeps its slot for the rest of the power-on
session" is false. The module reaps it itself at `AT+CIPSTO`, ~180 s, measured
enforced on real hardware — see the 2026-08-08 entry at the top of this file. So
the residual is **bounded**, not permanent, and the four peers have to overlap
within roughly three minutes rather than merely accumulating. What is untouched
is this paragraph's actual point: **nothing in this program frees one**, and
#16's part C does not subsume #19. The "user retrying a hang" clause is a
separate matter and was independently withdrawn by the 2026-08-06 entry above as
an unverified claim about user behaviour.)*

**Deliberately NOT fixed on this branch.** Freeing a multiplexed connection
needs `AT+CIPCLOSE=<id>`, and jnext's `AT+CIPCLOSE` takes no argument and acts
on the outbound slot only (`esp_at.cpp:124`, `cmd_cipclose`) — so the Z80 code
would be unexecutable by any bench here, on a branch whose whole value is that
its claims are checked. **Filed as dezogif_ng #19**, blocked on **jnext #211**
(`AT+CIPCLOSE=<id>` for multiplexed connections, with this project named as the
demonstrated consumer and sequenced as #210 was — the consumer exists and is
blocked). #211 asks that the `<close_all>` refusal STAY refused: that refusal is
what makes jnext's model honest, and it is the evidence this entry rests on.

**What is counted is the decision, not the number.** The idle wait's expiry is
deliberately **not** counted: it is indistinguishable from a client that is
thinking, and a recovery is not free — it retires the listener and puts it back,
refusing connections in between, clears `esp_conn_valid` so anything half-built
is dropped, and pays an AT chain. Counting the expiry would make a healthy
paused session buy all of that for nothing. That is what lets the limit be five
rather than one.

(An earlier version of this paragraph said "a recovery closes connections", which
is the same false claim the entry corrects four paragraphs above — left standing
six lines below its own correction, and phrased as the *reason*, which is the
worst place for it. Caught in re-review. **A correction is not finished until
the claim is gone from everywhere it was ever used as a premise**, and the
enumeration is a grep, not a memory.)

**NONE OF THIS IS A FIX FOR ISSUE #15, and the evidence points away from it.**
The manager session drove four candidate triggers at a real Next on build 000B
while this was being written — a client dying mid-command, a client that stops
**reading** mid-response, connection churn, and an RST landing while the stub
was blocked mid-flush — and **not one wedged it**; every one recovered within
~3 s. The first is precisely this loop with five payload bytes owed and the peer
gone: the next connection was answered in **4 ms**, because the loop also ends
on any byte from the module and a new connection makes the module speak. So the
unbounded wait is survivable on hardware, and an abandoned `AT+CIPSEND` is too.
What B fixes is a state a module should never be left in; what A buys is a
debugger that answers its own keyboard again. Issue #15 stays open.

**Evidence: `make test-no-hang`, four runs, all green, N3 shown red first.**
N1 is the loop as it was (`WAIT_SECS=0`), N2 the shipped ROM one constant away.
**The verdict is a keypress, not a reply**: the wait ends on any byte, so a
second command un-sticks even the unbounded build — asserting "can it still
serve" would have produced a check that passes either way. So "B" is pressed
during the silence and the border is read: yellow when the key was never polled,
black when it was. N3: before, both clients unanswered at 20 s; after, both
answered in 0.01 s with 824 bright-red pixels of "TX Timeout" as the
**precondition** that the injected budget was really reached — jnext's log
cannot show our timeout expiring, so without it N3 could pass having tested
nothing. N4 shows C's mechanism fires and re-listens; it is **not** evidence
that the recovery repairs anything, because nothing here can make the emulated
module unresponsive.

**Rejected.** `jp rx_timeout` on expiry (above — it corrupts healthy sessions);
a long bound to make that rare (any bound fires eventually, and "rare
corruption" is worse than "visible"); a liveness probe (`AT` → `OK`) before
deciding (unnecessary once expiry is harmless); gating the keyboard on
`prgm_state` instead of splitting `main` (it would have made "B" and "R" dead
during a session, and "R" is the escape hatch); counting the idle expiry towards
the recovery (it would disconnect healthy paused sessions); a different sentinel
for `esp_tx_fault` inside `esp_send_raw` rather than a bounded variant (the
payload loop is the one caller that must not divert, and a global change would
have moved every other call site's failure semantics).

**NOT COVERED, and said plainly.** A wedged peer's connection SLOT, above.
The **serial build's** half of A: identical
code, and nothing here can drive that transport headless — `make test`'s T6 runs
the serial ROM but attaches no client, so it never reaches `cmd_loop`. C at its
**shipped** limit, and C against a module that is actually broken. Anything at
all about a real ESP-01. And the **head-of-line blocking** the manager measured
the same day — one client that stops reading blocks the stub for as long as it
holds the socket, 33 s observed — which is deliberately **not** in this branch:
every chunk is already bounded and each one *succeeds* slowly, so no timeout
constant reaches it; it needs a bound on total elapsed time across chunks, a
time source this transport does not have, and a decision about what a client
sees when a response is abandoned mid-stream. Filed separately.

**Cost.** UART +36 bytes (`main_end` 0xF1DB→0xF1FF), WiFi +187
(0xF7F5→0xF8B0), 3233 and 1520 bytes still free to the identity block. **Both
ROMs move on purpose**: A is common code and `main.asm`/`constants.asm` are
shared. Pinned: UART `ba860de1`→`12e09efe`, WiFi `d3804367`→`f58faa73`. Both
variants `check-reproducible`.

---

## 2026-08-05 — The screen reports the SESSION, not the connection; and a bench that reads it

**Decided and built, issue #14.** WiFi mode's screen gains one line at row 8,
under the connect block:

    No debug session yet.
    Session opened (CMD_INIT).
    Session closed (CMD_CLOSE).

**THE CHEAP HALF WAS BUILT AND THE HONEST HALF WAS NOT, deliberately, and the
wording is what carries the difference.** The issue offered two: `CMD_INIT` /
`CMD_CLOSE`, which are already handlers running at the right moments; or
tracking the module's unsolicited `<id>,CONNECT` / `<id>,CLOSED` lines, which is
the same work as the reconnect residual `esp_flush_chunk`'s `.no_client` defers
to M3. The acceptance criterion is what decides between them — *"either it
tracks `<id>,CONNECT`/`<id>,CLOSED` and can be honest, or it says only what
`CMD_INIT`/`CMD_CLOSE` prove"* — and this says only the latter.

So every state is a **past-tense statement about an event that was observed**,
and each names the command it saw. That is not a style choice: it is the whole
of what makes the line legal. "Client connected" would be a claim about a socket
this transport cannot see, and would still be standing ten minutes after the
client had gone. "Session opened (CMD_INIT)" is true when it is drawn and stays
true afterwards, and a reader can see from the parenthesis that it reports
protocol traffic rather than a live link.

**What it therefore does NOT claim, stated in the source in the same words:** a
client that connects and never speaks (N1 asserts the line stays at NONE while
such a client is connected — a socket is not a session), and a client that
vanishes without `CMD_CLOSE`, which leaves ATTACHED standing. Closing the second
needs the `<id>,CLOSED` tracking above.

**UART mode gets the macros and expands them to NOTHING**, and that is also a
decision rather than an omission. Over a cable there is no connection to report:
the link exists whenever the debugger holds the joy port, whether or not
anything is on the other end. A line there could say a session had been opened
and could never say the peer had gone — less honest than silence.

**The seam is two macros, not an `IF ROM_VARIANT` in `commands.asm`.**
`TRANSPORT_CLIENT_ATTACHED` / `TRANSPORT_CLIENT_DETACHED` join the interface
beside `TRANSPORT_DEACTIVATE` and the two framing macros, for the reason
CLAUDE.md states as a hard rule: `commands.asm` must not be able to tell which
transport it was assembled against. **The UART ROM is byte-identical to
`main`'s** — `ba860de1…`, `main_end` 0xF1DB unmoved, with `BUILD_TIME` and the
build number pinned — which is the evidence that the seam held across a change
to common code. WiFi: `d3804367…` → `ea850838…`, `main_end` 0xF7F5 → 0xF86C,
**+119 bytes**, 1588 still free to the identity block at 0xFEA0.

**Neither macro repaints.** Both call sites already reach `show_ui` — `cmd_init`
calls it, `cmd_close` leaves through `jp main` — so the line costs nothing per
command, which the issue asks for explicitly.

**The state's lifetime is the debugger's, and that falls out of where it
lives.** It is in the image `init_main_bank` copies into MAIN_BANK, and that
copy happens on the FIRST M1 press after power-on and on a Symbol Shift
re-init — not on every press, because `mf_rom.asm`'s magic-number path goes
straight to `mf_nmi_button_pressed`. So breaking into a running debuggee with
the button leaves the line saying what it said, which is right, and a re-init
resets it, which is also right.

**THE BENCH READS THE SCREEN BACK AS TEXT, and that is the part worth copying.**
`make test-client-status`, three jnext runs, one per state. Every prior screen
check here compares one picture with another, and ERRORS.md records exactly what
that is worth: mfselect's M9 compared two runs, passed, and a reviewer then
**swapped** the two labels and it passed again. Here the two interesting states
are adjacent lines of similar length, so a swap is the obvious bug — and
cell-diff's answer to M9 (find the correct glyphs elsewhere in the same image)
is unavailable, because these words appear nowhere else on that screen.

`test/screen-text.py` decodes a row instead. No OCR and no committed reference
bitmap: the stub prints with the ZX ROM font, `main_bank_entry` copies it out of
the paged-in ROM at 0x3D00, and the bench pulls the same font off **the same SD
image the machine boots**. `ula.print_char` XORs an 8x8 glyph onto a screen
`show_ui` has just cleared, at multiples of 8, so reversing a cell is a
dictionary lookup. Each run therefore has a reading of its own line and is
judged alone.

**Shown red first, three ways, all re-run after a bench-serialisation scare (see
[[ERRORS.md]]):** against `main`'s ROM, 0 of 3 — row 8 empty; with the two table
entries **swapped**, N1 green and N2/N3 red, each reporting the other's text;
with `TRANSPORT_CLIENT_DETACHED` removed from `cmd_close`, only N3 red. The
second is the M9 trap and the first alone would not have caught it.

**Two things in the bench are checks on the bench.** The reader is validated
inside every image before its verdict is used — row 12 must read `R = Reset`,
drawn by the same code in the same font and not in question — so a broken
font or geometry reports itself instead of failing the subject. And the
screenshot's mtime is compared against the client's own "state is set"
timestamp, because jnext can only be told to capture at a FRAME and nothing can
make that wait for a TCP client: a capture that came too early is reported as a
harness problem, not as the screen saying the wrong thing.

**Rejected.** Present-tense wording of any kind, for the reason above; a line
that appears only in some link states (a row that comes and goes is the "screen
with holes in it" the status block already refuses to be — in FAILED it is
merely uninteresting, never wrong); reading the screen over DZRP with
`CMD_READ_MEM` instead of from a screenshot (it needs the same font to mean
anything, and couples the check to the debuggee's slot mapping); a host-side
render compared pixel-by-pixel rather than decoded (a mismatch would say "these
pixels differ" where a reading says what the line actually shows); folding the
three runs into `make test-dzrp-stub` (its four runs are the project's strongest
gate and this is a different subject; a separate target also keeps the diff away
from a file two other branches are working in).

**Noted, NOT fixed, and measured rather than assumed to be pre-existing.** N2's
screenshot carries `Last Error: RX Timeout` in the red area: a client that sends
one command and then goes quiet leaves `cmd_loop` reading a header that never
arrives, and the stub reports a fault on a machine with nothing wrong with it.
**`main`'s own ROM does exactly the same in the same phase** — checked, same
three runs, same rows — so this change neither causes nor cures it. It is the
neighbourhood of issues #15/#16 and belongs to whoever owns those. The session
line survives that repaint correctly, which is worth knowing: `drain_main` does
not reset `esp_client_state`, so the screen goes on reporting the session that
is in fact still open.

---

## 2026-08-05 — A reply belongs to one connection; a command belongs to one connection's frames

**Decided and measured, issue #13.** Two separate rules, because the defect was
two defects sharing a trigger, and **the obvious fix covers only one of them.**

**The trigger.** `cmd_get_tbblue_reg`, `cmd_set_breakpoints` and
`cmd_restore_mem` send their response header and **then** read payload. If the
command's payload does not all arrive in one `+IPD`, those reads reach
`esp_require_payload`, which takes the next frame — from anywhere — and writes
`esp_conn_id` on the way past. So: the reply went to whoever spoke last, **and**
the command's remaining bytes came out of that other client's frame. For
`cmd_set_breakpoints` the second one is breakpoint addresses assembled from two
clients and then written into the debuggee as `RST 0`.

**Rule 1, the latch.** `TRANSPORT_MESSAGE_START` — already at the first byte of
every response and every notification, and already the transport's own — now
snapshots `esp_conn_id`/`esp_conn_valid` into `esp_tx_conn_id`/`esp_tx_conn_valid`,
and `esp_flush_chunk` sends to the snapshot. A message cannot be redirected once
begun, whatever arrives. That is the issue's stated acceptance criterion, and it
is the whole of the addressing fix.

**Rule 2, ownership, and it is NOT redundant with rule 1.** `esp_cmd_id` names
the connection whose command is being received; a frame from anywhere else is
**parked** in the hold buffer (or dropped framed, when the buffer is busy)
rather than spliced, and served as the next command afterwards. Measured, not
argued: with only the latch, the split command is answered **on its own
connection with the wrong register's value**, and the other client's command is
eaten. A check asserting only "the reply reached the right socket" would have
been green over a debuggee still being patched with two clients' bytes.

**Where ownership is released is the subtle part, and the obvious place is
wrong.** `transport_flush` is NOT "the message ended" — `transport_write_byte`
calls it every `ESP_TX_CHUNK` bytes, mid-message. So `TRANSPORT_END_MESSAGE`
grew a routine of its own, `transport_end_message`, which clears
`esp_cmd_active` and falls into the flush. Those three sites (`cmd_loop`,
`main`, `main_loop.continue`) are the transport's only marker for "the debugger
is idle", and `transport.asm` already enumerates them for issue #11's reasons.

**Claiming has to happen at the first byte READ, not when a chunk is synced.**
`main_loop`'s poll calls `esp_sync_ipd` directly and `cmd_loop`'s
`TRANSPORT_END_MESSAGE` runs *after* it, so a claim made at sync time would be
cleared before the command it belongs to had been read — and the guard would
then be silently inert. It is claimed in `esp_require_payload` instead, which
every payload byte passes through. Reasoned first, then confirmed by the bench
going green rather than by the diff looking right.

**Parking rather than dropping, and rather than refusing.** Dropping the other
client's frame would have been ~20 bytes and is what a full hold buffer still
does. Parking costs nothing extra — `esp_capture_ipd`'s copy became
`esp_hold_frame`, taking an already-parsed header — and it keeps the other
client's command alive, so both are answered. Refusing to continue at all (an
RX timeout) was rejected: it turns two legitimate clients into a reported error.

**esp_conn_id is deliberately NOT restored after a park.** It names the
connection of the current chunk, and after a park there is no current chunk; the
next sync overwrites it. What the message being written depends on is the latch,
which is the point of having one.

**Evidence — red on TWO ROMs first**, bench check **W5**, run 5 of
`make test-dzrp-stub`:

| ROM | W5 |
|---|---|
| `main` | A never answered; **B received a reply carrying A's sequence number** |
| latch only | A answered correctly addressed, **with NextREG 0x09's value instead of 0x00's**; B's command eaten |
| as merged | `AT+CIPSEND=2,6` to A, `AT+CIPSEND=1,14` to B, in that order |

The precondition is asserted from jnext's own log — three `+IPD` frames, 6/15/1,
the middle from another connection — and the three client writes are **8 ms**
apart, a number bounded on both sides by measurement: below ~2 ms the module
frames the split command as one `+IPD` and there is nothing to test; above
~20 ms the stub's own RX budget expires first. Both edges were run.

**Cost: +110 bytes, WiFi only** — `main_end` 0xF7F5 → 0xF863, 1597 free to the
identity block. **The UART ROM is byte-identical** (`ba860de1…` pinned, before
and after), which is what says nothing shared moved: both macros are the
transport's own, so `message.asm` and `main.asm` did not change a byte.

**NOT COVERED, and none of it is hidden.** A **third** client speaking inside
the same window still loses its command — one hold buffer, one frame, which is
`esp_hold_frame`'s existing documented loss. Nothing here is evidence about
**hardware**: real TCP segmentation is not jnext's chunking. And the whole class
is **unreachable by DeZog**, which opens one connection and is strictly
request/response — so this is a latent defect closed, not a symptom cured.

**Rejected.** Reading the whole payload before answering in the three handlers
(the issue's own third option): it fixes the instances rather than the class,
the next handler written in that shape brings it back — and, more decisively, it
does not fix mode 2 at all, since a command's payload can span frames however it
is read. A "reserved" connection id to mean no-owner (the same reservation
mistake `esp_conn_valid` exists to have stopped, ERRORS.md). Clearing ownership
in `transport_flush` (mid-message, see above).

---

## 2026-08-05 — DeZog drives the stub on a Next, and an NMI against a RUNNING debuggee returns correctly

**Measured, not decided**, and it closes both M1's last item and the oldest
unverified claim in the project. A VS Code session, `remoteType: "cspect"`,
pointed at a real Next over WiFi: attach, disassemble, registers, memory,
single-step, **manual break**, clean disconnect, reattach. Captured through a
logging TCP tap, frozen at 1586 lines.

**The result that matters most is the twenty-second notification.** A
`CMD_CONTINUE` with **no temporary breakpoint** set the conformance fixture
running in its `jr $` at `0x801C`; ten seconds later the **M1 button** was
pressed; the `NTF_PAUSE` came back with break reason **1**
(`BREAK_REASON.MANUAL_BREAK`) and `CMD_GET_REGISTERS` reported **PC `0x801C`,
SP `0x9F00`**. `cmd_get_registers` reads `backup.pc`; `mf_rom.asm`'s dispatch reaches
`mf_nmi_button_pressed` only while `prgm_state` is `PRGM_RUNNING`; that path
calls **`save_nmi_return_address`** unconditionally; and the only other writer of
`backup.pc` needs an `RST 0` that no breakpoint was planted for. So the value is
that routine's and cannot be stale. **It had never executed anywhere**, in the
emulator or on silicon, and every NOT-COVERED list in this repository named it.

**WHICH OF ITS TWO BRANCHES RAN IS NOT ESTABLISHED, and I claimed it was.** The
routine reads NR `0xC2`/`0xC3` in stackless mode and the debuggee's own stack
otherwise, and **both give the answer we saw**. Nothing read NR `0xC0` back.
`doc/legacy/Design.md:378,434` make stackless the default from core 03.01.10 and
nothing in `src/` clears the bit, so it is a strong presumption — a presumption,
not an observation. **What is verified is the outcome plan §3.4 actually cares
about**: an NMI against a running debuggee returned a correct PC on an
uncorrupted stack, so entering the debugger did not corrupt the debuggee. Caught
by the reviewer, in a paragraph I wrote about not doing exactly this.

**It needed a finger, and that is the transferable part.** The reason no bench
could reach it is written down in three places: `--delayed-nmi` counts emulated
frames while a DZRP client counts wall clock, and the frame rate collapses under
traffic, so scheduling one is a race rather than a check. A human pressing a
button has no such race. **When a path is unreachable by construction from the
harness, ask whether it is reachable by a person** — the same move that got the
connect string read at 15 characters and the Reset-is-not-enough answer.

**Two errors of mine in writing this up, both caught in review, both the same
shape.** I said all thirteen notifications were identical at `0x801C` — they are
not: the first two are `0x8017` and `0x8019`, DeZog stepping the instructions
after the trap, and the truth is the stronger claim. And I said thirteen when the
frozen log has **twenty-two**. Both came from reading a `tail -5` and a snapshot
of a **live** log while the session was still running. ERRORS.md already carries
"a claim asserted from what the script does rather than what it runs"; this is
the same disease with a moving file. **Freeze the evidence before quoting it.**

**Also confirmed by the real client, on silicon:** `CMD_PAUSE` at shutdown.
DeZog's `CSpectRemote.disconnect()` sends command 7 and blocks on it, exactly as
predicted that morning from reading its minified source — so before issue #8
landed, every Shift+F5 would have hung. A fix reasoned from a code read, then
exercised by the thing it was written for.

**What the same evening cost:** two hardware wedges, each recovered only by
power-cycling — issue #15, with the anti-hang design as #16. Functionality is
complete; robustness is not, and the one unbounded wait in either transport
(`transport_wait_rx`) is where it starts.

---

## 2026-08-05 — The sprite commands answer nothing, at exactly the length asked for

**Decided (user) and built, issue #9.** `CMD_GET_SPRITES` (18) and
`CMD_GET_SPRITE_PATTERNS` (19) now answer `count*5` and `count*256` **zero
bytes**. They used to reach `cmd_not_supported`.

**It was worse than silence, which is why it outranked the other options.**
`cmd_not_supported` jumps to `drain_main`, and that re-initialises the debugger:
`prgm_state` to `PRGM_IDLE`, clock and backup state reset, `transport_activate`,
`show_ui`. So opening DeZog's sprite view hung the client **and tore the session
down underneath it** — any breakpoints or state the client believed in were
gone, silently, while it waited for ever.

**The length is not ours to choose, and that is what rules out a short "no".**
DeZog asserts `count*5 == r.length` and `r.length == 256*count` in the client
and then slices the reply into fixed-size records. A short reply is a **desync**,
not a refusal, and DZRP has no error response to send instead. So the only
question left is what to put in bytes we are obliged to send, and zeros are the
answer: a zeroed attribute has its visible bit clear, so the view renders empty
— the closest this wire format comes to "there is nothing I can show you".

**A Next genuinely cannot do better, and this time it was READ IN THE VHDL
rather than inherited.** Upstream's table said "not supported on a ZX Next" and
DeZog's `ZxNextSerialRemote` throws "The sprite attributes can't be read on a ZX
Next unfortunately"; both are hearsay by this project's own first hard rule.
Checked: ports `0x57` (attribute upload) and `0x5B` (pattern upload) have **no
read decode at all** — `zxnext.vhd:651-652` declares `port_57_wr` / `port_5b_wr`
and no read counterpart, `grep port_57_rd` is empty, and neither appears in the
port read mux (`zxnext.vhd:2803-2806`) or the data mux (`:2837-2840`). `0x303B`
*is* readable and returns the sprite **status** byte, not attributes.

**The asymmetry with an emulator is real and is not a defect.** CSpect's plugin
answers these for real because it runs in the HOST, where the sprite arrays are
ordinary variables, and jnext's own DZRP server (its issue #12) will too. Our
stub is Z80 inside the machine and is bounded by what the CPU can reach — in
jnext exactly as on silicon, because jnext models the write-only-ness
faithfully. The same DeZog session will show a populated sprite view against an
emulator and an empty one against a Next. Plan §8.4 already lists this family
among the tier no hardware target can implement; C13/C14 accept either.

**Rejected.** Closing the connection, as CSpect does for commands it refuses
(unambiguous, but it ends the debug session and DeZog must reconnect — a worse
outcome than an empty view for a *view*); reporting the error on the Next's
screen as well (it needs a report-without-drain path, since the drain is the
defect, and that is a change to the error machinery rather than to these two
commands); implementing them for real (impossible, see the VHDL above).

**Verified red first.** C13 and C14 against `main`'s ROM: *"no response within
25s: the remote is still serving, so it swallowed the command and carried on"*.
Green after, and both assert that a **second command on the same connection**
still works — the session-survival half, which is the part `cmd_not_supported`
actually broke. `prgm_state` itself is not observable over a socket, and the
checks say so rather than implying more.

**Cost: +43 bytes, and BOTH ROMs move by design** — `commands.asm` is common
code, so the UART byte-identity gate is expected to differ, as for #7, #8 and
#12. Pinned: UART `749692f4` → `9243cad6`; `main_end` 0xF1B0 → 0xF1DB. Suite
14/14.

**Still routed to `cmd_not_supported`, and still silent**: command 0 (reserved)
and everything out of range — `ADD_BREAKPOINT`/`REMOVE_BREAKPOINT` (40/41), the
watchpoints (42/43), `READ_STATE`/`WRITE_STATE` (50/51). The #8 entry called
this a class; #9 closes the two instances DeZog's `cspect` remote can actually
reach. The rest are reachable only by a client that sends them, and none does
today.

---

## 2026-08-05 — No scan may destroy an inbound frame; the transport gets one frame of memory

**Decided and measured, issue #11.** Every wait in `transport_esp.asm` skips
what it is not looking for — the property that lets it step over the module's
unsolicited lines instead of desynchronising on them — and a `+IPD` arriving
mid-scan was skipped the same way: read off the wire and thrown away. The client
was answered by nothing at all. `esp_read_scan` now **captures** such a frame
and `esp_require_payload` serves it as the next command.

**The measurement came first and it moved the target.** Three sweeps against a
real Next and one against jnext:

1. **One connection never fails**, at any delay from 0 to 250 ms, 3 trials each.
   So the standing claim that *"a single pipelining client would hit it too"* is
   **not supported** in the send-after-reply shape. The discriminator is the
   other connection, not timing alone.
2. **The window is 20-50 ms**, where a nine-character `SEND OK` costs ~2 ms at
   115200. Any timeout sized against the old reasoning would have been wrong.
3. **There is a SECOND window and jnext reproduces it 4 times out of 4.** Two
   commands queued back to back: the second frame sits in the FIFO ahead of
   `AT+CIPSEND`'s `OK\r\n> `, so `esp_wait_prompt` eats it. jnext's own esp01
   log shows both `+IPD` headers emitted and one `AT+CIPSEND` issued. **That
   retires "jnext never reproduces it"** — true of the `SEND OK` window, false
   of this one — and it is what made a red-first headless check possible at all.

**The design decision, and it breaks a stated principle on purpose.**
`esp_sync_ipd`'s comment says the payload is never buffered, "what keeps this
transport's RAM cost a constant rather than a function of the largest DZRP
command". That still holds for the normal path. The exception is **one frame,
`ESP_HOLD_MAX` = 256 bytes**, and it is the minimum that can work: the `SEND OK`
window could have been closed by holding the header alone and leaving the
payload on the wire, but the **prompt** window cannot — the prompt is still owed
*after* the frame, so reaching it means passing over the payload, and passing
over it means having somewhere to put it. Measurement (3) is what ruled the
cheap option out; without it the header-only fix would have looked complete and
shipped half a repair.

**esp_conn_id is NOT written at capture time**, and this is the subtle half. A
capture can land halfway through a response being flushed, and `esp_conn_id`
names the connection *that* response is going to. Adopting the id there would
redirect the rest of a reply to whoever spoke last — a new bug in the family the
id has already cost this project a night over. The id rides in `esp_hold_id`
and is joined to the transport only in `esp_require_payload`.

**What is deliberately still lost.** A frame longer than the buffer, or a second
one while the first is held, is read off the wire and dropped — but *framed*
correctly, where the old code consumed an unknown number of payload bytes and
could match its pattern inside them. And **a scan whose own pattern begins with
'+' cannot capture**, or it would swallow the line it is looking for: that is
`esp_sync_ipd` and `esp_query_address`'s `+CIFSR:STAIP,`. So a client connecting
inside bring-up's one `AT+CIFSR` exchange can still lose its first command,
which is issue #10 and is measured NOT to be fixed by this: 5 of 6 runs with W2's
precondition either way. **That one is closed bench-side instead** — the DZRP
bench settles 2 s after the listener appears and before any client connects,
which took the precondition to 6 of 6, and which `test/run-tx-patience.sh`
already did for the same reason (ERRORS.md). The bench declines to race the
stub; the window in bring-up is still there.

**TWO bugs of mine, both caught by running it and not by reading it, and the
second by the reviewer rather than by me.**

The second was the same *shape* as the first, one site along.
`esp_rx_from_hold` was cleared only by `esp_sync_ipd` — the wire path — so
between finishing a held command and the next chunk arriving off the wire the
buffer read as busy and `esp_capture_ipd` refused every capture. The first
collision was handled; the next one lost its command, silently, for exactly the
reason the first one no longer did. **Reproduced 11 times out of 11** with a
client that speaks while the stub is answering a held command. It is cleared in
`transport_read_byte` now, where `esp_rx_remaining` reaches zero — the only
place that count is decremented, so every path passes through it.
`transport_wait_rx` also had to learn about a held frame: it has no timeout by
design, so with a frame held and a quiet module it would have spun for ever.

**W4 could not see it, and making it able to took three measured attempts.** A
single collision never reaches the stuck state, because the next command comes
off the wire through the idle poll, which frees the buffer on the way past. Two
collisions do not either, for the same reason. What does is a client connected
in advance that speaks the moment the first reply lands — and even that needs
the *held* command to have a long answer (a five-byte `CMD_READ_MEM` returning
1 KB, five `AT+CIPSEND` chunks) or the window is a millisecond wide and the
check passes against a ROM known to be broken. It must NOT be a large loopback:
loopback echoes, so the command itself would exceed `ESP_HOLD_MAX` and be
dropped by design, failing a correct stub. Both wrong versions were run, not
imagined.

**The first bug, for the record.**
`transport_byte_available` polls through `esp_sync_ipd` **directly**, not through
`esp_require_payload`, so clearing "serving from the hold" in the latter left a
spent buffer selected and the next command was read out of already-consumed
bytes: the frame arrived, nothing was sent, the client timed out — the very
symptom being fixed, reintroduced by the fix. It is cleared in `esp_sync_ipd`
now, the one routine that makes a wire chunk current. **Two callers, one of
which bypasses the obvious place to put the state change**: worth checking for
by grep before choosing where a flag lives.

**Evidence.** Bench **W4**, shown red first against `main`'s ROM ("exactly one
of the two was answered") and green after. It asserts its own precondition from
jnext's log — two `+IPD` frames really emitted back to back — because a race that
did not race is not a test. Full suite 12/12 with W1-W4. **The UART ROM is
byte-identical to `main`'s** (`9e6bae1d`, pinned), which is what says nothing
shared moved: this file is in the WiFi build only.

**CONFIRMED ON HARDWARE the same day, and this paragraph used to say the
opposite.** The `SEND OK` window is the one a real Next measured and the one no
emulator here can reach, so until the ROM was reflashed this was a defect proven
against its *other* window and unproven on the machine that found it. Build
000A: **H3 green, 3 runs of 3** — the symmetric answer to the 3 failures of 3
that opened the issue — and the whole hardware bench green for the first time,
12 of 12 conformance included. **It costs nothing measurable**: median round trip
11.3 / 11.4 / 11.5 ms against 11.5 ms before, throughput 6.1 / 7.1 / 8.2 KB/s
against 8.3, the top of that spread matching the pre-fix figure. Measured three
times rather than once, because the first run alone showed 6.1 KB/s and a 108 ms
latency outlier that did not recur, and reporting either as a cost of the fix
would have been the reasoning-instead-of-measuring mistake this file exists for. Cost: **+485 bytes**, WiFi only —
`main_end` 0xF5CC → 0xF7B1, 1775 free to the identity block.

**Rejected.** Holding only the header and deferring the payload (measurement (3)
shows it cannot close the prompt window); a bigger buffer sized to the largest
DZRP command (that is the RAM cost the design refuses, and `CMD_WRITE_BANK` is
8-16 KB); sending the payload without waiting for `>` (the prompt is what says
the module switched to data mode, and no hardware here can test the guess);
parsing `<id>,CLOSED` to know what to expect (a second pattern in the hot path
for a case `ERROR` already covers).

---

## 2026-08-05 — The screen names the fork, the transport and the build; upstream's version leaves it

**Decided, issue #12.** The banner is now

    dezogif_ng WiFi build 0008
    DZRP v2.1.0
    Core: 03.02.03

where it read `ZX Next WiFi DeZog Interface` over `v2.2.1`. Three facts, and
the reason for each is different.

**The build number, which is the one that cost time.** It was already in the
ROM — `BUILD_NUMBER_HEX`, in the identity block at `0xFEA0` — and not on the
screen, so "did the new ROM take?" meant booting **mfselect** to read it,
repeatedly, during the 2026-08-05 hardware session, with the debugger's own
screen in front of you.

**One source, and it is structural rather than a promise.** `IDENTITY_LINE`
lives in `constants.asm` **beside `rom_magic`'s definition**, and both are
spelled from `ROM_VARIANT` and `BUILD_NUMBER_HEX`. They are emitted by the same
assembler pass, so within a build they cannot disagree; and changing one
without the other is visible in the diff. A second source for that number is
exactly the conflation issue #4 and [[ERRORS.md]] are about — there the CRC was
made to answer identity, and the guard it defeated destroyed a user's backup.

**`v2.2.1` is upstream's and leaves the screen rather than staying with a
label.** It has not moved since the fork and names nothing this project
versions. The screen answers *what is running*; the fork point is a fact about
the repository, and `NOTICE` is where it belongs. **It is still on the wire**,
as `CMD_INIT`'s `PROGRAM_NAME` (`dezogif v2.2.1`) — untouched here, because
changing that changes what DeZog displays to the user and is a separate
decision with a separate blast radius.

**Both ROMs move, and that is correct.** `data_const.asm` and `constants.asm`
are common code, so the UART byte-identity gate is *expected* to differ — the
third time this has been true on purpose, after issues #7 and #8. Pinned:
UART `b8b499be`→`240e4348`, WIFI `48cb7aea`→`00e4108a`. Each build is **11
bytes smaller**, because the line replaced is shorter than the two it replaced.

**The 32-column bound is an `ASSERT`, watched to fail** at both call sites.
The first version held it in a comment and the reviewer objected, correctly:
`rom_magic` six lines below bounds itself with an `ASSERT`, `esp_connect_address`
with two, and ERRORS.md carries three entries about bounds that nothing
checked. It costs no bytes.

**A measurement lesson worth more than the change.** The first pinned "before"
hash quoted for the WiFi ROM was wrong, because `make BUILD_TIME=… mf-rom` does
**nothing** when the output is already newer than its prerequisites — it hashed
an image built at the *unpinned* time. Delete everything **derived** before any
pinned comparison — `rm -f build/*.bin build/enNextMf*.rom`, **not** the `.rom`
files alone: the ROM is a `cat` of `main*.bin` and `mf_nmi*.bin`, whose rule
depends on the sources rather than on `BUILD_TIME`, so make will happily reuse
`.bin` files assembled at the unpinned time and hand you yesterday's answer.
`make check-reproducible` runs `make clean` first and is not affected.

*(Corrected 2026-08-06. This paragraph originally said "delete the outputs",
which is exactly what a later branch did — and it reported a WiFi ROM change on
a diff that touched no `src/` file. The output is not what make decides about;
its prerequisites are. Full incident in [[ERRORS.md]], "Deleting the ROMs is NOT
enough before a pinned hash comparison".)*

**Rejected.** Keeping `v2.2.1` with a label such as "fork of" (32 columns, and
a fork point is not a runtime fact); putting the build number on its own row
(a whole row for four characters, when six columns were free on row 0);
deriving it from `BUILD_TIME` or the git hash (`make check-reproducible` must
keep passing); changing `PROGRAM_NAME` in the same commit (out of scope, and it
is what a client shows its user).

**Noted, not fixed.** The UART build's row 3 still reads `ESP UART Baudrate:`
— upstream's wording for the joy-port cable's rate, in the build that has
nothing to do with the ESP. WiFi mode's half of that was fixed on 2026-08-05;
this half is cosmetic, in common text, and was left out of a change already
moving both ROMs.

---

## 2026-08-05 — The send waits get their own RX budget; the idle poll keeps the short one

**Decided and measured, issue #11** — the first defect in this project found on
**real hardware**, and diagnosed off the stub's own screen rather than from the
PC side.

**The symptom.** Build 0007 on a real Next: hardware bench **H3** failed 3 runs
of 3 (two connections open, both `CMD_INIT`s answered, connection 1's loopback
answered, connection 2's second exchange silent) and **H5** intermittently
truncated — once at *236 of 4097 bytes*, which is one `ESP_TX_CHUNK` of 240 less
the 4-byte length field. On the Next's screen: **`Last Error: TX Timeout`**.

**Why that text was decisive.** `esp_wait_prompt` already distinguishes the two
things `AT+CIPSEND` can produce: `ERROR` — the peer has gone, drop the message
*silently*, which is W2's fix — and *silence*, which reports TX Timeout. The
screen said silence. So the module answered neither `>` nor `ERROR` inside the
read budget, which after `transport_init`'s `.done` is **one** pass of
`ESP_RX_WAIT`, about 100 ms at 28 MHz.

**The other producer of that same screen text was excluded from the VHDL, not by
preference.** `esp_send_raw`'s TX-FIFO wait also reports `ERROR_TX_TIMEOUT`, so
the screen alone cannot tell them apart. `uart_tx.vhd:180` starts a frame on
`i_Tx_en = '1' and (i_cts_n = '0' or i_frame(5) = '0')`; bit 5 of the frame
register is the hardware-flow-control enable and `esp_uart_init` writes
`00011000b`, so CTS is ignored and the shifter is never held off. Its 8.5 ms is
~98 byte times at 115200 and cannot plausibly expire. **That also takes the
plan's open question 4 — is CTS/RTR populated on this board? — off this path
entirely**, since nothing in it consults CTS.

**The decision, and the constraint that shaped it.** The obvious fix — raise
`esp_rx_retries` globally — is wrong, and the reason is already written down in
this file: `transport_byte_available`, `main_loop`'s idle poll, reads through
the same `esp_try_read_raw`, and its documented worst case is a **~100 ms stall**
when the module puts an unsolicited line on the wire. A global 5-10× would make
that stall 0.5-1 s and buy a visibly sluggish debugger with the fix. So the
budget is raised around **exactly two calls** — `esp_wait_prompt` for the `>`,
and the `esp_wait_string` for `SEND OK` — and lowered immediately after. Those
are the only reads in this transport where the module *owes* an answer to
something already asked; bring-up is the other such window and already had its
own budget, which is the shape this follows.

**The value is a judgement call and is labelled as one in the source.**
`ESP_TX_PASSES = 10`, ~1 s. Nothing we trust documents a real ESP-01's
`AT+CIPSEND` latency under load, and **no bench here can measure it**. What
hardware established is the negative: 100 ms is too short. Ten passes is an
order of magnitude past that, past one retransmit inside the module's own TCP
stack, and short enough that a dead module still reports within a second rather
than reading as a hang. Deliberately *smaller* than bring-up's 20, because
unlike bring-up this can be paid once per chunk. Cost when the module answers
`SEND FAIL`: that report arrives 1 s late instead of 100 ms.

**Exception safety, which is where a scoped budget usually goes wrong.** The
pairs are tight: the only routines called with the budget raised are
`esp_wait_prompt` and `esp_wait_string`, and both always *return* — the sends
either side of them, which can divert to `tx_timeout`, run at the short budget.
The one arm that still leaves from inside is `esp_try_read_raw`'s RX overflow,
which jumps straight to `rxtx_error`, so **`rxtx_error` lowers the budget
itself**. That closes a pre-existing hole of the same shape: an overflow during
bring-up never reached `transport_init`'s `.done`, and left `ESP_INIT_PASSES` in
place for the rest of the power-on session.

**Proved by injection, because the emulator can never reach it otherwise.** New
bench `make test-tx-patience`, 3 runs. `ESP_RX_WAIT` and `ESP_TX_PASSES` become
overridable — the same seam and the same justification as `ESP_IP_MAX` — so one
pass can be shrunk to below jnext's own `AT+CIPSEND` answer latency. **P1** the
shipped `TX_PASSES=10` against that injected slow module completes; **P2** the
pre-fix `TX_PASSES=1` loses a reply and paints **824 bright-red pixels**, the
same count W2 measured pre-fix, i.e. `Last Error: TX Timeout` — the hardware
symptom reproduced; **P3** the same `TX_PASSES=1` build at the shipped
`ESP_RX_WAIT` completes, so P2's red is the injected budget and not
`TX_PASSES=1` by itself. P1 and P2 differ **only** in `TX_PASSES`, which is what
makes the lost reply attributable to one of the two scoped waits.

**Rejected.** Raising `esp_rx_retries` globally (the idle-poll regression above,
traded for the fix); parsing `SEND FAIL` as a distinct outcome (it would still
need a budget to be seen inside, and the two-pattern `esp_wait_prompt` shape
already covers the case that matters); a belt-and-braces restore at every exit
of `esp_flush_chunk` *instead of* at `rxtx_error` (it would not cover the
overflow arm, which is the only real escape); raising `ESP_TX_WAIT` as well —
the VHDL says it cannot be the fault.

**NOT VERIFIED, and no emulator run can verify it.** jnext answers instantly, so
the shipped build's timeout path is never taken there: every suite is green
before and after, and they prove only that nothing broke. `ESP_TX_PASSES = 10`
is reasoned. **H3 and H5 on a real Next, several times, plus the screen, are the
only things that can settle it.**

---

## 2026-08-05 — `CMD_PAUSE` is acknowledged and nothing more; the suite is 12/12

**Decided and measured, issue #8** — the last open issue, and the one that turns
`make test-dzrp-stub` fully green: **W1/W2/W3 pass and 12 passed / 0 failed of
12, exit 0.** Every check this project's strongest gate has is now green against
our own stub in the emulator.

**The defect.** `commands.asm`'s jump table routed command 7 to
`cmd_not_supported`, which stores an error and jumps to `drain_main`: the frame
was consumed, the stub repainted, and **nothing was sent**. The DZRP
specification gives `CMD_PAUSE` a Length=1 response — the sequence number alone
— with no exemption for a remote that is already stopped, so a client waited
forever. Pre-existing: `git blame` dates that entry to upstream's own 2023
commit, so both builds had always done it.

**The decision worth recording is what the handler does NOT do.** `cmd_pause` is
six bytes — `ld de,1` / `jp send_length_and_seqno` — and acknowledging is the
whole of it. Three reasons, and the second is the one that would have caused a
real regression:

1. **There is nothing to pause.** The handler is reachable only from `cmd_loop`,
   which runs only while the debugger is stopped, so the command cannot arrive
   in any other state.
2. **Writing `prgm_state` would break `cmd_continue`.** A client may legitimately
   send `CMD_PAUSE` before the first `CMD_CONTINUE` — conformance check C12 does
   exactly that — so it can arrive while `prgm_state` is `PRGM_LOADING`.

   An earlier version of this entry said *"DeZog sends `CMD_PAUSE` right after
   `CMD_INIT`"*, which the reviewer could not substantiate: tracing DeZog 3.7.4
   found no automatic path, only the UI Pause button, the debug console, a
   unit-test timeout and `CSpectRemote.disconnect()`. The narrower claim is the
   one that holds and the one the fix actually rests on — and the conclusion is
   unchanged either way, since not writing `prgm_state` is right regardless of
   which client sends it when. Recorded because a reason that turns out to be
   unsupported is worth more as a correction than as a quiet deletion.

   Overwriting that with
   `PRGM_STOPPED` — the obvious "mark ourselves stopped" move — makes the next
   `cmd_continue` skip its `cp PRGM_LOADING` branch, so the border colour is
   never restored and the flashing border is never disabled. The correct side
   effect is **none**.
3. **No `NTF_PAUSE`.** That notification reports a *transition* into the stopped
   state, and no transition happens here; DeZog is not awaiting one, and
   `send_ntf_pause` would set `PRGM_STOPPED` anyway, i.e. reason 2 again.

**CSpect agrees, and it was checked rather than assumed.** Its plugin's
`Pause()` stops the CPU and calls `SendResponse()` with no data; the
notification is emitted later by `CheckIfBreakpointHit()` and only when the
state actually changed. Same division: the response acknowledges, the
notification reports a transition.

**Why upstream never saw this, which is the transferable part.** DeZog's
`ZxNextSerialRemote` overrides `sendDzrpCmdPause()` to throw *"To pause
execution use the yellow NMI button of the ZX Next"* — over the serial remote,
command 7 never reaches the wire, so upstream's silent handler could not be
observed by upstream's only client. WiFi mode is driven by the `cspect` remote
(plan §7), which has **no such override** and inherits `DzrpRemote`'s
`await this.sendDzrpCmd(7)`: it sends the command and blocks. Verified in the
installed DeZog 3.7.4 by locating both classes' bodies in `out/extension.js`.
**Adopting a new client re-exposes defects the old client hid**, and this is the
second one this project has met — issue #7's `cmd_init` was the first.

**Scope, stated because it is the thing most likely to be over-read.** This is
**not** PC-initiated break. Breaking into a *freely running* debuggee is M2:
`nmi66h` serves button NMIs only and bench T4 asserts that decline deliberately.
`nmi66h` was not touched, no poll was added, and the Copper was not gone near.

**Cost and the gate.** Exactly **+6 bytes** in each build (`main_end` UART
0xF1B5→0xF1BB, WiFi 0xF5B0→0xF5B6), leaving 3301 and 2282 bytes to the identity
block. **Both ROMs moved, which is correct for common code**: UART
`a9d1de1c…`→`14ea485e…`, WiFi `f5a88f18…`→`e0e2d8fb…` with `BUILD_TIME` and
`BUILD_NUMBER` pinned. The byte-identity gate is *expected* to break here, as it
did for issue #7, and the merge carries a `make bump`.

**`test/hardware-check.py`'s `KNOWN_RED` is now empty again**, and that is a
result rather than housekeeping: with the emulator bench at 12/12 there is no
known-red left for a bench-top failure to hide behind, so **any red on a real
Next is a hardware finding by construction.**

**Rejected.** Sending an `NTF_PAUSE` as well (no transition to report; CSpect
does not); setting `prgm_state` (reason 2 above — actively harmful); folding
`cmd_pause` into `cmd_set_register`'s identical `ld de,1` / `jp
send_length_and_seqno` tail to save three bytes (a false economy that couples
two unrelated handlers, with ~3.3 KB free); and draining
`receive_buffer.length` the way issue #7 taught `cmd_init` to — `CMD_PAUSE` is
specified Length=0, and every other zero-payload handler here (`cmd_close`,
`cmd_get_registers`) ignores the field, so inventing a different rule for this
one would be the inconsistency, not the fix.

**Noted, not fixed — `cmd_not_supported` is a class, and #8 was one instance.**
Three jump-table entries still route there (0 reserved, 18 `CMD_GET_SPRITES`,
19 `CMD_GET_SPRITE_PATTERNS`), as does every out-of-range command including
`ADD_BREAKPOINT`/`REMOVE_BREAKPOINT` (40/41), the watchpoints (42/43) and
`READ_STATE`/`WRITE_STATE` (50/51). **All of them are silent in exactly the same
way**, and DZRP has no generic error response to send instead.

**18 and 19 are not theoretical — they are #8 again, verified in the same
place.** `ZxNextSerialRemote` throws locally on both ("The sprite attributes
can't be read on a ZX Next unfortunately"), so upstream is protected exactly as
it was for `CMD_PAUSE`. `CSpectRemote` overrides neither, and inherits
`sendDzrpCmdGetSprites` → `await this.sendDzrpCmd(18,…)` and
`sendDzrpCmdGetSpritePatterns` → `await this.sendDzrpCmd(19,…)`. So opening
DeZog's sprite view against our WiFi build will hang the client on a command the
stub silently swallows — the identical mechanism, the identical cause, and
already reachable. **Deliberately not fixed here** (this change is scoped to
issue #8) and it should get its own issue; the fix is not another
`ld de,1`, because both commands have real payload-bearing responses and
"refuse audibly" has to be designed rather than copied.

---

## 2026-08-05 — The stub resumes a debuggee. Measured, and controlled twice

**Measured, not decided**, and it is the largest claim this project has ever
been able to make. `make test-dzrp-stub` checks **C10** and **C11** (issue #2's
remaining half): a fixture is written into the debuggee's memory over DZRP, its
`PC`/`SP`/`BC`/`IX` are set with `CMD_SET_REGISTER`, `CMD_CONTINUE` carries a
temporary breakpoint — **and the debuggee runs**, writes its marker, stops on
the breakpoint, and the `NTF_PAUSE` names that address. Registers come back as
the program left them.

**Before this, nothing anywhere had ever shown the stub resuming anything.**
Not in the emulator, and not on the Next it had just run on for the first time
(the entry below): that press painted a UI and stopped there. So
`restore_registers`, `exit_code_di`,
the stack fix-up in `backup.asm` and the AltROM patch were code no test had
executed — see the T6 scope limit further down, which said exactly that and
is now partly retired.

**What the evidence is arranged to exclude, because "the debuggee ran" is easy
to fake.** The fixture's first two instructions store `BC` and `IX` **to
memory**, so what is read back is what the *running program* held rather than
what the debugger remembers being told. A byte written only by the instruction
*after* the breakpoint must stay zero, separating "stopped on it" from "ran
past it". And the marker area is cleared and read back before the run, because
a stale byte from an earlier check would let the whole thing pass without the
debuggee running at all.

**Two negative controls, and the second is the one that matters.**

1. Bench check **W3**: the identical run with only the `CMD_CONTINUE`
   withheld (`--no-continue`). C10 goes red. That proves the check is not
   vacuous — the T3-for-T4 shape this project already uses.
2. A ROM built with `cmd_continue`'s `jp restore_registers` replaced by `ret`,
   so the stub **answers** `CMD_CONTINUE` and never resumes. C10 *and* C11 go
   red against it. This is the failure mode that matters, and (1) alone would
   not have proved it was caught: a stub that acknowledges a resume it did not
   perform is exactly what a green check must not tolerate. Scratch build, not
   committed; ERRORS.md's "a fix never tested by removing it is a correlation"
   applied to a check instead of a fix.

**A consequence worth stating separately: the AltROM is now exercised.** The
breakpoint is an `RST 0`, and an `RST 0` reaches the debugger only through the
code `copy_altrom` installs at 0x0000/0x0066 in the Alt ROM. Plan §8.3 listed
AltROM as one of two things T6 left unanswered.

**The other of those two is NOT closed, and the distinction is narrow enough
to lose.** C10 sets `PC` itself, so `backup.pc` never comes from
`save_nmi_return_address` — the routine that reads the stackless-NMI return
address out of NR `0xC2`/`0xC3`. That runs only on an M1 press taken while
`prgm_state` is `PRGM_RUNNING`, i.e. a **second** NMI landing after a
`CMD_CONTINUE`. `--delayed-nmi` counts emulated frames while the client counts
wall clock, and the emulator's frame rate collapses under DZRP traffic, so
scheduling one is a race and not a check. **Deliberately not built**, rather
than built flaky. The M1 button breaking a *running* debuggee is unproven for
the same reason.

**A second finding, and it is a real conformance failure: `CMD_PAUSE` is not
answered at all.** Check **C12**. `commands.asm`'s jump table maps command 7 to
`cmd_not_supported`, which stores an error and jumps to `drain_main`; the frame
is consumed, the stub repaints, and **nothing is sent**. The specification
gives `CMD_PAUSE` a Length=1 response with no exemption for a stopped remote,
so a client waits forever. Measured, then confirmed alive on a second
connection, so "silent" is not reported as "dead".

Kept in proportion: it is **pre-existing**. The `cmd_jump_table` entry for
command 7 is upstream's, untouched by the WiFi work and untouched by issue #7's
`cmd_init` fix; this branch changes no `src/` file at all. And DeZog offers
Pause only while the program
runs — which is the state in which the command cannot arrive at all, because
PC-initiated break is M2 and `nmi66h` serves button causes only. **Fixing it
changes the serial ROM, so it belongs on its own branch**, exactly as C2 did
before issue #7. It is
still worse than CSpect's refusal, which at least closes the connection.

**Rejected: writing a check for `CMD_PAUSE` against a running debuggee.** It
cannot pass before M2 and is not a test but a placeholder. What C12 asserts
instead is the part that is answerable today, with its scope written into the
check's own docstring so nobody reads it as async break.

**Also rejected: reporting C12's silence as UNSUPPORTED.** The suite's
UNSUPPORTED is for a *deliberate refusal* — CSpect closes the connection —
which is a legitimate partial remote. Silence is not a refusal; it is a hang.
Grading it green-adjacent would have hidden the finding.

**Renumbered on rebase.** These landed as C9/C10/C11 and became C10/C11/C12
when issue #7 merged first and took C9 for its own check. Two meanings for
one identifier is the kind of thing that survives into a report and misleads
someone a month later.

**Measured on the combined tree, 2026-08-05, after rebasing onto build 0006**
(which carries issue #7, the WiFi UI and the `esp_conn_valid` change):
`make test-dzrp-stub` = **W1/W2/W3 pass, 11 passed / 1 failed of 12**. C2 is
green, main's C9 is green, C10 and C11 are green, C12 is the only red.

**That flips the target's exit code from 0 to 1, and the trade is deliberate.**
`main` had just reached 9/9. C12 does not break anything — the stub's
`CMD_PAUSE` behaviour is unchanged and always was silent — but a suite that
reports it honestly cannot exit 0. **Rejected: dropping C12 to keep the gate
green.** That is weakening a check to make it pass, which is the one thing this
project's testing culture refuses; C2 lived as a standing red for the same
reason until issue #7 fixed it. The alternative, if the green gate is judged
worth more tonight, is a one-line removal of C12's entry from `CHECKS` — the
check code stays and moves to the branch that fixes `CMD_PAUSE`, which is the
fix-and-check-together shape issue #7 itself used.

---

## 2026-08-05 — WiFi mode draws its own screen, and the old one was wrong

**Built, and the trigger was the 2026-08-04 hardware run recorded below.** The user
pressed NMI on a real Next with the **WiFi** ROM installed and got a screen
about UART baud rates and joystick ports. M1's last open item is closed:
`show_ui` is now the third thing the assembly-time switch selects, after the
byte stream and the lifecycle.

**This was a correctness fix, not cosmetics, and that is the part worth
keeping.** `data_const.asm` rendered `BAUDRATE` — the joy-port cable's 921600 —
unconditionally, while `transport_esp.asm` builds its prescaler table from
`ESP_BAUDRATE` (115200). So the WiFi ROM **stated a rate its own hardware was
not running at**, in the first place anyone looks when the ESP misbehaves. It
also drew a selector for a port that build never touches, and — because the two
builds shared every byte of that screen — a machine could not tell you which
ROM was installed. That ambiguity cost real time on the hardware run.

**What it draws now**, replacing exactly the two things MEMORY.md 2026-08-04
listed and nothing else:

    ZX Next WiFi DeZog Interface        <- "WiFi" where UART says "UART"
    v2.2.1 (DZRP v2.0.0)
    Core: 03.02.03                      <- unchanged, and CHECKED not shown
    ESP Baudrate: 115200                <- was "ESP UART Baudrate: 921600"
    Video timing: 0

    Remote debugger active.             <- was "Using Joy 2 (right)"
    Connect at 192.168.1.50:11000

    Keys:                               <- three lines shorter: no 1/2/3
    R = Reset
    B = Border on

**Two lines, not MEMORY.md's one, and the colon is gone.** The decided sketch
was `dezogif_ng remote debugger active. Connect at: <ip>:11000` — 64 characters
on a 32-column screen. `Connect at ` is eleven columns and the longest possible
tail, `255.255.255.255:11000`, is twenty-one: the line ends **exactly** at
column 32, with no room for a thirty-third character. That entry left wording
and layout explicitly undecided, which is the latitude taken.

**`AT+CIFSR` is asked once, during bring-up, not from `show_ui`.** `show_ui` is
re-entered on every redraw — the "B" key, `CMD_CLOSE`, an error report — so an
AT round trip per redraw would be paid for an answer that cannot have changed
while we hold the module. It is also the **last** step of `transport_init`, on
purpose: it is the only one whose failure still leaves a working listener.

**Three states, and a failure replaces the whole block rather than half of
it.** `esp_link_state` is `OK` / `NO_ADDRESS` / `FAILED`, and all three
alternatives are two lines, so nothing can leave `Connect at` standing over a
blank — the half-built line is precisely the failure this had to not produce.
`NO_ADDRESS` also raises `ERROR_NO_WIFI_ADDRESS` into the red error area, so
the fault is in both the place that explains it and the place users are trained
to look.

**`0.x.x.x` is rejected as an address.** An unassociated module reports
`0.0.0.0`; the whole of `0.0.0.0/8` is "this network" and can never be a host
address, so two characters settle it without a string compare. Drawing
`Connect at 0.0.0.0:11000` would have been the connect string with nothing
behind it that doc/WIFI-SETUP.md promises not to show.

**`FAILED` deliberately does not distinguish silence from a refused command.**
Telling them apart requires the module to have said something, which in the
silent case it has not; and from the screen's point of view they are one
situation with one first move ("check it is fitted and enabled"). So the text
says setup failed, not that the module is absent.

**`ESP_BAUDRATE` and `ESP_SERVER_PORT` moved to `constants.asm`.** Not tidying:
`data_const.asm` holds the on-screen text and is included **before**
`transport.asm`, so a `STRINGIFY` there cannot see a value defined inside the
transport implementation. Putting them beside `BAUDRATE` also puts the two
rates next to each other, which is where the confusion they caused belongs.

**The gate held.** With `BUILD_TIME` and the build number pinned the UART ROM
hashes `13217f12…`, identical to `main`'s, across a change that touched
`main.asm`, `ui.asm`, `data_const.asm` and `constants.asm` — four files of
common code. The mechanism is `IF ROM_VARIANT == …` in the UI files rather than
a macro: `data_const.asm` is assembled before the transport, so a macro from
the implementation is not available to it, and one mechanism used everywhere
beats two. The rule those files are NOT bound by is the one naming
`commands.asm`, `message.asm` and `breakpoints.asm`; the UI is exactly what
MEMORY.md 2026-08-04 says *should* differ per mode.

**Rejected.** A shared layout with the mode-specific rows blanked (a screen
with holes where its content should be reads as a broken debugger); factoring
the common lines into one prologue with two tails (thirty bytes of text, against
putting the UART byte-identity gate at risk); querying `AT+CIFSR` from
`show_ui`; a distinct error code for bring-up failure (`RX Timeout` is what it
is, and the status block now says which step in words).

**A LENGTH BOUND IS A THING NO BENCH HERE COULD REACH, and the first version
got it wrong.** The copy out of `AT+CIFSR` bounded DJNZ **passes** rather than
characters **stored**, so an address of exactly `ESP_IP_MAX` characters spent
its last pass on its last character and the closing quote was never read: the
address was refused as too long and the screen said `No WiFi address` on a
working machine. `192.168.100.136` — the user's own Next — is fifteen
characters, so this was ordinary, not a contrived maximum. Caught by the
independent reviewer, not by the author and not by any test.

**Why no test could have caught it, and what was done about that.** jnext
answers `AT+CIFSR` with `192.168.1.50`: a `static constexpr` with no option
behind it, twelve characters, which never reaches a bound of fifteen. The
boundary was **unreachable by construction**. So the decision — and it is the
reusable one — is to **move the bound instead of the input**: `ESP_IP_MAX` is
`IFNDEF`-guarded, the Makefile's `IP_MAX` overrides it into its own ROM name,
and `make test-ip-boundary` builds one ROM where jnext's own answer is exactly
at the bound and one where it is one over. Real Z80, real emulator, real
`AT+CIFSR` reply; one constant different. **Rejected: a host-side model of the
loop** — it would have tested a transcription of the code rather than the code,
and ERRORS.md already carries an entry about exactly that substitution.

Three sums previously done in comments are now assembler `ASSERT`s, each
watched to fail when violated. See [[ERRORS.md]], where this is filed as the
third occurrence of one shape.

**Not verified, and it is the same gap as everything else here.** The address
has **never been read off real hardware**. jnext's module is permanently
associated and always answers `192.168.1.50`, so what the bench proves is the
*mechanism* — `AT+CIFSR` sent, `+CIFSR:STAIP,"…"` parsed, the line composed and
drawn — and never the *value*. `doc/HARDWARE-TESTING.md` observation S4 is
where that gets closed. The **maximum-length line has also never been
rendered**: no bound setting makes jnext produce a 15-character address, so the
32-column worst case is held by a compile-time `ASSERT` rather than by a
picture.

---

## 2026-08-05 — No ESP connection id is reserved: validity is state, the id is data

**Decided (user), after the bug below was found on real hardware.** The rule is
now absolute and it is stronger than the fix that was first proposed: **no value
of an ESP connection id is special.** Not 0, not 0xFF, not 1. The id is opaque —
read it from the `+IPD` header, echo it back on `AT+CIPSEND`, and encode nothing
anywhere about its range, its first value or how the module allocates it.
"Is there a client" is tracked separately, in `esp_conn_valid`.

**What went wrong, and it is the exact failure MEMORY.md had already warned
about.** The entry below ("jnext's ESP server: inbound connection ids start at
1, not 0") recorded that jnext reserves slot 0 for the guest's own outbound
`AT+CIPSTART`, and said in as many words that this is a **jnext design choice**
which "must not be promoted to a hardware fact without measuring it". It was
promoted anyway — not in the parser, which correctly reads the id, but in
`transport_flush`, which used `esp_conn_id == 0` as the marker for "there is
nobody to send to".

**Real ESP-AT firmware assigns link id 0 to the first inbound connection.**
Measured on the user's Next, 2026-08-04 night: the listener came up (hardware
bench H1 passed, 295 ms), the client connected, commands were consumed and
executed — and **every reply was silently discarded**, because a perfectly valid
id read as "no client". No error, no data; every DZRP check timed out with
`timed out after 0 of 1 bytes`. The WiFi debugger was completely unusable on
real hardware.

**Rejected: `0xFF` as the sentinel instead.** It was the obvious minimal fix —
ESP-AT ids are 0-4, so 0xFF cannot collide, and it costs no extra state. The
user rejected it, and the reasoning is the part worth keeping: **the defect was
the reservation itself, not the value chosen.** Swapping one reserved value for
another repeats the mistake in a place that merely happens not to hurt today,
and leaves the next reader believing a reserved id is a legitimate design. Two
variables cost 6 bytes and remove the class of bug rather than one instance of
it.

**Also rejected: keeping them in one byte** by any encoding (id+1, a high bit).
Every such scheme is a reservation wearing a disguise, and the collision comes
back the moment the module's numbering changes again.

**The shape of the fix.** `esp_conn_id` holds whatever the header said and means
nothing else; `esp_conn_valid` is non-zero when there is somewhere to send.
`esp_sync_ipd` writes both, together, and is the only place that sets either.
`.no_client` — the path taken when `AT+CIPSEND` answers `ERROR`, i.e. the peer
has gone — **clears the flag and leaves the dead id alone**, because writing
some other value into it would be reserving one again. Bench check W2, which
exists because a stale id used to make the M1 button silently stop working after
the first disconnect, still passes.

**Cost:** 6 bytes in the WiFi ROM (`main_end` 0xF505 → 0xF50B, 2453 still free).
The UART ROM is byte-identical — `transport_esp.asm` is in the WiFi build only,
and that asymmetry is the evidence that nothing shared was touched.

**THE EMULATOR CANNOT CONFIRM THIS FIX, and that is a permanent property of it,
not a gap to close.** jnext never hands out id 0, so `make test-dzrp-stub` is
green *before and after*. There is no red-to-green transition to point at, and
anyone who adds a check claiming otherwise has misunderstood what the bench can
see.

**What the emulator CAN show is the mechanism, and it was measured rather than
argued** — by forcing the parsed id to 0 in a throwaway tree, i.e. simulating
hardware numbering under jnext, one variable at a time:

| tree | commands arrived (`+IPD` framed) | `AT+CIPSEND` issued |
|---|---|---|
| `main`'s code + forced id 0 | 18 | **0** — every reply dropped at `transport_flush` |
| fixed code + forced id 0 | 16 | **8**, as `AT+CIPSEND=0,25` |

So the hardware symptom reproduces exactly under jnext once the id is forced,
and the fix demonstrably carries a zero id through to the wire. jnext then
refuses cid 0 (it is jnext's outbound slot), which is why the DZRP checks still
fail in that control and why it can never be a committed test. It also proves
`esp_put_decimal` emits `"0"` correctly — a path no bench had ever executed,
since every id jnext issues is 1 or 2.

**Confirmation is a hardware run**, and only that: `make test-hardware
NEXT_IP=<ip>`, expecting H1 to pass as before and the DZRP checks that timed out
to go green.

---

## 2026-08-04 — FIRST RUN ON REAL HARDWARE: the stub comes up on a Next

**Measured, not decided.** A real ZX Spectrum Next, our WiFi ROM installed by
mfselect, M1 button pressed: **the stub takes over and paints its UI.** Core
reported **03.02.01**, above the 03.01.10 stackless NMI needs, so the version
check passed. The error area was clear.

Everything this project had ever produced ran in jnext. This is the first
evidence that any of it works on silicon, and it lands three separate results
at once:

1. **The stub runs.** Multiface paging, the relocation of `MAIN` into a RAM
   bank at slot 7, `show_ui` and the core-version check all work on real
   hardware, not just in the emulator. It also answers plan open question 2 —
   tbblue does **not** checksum `enNextMf.rom`, because ours booted.
2. **mfselect runs, on its first ever hardware outing**, and did the whole job:
   identified the installed ROM as not-ours, captured it as `original.rom`
   (**CRC 6320**), installed the WiFi build, read it back and verified it
   (**B5C6**).
3. **The stock Multiface ROM's CRC is 6320 on real hardware — the same value
   bench check M2 reports in the emulator.** So jnext's reference SD image
   carries the authentic Multiface ROM, and mfselect's on-Next CRC16 agrees
   with `tools/romsum.py` on silicon as well as under emulation. Neither was
   certain before; both were assumed.

**What this run does NOT establish, and the reason is a UI gap rather than a
doubt about the stub.** The screen **cannot tell you which build is running**.
The connect-string UI is M1's last unbuilt item, so the WiFi build still draws
upstream's UART screen — byte for byte the same screen the UART build draws.
Whether the ESP came up and is listening is therefore **not visible**, and an
observer's "it looks like it started listening" is an inference from the
absence of an error, not evidence. `make test-hardware NEXT_IP=<ip>` (check H1)
is what settles it.

**And the screen states a baud rate that is wrong for the build it is running.**
`data_const.asm` draws `BAUDRATE` unconditionally, which is upstream's joy-port
921600, while the WiFi build's UART is set from `transport_esp.asm`'s own
`ESP_BAUDRATE` = 115200 with its own prescaler table. So a WiFi ROM reports
"ESP UART Baudrate: 921600" while running the ESP at 115200. Not a functional
defect — the peripheral really is at 115200 — but the screen lies, in exactly
the place somebody would look first when the ESP misbehaves. It makes the
connect-string UI a correctness fix, not only a nicety.
---

## 2026-08-04 — the frame's length decides where a command ends, not its content

**Decided, issue #7.** `cmd_init.inner` consumes exactly the number of payload
bytes the frame declared. It used to read three version bytes by count and then
the remote's program name **until a NUL**, ignoring the length field entirely,
so a `CMD_INIT` whose length disagreed with its payload left the stream
desynchronised — silently, and for the rest of the session.

**The rule, stated once so it does not have to be re-derived per command.** The
length field is framing; the NUL is content. Content may tell a handler how to
*interpret* what it read, and must never decide how much leaves the stream.
Every other handler in `commands.asm` already worked that way —
`cmd_loopback`, `cmd_write_mem`, `cmd_restore_mem`, `cmd_write_bank`,
`cmd_exec_asm` all take their count from `receive_buffer.length` — so this was
the one place that did not, not a new policy.

**The bytes are read and dropped, and that is deliberate.** The response is
built from our own `DZRP_VERSION` and `PROGRAM_NAME`, so nothing above ever
looked at the remote's version or name; upstream stored the three version bytes
and no code has ever read them. Storing a client-chosen count into the 102-byte
payload buffer would need a bound check that buys nothing. Net effect on the
image: **one byte smaller** (`main_end` 0xF1B6 → 0xF1B5).

**Every hostile boundary the issue named falls out of that one rule, with no
special case for any of them** — which is the argument for the rule rather than
for a validator: a name filling the frame with no NUL (only the declared bytes
are taken; what follows is the client's next frame by definition); a length
below 3 (fewer than three bytes are read, so there is no over-read waiting for
version bytes nobody promised); a length of 0 (nothing is read); a length longer
than what was sent (the read blocks, and the transport's own RX timeout resets
the call stack, drains and reports — the recovery every other over-declared
command already gets).

**Rejected: rejecting the frame with an error.** DZRP has no framing-error
response, so "reject" could only mean an error code in a *response* — which is
itself a frame, sent onto a stream whose position we would be admitting we do
not know. Consuming the declared count is the only answer that keeps the two
ends agreeing about where the next command starts. Also rejected: keeping the
version bytes with a bounded copy (a `min()` and a second loop for data nothing
reads); validating that the name is NUL-terminated inside the frame (bytes for a
case DeZog never produces, and the length already makes it harmless).

**THIS CHANGED THE SERIAL ROM'S BYTES, ON PURPOSE, AND IT IS THE FIRST CHANGE
HERE THAT SHOULD.** `src/commands.asm` is common code, so the UART byte-identity
gate — this project's standing proof that a refactor changed no behaviour — is
*expected* to differ, and a merge that preserved it would have meant the fix did
not reach the serial build. With `BUILD_TIME=1700000000` and `BUILD_NUMBER=3`
pinned: UART `13217f12…` → `dc21bcbb…`, WiFi `d144ccb2…` → `62dbedb0…`. The
diff was checked against the symbol tables rather than eyeballed: 412 labels
before and after, none added or removed, everything below `cmd_init.inner`
identical, `cmd_init.read_loop` −5 and every label after `cmd_init` −1.

**C9 exists because C2 can only see half of this**, and the half it cannot see
is the one that desynchronises a *well-formed* session. C2 over-declares the
length and requires silence, so it proves the remote reads **at least** as far
as it was promised; it would stay green for a fix that read too little. C9 sends
an honest length whose payload carries four bytes past the name's NUL and then a
second ordinary `CMD_INIT` behind it: a remote that frames on the NUL leaves
those four bytes to be read as the next command's header. **Shown failing
first**, against the pre-fix WiFi ROM: C9 red with `timed out after 0 of 1
bytes` — the stub had answered the padded frame and then never answered
anything again. Post-fix, `make test-dzrp-stub` is **9 passed, 0 failed, 0
unsupported of 9**, with W1 and W2 still green.

**The issue's own acceptance criteria contradict each other**, and this is the
reading taken: it asks for 8 passed *and* for a new check that a well-formed
`CMD_INIT` still works. Those cannot both be true. C1 already sends a
well-formed `CMD_INIT`, so the literal request would have been the "strictly
weaker duplicate" a reviewer rejected from C2 once already; C9 is the same
intent in the only form that can fail for a reason C1 cannot.

---

## 2026-08-04 — mfselect offers three ROMs; the card carries both of ours

**Decided, issue #5.** mfselect's menu is now four entries — the stock
Multiface ROM, our **WiFi** build, our **UART** build, Exit — and both of our
ROMs live on the card as `dezowifi.rom`/`.sum` and `dezouart.rom`/`.sum`,
8.3-safe, replacing the single `dezogif.rom`/`.sum` pair.

**The UART build is not a legacy leftover**, which is the whole justification:
one ESP, one user of it, so a debuggee that owns the ESP cannot be debugged
over WiFi and the serial ROM is the plan's stated answer to that (§10,
"this is the reason the UART build is kept"). Buildable-but-not-installable
sent exactly those users back to swapping files on a card in a PC, which is
what mfselect exists to remove.

**`make mfselect` builds BOTH, in one command.** It recurses once per variant
with a single captured `BUILD_TIME`, so the five files a card needs are always
a coherent set. Every other target here builds exactly one variant on purpose —
the two ROM paths are deliberately separate so `make TRANSPORT=wifi` cannot
leave a WiFi ROM where `make test` reads one — and mfselect is the one consumer
that genuinely needs both regardless of how it was invoked. A two-command
ritual would have shipped one ROM with the other's checksum eventually.

**Nothing had to be invented to tell the two apart**: issue #4's magic string
already answered it, and `installed_name()` already returned "dezogif_ng UART"
/ "dezogif_ng WiFi". What was missing was a second ROM to install. That is the
payoff #4 was written for, and it is worth noting that the *guard* keys off the
**prefix** alone, so it protects both variants — and will protect a third
transport written by someone who never touches mfselect.

**Three bench checks, and each was seen to fail before it was believed.**

- **M7** — the first-run guard refuses our **UART** ROM as well as our WiFi one.
  Not M4 with a different file: a guard that recognised only the variant it was
  written against would destroy the stock ROM for exactly the users who chose
  the other transport. Control: guard changed to `id == ID_WIFI`; **M4 passed,
  M7 failed with the UART ROM captured as `original.rom`.**
- **M8** — the fourth menu entry reaches the file it names, two Downs from the
  top. Control: the UART entry pointed at the WiFi pair — the copy-paste bug —
  and **M3 passed while M8 failed**, naming the wrong CRC.
- **M9** — mfselect names the installed variant **correctly** on screen, which
  no file on the card can show. **This one was got wrong first, rejected in
  review, and rebuilt; see below.**
- **M10** — and nothing else on that row differs between the two runs.

**M9's first version was REJECTED, and the correction is the useful part of
this entry.** It compared the two runs *against each other*: WiFi installed vs
UART installed, and the status rows had to differ in exactly the four columns of
the transport name. The control I ran was `installed_name()` returning **one**
string for both variants, which failed it with an empty differing-column set —
and I reported that as evidence the check discriminated. It does not. The
reviewer **swapped** the two return strings, so each variant reported the
other's name, rebuilt, and the bench passed **9/9 with M9 green**: two labels
exchanged still differ in exactly those columns.

The degenerate control probed only the case where the labels **collapse**, and
passing that says nothing about the case where they **cross**. Nothing else on
the bench covers it either — M3 and M8 assert on the bytes of the installed
file, which say nothing about what the screen claims about them.

**The fix is ground truth internal to each screenshot, and it needed no new
asset.** mfselect's menu renders `dezogif_ng WiFi (ESP-01)` and
`dezogif_ng UART (joy port)` whatever is installed, in the same ROM font and
under the same attribute as the status row — so both correct labels are already
in every picture. M9 now requires each run's status field to **match the right
menu entry and differ from the other**, judged inside one image. A swap cannot
satisfy that; nor can one label used twice, so the new check subsumes the old
control instead of trading one break for another. Both were re-run: **swap → M9
red, M10 green; one-label → M9 and M10 both red; restored → 10/10.**

Every column falls out of one fact — all these strings begin with the 11
characters `dezogif_ng ` — so the transport field is 11 cells in: status row 2
columns 23-26, menu rows 6 and 7 columns 13-16. Pixel comparison means the
attributes must match too, and they do: the status row and the *unselected* menu
rows are both `ATTR_BODY`, and the selected row in these runs is row 5.

**M10 keeps what M9 gave up.** M9 reads four cells; M10 covers the other
twenty-eight, so a name of a different length — shifting the build number after
it — cannot hide behind a correct transport field.

**Neither is a percentage, deliberately.** Two status lines differing in four
characters differ in ~0.05% of the screen, which no threshold separates from
noise: the exact failure ERRORS.md records for T4.

**The lesson, and it is a new shade of one this project keeps paying for.**
ERRORS.md already says a fix never tested by *removing* it is a correlation, and
that "the screen changed" is not "the stub took over". This is the third shape:
**a control that breaks a thing in the easiest direction proves only that
direction.** Collapsing two labels into one is the degenerate break; exchanging
them is the adversarial one, and only the second distinguishes "these differ"
from "this one is right". When a check compares two observations, ask what it
knows about *either* of them on its own — and if the answer is nothing, it is a
consistency check, not a correctness check.

**M6 was moved onto the WiFi ROM at the same time**, and that is not cosmetic.
It had installed the UART ROM, so the guard control above turned M6 red too —
a check failing for a reason outside its own subject, which ERRORS.md names as
a defect in the check rather than a finding. M6's subject is checksum skew;
M7's is the UART guard; they should not be able to fail together.

**Two compile-time asserts** guard the menu, because the failure modes are
silent. `menu_fits_above_messages` — the menu must still end above `ROW_MSG`,
or a fifth entry paints over the first line of every message. 
`exit_is_the_last_menu_entry` — `main()`'s dispatch ends in an `else` that
installs the UART ROM, so an entry added *after* Exit would be selectable,
unnamed, and would quietly install something the user did not choose. Both were
verified to fire by compiling with `MENU_ITEMS` at 5 and 6; an earlier assert
comparing `sizeof(menu_text)` against `MENU_ITEMS` was **removed after being
shown useless** — the array's bound is `MENU_ITEMS`, so the two can never
disagree.

**Rejected.** Keeping `dezogif.rom` for one variant and adding a second name
only for the other (asymmetric, and it makes "which one is this" a question
about the filename rather than the ROM); naming them `enNextMf-wifi.rom` on the
card (not 8.3-safe, the constraint that already rejected `enNextMf.orig.rom`);
identifying the installed variant by checksum (that conflation was the
data-loss bug of #4 — see ERRORS.md); a `make mfselect-wifi` / `make
mfselect-uart` pair (it is one deployable directory, not two).

---

## 2026-08-04 — The unit tests run headless, and 36 of 64 never can

**Built and measured**, issue #3. `make test-unit` runs the Z80 unit tests in
jnext with no VS Code. **28 of the 64 cases run and pass; 36 are excluded and
say so on every run.**

**The thing the issue did not know, and it reshapes the problem.** The issue
says the tests need VS Code because DeZog *drives* them — enumerates the
`UT_*` labels, patches `UNITTEST_CALL_ADDR`, decides pass/fail by breakpoint.
True, and only half of it. **The assertions are also PC-side.** An assertion
here is a comment on an inert `nop`:

    nop ; TEST ASSERTION HL == 2

`SLDOPT COMMENT ... ASSERTION` copies it into the SLD and DeZog evaluates
`HL == 2` in JavaScript at a conditional breakpoint. So `ut.nex` is not a test
needing a runner; it is a test **whose checks are not in the image at all**.
Any headless approach has to compile ~291 assertions into Z80, not just
enumerate labels. Issue #3's approach (2), "external driver, keeps the assembly
untouched", cannot work for that reason — a driver has nothing to evaluate.

**The design.** Upstream's `unit_tests.inc` is replaced by
`headless/ut_headless.inc`, same macro names, assertions compiled to Z80; the
~65 assertions written *inline* rather than through a macro are rewritten by
`tools/ut-headless-gen.py` into copies under `build/`. **Nothing in
`src/unit_tests/` is modified** — `make unit-tests` and the VS Code path still
work, and `git blame` against maziac/dezogif stays useful.

Two details worth keeping. **The assertion must disturb nothing** — upstream
writes runs of them on different registers back to back, so each macro saves
AF plus its scratch and consumes the compare with a *conditional call*, `ld`
between `cp` and `call` not touching flags. And **the failing assertion names
itself**: `ut_assert_fail` pops its own return address, so no per-assertion id
has to be allocated or kept in step with the source.

**Silence is a FAIL, and that is the load-bearing property.** jnext's run is
frame-bounded, so a wedged guest ends the run quietly with status 0. `UT-BEGIN`
is emitted *before* each test and the bench requires an explicit `UT-DONE`; a
hang therefore fails and the last `UT-BEGIN` names the culprit. **Demonstrated
by breaking it**: an injected `jr $` gave `U2 the suite did NOT finish — it
hung or crashed in: 01 ut_utilities.UT_div_hl_e`, and two deliberately broken
assertions (one inline, one macro) went red with addresses that map to the
exact lines.

**Why 36 cannot run, and it is not a shortcut.** `.vscode/launch.json` gives
zsim a `customCode` plugin, **`src/simulation/uart.js`** — a JavaScript
peripheral inventing ports `0x8000`, `0x0001`-`0x0004`, and a `0x133B`/`0x143B`
UART whose RX is a queue and whose TX is always ready. Every test that drives
the debugger through a command reads its response back through those. **The Z80
cannot trap its own I/O**, so they cannot be provided from inside the guest,
and providing them in jnext is out of scope — a project-specific peripheral in
a general emulator, against this project's own rule that nothing of ours goes
there.

**The exclusion list is derived and was validated by measurement, not by
reading the JS.** Every test was run *alone in its own emulator process*
(`-DUT_ONLY=<n>`, kept as a diagnostic). The marker-based rule covers every
test that fails or hangs under jnext and adds exactly one more:
`ut_nmi.UT_nmi_cause_button`, which **passes for the wrong reason** — its
zsim-only setup write to port `0x0002` does nothing on a real machine, and the
real NR `0x02` happens to satisfy `nmi66h`'s cause check anyway. Excluded too,
because a test that passes without its setup having worked is not evidence.

**Isolation was verified, not assumed.** Several tests self-modify the debugger
and never undo it — `ut_uart` patches `transport_read_byte.timeout`, `ut_nmi`
patches `MF.nmi66h.is_button_cause` — so a later test could jump into a
leftover trampoline, land on its `TC_END` and be **reported as a pass it never
earned**. The runner restores all eight MMU slots and copies a pristine 8 KB
program bank back before each test, and the single-run verdicts are identical
to the isolated per-test ones.

**Counts are pinned in two places** — the Makefile (checked against the
sources at build time) and the bench (checked against what ran). Pinning only
the total would let a test slide from the runnable set into the excluded set
while the total stayed right, which is the "runs 5 of 25, reports 5/5" failure
in a new costume.

**The gate held.** Both ROMs are byte-identical to `main`'s with `BUILD_TIME`
and the build number pinned — UART `13217f12…`, WiFi `d144ccb2…` — and
`make test` 6/6, `make test-mfselect` 10/10 are unchanged. Nothing that
produces a ROM was touched.

**Rejected.** Reimplementing `uart.js`'s ports in jnext (out of scope, and the
wrong home for a project-specific peripheral); rewriting the excluded tests to
use memory instead of ports (that changes upstream's assertions and would test
my simulator rather than the code); dropping the excluded tests from the table
silently (an exclusion nobody sees is an exclusion nobody notices); folding
`test-unit` into `make test` (it *could* — no external dependency, no port —
but every other bench here is its own target, and `make test` is documented at
length as the screenshot bench).

**The issue's "25 test cases" is wrong: there are 64.** `TC_END` appears 64
times, and there are 64 `UT_*` entry points.

---

## 2026-08-04 — WiFi is a prerequisite; the stub holds no credentials

**Decided (user).** In WiFi mode the stub assumes the Next is **already
associated** and will never put it there. It sends no `AT+CWJAP`, stores no
SSID and no passphrase, and only *verifies* that it has an address
(`AT+CIFSR`), reporting clearly on screen when it does not.

The user satisfies the prerequisite once with `/apps/wifi/setup/wifi2.bas`,
the wizard on the NextZXOS SD card, and the ESP-01 keeps the credentials in
its own flash. Documented exhaustively in [doc/WIFI-SETUP.md].

**Rejected: storing credentials in the ROM.** The user's first instinct was to
put them "in the ROM itself", which was a reasonable reading of the constraint
below, and the user then reversed it. **Two reasons, each sufficient on its
own:**

1. **A passphrase in a ROM is cleartext on a removable card.**
   `enNextMf.rom` is a file that gets copied, backed up and mailed to us with
   bug reports. Every copy would be a credential leak, readable by any program
   on the machine. Obfuscation would be theatre.
2. It would need a patch path — a host tool or mfselect — to be usable at all,
   because otherwise changing network means reassembling the ROM.

A third argument — that it buys nothing, because the module persists its own
credentials and auto-reconnects — is **deliberately not counted**, because it
rests on the one thing this entry admits is unverified (see the closing
paragraph). A draft of this entry listed it as a third *sufficient* reason
while flagging the same claim as unmeasured thirty lines below, which is the
contradiction the reviewer caught. **If a reason depends on something we have
not measured, it is not sufficient**, and the decision does not need it.

**The constraint that made "in the ROM" look necessary, and it is real.** The
stub **cannot read the SD card**: nothing in `src/` opens a file, and the only
`rst 8` is inside `MF_BREAK` in `macros.asm`, a macro upstream disabled as
"did not work for me". Nor could it safely — it is an NMI handler running with
the debuggee's banks paged arbitrarily and NextZXOS possibly mid-operation, so
the esxdos API needs guarantees the NMI path cannot make. **So there is no
config file, and with credentials rejected there is nothing that needs one.**

**Consequence for M1, and it is not small.** Bring-up must *check* association
and fail loudly rather than hang or draw a connect string with no address
behind it. That is plan §M3's "clear failure reporting on the Next's screen",
pulled forward to M1 because without it a Next that was never put on WiFi
presents as a broken debugger.

**Measured while writing this up** (jnext 0.99.118, `--esp`): `wifi2.bas` runs
in the emulator and its **read-only half works** — firmware, SSID and IP are
reported — while its **configuring half does not**, because jnext implements
`AT+CIPDNS_CUR?` but not `AT+CIPDNS?`, and none of `CWLAP`, `CWJAP=`,
`CIPSTA=`, `CWDHCP=` or `CIUPDATE`. That is the correct half for us: we only
ever verify. Credentials can only be set on hardware, which is consistent with
this being a prerequisite rather than a feature.

**One prediction was wrong and is worth keeping.** A static trace of the
wizard's commands against jnext's dispatch table said it would die at startup
on the unimplemented `AT+CWMODE=1`. It does not — unknown commands answer
`ERROR` and the wizard shrugs them off. Running it is what showed that.

**NOW EVIDENCED ON HARDWARE, which is not quite the same as measured.** The
user reports (2026-08-04) that their Next **comes up already associated**: once
WiFi is set up, the ESP is associated and ready from then on, exactly as jnext
models it. So the setup story is **once per machine**, not once per boot, and
the "verify, do not configure" design rests on first-hand hardware evidence
rather than on ESP-AT documentation.

**Calibrated deliberately**, after a reviewer pointed out that the first draft
tagged this "verified on hardware" and gave it the same rung as claims anyone
can re-run with a grep or an emulator run. It is one machine, one reporter, no
captured artefact. That is the strongest evidence obtainable — no emulator can
produce it — and it is still weaker than a re-runnable check. The ladder now
has a rung for it: **reported on hardware**.

Note this does *not* re-promote the discarded third reason above. That reason
is now true, but the decision never needed it and the lesson stands: it was
counted as sufficient while unmeasured, and that was the error — not the claim
itself.

[doc/WIFI-SETUP.md]: doc/WIFI-SETUP.md

---

## 2026-08-04 — ROM identity is a magic string; the CRC keeps only integrity

**Decided (user), issue #4.** Every `enNextMf.rom` carries a magic string at a
fixed offset, and mfselect uses it to answer "is this ours?". The string, and
its shape is the user's:

    DeZoGiFnG_UART_0001        DeZoGiFnG_WIFI_0001

prefix + transport variant + a four-hex-digit build number from a new
`version.yaml`, bumped by `make bump`, one bump per merge to `main` **that
changes a ROM**.

**That qualifier was added the same day, after the rule met its first
counter-example** (user, 2026-08-04). The original wording was "one bump per
merge", full stop, and the very next merge was documentation. Measured rather
than argued: building both sides with `BUILD_TIME` and `BUILD_NUMBER` pinned
gave a **byte-identical ROM**. Bumping there would have minted a new identity
for a ROM that had not changed — asserting a difference that does not exist,
which is precisely the opposite of what the number is for.

The check is mechanical, not a judgement call —
`git diff --name-only main..<branch> -- src/ Makefile`, empty means
no bump — and deliberately conservative: a touched `Makefile` may leave
the ROM identical, and bumping anyway costs nothing, whereas failing to bump
when a ROM *did* change leaves two different ROMs claiming to be the same
build. With two variants (#5) the rule is *any* of them; they share sources, so
one check covers both.

**The two questions that were being conflated.** *Identity* — is this ours,
and which variant — is now the magic. *Integrity* — did these bytes land
intact — stays the CRC in the `.sum` files, which is what it was always good
for. Nothing about the post-copy verification changed.

**Why this was a bug and not a tidy-up, which the first draft of the issue
undersold.** `BUILD_TIME` is stamped into every ROM, so the CRC changes on
*every build*. mfselect's first-run guard — the one that refuses to save
**our** ROM as the user's `original.rom` — was a checksum comparison against
`dezogif.sum`. The moment a user upgraded the stub, the installed ROM and the
`.sum` beside it came from different builds, the comparison failed, the guard
fell silent, and mfselect captured the debug stub as the stock Multiface ROM
with no copy of the real one left on the card. Same shape as the `CREAT_TRUNC`
defect in [[ERRORS.md]]: a guard defeated through a door nobody had checked.

**Proved by reverting it, not by argument.** Bench check **M6** ships a
deliberately stale `dezogif.sum` against our ROM — what an upgraded card looks
like — and requires the guard to hold. With the old checksum guard restored,
**M4 still passed and M6 failed with `original.rom` overwritten by our ROM**.
So M4 could never have caught this, and M6 earns its place.

**Design points worth keeping.**

- **The offset is a permanent contract**: ROM file offset `0x1FE0`, address
  `0xFEA0`. It is the *end* of an image whose size the firmware fixes at 8192,
  chosen because it cannot drift as the code grows. An `ASSERT` in `main.asm`
  fails the build if the debugger grows into it — which also closes a latent
  hole, since the existing assert permitted `0xFF00`, past even the end of the
  region `SAVEBIN` writes.
- **Match the prefix and the variant, never the build number.** Matching a
  per-build value is precisely the fragility this removes.
- **The build number is not derived from `BUILD_TIME` or the git hash**, and
  that is deliberate: `make check-reproducible` must keep passing, so identity
  must not change on every build.
- **An unrecognised variant reports as ours-but-unnamed**, not as UART.
  Guessing would be a false statement about the ROM on the card, which is the
  class of thing this block exists to stop.

**Rejected.** A separate variant *byte* alongside a shorter magic (the user
specified the variant inside the string, and one readable token in a hex dump
beats two fields); putting the block at the ROM's *start*, where the RST
vectors live and where any offset would move as code changed; keeping the
checksum as a second identity check (it cannot be one — it is wrong after
every build, so it could only ever veto a correct answer).

---

## 2026-08-04 — M0(b) first, and M0(a) is off the critical path

**Decided, and it reorders the plan.** M1's WiFi half starts with the **M0(b)
spike** — the ESP brought up as a TCP server in a standalone fixture — and not
with `transport_esp.asm`. Landed as `test/esp_server.asm` + `make test-esp`.

**Why the spike rather than going straight at the transport.** Two unknowns
would otherwise be debugged at once: the AT/`+IPD` protocol, and the
debugger's own constraints. The second is not hypothetical —
`transport_wait_rx` runs with layer-2 read/write possibly mapped and therefore
**no CALLs and no PUSH/POP** (`transport_uart.asm`), which is a bad place to
first meet a framing bug. Plan §9 already said this ("it isolates 'is the ESP
path alive at all' from 'is my `+IPD` parser right'"); the only new thing is
that jnext#210 made it runnable headless, so it costs one bench target instead
of a hardware session.

**The spike is not throwaway, and that is what settles the cost question.** It
is a permanent bench check whose assertions are on **bytes over a socket** —
the first in this repository that are. Every other layer judges pixels or
files, and ERRORS.md already records a pixel check that could not tell success
from noise.

**M0(a) is DROPPED — decided by the user, 2026-08-04.** An earlier version of
this entry called it "deferred, not rejected on merit". The user's call is that
it is scratched definitively, and the justification is that it was never work
worth scheduling in the first place:

1. It spikes a **client**-mode transport (`AT+CIPSTART` + `AT+CIPMODE=1`), and
   §4.2 settles that the Next must be a **server** because DeZog always dials
   out. A client-mode Next needs a PC-side relay nobody intends to write.
2. Its only value — answering "is the ESP path alive at all?" cheaply and
   separately from "is my `+IPD` parser right?" — was collected by (b) on its
   way past.
3. It cannot run here regardless: it needs `AT+CIPMODE`, which jnext does not
   implement and deliberately will not, because server mode forbids
   passthrough.

So **M0 is complete**, and (a) is not outstanding work. If server mode ever
fails on real hardware, §4.2's fallback is where that contingency lives — a
paragraph in the transport section, not a milestone anyone is tracking.

**What M0 did NOT establish is hardware**, and dropping (a) does not change
that either way: (b) and (c) both ran in jnext, so the section's original "on
real hardware" wording is unsatisfied by either of them. That gap is M1's.

**What the bench established, by breaking it on purpose rather than by
argument.** With the `+IPD` connection id hardcoded to `0` — the value the
Espressif documentation leads you to expect — **E2 gets an empty reply**: no
error, no data, exactly the signature the jnext-inbound-id entry below
predicts. With it hardcoded to `1`, E2 and E3 **pass** and only E4 fails. So E4
(a second simultaneous connection) is the only check that catches an id that is
assumed rather than read, and it earns its place.

**One correction from that run, because the first reading of it was wrong.**
The id-`0` control also failed E3 and E4, and the obvious story — the guest had
parked in its failure loop, so it refused the second connection — is false. The
ESP listener lives in the **emulator**, not in the guest, so a wedged guest
refuses nothing. What actually happened is that the jnext run is bounded in
**frames**, not in wall clock, so the process exits while the guest is still
silent — the client's pending read then ends on **EOF** as the socket is torn
down, and the next connection is refused because nothing is listening any more.
The failures after E2 were an artefact of the harness, not evidence.

Note the timeouts do *not* elapse, and the first correction to this paragraph
said they did: the whole failing run takes ~9 s, where two 20 s timeouts alone
would need 40. Measuring it is what showed that; reasoning about it produced
the wrong mechanism **twice in a row**, once in each direction. The client now
labels a silent guest instead of presenting the cascade as three independent
findings.

**Two divergences the emulator cannot show, written down before they bite.**

- **Association.** jnext has no `AT+CWJAP=` at all, only the query form, so the
  emulated module is permanently on a network. ~~Hardware is not, and the stub
  will need a bring-up path the bench can never exercise.~~ **Both halves of
  that turned out wrong, later the same day.** Hardware *is* already associated
  — a configured Next comes up that way (reported on hardware, 2026-08-04) —
  and the stub therefore needs **no bring-up path at all**: WiFi is a
  prerequisite the user satisfies once with `wifi2.bas`, and the stub only
  verifies it has an address. See the WiFi entry at the top of this file. What
  survives is the narrow original point: the bench cannot exercise association
  either way, so nothing here can ever test it.
- **Baud.** jnext models baud as *timing* only, so the fixture would have
  passed at any rate. It is pinned to **115200** anyway — what a real ESP-01
  answers at until told otherwise — because a value that only works in the
  emulator is precisely the kind of thing that passes CI and fails on the
  bench-top. Upstream's 921600 is a *joy-port cable* rate, where both ends are
  ours to choose; the ESP's is not. Raising it is M3's baud negotiation and
  must start by talking at 115200.

**Rejected.** Writing `transport_esp.asm` first and testing it through
`make test-dzrp` (two unknowns at once, and the harness has never run against
our stub either — [[#DZRP's two length conventions]]); folding this into
`make test` (it needs a concurrent client and binds a host port, so it cannot
keep that suite's no-external-dependencies promise); asserting on the
fixture's border colour (the socket checks are strictly stronger, and a check
that cannot fail independently is noise — the border stays as *diagnosis*, to
name which step stopped).

---

## 2026-08-04 — M1's second half: the ESP transport, and the switch

**Built and measured.** `src/transport_esp.asm` implements the whole
`transport.asm` interface over the ESP-01 in TCP server mode, selected by
`make TRANSPORT=wifi` (`-DTRANSPORT_WIFI` → `ROM_VARIANT`). The AT chain, the
`+IPD` parser and the `AT+CIPSEND` framing are ported from `test/esp_server.asm`,
the M0(b) spike — which is the whole reason that fixture was built first.

**The measurement that matters: `make test-dzrp-stub` — W1 pass, then 7 of 8
DZRP checks pass.** A headless Next with our WiFi ROM as the Multiface ROM, an
emulated M1 press, and the conformance suite talking DZRP over a socket to the
debugger. Loopback is exact at 0, 1, 255, 256 and **1024** bytes, which is the
multi-chunk path; sequence numbers echo across five commands; registers and a
memory round trip come back right. Before this the strongest evidence in the
project was a pixel count.

**Three decisions worth keeping.**

1. **The 0xA5 preamble is a macro, not an `IF`.** `TRANSPORT_MESSAGE_START`
   expands to upstream's two instructions in UART mode and to nothing in WiFi
   mode, so `message.asm` cannot tell which it was assembled against — the rule
   CLAUDE.md states. Asserted rather than assumed: the bench passes
   `--expect-preamble none`.
2. **Responses are buffered and framed, because `AT+CIPSERVER` forbids
   passthrough.** `transport_write_byte` appends; `TRANSPORT_END_MESSAGE`
   flushes as an `AT+CIPSEND=<id>,<len>`. TCP is a stream, so a long response
   spanning several CIPSENDs is invisible to the client.
3. **The connection id is read from `+IPD` and echoed back, never assumed** —
   the note recorded below about jnext's inbound ids starting at 1, now used
   rather than only written down.

**The bug that only a real client could have found, and the shape of it is the
lesson.** `TRANSPORT_END_MESSAGE` was placed at the top of `cmd_loop` and of
`main`, which looked exhaustive: a response returns to `cmd_loop`, `NTF_PAUSE`
is followed by `jp cmd_loop`, `CMD_CLOSE` by `jp main`, `CMD_CONTINUE` already
flushed in `backup.asm`. **`cmd_loopback` reaches none of them** — it ends
`pop af` / `jp main_loop.continue`, bypassing `cmd_loop` entirely. So its reply
sat in the buffer until the *next* command arrived and was then delivered to
whichever connection had asked that one. The suite saw a timeout followed by a
sequence mismatch on the *following* check, i.e. the symptom appeared one check
away from the cause. Found by reading jnext's `esp01=trace` log against the
source, not by reasoning about it.

**Two things the independent review rejected, both real, both fixed and both
now defended by a test.**

1. **The `+IPD` reassembly path had no committed test.** jnext splits inbound
   TCP at `MAX_IPD_CHUNK = 2048` (`esp_at.h:448`), and the loopback sweep
   stopped at 1024 — so *every* payload in the transport's evidence had arrived
   in a single frame, and the most novel code in the diff was never executed by
   anything. The reviewer ran 2000/2048/2049/3000/4096/8192 by hand and all six
   round-tripped, so the code was right; what was missing was the standing
   check. The sweep now runs 2047/2048/2049/4096, straddling the boundary
   rather than jumping over it. Real traffic crosses this constantly —
   `CMD_WRITE_BANK` pushes 8-16 KB per bank when DeZog loads a `.nex`.

2. **`esp_conn_id` was never cleared, which broke the NMI-button fallback.** It
   was set by an inbound `+IPD` and nothing ever reset it, so after a client
   disconnected the id of a closed connection survived for the rest of the
   power-on session. Every later *unprompted* `NTF_PAUSE` — the M1 button, or a
   leftover `RST 0` through `breakpoints.asm` — was addressed to it, got
   `ERROR` from `AT+CIPSEND`, waited for a `>` that could not come, and diverted
   to `drain_main`, which discarded the notification and painted **"Last Error:
   TX Timeout"** on a machine with nothing wrong with it. Plan §4.3 calls the
   button "always available"; it silently stopped being so after the first
   disconnect.

   **Fixed by reading `AT+CIPSEND`'s refusal rather than by parsing
   `<id>,CLOSED`**, and the choice matters: `ERROR` covers *every* reason a cid
   stops being usable — closed by the peer, closed by the module, never opened —
   at one point in the code, where a `CLOSED` parser only covers the one case it
   was written for and adds a second pattern to the RX hot path. So
   `esp_wait_prompt` now matches `'>'` **or** `"ERROR"`, and on `ERROR` the id
   goes back to 0, which is the "nobody to send to" state `transport_flush`
   already discards in.

   **The residual is stated rather than fixed:** a client that has reconnected
   but not yet sent anything is invisible, because only an inbound `+IPD`
   refreshes the id, so an unprompted notification in that window still goes
   nowhere. Closing it needs `<id>,CONNECT` tracking, which belongs with M3's
   reconnect work.

**The test for (2) was shown failing first, which is the only reason it is
worth anything.** Bench check **W2**: a client sends `CMD_CONTINUE` and closes
in the same breath; with nothing loaded the debuggee resumes at PC=0 and runs
into a stray `RST 0` (measured: address 0x6417, break reason 2), so the stub
sends an `NTF_PAUSE` to a connection that has gone — no button press and no
timing luck required. W2 asserts the *precondition* from jnext's own log (an
`AT+CIPSEND` really was refused), that the stub still serves a new client, and
that its screen reports no error, counted as **bright-red pixels** — jnext
renders non-bright components as 182 and bright as 255, and `out (BORDER),a`
carries no bright bit, so the error text is the only thing on that screen that
can be exactly `(255,0,0)`. Pre-fix: **824**. Post-fix: **0**.

**What is NOT done, and none of it is hidden.**

- **`AT+CIFSR` is not sent and no address is shown.** Reporting an address means
  parsing and drawing it, which is the connect-string UI decided on 2026-08-04
  and deliberately left to its own change. WiFi mode currently draws upstream's
  baud line and joy-port selector, both meaningless there.
- **A re-init while already listening reports an error.** Symbol Shift + NMI
  runs `transport_init` again and `AT+CIPSERVER=1,<port>` answers ERROR when a
  server is up. The link keeps working; the screen lies. `esp_wait_prompt` now
  shows how to fix it — the same two-pattern shape applied to `esp_command_ok` —
  so this is a small follow-up rather than an open question.
- **`transport_byte_available` can stall `main_loop` for ~100 ms** when the
  module puts an unsolicited line on the wire (`<id>,CONNECT` is the common
  one): it scans for a header that is not there and gives up on the RX timeout.
  Upstream's is an O(1) status read. Bounded, free while idle, and worth knowing
  before anything is built on "that poll returns immediately", which is a
  statement about the serial build.
- **Bring-up failure shows as "RX Timeout"**, because adding an error code
  means adding a string and a table entry to `data_const.asm` — common code
  whose bytes the UART gate protects. `transport_activate` carries the flag past
  `drain_main`'s reset of `last_error`, which is the only trick involved.
- **C2 of the DZRP suite is red, and it is pre-existing.** `cmd_init` reads the
  remote's program name until a NUL and ignores the frame length, so a length
  that disagrees with the payload desynchronises silently. `commands.asm` is
  untouched and the UART ROM is byte-identical to `main`'s, so this is what the
  serial build has always done. Fixing it changes the serial ROM and belongs on
  its own branch. **CLOSED — issue #7, on its own branch as predicted; see the
  entry at the top of this file.**
- **Nothing has run on hardware.** jnext models baud as timing only and its
  module is permanently associated (no `AT+CWJAP=` at all), so the 115200
  pinning, the ESP-AT echo default and every timeout constant are reasoned, not
  measured.

**The gate held.** With `BUILD_TIME` and the build number pinned the UART ROM
hashes `2387fc96…`, identical to `main`'s, across a change that added a
transport, two framing macros, three macro call sites in common code and a
Makefile variant split. That is the same standard the interface extraction was
landed to, and it is worth keeping as the price of admission for M2.

---

## 2026-08-04 — DZRP's two length conventions, and where 0xA5 really comes from

**Found by the DZRP conformance suite** ([issue #2]) on its first run against a
reference remote, which is what the suite was built for.

**1. The two directions use different length conventions.** A *command*'s
length counts the **payload only**; a *response*'s counts **from the sequence
byte**. DeZog's spec says exactly this in two tables whose wording differs by a
clause. Sending `CMD_INIT` with a symmetric length produced no reply at all —
the remote sat waiting for two bytes it thought it was owed. The cost of
assuming symmetry is a silent hang, not an error. Confirmed three ways by the
reviewer: our own stub's send and receive paths, DeZog 3.7.4's `sendDzrpCmd`,
and CSpect.

**2. `0xA5` is a documented DZRP extension for the serial link — NOT a leak.**
The first version of this entry called it "a serial artefact that leaks into
`message.asm`" and said "nothing here establishes why the zero noise required
it, only that the comment says so". **Both statements were wrong**, and the
source that disproves them is `doc/legacy/Design.md:30-31`, a file CLAUDE.md
lists as required reading:

> the DZRP protocol was extended by one byte which is sent as first byte of a
> message (only in direction from ZX Next to PC). This is the
> MESSAGE_START_BYTE (0xA5). DeZog will wait on this byte before it recognizes
> messages coming from the Next.

The why is the paragraph above it: a game that grabs the joy port leaves the
Next emitting endless zeroes, and the preamble is how DeZog resynchronises.
DeZog implements the split itself — `ZxNextSerialRemote` strips byte 165,
`CSpectRemote` does not (verified against the installed DeZog 3.7.4,
`~/.vscode/extensions/maziac.dezog-3.7.4/out/extension.js`; both classes
identify themselves by their own log strings, which survive minification).

**So M1's answer is settled, and it is the opposite of "remove it".** The
preamble is **required in UART mode and must be absent in WiFi mode**, which
makes it a property the *transport* contributes — the fourth thing the
assembly-time switch selects, after the byte stream, the lifecycle and the UI.
An earlier draft listed "drop it in both modes and see whether the serial path
needed it" as an option to try; that would have broken interoperability with
DeZog's real `zxnext` remote, i.e. exactly the UART regression CLAUDE.md's hard
rule exists to catch.

**How the error happened, because it is the repeating one.** The claim was
derived from the DZRP spec plus one socket remote, without reading the
project's own frozen upstream design doc. [[ERRORS.md]] already carries an
entry for this shape — deriving a hardware fact instead of reading the VHDL —
and this is the protocol-side repeat. Caught by the independent reviewer, not
by the author.

[issue #2]: https://github.com/jorgegv/dezogif_ng/issues/2

---

## 2026-08-04 — The stub is alive: first liveness evidence, bench T6

**Measured, not decided.** With jnext 0.99.118's `--delayed-nmi`, a real M1
button press against our own `enNextMf.rom` makes the stub **take over and
paint its UI: 90.28% of the screen repainted**, against the stock Multiface
monitor's 91.41%. Now bench check **T6**.

**Why this matters more than the number.** Every check this bench had proved a
*negative*: it assembles, it does not perturb the boot, it correctly ignores a
software NMI. None of them would have failed if the stub had been incapable of
running at all. T6 exercises, in one run, Multiface paging, the relocation of
`MAIN` into a RAM bank at slot 7, `show_ui`, and the core-version check passing
against core 03.02.03.

**It answers plan §8.3 for the entry path, and only that.** That section
proposed dropping upstream's released ROM onto a jnext SD image as third-party
validation of jnext's Multiface/AltROM/stackless-NMI implementations, before
writing new Z80 code. Our own build coming up is the same evidence for
**Multiface paging and the entry side of stackless NMI**. It is *not* evidence
for AltROM or for the return-to-debuggee half — see the scope limit below. An
earlier draft of this entry said "retires §8.3" flatly; that was the same
overclaim, one paragraph up from where I had just corrected it.

**T6 did not replace T4, and both CLAUDE.md and the plan said it would.** That
was wrong and is corrected in both. The two send **different causes** to the
same check in `nmi66h`: T6 a button press, which it accepts; T4 a software
NR `0x02` write, which it rejects. Deleting T4 would have thrown away the
regression check M2 is required to invert when it teaches `nmi66h` to accept a
software cause — the check would have vanished on the day the button arrived,
and nobody would have noticed until M2 broke something silently.

**What T6 does not cover — larger than the first draft of this entry admitted,
and the reviewer had to point it out.** That draft said only that a *second*
press after a resume was untested, which implies the first resume was covered.
It is not. **T6 never resumes at all.** No DZRP client attaches, so the stub
idles in `main.asm`'s `main_loop`, whose `transport_byte_available` poll is a
status-bit read returning immediately; with no byte ever arriving its
`jp nz,cmd_loop` never fires, so `cmd_loop` — and the blocking
`transport_wait_rx` inside it — are never reached at all, and the run ends on
the frame limit. Nothing past "the debugger came up" executes: not the exit
path, not `backup.asm`'s restoration, and not the **return-to-debuggee half of
stackless NMI** — the half plan §3.4 says actually matters, because without it
entering the debugger corrupts the program being debugged. Of stackless NMI,
T6 exercises the **entry side only**.

So the Appendix A row is scoped to that, and the honest summary is: the stub
comes up. Not "the NMI path is sound".

**A green T6 still cannot tell a takeover from a crash**, because it is a
pixel-difference measure and does not know what it is looking at — the lesson
already in [[ERRORS.md]]. One failure mode is now excluded automatically: T6
also requires the result to look *unlike* the stock Multiface monitor, which
catches "our ROM was not actually installed". A crashed machine would still
pass, so the screenshot remains the artefact to inspect.

**Two rounds of review were needed to get this paragraph right, and the second
correction was to the mechanism, not the conclusion.** The first version of it
claimed `cmd_loop` blocks on `transport_wait_rx`. It does not — `cmd_loop` is
never entered. That wrong mechanism had been asserted confidently, propagated
into four files, and was caught only by someone tracing `main.asm:154-191`
against the source. It is the failure ERRORS.md already names: a plausible
mechanism stated instead of a traced one.

**Also fixed while here.** The bench's summary line was hardcoded `5/5` and
would have kept saying so after a sixth check was added — a small lie in
exactly the place a reader trusts. It is derived now.

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

**House form.** `git merge --ff-only` is the default, and a conflict means
rebase or resolve deliberately rather than silently minting a merge commit.

(This entry originally justified that with "`main`'s history is linear — no
merge commits before today". That was already untrue when written: `857a1df`
is a merge commit. The rule stands on its own; the false premise is removed
rather than the conclusion.)

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

**~~Not decided.~~ ANSWERED ON HARDWARE, 2026-08-04: a soft reset is NOT
enough.** This entry used to say the question was open, that the advice was
"safe either way", and that the project's "read the VHDL" rule could not settle
it because it is a tbblue firmware question. The user settled it by doing it:
after installing our WiFi ROM, a **Reset button press** followed by NMI brought
up the **stock Multiface menu** — the old ROM, still live. A **power cycle**
then brought up ours. So the firmware reads the Multiface ROM at power-on and
nothing short of that re-reads it, and mfselect's yellow POWER-CYCLE advice is
correct rather than merely cautious.

Worth keeping for the method as much as the answer: this cost one button press
to establish and had sat unanswerable for a day, because no emulator run and no
amount of VHDL could reach it. Some questions are only hardware's to answer,
and the cheap ones should be asked the moment hardware is available.

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
