# mfinstall — installing the debugger ROM without touching the SD card

`.mfinstall` is a NextZXOS **dot command** that writes a dezogif_ng ROM straight into the
Multiface ROM's SRAM at run time, through the Next's **config mode**. Nothing on the SD card
changes. Because it is a dot command it takes a command tail, so `AUTOEXEC.BAS` can call it and
the machine can come up with the debugger already installed.

Filed as [issue #21](https://github.com/jorgegv/dezogif_ng/issues/21).

## Read this first: what "install" and "unload" mean here

**This is not mfselect with a different user interface.** The two tools do genuinely different
things, and confusing them will cost you an evening.

| | `mfselect` | `.mfinstall` |
|---|---|---|
| What it writes | the **SD card** (`/machines/next/enNextMf.rom`) | the Multiface ROM's **SRAM** |
| When the change takes effect | the next **power-on** | **immediately** — the next NMI press |
| How long it lasts | for ever, until changed again | until the next **power-off** |
| Needs a power cycle | yes, to take effect | no |
| Can run from `AUTOEXEC.BAS` | no | **yes** |

`tbblue.fw` loads `enNextMf.rom` from the card into that SRAM at every power-on. mfselect changes
what gets loaded; mfinstall changes what is *there*, after the loading has happened. So:

- **`--load` is live at once.** Press the NMI button and the stub is there — no reset, no power
  cycle.
- **`--unload` is a within-session operation.** It copies `/mfselect/original.rom` back over the
  same SRAM. It does **not** repair anything on the card, because the card was never written; a
  power cycle would have done the same thing.
- **Every power-on starts from whatever is on the card.** If you want the stub back, run
  `.mfinstall` again — which is what `--auto` in `AUTOEXEC.BAS` is for.

**The SD card is never written.** That is the safety property worth having: the failure this
project already recorded as a data-loss bug — capturing the debug stub as your "original" and
leaving no copy of the stock Multiface ROM anywhere — cannot happen through this path, because
this path does not write files at all.

## Building

    make mfinstall           # build/mfinstall + BOTH ROMs + both .sum files
    make test-mfinstall      # the headless bench, 8 runs, 6 checks

`make mfinstall` depends on `make mfselect`, because it installs the same ROMs from the same
directory by a different means and a card with the command but not the ROMs is useless. Like
mfselect it is built with **z88dk** rather than sjasmplus — the stub must stay sjasmplus because
DeZog cannot do banking with z88dk, and that constraint does not reach a standalone NextZXOS
utility DeZog never sees.

One piece of it *is* sjasmplus: `tools/mfinstall/mfwin.asm`, the critical section, which has to be
assembled at a fixed address and cannot be a C function. See *How it works* below.

## Installing it on the card

> ### The command goes in `/dot/`. Its ROMs stay in `/mfselect/`.
>
> Dot commands are looked up in `/dot/`, so `mfinstall` itself cannot live beside the ROMs. Its
> ROM paths are hardcoded to `/mfselect/`, exactly as mfselect's are, so the two tools share one
> set of files and one `make mfselect` keeps them coherent.

`make mfinstall` fills `build/deploy/` and prints the destination of every file. Six of them:

| From | To |
|---|---|
| `build/deploy/mfinstall`    | `/dot/mfinstall` |
| `build/deploy/dezowifi.rom` | `/mfselect/dezowifi.rom` |
| `build/deploy/dezowifi.sum` | `/mfselect/dezowifi.sum` |
| `build/deploy/dezouart.rom` | `/mfselect/dezouart.rom` |
| `build/deploy/dezouart.sum` | `/mfselect/dezouart.sum` |
| `build/deploy/mfselect.nex` | `/mfselect/mfselect.nex` |

`/mfselect/mfinstall.yml` you write yourself (below), and `/mfselect/original.rom` plus
`/mfselect/original.sum` are captured by **mfselect** on its first run — `.mfinstall --unload`
needs them and cannot create them, because capturing the stock ROM means reading the card, deciding
whether what is there is really the stock ROM, and writing a file, all of which mfselect already
does with a guard this program deliberately does not duplicate.

**So run mfselect once before relying on `--unload`.** Without `original.rom` the unload reports
that it cannot open the ROM file, and a power cycle is your way back.

## Using it

    .mfinstall --load wifi     install the WiFi build into Multiface ROM space
    .mfinstall --load uart     install the UART build
    .mfinstall --unload        put /mfselect/original.rom back
    .mfinstall --auto          do whatever /mfselect/mfinstall.yml says
    .mfinstall --help

Then **press the NMI button**. That is the only step; there is no reset and no power cycle.

It prints what it is doing, and the last line it leaves on screen is the outcome. **The screen is
blanked in the middle of the operation** and that is not a fault — see *How it works*.

### The config file

`/mfselect/mfinstall.yml`, one key:

```yaml
install: wifi        # or: uart, or: none
```

`install: none` is a success, not an error: `--auto` says so and exits cleanly, which is what makes
it safe to leave in `AUTOEXEC.BAS` on a day you are not debugging.

### AUTOEXEC.BAS

```basic
10 .mfinstall --auto
```

That is the whole of it, and it is why this exists. Xalior's objection to a file-swap installer was
that it is a **ROM change**, where an `AUTOEXEC.BAS` change can be undone by holding the key that
skips `AUTOEXEC.BAS` — no card in a PC, no file to remember replacing.

`--auto` is safe to run at every boot. It reads the identity block out of the **live** Multiface
ROM first and does nothing if the requested variant is already there.

### One consequence of that idempotence, stated plainly

The "already installed?" test matches the ROM's **variant**, not its build number — that is issue
#4's rule and it exists because a per-build check goes stale the moment you rebuild. The
consequence:

> **Rebuild the stub, run `.mfinstall --load wifi` again in the same session, and the new build is
> NOT installed.** The old one is still "the WiFi ROM" as far as the check is concerned.

Power-cycle, or `.mfinstall --unload` first, and then load. It is not a problem at boot, where the
SRAM has just been reloaded from the card and nothing of ours is ever live. The message tells you
which build it found — `Already: dezogif_ng WiFi 00.10` — so the situation is at least visible.

## How it works, and why it is shaped like that

Two facts were **measured** in jnext under a booted NextZXOS, not taken from documentation, and
together they force the whole design:

1. **A naive dot command cannot do this at all.** It runs at `0x2000` with DivMMC RAM mapped there,
   and DivMMC's two pages are enabled together — so the DivMMC ROM is necessarily at `0x0000` too,
   where it is read-only. Config mode deliberately leaves DivMMC eligible in the arbiter that runs
   after it, so DivMMC wins and **every config-mode write to the Multiface ROM is silently
   discarded**. The first probe read back the DivMMC ROM's own bytes.
2. **Turning DivMMC off fixes it; relocating the code is what makes that survivable.** A control
   run — the same routine with DivMMC left on, one assembler constant different — reproduced the
   blocked result from the same code location. So relocation alone fixes nothing.

Hence `tools/mfinstall/mfwin.asm`: a small routine assembled at `0x5000`, copied there before every
call, which turns DivMMC off, enters config mode, does its work, and puts everything back exactly
as it found it. Everything at `0x2000` — the C code and its variables — does not exist while that
runs.

**The screen is the buffer.** Code, data and stack must all be above `0x4000`, so the display file's
pixel area (`0x4000`-`0x57FF`) holds the 4 KB image buffer, the routine, its variables and its
stack. That is why the ROM is copied in **two passes of 4 KB** — 8192 bytes plus the routine do not
fit — and why the screen is blanked afterwards rather than restored: there is nowhere to keep 6144
bytes while DivMMC is off. The attributes are never touched, so the screen keeps its colours.

**The write is verified inside the window.** A discarded write is this mechanism's entire failure
mode, and outside config mode there is nothing to read back — `0x0000` is the DivMMC ROM again. So
the routine reads its own work back before leaving, and `Write blocked: ROM unchanged` is a real
message that a real fault produces. The source ROM's CRC-16 is checked against its `.sum` first,
as mfselect does, so a corrupt file on the card is never copied anywhere.

**No soft reset is issued.** taylorza reported needing `NEXTREG 2,1` for a config-mode replacement
to take effect; bench check I2 presses the NMI button straight after an install, with no reset, and
requires the stub's own screen — so in the emulator the answer to that open question is that a
reset is **not** required. On real hardware nobody has checked.

The full VHDL reasoning, with line citations, is in
[CONFIG-MODE-ROM-REPLACEMENT.md](CONFIG-MODE-ROM-REPLACEMENT.md).

## What the bench checks

`make test-mfinstall` — 8 headless jnext runs, 6 checks, no VS Code and no hardware.

| | |
|---|---|
| **I1** | `--load wifi` reports success, and a second invocation reads the identity block back **through config mode** and finds `WIFI` |
| **I2** | after that, an M1 button NMI brings up **the stub's own screen** and not the stock Multiface monitor — with no soft reset |
| **I3** | `--unload` restores the original: the same NMI brings up the stock monitor. Its second clause is the control that the button fires at all |
| **I4** | a second `--load wifi` is a no-op and says so |
| **I5** | `--auto` obeys `mfinstall.yml`: `wifi` installs the stub, `none` installs nothing |
| **I6** | **the control for the whole bench** — the card's `enNextMf.rom` is byte-identical afterwards, so the mechanism really was config mode and not a file write |

**I2 is the strongest check here** and it is the one that answers issue #21's open question 3. I6
is the one that makes the others mean what they say: without it, every check above is equally
satisfied by a tool that just wrote the file.

**It says nothing about hardware.** jnext's config-mode model cites the same VHDL lines this design
was read from, so agreement between them is not independent evidence — and this project has twice
been bitten by an emulator whose values sat on the safe side of ours (a connection id of 0, a
15-character IP address). What is *not* covered is listed at the end of
[CONFIG-MODE-ROM-REPLACEMENT.md](CONFIG-MODE-ROM-REPLACEMENT.md).

## What it does not do

- **It does not capture the stock ROM.** mfselect does that, with a guard; see above.
- **It does not survive a power cycle**, by construction.
- **It does not tell the stock Multiface ROM from any other third-party one.** `--unload` reports
  "nothing to do" when what is live carries no dezogif_ng magic — which is a true statement about
  what *we* installed, and not a claim about what is there.
- **It cannot roll back a failed second pass.** If the write fails halfway the previous contents are
  already gone and there is nothing to restore them from — SRAM has no rename. It says so, and a
  power cycle always fixes it.
