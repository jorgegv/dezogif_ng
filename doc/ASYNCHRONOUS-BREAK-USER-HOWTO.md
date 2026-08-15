# Pausing a running program from the PC

**How to make a program breakable from DeZog's Pause button, what it costs, and when it will
not work.**

The design reasoning is in [ASYNCHRONOUS-BREAK-DESIGN.md](ASYNCHRONOUS-BREAK-DESIGN.md); it is
not needed to use this.

**Exception note:** Example code included in this document is an exception to the general license
for this repository, and is explicitly licensed according to MIT License, on the same terms
specified for the original Maziac code in the NOTICE file at the root of the repository.

---

## What it gives you

Without it, once Continue is pressed there are two ways back into the debugger: the program
reaches a breakpoint, or somebody presses the **M1 button** on the Next.

With it, **Pause in VS Code stops the program** wherever it is, and breakpoints and memory can
be inspected without touching the machine.

## What to add to the program

**Forty-four bytes, once, at the start.** Two Copper instructions raise the Multiface NMI once
per frame; the debugger's handler polls the debug link on each one and returns immediately
unless the PC has sent something.

The debugger cannot install them itself. The Copper's instruction list is **write-only** — the
instruction RAMs discard their CPU-side read output and NR `0x60`/`0x63` have no read decode —
so a debugger that installed its own list could never give the original back. The program owns
the Copper, so the program installs the two instructions.

```asm
; --- asynchronous break: let the PC stop this program -------------------
; Two Copper instructions raise the Multiface NMI once per frame. The
; debugger's handler polls the debug link and returns immediately unless
; the PC has said something, so this costs ~0.23% of a frame and nothing
; else. Remove it (or assemble it out) for a release build.

BREAK_LINE:     equ 100         ; any raster line; see "choosing a line"

    ; NR 0x06 bit 3 gates EVERY Multiface NMI source, and its power-on
    ; value is 0. NextZXOS leaves it set, so these seven bytes are
    ; insurance against what the firmware happened to leave behind.
    ld bc,0x243B
    ld a,0x06
    out (c),a
    ld bc,0x253B
    in a,(c)
    or 0x08
    out (c),a

    ; Stop the Copper and put its write pointer at index 0.
    nextreg 0x62,0              ; control: stopped
    nextreg 0x61,0              ; address LSB = 0

    ; The list, MSB first:
    ;   WAIT line,0   = 0x8000 | (hpos<<9) | line
    ;   MOVE $02,$08  = (reg<<8) | value   -> NR 0x02 bit 3, the MF NMI
    nextreg 0x60,(0x8000 + BREAK_LINE) >> 8
    nextreg 0x60,(0x8000 + BREAK_LINE) & 0xFF
    nextreg 0x60,0x02
    nextreg 0x60,0x08

    ; Run it from index 0, looping.
    nextreg 0x62,01000000b
; ------------------------------------------------------------------------
```

**Twenty-eight bytes** without the NR `0x06` block. NextZXOS leaves that bit set, so the block
is only needed by a program that writes NR `0x06` itself.

The encoding is from the FPGA source (`device/copper.vhd:91-104`): `WAIT` is bit 15 = 1, bits
14:9 = hpos, bits 8:0 = line, and it fires when `vcount = line` and `hcount >= hpos*8 + 12`;
`MOVE` is bit 15 = 0, bits 14:8 = the NextREG number, bits 7:0 = the value.

### If the program already uses the Copper

Add `WAIT <line>,0` and `MOVE $02,$08` **to the existing list**, at any raster position, and
leave the rest of it alone. That is all the debugger needs — it does not care where in the list
the two instructions sit or what else the list does.

### Choosing a line

Any line works. `100` is mid-screen and well clear of the border. The NMI arrives at that
raster position every frame, so a program with raster-timed effects should put the break
somewhere it does not care about: the interruption is short, but it is not free and it is
always in the same place.

### Turning it off

Assemble it out for release. It is a contiguous block with no other dependency, so an
`IFDEF DEBUG` around it is enough; nothing else in the program changes.

## What it costs while it is in

Measured with `make measure-poll-cost`:

|                                               |                                      |
| --------------------------------------------- | ------------------------------------ |
| the poll, per frame, when nothing has arrived | **1288 T-states**                    |
| as a fraction of a frame at **28 MHz**        | **0.230%** — measured                |
| as a fraction of a frame at **3.5 MHz**       | **1.84%** — arithmetic, not measured |

Plus the 44 bytes, plus the Copper list, plus the raster line.

**THAT FIGURE IS A FLOOR, NOT THE WHOLE BILL, AND THE INSTRUMENT CANNOT SEE THE REST.**
`make measure-poll-cost` runs its fixture with **no debugger brought up**, so the handler declines
at its "is our image really there?" check and never reaches the part that looks at the debug link
at all. Proved rather than assumed: planting a ~3300 T-state delay loop inside the link check moves
the measurement by **nothing**. What a real session pays is the 1288 above **plus** that check —
of the order of another 100 T-states by instruction timing, which is **arithmetic and has been
measured nowhere**. Nothing here is affected by build `00.24`'s extra 39 T-states except that they
are part of the unmeasured remainder.

The poll does **not** change the machine's clock speed. It runs at whatever clock the program
is running at.

## If your program uses the other UART

It may, and the break still works — that is what build `00.24` fixed. One thing to know:

**The debugger selects its own UART channel whenever it takes control, and does not give your
selection back.** So after any break — a breakpoint, the M1 button, or a Pause — port `0x153B`
points at the debugger's channel, and your program's next UART access goes to the wrong one unless
it selects again. **Select your channel where you use it rather than once at start-up** and the
question does not arise.

While your program is *running* the pointer is yours: the poll borrows it for a single status read
and restores it before the interrupt returns, so a program that never breaks never notices.

This is the same shape as the NextREG select latch, which the debugger also does not preserve, and
for the same reason — the value belongs with the debugger's other break-time captures and is not
saved there yet.

## When it will not work

Seven states, in rough order of how likely they are to be met. None of them damages anything: in
each, Pause simply does nothing until the state passes, and the M1 button always still works.

**1. A UART (serial) build with the cable on joy port 1.** Over a cable the break works on
**joy port 2 only** — the stub's screen says which you have, on the line under the port
selection: `PC break: ready` or `PC break: needs Joy 2`. Press **2** on the stub's screen and
put the cable in the right-hand connector.

The reason it is one port and not both is that the port selector is what decides whether the
cable's receive line stays connected while your program runs, and the connector holding the cable
cannot also hold a joystick. Port 2 keeps the line live so a Pause can land; port 1 is left alone
so that the debugged program keeps the left connector, which is where the first stick goes. See
ASYNCHRONOUS-BREAK-DESIGN.md §8.3.

*(**That used to read "so that the debugged program gets a real joystick on the left connector",
and it claimed more than the machine delivers.** What port 1 keeps is the *connector*, not a
fully working joystick: i/o mode is global, so both connectors lose the same things whichever one
holds the cable — see the table below. Preferring port 2 is convention, not hardware.)*

### What holding a joy port costs your joysticks

**It applies to both ports and to WiFi mode too, and NO PORT CHOICE AVOIDS ANY OF IT.** The
switch is NR `0x0B` bit 7 — joystick i/o mode — and it is **global**: it does not name a
connector, so turning it on for one changes what *both* report. Choosing port 2 over port 1
decides where the cable goes and nothing else.

| what your program reads | while the debugger holds a joy port |
|---|---|
| **Kempston** (port `0x1F`) — directions and the two fire buttons | **works**, both connectors |
| **MD** (port `0x37`) — directions and the two fire buttons | **works**, both connectors |
| **MD 6-button extended buttons** — START, MODE, X, Y, Z | **read as 0**, both connectors |
| **Sinclair, Cursor, user-defined** joystick types | **nothing at all**, both connectors |

So a game reading Kempston has a working stick throughout. A game that wants **START on a
Mega Drive pad**, or that uses the Sinclair or Cursor mappings, does not — and cannot be given
one by putting the cable in the other socket.

**Why, in one line each.** In i/o mode the joystick scanner publishes `"000000" & not joy_raw`
(`input/md6_joystick_connector_x2.vhd:188-190`), zeroing bits 11:6, and the Kempston and MD port
reads take their bits 7:6 from exactly those (`zxnext.vhd:3477-3492`) — that is the extended
buttons gone. The keyboard-key injection the Sinclair and Cursor types rely on is switched off
outright (`input/membrane/membrane_stick.vhd:190`). Both are in words at `nextreg.txt:203-206`:
*"While in i/o mode, keyboard joystick types (Sinclair, Cursor, etc) produce no readings but the
current state of pins can still be read via the Kempston ports."*

**THE ESCAPE HATCH IS SELECTION 3, AND IT IS THE ONE THING THAT GETS THEM ALL BACK.** With
`3 = No joystick port` the debugger never turns i/o mode on, so both connectors behave exactly
as they would with no debugger attached — every joystick type, every button. What you give up is
**this feature**: the cable is then on the WiFi connector CN9 rather than a joy port, and Pause
does nothing (see state 1 above). That is the whole trade, and it is a real one: if your program
needs START, take option 3 and break in with the M1 button.

*(**Do not read the extended-button row as new, or as a cost of asynchronous break.** It is
inherent to running the UART on a joystick port and predates all of this — Maziac's own note on
dezogif says so: *"If UART is connected to the joyport only normal joysticks would work, not MD.
At the moment also MD works because I'm constantly switching the UART at the joyport."* That
constant switching is exactly what the port-2 selection stops doing, so what asynchronous break
changes is **when** you pay: before, only while the debugger was stopped; now, for as long as
your program runs too. It was first seen on real hardware on 2026-08-15, having until then been
a reading of the VHDL.)*

*(**This state read "UART builds — in practice this is a WiFi-mode feature. Use the WiFi ROM"
until 2026-08-12.** That was true of the code and was never a property of the machine: the poll
already existed in the serial build and was already correct, and the one thing stopping it was
four bytes of ours that severed the cable's receive line on every resume. See the design doc §8.2.)*

**2. While the machine is inside an esxDOS / DivMMC call.** Any live DivMMC automap session
blocks **every** Multiface NMI for its whole duration — the poll and the M1 button alike. Not
just the DivMMC NMI menu: any file I/O, any dot command, any `RST 8` trap window
(`zxnext.vhd:2107` against `device/divmmc.vhd:148-150`). Requests are dropped rather than
queued, so each lost poll simply retries next frame; but a program sitting inside a long esxDOS
call cannot be paused until it comes out.

**3. If the program clears NR `0x06` bit 3.** That gates every Multiface NMI source. The break
then dies **silently** — Pause does nothing and nothing says why — and the only way back is an
M1 press. The poll cannot re-assert the bit, because the poll is the thing that stops running.

**4. If the program stops or restarts its own Copper.** A write of NR `0x62` that *changes* the
mode bits restarts the list from index 0, mode `00` stops it outright, and writing list content
through NR `0x60` overwrites whatever was there. Since the two instructions belong to the
program, this is under its control: restart the list and the break comes back with it.

**5. While `.mfinstall` is writing a ROM.** Config mode suppresses every Multiface NMI while it
is active. It is a window of milliseconds and it self-recovers.

**6. If the program writes NR `0x0B` (serial builds only).** That is the joystick i/o mode:
clearing it disconnects the cable's receive line, which is exactly what the debugger stopped doing
in order to make the break work. It kills the break **silently**, and the M1 button is the way
back. A program that wants its own joystick i/o mode can have it; it cannot have it and
PC-initiated break at the same time.

*(**This state used to name port `0x153B` as well, and that is FIXED as of build `00.24`.** The
machine has two UARTs so that two owners can coexist, and `0x153B` is only the pointer saying which
one the CPU's UART registers currently refer to — not a resource the debugger owns. The poll now
borrows the pointer for its one status read and hands it straight back, so **your program may use
the other UART and still be paused from the PC**. See "If your program uses the other UART" above
for the one thing you do have to know, and ASYNCHRONOUS-BREAK-DESIGN.md §8.5 for why guarding it
was preferred to documenting it.)*

**7. After a reset, until the next M1 press (serial builds).** Any reset puts NR `0x0B` back to
disabled (`zxnext.vhd:4939-4941`), so the cable's receive line is disconnected again and Pause
stops working. The debugger re-arms it the next time it takes control, so one M1 press is the
whole cure. The same shape as state 3, and with the same tell: nothing says why.

## How to tell it is working

Press Pause and look at the PC, not at the Next — there is deliberately nothing to see on the
machine:

- **The Next's screen does not change when a break happens.** A poll break goes to the
  debugger's command loop, which does not repaint.
- What *does* change: **the border resumes cycling** (the debugger is executing again), and
  DeZog shows the program stopped, with registers and a call stack.
- DeZog reports the stop as **`Manual break`**, the same reason an M1 press gives. DZRP has no
  break reason meaning "the PC asked".

If Pause does nothing: on a **serial** build check the stub's screen reads `PC break: ready`
rather than `PC break: needs Joy 2` (state 1), and that nothing has reset the machine since the
last M1 press (state 7). On **either** build, check the two instructions really are in the list,
and that NR `0x06` bit 3 has not been cleared (state 3). Then press M1, which always works.
