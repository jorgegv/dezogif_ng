# Pausing a running program from the PC

**How to make your own program breakable from DeZog's Pause button, what it costs, and the
five states in which it will not work.**

This is the user's half of milestone M2. The design reasoning is in
[ASYNCHRONOUS-BREAK-DESIGN.md](ASYNCHRONOUS-BREAK-DESIGN.md); you do not need to read it to
use this.

---

## What it gives you

Without it, once you press Continue there are exactly two ways back into the debugger: your
program reaches a breakpoint, or somebody walks to the Next and presses the **M1 button**.
That is upstream dezogif's headline limitation, and it is not a figure of speech — it was
measured on a real Next on 2026-08-10, where a `CMD_CONTINUE` into a program that never
reached a breakpoint left the machine not answering DeZog for **four minutes with no
recovery**, and then recovered **immediately** on an M1 press.

With it, **Pause in VS Code stops the program**, wherever it is, and you can set breakpoints
and inspect memory without touching the machine.

## What you have to add to your program

**Forty-four bytes, once, at the start.** The debugger does *not* install this and cannot:
the Copper's instruction list is **write-only** — both instruction RAMs discard their
CPU-side read output and NR `0x60`/`0x63` have no read decode — so a debugger that installed
its own list could never give you yours back. Your program owns the Copper; therefore your
program installs the two instructions.

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

**Twenty-eight bytes** if you drop the NR `0x06` block and trust NextZXOS to have left bit 3
set, which it does. Keep it if your program touches NR `0x06` itself.

The instruction encoding is read from the FPGA source (`device/copper.vhd:91-104`), not from
a wiki: `WAIT` is bit 15 = 1, bits 14:9 = hpos, bits 8:0 = line, and it fires when
`vcount = line` and `hcount >= hpos*8 + 12`; `MOVE` is bit 15 = 0, bits 14:8 = the NextREG
number, bits 7:0 = the value.

**Do not copy the `ei : halt : di` prologue** you will find at the top of
`test/copper_poll.asm`. That is a workaround for a defect in the emulator's `--inject`, not
something a real program needs.

### If you already use the Copper

Add `WAIT <line>,0` and `MOVE $02,$08` **to your own list**, at a raster position of your
choosing, and leave the rest of it alone. That is all the debugger needs; it does not care
where in your list the two instructions sit or what else the list does.

### Choosing a line

Any line works. `100` is mid-screen and well clear of the border. The NMI arrives at that
raster position every frame, so if your program has raster-timed effects, put the break
somewhere it does not care about — the interruption is short but it is not free, and it is
always in the same place.

### Turning it off

Assemble it out for release. It is a contiguous block with no other dependency, so an
`IFDEF DEBUG` around it is enough. Nothing else in your program changes.

## What it costs while it is in

**Measured, not estimated** — `make measure-poll-cost`, and the figure is re-runnable:

| | |
|---|---|
| the poll, per frame, when nothing has arrived | **1288 T-states** |
| as a fraction of a frame at **28 MHz** | **0.230%** — measured |
| as a fraction of a frame at **3.5 MHz** | **1.84%** — arithmetic, not measured |

Plus the 44 bytes, plus your Copper list, plus the raster line.

The project plan carried "~100-200 T-states/frame (≈0.3%)" as an estimate for years. It was
**6-13× low**, which is why the measurement exists and why it is quoted here rather than
the estimate.

The poll does **not** change the machine's clock speed, which was the perturbation the
design originally worried about most. It runs at whatever clock your program is running at.

## When it will not work

Five states, in rough order of how likely you are to meet one. None of them damages
anything; in each, Pause simply does nothing until the state passes, and the M1 button
always still works.

**1. UART (serial) builds.** In practice this is a **WiFi-mode feature**. A serial build
hands the joy ports back to your program when it resumes you, which re-points UART0's
receive line away from the joystick pin the cable is on — so the PC's bytes have nowhere to
land while your program runs. The poll fires and finds nothing, for ever. Use the WiFi ROM.

**2. While the machine is inside an esxDOS / DivMMC call.** Any live DivMMC automap session
blocks **every** Multiface NMI for its whole duration — the poll included, and the M1 button
too. Not just the DivMMC NMI menu: any file I/O, any dot command, any `RST 8` trap window.
Requests are dropped rather than queued, so each lost poll simply retries next frame; but a
program sitting inside a long esxDOS call cannot be paused until it comes out. Nothing in
software can see this happen. (`zxnext.vhd:2107` against `device/divmmc.vhd:148-150`.)

**3. If your program clears NR `0x06` bit 3.** That gates every Multiface NMI source. The
break then dies **silently** — Pause does nothing and nothing says why — and the only way
back is an M1 press. Re-asserting it from the poll cannot work, because once the break is
off, the poll is the thing that would have re-asserted it.

**4. If your program stops or restarts its own Copper.** A write of NR `0x62` that *changes*
the mode bits restarts the list from index 0, and mode `00` stops it outright; writing list
content through NR `0x60` overwrites whatever was there. Since the two instructions are
**yours**, this is under your control — which is the main practical advantage of the program
installing them rather than the debugger. Restart your list and your break comes back with
it.

**5. While `.mfinstall` is writing a ROM.** Config mode suppresses every Multiface NMI while
it is active. It is a window of milliseconds and it self-recovers.

## How to tell it is working

The honest answer is: **press Pause and see**. There is deliberately nothing to look at on
the Next, and that is worth knowing before you go hunting for it —

- **The Next's screen does not change when a break happens.** A poll break goes to the
  debugger's command loop, which does not repaint. This cost a session two runs of
  misdiagnosis on 2026-08-10, when an M1 press was read as "did nothing".
- What *does* change: **the border resumes cycling** (the debugger is executing again), and
  DeZog shows the program stopped, with registers and a call stack.
- DeZog reports the stop as **`Manual break`** — the same reason an M1 press gives. DZRP has
  only three break reasons and none of them means "the PC asked", so inventing one would
  have meant inventing a protocol.

If Pause does nothing: check you are on the WiFi ROM (state 1), check the two instructions
really are in your list, and check you have not cleared NR `0x06` bit 3 (state 3). Then
press M1, which always works.

## What has been tested, and what has not

**In the emulator**, and re-runnably: a debuggee run free with `CMD_CONTINUE` and no
breakpoint anywhere is stopped by `CMD_PAUSE` from the PC, reports `MANUAL_BREAK` with the
correct `PC` and `SP`, answers the `CMD_PAUSE`, and serves on afterwards — with a control run
in which the pause is withheld and nothing comes back (`make test-dzrp-stub`, check **W8**).
And the poll declining ~50 times a second against a *stopped* debugger, with the stub still
answering its own keyboard afterwards (`make test`, check **T9**).

**Not tested:** any of it on a **real ZX Spectrum Next**. Every result above is jnext's, and
this project has twice been caught by the emulator sitting on the safe side of reality — a
connection id of 0 and a 15-character IP address, both of which passed every emulator check
and failed on the bench-top. The DivMMC and NR `0x06` behaviour in "When it will not work"
is read from the FPGA source and has not been watched happening. And nothing has driven this
from **DeZog itself**; W8 speaks DZRP directly.

Treat the first hardware run as the real test, and expect it to find something.
