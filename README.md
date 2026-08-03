# dezogif_esp — a ZX Spectrum Next debug stub over WiFi

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
make mf_rom     # build/enNextMf.rom, the deployable artefact
~~~

Build output goes to `build/`.


# Testing

~~~
make test
~~~

runs a local headless test bench in the [jnext](https://github.com/jorgegv/jnext) emulator — no
VS Code, no hardware. It installs the freshly built ROM into a copy of an SD card image, boots a
Next, fires a Multiface NMI from guest code and judges the resulting screenshots. `make
check-reproducible` verifies that a pinned `BUILD_TIME` yields a byte-identical ROM.

The Z80 unit tests under `src/unit_tests/` are DeZog-driven and need VS Code; they are a manual
layer.


# Deployment

The enNextMf.rom binary needs to be copied to the ZX Next SD card under machines/next/enNextMf.rom.

There exists already one, so you need to backup the original.

The program (dezogif/enNextMf.rom) is started after NextOS has been started by pressing the yellow NMI button.

To re-initialize later you need to hold down the "Symbol Shift" (or CTRL) key while hitting the NMI button.

Note: the SW (enNextMf.rom) is known to work with ZXNext core 03.01.10 and core 03.02.00. It will not work on older cores.


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
