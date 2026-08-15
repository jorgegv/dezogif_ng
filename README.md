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
| Joysticks | taken over while stopped | **never taken over** in WiFi mode; in UART mode joy port 2 is held while the program runs too |
| Pause from the PC | impossible — press the NMI button | **yes** over WiFi, and over the cable on joy port 2 |
| Choosing a ROM | swap a file on the SD card in a PC | **from the machine**, live at the next NMI press |
| Test bench | Z80 unit tests, DeZog-driven | those, **plus** a headless emulator-driven bench: `make test` |

Everything above the byte stream is inherited unchanged: the memory choreography, the AltROM
trick, `RST 0` breakpoints, and the DZRP command layer.

**WiFi mode.** `make mf-rom-wifi` gives a ROM that brings the ESP-01 up as a TCP server on port
11000 and speaks DZRP through it. No cable, and the joysticks stay with the program permanently.
The link negotiates up to 460800 baud, giving a round trip of about 6.6 ms and about 20 KB/s.

**Pause from the PC.** Pause in DeZog stops a freely running program — no button press and no
breakpoint, and **for most programs no source change either**: the debugger installs the Copper list
the break rides on when a debug session opens, before your program has even been pushed to the
machine. If your program uses the Copper it must carry the two instructions itself, because the
Copper's instruction list is write-only and nothing can merge into a list it cannot read. The **"C"**
key on the stub's screen turns the feature off. See
[doc/ASYNCHRONOUS-BREAK-USER-HOWTO.md](doc/ASYNCHRONOUS-BREAK-USER-HOWTO.md) for the snippet, what it
costs, and the seven states in which the break will not fire.

**It works over the cable too, on joy port 2** — which is the default, so the serial ROM ships with
it on. Upstream cleared the joy port's i/o mode when it resumed your program, which cut the cable's
receive line; this fork keeps it on for port 2, so a byte from the PC still has somewhere to land.
Port 1 keeps upstream's resume behaviour deliberately, so a debugged program can have a real
joystick on the left connector. The stub's screen says which you have, on the row under the port selection:
`PC break: ready` or `PC break: needs Joy 2`.

What that costs is joystick types rather than a connector: while the port is held, Kempston and MD
reads keep working on **both** connectors, but Sinclair, Cursor and user-defined types produce
nothing and the MD 6-button extended buttons read as zero. Upstream paid that only while your
program was stopped; on port 2 it is now paid while it runs as well. No port choice could avoid it —
the register that reroutes the pin switches the key injection off globally.

Two caveats there, and the first is the one that bites today. **DeZog's serial remote refuses to
send Pause client-side** — it throws *"use the yellow NMI button"*, a refusal written when a cable
genuinely could not carry a byte to a running program — so over a cable the button is still what
you press until that refusal is lifted. The socket remote does send it, so WiFi mode is unaffected.
And the serial break **has not run on hardware**: `make test-uart-break` stops a freely running
debuggee with bytes on an emulated cable, and no real Next has been near it
([#43](https://github.com/jorgegv/dezogif_ng/issues/43)).

**Two ROMs, switched from the machine.** Both builds go on the SD card together, and either can be
installed from the NextZXOS command line or `AUTOEXEC.BAS` (`.mfinstall`, live at the next NMI
press) or from a menu (`mfselect`). That matters because there is one ESP: a program that uses WiFi
itself cannot be debugged over WiFi, and the serial ROM is the answer for it — a command away
rather than a PC session away.

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

In UART mode the joy ports are configured for the serial link while stopped. On **joy port 2** that
configuration is left in place when the program resumes, so the cable's receive line stays live and
a Pause has somewhere to land; on joy port 1, and with no port selected, the ports are handed back
as upstream does. In WiFi mode the joy ports are never taken over, and UART0 stays on the ESP-01
pin permanently — which is why a byte from the PC can arrive there at any time.

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

Behind it are eighteen more `test-*` targets, each with its own subject — the DZRP conformance suite
against our own stub over an emulated ESP-01 (`make test-dzrp-stub`), asynchronous break over the
joy-port cable (`make test-uart-break`), the ROM switcher (`make test-mfselect`), the dot command
(`make test-mfinstall`), the ESP transport's timeouts, recovery and baud negotiation, and the Z80
unit tests (`make test-unit`). Bare `make` lists them;
[doc/DZRP-TESTING.md](doc/DZRP-TESTING.md) and the other documents under `doc/` say what each one
does and does not establish. `make test-hardware NEXT_IP=<ip>` runs the same conformance suite
against a real Next.

Two limits worth knowing. The benches bind host TCP ports or need a client running concurrently
with the emulator, so most of them are deliberately not part of `make test`. And `make test-unit`
runs 30 of the 70 unit test cases: the other 40 need ports invented by a JavaScript peripheral
that DeZog's zsim loads as `customCode`, and the Z80 cannot trap its own I/O, so those stay a
manual VS Code layer.


# Deployment

The stub **is** the Multiface ROM. There are two ways to put it there, and they differ in what they
touch: `.mfinstall` writes it into Multiface memory for the current session and **never writes a ROM
to the SD card** — only its `--configure` verb writes anything there, one config file and no ROM —
while `mfselect` replaces `machines/next/enNextMf.rom` on the card permanently. Both live on the
card together and one build produces the set.

**The card already carries the stock Multiface ROM, and you want a copy of it kept.** `mfselect`
captures it on its first run, and `.mfinstall --unload` needs that copy — so run `mfselect` once
even if you then use `.mfinstall` for everything.

## Getting the files onto the card

`make mfinstall` (or `make all`) leaves everything in **`build/deploy/`**, under the exact names
*and in the directories* the card expects:

~~~
build/deploy/  →  the root of the card
    dot/mfinstall
    mfselect/dezouart.rom
    mfselect/dezouart.sum
    mfselect/dezowifi.rom
    mfselect/dezowifi.sum
    mfselect/mfinstall.yml
    mfselect/mfselect.nex
~~~

i.e. `cp -r build/deploy/* /path/to/card/`. **Nothing needs renaming and nothing needs placing by
hand** — the ROMs are built under the name the Next's firmware loads at boot, and both tools look
for them beside themselves under different names, so the same bytes wearing two names in two
directories is the build's problem rather than yours. (`make mfselect` alone leaves out
`dot/mfinstall` and `mfselect/mfinstall.yml`.)

One build produces the whole set with the same `BUILD_TIME`, which is what makes it coherent: the
stamp goes into each ROM, so a `.rom` paired with a `.sum` from another build is refused.

## Recommended: .mfinstall, from the NextZXOS command line

A dot command that installs either build straight into Multiface ROM space:

~~~
.mfinstall --load wifi     install the WiFi build
.mfinstall --load uart     install the UART build
.mfinstall --unload        put the stock Multiface ROM back
.mfinstall --auto          install whatever mfselect/mfinstall.yml says
.mfinstall --configure wifi|uart|none    set that file; install nothing
~~~

It is the comfortable one, for three reasons. **An install is live at the next NMI press** — no
reset and no power cycle, so switching between the two builds costs one command. **No ROM ever
reaches the SD card**, so nothing can be lost by a mistake or an interrupted write. And it can be
automated: put `.mfinstall --auto` in `AUTOEXEC.BAS` and the machine comes up with the debugger
installed, with `--configure` deciding which build without editing the file by hand.

The cost is that an install **lasts until power-off**, because it writes memory rather than the
card — which is exactly why `--auto` exists. `install: none` is a clean success, so leaving `--auto`
in `AUTOEXEC.BAS` on a day you are not debugging costs nothing. Full detail, including the
`AUTOEXEC.BAS` requirements that are easy to get wrong: [doc/MFINSTALL.md](doc/MFINSTALL.md).

## mfselect, the menu — and the one thing only it does

`mfselect` switches the installed Multiface ROM between the stock one and either of this project's
two builds, with the card still in the machine, by **replacing the file on the card**. Use it to
make the choice permanent, and run it once regardless, because **capturing the stock ROM is its job
alone**: `.mfinstall` deliberately does not duplicate that, since deciding whether what is installed
really is the stock ROM is the step that can lose it.

From the NextZXOS command line:

~~~
.nexload /mfselect/mfselect.nex
~~~

Up/Down to move, ENTER to choose:

![mfselect's menu on a ZX Spectrum Next](doc/images/mfselect-menu.png)

*A real screenshot, taken by `make test-mfselect` from a headless run — not a mock-up, so it cannot
drift from what the program actually draws.*

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
want over it. Changing your mind later means doing it again, and it also trips mfselect's first-run
guard — the two tools above exist so that neither has to happen.

## Starting the stub

Once installed, the stub starts after NextZXOS has booted, by pressing the yellow NMI button. To
re-initialise later, hold Symbol Shift (or CTRL) while pressing it. In WiFi mode the screen then
shows the address to connect to; in UART mode it shows the joy port in use and whether Pause can
reach you on it.


# Connecting DeZog

In WiFi mode the Next is a TCP **server** on port 11000, and DeZog connects to it. Point DeZog's
`zxnext` remote at that address instead of a serial device:

~~~json
"remoteType": "zxnext",
"zxnext": { "hostname": "192.168.1.42", "port": 11000 }
~~~

It is a `serial` property that selects a cable; **without one the socket transport is used**,
configured by `hostname` and `port`, which default to `localhost:11000` — the defaults a stub
running inside jnext wants, since the emulated ESP-01 listens on a host port. The two are mutually
exclusive, and `hostname` or `port` beside a `serial` is an error. A static DHCP reservation for the
Next is worth setting up, so the address never moves and `launch.json` is written once.

The `cspect` remote reaches the stub too, being a generic DZRP-over-socket client, but it places
editor breakpoints with a DZRP command the stub does not implement and explicitly refuses — so
breakpoints, ASSERTIONs and LOGPOINTs set in the editor will not fire there. Stepping is unaffected
either way, since temporary breakpoints travel inside the continue command. Use `zxnext`.

Also note that nothing else may use the ESP during a session — NextSync and friends will
reconfigure the module out from under the stub — and that a program using another ROM will not
work, because the stub patches the 48K BASIC ROM into the Alt ROM to make breakpoints and stepping
work in ROM code. Both are inherited constraints.


# License

This project is licensed under the [GNU General Public License v3](LICENSE).

It is a derivative work of [maziac/dezogif](https://github.com/maziac/dezogif), which is under the
MIT licence. That notice is retained in [NOTICE](NOTICE) and still governs maziac's original code;
the GPLv3 covers the combined work.

Example code meant to be copied into your own program — currently the 44-byte Copper snippet in
[doc/ASYNCHRONOUS-BREAK-USER-HOWTO.md](doc/ASYNCHRONOUS-BREAK-USER-HOWTO.md) — carries its own
licence note in that document.


# Acknowledgements

To **maziac**, for dezogif and for DeZog itself. Everything above the byte stream here — the
memory choreography, the AltROM trick, the breakpoint design, the DZRP command layer — is
maziac's work, and this fork would have been months of rediscovery without it.

And, in maziac's own words from the original readme:

> Many thanks to Chris Kirby. I have used his NDS code
> https://github.com/Ckirby101/NDS-NextDevSystem as starting point and used e.g. his routine to
> set the baudrate.
