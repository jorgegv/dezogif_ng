# mfselect — switching the Multiface ROM from the Next itself

`mfselect` is a NextZXOS utility that swaps `/machines/next/enNextMf.rom` between the stock
Multiface ROM and dezogif_ng's, with the SD card still in the machine. It removes the only
physical step in the debugging workflow (plan Appendix B.1 step A3: card out, into a PC, back up,
copy over) — and, more usefully, removes it in the *reverse* direction, for when the stub
misbehaves and you want the stock Multiface back immediately.

Filed as [issue #1](https://github.com/jorgegv/dezogif_ng/issues/1).

## Building

    make mfselect            # build/mfselect.nex + build/dezogif.sum
    make test-mfselect       # the headless bench, 5 checks

It is deliberately **not** part of `make all` or `make test`: `make all` builds the ROM
deliverable, and mfselect is separate tooling.

`mfselect` is the one thing in this repository built with **z88dk**, not sjasmplus. MEMORY.md pins
sjasmplus for the stub, and the reason is specific — DeZog cannot do banking with z88dk — but
mfselect is a standalone utility DeZog never sees, so that constraint does not reach it. The stub
itself must stay sjasmplus.

## Installing it on the card

Copy three files into a new `/mfselect/` directory on the SD card:

| From | To |
|---|---|
| `build/mfselect.nex` | `/mfselect/mfselect.nex` |
| `build/enNextMf.rom` | `/mfselect/dezogif.rom` |
| `build/dezogif.sum`  | `/mfselect/dezogif.sum` |

**Copy the `.rom` and the `.sum` from the same build.** `BUILD_TIME` is stamped into the ROM, so
every build produces a different image and a different checksum; a mismatched pair makes mfselect
refuse to install, which is the correct behaviour but a confusing way to discover the mistake.

**A mismatched pair no longer endangers your backup, though**, and it used to. mfselect identifies
our ROM by a magic string inside it (`DeZoGiFnG_UART_0001`), not by its checksum, so identity
survives a rebuild — see *Identity vs integrity* below.

The fourth and fifth files — `original.rom` and `original.sum` — are written by mfselect itself on
its first run.

## Running it

It must run **under NextZXOS**: every file access is the esxdos API. From the NextZXOS command
line:

    .nexload /mfselect/mfselect.nex

Up/Down move the selection, ENTER runs it, exactly as the NextZXOS browser behaves.

Selecting either ROM copies it over the official path, verifies the copy by reading it back, and
then tells you to **power-cycle** the machine. The Multiface ROM is read at power-on, so nothing
changes until then.

## The first run, and why it asks

On its first run mfselect has no `original.rom`, so it offers to capture whatever is currently at
the official path. That capture is guarded, and the guard is the reason this program is more than
two file copies:

**The naive rule destroys the stock ROM for exactly the people most likely to run this first.**
Anyone who has already installed dezogif_ng by hand — which is what Appendix B.1 step A3 tells them
to do — has *our* ROM at the official path. Capturing that as "the original" would label the debug
stub as the stock Multiface ROM and leave no copy of the real one anywhere on the card.

So:

- If the installed ROM **carries our magic string**, mfselect **refuses** and says why.
- Otherwise it shows the checksum and **asks** before capturing, because "not ours" is not proof of
  "stock" — it could be upstream dezogif's ROM, or any other third-party Multiface ROM.

Bench check M4 exists specifically for this: it runs mfselect on a card where our ROM is already
installed with no backup present, answers Y anyway, and requires that no `original.rom` appears.

**M6 is the one that matters**, and M4 could never have caught what it catches. This guard used to
compare checksums, so it only recognised our ROM while `dezogif.sum` came from the *same build* —
and `BUILD_TIME` changes the checksum on every build, so the guard fell silent the moment anyone
upgraded the stub, and captured our ROM as their `original.rom`. M6 ships a deliberately stale
`.sum`, which is what an upgraded card looks like, and requires the guard to hold anyway. Verified
by reverting the guard to its old form: M4 still passed, M6 failed with the backup destroyed.

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

`dezogif.sum` is produced by the **build**, not computed on the card at install time. A checksum
computed from an already-corrupt file would simply bless the corruption.

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

## Open questions

1. **Is a hardware power cycle actually required, or does a soft reset suffice?** The advice to
   power-cycle is safe either way, so the on-screen text stands — but nothing here has established
   that a soft reset is insufficient. This is a tbblue firmware question (when `enNextMf.rom` is
   read into page 0x0A), not a VHDL one, so the project's usual "read the VHDL" rule gives no
   answer.
2. Nothing here has run on **real hardware**. Everything above is jnext.
