# Pausing a running program from the PC

**How to make a program breakable from DeZog's Pause button, what it costs, and when it will
not work.**

The design reasoning is in [ASYNCHRONOUS-BREAK-DESIGN.md](ASYNCHRONOUS-BREAK-DESIGN.md); it is
not needed to use this.

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

| | |
|---|---|
| the poll, per frame, when nothing has arrived | **1288 T-states** |
| as a fraction of a frame at **28 MHz** | **0.230%** — measured |
| as a fraction of a frame at **3.5 MHz** | **1.84%** — arithmetic, not measured |

Plus the 44 bytes, plus the Copper list, plus the raster line.

The poll does **not** change the machine's clock speed. It runs at whatever clock the program
is running at.

## When it will not work

Five states, in rough order of how likely they are to be met. None of them damages anything: in
each, Pause simply does nothing until the state passes, and the M1 button always still works.

**1. UART (serial) builds.** In practice this is a **WiFi-mode feature**. A serial build hands
the joy ports back to the program when it resumes, which re-points UART0's receive line away
from the joystick pin the cable is on — so the PC's bytes have nowhere to land while the
program runs. The poll fires and finds nothing. Use the WiFi ROM.

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

## How to tell it is working

Press Pause and look at the PC, not at the Next — there is deliberately nothing to see on the
machine:

- **The Next's screen does not change when a break happens.** A poll break goes to the
  debugger's command loop, which does not repaint.
- What *does* change: **the border resumes cycling** (the debugger is executing again), and
  DeZog shows the program stopped, with registers and a call stack.
- DeZog reports the stop as **`Manual break`**, the same reason an M1 press gives. DZRP has no
  break reason meaning "the PC asked".

If Pause does nothing: check that the WiFi ROM is the one running (state 1), that the two
instructions really are in the list, and that NR `0x06` bit 3 has not been cleared (state 3).
Then press M1, which always works.
