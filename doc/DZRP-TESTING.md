# DZRP conformance testing

`make test-dzrp REMOTE=…` speaks DZRP to a remote and judges the exchange against the protocol
specification. Issue [#2](https://github.com/jorgegv/dezogif_ng/issues/2).

It is the only layer in this repository that exercises the wire. `make test` judges screenshots,
`make test-mfselect` judges files on an SD image, and the Z80 unit tests need VS Code — so until
this existed, the protocol, which is the entire deliverable, had no test.

## Running it

    make test-dzrp-stub                                 # OUR OWN WiFi stub, in jnext
    make test-dzrp REMOTE=tcp:192.168.1.42:11000        # a real Next over WiFi
    make test-dzrp REMOTE=tcp:127.0.0.1:11000           # anything listening locally
    make test-dzrp REMOTE=serial:/dev/ttyUSB0:921600    # UART mode (needs pyserial)

`make test-dzrp-stub` is the self-contained one and the reason the rest exists: it builds the
WiFi ROM, installs it as the Multiface ROM on a copy of the reference SD image, boots a headless
Next, presses M1 to bring the debugger up, waits for the stub's own `AT+CIPSERVER` listener to
appear on `127.0.0.1:11000` (that wait is check **W1**, and nothing else in this repository has
ever shown the ESP being brought up by the stub rather than by a fixture), and then runs the
suite against it.

It then does a **second** emulator run for check **W2**, which is about the transport rather than
the protocol: a client connects, sends `CMD_CONTINUE` and closes in the same breath, the debuggee
runs into a stray `RST 0`, and the stub tries to send an `NTF_PAUSE` to a connection that is
already gone. W2 asserts three things — that the module really did refuse the `AT+CIPSEND`
(read from jnext's own log, so a run where the situation did not arise fails instead of passing
vacuously), that the stub still serves a new client afterwards, and that **its screen reports no
error**, counted as bright-red pixels. Before the fix that count was 824: `Last Error: TX Timeout`.
Its own run because it deliberately crashes the debuggee and because the suite would repaint the
screen its verdict is read from.

Extra arguments go through `DZRP_ARGS`:

    make test-dzrp REMOTE=tcp:127.0.0.1:11000 \
         DZRP_ARGS="--require INIT,LOOPBACK --expect-preamble none"

| Flag | Meaning |
|---|---|
| `--require CMD,…` | absence of these commands is a FAILURE, not UNSUPPORTED |
| `--expect-preamble report\|a5\|none` | assert the frame preamble instead of only reporting it |
| `--start-byte auto\|a5\|none` | what the remote prefixes frames with (default: autodetect) |

## Validating the suite before trusting it

Point it at **CSpect and its bundled DeZog plugin**, which is a working DZRP remote. A red result
against our own stub then means the stub, not the harness.

    pgrep -f CSpect >/dev/null || ( cd ~/src/spectrum/CSpect3_1_0_0 &&
        timeout 180 mono ./CSpect.exe -w2 -zxnext -mmc=./ -brk -tv -r -debug & )
    make test-dzrp REMOTE=tcp:127.0.0.1:11000

Result on 2026-08-04, CSpect 3.1.0.0 / DeZogPlugin v2.3.0.20958 / DZRP 2.0.0 — **6 passed, 0
failed, 2 unsupported of 8**. That was the **eight**-check suite: **C9 has never been measured
against CSpect**, so it is validated only by having been shown failing against our own pre-fix ROM.

**Check that nothing else holds the port before believing a run of this.** Every check opens its
own connection, so a remote that comes and goes on 11000 — another jnext, a bench in a second
worktree — can serve *different checks of one suite run*. That is not hypothetical: an attempt to
measure C9 here produced three mutually contradictory results, and the tell was C1 reporting
`dezogif v2.2.1` / DZRP 2.1.0, which is our own stub, in a run aimed at CSpect. `make
test-dzrp-stub` refuses to start in that situation; `make test-dzrp` cannot, because it has no idea
what it was pointed at. `ss -ltn | grep 11000` first.

## Result against our own stub

**2026-08-04, issue #7 fixed — `make test-dzrp-stub`: W1 and W2 pass, and 9 passed, 0 failed, 0
unsupported of 9.** Version negotiation, the absent preamble, both length checks, loopback
round-trips exact at 0/1/255/256/1024/2047/2048/2049/4096 bytes, sequence echo across five
commands, a 37-byte register block, and a 64-byte memory write/read round trip.

**C2 was red until then, and it was never a transport defect.** `cmd_init` read the remote's
program name from the stream **until a NUL**, ignoring the frame's length field entirely, so a
frame whose length disagreed with its payload was consumed and answered — and the stream stayed
desynchronised for the rest of the session. Three things showed it was pre-existing rather than
introduced by the WiFi work: `src/commands.asm` was untouched by it, the UART ROM was
byte-for-byte identical to the one `main` shipped, and the frame-reading path (`cmd_loop`,
`receive_bytes`, `cmd_init`) is common code shared by both builds. It was [issue
#7](https://github.com/jorgegv/dezogif_ng/issues/7), and fixing it changed the serial ROM's bytes,
which is why it took its own branch and its own build-number bump.

`cmd_init.inner` now consumes exactly the payload the frame declared, like every other handler in
that file. **C9 is the other half of the same fix**, and it exists because C2 cannot reach it: C2
over-declares the length and requires silence, which proves the remote reads *at least* as far as
it was promised. C9 sends an honest length whose payload carries four bytes past the name's NUL,
then a second ordinary `CMD_INIT` behind it — a remote that frames on the NUL leaves those four
bytes to become the next command's header, and the second command comes back wrong or not at all.

**The first result against our own stub, for the record (2026-08-04):** W1 and W2 pass, 7 passed,
1 failed, 0 unsupported of 8 — the failure being C2, above.

**Not ZEsarUX.** ZEsarUX speaks ZRCP, its own protocol, reached by DeZog's `zrcp` remote type. It
is not a DZRP endpoint and cannot serve as a reference.

**Kill CSpect by PID, not `pkill -f CSpect`.** The pattern matches the command line of the shell
running it, so the shell kills itself — this cost two aborted commands before it was spotted.

## What the checks cover

| | |
|---|---|
| C1 | `CMD_INIT` negotiates a version |
| C2 | the length conventions are as specified — an over-declared length must not be answered |
| C3 | the frame preamble, reported and optionally asserted |
| C4 | `CMD_LOOPBACK` round-trips 32 bytes unchanged |
| C5 | `CMD_LOOPBACK` is exact at 0, 1, 255, 256, 1024, **2047, 2048, 2049** and 4096 bytes |
| C6 | sequence numbers echo back across consecutive commands |
| C7 | `CMD_GET_REGISTERS` returns a register block DeZog can index |
| C8 | memory write/read round-trip |
| C9 | `CMD_INIT` consumes exactly the declared payload, so the next command is still in sync |

**C5's sizes straddle a transport boundary, and that is the point of three of them.** jnext frames
inbound TCP into `+IPD` chunks of at most **2048** bytes
(`src/esp01/include/esp01/esp_at.h:448`), so anything larger reaches the remote as *several*
headers and has to be reassembled. The first version of this sweep stopped at 1024, which meant
every payload in the WiFi transport's evidence had arrived in a single frame and the reassembly
path — the most novel code in that transport — was never executed by a committed test. Real
traffic crosses it constantly: DeZog pushes 8-16 KB per `CMD_WRITE_BANK` when it loads a `.nex`.
2047/2048/2049 pin the boundary itself and 4096 forces more than one split, so a remote that
handles exactly one is not mistaken for one that handles any number.

**A partial remote is legitimate.** DZRP has 29 commands and remotes implement different subsets —
CSpect's plugin does not implement `CMD_LOOPBACK` at all, and closes the connection when it sees
one. An unimplemented command is therefore reported UNSUPPORTED rather than failed, unless named
in `--require`. Every check runs on its own connection so one refused command cannot take the rest
of the suite down; the suite retries briefly on connect, because a remote serving one client at a
time needs a moment to start listening again.

**What it deliberately does not test.** DeZog owns instruction-length calculation, the original
opcode under a breakpoint, the temporary breakpoints used to step off one, and condition
evaluation. Asserting those against the remote would encode the wrong contract and push whoever
tried to satisfy it into building the thing that fights DeZog at runtime.

## Two things this established that were not obvious

### The two directions use different length conventions

- A **command**'s length counts the **payload only** — neither the sequence number nor the
  command ID.
- A **response**'s (and a notification's) length counts **from the sequence number**.

The spec's two tables say exactly this, in wording easy to skim past. Sending `CMD_INIT` with a
symmetric length produced **no reply at all**: CSpect sat waiting for the two bytes it thought it
was still owed. Assuming symmetry costs a silent hang, not an error.

### Our stub's `0xA5` preamble is serial-only, and deliberately so

`src/message.asm` defines `MESSAGE_START_BYTE: equ 0xA5` and emits it before every response
(`send_4bytes_length_and_seqno`) and every notification (`send_ntf_pause`). It is emitted but
never expected — the receive path reads length/seq/command with no preamble.

That asymmetry is **by design, and documented upstream**. `doc/legacy/Design.md:30-31`:

> the DZRP protocol was extended by one byte which is sent as first byte of a message (only in
> direction from ZX Next to PC). This is the MESSAGE_START_BYTE (0xA5). DeZog will wait on this
> byte before it recognizes messages coming from the Next.

The reason is the paragraph above it: a game that takes the joy port leaves the Next transmitting
endless zeroes, and the preamble is how DeZog resynchronises. DeZog implements exactly that split
— `ZxNextSerialRemote` scans for and strips byte 165, `CSpectRemote` does not
(verified against the installed DeZog 3.7.4, `out/extension.js`), and `make test-dzrp`
against CSpect confirms the socket side emits none.

**So the byte is required in UART mode and must be absent in WiFi mode.** It is a property the
transport contributes, not a defect to delete. Removing it in both modes would break
interoperability with DeZog's real `zxnext` remote — the UART regression CLAUDE.md's hard rule
exists to prevent. See MEMORY.md for what M1 has to do about it.
