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

**No install ever writes the SD card.** That is the safety property worth having: the failure this
project already recorded as a data-loss bug — capturing the debug stub as your "original" and
leaving no copy of the stock Multiface ROM anywhere — cannot happen through this path, because no
ROM ever travels towards the card.

**`--configure` is the single exception, and it is not an install**: it writes one file,
`/mfselect/mfinstall.yml`, and touches no ROM at all. This paragraph used to say "the SD card is
never written" flatly, which `--configure` makes false as stated; what it was ever protecting is
the ROM images, and that is unchanged.

## Building

    make mfinstall           # build/mfinstall + BOTH ROMs + both .sum files
    make test-mfinstall      # the headless bench, 12 runs, 9 checks

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

`make mfinstall` fills `build/deploy/` **in the card's own layout**, so there is no table to
transcribe and nothing to place by hand:

~~~
build/deploy/  →  the root of the card
    dot/mfinstall
    mfselect/mfselect.nex
    mfselect/dezowifi.rom
    mfselect/dezowifi.sum
    mfselect/dezouart.rom
    mfselect/dezouart.sum
    mfselect/mfinstall.yml
~~~

i.e. `cp -r build/deploy/* /path/to/card/`. The build prints the same listing when it finishes.

`mfinstall.yml` is a **default** — it says `install: wifi`, and `.mfinstall --configure` changes it
on the machine, with no card reader (below). `/mfselect/original.rom` and `/mfselect/original.sum` are the two files not shipped here:
they are captured by **mfselect** on its first run. `.mfinstall --unload` needs them and cannot
create them, because capturing the stock ROM means reading the card, deciding whether what is there
is really the stock ROM, and writing a file, all of which mfselect already does with a guard this
program deliberately does not duplicate.

**So run mfselect once before relying on `--unload`.** Without `original.rom` the unload reports
that it cannot open the ROM file, and a power cycle is your way back.

## Using it

    .mfinstall --load wifi     install the WiFi build into Multiface ROM space
    .mfinstall --load uart     install the UART build
    .mfinstall --unload        put /mfselect/original.rom back
    .mfinstall --auto          do whatever /mfselect/mfinstall.yml says
    .mfinstall --configure wifi|uart|none    set that file; install nothing
    .mfinstall --help

Then **press the NMI button**. That is the only step; there is no reset and no power cycle.

It prints what it is doing, and the last line it leaves on screen is the outcome. **The screen is
blanked in the middle of the operation** and that is not a fault — see *How it works*.

### The config file, and `--configure`

`/mfselect/mfinstall.yml` is one line and nothing else:

```yaml
install: wifi
```

`wifi`, `uart` or `none`. **It ships saying `wifi`**, from `tools/mfinstall/mfinstall.yml`, so
`--auto` works out of the box.

**You do not have to edit it by hand, and on a stock NextZXOS you cannot** — there is no editor on
the machine that will open it (user, 2026-08-07). That is what `--configure` is for:

    .mfinstall --configure uart

It writes the file and **does nothing else** — no ROM is loaded, unloaded or touched. `--load` is
the verb that installs now; `--auto` is the one that obeys this file; `--configure` decides what
`--auto` will do at the *next* boot. Keeping the three orthogonal is what makes it safe to run
mid-session.

**No comments, by decision.** The documentation is this file, and a preamble is a thing that grows:
`read_config()` reads 511 bytes **once** and scans only those, so enough explanatory text would push
`install:` out of the window and make the file unreadable to the program it configures. The build
refuses a shipped file over 511 bytes for that reason — a proxy for the real bound rather than the
bound itself — and `--configure` rewrites the file in the same lean form, so the only way a preamble
gets in now is if you put it there.

Two more properties, if you do edit it by hand:

- **CRLF line endings and plain ASCII**, which is what NextZXOS's own config files use
  (`/nextzxos/browser.cfg`, `/nextzxos/enBrowsext.cfg`) and what its editor expects. The parser
  itself takes either, and `--configure` writes CRLF;
- **the name is nine characters, which needs a long-filename entry** on the card. That is ordinary
  here — NextZXOS reads its own `enBrowsext.cfg` and looks dot commands up by names like
  `DISPLAYEDGE` — and `make test-mfinstall`'s I5 copies this exact file into the image with `mcopy`,
  which writes the same kind of entry a PC would. Nothing has opened it on real hardware.

**What `--configure` writes is byte-identical to what the build ships**, and that is checked rather
than intended: they are two separate sources — a checked-in file the Makefile copies, and C that
composes the same line — and bench check **I9** compares them. **I8** is the round trip:
`--configure uart`, then `--auto`, and the UART stub has to come up.

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

**Confirmed on a real Next, 2026-08-07**: the stub is installed at boot and the next M1 press brings
up the debugger, with no reset and nothing else typed.

That is the whole of the program, and it is why this exists — but **two things about the file itself
are easy to get wrong and neither is optional**, both from the NextZXOS Guide on the card
(`/docs/guides/NextZXOS.gde`, node `AUTOEXEC`):

- **it must be `c:/nextzxos/autoexec.bas`.** Not the root of the card. Nothing looks there;
- **it must be SAVEd with an auto-run line**, or it is a program that loads and never starts:

      SAVE "c:/nextzxos/autoexec.bas" LINE 10

Either mistake gives the same symptom — it runs perfectly when you `LOAD` and `RUN` it yourself, and
never runs at boot. The auto-run line lives in bytes 18-19 of the file's 128-byte `PLUS3DOS` header,
so it is checkable from a PC: `0A 00` is line 10, anything ≥ `00 80` means no auto-run. The card's
own `/nextzxos/autoexec.1st` reads `LINE 10` there, which is where that was confirmed rather than
assumed. `ERASE` as a last line is safe and is what the guide recommends: with no arguments it
erases the program from *memory*, not the file.

Xalior's objection to a file-swap installer was that it is a **ROM change**, where an
`AUTOEXEC.BAS` change is undone without a card reader. Note one part of that argument this project
has not been able to source: it was put as "hold the key that skips `AUTOEXEC.BAS`", and **no such
key is documented anywhere in the NextZXOS guide** — BREAK stopping a running NextBASIC program is
the obvious candidate and nothing here has verified it applies at boot. What is certainly true is
the weaker form: the file is one line, editable on the Next, and `install: none` turns the whole
thing off without touching it.

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
stuck — a description of what they did, not a claim that a reset is required. Bench check I2
presses the NMI button straight after an install, with no reset, and
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
