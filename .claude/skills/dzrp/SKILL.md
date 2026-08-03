---
name: dzrp
description: Look up authoritative DZRP (DeZog Remote Protocol) behaviour, and drive CSpect as a reference DZRP implementation to compare against. Use when the user asks "what does DZRP say about X", "which command does Y", "how does CSpect answer Z", or before implementing or changing any DZRP command handler in the stub.
---

# DZRP protocol lookup and CSpect oracle

DZRP is the wire protocol between DeZog (PC) and this stub (Next). It is **not** ours to redefine — the client is a released product and its assumptions are a contract.

## Sources of authority, in order

1. **The spec** — https://github.com/maziac/DeZog/blob/main/design/DeZogProtocol.md
   Fetch it rather than reciting from memory; it is versioned and it has changed.
2. **DeZog's own docs** — https://github.com/maziac/DeZog/blob/main/documentation/Usage.md
   for what the client *does with* a command (which is often more constraining than the wire format).
3. **CSpect's DeZog plugin** — https://github.com/mikedailly/CSpectPlugins/tree/main/DeZogPlugin
   a working remote. When the spec is ambiguous, this is what the client is actually tested against.
4. **dezogif upstream** — `doc/legacy/Design.md`, for how a *constrained* remote implements the same subset.

## Things that are settled, do not re-derive

- **The command set is 29 commands.** `CMD_INIT=1`, `CLOSE=2`, `GET_REGISTERS=3`, `SET_REGISTER=4`, `WRITE_BANK=5`, `CONTINUE=6`, `PAUSE=7`, `READ_MEM=8`, `WRITE_MEM=9`, `SET_SLOT=10`, `GET_TBBLUE_REG=11`, `SET_BORDER=12`, `SET_BREAKPOINTS=13`, `RESTORE_MEM=14`, `LOOPBACK=15`, `GET_SPRITES_PALETTE=16`, `GET_SPRITES_CLIP_WINDOW_AND_CONTROL=17`, `GET_SPRITES=18`, `GET_SPRITE_PATTERNS=19`, `READ_PORT=20`, `WRITE_PORT=21`, `EXEC_ASM=22`, `INTERRUPT_ON_OFF=23`, `ADD_BREAKPOINT=40`, `REMOVE_BREAKPOINT=41`, `ADD_WATCHPOINT=42`, `REMOVE_WATCHPOINT=43`, `READ_STATE=50`, `WRITE_STATE=51`, plus the `NTF_PAUSE` notification.
- **Remotes implement different subsets.** `CMD_INIT` negotiates versions; a partial server is legitimate. Breakpoints in particular "differ considerably on a real ZXNext".
- **There is NO history, trace or replay command.** Reverse debugging is implemented wholly inside DeZog from what it observes while stepping, and stores registers and stack only — not memory. Do not plan around a remote-side history feature; it does not exist. See `doc/ZXNEXT-REMOTE-DEBUG-STUB.md` Appendix C.
- **`CMD_READ_STATE`/`CMD_WRITE_STATE` is `-state save`/`-state restore`**, a bookmark. Its payload is "arbitrary data, the format is up to the remote". It is not time travel.
- **Breakpoint bookkeeping lives in DeZog**, not in the remote: instruction length, the original opcode, the 1-2 temporary breakpoints for stepping off a breakpoint, and condition evaluation. A conditional breakpoint is an unconditional pause as far as we are concerned.

## Using CSpect as a reference implementation

CSpect + its bundled DeZog plugin is a working DZRP remote listening on port 11000. To see how a command is really answered, point DeZog at CSpect and capture the exchange.

**Lifecycle safety — always, no exceptions:**

- Wrap every launch in `timeout`. A wedged `mono` process will otherwise sit there consuming a core.
- Bracket the run with `pkill` before and after, so a previous stuck instance cannot poison the result.
- Never leave CSpect running between tool calls without a timeout guarding it.

```bash
pkill -f CSpect.exe 2>/dev/null || true
timeout 60 mono /home/jorgegv/src/spectrum/CSpect3_1_0_0/CSpect.exe -w2 -zxnext -mmc=./ -exit -brk -tv -r -debug
pkill -f CSpect.exe 2>/dev/null || true
```

## Smoke-test order when bringing up our own server

Implement and prove in this order — it isolates transport faults from protocol faults:

1. **`CMD_LOOPBACK=15`** — proves framing, byte order and the transport end to end without touching machine state.
2. **`CMD_INIT=1`** — proves version negotiation and that DeZog will proceed at all.
3. `CMD_GET_REGISTERS`, then memory, then breakpoints.

If `CMD_LOOPBACK` does not round-trip cleanly, nothing above it is worth debugging.

## Hard rules

- **Cite the spec, don't paraphrase it.** Quote the command's table when answering a wire-format question.
- **Never invent a command or a field.** If DZRP cannot express something, say so plainly — that is a real finding, and at least once it has changed a design decision.
- **CSpect is a reference, not the spec.** Where they disagree, report the disagreement rather than silently following either.
