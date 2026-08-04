# DZRP conformance testing

`make test-dzrp REMOTE=…` speaks DZRP to a remote and judges the exchange against the protocol
specification. Issue [#2](https://github.com/jorgegv/dezogif_ng/issues/2).

It is the only layer in this repository that exercises the wire. `make test` judges screenshots,
`make test-mfselect` judges files on an SD image, and the Z80 unit tests need VS Code — so until
this existed, the protocol, which is the entire deliverable, had no test.

## Running it

    make test-dzrp REMOTE=tcp:192.168.1.42:11000        # a real Next over WiFi
    make test-dzrp REMOTE=tcp:127.0.0.1:11000           # anything listening locally
    make test-dzrp REMOTE=serial:/dev/ttyUSB0:921600    # UART mode (needs pyserial)

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
failed, 2 unsupported of 8**.

**Not ZEsarUX.** ZEsarUX speaks ZRCP, its own protocol, reached by DeZog's `zrcp` remote type. It
is not a DZRP endpoint and cannot serve as a reference.

**Kill CSpect by PID, not `pkill -f CSpect`.** The pattern matches the command line of the shell
running it, so the shell kills itself — this cost two aborted commands before it was spotted.

## What the checks cover

| | |
|---|---|
| C1 | `CMD_INIT` negotiates a version |
| C2 | the length conventions are as specified — see below |
| C3 | the frame preamble, reported and optionally asserted |
| C4 | `CMD_LOOPBACK` round-trips 32 bytes unchanged |
| C5 | `CMD_LOOPBACK` is exact at 0, 1, 255, 256 and 1024 bytes |
| C6 | sequence numbers echo back across consecutive commands |
| C7 | `CMD_GET_REGISTERS` returns a register block DeZog can index |
| C8 | memory write/read round-trip |

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
