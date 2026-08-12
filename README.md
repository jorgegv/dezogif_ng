# dezogif_ng — a ZX Spectrum Next debug stub over WiFi

A Z80 debug stub that runs on **real ZX Spectrum Next hardware** and is debugged from a PC with
[DeZog](https://github.com/maziac/DeZog) in VS Code, speaking DZRP.

It is a fork of [maziac/dezogif](https://github.com/maziac/dezogif), whose transport is a serial
cable on the joystick port. This fork **adds a second transport over the Next's on-board ESP-01
WiFi module** — the same UART peripheral behind a pin mux — selected **at assembly time**, so the
ROM builds in either UART mode or WiFi mode. The serial transport is not removed.

Maintained by [jorgegv](https://github.com/jorgegv). Original author: maziac.


# What this fork adds

| | dezogif | dezogif_ng |
|---|---|---|
| Transport | serial on the joy port | **either**: the same serial link, or **ESP-01 WiFi over TCP** |
| Cable | D-SUB 9 + USB serial adapter | **none** in WiFi mode |
| Joysticks | taken over while stopped | **never touched** in WiFi mode |
| Pause from the PC | impossible — press the NMI button | **yes** in WiFi mode |
| Choosing a ROM | swap a file on the SD card in a PC | **from the machine**, both builds on the card |
| Test bench | — | headless, emulator-driven, `make test` |

Everything above the byte stream is inherited unchanged: the memory choreography, the AltROM
trick, `RST 0` breakpoints, and the DZRP command layer.

**WiFi mode.** `make mf-rom-wifi` gives a ROM that brings the ESP-01 up as a TCP server on port
11000 and speaks DZRP through it. No cable, and the joysticks stay with the program permanently.
The link negotiates up to 460800 baud, giving a round trip of about 6.6 ms and about 20 KB/s.

**Pause from the PC.** In WiFi mode, Pause in DeZog stops a freely running program — no button
press and no breakpoint. It needs two Copper instructions in **your** program, 44 bytes, because
the Copper's instruction list is write-only and a debugger that installed its own could never give
yours back. See [doc/ASYNCHRONOUS-BREAK-USER-HOWTO.md](doc/ASYNCHRONOUS-BREAK-USER-HOWTO.md) for
the snippet, what it costs, and the states in which the break will not fire.

UART mode has no PC-initiated break and cannot have one: a serial build hands the joy ports back
when it resumes your program, which re-points the UART's receive line at the ESP-01 pin, so the
cable's bytes have nowhere to land while the program runs. There the NMI button is the only way to
stop it.

**Two ROMs, switched from the machine.** Both builds go on the SD card together, and either can be
installed from a menu (`mfselect`) or from the NextZXOS command line and `AUTOEXEC.BAS`
(`.mfinstall`). That matters because there is one ESP: a program that uses WiFi itself cannot be
debugged over WiFi, and the serial ROM is the answer for it — a power cycle away rather than a PC
session away.

Read [doc/ZXNEXT-REMOTE-DEBUG-STUB.md](doc/ZXNEXT-REMOTE-DEBUG-STUB.md) for the design, the
VHDL-verified hardware facts with citations, and which claims rest on hardware rather than on the
emulator.


# Requirements

- **ZX Next core 03.01.10 or later.** The stub depends on stackless NMI, which older cores lack.
- **A Multiface-enabled machine config**, since the stub *is* the Multiface ROM.
- **For WiFi mode, a Next that is already on the network.** Set that up once with
  `/apps/wifi/setup/wifi2.bas`; the ESP stores its own credentials. The stub holds no SSID and no
  passphrase and never joins a network — it only checks that it has an address, and says so on
  screen when it does not. See [doc/WIFI-SETUP.md](doc/WIFI-SETUP.md).
- **sjasmplus** to build the ROM, and [z88dk](https://github.com/z88dk/z88dk) for `mfselect` and
  `.mfinstall`.


# Design

There are two states: the debugged program is running, or it is stopped.

While it runs, the debugger is not executing. When it stops — on a breakpoint, on the NMI button,
or on a Pause from the PC — the stub takes over, reports the state change to DeZog with a DZRP
pause notification, and waits for requests: read registers, read memory, set breakpoints. The
program starts again when DeZog sends a continue request.

In UART mode the joy ports are configured for the serial link while stopped and handed back to the
program when it resumes, exactly as upstream does. In WiFi mode the joy ports are never touched,
and UART0 stays on the ESP-01 pin permanently — which is what makes a byte from the PC able to
arrive at any time, and so what makes Pause possible.

See [doc/legacy/Design.md](doc/legacy/Design.md) for the memory choreography, the AltROM trick and
the breakpoint design, all inherited.


# Build

Running `make` with no target lists everything available. Output goes to `build/`.

~~~
make mf-rom       # build/enNextMf.rom       — UART (default)
make mf-rom-wifi  # build/enNextMf-wifi.rom  — WiFi
make mfselect     # the on-Next ROM switcher and both ROMs it installs
make mfinstall    # the .mfinstall dot command
make all          # all of the above, plus checksums and build/deploy/
~~~

The two variants have different output names on purpose, so a WiFi build cannot be left where a
test reads a serial one. `make check-reproducible` verifies that a pinned `BUILD_TIME` yields a
byte-identical ROM.


# Testing

The bench is local, headless and driven by the [jnext](https://github.com/jorgegv/jnext) emulator —
no VS Code and no hardware.

~~~
make test
~~~

is the gate: it installs the freshly built ROM into a copy of an SD card image, boots a Next,
fires Multiface NMIs and judges the resulting screenshots.

Behind it are about a dozen more targets, each with its own subject — the DZRP conformance suite
against our own stub over an emulated ESP-01 (`make test-dzrp-stub`), the ROM switcher
(`make test-mfselect`), the dot command (`make test-mfinstall`), the ESP transport's timeouts,
recovery and baud negotiation, and the Z80 unit tests (`make test-unit`). Bare `make` lists them;
[doc/DZRP-TESTING.md](doc/DZRP-TESTING.md) and the other documents under `doc/` say what each one
does and does not establish. `make test-hardware NEXT_IP=<ip>` runs the same conformance suite
against a real Next.

Two limits worth knowing. The benches bind host TCP ports or need a client running concurrently
with the emulator, so most of them are deliberately not part of `make test`. And `make test-unit`
runs 28 of the 64 unit test cases: the other 36 need ports invented by a JavaScript peripheral
that DeZog's zsim loads as `customCode`, and the Z80 cannot trap its own I/O, so those stay a
manual VS Code layer.


# Deployment

The stub **is** the Multiface ROM: one of `build/enNextMf.rom` (UART) or
`build/enNextMf-wifi.rom` (WiFi) replaces `machines/next/enNextMf.rom` on the Next's SD card.
**The card already has one, and it is the stock Multiface ROM — you must keep a copy of it.**
Without one you cannot get the normal Multiface back, and you will want it back every time the
stub misbehaves.

## Recommended: mfselect, on the Next itself

`mfselect` is a small NextZXOS utility that switches the installed Multiface ROM between the stock
one and either of this project's two builds, with the card still in the machine. It captures the
stock ROM the first time it runs, so the backup is made for you.

`make mfselect` (or `make all`) leaves everything it needs in **`build/deploy/`**, under the exact
names *and in the directories* the card expects:

~~~
build/deploy/  →  the root of the card
    mfselect/mfselect.nex
    mfselect/dezowifi.rom
    mfselect/dezowifi.sum
    mfselect/dezouart.rom
    mfselect/dezouart.sum
~~~

i.e. `cp -r build/deploy/* /path/to/card/`. **Nothing needs renaming and nothing needs placing by
hand** — the ROMs are built under the name the Next's firmware loads at boot, and mfselect looks
for them beside itself under different names, so the same bytes wearing two names in two
directories is the build's problem rather than yours. `make mfinstall` adds `dot/mfinstall` and a
default `mfselect/mfinstall.yml` to the same tree; see [doc/MFINSTALL.md](doc/MFINSTALL.md).

One build produces the whole set with the same `BUILD_TIME`, which is what makes it coherent: the
stamp goes into each ROM, so a `.rom` paired with a `.sum` from another build is refused.

Then, from the NextZXOS command line:

~~~
.nexload /mfselect/mfselect.nex
~~~

Up/Down to move, ENTER to choose:

![mfselect's menu on a ZX Spectrum Next](doc/images/mfselect-menu.png)

`Installed:` names which ROM is on the card and its build number, read from a magic string inside
the ROM rather than from a checksum, so it stays correct after the stub is rebuilt. Whichever is
chosen is copied over the official path and **verified by reading it back**. Then **power-cycle
the machine**: the Multiface ROM is read at power-on, so nothing changes until then.

On its first run mfselect offers to save the currently installed ROM as the original. It refuses if
what is installed is already one of this project's ROMs — either of them — because saving the debug
stub as "the original" would lose the stock Multiface ROM with no copy left on the card. If you
have already installed the stub by hand, restore the stock ROM first or the backup will never be
made.

Full detail, including the checksum scheme: [doc/MFSELECT.md](doc/MFSELECT.md).

## By hand

Put the card in a PC, back up `machines/next/enNextMf.rom` somewhere safe, and copy the variant you
want over it. Changing your mind later means doing it again; mfselect exists so that it does not.

## Starting the stub

Once installed, the stub starts after NextZXOS has booted, by pressing the yellow NMI button. To
re-initialise later, hold Symbol Shift (or CTRL) while pressing it. In WiFi mode the screen then
shows the address to connect to.


# Connecting DeZog

In WiFi mode the Next is a TCP **server** on port 11000, and DeZog connects to it. Point DeZog's
`zxnext` remote at that address instead of a serial device:

~~~json
"remoteType": "zxnext",
"zxnext": { "hostname": "192.168.1.42", "port": 11000 }
~~~

Use `localhost` for a stub running inside jnext rather than on a real machine — the emulated ESP-01
listens on a host port. A static DHCP reservation for the Next is worth setting up, so the address
never moves and `launch.json` is written once.

**The socket form of the `zxnext` remote is not in a released DeZog yet**
([maziac/DeZog#186](https://github.com/maziac/DeZog/pull/186)). Until it is, released DeZog can
drive the stub through its `cspect` remote, which is a generic DZRP-over-socket client with a
configurable hostname:

~~~json
"remoteType": "cspect",
"cspect": { "hostname": "192.168.1.42", "port": 11000 }
~~~

Everything works that way **except breakpoints set in the editor**, which the `cspect` remote
places with a DZRP command the stub does not implement, and which the stub therefore refuses. It
says so on its own screen, and the session carries on. Stepping is unaffected. If you need editor
breakpoints today, build the `zxnext` remote from that pull request.

Also note that nothing else may use the ESP during a session — NextSync and friends will
reconfigure the module out from under the stub — and that a program using another ROM will not
work, because the stub patches the 48K BASIC ROM into the Alt ROM to make breakpoints and stepping
work in ROM code. Both are inherited constraints.


# License

This project is licensed under the [GNU General Public License v3](LICENSE).

It is a derivative work of [maziac/dezogif](https://github.com/maziac/dezogif), which is under the
MIT licence. That notice is retained in [NOTICE](NOTICE) and still governs maziac's original code;
the GPLv3 covers the combined work.

**Example code meant to be copied into your own program is MIT rather than GPLv3**, on the terms in
[NOTICE](NOTICE) — currently the 44-byte Copper snippet in
[doc/ASYNCHRONOUS-BREAK-USER-HOWTO.md](doc/ASYNCHRONOUS-BREAK-USER-HOWTO.md), which would be of no
use to anybody under a licence that infected the program it goes into.


# Acknowledgements

To **maziac**, for dezogif and for DeZog itself. Everything above the byte stream here — the
memory choreography, the AltROM trick, the breakpoint design, the DZRP command layer — is
maziac's work, and this fork would have been months of rediscovery without it.

And, in maziac's own words from the original readme:

> Many thanks to Chris Kirby. I have used his NDS code
> https://github.com/Ckirby101/NDS-NextDevSystem as starting point and used e.g. his routine to
> set the baudrate.
