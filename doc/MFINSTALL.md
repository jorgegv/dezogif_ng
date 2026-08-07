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
    make test-mfinstall      # the headless bench, 10 runs, 7 checks

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

**A missing or unreadable `mfinstall.yml` IS an error**, and deliberately so — `--auto` was asked to
obey a file that is not there, and a `.mfinstall` that quietly did nothing would leave you wondering
at the next NMI press why the debugger is not the one that came up. From `AUTOEXEC.BAS` that shows as
a BASIC error you can read and fix; `install: none` is how you say "do nothing" on purpose.

### AUTOEXEC.BAS

```basic
10 .mfinstall --auto
```

That is the whole of it, and it is why this exists. Xalior's objection to a file-swap installer was
that it is a **ROM change**, where an `AUTOEXEC.BAS` change can be undone by holding the key that
skips `AUTOEXEC.BAS` — no card in a PC, no file to remember replacing.

### `--auto` is safe to run at every boot, and it is idempotent by construction

Not by a rule that could be wrong about your ROM: **it compares the bytes**. Each 4 KB pass is
checked against what is already live, inside the same config-mode window, and written only if it
differs. Run it twice and the second run says `Already loaded; nothing written.`

**That is why a locally rebuilt stub still installs.** An earlier version keyed the decision off the
identity block's *variant* field, which answers "is a WiFi ROM live" — a different question from "are
these the bytes". Rebuild the stub without a `make bump` and it is a new ROM wearing the same
`DeZoGiFnG_WIFI_0010`; the old test would have skipped it, and the person running this repeatedly is
exactly the person rebuilding the stub. Comparing bytes cannot make that mistake.

The identity block is still read, for the job [issue #4](https://github.com/jorgegv/dezogif_ng/issues/4)
says it is for: **telling you what is live**. Every run that gets that far prints it —
`Live ROM: dezogif_ng WiFi 00.10`, or `Live ROM: not ours` — and nothing is decided on it.

It is read **after** the work rather than before, so it names what is live *now* rather than what
used to be. It has to be: the install borrows the display file for its buffer and blanks it
afterwards, so a line printed beforehand is erased. A first version printed it first and the line
vanished — caught by the bench reading the screen back as text.

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

**No soft reset is issued.** taylorza's worked example ends with `NEXTREG 2,1` and the replacement
stuck — a description of what they did, not a claim that a reset is required; bench check I2 presses the NMI button straight after an install, with no reset, and
requires the stub's own screen — so in the emulator the answer to that open question is that a
reset is **not** required. On real hardware nobody has checked.

The full VHDL reasoning, with line citations, is in
[CONFIG-MODE-ROM-REPLACEMENT.md](CONFIG-MODE-ROM-REPLACEMENT.md).

## What the bench checks

`make test-mfinstall` — 10 headless jnext runs, 7 checks, no VS Code and no hardware.

| | |
|---|---|
| **I1** | `--load wifi` reports success, and a second invocation reads the identity block back **through config mode** and finds `WIFI` |
| **I2** | after that, an M1 button NMI brings up **the stub's own screen** and not the stock Multiface monitor — with no soft reset |
| **I3** | `--unload` restores the original: the same NMI brings up the stock monitor. Its second clause is the control that the button fires at all |
| **I4** | a second `--load wifi` finds all 8192 bytes already there and writes nothing |
| **I5** | `--auto` obeys `mfinstall.yml`: `wifi` installs the stub, `none` installs nothing |
| **I6** | **the control for the whole bench** — the card's `enNextMf.rom` is byte-identical afterwards, so the mechanism really was config mode and not a file write |
| **I7** | **the control that attributes the fix to one constant** — a probe built with `DIVMMC_OFF=0`, DivMMC left mapped and nothing else changed, reports the write blocked, and an NMI after it brings up the stock monitor |

**I2 is the strongest check here** and it is the one that answers issue #21's open question 3. **I6
and I7 are the two that make the others mean what they say**: without I6, every check is equally
satisfied by a tool that just wrote the file; without I7, the bench shows that the tool works and
never *why*, since `DIVMMC_OFF` is the one constant the whole mechanism turns on. `DIVMMC_OFF` is a
build seam of the same shape as `IP_MAX`, `RX_WAIT`, `TX_PASSES`, `WAIT_SECS`, `FAULT_LIMIT` and
`LINK_IDS`, and for their reason: a state a check must be shown red against has to be reachable by a
build, or the red is a story about a scratch tree nobody can re-run.

**It says nothing about hardware.** jnext's config-mode model cites the same VHDL lines this design
was read from, so agreement between them is not independent evidence — and this project has twice
been bitten by an emulator whose values sat on the safe side of ours (a connection id of 0, a
15-character IP address). What is *not* covered is listed at the end of
[CONFIG-MODE-ROM-REPLACEMENT.md](CONFIG-MODE-ROM-REPLACEMENT.md).

## What it does not do

- **It does not capture the stock ROM.** mfselect does that, with a guard; see above.
- **It does not survive a power cycle**, by construction.
- **`--unload` needs `/mfselect/original.rom` even when there is nothing to undo.** It takes the same
  path as a load — compare the bytes, write what differs — so it has no way to say "nothing of ours is
  live" without reading the file it would put back. If mfselect has never captured the original it
  reports that it cannot open the ROM file, rather than quietly succeeding. That is the price of
  having one code path instead of two, and a power cycle does the same job.
- **It cannot roll back a failed second pass.** If the write fails halfway the previous contents are
  already gone and there is nothing to restore them from — SRAM has no rename. It says so, and a
  power cycle always fixes it.
