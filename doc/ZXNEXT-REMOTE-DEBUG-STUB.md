# ZX Spectrum Next — Remote WiFi Debug Stub

**Project plan / feasibility analysis**
Date: 2026-08-03
Status: exploration complete, not started

---

## 0. Executive summary

A debug stub running on **real ZX Spectrum Next hardware**, debugged from a PC **over the
Next's ESP-01 WiFi module**, is feasible and most of the hard work already exists. The stub keeps
upstream's joy-port serial transport too, and the mode is chosen when the ROM is assembled.

- The reference implementation of a Next debug stub — **dezogif** — already exists, is MIT
  licensed, and works. It talks **DZRP** to **DeZog** in VS Code.
- dezogif's transport is a **serial cable on the joystick port**, and that single choice is the
  source of its headline limitation: *you cannot pause the running program from the PC; you
  must physically press the NMI button.*
- On the Next, the joy-port serial and the ESP WiFi module are **the same UART peripheral
  behind a pin mux**. Adding an ESP transport beside the serial one is therefore a small
  change with a disproportionate payoff: in WiFi mode the joysticks stay with the game
  permanently, and the hardware gains a route for PC-initiated break.

**Recommended shape:** fork dezogif, add a second transport behind an assembly-time switch, add
asynchronous break. **The joy-port serial transport stays** — the ROM is built in either UART mode
or WiFi mode, so a user with a working cable setup keeps it, and the serial build remains the
fallback whenever the ESP is unavailable or in use by the debuggee (§10).
Everything above the byte stream (DZRP, breakpoints, memory paging, the DeZog client) is
inherited unchanged.

**This is a separate project, not a jnext feature.** See §9.

---

## 1. Scope

### In scope

- A Z80 debug stub for real Next hardware, deployed as a replacement `enNextMf.rom`.
- DZRP over TCP via the on-board ESP-01, to an unmodified DeZog in VS Code.
- **Two build modes, chosen at assembly time: UART (upstream's joy-port serial) and WiFi.**
  Upstream's transport is retained, not replaced. One mode per ROM, by design: a runtime switch
  would put a branch in the hot path of every transport call and buy nothing a rebuild does not.
  Capacity is *not* the argument — see MEMORY.md; the free space is measured, an AT-command
  stack's size is not.
- Asynchronous (PC-initiated) break, which dezogif cannot do.

### Explicitly out of scope

- Any change to jnext's emulator core. jnext is a **development bench and a validation
  target**, not the home of this code (§9).
- Inventing a new wire protocol. DZRP exists, is documented, has a mature client, and is
  already the consensus choice on jnext issue #12.
- Cycle-accurate or non-intrusive debugging. This is a software stub on real silicon; it
  costs cycles and it perturbs state. That is accepted.

### Why this is not part of jnext

Three reasons, in descending order of force:

1. **jnext's quality methodology has no purchase on it.** jnext's identity is "the VHDL is the
   spec" — every test row cites FPGA source lines. A debug stub has *no oracle*: it is a design
   problem, not a fidelity problem. Work that cannot be judged by the project's own standard
   does not belong under its roof.
2. **CI can never test it.** jnext's rule is that a missing test is a loud failure and every
   suite is declared with a pinned row count. A hardware-only component would be the single
   part of that repo with no gate, permanently, because GitHub Actions will never have a Next
   plugged into it.
3. **Nothing in it ships in a jnext release.** The deliverable is an 8 KB `.rom` on a Next SD
   card, plus Z80 assembly and an sjasmplus toolchain. None of that appears in the rpm, deb,
   flatpak, Windows zip or dmg.

---

## 2. Prior art

| Project | What it is | Licence | Relevance |
|---|---|---|---|
| [dezogif](https://github.com/maziac/dezogif) | The Next-side debug stub. Ships **as `enNextMf.rom`**. | MIT | The thing to fork |
| [DeZog](https://github.com/maziac/DeZog) | VS Code debug adapter; the PC-side client | MIT | Used unmodified |
| [DZRP spec](https://github.com/maziac/DeZog/blob/main/design/DeZogProtocol.md) | The wire protocol | — | Used unmodified |
| [NDS-NextDevSystem](https://github.com/Ckirby101/NDS-NextDevSystem) (Chris Kirby) | Earlier Next dev/debug system | — | dezogif's starting point |
| [NextTang](https://github.com/jattree/NextTang) | Next FPGA core on Sipeed Tang, hardware debug as a first-class goal, plans to speak DZRP | — | Another DZRP target |
| [jnext](https://github.com/jorgegv/jnext) issue #12 | Emulator-side DZRP server (v1.1) | GPLv3 | Complementary target |

### How dezogif works (verified by reading its source and design doc)

- **It is the Multiface ROM.** Deployment is: copy its `enNextMf.rom` over
  `machines/next/enNextMf.rom` on the SD card, keeping a backup of the original.
- **The ROM swap is forced, not chosen.** MF ROM/RAM can only be paged in by the NMI button
  (`IN A,($3F)` pages in, `IN A,($BF)` pages out, `OUT ($3F),A` + `IN A,($BF)` hides it until the
  next press). A running program cannot write MF memory at all, so there is no way to inject a
  stub at runtime — it must already be in the file the firmware loads at boot.
- **8 KB is not enough, so it relocates.** On NMI, MF ROM sits at `0x0000-0x1FFF` and MF RAM at
  `0x2000-0x3FFF`. The ROM code copies the real debugger (`MAIN`) into a RAM bank and runs it
  from **slot 7** (`0xE000-0xFFFF`). **Slot 6 is a SWAP window**: to read/write debuggee memory
  or patch a breakpoint it pages the target bank into slot 6, does the access, and restores.
- **The AltROM trick.** To make breakpoints and stepping work in ROM code, it patches the 48K
  BASIC ROM and writes the result into the **Alt ROM** (NR `0x8C`), which pages in via bank
  `0xFF` like the real ROM. Price, stated outright in its design doc: *your program cannot use
  any of the other ROMs.*
- **Breakpoints are `RST 0` patches**, with the bookkeeping deliberately exported to the PC
  (§6.4).
- **M1 (NMI) button is disabled while the debugger runs**, so no NMI-inside-NMI.
- **Known-good on core 03.01.10 and 03.02.00**; will not work on older cores.
- Last commit 2023-06-13 — effectively dormant, which is part of why a fork is reasonable.

---

## 3. Hardware facts (verified against the FPGA VHDL)

All citations are to `cores/zxnext/src/` in the ZX Spectrum Next FPGA repository. These four
facts are what make the WiFi variant attractive; each was checked in the source, not assumed.

### 3.1 The ESP and the joy-port serial are ONE UART, muxed at the pins
`zxnext.vhd:3340-3349`. With `joy_iomode_uart_en=1` UART0's RX comes from the joystick pin
instead of `i_UART0_RX`, and `uart0_tx_esp` is forced idle. Same register interface either way
(`0x133B` Tx/status, `0x143B` Rx/prescaler, `0x153B` select, `0x163B` frame).

**Consequence:** a dezogif-derived stub becomes a WiFi stub by simply *not* flipping the mux.
The DZRP layer above is untouched, and the joysticks stay with the game permanently. Because the
register interface is identical either way, the two transports differ only in bring-up and
framing — which is what makes an **assembly-time mode switch** cheap rather than a fork of the
whole layer. One mode per ROM, chosen for the reasons in §1 — not on capacity grounds.

### 3.2 The UART RX has a real interrupt in the IM2 fabric
`zxnext.vhd:1943` — `uart0_rx_near_full or uart0_rx_avail`, enabled by NR `0xC6` bits 2:0,
status/clear via NR `0xCA`.

**Consequence:** a byte arriving from the PC can interrupt the running program. This is the
PC-initiated break that dezogif cannot do. Caveat: it depends on the debuggee's interrupt
mode and vector table, so it is intrusive — see §6.3 for the non-intrusive alternative.

### 3.3 The Copper can raise an NMI
`zxnext.vhd:3830-3833` — `nmi_cu_02_we` fires on a **Copper** write to NR `0x02`; bit 3 →
Multiface NMI, bit 2 → DivMMC NMI. A **CPU** write to the same register does the same thing
(`nmi_cpu_02_we`, same lines), which is what the headless test bench uses.

**It is not ungated** — an earlier draft of this document said it was, and that was wrong.
`zxnext.vhd:2090`:

```vhdl
nmi_assert_mf <= '1' when (hotkey_m1 = '1' or nmi_sw_gen_mf = '1')
                 and nr_06_button_m1_nmi_en = '1' else '0';
```

Every Multiface NMI source — the M1 button, the CPU/Copper NR `0x02` write and the I/O trap
alike — is ANDed with **NR `0x06` bit 3** (`zxnext.vhd:5166`; it reads back, `zxnext.vhd:5900`),
whose power-on value is `'0'`. So the stub must set that bit itself before the Copper trick can
break anything, and must consider that the debuggee may clear it.

**Consequence:** a two-instruction Copper list (`WAIT line,0` / `MOVE $02,$08`) gives a
**periodic NMI at a chosen raster line, with zero CPU cost and no dependence on the debuggee's
interrupt mode**. This is the cleanest asynchronous-break mechanism on the machine.

### 3.4 Stackless NMI
NR `0xC0` bit 3, with the return address in NR `0xC2`/`0xC3`. The NMI acknowledge writes the
return address to NextREGs instead of the debuggee's stack, and the first `RETN` takes it back
from there. This is why dezogif requires core ≥ 03.01.10 — without it, entering the debugger
corrupts the program being debugged.

### 3.5 Secondary facts

- **I/O trap → MF NMI**: `zxnext.vhd:3835`, ports `0x2FFD`/`0x3FFD`, gated by NR `0xD8`. Useful
  as an explicit "break here" in source. Too many bytes to be a patched breakpoint.
- **Baud**: prescaler = Fsys/baud, 17 bits wide (3 MSB from `0x153B`, 14 LSB from `0x143B`
  writes), so >1 Mbaud is reachable. The Next's own auto-detect list includes 1152000.
- **Hardware flow control** exists in the core for the ESP pins (`esp_uart_rtr_n`,
  `i_UART0_CTS_n`). **To verify** whether it is populated on the specific board revision before
  relying on it at high baud.

---

## 4. Architecture

*This section describes **WiFi mode**. UART mode is upstream's architecture unchanged — the same
diagram with the ESP box replaced by the joy-port cable — and §4.2's TCP/server discussion has no
counterpart there. ~~§4.3 is the interesting difference: PC-initiated break is absent from UART mode
for a concrete reason, not by choice.~~* ***CORRECTED 2026-08-12: IT WAS ABSENT BY CHOICE — OURS —
AND IT IS NOW BUILT FOR JOY PORT 2.*** *Upstream hands the joy ports back to the debuggee before
resuming it — `backup.asm` writes `REG_JOYSTICK_IO_MODE,0` — which clears `joy_iomode_uart_en`
(`zxnext.vhd:3536`) and so re-points UART0's RX **away from the joystick pin and onto the ESP-01
pin** (`zxnext.vhd:3340`: `uart0_rx <= joy_uart_rx when joy_iomode_uart_en = '1' ... else
i_UART0_RX`). The PC's cable is on the joystick pin, so while the debuggee runs its bytes have
nowhere to land. WiFi mode never touches that register, UART0 stays on the ESP-01 pin
permanently, and that is exactly why a byte from the PC can reach it at any time — which is what
makes the break reachable.*

*Every citation above stands; the **inference** from them did not. That write is a four-byte
`nextreg` in a macro with one call site, entirely inside this project's control, and the serial
build's poll was already present and already correct — so what looked like an architectural
constraint was a line of ours. On joy port 2 `TRANSPORT_DEACTIVATE` no longer clears the register,
and the joystick pin is routed to **UART1** (NR `0x0B` bit 0 = 1) rather than UART0, which is what
keeps the ESP-01's own TX and RTR out of io mode's way. Port 1 keeps the old behaviour on purpose,
so the debugged program has a connector for a real joystick. ~~**Not shown to work anywhere**: no
bench here can put a byte on that cable.~~ **BENCHED 2026-08-13 — `make test-uart-break`, issue #43**
— once jnext#251 gave the joystick port a serial source: a freely running debuggee is stopped by
bytes on the cable, and both arms of `TRANSPORT_DEACTIVATE` are told apart by the debuggee reading
NR `0x0B` while it runs. **Still not shown on hardware.** See
[ASYNCHRONOUS-BREAK-DESIGN.md](ASYNCHRONOUS-BREAK-DESIGN.md) §8, and §8.0.1 for the evidence ladder.*

```
   PC (dev machine)                        ZX Spectrum Next (real hardware)
┌───────────────────────────┐          ┌────────────────────────────────────────┐
│ VS Code + DeZog           │          │  debuggee program  (its own banks)     │
│   remoteType: "cspect"    │          │                                        │
│   hostname: <next-ip>     │          │  ┌──────────────────────────────────┐  │
│   port:     <port>        │          │  │ STUB (deployed as enNextMf.rom)  │  │
└─────────────┬─────────────┘          │  │   MF ROM 0x0000  — bootstrap     │  │
              │                        │  │   MAIN in a RAM bank, slot 7     │  │
              │ DZRP over TCP          │  │   SWAP window, slot 6            │  │
              │                        │  │   patched 48K ROM in AltROM      │  │
              ▼                        │  └────────────────┬─────────────────┘  │
      ~~~~ WiFi / LAN ~~~~─────────────┼──── ESP-01 ───────┘  UART0             │
                                       │   AT+CIPSTART, AT+CIPMODE=1            │
                                       │   (transparent passthrough)            │
                                       └────────────────────────────────────────┘
```

### 4.1 Memory choreography

Inherited from dezogif essentially unchanged — it is well designed and hard-won.

| Slot | Running | NMI / break | Debug loop | Debug exec | Exit |
|---|---|---|---|---|---|
| 0 | debuggee (or patched AltROM) | **MF ROM** | debuggee | debuggee | debuggee |
| 1 | debuggee | MF RAM | debuggee | debuggee | debuggee |
| 2-5 | debuggee | debuggee | debuggee | debuggee | debuggee |
| 6 | debuggee | debuggee | debuggee | **SWAP** | debuggee |
| 7 | debuggee | → **MAIN** | **MAIN** | **MAIN** | **MAIN** → debuggee |

Notes carried over from dezogif's design doc, all of which remain true here:

- The debuggee's **SP can point anywhere**, including into slot 7 or across a slot boundary.
  Reaching its stack needs the memory around SP mapped into two spare banks.
- `MAIN`'s data is reachable from slot 0 or slot 7; from slot 0 the addresses are offset by
  `0xE000`.
- The NMI button must be re-armed before leaving the NMI handler.

### 4.2 Transport — the Next must be a TCP **server**

This is forced by the client, not chosen. **DeZog always dials out**, and every existing DZRP
remote listens: the CSpect plugin on port 11000, ZEsarUX on 10000. For an unmodified DeZog to
attach (§7), something on the Next must be **listening**. A Next in TCP client mode has nothing
for DeZog to connect to and drags a PC-side relay back into the design.

**Chosen: Next as TCP server.**

1. **Association — NOT done by the stub.** WiFi is a prerequisite the user satisfies once with
   `/apps/wifi/setup/wifi2.bas`, and the ESP-01 keeps the credentials in its own flash. The stub
   sends no `AT+CWJAP`, holds no SSID and no passphrase, and only *verifies* it has an address.
   Decided 2026-08-04; storing credentials in the ROM was considered and rejected — see
   [WIFI-SETUP.md](WIFI-SETUP.md) and MEMORY.md.
2. `AT+CIPMUX=1`.
3. `AT+CIPSERVER=1,<port>`.
4. Inbound data arrives as `+IPD,<id>,<len>:<bytes>`; each reply is prefixed with
   `AT+CIPSEND=<id>,<len>`.

**Passthrough is not available in this mode, and that is a hard ESP constraint, not a
preference.** Per the Espressif AT documentation, `AT+CIPSERVER` requires `AT+CIPMUX=1`, and
`AT+CIPMUX=1` requires `AT+CIPMODE=0`. Server mode and transparent transmission are mutually
exclusive.

Consequences, accepted:

- More Z80 code: a `+IPD,<id>,<len>:` parser and an `AT+CIPSEND` prefix on every reply.
  Feasible and proven — NXtel does exactly this.
- Worse per-exchange latency than a raw byte pipe. Mitigated by DZRP's bounded reads and by
  batching.
- **Better connection lifecycle**, which is why this is not purely a sacrifice: passthrough can
  only be left via the `+++` escape with its timing guard bands and detects a dropped link
  poorly. A debugger has to survive a WiFi blip and reconnect cleanly (M3), and explicit
  connection management buys more than the byte-pipe efficiency costs.

**Alternative, kept as a fallback — Next as TCP client** (`AT+CIPSTART` + `AT+CIPMODE=1`
transparent passthrough). Minimal Z80 code and the best throughput, but it requires a small
listen/listen relay on the PC to splice DeZog's outbound connection to the Next's inbound one,
or a DeZog patch to listen. Worth prototyping first at M0 *because it is the quickest way to
prove the physical path*, then switching to server mode for the real thing.

**Throughput/latency budget:** 115200 baud ≈ 11.5 KB/s; a full 64 KB read ≈ 6 s. At 1152000
baud the ESP's TCP stack becomes the limit (tens of KB/s) and the same read is 1-2 s. Round-trip
latency over WiFi is 10-100 ms, which is fine for stepping and demands batching for anything
that reads memory in a loop. DZRP's `CMD_READ_MEM` is bounded by start+size, so a latent target
is never forced into whole-memory reads.

### 4.3 Break mechanisms

Three, in increasing order of value:

1. **NMI button** — always available, zero cost, manual. What dezogif has.
2. **Copper-driven periodic NMI** (§3.3) — a Copper list raises NMI at a fixed raster line every
   frame; the stub polls the UART FIFO and returns immediately if there is nothing to do. Costs
   roughly 100-200 T-states/frame (≈0.3% at 3.5 MHz) — ~~**an estimate nobody has measured**~~
   **MEASURED 2026-08-11 AND WRONG: it is ≈1288 T-states/frame, 0.230% of a frame at 28 MHz and
   1.84% at 3.5 MHz** (`make measure-poll-cost`; see ASYNCHRONOUS-BREAK-DESIGN.md §5) — and
   the current entry path is far larger than it — needs no cooperation from the debuggee's
   interrupt setup, and gives the PC an asynchronous break. **This is the recommended
   mechanism** and the main functional advance over dezogif. It is also **the only one**: the
   line interrupt, the UART RX interrupt and the DMA/CTC sources all terminate in the maskable
   INT bus and never reach `nmi_activated`, so there is no fallback if its cost is refused.

   ~~Cost: it consumes the Copper, which the debuggee may want.~~ **The cost is worse than
   "consumes", and this line understated it.** The 1024-instruction Copper list is
   **write-only** — both instruction RAMs have their CPU-side read output discarded at the top
   level (`zxnext.vhd:3959-3976`, `:3980-3998`), and NR `0x60`/`0x63` have no read decode at all
   (`:6286-6287`) — so the debugger **cannot save and restore** a debuggee's Copper program.
   Installing ours destroys it for the rest of the session. A Copper-using program therefore
   cannot have asynchronous break at all, unless its developer puts the two instructions into
   **their own** list, which is the supported route for that case. See
   [ASYNCHRONOUS-BREAK-DESIGN.md](ASYNCHRONOUS-BREAK-DESIGN.md) §3.1.
3. **UART RX interrupt** (§3.2) — cheapest of all when it applies, but requires the debuggee to
   be in a compatible interrupt mode with a cooperative vector table. Offer it as an opt-in mode
   for programs that can accept it.

### 4.4 Breakpoints

Inherited from dezogif, and **the division of labour must be preserved** because DeZog assumes
it:

- Breakpoint = the opcode at the address replaced by a one-byte `RST 0`.
- Stepping off a breakpoint you are standing on is solved by DeZog, not the stub: it *decides*
  where the 1-2 **temporary** breakpoints go, computing the instruction length and the branch
  target, and names their addresses in `CMD_CONTINUE`'s payload.
- **The stub does keep the substituted opcode, and an earlier version of this line denied it.**
  `TMP_BREAKPOINT` and `BREAKPOINT` in `src/breakpoints.asm:29-40` each store the byte that the
  `RST 0` replaced, because the stub is the party that patches memory and therefore the only one
  that can un-patch it — `clear_tmp_breakpoints` puts the byte back. That is *substitution
  bookkeeping*, and it is legitimately the stub's. What stays exclusively DeZog's is the
  **decisions**: instruction length, where a temporary breakpoint belongs, and condition
  evaluation. Keep that boundary; the older "no tables, no opcode store, no state machine"
  wording named the wrong one and is contradicted by the source it describes.
- **Conditional** breakpoints are unconditional pauses as far as the stub is concerned; DeZog
  evaluates the condition and silently continues if false.
- No watchpoints and no code coverage — dezogif's design doc rules both out on hardware as far
  too slow, and nothing here changes that.
- **DeZog's reverse debugging still works, because DeZog implements it entirely on the PC
  side.** It is a ring buffer of *register and stack values only* (`reverseDebugInstructionCount`,
  default 10000, ~40 bytes per instruction), maintained by DeZog from what it observes while
  stepping. DZRP has **no** history, trace or replay command of any kind, so no remote — emulator
  or hardware — supplies it. Consequence, stated in DeZog's own docs: *"the memory or other HW
  state is not stored… You can only rely on the register values"*, and a breakpoint condition
  that reads memory fires unconditionally in reverse mode. See Appendix C.

---

## 5. Delta versus dezogif

| Area | dezogif | This project |
|---|---|---|
| Transport | Serial on joy port | **Either**, chosen at assembly time: serial as upstream, or **ESP-01 WiFi, TCP** |
| Joysticks | Taken over while stopped | **Never touched** in WiFi mode; in UART mode the chosen port is held permanently on joy 2 (async break) and as upstream on joy 1 |
| Cable | D-SUB 9 + USB serial adapter | **None** in WiFi mode; as upstream in UART mode |
| PC-initiated pause | **Impossible** | **Yes** (Copper NMI poll). WiFi mode, and UART mode on **joy port 2** since 2026-08-12 — untested there, see design doc §8.0 |
| Breakpoint while running | Impossible | Yes, follows from the above |
| Bootstrap | `enNextMf.rom` | Same |
| Memory choreography | slot 7 MAIN / slot 6 SWAP / AltROM | Same |
| Breakpoints | `RST 0` + DeZog-side bookkeeping | Same |
| PC client | DeZog | Same |

Everything in the "Same" rows is inherited. The genuinely new work is the second transport and
the asynchronous break — perhaps 20-30% of the stub, concentrated in two well-isolated modules
(`uart.asm` and the NMI entry path).

Keeping both modes is what makes the isolation a *requirement* rather than good manners: the two
paths have to sit behind one interface that `commands.asm` and `message.asm` cannot tell apart,
because both are assembled against it. It also makes the UART build a live regression check on
that interface — if a change breaks UART mode, the abstraction leaked.

---

## 6. Fork or new project?

**Fork dezogif.** It is MIT, so relicensing is unconstrained; it is dormant, so there is no
upstream churn to track; and its `src/` is already factored with `uart.asm` separate from
`commands.asm`/`breakpoints.asm`/`mf.asm`. Rewriting the memory choreography and the DZRP
command layer from scratch would be months of work to arrive at the same place, with new bugs.

**Licensing (decided 2026-08-03).** The combined work is distributed under **GPLv3** (`LICENSE`).
Upstream's MIT notice is retained verbatim in `NOTICE` — MIT requires it, and it continues to
govern Maziac's original code. The attribution to both Maziac and Chris Kirby stays.

This has a consequence for the paragraph below: **GPLv3 code cannot be merged into an MIT
project.** Offering the transport back upstream is now a licensing decision as well as a
technical one — any part genuinely meant for dezogif has to be written with the intention of
also offering it under MIT, and that has to be decided when it is written.

If the transport abstraction turns out clean, offer it back upstream as an option rather than
maintaining a permanent fork.

---

## 7. Relationship to DeZog (the PC side)

*Also **WiFi mode**. In UART mode the client is upstream's: DeZog's `zxnext` remote over the
serial port, which is exactly why that remote's serial-only nature is a problem for WiFi and not
for UART.*

**No upstream change is required to start.** DeZog has five remote types:

| remoteType | Transport | Usable here? |
|---|---|---|
| `zsim` | internal simulator | n/a |
| `zrcp` | ZEsarUX, socket | n/a |
| `cspect` | **plain DZRP over TCP, configurable `hostname` + `port`** | **yes** |
| `zxnext` | real hardware, **serial only** since DeZog 2.6.0 | no |
| `mame` | MAME gdbstub, socket | n/a |

The `zxnext` remote dropped `hostname`/`port` in 2.6.0 when DeZog absorbed the serial handling
that the separate `DeZogSerialInterface` helper used to provide — a middleman being deleted, not
a policy against sockets. The `cspect` remote is a **generic DZRP-over-socket client whose
hostname is configurable**, so pointing it at the Next's IP works with a released, unmodified
DeZog.

**This works only because the Next is a TCP server (§4.2).** DeZog is always the party that
connects; it never listens. That single fact is what forces `AT+CIPSERVER` and rules out
transparent passthrough — see §4.2 for the full consequence chain. If the Next were a TCP
client, this section's "no upstream change required" claim would be false.

**To verify early:** DeZog may branch on remote type above the wire (breakpoint strategy,
capability assumptions). `CMD_LOOPBACK=15` and `CMD_INIT=1` are the first two commands to
implement and will answer this in an afternoon.

**Eventual upstream PR (optional, low priority):** a properly named remote type so users are not
configuring something called "cspect" to talk to a Next. DeZog is MIT, active (last push
2026-07-30), and demonstrably accepts outside contributions — six merged PRs from non-owner
contributors, most recently 2026-07-06 — and ships a
[design/AddingNewRemotes.md](https://github.com/maziac/DeZog/blob/main/design/AddingNewRemotes.md).
**Sequence it last:** a PR adding a remote type for a target that does not exist yet is not
practically mergeable, because the maintainer has nothing to test against.

---

## 8. Relationship to jnext (the emulator)

### 8.1 jnext as the development bench

jnext already emulates every piece this project touches:

- The dual UART with the correct prescaler, FIFO and interrupt model (`src/peripheral/uart.*`).
- A real ESP-01 with genuine host networking (`src/esp01/`), proven live against the nx.nxtel.org
  BBS.
- The Multiface, with its ROM loaded from `/MACHINES/NEXT/enNextMf.rom` on the SD image.
- NMI sources, the Copper NR `0x02` path, and **stackless NMI** (NR `0xC0` bit 3, the NR
  `0xC2`/`0xC3` latch and the Z80 NMIACK/RETN bus substitution) — checked, already implemented.

So the stub can be **developed and regression-tested inside jnext**, and the identical
`enNextMf.rom` then copied to a real SD card. jnext's headless mode makes that CI-testable on
the stub project's side.

### 8.2 The gap in jnext's ESP emulation that this project would hit

**Status (2026-08-04): the primary gap is CLOSED and exercised.** jnext 0.99.118 shipped the
server-mode triad ([jnext#210]), and this project has now used it: `make test-esp` brings the
emulated module up as a TCP server and echoes over a real socket — see M0(b). The description
below is kept because the *reasoning* still governs anything further we ask jnext for, but read
its present tense as of the filing date, not of today. What is still absent is `AT+CIPMODE`
passthrough, which the chosen design cannot use anyway (§4.2), and `AT+CWJAP=` in its setting
form, which the emulator does not need and hardware will.

Both absences below are deliberate and documented in `src/esp01/include/esp01/esp_at.h`, whose
stated rule is that every emulated command must appear in software that actually runs on a Next.
**This project is the first real consumer of the server path**, which is exactly the bar that
file sets.

[jnext#210]: https://github.com/jorgegv/jnext/issues/210

**Primary requirement — server mode.** Per §4.2 this needs three things together, not one:

1. `AT+CIPSERVER` — today "appears exactly once in all the software examined, and only to turn
   it OFF", so it is not implemented.
2. `AT+CIPMUX=1` — today **actively REFUSED with `ERROR`**, not merely unimplemented.
3. The multiplexed `+IPD,<id>,<len>:` inbound form, which follows from (2).

The refusal in (2) is load-bearing and must not be casually removed: nextsync never sends
`AT+CIPMUX` at all, relies on the power-on default being 0, and its `+IPD` reader *silently
corrupts* the multiplexed form rather than rejecting it. So the constraint on any
implementation is: **the power-on default stays 0, `CIPMUX=1` only ever happens on explicit
command, and nextsync keeps working.** That makes this a real piece of work, not a small
addition.

**Secondary — `AT+CIPMODE` passthrough**, needed only for the fallback client transport (§4.2),
and useful for the M0 spike.

**Filed as [jnext#210](https://github.com/jorgegv/jnext/issues/210)** (milestone v1.0, 2026-08-03):
the server-mode triad only — `AT+CIPMUX=1`, `AT+CIPSERVER`, and the multiplexed `+IPD,<id>,<len>:`
form — with this project named as the consumer. `AT+CIPMODE` was **deliberately left out of that
issue**: server mode forbids passthrough, so the chosen design cannot use it even if it existed,
and asking for it would be exactly the speculative widening jnext's own scoping rule refuses. The
issue also carries forward the nextsync constraint (`CIPMUX` default stays 0, refusal only on the
wrong value) so an implementer does not meet the existing `ERROR` cold and assume it was an
oversight. jnext#154 (v1.1) remains the home for broad datasheet fidelity; #210 is the narrow
evidenced slice its own closing note invites.

The correct etiquette is to file these as jnext issues **with this project as the demonstrated
consumer**, not to ask for them speculatively. jnext's own rule is that features are
demo-driven, not completeness-driven — and `esp_at.h` already anticipates the widening, tracking
"full datasheet-level fidelity" as its own v1.1 issue and noting the file is *shaped* so that
widening is filling in blanks rather than surgery.

**Third gap, now closed: headless M1-button NMI.** jnext used to expose the Multiface NMI only as
the F9 host key and the toolbar button, so a headless run could not press it — which is why
`test/nmi_trigger.asm` uses the *software* NMI (NR `0x02` bit 3), and why the bench's T4 asserts
only that the stub **declines** a non-button cause. `--delayed-nmi` / `--delayed-nmi-frames`
shipped in **jnext 0.99.118** (GH #209), with this project as the demonstrated consumer.

**What it changed, measured 2026-08-04.** The bench gained **T6**: a real M1 button press against
our ROM, and the stub **takes over and paints its own UI — 90.28% of the screen repainted**,
against the stock Multiface monitor's 91.41%. That is the first evidence in this project's history
that the stub *runs*; every prior check proved a negative. In one run it exercises Multiface
paging, the relocation of `MAIN` into a RAM bank at slot 7, `show_ui`, and the core-version check
passing (the reference image reports core 03.02.03, above the 03.01.10 that stackless NMI needs).

It also settles §8.3's validation experiment for the entry path: jnext's Multiface paging and the
**entry side** of stackless NMI are good enough to bring a real stub up. Not AltROM, and not the
return side — see the scope limit below.

**T6 did not replace T4, and an earlier draft here said it would.** They send different causes to
the same check in `nmi66h` — T6 one it accepts, T4 one it rejects. Both are kept, so T4 remains
the regression check M2 had to re-examine deliberately when it taught `nmi66h` to accept a software
cause. ~~invert~~ **It did not need inverting** (2026-08-11): the poll accepts the cause and then
declines unless our image is in `MAIN_BANK` and a debuggee is running, neither of which holds in
T4's run. Verdict unchanged, reason changed; **T9** asserts the serving half.

**What T6 does not cover, and it is more than "the second press".** **T6 never resumes.** No DZRP
client attaches, so the stub idles in `main.asm`'s `main_loop`, whose
`transport_byte_available` poll returns immediately and whose `jp nz,cmd_loop` therefore never
fires — `cmd_loop`, and the blocking `transport_wait_rx` inside it, are never reached. The frame
limit ends the run. Nothing beyond "the debugger came up" executes: not the
exit path, not `backup.asm`'s restoration, and not the **return-to-debuggee half of stackless
NMI** — the half §3.4 identifies as the one that matters, since without it entering the debugger
corrupts the debuggee. Of stackless NMI, only the **entry side** is verified.

Closing that gap needs a DZRP client to send `CMD_CONTINUE` and a check that the debuggee really
resumes — which is [issue #2](https://github.com/jorgegv/dezogif_ng/issues/2), the protocol
conformance suite, not another screenshot check.

**CLOSED, 2026-08-05, by that suite's C10 and C11** (`make test-dzrp-stub`; see
[DZRP-TESTING.md](DZRP-TESTING.md)). A fixture is loaded with `CMD_WRITE_MEM`, the debuggee's
`PC`/`SP`/`BC`/`IX` are set, and `CMD_CONTINUE` carries a temporary breakpoint: **the debuggee
runs, writes its marker, stops on the breakpoint, and the `NTF_PAUSE` names that address.** The
exit path, `backup.asm`'s restoration and — because the breakpoint is an `RST 0` that could only
have reached the debugger through `copy_altrom`'s patched code — the **AltROM** are all executed.

**One thread of the paragraph above is NOT closed, and the distinction is narrow enough to be
easy to lose.** C10 sets `PC` itself, so `backup.pc` never comes from `save_nmi_return_address`,
which is where the stackless-NMI return address is read back out of NR `0xC2`/`0xC3`. That routine
runs only on an M1 press taken while `prgm_state` is `PRGM_RUNNING` — a *second* NMI, landing
after a `CMD_CONTINUE`. `--delayed-nmi` counts emulated frames while a DZRP client counts wall
clock, and the emulator's frame rate collapses under that traffic, so scheduling one is a race
rather than a check, and none is written. What C10 does establish is the half that any such press
would depend on: `restore_registers` really hands the machine back, and the program really runs.

T6 is also a pixel-difference measure, so it cannot distinguish a takeover from a crash. It does
now exclude one wrong answer automatically by requiring the result to look *unlike* the stock
Multiface monitor, which catches "our ROM was never installed".

### 8.3 A validation experiment worth doing first — largely answered, see §8.2

**Status (2026-08-04): answered, in two steps, neither of them this experiment.** T6 answered the
entry path — our own build comes up under jnext on a real button NMI, which is the evidence this
section was after and makes running a third-party binary unnecessary. `make test-dzrp-stub`'s
**C10/C11 then answered AltROM and the resume**: the debuggee runs again after `CMD_CONTINUE` and
its `RST 0` breakpoint reaches the debugger, which requires the patched Alt ROM. The one strand
left is the stackless-NMI **return address** (NR `0xC2`/`0xC3` → `save_nmi_return_address`), which
needs an M1 press against a *running* debuggee; see the end of §8.2. The original text follows.


Drop **dezogif's existing** `enNextMf.rom` onto a jnext SD image and press the emulated NMI
button. If it comes up, that is third-party validation of jnext's Multiface paging, AltROM and
stackless-NMI implementations all at once — and it de-risks this project by proving the
emulator bench is trustworthy before any new Z80 code is written. Manual experiment, not a
committed test fixture (MIT is licence-clean, but a third-party binary in a test tree needs its
own decision).

### 8.4 jnext issue #12 is the complementary half

jnext issue #12 ("Make a API remote debugger", milestone v1.1) is an **emulator-side DZRP
server**, requested by the ZX Basic Studio author and with consensus on DZRP from three
contributors. It is not this project and does not compete with it: DZRP is one protocol with
several targets.

- **jnext** — DZRP remote for the emulator (#12)
- **NextTang** — DZRP remote for the core running on Sipeed Tang FPGA boards
- **this project** — DZRP remote for real Next hardware over WiFi
- **CSpect** — DZRP remote via its bundled DeZog plugin

The same DeZog session points at any of them by changing configuration. Comparing an emulator
against the same VHDL running as gates, or against real silicon, becomes a config change rather
than a bridge somebody has to build.

Worth noting the capability split, since it explains why nobody's work is wasted. jnext can serve
a tier of DZRP that **no hardware target can ever implement**:

- `CMD_READ_STATE` / `CMD_WRITE_STATE` — DeZog's `-state save <name>` / `-state restore <name>`
  console commands. The payload is explicitly "arbitrary data, the format is up to the remote",
  which maps exactly onto jnext's `Saveable` serialisation. A real Next cannot do this at all:
  several NextREGs are write-only, so the machine cannot read its own state back.
- `CMD_ADD_WATCHPOINT` / `CMD_REMOVE_WATCHPOINT` — real read/write/IO watchpoints.
- The `CMD_GET_SPRITES*` family, cheap for an emulator and awkward on hardware.

Conversely only hardware tells you what the real machine does.

**What this tier is NOT is reverse debugging** — see Appendix C. jnext's own backward execution
is strictly more capable than anything DeZog can express, and DZRP has no command through which
to offer it.

---

## 9. Roadmap

Each milestone ends in something observable. Do not start the next until the previous is proven.

### M0 — Transport spike (no debugger at all)
Proofs to have before any porting work. **This originally read "two independent proofs, on real
hardware", and neither half of that survived contact**: (a) is struck below, leaving two live
items rather than two of three; and (b) and (c) were both proved *in jnext*, headless and
repeatably, which is better for regression and is not what "on real hardware" asked for. The
hardware gap is real and is stated where M0 is declared complete.

- **a) ~~A ~50-line Z80 program that brings up `AT+CIPSTART` + `AT+CIPMODE=1` and echoes bytes to
  a `nc -l` on the PC.~~ DROPPED (user, 2026-08-04)** — not deferred, not parked as work to
  schedule later. Three reasons, and any one of them is sufficient:

  1. **It spikes a transport this document already rejected.** `AT+CIPSTART` makes the Next a TCP
     *client*, and §4.2 settles that the Next must be a **server**, because DeZog always dials out
     and never listens. A client-mode Next needs a relay on the PC that nobody is going to write.
  2. **Its only real value was already collected, by (b).** It existed to answer "is the ESP path
     alive at all?" cheaply, separately from "is my `+IPD` parser right?". (b) answered the first
     question directly on its way to the second, so (a) can now only re-prove something known.
  3. **It cannot be run here anyway.** It needs `AT+CIPMODE`, which jnext does not implement and
     deliberately will not — server mode forbids passthrough, so the chosen design cannot use it
     (§8.2). Running (a) would mean going straight to hardware to test a design we are not
     building.

  **If server mode ever fails on real hardware**, the fallback is §4.2's, and this is where the
  spike for it would be written. That is a contingency in the transport section, not an
  outstanding milestone, and M0 is **complete without it**.
- **b)** The same, but `AT+CIPMUX=1` + `AT+CIPSERVER=1,<port>` with `+IPD` parsing, and `nc` on
  the PC connecting *to the Next*. This is the shape the real thing uses (§4.2), so it is the
  one that must ultimately pass.
  **DONE in jnext, headless (2026-08-04); NOT yet on hardware.** `test/esp_server.asm` brings the
  module up — `ATE0`, `AT`, `AT+CIPMUX=1`, `AT+CIPSERVER=1,11000`, `AT+CIFSR` — then parses
  `+IPD,<id>,<len>:` and echoes the payload back with `AT+CIPSEND=<id>,<len>`. It is bench
  `make test-esp`, and its assertions are on **bytes over a socket**, not on pixels: E1 the
  listener exists (which covers the whole AT chain, since each step gates the next and
  `CIPSERVER` is refused without `CIPMUX`), E2/E3 payloads echo back byte-identically, E4 a
  second *simultaneous* connection echoes too.

  **E4 is the one that pays for itself**, and it was verified by breaking the fixture on purpose
  rather than by argument. With the id hardcoded to `0` — the value the Espressif documentation
  leads you to expect — E2 gets an *empty* reply, which is precisely the "no error, no data"
  signature MEMORY.md warns looks like a DZRP bug. With it hardcoded to `1`, E2 and E3 **pass**
  and only E4 fails. So the id must be read from the header, and only E4 proves it was.
  (That control also failed E3 and E4, but for a harness reason rather than an independent one —
  see MEMORY.md. The client now labels a silent guest instead of reporting the cascade as three
  findings.)

  What this does **not** cover: real hardware. jnext has no `AT+CWJAP=` at all, only the query
  form, so the emulated module is permanently associated and the fixture never has to join a
  network. The fixture is nevertheless pinned to **115200** — the rate the ESP-01 answers at
  until told otherwise — because jnext models baud as timing only and would have accepted
  anything, which is exactly the kind of divergence that passes here and fails on the bench-top.
- **c)** A Copper list (`WAIT`/`MOVE $02,$08`) whose NMI you can observe firing.
  **DONE (2026-08-04), in jnext, headless.** `test/copper_nmi.asm` writes a two-instruction list
  — `WAIT line 100,0` then `MOVE $02,$08` — and the stock Multiface ROM takes the screen, 91.41%
  repainted. It is bench check T5, so it stays proven.

  Measured at the same time, one variable at a time: with NR `0x06` bit 3 **set** the NMI fires,
  **left untouched** it fires, **explicitly cleared** it does not (0.00%). So the §3.3 gate is
  real and jnext models it — and NextZXOS leaves that bit set after boot, so a guest inherits it
  rather than needing to set it. See ERRORS.md; an earlier entry credited that gate with a
  failure actually caused by dezogif's own cause check.

Doing (a) first is deliberate: it isolates "is the ESP path alive at all" from "is my `+IPD`
parser right". Run in jnext where possible, but note (b) cannot run in jnext until §8.2 lands —
hardware first is acceptable here.

**That ordering was overtaken by events, and (b) went first.** §8.2's gap closed
([jnext#210](https://github.com/jorgegv/jnext/issues/210), in 0.99.118) before either spike was
written, so (b) became runnable headless and repeatable, which is what made doing it first
strictly better than doing the cheap-but-wrong-shape one first. (a) was dropped outright rather
than resequenced — see the bullet above for why.

**M0 is therefore COMPLETE**: (b) and (c) are done and are permanent bench checks, and (a) is not
outstanding work. What M0 has *not* established is anything about real hardware — both (b) and (c)
ran in jnext, and the original wording of this section ("on real hardware") is not satisfied by
either. That gap belongs to M1, which cannot be signed off on an emulator alone.

### M1 — Fork, add the second transport, feature parity
Fork dezogif. Put the joy-port serial path behind a transport interface, then add beside it an ESP
bring-up, `CIPSERVER` listen and the `+IPD` / `AT+CIPSEND` framing, with the mode selected at
assembly time. Keep break-on-NMI-button. Success, and both halves are required:

- **WiFi mode** — DeZog attaches over WiFi with `remoteType: "cspect"` + `hostname`, and
  registers/memory/breakpoints/stepping behave exactly as dezogif does over serial. **No cable,
  joysticks still work.**
- **UART mode** — still byte-for-byte equivalent in behaviour to upstream dezogif. This is the
  cheap proof that the interface did not leak, and it is not optional.

The transport interface also has a **UI half**, settled 2026-08-04: UART mode keeps upstream's
joy-port selector, WiFi mode draws a connect string —
`dezogif_ng remote debugger active. Connect at: <ip>:11000` — composed at run time, because the
address comes from the ESP (`AT+CIFSR`) and is not known at assembly time. That orders the WiFi
work: bring-up first, then UI. **Port 11000**, DeZog's `cspect` default, so Appendix B's
`launch.json` and the ROM agree. It replaces the baud line and the joy-port selector only; the
core-version check and the error area are mode-independent and stay. See MEMORY.md.

*As built (2026-08-05) that string is two lines — `Remote debugger ACTIVE` then
`Connect at <ip>:11000` — because the screen is 32 columns and the sketch above is 64. The colon
after "at" went with it: `Connect at ` is eleven columns, and the longest possible tail
(`255.255.255.255:11000`) is twenty-one, so the line ends exactly at column 32 with no room for a
thirty-third character. MEMORY.md left wording and layout undecided, which is the latitude used
here.*

**Status 2026-08-05 — BOTH halves are done in the emulator.**
`src/transport_esp.asm` exists, `make TRANSPORT=wifi` builds it, and `make test-dzrp-stub` runs the
DZRP conformance suite against it inside jnext: the stub brings the ESP up, listens on 11000, and
**answers every check — 12 of 12, with W1/W2/W3 green and the target exiting 0.** The first eight
were green when the transport landed; C2 was a pre-existing `cmd_init` behaviour shared with the
serial build, fixed separately as issue #7 (which also added C9 — see `doc/DZRP-TESTING.md`). The
UART build was byte-identical to the one before the transport change, so the interface did not
leak; issue #7 then changed both ROMs deliberately, being common code. The last red was **C12**,
`CMD_PAUSE`, which the stub did not answer at all — pre-existing in the same sense C2 was, and
closed on its own branch as **issue #8**, again moving both ROMs.

**Including, since 2026-08-05, the resume**: C10/C11 load a fixture over DZRP, `CMD_CONTINUE` it
onto a temporary breakpoint, and get the `NTF_PAUSE` back with the registers intact. So "registers
/ memory / breakpoints / stepping behave exactly as dezogif does over serial" is no longer taken
on trust — a breakpoint really fires and a resumed program really runs, in the emulator.

The **UI half** landed 2026-08-05, and it was a correctness fix rather than a cosmetic one: the
WiFi ROM had been rendering `BAUDRATE` — the joy-port cable's 921600 — while its own prescaler
table was built from `ESP_BAUDRATE` (115200), so it stated a rate the hardware was not using, in
the first place anyone looks when the ESP misbehaves. It also drew a joy-port selector for a port
that build never touches, and, sharing every byte of its screen with the serial build, gave a real
machine no way to say which ROM was installed. It now sends `AT+CIFSR`, parses the station address
and draws `Connect at <ip>:11000`, with a two-line plain-language message in the same place when
there is no address or the AT chain did not complete. The UART ROM's bytes did not move.

**A DZRP session has now run on hardware** (2026-08-05), and since build 000A **every check of the
hardware bench passes** — 12 of 12 conformance, H3 included. The first run answered **11 of 12**
conformance checks over WiFi — the one red being `CMD_PAUSE`, since fixed as issue #8 — and that
included **C10/C11, so a debuggee was resumed on silicon**, not only in the emulator. Latency and
throughput were measured rather than estimated: median **13.0 ms** round trip, and 8192 bytes
across the wire in 1.01 s, which is **71% of what 115200 8N1 can carry**. The connect string was
**confirmed correct on the machine**, at a 15-character address — the length its parser used to
refuse, and one jnext cannot produce, since its module always answers the twelve characters of
`192.168.1.50`.

**Two bugs came out of those two hardware evenings, and neither was findable in the emulator**,
both because jnext's values sit on the safe side of ours: a connection id of `0`, which the stub
read as "no client" and used to discard every reply, and the 15-character address above. Every
emulator check stayed green through both. That is the standing argument for §6's hardware rung
being a rung and not a formality.

**M1's last item closed, 2026-08-05: DeZog itself has now driven the stub on a real Next.** A
session in VS Code with `remoteType: "cspect"` pointed at `<next-ip>:11000` attached, disassembled,
read registers and memory, **single-stepped**, broke in with the **NMI button**, disconnected
cleanly and reattached. Captured through a logging TCP tap, so it is a record rather than a report.

Counts are from a **frozen snapshot** of that tap (the session was still running when it was taken,
and an earlier draft of this paragraph quoted numbers from a truncated view — see below):

- `CMD_INIT` from `DeZog vv24.18.0`, answered `dezogif v2.2.1` / DZRP 2.1.0 / machine 4;
- 121 `CMD_READ_MEM`, 26 `CMD_GET_REGISTERS`, 1 `CMD_LOOPBACK`, across 5 connections;
- **22 `CMD_CONTINUE` and 22 `NTF_PAUSE`**. Twenty-one carry break reason 0 and land at
  **`0x8017`, then `0x8019`, then `0x801C` nineteen times** — DeZog stepping the three instructions
  after the conformance fixture's trap (`ld a,0xC3`, `ld (0x9805),a`, `jr $`), the last of which
  branches to itself, which is why the tail of them repeats. The addresses are *not* all identical,
  and that they differ is the stronger fact: it shows DeZog computing each step's target and the
  stub planting a temporary breakpoint there, on silicon;
- shutdown is `CMD_PAUSE` then `CMD_CLOSE`, **both answered**, socket closed 1 ms later, and a
  reattach 33 s afterwards worked and went on stepping.

Each resume exercised `CMD_CONTINUE`, `set_tmp_breakpoint`'s patch, `restore_registers`, the AltROM
`RST 0` path back in, and `send_ntf_pause` — the whole execution-control loop, driven by the real
client rather than by our own suite.

**THE TWENTY-SECOND NOTIFICATION IS THE ONE THAT MATTERS MOST, AND IT CLOSES THE LAST UNEXECUTED
PATH IN THIS PROJECT.** It carries break reason **1**, `BREAK_REASON.MANUAL_BREAK`
(`breakpoints.asm:20`):

```
-> CMD CONTINUE  seq=35  payload=00 00 00 ...        no temporary breakpoint: run free
<- NTF           seq=0   payload=01 01 00 00 00 00   reason 1 = MANUAL_BREAK
<- RSP           seq=36  payload=1C 80 00 9F ...     PC=0x801C, SP=0x9F00
```

A `CMD_CONTINUE` with no breakpoint set the fixture running in its `jr $`; ten seconds later the
**M1 button** was pressed; the stub broke in and reported it. `cmd_get_registers` reads from
`backup.pc`; `mf_rom.asm`'s dispatch reaches `mf_nmi_button_pressed` only while `prgm_state` is
`PRGM_RUNNING`; that path calls **`save_nmi_return_address`** unconditionally (`mf.asm:119`,
`:165-193`); and the only other writer of `backup.pc` needs an `RST 0` that no breakpoint was
planted for. So the value is that routine's and cannot be stale. It returned `0x801C` — exactly
where the debuggee was spinning — with SP `0x9F00`, the fixture's own stack.

**Which of its two branches ran is NOT established, and saying so is the difference between a
measurement and a story.** `save_nmi_return_address` reads NR `0xC2`/`0xC3` in stackless mode and
the debuggee's own stack otherwise, and **both would have produced this same correct answer**.
`doc/legacy/Design.md:378` and `:434` record that stackless is the *default* from core 03.01.10,
this machine reports above that, and nothing in `src/` ever clears NR `0xC0` bit 3 — so stackless is
a strong presumption, not an observation. Distinguishing them needs NR `0xC0` read back at the
moment of the break, which nothing does.

**What IS verified is the outcome, and it is what §3.4 actually cares about**: an NMI taken against
a running debuggee returned a correct PC on an uncorrupted stack, so entering the debugger did not
corrupt the program being debugged. §3.4 calls it the half that
matters, because without it entering the debugger corrupts the program being debugged; §8.2 and
Appendix A have carried it as unverified since the fork, and no test anywhere — emulator or
silicon — had ever executed it. It needed a finger on a button, which is precisely why no bench
could reach it.

**That also answers open question 1**: the `cspect` remote makes no assumption above the wire that
this stub does not satisfy. It retired issue #8 the hard way too — DeZog's
`CSpectRemote.disconnect()` really does send `CMD_PAUSE` and block on it, exactly as predicted from
reading its source that morning, so before that fix every Shift+F5 would have hung the client.

**What the same evening also found is a liveness fault**, twice, each needing a power cycle:
issue #15, with the anti-hang design in issue #16. M1's functionality is complete; its
*robustness* is not.

### M2 — Asynchronous break
Add the Copper-driven periodic NMI poll (§4.3). Success: `CMD_PAUSE` from DeZog stops a freely
running program, and breakpoints can be set without pressing anything.

**BUILT 2026-08-10, AND THE BUILD CHANGED THE SHAPE OF IT.** `CMD_PAUSE` from a client stops a
freely running program — bench check **W8** in `make test-dzrp-stub`, which resumes a debuggee with
**no** temporary breakpoint so that nothing the debugger planted can bring it back, and its own
control run with the pause withheld. `nmi66h` serves a software Multiface NMI; the decline path
costs a **measured** ~1288 T-states per frame (`make measure-poll-cost`).

**AND IT HAS RUN ON A REAL NEXT, 2026-08-11 — bench check H7, with its control, and it passed.**
So the milestone's success criterion is met on silicon and not only in the emulator: the Copper
raises a Multiface NMI at 50 Hz on real hardware, the poll serves it, and `CMD_PAUSE` stops a
freely running program. NR `0xC0` read `0x0A` at the break, which makes this the first time the
**stackless** branch of `save_nmi_return_address` has been distinguished on hardware. **AND DeZog HAS NOW DRIVEN IT**, the same day and the same machine: Pause clicked in VS Code,
`Manual break` reported, registers and source view populated, Continue and Pause again, clean
disconnect. **M2 is complete end to end on hardware, with the real client.**
Read
[ASYNCHRONOUS-BREAK-DESIGN.md](ASYNCHRONOUS-BREAK-DESIGN.md) §0 first, and
[ASYNCHRONOUS-BREAK-USER-HOWTO.md](ASYNCHRONOUS-BREAK-USER-HOWTO.md) for what a user has to do.

**THE ONE DECISION THAT MOVED, AND IT REMOVES THIS MILESTONE'S HEADLINE COST: the DEBUGGED PROGRAM
installs the Copper list, not the debugger.** Two instructions at the start of the program under
test, 44 bytes, compiled out for release. So there is nothing for the debugger to destroy and
nothing to opt into — the feature is opt-in in the *debuggee*, by construction. The cost falls the
other way instead: a program that does not carry them gets no asynchronous break at all, and the
debugger cannot install one for it, because it cannot read what it would be overwriting.

The 2026-08-08 evaluation follows, annotated. Its VHDL and its reasoning stand; its verdict is
superseded by the paragraph above.

> **EVALUATED 2026-08-08, before any code:
> [ASYNCHRONOUS-BREAK-DESIGN.md](ASYNCHRONOUS-BREAK-DESIGN.md). Verdict: feasible, and it should be
> ~~OPT-IN~~** *(opt-in in the DEBUGGEE, as built)*. **The mechanism is sound and is the only one on
> the machine; the byte budget is not the
> blocker it was briefly recorded as; and open question 5b is answered (you cannot distinguish the
> causes, and a poll-shaped handler does not need to). What the evaluation adds to this milestone is
> two costs the plan did not carry: ~~the Copper list is **write-only**, so enabling the break destroys
> any Copper program the debuggee had, irrecoverably~~ *(the list is write-only, and that fact
> stands — but the debugger never writes one, so nothing is destroyed)*; and the debuggee can switch
> the break off
> silently — NR `0x06` bit 3, or a write of NR `0x62` that **changes** the mode bits, which restarts
> the list (`device/copper.vhd:69-78`) — after which **the poll is what would have restored it**, so only a
> human pressing M1 gets it back *(the NR `0x62` half is now the program's own business, since it
> owns the list; the NR `0x06` half stands)*. Read §3 and §7 of that document before starting.

### M3 — Robustness
Reconnect after WiFi drop, ESP state recovery, baud negotiation, a configuration path for
SSID/host/port that does not require reassembling the ROM, and clear failure reporting on the
Next's screen when the transport cannot come up.

### M4 — Upstream (optional)
Named DeZog remote type; contribute the transport abstraction back to dezogif if it is clean.

---

## 10. Risks and known constraints

| Risk | Detail | Mitigation / status |
|---|---|---|
| **AltROM constraint** | The debuggee may not use any ROM other than the one the stub patched into AltROM | Inherited from dezogif; document loudly. No known fix |
| **ESP contention** | One ESP. A program that uses WiFi cannot be debugged over WiFi. NextZXOS/NextSync also reconfigure it | Detect and report rather than hang — and **this is the reason the UART build is kept**: for a debuggee that owns the ESP, the serial ROM is the answer, not a workaround. Since issue #5 that answer is reachable **from the machine**: mfselect carries both ROMs on the card and switches between them in three keystrokes, so choosing the serial build costs a power-cycle rather than a PC session |
| **State transparency** | Several NextREGs are write-only; a full snapshot is impossible on hardware | Permanent ceiling vs an emulator. Accept and document |
| **No watchpoints / coverage / true reverse debugging** | Would require tracing every instruction | Ruled out by dezogif's design doc; DeZog lite history remains |
| **`nmi66h` filters the Copper NMI** | Inherited `mf_rom.asm` reads NR `0x02`, masks `00011100b` and returns unless zero — button causes only. The Copper `MOVE $02,$08` sets exactly that bit (`nmi_gen_nr_mf` covers CPU and Copper, `zxnext.vhd:3832`; latched at `:3843-3848`), so **M2's break mechanism is filtered out by the code M1 inherits**. Demonstrated: bench T4 | **DONE, 2026-08-11.** M2 modified the cause check to accept a software cause and clears the latch on the way out — for cause REPORTING rather than to re-arm, which RETN does in hardware. ~~and invert bench T4 in the same change~~: T4 did **not** need inverting, because the poll declines where no debugger image is in `MAIN_BANK`; its verdict is unchanged and only its reason moved. **T9** asserts the serving half |
| **NR `0x06` bit 3 gates every MF NMI** | Power-on 0 (`zxnext.vhd:2090`, `:5166`), but **NextZXOS leaves it set** — measured 2026-08-04, see M0(c). So the live risk is not that the stub forgets to set it, it is that the **debuggee clears it** and the break then dies silently | Set on entry anyway (seven bytes, removes the dependency on what the firmware left); re-assert from the poll |
| **Timing intrusiveness** | ~0.3%/frame for the NMI poll; contention-timed and tape/beeper code will notice. **The figure is an estimate nobody has measured**, and part of the entry path runs at the *debuggee's* clock before the handler switches to 28 MHz — a speed change 50 times a second is a different kind of perturbation from stolen cycles | Make the poll disableable; document; **measure it in M2** rather than inheriting the estimate |
| **Copper contention — the debuggee's list is DESTROYED, not borrowed** | The 1024-instruction list is **write-only**: both instruction RAMs discard their CPU-side read output (`zxnext.vhd:3959-3976`, `:3980-3998`) and NR `0x60`/`0x63` have no read decode (`:6286-6287`). So the debugger cannot save and restore it. NR `0x61`/`0x62` read back the mode and the *load* pointer only (`:6083-6087`) | ~~**Make asynchronous break opt-in.**~~ **RESOLVED 2026-08-11 by making the escape hatch the ONLY route**: the debugged program carries `WAIT`/`MOVE $02,$08` in its own list, the debugger installs nothing, so nothing is destroyed and there is nothing to opt into. The write-only fact stands and is precisely why. There is still no fallback mechanism — the Copper is the only periodic NMI source on the machine |
| **The debuggee can switch the break off silently, and it cannot be restored** | NR `0x06` bit 3 gates every MF NMI source; and a write of NR `0x62` that **changes** the mode bits restarts the list from index 0, mode `00` stopping it outright (`device/copper.vhd:69-78`). The plan's "re-assert from the poll" cannot work here: once the Copper stops, **the poll is what would have re-asserted it** | Document as best-effort. Recovery is an M1 press — the button the feature exists to remove. Detecting it from the PC side is not possible either: the stub simply goes quiet |
| **NR `0x02` read-modify-write resets the machine** | Bits 1:0 *written* trigger a soft/hard reset (`zxnext.vhd:6370-6371`); *read* they are reset history (`:1306`, `:1732-1739`) and are non-zero in ordinary operation. The handler must clear the cause latch on the way out, so it writes this register every frame | Upstream's `and 10000000b` mask is what makes the existing path safe — **load-bearing, do not lose it**. Prefer a literal constant to a read-modify-write |
| **Latency** | 10-100 ms per round trip | Batch; DZRP's bounded reads help |
| **Core version dependency** | dezogif needs ≥03.01.10 for stackless NMI | Inherited; check at startup and refuse loudly |
| **Slots 6 and 7 reserved** | The debugger occupies them while active | Inherited |
| **Hardware flow control** | May not be populated on all board revisions | Verify before relying on high baud |
| **DeZog remote-type assumptions** | `cspect` remote may branch above the wire | Verify at M1 with `CMD_LOOPBACK` |
| **ESP mode exclusivity** | Server mode forbids passthrough (`CIPSERVER`→`CIPMUX=1`→`CIPMODE=0`), so the raw byte pipe is unavailable in the chosen design | Designed around in §4.2; costs Z80 code and latency, buys connection lifecycle |
| **`0xA5` preamble is serial-only** | The stub emits `MESSAGE_START_BYTE` before every response and notification. This is a documented DZRP extension for the serial link (`doc/legacy/Design.md:30-31`: "DeZog will wait on this byte"), because a game that grabs the joy port leaves the Next emitting zeroes. DeZog's `ZxNextSerialRemote` strips it; its `CSpectRemote` does not, and CSpect emits none (measured, `make test-dzrp`) | **Required in UART mode, must be absent in WiFi mode** — so the preamble is a property the transport contributes, the fourth thing the assembly-time switch selects. Removing it in both modes would break the real `zxnext` remote |
| **`+IPD` framing bugs** | The multiplexed `+IPD,<id>,<len>:` form is easy to get subtly wrong, and a corrupt parser looks like a protocol bug | M0(b) exists specifically to isolate this. NXtel's `src/esp.asm` is a working reference |

---

## 11. Open questions

1. ~~Does DeZog's `cspect` remote make CSpect-specific assumptions above the wire protocol?~~
   **ANSWERED, 2026-08-05: no.** A real session attached, stepped, and disconnected against a Next
   over WiFi — see M1. The one client-specific behaviour found was `CSpectRemote.disconnect()`
   sending `CMD_PAUSE`, which the stub had never answered until issue #8; that is a gap in the
   remote's coverage of the protocol rather than an assumption above it.
2. Does the tbblue firmware checksum or otherwise validate `enNextMf.rom`? dezogif's existence
   strongly implies not, but confirm.
3. Who made the "[Remote debugging via Wifi on the ZX Spectrum
   Next](https://www.youtube.com/watch?v=Wl2yQKeIuTs)" video? Somebody may already be on this
   path — find out before writing code.
4. Is CTS/RTR populated on the target board revision (§3.5)?
5. Does the Copper-NMI poll interact badly with esxdos's own NMI menu, or with DivMMC automap?
5b. ~~When `nmi66h` is taught to accept a software cause, how does it *distinguish* a Copper poll
   from a debuggee's own NR `0x02` write?~~ **ANSWERED, 2026-08-08: it cannot, ever, and the
   design must be shaped so that it does not need to.** CPU and Copper writes are muxed onto one
   bus with no tag carried through (`zxnext.vhd:4775-4777`) before `nmi_gen_nr_mf` computes, and
   the latch it feeds is a single untagged bit. No register anywhere records the source — checked
   across NR `0x02`, NR `0xC0`, NR `0xDA`, the `nmi_state` machine and `device/multiface.vhd`,
   whose `button_i` input is a naming trap: it is asserted for *any* accepted Multiface NMI
   (`zxnext.vhd:2169`). The question presumed the handler needs to know; it does not, if its
   contract is "poll, and break only if there is traffic" — a debuggee's own write then costs one
   wasted poll that returns immediately. See
   [ASYNCHRONOUS-BREAK-DESIGN.md](ASYNCHRONOUS-BREAK-DESIGN.md) §3.3.
6. Is Maziac interested in the transport work upstream, or is a permanent fork the honest plan?
7. ~~**Is asynchronous break reachable in UART mode too?**~~ **ANSWERED YES, 2026-08-12, AND BUILT
   FOR JOY PORT 2 — BUT BY A DIFFERENT ROUTE THAN THIS QUESTION PROPOSED.** The answer is not to
   exploit the ESP pin at all; it is to **stop clearing NR `0x0B` on resume** and to route the
   joystick pin to **UART1** (bit 0 = 1) so that doing so leaves the ESP-01's own TX and RTR
   untouched. The cable's bytes reach the machine through the joystick pin, exactly as they do while
   the debugger is stopped — no ESP bring-up, no baud coincidence, and the poll that reads them
   (`transport_poll_traffic`) was already present and already correct. Port 2 only, so the debugged
   program keeps a connector for a real joystick. ~~**What is NOT established is that it works**: no
   bench here can put a byte on that cable.~~ **ESTABLISHED IN THE EMULATOR 2026-08-13** by
   `make test-uart-break` (issue #43), which jnext#251's `--joy-uart-rx` made possible; **hardware
   is still owed**. See
   [ASYNCHRONOUS-BREAK-DESIGN.md](ASYNCHRONOUS-BREAK-DESIGN.md) §8, and §8.0.1 for the evidence ladder.

   *The route this question actually asked about — the ESP pin being the live RX source in a serial
   build — is **still unexplored and is now moot**, since it was only ever attractive while NR `0x0B`
   looked immovable. Its three obstacles as stated (bring-up, baud, nothing polling) all stand.*

Note on question 7: the hardware fact is cited, the opportunity is not. Do not promote it to a
design assumption without measuring it — see ERRORS.md on what deriving instead of reading costs.
*(That note was written about the ESP-pin opportunity and it held: the opportunity was never
measured, and what replaced it was a different mechanism read out of the same mux. The caution
applies unchanged to the built one — which **has** been exercised since 2026-08-13, in the
emulator only, by `make test-uart-break` (issue #43). On hardware it still has not.)*

---

## 12. References

**Protocol and client**
- DZRP spec — https://github.com/maziac/DeZog/blob/main/design/DeZogProtocol.md
- DeZog — https://github.com/maziac/DeZog
- Adding a new DeZog remote — https://github.com/maziac/DeZog/blob/main/design/AddingNewRemotes.md
- DeZogSerialInterface (pre-2.6.0 socket↔serial bridge; transport reference) — https://github.com/maziac/DeZogSerialInterface

**Next-side prior art**
- dezogif — https://github.com/maziac/dezogif
- dezogif design doc — https://github.com/maziac/dezogif/blob/main/documentation/Design.md
- NDS-NextDevSystem (Chris Kirby) — https://github.com/Ckirby101/NDS-NextDevSystem
- CSpect DeZog plugin — https://github.com/mikedailly/CSpectPlugins/tree/main/DeZogPlugin

**Other DZRP targets**
- NextTang — https://github.com/jattree/NextTang
- jnext — https://github.com/jorgegv/jnext · issue #12 — https://github.com/jorgegv/jnext/issues/12

**Hardware**
- ZX Spectrum Next FPGA core — https://gitlab.com/SpectrumNext/ZX_Spectrum_Next_FPGA
  (`cores/zxnext/src/zxnext.vhd`, `cores/zxnext/nextreg.txt`, `cores/zxnext/ports.txt`)
- ESP8266-01 on the Next — https://wiki.specnext.dev/ESP8266-01
- The Next on the network — https://www.specnext.com/the-next-on-the-network/
- NXtel WiFi/UART notes — https://github.com/Threetwosevensixseven/NXtel/blob/master/docs/WIFIand%20UARTReadME1st.txt

---

## Appendix A — Verification status of claims in this document

Facts checked directly against a primary source during the analysis.

**Status tiers**, in descending order of what they entitle you to assume:

- **verified** — checked against a primary source (VHDL, a spec, a source read) or produced by a
  check anyone can re-run. The strongest, and the only tier you may build on without saying so.
- **reported on hardware** — first-hand evidence from a real Next, but a single machine, a single
  reporter, and no captured artefact we can re-run. Stronger than any emulator result for
  hardware questions, weaker than anything above. Added 2026-08-04 because the ladder had no rung
  for it and a claim was briefly filed one tier too high.
- **inferred** — derived from documentation or reasoning, not observed here. Treat as a hypothesis;
  ERRORS.md exists largely because these keep turning out backwards.
- **estimate** — arithmetic or general knowledge, not measured.

**The list is not exhaustive, and the table qualifies these where it needs to.** `unverified`
is weaker than all four — nothing checked and no source to derive from, as against `inferred`,
which at least has a derivation behind it. `verified for jnext` and `verified, scoped` are the top
rung with its limits stated inline, which is preferable to a rung per shade of scope. What matters
is that a claim never sits *higher* than its evidence; sitting lower, or off the ladder with its
reason attached, is fine.

| Claim | Source | Status |
|---|---|---|
| ESP and joy-port serial share UART0 behind a mux | `zxnext.vhd:3340-3349` | **verified** |
| UART0 RX interrupt exists in the IM2 fabric | `zxnext.vhd:1943`, NR `0xC6`/`0xCA` | **verified** |
| Copper writes to NR `0x02` generate NMI | `zxnext.vhd:3830-3833` | **verified** |
| **A Copper-caused NMI cannot be told apart from a CPU-caused one** | `zxnext.vhd:4775-4777` muxes both onto one untagged bus before `nmi_gen_nr_mf`; no source is recorded in NR `0x02`, NR `0xC0`, NR `0xDA`, `nmi_state` or `device/multiface.vhd` | **verified** — answers open question 5b, by exhaustive search rather than absence of evidence |
| **The Copper instruction list is WRITE-ONLY**, so a debuggee's program cannot be saved or restored | both RAMs wire `data_a_o => open` (`zxnext.vhd:3959-3976`, `:3980-3998`); no read decode for NR `0x60`/`0x63` (`:6286-6287`) | **verified** — checked at the RAM primitive, not only at the register decode |
| NR `0x61`/`0x62` do read back, giving mode and the **load** pointer — not the running PC, not the contents | `zxnext.vhd:6083-6087`, `:5418-5437` | **verified** |
| **The Copper is the ONLY periodic NMI source**: the line interrupt, UART RX and DMA/CTC all reach the maskable INT bus only | `zxnext.vhd:1943`, `:1944`, `:2093`, `:2107-2112` | **verified** — by tracing every input of `nmi_activated` |
| A write of NR `0x62` that **changes** the mode bits to `01`/`11` restarts the Copper list from index 0 — not merely a disable, but not every write either | `device/copper.vhd:69-78`: guarded by `last_state_s /= copper_en_i`, and the reset is inside a further `copper_en_i = "01" or "11"` | **verified** — an earlier draft of this row said "any write", which overstated it |
| A second NMI arriving while the handler runs is **dropped**, not queued | `zxnext.vhd:2095-2116`, `:2164` | **verified** |
| Writing NR `0x02` bits 1:0 triggers a reset, while reading them gives reset history — so read-modify-write of that register resets the machine | `zxnext.vhd:6370-6371` against `:1306`, `:1732-1739` | **verified** — upstream's `and 10000000b` mask is what avoids it today |
| **The MF ROM half CAN grow, in 16-byte steps** — the permanent contract is the identity block's *file offset*, not its address | probed 2026-08-08: +16 bytes with `ROM_MAGIC_ADDR` moved down 16 builds clean, ROM still 8192, block still at `0x1FE0` | **verified** — corrects a claim recorded on 2026-08-07 that it cannot grow at all |
| …but every MF NMI source is gated by NR `0x06` bit 3 (default 0) | `zxnext.vhd:2090`, `:5166` | **verified** — corrects an earlier "ungated" claim |
| A software MF NMI enters the stock Multiface ROM under jnext | `make test` T3, 91% repaint | **verified** |
| **Our stub takes over on a real M1 button NMI and paints its UI** | `make test` T6, 90.28% repaint, jnext 0.99.118 `--delayed-nmi` | **verified** — the first evidence the stub runs at all |
| jnext's Multiface paging and the **entry side** of stackless NMI are good enough to run a real stub | same T6 run; answers §8.3's experiment for the entry path only | **verified, scoped** — T6 itself covers neither AltROM nor the resume; both are covered by C10/C11 below |
| **The stub RESUMES a debuggee, and the debuggee runs** | `make test-dzrp-stub` C10: fixture loaded over DZRP, `CMD_CONTINUE`, marker written, `NTF_PAUSE` naming the temporary breakpoint at 0x8016 | **verified** — the exit path and `backup.asm`'s restoration, which nothing had ever executed |
| The debuggee's registers survive the round trip in both directions | same bench, C11: `BC`/`IX` read back out of memory where the *resumed program* stored them; `PC`/`SP`/`AF`/`BC`/`DE`/`HL`/`IX` from `CMD_GET_REGISTERS` afterwards | **verified** |
| **The AltROM patch works** | C10: the breakpoint is an `RST 0`, which can only reach the debugger through the code `copy_altrom` installs at 0x0000/0x0066 — and while the debuggee runs slot 0 holds `ROM_BANK` (`main.asm:150`, restored `breakpoints.asm:192`) with the AltROM enabled (`altrom.asm:55`, the only enable, never disabled) | **verified**, in jnext and **on hardware** — C10 runs there too, through H2's delegation to the same suite |
| C10 detects a stub that answers `CMD_CONTINUE` and does not resume | two controls: bench W3 (`--no-continue`) and a ROM whose `cmd_continue` returns to `cmd_loop` instead of `restore_registers` — C10/C11 red against both | **verified** |
| **An NMI taken against a RUNNING debuggee returns a correct PC on an uncorrupted stack** — `save_nmi_return_address`'s outcome, §3.4's actual concern | **a real DeZog session on a Next, 2026-08-05**: `CMD_CONTINUE` with no breakpoint set the fixture running in its `jr $`, the M1 button was pressed, and the `NTF_PAUSE` carried break reason 1 (`MANUAL_BREAK`) with `CMD_GET_REGISTERS` returning **PC `0x801C`, SP `0x9F00`** — where it was spinning, on its own stack. `backup.pc` can only come from that routine on a press taken while `prgm_state` is `PRGM_RUNNING` | **verified on hardware** — the last unexecuted path in the entry/exit choreography. **Which branch of that routine ran is NOT distinguished**: stackless (NR `0xC2`/`0xC3`) and the stack read both give this answer, and `doc/legacy/Design.md:378,434` make stackless the presumption rather than an observation. It needed a finger on a button, which is why no bench could ever reach it |
| `CMD_PAUSE` while stopped is answered with the Length=1 response | `make test-dzrp-stub` C12, measured green; `commands.asm` maps command 7 to `cmd_pause` | **verified** — issue #8. It got **no** response until then, a failure the serial build had always had |
| DeZog's `cspect` remote really sends command 7 and blocks on it, while its `zxnext` remote never puts it on the wire | DeZog 3.7.4 `out/extension.js`: `CSpectRemote` has no `sendDzrpCmdPause` override and inherits `await this.sendDzrpCmd(7)`; `ZxNextSerialRemote`'s throws "use the yellow NMI button" | **verified** — why upstream never saw issue #8 |
| ~~dezogif declines a software MF NMI: `nmi66h` serves button causes only~~ **Upstream's did; ours has SERVED one since 2026-08-11** (issue #22), declining it only where no debugger image is in `MAIN_BANK` | `mf_rom.asm` `nmi66h`, `zxnext.vhd:3843-3848`; `make test` T4 and T9 | **verified**, both arms |
| I/O trap on `0x2FFD`/`0x3FFD` generates MF NMI | `zxnext.vhd:3835` | **verified** |
| Prescaler formula and width | `ports.txt` (`0x143B`), `uart.h` | **verified** |
| dezogif ships as `enNextMf.rom` | its `readme.md` + `releases/enNextMf.rom` | **verified** |
| dezogif memory choreography, AltROM, `RST 0` breakpoints | its `documentation/Design.md` | **verified** |
| Reverse debugging / coverage impossible on hardware | same, verbatim | **verified** |
| DeZog `cspect` remote has configurable `hostname` + `port` | DeZog `documentation/Usage.md` | **verified** |
| DeZog connects out; DZRP remotes listen (CSpect 11000, ZEsarUX 10000) | DeZog `documentation/Usage.md` | **verified** |
| `CIPSERVER` needs `CIPMUX=1`; `CIPMUX=1` needs `CIPMODE=0` | Espressif ESP8266 AT instruction set | **verified** |
| jnext refuses `AT+CIPMUX=1` with `ERROR` by design, and why | `src/esp01/include/esp01/esp_at.h` | **verified** |
| DeZog is MIT and merges outside PRs | GitHub API | **verified** |
| jnext implements stackless NMI | `src/cpu/im2.h`, `src/cpu/z80_cpu.h`, `src/port/nextreg.h` | **verified** |
| jnext does not emulate `AT+CIPMODE`/`AT+CIPSERVER` | `src/esp01/include/esp01/esp_at.h` | **was verified; `AT+CIPSERVER` NO LONGER TRUE** — shipped in 0.99.118 (jnext#210). `AT+CIPMODE` still absent |
| **The ESP can be brought up as a TCP server from Z80 and echo over a socket** | `make test-esp` E1-E4, jnext 0.99.118 | **verified** — M0(b) |
| **The `+IPD` connection id must be read, not assumed** | same bench, broken deliberately: id hardcoded to `0` fails E2-E4, to `1` fails only E4 | **verified** |
| jnext's inbound connection ids start at 1, not 0 | `esp_at.h` simplification 8a; observed as `accepted as cid 1` / `cid 2` | **verified for jnext** |
| **Real ESP-AT firmware assigns the first inbound connection id 0** | the WiFi build failing completely on a Next, 2026-08-04: the stub used `esp_conn_id == 0` as its "no client" marker and discarded every reply | **verified indirectly** — by the failure it caused, not by observation; no PC-side check can see the ids |
| **A configured Next comes up already associated**, so the stub never needs to join a network | user's own machine, reported 2026-08-04 | **reported on hardware** — a rung the verified/inferred ladder lacked. First-hand and load-bearing, but one machine, one reporter, no captured artefact, and nothing we can re-run |
| Real ESP-AT firmware answers at 115200 until told otherwise | hardware bench H1 connected in 274 ms, so the whole AT chain was accepted at that rate | **verified** (2026-08-05) |
| ESP TCP throughput | **measured on hardware**: 8192 bytes across the wire in 1.01 s = 71% of what 115200 8N1 can carry | **verified** (2026-08-05) |
| Round-trip latency 10-100 ms | **measured on hardware**: min 10.8 ms, median 13.0 ms, max 23.6 ms over 20 samples | **verified** (2026-08-05) — at the good end of the estimate |
| The stub resumes a debuggee, and its state survives | conformance C10/C11, in jnext and then on a Next | **verified**, both places |
| **No scan in the ESP transport destroys an inbound `+IPD`** | issue #11. Bench W4 in jnext (red on `main`, red on the intermediate fix, green after); hardware bench H3, 3 runs of 3 green at build 000A, against 3 failures of 3 before it | **verified**, both places — and the two halves are covered in different places: jnext can only reach the `AT+CIPSEND` prompt window, hardware only the `SEND OK` one |
| The `SEND OK` window on a real module is 20-50 ms wide | measured on a Next, 3 trials at each of 8 delays: lost at 0/2/5/10/20 ms, clean at 50/100/250 ms | **verified** — and note a nine-character `SEND OK` costs ~2 ms at 115200, so the window is not the transmission |
| A single client that pipelines loses commands the same way | tested on a Next, one connection, 3 trials at each of 8 delays including 0 ms: never lost one | **disproved as stated** — the discriminator is a *second connection*, not the timing alone. The mechanism behind that is a reading, not a measurement |
| **DeZog drives the stub on real hardware: attach, disassemble, registers, memory, single-step, manual break, clean disconnect, reattach** | a logging TCP tap between VS Code and a Next, 2026-08-05, frozen snapshot: `DeZog vv24.18.0` ↔ `dezogif v2.2.1`, 121 `CMD_READ_MEM`, 26 `CMD_GET_REGISTERS`, **22 `CMD_CONTINUE` each answered by an `NTF_PAUSE`** — at `0x8017`, `0x8019`, then `0x801C`, plus one `MANUAL_BREAK` — then `CMD_PAUSE` + `CMD_CLOSE` both answered | **verified** — the last item of M1, and the answer to open question 1 |
| The stub can be left unable to serve anyone, recovered only by power-cycling | two occurrences in one evening; TCP still accepted (accept latency degraded 83 ms → 389 ms → timeout), no border flicker, screen intact. NOT caused by a clean disconnect — that was measured and is safe | **verified that it happens; the mechanism is a hypothesis** — issue #15, design in #16 |
| The connect string draws a correct address on hardware | user's own machine, 2026-08-05, at a 15-character address | **reported on hardware** — one machine, one reporter, no re-runnable artefact |
| ~~NMI poll costs ~100-200 T-states/frame~~ **It costs ≈1288 T-states/frame** — 0.230% of a frame at 28 MHz, and 1.84% of one at 3.5 MHz | `make measure-poll-cost`, 2026-08-11: a fixed-length counting loop, two builds one constant apart, HL differenced across nine frames; bit-identical over three runs. The clock is read off the machine (NR 0x07 = 0x33) | **verified** in jnext — which counts the same T-states a Next does — for the DECLINE path only, and never on hardware. The 3.5 MHz figure is arithmetic from the 28 MHz measurement. **NARROWED 2026-08-13: the link check is NOT in this figure.** The fixture brings no debugger up, so the handler declines at its magic-number compare, *before* the `jp mf_nmi_poll` that reaches `transport_poll_traffic` — proved by control, a ~3300 T-state delay loop planted there moving the reading by nothing. A real session pays this plus the link check, ~100 T-states more by instruction timing, measured nowhere |
| CTS/RTR populated on a given board | — | **unverified** |
| tbblue does not checksum `enNextMf.rom` | inferred from dezogif working | **inferred** |
| DZRP has no history/trace/replay command | full grep of `design/DeZogProtocol.md` | **verified** |
| DeZog reverse debugging stores registers+stack only, not memory | DeZog `documentation/Usage.md` §Reverse Debugging | **verified** |
| `CMD_READ_STATE`/`WRITE_STATE` is `-state save/restore`, not time travel | DZRP spec + Usage.md §State Save/Restore | **verified** |
| DeZog `load` writes the program into the target for socket remotes | DeZog `documentation/Usage.md` | **verified** |

---

## Appendix B — End-to-end workflow (WiFi mode)

*UART mode's workflow is upstream dezogif's, unchanged: serial cable, `remoteType: "zxnext"`,
and no PC-initiated break.*

What using this actually looks like, once M2 is complete. Machine column is where each operation
happens.

### B.1 One-time setup

| # | Where | Operation |
|---|---|---|
| A1 | PC | Install VS Code + the DeZog extension |
| A2 | PC | `make mfselect` — it builds **both** stub ROMs (`build/enNextMf-wifi.rom`, `build/enNextMf.rom`), their `.sum` sidecars and `build/mfselect.nex`, and gathers all five into `build/deploy/` under the names and in the directories the card wants |
| A3 | PC | SD card into the PC; back up `machines/next/enNextMf.rom`; `cp -r build/deploy/* <card>/`, which is the whole of it — the tree already carries the layout, so nothing is renamed or placed by hand ([MFSELECT.md](MFSELECT.md)). **Do not copy a stub over the official path by hand** — leave the stock ROM there and let mfselect capture it, or its first-run guard will refuse and you will have no backup |
| A3b | Next | Boot NextZXOS, `.nexload /mfselect/mfselect.nex`, let it capture the original, then pick **dezogif_ng WiFi (ESP-01)** and power-cycle. Switching to the UART build later, or back to the stock ROM, is the same three keystrokes and never needs a PC again |
| A4 | Next | Confirm core ≥ 03.01.10 and Multiface enabled in the machine config |
| **A5** | **Next** | **Get the Next onto WiFi**, with `/apps/wifi/setup/wifi2.bas`, and confirm it reports an IP address. **The stub never does this and holds no credentials** — see [WIFI-SETUP.md](WIFI-SETUP.md), which also covers what breaks it later. Once per machine — the ESP stores its own credentials, reported on hardware 2026-08-04 |
| A6 | PC | Give the Next a **static DHCP reservation** on the router — then its IP never moves and `launch.json` is written once |
| A7 | PC | Write `launch.json` (§B.5) |

Three acts on the Next, all once ever — and A5 is the one people will forget, because a debugger
that cannot reach the network looks like a broken debugger rather than a machine that was never put
on WiFi.

**A3 no longer means "copy the stub over the official path", and the change matters.** With
mfselect on the card the swap happens on the Next, both ways, and the card carries both variants —
so a debuggee that owns the ESP (the contention row in §10) is a menu entry away rather than a PC
session away. Doing the hand-copy anyway is what trips mfselect's first-run guard: it refuses to
save *our* ROM as your original, correctly, and then you have no backup at all.

### B.2 Every power-on

| # | Where | Operation |
|---|---|---|
| B1 | Next | Power on. NextZXOS boots; tbblue.fw loads your `enNextMf.rom` into page 0x0A |
| B2 | Next | **Press the NMI button once.** The stub copies `MAIN` into a RAM bank, runs `AT+CIPMUX=1` / `AT+CIPSERVER=1,11000`, and prints its IP and port on screen |
| B3 | Next | The stub returns control. NextZXOS is usable again — **the ESP holds the listening socket, so the listener survives while the machine is used normally** |

One button press per power-on. Re-initialise later with Symbol Shift (CTRL on a PS/2 keyboard)
held while pressing NMI, exactly as dezogif does.

### B.3 The edit-debug cycle — entirely from the PC

| # | Where | Operation |
|---|---|---|
| C1 | PC | Edit source in VS Code |
| C2 | PC | Build task → `program.nex` + `program.sld` |
| C3 | PC | **F5** |
| C4 | PC → wire | DeZog opens TCP to `<next-ip>:11000` |
| C5 | Next | ESP accepts; `+IPD` lands in the 512-byte UART RX FIFO; the Copper-driven NMI poll sees it within one frame; the stub enters its debug loop |
| C6 | wire | `CMD_INIT` — version negotiation |
| C7 | wire | `CMD_WRITE_BANK` × N — **DeZog pushes the .nex bank by bank over WiFi** |
| C8 | wire | `CMD_ADD_BREAKPOINT` — the stub patches `RST 0` at each address through the slot-6 SWAP window |
| C9 | wire | `CMD_CONTINUE`, or the program waits at entry with `startAutomatically: false` |
| C10 | Next | The program runs at full speed; the debugger is dormant |
| C11 | Next → PC | Breakpoint hit → `RST 0` → stub → `NTF_PAUSE` |
| C12 | PC | Source line, registers, memory, call stack. Each panel issues `CMD_GET_REGISTERS` / `CMD_READ_MEM` / `CMD_GET_SPRITES` as needed |
| C13 | PC | Step: DeZog computes instruction length and branch target, plants 1-2 temporary breakpoints, `CMD_CONTINUE`, waits for `NTF_PAUSE`. **One round trip per step** |
| C14 | PC | Shift+F5 → `CMD_CLOSE`. The stub returns control and keeps listening |
| C15 | PC | Edit and F5 again |

No SD card handling and no NextSync anywhere in this loop: the program travels over the same
WiFi link as the debug traffic.

### B.4 Breaking into a running program

| # | Where | Operation |
|---|---|---|
| D1 | PC | Press Pause in VS Code → `CMD_PAUSE` |
| D2 | Next | The byte lands in the UART RX FIFO; the Copper NMI, firing at a fixed raster line every frame, polls it, sees traffic and breaks |
| D3 | Next → PC | `NTF_PAUSE`. Breakpoints can now be set without touching the machine |

This is the entire point of the WiFi variant. dezogif requires walking over and pressing a
button.

### B.5 `launch.json`

```json
{
  "type": "dezog",
  "request": "launch",
  "remoteType": "cspect",
  "cspect": { "hostname": "192.168.1.42", "port": 11000 },
  "sjasmplus": [{ "path": "program.sld" }],
  "load": "program.nex",
  "rootFolder": "${workspaceFolder}",
  "topOfStack": "stack_top",
  "startAutomatically": false,
  "history": { "reverseDebugInstructionCount": 10000 }
}
```

`remoteType: "cspect"` is not a mistake — it is DeZog's generic DZRP-over-socket client, and
`hostname` points it anywhere (§7). Exact key names to be confirmed against DeZog's docs at M1.

### B.6 What still needs hands on the Next

- Power on, and one NMI press per session.
- Recovering from a wedged stub or ESP: Symbol Shift + NMI, or a power cycle.
- Any hard reset — DZRP has no reset command.

### B.7 What to expect

- **A single step is a WiFi round trip**, roughly 30-100 ms. Interactive stepping is
  comfortable; stepping thousands of times is not. Breakpoints are the tool for deep loops.
- **`.nex` loading is partial**, by DeZog's own admission: loading screens are not displayed,
  the file-handle address is ignored, and only bank data plus the border are set. A program that
  depends on NEX loader side effects should be loaded normally and attached to instead.
- **Nothing else may use the ESP during a session** — NextSync and friends will reconfigure the
  module out from under the stub.

---

## Appendix C — Reverse debugging: what it is and what it is not

This appendix exists because the distinction was **initially got wrong in this document**, and
the error is an easy one to repeat.

### C.1 The feature

Reverse debugging — also called time-travel, historical or replay debugging, and the same idea
as jnext's own *backward execution* — lets you step **backwards** through instructions already
executed, inspecting state from the past. In VS Code it is two extra buttons: step back one
instruction, and run backwards until a breakpoint or the start of history.

### C.2 How DeZog implements it

Entirely **on the PC**. DeZog keeps a ring buffer of what it has observed, sized by:

```json
"history": { "reverseDebugInstructionCount": 10000 }
```

At roughly 40 bytes per instruction, 10 000 entries is ~400 KB; 1 second of a 4 MHz Z80 would be
about 40 MB, and 1 GB buys about 25 seconds.

The critical limitation, in DeZog's own words:

> "The history stores only the register values and stack contents. I.e. the memory or other HW
> state is not stored. So whenever a memory location is changed from the program code in reverse
> debugging this will not be reflected in e.g. the memory view. You can only rely on the register
> values."

Consequences: the memory view is wrong while stepping back, and a breakpoint condition that
reads memory (`b@(HL) == 0`) **fires unconditionally** in reverse mode. It is a *trace replay of
registers*, not a restoration of machine state.

### C.3 What DZRP does not have

**DZRP contains no history, trace or replay command.** A full-text search of the protocol
specification for "history", "trace", "reverse" and "time travel" returns only the spec's own
changelog heading. The 29 commands cover registers, memory, banking, breakpoints, watchpoints,
ports, sprites and state save/restore — and nothing else.

So no DZRP remote, emulator or hardware, contributes anything to reverse debugging. It is
DeZog-side, and it works identically against every remote.

Where the richer variant exists is **ZEsarUX**, whose `cpu-history` command supplies real
executed-instruction history so DeZog can step back through code that ran at full speed rather
than only through steps it made itself. That command belongs to **ZRCP**, ZEsarUX's own
protocol, not to DZRP. It is unreachable from a DZRP remote.

### C.4 What `CMD_READ_STATE` / `CMD_WRITE_STATE` actually are

A different feature entirely: the debug-console commands `-state save <name>` and
`-state restore <name>`, for snapshotting the machine before a crash and returning to it. The
payload is defined as *"arbitrary data. The format is up to the remote."*

It is a bookmark, not a time machine. **Conflating it with reverse debugging is the error this
appendix documents.**

### C.5 Consequence for jnext

jnext's backward execution (frame-start snapshots plus replay, with all 22 subsystems
serialised) is **strictly more capable than DeZog's**, because it restores real machine state
including memory rather than replaying a register trace.

And DZRP cannot express it. If DeZog is ever to drive jnext's rewind, that needs a **protocol
extension** — a genuine upstream conversation with the DeZog maintainer, not a matter of
implementing an existing command. What jnext *can* offer over DZRP today is `-state
save`/`restore` via `CMD_READ_STATE`/`CMD_WRITE_STATE`, real watchpoints, and sprite
introspection.
