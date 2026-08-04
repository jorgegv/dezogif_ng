# dezogif_ng — a ZX Spectrum Next debug stub over WiFi

A Z80 debug stub that runs on **real ZX Spectrum Next hardware** and is debugged from a PC with
[DeZog](https://github.com/maziac/DeZog) in VS Code, speaking DZRP.

It is a fork of [maziac/dezogif](https://github.com/maziac/dezogif), whose transport is a serial
cable on the joystick port. The goal of this fork is to **add a second transport over the Next's
on-board ESP-01 WiFi module** — the same UART peripheral behind a pin mux — and to select between
the two **at assembly time**, so the ROM can be built in either UART mode or WiFi mode. The serial
transport is not being removed. WiFi mode would drop the cable, leave the joysticks with the game
permanently, and open a route for **PC-initiated break**, which the serial version cannot do.
None of it is written yet: what is here today is upstream's serial stub, plus this project's
build, test bench and documentation.

Maintained by [jorgegv](https://github.com/jorgegv). Original author: maziac.

**Status: Work in Progress**


# Design

There are basically 2 states:
- the debugged program is running
- the debugged program is stopped

When the debugged program is running no communication takes place and the joy ports are restored for joystick usage.
When the debugged program is stopped the dezogif takes over and configures the joy port for UART communication.

This implies that it is not possible to stop the debugged program from DeZog.
To stop it you need to press the yellow NMI button.

When the NMI button was pressed dezogif sends a DZRP pause notification to DeZog to notify about the state change. Then dezogif will wait for further requests from DeZog, e.g. to read register values etc.

The program is started when DeZog sends a DZRP continue request.

See [Design.md](doc/legacy/Design.md) for more info.

Lifting the "cannot stop from DeZog" limitation is the point of this fork; the mechanism is a
Copper-driven periodic NMI, and it is milestone M2 of the plan.


# Build

The assembler is [sjasmplus](https://github.com/z00m128/sjasmplus). Running `make` with no target
lists everything available:

~~~
make all        # the ROM, the program and the unit tests
make mf-rom     # build/enNextMf.rom, the deployable artefact
make mfselect   # the on-Next ROM switcher and both ROMs it installs (see Deployment)
~~~

Build output goes to `build/`.

`mfselect` is the one component built with [z88dk](https://github.com/z88dk/z88dk) rather than
sjasmplus. It is not part of `make all`.


# Testing

~~~
make test
~~~

runs a local headless test bench in the [jnext](https://github.com/jorgegv/jnext) emulator — no
VS Code, no hardware. It installs the freshly built ROM into a copy of an SD card image, boots a
Next, fires a Multiface NMI from guest code and judges the resulting screenshots. `make
check-reproducible` verifies that a pinned `BUILD_TIME` yields a byte-identical ROM.

~~~
make test-mfselect
~~~

runs mfselect's own bench: six headless jnext runs, nine checks, asserting mostly on the files
pulled back off the SD image rather than on pixels — that the stock ROM is captured
byte-identically, that the on-Next and host checksums agree, that each of our two ROMs installs,
that mfselect refuses to mistake *either* of them for the original, and that a backup left short by
an interrupted capture is detected and taken again rather than trusted. It is not part of
`make test`.

The Z80 unit tests under `src/unit_tests/` are DeZog-driven and need VS Code; they are a manual
layer.


# Deployment

The stub **is** the Multiface ROM: `build/enNextMf.rom` replaces
`machines/next/enNextMf.rom` on the Next's SD card. **The card already has one, and it is the
stock Multiface ROM — you must keep a copy of it.** Without one you cannot get the normal
Multiface back, and you will want it back every time the stub misbehaves.

There are two ways to do that swap.

## Recommended: mfselect, on the Next itself

`mfselect` is a small NextZXOS utility that switches the installed Multiface ROM between the stock
one and **either** of this project's two builds, with the card still in the machine. It captures
the stock ROM the first time it runs, so the backup is made for you rather than being something you
must remember.

Install it once, by copying five files — everything `make mfselect` produces — into a new
`/mfselect/` directory on the card:

| From | To |
|---|---|
| `build/mfselect.nex`      | `/mfselect/mfselect.nex` |
| `build/enNextMf-wifi.rom` | `/mfselect/dezowifi.rom` |
| `build/dezowifi.sum`      | `/mfselect/dezowifi.sum` |
| `build/enNextMf.rom`      | `/mfselect/dezouart.rom` |
| `build/dezouart.sum`      | `/mfselect/dezouart.sum` |

Copy each `.rom` with its own `.sum`, **from the same build** — `BUILD_TIME` is stamped into the
ROM, so each build has a different checksum, and a mismatched pair is refused. One `make mfselect`
builds both variants with the same `BUILD_TIME`, so the five files above are always a coherent set.

Then, from the NextZXOS command line:

~~~
.nexload /mfselect/mfselect.nex
~~~

Up/Down to move, ENTER to choose:

~~~
 mfselect            dezogif_ng
 Installed: dezogif_ng WiFi 0003

 Select ROM to install:
  Official Multiface NMI ROM
  dezogif_ng WiFi (ESP-01)
  dezogif_ng UART (joy port)
  Exit without changes

 Up/Down to move   ENTER to run
~~~

**Both of our builds are offered**, because a debuggee that uses the ESP itself cannot be debugged
over WiFi and the serial ROM is the answer for it. `Installed:` names which one is on the card, and
its build number, read from a magic string inside the ROM rather than from a checksum — so it stays
correct after the stub is rebuilt.

Whichever is chosen is copied over the official path and **verified by reading it back**. Then
**power-cycle the machine** — switch it off and on. The Multiface ROM is read at power-on, so
nothing changes until then.

On its very first run mfselect offers to save the currently installed ROM as the original. It
refuses to do that if what is installed is already one of this project's ROMs — either of them —
because saving the debug stub as "the original" would lose the stock Multiface ROM with no copy
left on the card. If you have already installed the stub by hand, restore the stock ROM before
running mfselect, or its backup will simply never be made.

Full detail, including the checksum scheme: [doc/MFSELECT.md](doc/MFSELECT.md).

## By hand

Put the card in a PC, back up `machines/next/enNextMf.rom` somewhere safe, and copy
`build/enNextMf.rom` over it.

## Using the stub

Once installed, the stub starts after NextZXOS has booted, by pressing the yellow NMI button. To
re-initialise later, hold "Symbol Shift" (or CTRL) while hitting the NMI button.

Note: the stub is known to work with ZX Next core 03.01.10 and 03.02.00. It will not work on older
cores — stackless NMI, which it depends on, does not exist there.


# License

This project is licensed under the [GNU General Public License v3](LICENSE).

It is a derivative work of [maziac/dezogif](https://github.com/maziac/dezogif), which is under
the MIT licence. That notice is retained in [NOTICE](NOTICE) and still governs maziac's original
code; the GPLv3 covers the combined work.


# Acknowledgements

To **maziac**, for dezogif and for DeZog itself. Everything above the byte stream here — the
memory choreography, the AltROM trick, the breakpoint design, the DZRP command layer — is
maziac's work, and this fork would have been months of rediscovery without it.

And, in maziac's own words from the original readme:

> Many thanks to Chris Kirby. I have used his NDS code
> https://github.com/Ckirby101/NDS-NextDevSystem as starting point and used e.g. his routine to
> set the baudrate.
