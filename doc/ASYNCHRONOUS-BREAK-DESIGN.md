# Asynchronous break — feasibility and design

**Issue [#22](https://github.com/jorgegv/dezogif_ng/issues/22), milestone M2.** Written 2026-08-08,
before any M2 code existed, to answer one question the plan parked and one it did not think to ask.
**Built 2026-08-10, and the build changed the shape of the thing** — see the next section, which is
the one to read first. Everything below it is the pre-build evaluation, annotated where the build
falsified it and left standing where it did not, because this project annotates superseded claims
rather than editing evidence.

---

## 0. AS BUILT, 2026-08-10 — and the decision that reshaped it

**THE DEBUGGED PROGRAM INSTALLS THE COPPER LIST, NOT THE DEBUGGER** (user's call, before any code).
That single decision removes this document's headline cost. §3.1's argument — that enabling
asynchronous break **destroys** the debuggee's Copper program irrecoverably, because the list is
write-only and cannot be saved — was correct and is now **moot**: the debugger installs nothing, so
there is nothing to destroy. A developer who wants PC-initiated break puts

```
WAIT line,0
MOVE $02,$08
```

at the start of their program, or into their own Copper list, and compiles it out for release.
Measured cost in the program: **44 bytes** (16 for the NR 0x06 bit-3 read-modify-write, 28 for seven
`nextreg` writes; 28 if you trust NextZXOS to have left the gate set, which it does).

**The cost, stated in the direction it now falls:** a program that does not cooperate gets no
asynchronous break at all, and the debugger cannot install one for it — because it cannot read what
it would be overwriting. That is a strictly smaller price than the one this document was written to
weigh, and it is why the feature no longer needs to be "opt-in" in the debugger at all: it is opt-in
in the *debuggee*, by construction.

### What the stub gained

`nmi66h` serves a software Multiface NMI (NR 0x02 bit 3). The path is deliberately not the button
path: it never changes the clock unless it breaks in, never reaches `init_main_bank`, and **restores
MMU slot 7**, because it fires while the *debuggee* is executing. The decision itself lives in
`mf_nmi_poll` in the debugger's own bank, behind a two-byte magic check, so that MF ROM bytes — which
cost 32 each, a 16-byte `ALIGN` step in that half plus 16 of the other — are spent only where they
must be. §4.5's byte arithmetic held: the half went 0x140 → 0x170, three steps.

**T4 was NOT inverted, and this document, `CLAUDE.md` and the plan all said it would be.** That
instruction assumed the fix would make a software cause *take over*. It does not: the poll accepts
the cause and then declines unless our image is in `MAIN_BANK` **and** a debuggee is running. In
T4's run no debugger has ever been started, so the decline — and T4's verdict — are unchanged. What
changed is the reason. §4.1 and the plan's risk table are annotated accordingly.

**A defect M2 would have made dangerous was fixed with it.** `nmi66h`'s cause check selected NR 0x02
*before* the instruction that claimed to save the debuggee's NextREG select latch, so what was saved
was always `REG_RESET` — issue #37's second discovery, harmless once per button press and a
recurring corruption of the debuggee at 50 Hz. The latch is now read once at the top of `nmi66h` and
restored on every path that returns to the interrupted code. It costs four bytes **less** than the
version it replaces.

### The poll's costs, in one place

1. **~1288 T-states per frame** — 0.230% at 28 MHz, **1.84% at 3.5 MHz**. Measured; §5.
2. **A spurious break on any byte the module says**, including its own unsolicited
   `<id>,CONNECT` / `<id>,CLOSED` lines. Decided; below.
3. **AN EXTINGUISHED DIAGNOSTIC, and it is not the same thing as (2).** `transport_poll_traffic`
   reads the UART status register, which clears the **sticky** RX overflow and framing bits
   (`serial/uart.vhd:530-539`, cleared on the falling edge of a read of 0x133B). `mf_nmi_poll` asks
   `prgm_state` first, which keeps that away from a *race* with the debugger's own reads — but it
   does not stop the poll wiping an overflow that happened while the debuggee was **running**, ~50
   times a second, before anything can report it. So `Last Error: RX Buffer overflow` will in
   practice never be seen for an overflow during a free run.

   **A lost diagnostic, not a lost guarantee.** The bytes are already gone by the time the flag is
   set, and their loss still surfaces as a DZRP desynchronisation or a timeout, exactly as it would
   have. What is lost is being told which fault it was. Nothing covers it and no run stages it.
4. **The debuggee must carry the two Copper instructions**, or it gets no asynchronous break at all.

### §4.3's open question is decided: BREAK ON ANY BYTE

`transport_poll_traffic` is O(1) by contract and may not scan, so it cannot tell a `CMD_PAUSE` from
one of the ESP module's unsolicited `<id>,CONNECT` / `<id>,CLOSED` lines. Such a line therefore
breaks a running debuggee in when nobody asked. The alternative — parsing inside the NMI — costs up
to ~100 ms per frame, which is not a poll. The precedent is `cmd_loop`'s own `transport_wait_rx`,
which has always ended on any byte from the module.

**The break reason is `MANUAL_BREAK`**, and no fourth reason was invented: `BREAK_REASON` has three
values (`src/breakpoints.asm:18-20`), DZRP defines no "the client asked", and DeZog's `cspect`
remote already understands the one a button press reports. `cmd_pause` is unchanged, and issue #8's
two prohibitions still hold for #8's own reasons — the break is caused by the **poll**, so by the
time `cmd_loop` reads command 7 the machine is already stopped and `send_ntf_pause` has already set
`prgm_state`.

### TWO THINGS WERE RECORDED HERE AS MEASURED AND UNRESOLVED. BOTH WERE WRONG, AND HOW THEY WERE WRONG IS WORTH MORE THAN EITHER

They are kept, struck, rather than deleted: this section was the handover a reader would have acted
on, and both were confident, specific, and reproduced. Neither was a defect in the Next, in
upstream's handler, or in this stub. Settled 2026-08-11; MEMORY.md carries the runs.

**1. ~~THE REPORTED PC IS WRONG, AND BENCH CHECK W8 IS A STANDING RED BECAUSE OF IT.~~ THE CHECK WAS
READING THE WRONG FIELD.** The run was described correctly — the notification arrives, carries
`MANUAL_BREAK`, the command is answered, the stub serves on, the control is silent — and the
conclusion drawn from `0x0000` was not. `NTF_PAUSE`'s payload is
`[id][reason][bp_addr_lo][bp_addr_hi][bank+1][string]` (`src/message.asm:342-362`), and `bp_addr` is
the address of the **breakpoint** that stopped the program. `mf_nmi_button_pressed` passes
`ld hl,0` (`src/mf.asm:169`) because a manual break has no breakpoint. So those two bytes are
`0x0000` by design, on every remote, for every asynchronous break — and the 2026-08-05 hardware
capture of a real M1 press in this repository records exactly that (`payload=01 01 00 00 00 00`,
with the PC arriving separately as `CMD_GET_REGISTERS` → `0x801C`). The `0x0000` was an honest
reading of a field that is not the PC.

**Measured, on the same run that reported the red**: `CMD_GET_REGISTERS` returns **PC `0x802D`,
SP `0x9F00`** — the fixture's spin and the fixture's own stack. And `save_nmi_return_address` took
its **stackless** branch (NR `0xC0` = `0x0A`), so the PC came out of NR `0xC2`/`0xC3`. That closes
MEMORY.md 2026-08-05's standing gap: *which* branch of that routine runs had never been
distinguished anywhere, and now is, in the emulator.

**The trap that produced the wrong diagnosis is still there and is now named in the check**: NR
`0xC2`/`0xC3` read back *after* a break always hold a **debugger** address, because the poll keeps
firing against the stopped debugger and every acknowledge overwrites the pair. That is not evidence
about what the latch held at the break, and it reads exactly like evidence.

**2. ~~A SOFTWARE NMI DOES NOT RELIABLY RETURN TO THE INSTRUCTION IT INTERRUPTED.~~ IT DOES. THE
DERAIL WAS AN ARTEFACT OF `--inject`.** jnext's `Emulator::inject_binary`
(`src/core/emulator.cpp:6683-6726`) sets PC, SP and IFF1/IFF2 and **never clears the CPU's HALTED
flag**. NextZXOS idles in a `halt`, so an injected program inherits `halted = 1`; running DI'd it
can never clear it, because FUSE clears that flag only in an interrupt or NMI acknowledge. The
**first** NMI then takes jnext's `z80.halted ? pc + 1 : pc` branch
(`src/cpu/z80_cpu.cpp:636`) and captures the interrupted PC **plus one**.

So exactly one return — the first — landed a byte late, and eight NOPs either side were simply wide
enough to absorb it. The "18132 iterations across ~400 NMIs untouched" was not the padding
suppressing a recurring fault; it was the program surviving a single one-off.

**Proved by removal**, on `main`'s own ROM, one three-byte prologue apart and nothing else changed:
with `ei : halt : di` (one maskable interrupt clears the flag) a `jr $` under this Copper list is
returned to **402 times out of 402**; without it, the same loop derails on its first NMI and the
latch reads `0x9001` for an interrupted PC of `0x9000`. The **stackless enable makes no difference**
— with NR `0xC0` bit 3 cleared, so that the NMI pushes onto the program's own stack, the derail is
byte-identical, which is what rules the stackless machinery out rather than arguing it out.
T9's fixture carries the prologue and no padding. The `--inject` defect is jnext's and is written up
for filing; nothing here depends on it being fixed.

### A LIMITATION NOBODY HAD WRITTEN DOWN, AND IT ANSWERS THE PLAN'S OPEN QUESTION 5

**Any live DivMMC automap session blocks every Multiface NMI, the poll included, for its whole
duration.** `zxnext.vhd:2107` accepts one only `if nmi_assert_mf = '1' and port_e3_reg(7) = '0' and
divmmc_nmi_hold = '0'`, and `divmmc_nmi_hold` is DivMMC's `o_disable_nmi <= automap or button_nmi`
(`device/divmmc.vhd:150`), where `automap` is asserted for the whole time `automap_held = '1'`
(`:148`). That is not merely the esxDOS NMI menu: it is **any** esxDOS file-I/O call, any dot
command, any `RST 8` trap window. The same gate applies while CONMEM is held (`port_e3_reg(7)`,
`:4181`), which is `.mfinstall`'s config-mode window.

Requests are dropped rather than queued (`:2095-2116`), so each lost poll simply retries next frame
— but **a debuggee sitting inside a long esxDOS call cannot be paused until it comes out**, and
nothing in software can see this happen, because `nmi_mf` never latches and `nmi66h` never runs.

The mirror case: a DivMMC (drive) button press landing while our handler executes is dropped, since
`nmi_assert_divmmc` is accepted only `and mf_is_active = '0'` (`:2109`). Our handler is short, so the
exposure is small — but it is per frame.

**Memory state is not at risk in either direction**, and that was checked rather than assumed: while
`mf_mem_en = '1'` the priority arbiter sets `sram_pre_override <= "000"` so DivMMC automap cannot
newly trigger (`:3029-3036`, `:3137`), a pre-existing `automap_held` self-holds unchanged, and
`divmmc_retn_seen <= z80_retn_seen_28 and not mf_is_active` (`:4111`) means our own exit RETN is
deliberately not seen by DivMMC as its own.

**None of this has been observed running.** It is read from the VHDL, and no run anywhere stages a
poll landing inside a DivMMC automap window.

---

**Verdict (2026-08-08, before the build): it can be done, and it should be OPT-IN rather than
default.** The mechanism works and is already proven headless. What the plan understates is the
price: enabling asynchronous break **destroys** any Copper program the debuggee had, irrecoverably,
and the debuggee can switch the break off by accident in a way nothing can recover from without a
human pressing the M1 button.

*(**ANNOTATED 2026-08-10**: the destruction half is moot as built — §0. "Opt-in" survives in a
different and better form: it is opt-in in the debuggee, which is where the two instructions live.)*

Everything below about hardware is read from the FPGA VHDL with line citations, per this project's
first hard rule. Everything about the stub is read from `src/`. Where something is an estimate or a
design opinion it says so.

---

## User story — a Pause click, end to end

**NONE OF THIS HAS BEEN BUILT.** No M2 code exists, so what follows is a walkthrough of the design
in §2-§5, not a description of working code. Read it as *what would happen*. Every step is either
cited to the VHDL or to `src/` — which describe what exists **today**, before M2 touches it — or is
marked as a decision M2 has not made. §6's list of what this document does not establish governs
this section as much as the rest, and two of the twelve steps below are open rather than settled.

### Before anything runs: what opting in costs

The stub installs a two-instruction Copper program (§2, §4.4):

```
WAIT line,N        ; N is the raster line; not fixed anywhere here.
MOVE $02,$08       ; NR 0x02 bit 3 = generate Multiface NMI. T5's fixture uses line 100.
```

**That is destructive, and it is why the feature is opt-in rather than default.** The Copper's
1024-instruction list is write-only — both instruction RAMs discard their CPU-side read output
(`zxnext.vhd:3959-3976`, `:3980-3998`) and NR `0x60`/`0x63` have no read decode (`:6286-6287`) — so
the debugger cannot save and restore whatever the debuggee had there. Installing this destroys it,
irrecoverably, for the rest of the session. §3.1 has the full argument, including the escape hatch:
a Copper-using program can carry these two instructions in **its own** list instead.

### The walkthrough

1. **The user clicks Pause in VS Code.** DeZog sends `CMD_PAUSE` — command 7 — over TCP to
   `<next-ip>:11000`.

2. **It crosses the WiFi link to the ESP-01**, which emits `+IPD,<id>,<len>:` and the frame on its
   UART TX line.

3. **The bytes land in UART0's Rx FIFO** — *"Both uarts have a 512 byte Rx buffer and a 64 byte Tx
   buffer"* (`serial/uart.vhd:24`). **Nothing is reading them.** The debuggee owns the CPU and
   the debugger is not executing between polls, which is exactly why a byte cannot wake anything by
   itself — §1.

4. **Meanwhile, 50 times a second, the Copper reaches line N and executes `MOVE $02,$08`.**

5. **The FPGA turns that into an NMI.** The write raises `nmi_gen_nr_mf` (`zxnext.vhd:3832`), which
   sets the latch `nr_02_generate_mf_nmi` (`:3840-3851`) and reaches `nmi_assert_mf` — ANDed there
   with **NR `0x06` bit 3** (`:2090`), the gate that catches every Multiface NMI source. Its
   power-on value is `'0'`, but NextZXOS leaves it set (§3.2), so a guest inherits it. The Z80
   samples `/NMI` at an instruction boundary (`cpu/t80n.vhd:1663-1669`, `:1765`).

6. **The NMI is taken, and the return address does not go on the debuggee's stack.** In stackless
   mode it lands in NR `0xC2`/`0xC3` instead — the plan's §3.4, which is where that mechanism is
   documented rather than here. MF ROM pages in at `0x0000` and MF RAM at `0x2000`
   (`zxnext.vhd:3029-3035`), and execution starts at `0x0066`.

7. **`nmi66h` runs — the routine M2 has to change.** Today it reads NR `0x02`, masks `00011100b`
   and returns unless the result is zero: button causes only, which bench **T4** asserts. M2 teaches
   it to accept a software cause and ~~**inverts T4 in the same change**~~ — **it did not need to;
   see §0** (§4.1).

   It also needs a **fast path**, not a widening of the existing one. The current entry runs **82
   instructions** before the dispatch decides anything — saving the NextREG select, reading and
   changing the turbo mode, polling the keyboard for Symbol Shift, comparing six magic bytes.
   Reasonable once per button press; wrong 50 times a second.

8. **Is a debuggee running?** Answered from a flag in **MF RAM**, because the decision has to happen
   *before* `MAIN_BANK` is paged in and so cannot live in the debugger's own bank. MF RAM is
   addressable throughout `nmi66h` and costs no ROM bytes — the same reasoning that put
   `MF.nmi_slot7` there for issue #26 (§4.1).

9. **`MAIN_BANK` is paged into slot 7 and the FIFO is polled.** `transport_byte_available` is O(1)
   in the UART build and, in the ESP build, gates its expensive `+IPD` scan behind the same O(1)
   check (§4.3).

   9a. **Empty — the common case, ~50 times a second.** Clear the NMI cause latch and return. **Two
   traps, both of which have bitten this project already.** NR `0x02`'s bits 1:0 *written* trigger a
   reset (`zxnext.vhd:6370-6371`) while *read* they are reset history (`:1306`, `:1732-1739`), so a
   read-modify-write would reset the machine 50 times a second — upstream's `and 10000000b` mask is
   what prevents it and **must not be lost** (§3.4). And the exit **must restore MMU slot 7**,
   unlike the existing immediate return, which deliberately does not because it only ever runs while
   the debugger itself is executing. Getting that wrong is issue #26 again (§4.2).

   9b. **Non-empty — the Pause has arrived.** The full entry path runs:
   `save_nmi_return_address` reads the PC back out of NR `0xC2`/`0xC3` (`src/mf.asm`), registers are
   saved, and per §4.4 the Copper list is stopped on the way in.

10. **The break is reported.** `send_ntf_pause` (`src/message.asm:325`) sets `prgm_state` to
    `PRGM_STOPPED` and writes `NTF_PAUSE`; VS Code shows the program stopped, with PC and registers.

11. **What becomes of the `CMD_PAUSE` itself is NOT settled here.** The shape the design implies is
    the one the M1 button path already produces — notification first, then `cmd_loop` reads the
    pending command and answers it with the Length=1 response the specification requires, since
    `mf_nmi_button_pressed` sends the notification and falls straight into `cmd_loop`
    (`src/mf.asm`). **Two things stop that being a settled sequence, and each is M2 work rather than
    a detail:**

    - **The existing break path drains the link immediately before notifying.**
      `mf_nmi_button_pressed` calls `transport_drain` — discard everything until 100 ms of quiet
      (`src/transport_uart.asm:174`) — and then `send_ntf_pause`. That is right for a *button*
      press, where there is no pending command and junk on the link should go. **Reused unchanged
      for an asynchronous break it would discard the very `CMD_PAUSE` that caused the break**, and
      DeZog would block on a response that never comes.
    - **Whether the command is still in the FIFO at all depends on §4.3's open question.** "Break on
      any byte" leaves it there for `cmd_loop` to read normally. "Parse first, break only on a real
      command" has already consumed at least the header inside the NMI handler, so something has to
      carry the partly-read frame across into `cmd_loop`.

12. **The user inspects, sets breakpoints, hits Continue.** `CMD_CONTINUE` resumes as it does from a
    breakpoint today, **plus one thing that is new**: §4.4 puts installing the Copper list on the
    resume path, so it goes back in here — having come out at step 9b.

### What `cmd_pause` has to become

Today `cmd_pause` (`src/commands.asm`) answers with the Length=1 response and does nothing else, and
issue #8 made that deliberate: it is only ever reached from `cmd_loop`, which runs only while the
debugger is stopped; writing `prgm_state` would clobber `PRGM_LOADING` and break the next
`cmd_continue`'s "loading finished" branch; and it sends no `NTF_PAUSE`, because that notification
reports a *transition* and none happens there.

**Asynchronous break overturns none of that, and the reason is worth stating precisely.** The break
is caused by the **poll**, not by the handler. By the time `cmd_loop` reads command 7 the machine is
already stopped and the transition has already been reported by whoever caused it — step 10. So
`cmd_loop` still runs only while stopped, there is still nothing for `cmd_pause` to pause, and both
of #8's prohibitions hold for exactly the reasons #8 gives them.

**What M2 must change is the handler's own comment, which asserts the opposite in as many words**:
*"while the debuggee runs nothing polls the link and no command can be received at all"*. That is
true today and is precisely what M2 makes false. Left standing, it would tell the next reader that
the command cannot arrive in the state M2 was built to create.

### What it costs in time

**Arithmetic, not a measurement.** The poll fires once a frame, so the wait from byte-in-FIFO to
break is **up to ~20 ms** — one frame at the 50 Hz this document assumes throughout. On top of that
sits the WiFi round trip, **measured** at a median of 11.2 ms on a real Next
([HARDWARE-TESTING.md](HARDWARE-TESTING.md), H4). So a Pause click should stop the machine in a few
tens of milliseconds. The 11.2 ms is real; the sum is not, and nothing has run.

**The running cost is an estimate nobody has measured**, and §5 says so at length: the plan's
~100-200 T-states/frame (≈0.3%). Two things make a naive figure misleading — part of the entry runs
at the **debuggee's** clock before the handler switches to 28 MHz, and that switch happens 50 times
a second, which is a different kind of perturbation from stolen cycles for anything doing
contended-memory or beeper timing. **M2 measures it rather than inheriting it.**

### Three ways it stops working, and one has no recovery

**The debuggee can switch the break off silently, and nothing can put it back.** Clearing NR `0x06`
bit 3 kills every Multiface NMI source. And a write of NR `0x62` that **changes** the mode bits
restarts our list from index 0 — the guard is `last_state_s /= copper_en_i`, with the pointer reset
sitting inside a further test for a new mode of `"01"` or `"11"` (`device/copper.vhd:69-78`) — while
mode `"00"` stops it outright and a write carrying the **same** mode leaves the pointer alone.
Writing list content through NR `0x60` overwrites ours regardless of the mode. The obvious
mitigation, re-asserting from the poll, **cannot work**: once the Copper stops, the poll is the
thing that would have re-asserted it. Recovery is an M1 press — the button the feature exists to
remove. §3.2.

**A second NMI arriving while the handler runs is dropped, not queued** (`zxnext.vhd:2095-2116`,
`:2164`). Harmless for a periodic poll, since the next frame's fire serves — but the handler's
duration directly reduces the poll rate. §5.

**Config mode suppresses the poll entirely while it is active** (`zxnext.vhd:2102-2105`,
`:2156-2157`), and `.mfinstall` opens that window three times per install. Self-recovering — the Copper
keeps running and the next frame's fire is accepted — so the cost is a poll or two missed, not a
dead break. §5.

### Two decisions still open, and the first of them decides steps above

**What counts as "traffic"?** When the FIFO is non-empty the ESP build may spend up to ~100 ms
synchronising, inside an NMI, with the debuggee stopped. If what arrived was a real command that is
fine — we are about to break anyway. If it was one of the module's unsolicited lines
(`<id>,CONNECT`, `<id>,CLOSED`) it is 100 ms stolen from the debuggee for nothing, or, if the
handler breaks on any traffic rather than parsing, a **spurious break the user did not ask for**.

Break on any byte, or parse first? Both have a visible cost, §4.3 records the decision as unmade,
and it is what settles step 11's second bullet as well as step 9b's shape.

**And nothing has chosen the break reason step 10 reports.** `BREAK_REASON` holds only `NO_REASON`,
`MANUAL_BREAK` and `BREAKPOINT_HIT` (`src/breakpoints.asm:18-20`), so a poll-triggered break would
report `MANUAL_BREAK` and be **indistinguishable from an M1 press to the client** — DZRP offers no
third reason. Whether that is acceptable, or wants one, is unmade.

### Why the design is shaped around a poll rather than a cause

**You cannot tell a Copper-caused NMI from a CPU-caused one — ever.** Both are muxed onto one
untagged bus before `nmi_gen_nr_mf` computes (`zxnext.vhd:4775-4777`), and the latch it feeds is a
single bit; nothing anywhere records a source. That was the plan's open question 5b, and the answer
is that it is unanswerable.

**But a poll-shaped handler does not need to know.** If the contract is *"poll, and break only if
there is traffic"*, a debuggee's own write to NR `0x02` costs exactly one wasted poll that returns
immediately. That reframing is what makes the impossibility stop mattering, and it is why every step
above is built around the poll. §3.3.

---

## 1. What asynchronous break is for

`dezogif`'s headline limitation is that you cannot pause a running program from the PC — you must
walk over and press the M1 button. In WiFi mode the machine is on the network, so the button is the
only thing left that needs a person in the room. M2 removes it: DeZog's Pause sends `CMD_PAUSE`, the
byte lands in UART0's RX FIFO, and *something on the Next has to notice*.

The debugger is not executing while the debuggee runs, so noticing requires an interrupt the
debuggee cannot be relied upon to permit. That is the whole problem, and it is why the answer is an
NMI rather than the UART's own IM2 interrupt.

---

## 2. The mechanism, and why there is no alternative

A two-instruction Copper list — `WAIT line,N` then `MOVE $02,$08` — raises a Multiface NMI at a
chosen raster line, every frame, with **no CPU involvement and no dependence on the debuggee's
interrupt mode**. The handler polls the RX FIFO and returns immediately if there is nothing to do.

**This is the only such mechanism on the machine.** Every candidate was traced to where it lands:

| candidate | where it ends up | usable as a periodic poll? |
|---|---|---|
| Copper `MOVE` to NR `0x02` bit 3 | `nmi_gen_nr_mf` → `nmi_sw_gen_mf` → `nmi_assert_mf` (`zxnext.vhd:3832`, `:3837`, `:2090`) | **yes** |
| M1 button | `hotkey_m1`, from top-level pin `i_SPKEY_FUNCTION(9)` (`zxnext.vhd:6348`, `:69`) | no — manual |
| I/O trap on `0x2FFD`/`0x3FFD` | gated on an actual `iord`/`iowr` cycle (`zxnext.vhd:2723-2725`) | no — fires on a debuggee *access*, not on time |
| UART RX interrupt | `im2_int_req` (`zxnext.vhd:1941-1944`) — the **maskable** INT bus | no — needs the debuggee's IM2 setup |
| **line / raster interrupt** (NR `0x22`/`0x23`) | `line_int_pulse` → `im2_int_req` (`zxnext.vhd:1944`) | **no — never reaches NMI**, checked specifically |
| DMA / CTC interrupt enables | `im2_int_en` / `im2_dma_int_en` only | no |
| expansion-bus NMI | `i_BUS_NMI_n`, a physical pin (`zxnext.vhd:2089`, `:202`) | no — needs external hardware |

`nmi_activated` has exactly three inputs — `nmi_mf`, `nmi_divmmc`, `nmi_expbus` (`zxnext.vhd:2093`)
— and their set conditions are the complete list above (`:2107-2112`). So the Copper is not merely
the *best* option; it is the only one, and a design that finds the Copper cost unacceptable has no
fallback to retreat to.

**It is already proven.** `test/copper_nmi.asm` is bench check **T5**: the list above raises the
Multiface NMI at line 100 under jnext and the stock Multiface monitor takes the screen, 91.41%
repainted. The encoding is read from `device/copper.vhd:91-104`, not from a wiki.

---

## 3. The costs, in descending order of how much they should change the plan

### 3.1 The Copper list is WRITE-ONLY, so the debuggee's program is destroyed, not borrowed

**ANNOTATED 2026-08-10: THIS SECTION'S FACTS ALL HOLD AND ITS CONCLUSION IS MOOT.** The list really
is write-only and really cannot be saved and restored — every citation below stands. What the build
changed is who writes it: the debugged program does, so the debugger destroys nothing and the
"cannot be debugged with asynchronous break enabled" consequence does not arise. The escape hatch at
the end of this section became the primary route. See §0.

The plan says async break "consumes the Copper, which the debuggee may want". That is too gentle.

Both Copper instruction stores are `dpram2` instances whose CPU-facing read output is **discarded at
the top level** — `data_a_o => open` on the MSB store (`zxnext.vhd:3959-3976`) and on the LSB store
(`:3980-3998`). The NextREG read multiplexer has no `when X"60"` and no `when X"63"` entry at all,
so a read falls through to `when others => port_253b_dat <= (others => '0')` (`zxnext.vhd:6286-6287`).
The Copper's own execution pointer, `copper_instr_addr`, is consumed only as the RAM's read address
and reaches no readable register.

**So there is no path, through any port or register, by which the Z80 can read back the 1024
instructions.** The same asymmetry this project already found on the sprite upload ports `0x57` and
`0x5B` — and just as easy to miss, because `ram/dpram2.vhd:51,93` *does* provide a port-A read output;
it is the instantiation that throws it away.

**Consequence:** the debugger cannot save and restore a debuggee's Copper program. Installing our
two instructions over it is irreversible for the rest of that session. A Next program that uses the
Copper for raster effects — an ordinary thing — **cannot be debugged with asynchronous break
enabled**. This is the single strongest argument for the feature being opt-in.

**Partial mitigation, and it is genuinely partial.** NR `0x61` and NR `0x62` *do* read back
(`zxnext.vhd:6083-6087`), giving the mode bits and the address MSBs. But `nr_copper_addr` is the
**CPU-side load pointer** used when writing the list through NR `0x60`/`0x63`
(`zxnext.vhd:5418-5437`), not the running program counter. So the debugger can restore *whether* the
Copper was enabled and *in which mode*, and nothing about what it was running.

**The escape hatch worth offering users.** The two instructions do not have to come from the
debugger. A developer whose program uses the Copper can put `WAIT line,N` / `MOVE $02,$08` into
**their own** list, at a raster position of their choosing, and get asynchronous break at the cost of
a source change rather than losing the Copper entirely. That should be documented as the supported
route for Copper-using programs rather than left for someone to discover.

### 3.2 The debuggee can switch the break off silently, and the stub cannot get it back

**ANNOTATED 2026-08-10: LARGELY DEFUSED BY THE BUILD, BUT NOT ENTIRELY.** A program that installs its
own list also restarts its own list, so the NR 0x62 half is now the program's business rather than a
thing done to it behind its back. The NR 0x06 bit 3 half survives untouched: a debuggee that clears
that gate still kills its own break with no way for the stub to notice or restore it, because the
poll is what would have noticed.

Two independent ways, and the second is worse than it looks:

- **NR `0x06` bit 3** gates *every* Multiface NMI source, the Copper one included
  (`zxnext.vhd:2090`; written at `:5166`, power-on `'0'` at `:1110`). NextZXOS leaves it set, measured
  2026-08-04, so a guest inherits it — but a debuggee may clear it.
- **NR `0x62`, whenever the mode bits CHANGE.** `device/copper.vhd:69-78`: the guard is
  `if last_state_s /= copper_en_i`, and inside it the pointer is reset only when the *new* mode is
  `"01"` or `"11"`. So a debuggee that switches the Copper to a different running mode silently
  restarts our list from index 0, and mode `"00"` stops it outright — while a write of NR `0x62`
  carrying the **same** mode (re-asserting the address bits, say) leaves the pointer alone.
  Writing the list content through NR `0x60` overwrites ours in place regardless of the mode.

**The bootstrap problem is the real finding.** The plan's mitigation for NR `0x06` bit 3 is to
"re-assert from the poll". That cannot work for the Copper case and cannot work for either case once
the mechanism has actually stopped: **if the Copper is not running, the poll does not run, so there
is nothing left executing that could put it back.** Once a debuggee stops the break, only a human
pressing M1 restores it.

So the honest statement is: asynchronous break is **best-effort**. It works until the debuggee does
something that turns it off, at which point it fails **silently** — the PC's Pause simply does
nothing — and recovery needs the button the feature exists to eliminate. That belongs in the user
documentation, not only here.

### 3.3 A CPU-caused and a Copper-caused NMI are indistinguishable — and the design must not care

**This is the plan's open question 5b, and the answer is that you cannot tell them apart, ever.**

`zxnext.vhd:4775-4777` is the load-bearing line, and it had not been cited in this project before:

```vhdl
nr_wr_en  <= copper_req or cpu_req;
nr_wr_reg <= copper_nr_reg when copper_req = '1' else cpu_nr_reg;
nr_wr_dat <= copper_nr_dat when copper_req = '1' else cpu_nr_dat;
```

CPU and Copper writes are muxed onto one bus with no tag carried through. By the time
`nmi_gen_nr_mf` computes (`zxnext.vhd:3832`) it is an OR of two mutually exclusive pulses into one
wire, and that wire is the only thing reaching the latch `nr_02_generate_mf_nmi` (`:3840-3851`),
which is a single untagged bit. Nothing else records a source: NR `0xDA`'s `iotrap_cause`
distinguishes only among I/O-trap sub-causes (`:3866-3883`); NR `0xC0` carries IM2/stackless
configuration only; `nmi_state` is internal with no port; and inside `device/multiface.vhd` the input
is called `button_i` but is fed from `nmi_mf_button`, which is asserted for **any** accepted
Multiface NMI (`zxnext.vhd:2169`) — a naming trap worth knowing about.

**Why this does not block M2.** The question assumed the handler needs to know. It does not, if the
handler's contract is *"poll, and break only if there is traffic"*. A debuggee that writes NR `0x02`
bit 3 itself then costs exactly one wasted poll, which returns immediately. Design the entry path
around the poll rather than around the cause and the impossibility stops being relevant.

(NR `0x10` bit 0 is the raw, live M1 button pin — `zxnext.vhd:5923-5924` — and is the only
source-adjacent thing readable. It can corroborate "this was a button press", because a button NMI
never touches `nr_02_generate_mf_nmi` at all. It does nothing for Copper-versus-CPU.)

### 3.4 A landmine on the exit path: NR `0x02`'s bits mean opposite things read and written

The handler must clear the cause latch on the way out, or the next frame's write is not seen as a new
event. The clear is a write of NR `0x02` with bit 3 low (`zxnext.vhd:3847-3848`), and one write with
bits 4, 3 and 2 low clears the I/O-trap, Multiface and DivMMC latches together (`:3847`, `:3860`,
`:3879`). It is **not** gated by `nmi_accept_cause`, so it can happen at any point in the handler,
and nothing about `RETN` clears it automatically.

**But bits 1:0 are a trap.** Written, they *trigger* a soft or hard reset
(`zxnext.vhd:6370-6371`). Read, they are `nr_02_reset_type`, a reset-history shift register
(`:1306`, `:1732-1739`) which is **non-zero in ordinary operation** after any reset has occurred. So
the obvious "read it, modify my bit, write it back" pattern **resets the machine**.

Upstream's existing non-button path survives only because of its mask:

```asm
    in a,(c)        ; Read again
    and 10000000b   ; Preserve esp/expbus bit
    nextreg REG_RESET,a
```

`src/mf_rom.asm` — the `and 10000000b` is what forces bits 1:0 to zero. **That mask is load-bearing
and M2 must not lose it.** Prefer a literal constant over a read-modify-write here.

---

## 4. What M2 has to build

### 4.1 The entry path

`nmi66h` reads NR `0x02`, masks `00011100b` and returns unless the result is zero — it serves button
causes only, which is why bench **T4** asserts that our stub *declines* a software NMI. M2 must teach
it to accept a software cause, and ~~**invert T4 in the same change**, deliberately~~ — **ANNOTATED
2026-08-11: it did not, and the prediction was wrong rather than the change incomplete.** The poll
accepts the cause and then declines unless our image is in `MAIN_BANK` and a debuggee is running,
neither of which holds in T4's run, so T4's verdict is unchanged and only its reason moved. §0.
T4 and T6 send
different causes to the same check, so both stay; T4 becomes the assertion that the software cause is
now *taken*.

**A fast path is needed, not a widening of the existing one.** The current entry runs **82
instructions** before the dispatch decides anything — it saves the NextREG select, reads and changes
the turbo mode, polls the keyboard for Symbol Shift, and compares six magic bytes. That is
reasonable once per button press and wrong 50 times a second. The poll needs its own short route:
cause check, page in `MAIN_BANK`, check the FIFO, and get out.

**The state it needs already exists.** Whether a debuggee is running has to be decided *before*
`MAIN_BANK` is paged in — so it cannot be `prgm_state`, which lives in that bank. A flag in **MF
RAM** answers it: MF RAM is addressable throughout `nmi66h` and costs no ROM bytes, which is the same
reasoning that put `MF.nmi_slot7` there for issue #26.

### 4.2 The exit path is NOT the existing immediate return

`mf_nmi_button_pressed_immediate_return` restores the NextREG select, the turbo mode and the
Multiface paging — and deliberately **not** MMU slot 7, because it only ever runs when the debugger
itself is executing and slot 7 legitimately holds `MAIN_BANK`.

**M2's poll fires while the DEBUGGEE is executing**, so its return must put the debuggee's bank back.
Getting that wrong is exactly issue #26: a return into a context whose slot 7 you clobbered, which on
real hardware produced a machine that locked up shortly afterwards. The value needed is already
saved — `MF.nmi_slot7`, written on every NMI entry since #26's second fix.

### 4.3 The poll itself

`transport_byte_available` is O(1) in the UART build (one status read) and, in the ESP build, gates
its expensive `+IPD` scan behind the same O(1) FIFO check (`src/transport_esp.asm`). So the quiet
case — which is almost every frame — is cheap in both.

**The un-quiet case needs a decision that has not been made.** When the FIFO is non-empty the ESP
build may spend up to ~100 ms synchronising, inside an NMI, with the debuggee stopped. If the byte
was a real command that is fine, because we are about to break anyway. If it was one of the module's
unsolicited lines (`<id>,CONNECT`, `<id>,CLOSED`) it is 100 ms stolen from the debuggee for nothing —
or, if the handler breaks on any traffic rather than parsing, a **spurious break** the user did not
ask for. Choosing between "break on any byte" and "parse first, break only on a command" is M2's
design decision and both have a visible cost.

### 4.4 Installing and removing the list

The stub writes the list through NR `0x61`/`0x62`/`0x60` when it resumes a debuggee and stops it when
it breaks back in. NR `0x62` bits 7:6 start it (`01` = run from index 0 and loop). Nothing in `src/`
touches the Copper today — greped, no hits — so M2 owns it outright with no existing behaviour to
preserve.

### 4.5 Byte budget — not a blocker, and an earlier claim of ours was wrong

`mf_nmi.bin` is `ALIGN 16`-ed and, since #26, exactly full at 320 bytes. **This project recorded on
2026-08-07 that the MF ROM half therefore "cannot grow". That is wrong**, and was corrected by
experiment on 2026-08-08: adding 16 bytes and moving `ROM_MAGIC_ADDR` down by the same 16 builds
clean, keeps the ROM at 8192 bytes, and leaves the identity block readable at file offset `0x1FE0`.

The permanent contract is the **file offset**, which is what `tools/mfselect/mfselect.c` parses — not
the address. `main.asm`'s `ASSERT` enforces exactly the relationship that preserves it, so the
failure mode is a build error rather than a silently misplaced block. The half grows in 16-byte
quanta at the cost of one constant.

**THE SECOND HALF OF THIS PARAGRAPH WAS WRONG UNTIL 2026-08-09, IN THE DIRECTION THAT MATTERS TO
M2.** It said the debugger half "has over a kilobyte of headroom in the tighter WiFi build — many
such steps". It had **119 bytes**.

`main_bank_entry` used to copy the 0x300-byte ZX font into the top of the debugger's bank at
`0xFD00 - MF.main_prg_copy` = `0xFBC0`, so the usable region really ended 736 bytes below
`ROM_MAGIC_ADDR`. **Nothing in the source emitted a byte there**, so the assembler could not see the
collision, and growth past it silently aliased the debugger's variables onto the glyph bitmaps —
issue #31, which is what the 460800 screen artefacts were.

**Issue #31 removed the buffer rather than guarding it**: the glyphs are read live from the ROM, so
the bank got its top 768 bytes back. Measured now: **WiFi 818 bytes free, UART 3201.** What is
*unchanged* is that a 16-byte step of the MF ROM half still spends 16 of them, because the image
ends at `0xE000 + 0x2000 - MF.main_prg_copy` and `ROM_MAGIC_ADDR` moves down with it. **The two
halves share one budget**, and 818 is the number M2's §4.1 fast path and its slot-7-restoring exit
have to fit inside together in the WiFi build.

One thing M2 inherits from that fix: printing now depends on MMU slot 1 and on NR `0x8C`'s Alt ROM
half, held open by `text.font_map` / `text.font_unmap`. **A poll-shaped handler that paints anything
must hold that window too** — and must give slot 1 back, which is bench check N7.

---

## 5. Timing, collisions and cost

**Deterministic.** In repeat mode the list pointer is forced to 0 at `vcount=0, hcount=0` every frame
(`device/copper.vhd:80-83`), and `WAIT` releases when `vcount = line` and
`hcount >= hpos*8 + 12` (`:91-104`). Same raster position every frame. The only jitter is ordinary
Z80 NMI latency — `/NMI` is sampled at instruction boundaries (`cpu/t80n.vhd:1663-1669`, `:1765`) —
which is not Copper-specific.

**Collisions are dropped, never queued.** A new `nmi_mf` is latched only while `nmi_activated` is
`'0'` (`zxnext.vhd:2095-2116`), and `nmi_accept_cause` is false outside `S_NMI_IDLE`/`S_NMI_FETCH`
(`:2164`). A Copper fire while the handler is still running is simply lost, with no makeup event.
Harmless for a periodic poll — the next frame's fire serves — but it means the handler's duration
directly reduces the poll rate, and a handler that ran longer than a frame would poll at half rate or
worse.

**CONFIG MODE SUPPRESSES THE POLL WHILE IT IS ACTIVE, and this repository already ships a tool that
uses config mode.** `zxnext.vhd:2102-2105` clears `nmi_mf`/`nmi_divmmc`/`nmi_expbus` continuously for
as long as `nr_03_config_mode = '1'`, and `:2156-2157` forces `nmi_state` back to `S_NMI_IDLE` — this
was established for the *button* case in
[CONFIG-MODE-ROM-REPLACEMENT.md](CONFIG-MODE-ROM-REPLACEMENT.md) §1.5 and applies identically to a
Copper-sourced pulse, which nothing had connected until now. `.mfinstall` opens that window **three
times** per install — two 4 KB passes (`tools/mfinstall/mfinstall.c:558`) plus the identity read that
makes the "Live ROM:" line accurate (`:880`), as MEMORY.md's 2026-08-06 entry records — and
NextZXOS's own boot ROM load uses it too, so a `MOVE $02,$08` landing inside one is silently lost
with no makeup event.

It is **self-recovering** — the Copper keeps running, `.mfinstall` never touches NR `0x60`-`0x64`, and
the next frame's fire is accepted — so the consequence is a poll or two missed, not a dead break. It
is recorded because "deterministic, and the only jitter is Z80 NMI latency" would otherwise be read
as stronger than it is. It is **adjacent to, and not a substitute for, the plan's still-open question
5** (does the poll interact badly with esxdos's NMI menu or DivMMC automap?), which remains
unanswered.

**MEASURED 2026-08-11, AND THE ESTIMATE WAS 6-13 TIMES TOO LOW.** `make measure-poll-cost`
(`test/copper_cost.asm`, `test/run-poll-cost.sh`): a fixed-length counting loop, two builds
differing in **one** assembler constant — the Copper list started or not — with HL snapshotted at
two frame counts and the difference taken, so the fixture's start-up and the snapshot's overhead
cancel and the shortfall is attributable to the polls alone.

| | |
|---|---|
| loop rate without the poll | 3912.1 iterations/frame |
| loop rate with it | 3903.1 iterations/frame |
| **cost** | **0.230% of a frame, ≈1288 T-states per frame** |
| clock | **28 MHz**, read off the machine (NR 0x07 = 0x33), not assumed |

Bit-identical across three runs. **The 28 MHz is a measurement and the 3.5 MHz figure is
ARITHMETIC**: the same ~1288 T-states is **1.84%** of a 3.5 MHz frame, because the poll runs at
whatever clock the debuggee is running at and a 50 Hz frame holds eight times fewer T-states there.
That is the number a contended-memory, tape or beeper program actually pays.

**So the plan's ~100-200 T-states/frame (≈0.3% at 3.5 MHz) is wrong in both halves** — six to
thirteen times low in T-states, and its percentage happened to look right only because it was
quoted against the slow clock while the real cost is a much bigger absolute number. Corrected in
`doc/ZXNEXT-REMOTE-DEBUG-STUB.md` §10 and Appendix A, annotated rather than rewritten.

**WHAT THE FIGURE DOES NOT COVER.** It is the **decline** path only: no client is attached, so
every poll answers "quiet" and returns. A poll that breaks in costs the whole entry path, which is
a much larger number paid once rather than per frame, and nothing measures it. It is jnext rather
than silicon — legitimate here, because jnext counts the same T-states a Next does, and that is the
same entitlement the baud ceiling rests on (MEMORY.md 2026-08-09) — but no Next has run any of M2.
And **the poll is still not disableable**, which the original text below asked for.

The original text follows, for the record.

> **Cost is an estimate, not a measurement.** The plan's ~100-200 T-states/frame (≈0.3%) is plausible
> for a fast path but has never been measured, and the current entry path is far larger than that. Two
> things make a naive figure misleading: part of the entry runs at the **debuggee's** clock before the
> handler switches to 28 MHz, and the switch itself happens 50 times a second, which is a perturbation
> of a different kind from stolen cycles for anything doing contended-memory or beeper timing.
> **Measuring this belongs in M2, and the poll should be disableable.**

*(One clause of that is worth keeping rather than filing as superseded: the poll as built **does
not** switch the clock unless it breaks in — §0 — so the "speed change 50 times a second"
perturbation it warns about does not arise. What the 1288 T-states buys is stolen cycles and
nothing else.)*

---

## 6. What this document does NOT establish

**ANNOTATED 2026-08-10: the first bullet is overtaken and the rest are not.** M2 is built and runs
in the emulator — bench T9 and W8 — so "nothing here has run" is false. Everything else in this list
survives, and §0 adds three items to it: the reported PC (a standing red), the software-NMI
mis-return, and the DivMMC automap block, none of which has run on hardware either.

- ~~**Nothing here has run.** No M2 code exists.~~ Built 2026-08-10; see §0.
  ~~Every hardware claim is still VHDL rather than silicon, and **no part of M2 has run on a real
  Next.**~~ **IT HAS, 2026-08-11 — bench check H7 on the user's own Next, and it passed with its
  control.** A freely running debuggee, resumed with no breakpoint, was stopped by `CMD_PAUSE`; the
  `PC` came back at the fixture's spin and the `SP` at the fixture's own stack. So the Copper really
  does raise a Multiface NMI at 50 Hz on silicon (T5 and T9 are the emulator's), the poll really
  does serve the software cause there, and NR `0xC0` read `0x0A` — **the stackless branch of
  `save_nmi_return_address`, established on hardware** rather than in the emulator alone. What is
  still VHDL rather than silicon is everything in §0's limitation list, and the poll's per-frame
  cost has never been measured on a Next at any clock.
- ~~**The cost figure is unmeasured**, see §5.~~ **Measured 2026-08-11** — §5. What remains
  unmeasured is the cost of a poll that BREAKS IN, and anything on hardware.
- ~~**The unsolicited-line decision in §4.3 is unmade**~~ — made: break on any byte, §0. Its
  user-visible consequence stands and nothing stages it: no run here makes the module emit an
  unsolicited line while a debuggee is running.
- **jnext's Copper model has not been checked against this document.** T5 shows the NMI path works;
  nothing here confirms the emulator reproduces the NR `0x62`-restarts-the-list behaviour of
  `device/copper.vhd:69-78`, which is what §3.2's silent-failure claim rests on. A bench for M2 needs
  that to be true, or the failure mode cannot be tested headless.
- **DMA as a third writer of NR `0x02` was not traced.** If a debuggee's DMA channel could target it,
  it would land on the same undifferentiated bus as CPU and Copper. Nobody has raised it; noted so
  that the enumeration in §3.3 is not read as more exhaustive than it is.
- **No hardware.** Everything about a real Next remains to be seen, and this project has twice been
  caught by jnext sitting on the safe side of reality.
- ~~**Nothing has driven this from DeZog itself.**~~ **DeZog drove it on a real Next, 2026-08-11**:
  the fixture loaded as an ordinary program, Pause clicked, `Manual break` reported, registers and
  source view populated, Continue and Pause again, clean `CMD_CLOSE`. So the `NTF_PAUSE`
  arriving *before* its own `CMD_PAUSE` response — reasoned from CSpect's plugin and never watched
  — is watched, and the real client handles it.
- **The extinguished RX-overflow diagnostic** (§0, cost 3) is reasoned from the VHDL and from the
  ordering in `mf_nmi_poll`. No run anywhere produces an overflow while a debuggee is running, so
  neither the loss nor its harmlessness has been observed.
- **The cost of a poll that BREAKS IN** — §5 measures the decline path only.

---

## 7. Recommendation — and what became of it

**ANNOTATED 2026-08-10.** Items 1 and 4 are done. Item 2 was examined and **rejected with a reason**:
T4's verdict is unchanged because the poll declines at a machine with no debugger (§0). Item 3 is
struck — the program installs the list (§4.4). Item 5 **is done**: §5 carries the measurement, and
`make measure-poll-cost` makes it re-runnable. Item 6 changes shape with §0 — what a user needs to be told is how to add the two
instructions, not what the debugger will destroy — and the HOWTO is deliberately not written here.

The original recommendation follows for the record.

> Build it, **opt-in**, and document the Copper cost where a user will meet it rather than here. The
> sequence that follows from the above:
>
> 1. the fast path in `nmi66h` plus the poll-and-return exit that restores slot 7 (§4.1, §4.2);
> 2. invert T4 in the same change, deliberately (§4.1);
> 3. install/remove the Copper list around resume and break (§4.4);
> 4. decide §4.3's unsolicited-line question and write down which way and why;
> 5. measure the per-frame cost rather than inheriting the estimate (§5);
> 6. document, for users: async break destroys the Copper, can be switched off by the debuggee
>    silently, and a Copper-using program can instead carry the two instructions itself (§3.1).
