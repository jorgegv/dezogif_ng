# mfselect — switching the Multiface ROM from the Next itself

`mfselect` is a NextZXOS utility that swaps `/machines/next/enNextMf.rom` between the stock
Multiface ROM and **either** of dezogif_ng's two builds, with the SD card still in the machine. It
removes the only physical step in the debugging workflow (plan Appendix B.1 step A3: card out,
into a PC, back up, copy over) — and, more usefully, removes it in the *reverse* direction, for
when the stub misbehaves and you want the stock Multiface back immediately.

Filed as [issue #1](https://github.com/jorgegv/dezogif_ng/issues/1); the second of our ROMs was
added by [issue #5](https://github.com/jorgegv/dezogif_ng/issues/5).

## The three ROMs it offers

| Menu entry | File on the card | What it is |
|---|---|---|
| Official Multiface NMI ROM | `original.rom` | the stock ROM, captured on first run |
| dezogif_ng WiFi (ESP-01) | `dezowifi.rom` | our stub, DZRP over TCP through the ESP-01 |
| dezogif_ng UART (joy port) | `dezouart.rom` | our stub, upstream's joy-port serial link |

**Both of ours are offered on purpose, and the UART build is not a legacy leftover.** One ESP,
one user of it: a debuggee that owns the ESP itself cannot be debugged over WiFi, and the plan's
risk table says outright that this is *the reason the UART build is kept*. Keeping it buildable
but not installable would push a user with a joy-port cable back to swapping files on a card in a
PC, which is the whole thing this program exists to avoid.

## Building

    make mfselect            # build/mfselect.nex + BOTH ROMs + both .sum files
    make test-mfselect       # the headless bench, 6 runs, 10 checks

`make mfselect` builds both variants whatever `TRANSPORT` it is invoked with, by recursing into
itself once per variant — the two ROMs otherwise have deliberately separate output paths so that
`make TRANSPORT=wifi` cannot leave a WiFi ROM where a UART one is expected. Building a card's
worth of files must not be a two-command ritual with a chance of shipping one variant and the
other's checksum.

It is deliberately **not** part of `make all` or `make test`: `make all` builds the ROM
deliverable, and mfselect is separate tooling.

`mfselect` is the one thing in this repository built with **z88dk**, not sjasmplus. MEMORY.md pins
sjasmplus for the stub, and the reason is specific — DeZog cannot do banking with z88dk — but
mfselect is a standalone utility DeZog never sees, so that constraint does not reach it. The stub
itself must stay sjasmplus.

## Installing it on the card

> ### It must go in `/mfselect/`. Not anywhere else.
>
> The directory is **hardcoded** and mfselect cannot find its files anywhere else. Install it in
> `/tools/`, `/apps/`, or beside your own project, and it will start, fail to find
> `dezowifi.rom`, and be useless. There is no error you can act on, because from the program's
> point of view the files simply are not there.
>
> This is a real limitation, not an oversight, and it was investigated and closed as
> [#6](https://github.com/jorgegv/dezogif_ng/issues/6) — see *Why the path is hardcoded* below
> before trying to fix it.

`make mfselect` puts everything into **`build/deploy/`, already in the card's own layout**, so
there is nothing to rename and nothing to place by hand:

~~~
build/deploy/  →  the root of the card
    mfselect/mfselect.nex
    mfselect/dezowifi.rom
    mfselect/dezowifi.sum
    mfselect/dezouart.rom
    mfselect/dezouart.sum
~~~

i.e. `cp -r build/deploy/* /path/to/card/`. The build prints that listing when it finishes.
(`make mfinstall` adds `dot/mfinstall` and a default `mfselect/mfinstall.yml` to the same tree —
see [MFINSTALL.md](MFINSTALL.md).)

**The names on the card are not the names the build produces**, which is exactly why
`build/deploy/` exists: `enNextMf.rom` is what the Next's firmware loads at boot, while mfselect
looks for `dezouart.rom` beside itself. The same bytes wear a different name depending on which of
the two jobs they are doing, and transcribing that by hand is the step at which somebody pairs
`dezowifi.sum` with the UART ROM. The card's names are also **8.3-safe** because the card is FAT;
that constraint already rejected `enNextMf.orig.rom` once (MEMORY.md).

**Copy each `.rom` with its own `.sum`, from the same build.** `BUILD_TIME` is stamped into the
ROM, so every build produces a different image and a different checksum; a mismatched pair makes
mfselect refuse to install, which is the correct behaviour but a confusing way to discover the
mistake. `make mfselect` hands both sub-builds the same `BUILD_TIME`, so the pair it produces is
coherent.

**A mismatched pair no longer endangers your backup, though**, and it used to. mfselect identifies
our ROMs by a magic string inside them (`DeZoGiFnG_WIFI_0003`), not by their checksum, so identity
survives a rebuild — see *Identity vs integrity* below.

Copying only one of the two variants is allowed and does no harm: the menu entry for the missing
one reports that it cannot read the file and installs nothing. There is no reason to do it, since
one command builds both.

The sixth and seventh files — `original.rom` and `original.sum` — are written by mfselect itself
on its first run.

## Running it

It must run **under NextZXOS**: every file access is the esxdos API. From the NextZXOS command
line:

    .nexload /mfselect/mfselect.nex

Up/Down move the selection, ENTER runs it, exactly as the NextZXOS browser behaves.

    Installed: dezogif_ng WiFi 00.03

    Select ROM to install:
      Official Multiface NMI ROM
      dezogif_ng WiFi (ESP-01)
      dezogif_ng UART (joy port)
      Exit without changes

Selecting any of the three ROMs copies it over the official path, verifies the copy by reading it
back, and then tells you to **power-cycle** the machine. The Multiface ROM is read at power-on, so
nothing changes until then.

The `Installed:` line names what is there now, including which of our two transports it is, and
the build number beside it. That is what the ROM identity block is for — no checksum is computed
to answer it, so it still reads correctly after the stub has been rebuilt.

## The first run, and why it asks

On its first run mfselect has no `original.rom`, so it offers to capture whatever is currently at
the official path. That capture is guarded, and the guard is the reason this program is more than
two file copies:

**The naive rule destroys the stock ROM for exactly the people most likely to run this first.**
Anyone who has already installed dezogif_ng by hand — which is what the plan's Appendix B.1 used to
tell them to do, and what anyone who found this project before mfselect existed will have done —
has *our* ROM at the official path. Capturing that as "the original" would label the debug stub as
the stock Multiface ROM and leave no copy of the real one anywhere on the card. (A3 now says the
opposite: leave the stock ROM where it is and let mfselect capture it.)

So:

- If the installed ROM **carries our magic string**, mfselect **refuses** and says why. That is the
  prefix, so **either** of our variants is refused — the guard asks "is this ours", never "is this
  the one I expected".
- Otherwise it shows the checksum and **asks** before capturing, because "not ours" is not proof of
  "stock" — it could be upstream dezogif's ROM, or any other third-party Multiface ROM.

Bench checks M4 and M7 exist specifically for this: they run mfselect on a card where one of our
ROMs is already installed with no backup present, answer Y anyway, and require that no
`original.rom` appears. **M7 is the WiFi/UART pair of M4, not a duplicate of it.** A guard that
recognised only the variant it was written against would destroy the stock ROM for exactly the
users who chose the other transport, and nothing else on this bench would notice.

**M6 is the one that matters**, and M4 could never have caught what it catches. This guard used to
compare checksums, so it only recognised our ROM while the `.sum` beside it came from the *same
build* — and `BUILD_TIME` changes the checksum on every build, so the guard fell silent the moment
anyone upgraded the stub, and captured our ROM as their `original.rom`. M6 ships deliberately stale
`.sum` files, which is what an upgraded card looks like, and requires the guard to hold anyway.
Verified by reverting the guard to its old form: M4 still passed, M6 failed with the backup
destroyed.

M6 installs the **WiFi** ROM and M7 the **UART** one, which keeps them independent: an earlier
arrangement had both on UART, and a control that broke the guard for that variant alone turned M6
red as well as M7 — a check failing for a reason outside its own subject, which is the defect
ERRORS.md describes rather than a second finding.

### Identity vs integrity

Two different questions, and answering the first with the second was the bug above:

| Question | Answered by |
|---|---|
| Is this ROM ours, and which variant? | the **magic string** at ROM offset `0x1FE0` |
| Did these bytes land intact? | the **CRC** in the `.sum` files |

The magic is `DeZoGiFnG_` + variant (`UART`/`WIFI`) + `_` + a four-hex-digit build number from
`version.yaml`. **Match the prefix and the variant; never the build number** — it changes, and
matching it would reintroduce exactly the per-build fragility the block removes. mfselect shows it
beside the ROM name so you can say which build is on the card without computing anything.

**The block stores four bare digits; mfselect shows them as `NN.NN`** (issue #20), the same way
the debugger's own banner does — high byte, dot, low byte. The dot is a rendering applied where a
person reads the number, and it is deliberately *not* in the ROM: this field's format is a
contract, and one stored form with one display transform is what stops the two drifting.

The two fields answer two different questions, and mfselect uses each for one of them:

- the **prefix** answers *is this ours* — and that alone drives the first-run guard, so both
  variants are protected by one comparison;
- the **variant field** answers *which of ours*, and drives only the `Installed:` line.

An unrecognised variant reads as **ours but unnamed** (`dezogif_ng ROM`), never as one of the two.
Guessing would print a false statement about the card, which is the class of thing this block
exists to stop; and because the guard keys off the prefix, a future third transport is protected
by an mfselect that predates it.

### Checking the label, not just the difference

Bench check **M9** asserts the naming half, and getting it right took two attempts — the first
version was rejected in review and the reason is worth keeping.

That version compared the two runs *against each other*: install the WiFi ROM, install the UART
ROM, and require the status rows to differ in exactly the four columns of the transport name. It
passes on a correct build. **It also passes when the two labels are swapped** — each variant
reporting the other's name still differs in exactly those columns. The reviewer swapped the return
strings in `installed_name()`, rebuilt, and the bench stayed green at 9/9. Two runs disagreeing is
not either of them being right, and nothing else on this bench reads the screen: M3 and M8 assert
on the bytes of a file, which say nothing about what was displayed about them.

**M9 now judges each screenshot on its own, against ground truth already inside it.** The menu
draws `dezogif_ng WiFi (ESP-01)` and `dezogif_ng UART (joy port)` whatever is installed, in the
same ROM font and the same attribute as the status row — so every screenshot contains a correct
rendering of *both* labels. The status row's transport field must match the **right** menu entry
and differ from the other. A swap cannot satisfy that, and neither can a single label used for
both. No OCR and no committed reference bitmap: the picture checks itself.

Every column involved falls out of one fact — all these strings begin with the 11 characters
`dezogif_ng ` — so the transport field is 11 cells into each: status row 2, columns 22-25; menu
rows 6 and 7, columns 13-16. (The status row starts at column 0 rather than 1 since issue #20: the
dotted build number is one character wider, and `Installed: dezogif_ng UART 00.0E` is exactly the
32 columns there are.)

**M10** keeps the cross-run half, which is still worth something on its own: nothing *else* on that
row may differ between the two runs. M9 reads four cells; M10 covers the other twenty-eight, so a
name of a different length — which would shift the build number after it — cannot hide behind a
correct transport field.

**Existence of `original.rom` is not proof of a backup**, and assuming it was cost a REJECT in
review. Opening a file with `CREAT_TRUNC` creates the directory entry before the first byte is
written, so a capture interrupted by a power cut leaves a *short* `original.rom`. Taking that as
"already backed up" made every later run skip the capture silently — and the user would then
install the stub believing the stock ROM was safe when no copy of it existed. Two changes followed:

- `backup_valid()` checks size and the presence of a readable `.sum`, not just existence. It
  deliberately does not re-CRC 8 KB at every start: an interrupted capture always yields a short
  file, which the size test catches instantly, and the backup's bytes are CRC-checked both when
  written and by `install()` before they are ever copied over the live ROM.
- **Every ROM write is now atomic.** The bytes go to a temporary in the same directory as their
  destination, are verified there, and only then is the destination unlinked and the temporary
  renamed onto it. The live Multiface ROM is never truncated in the hope that the write succeeds.
  In the capture path the `.sum` is written *before* the rename, so a power cut between them leaves
  no `original.rom` and the next run simply captures again — the reverse order could leave a ROM
  with no checksum, which `backup_valid()` rejects and no run could repair.

Bench check M5 covers it: seed a zero-length `original.rom`, run, and require that it is recaptured
from the stock ROM byte-identically.

## Checksums

CRC-16/CCITT (poly 0x1021, init 0xFFFF, no reflection, no final xor), stored as four uppercase hex
digits in a `.sum` sidecar. Three jobs: identify which ROM is installed, detect a truncated or
corrupt copy, and guard the first-run capture.

There are two independent implementations — `tools/romsum.py` on the host and `crc16()` in
`tools/mfselect/mfselect.c` on the Next — and the `.sum` files are worthless if they disagree.
Bench check M2 compares them: it takes the `original.sum` that mfselect computed on the Next and
requires it to equal what `romsum.py` computes on the host for the same bytes.

`dezowifi.sum` and `dezouart.sum` are produced by the **build**, not computed on the card at
install time. A checksum computed from an already-corrupt file would simply bless the corruption.
Each ROM has its own, and `install()` reads the one that belongs to the ROM it is installing —
there is no shared "our checksum" any more, and there was never a reason for one.

## Things worth knowing before changing it

**There is no `printf`.** z88dk's console for the `zxn` target is a plain character sink: control
codes 12 (cls), 22 (AT) and 16/17 (INK/PAPER) all print as `?`, and there is no native console
redirect for this target — both were established by running a probe, not from documentation. The
screen primitives at the top of `mfselect.c` write the display file directly, taking the font from
the address in the `CHARS` system variable. Anything printed must fit 32 columns; longer lines wrap
mid-word and turn an error message into a puzzle.

**The CRC is slow.** A bitwise CRC over 8 KB takes a few seconds at 3.5 MHz, and the menu computes
one every time it is drawn. Every long operation prints what it is about to do first, because a
screen that sits still for four seconds with no explanation reads as a hang. The CPU speed is
deliberately left at whatever NextZXOS set: raising it would speed this up eightfold, but changing
the clock under NextZXOS's SD I/O is a risk not worth taking for a program that runs seldom.

**The bench cannot use `jnext prog.nex`.** That injects the NEX at frame 0 with NextZXOS never
booted, so the first `RST $08` hangs — this cost an hour to diagnose the first time. There is no
`--load-delay`. `test/run-mfselect.sh` therefore boots NextZXOS, types `.nexload` one keypress at a
time (`/` is `sym+v`), and asserts on file contents extracted from the SD image with mtools rather
than on pixels.

## Why the path is hardcoded

Because there is no way for the program to discover where it lives, and this was measured rather
than assumed — [#6](https://github.com/jorgegv/dezogif_ng/issues/6).

The obvious mechanism is `esx_f_getcwd()`, which z88dk provides for this target. It returns the
**launcher's** working directory, not the program's:

| Launch | `esx_f_getcwd()` |
|---|---|
| `.nexload /probedir/cwdprobe.nex`, typed at the Command Line (which starts at `C:/`) | `C:/` |
| Browser, having navigated into `/PROBEDIR` | `C:/PROBEDIR/` |

The first row is the one that settles it: the launcher was at the root, the program was in
`/probedir`, and the answer came back as the root. A second, independent readout — creating a file
with a *relative* name and seeing where it landed — agreed in both cases.

So a `getcwd`-based mfselect would resolve its files against `C:/` under the invocation this very
document recommends, find nothing, and be **broken for the documented launch method** while
appearing to work from the Browser. That is worse than a hardcoded path, because it fails
differently depending on how it was started.

There is also no way for a NEX to recover its own path: esxdos has no handle→path call
(`esx_f_fstat` returns drive, attributes, date and size — no name). Whether NextZXOS records the
loaded NEX's path anywhere is unknown rather than disproven.

**If you want to fix this properly**, the honest answer is a dot command rather than a NEX — dot
commands receive a command tail, so the directory could simply be an argument. That is a rewrite
against the 8K divMMC window, and it needs to be worth doing on its own merits.

Two details for anyone who revisits it: `esx_f_getcwd()` returns a drive-prefixed, trailing-slash,
**uppercase** path (`C:/PROBEDIR/`), so joining must not double the slash and comparisons must be
case-insensitive because of FAT short names. And whether `cd` at the Command Line works well
enough to make "run it from its own directory" a usable convention is **unverified** — three
headless attempts failed to submit the typed line, which is a bench-mechanics problem and not a
finding about NextZXOS.

## Open questions

1. **Is a hardware power cycle actually required, or does a soft reset suffice?** The advice to
   power-cycle is safe either way, so the on-screen text stands — but nothing here has established
   that a soft reset is insufficient. This is a tbblue firmware question (when `enNextMf.rom` is
   read into page 0x0A), not a VHDL one, so the project's usual "read the VHDL" rule gives no
   answer.
2. Nothing here has run on **real hardware**. Everything above is jnext.
