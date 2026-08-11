# DeZog breakpoints — why they do not work, and the four ways out

**Issue [#41](https://github.com/jorgegv/dezogif_ng/issues/41).** Written 2026-08-11, the day the
fault was measured, **before any code**. Nothing here is built.

The finding itself is in the issue and in `MEMORY.md`; this document is only about what to do about
it. In one line: a breakpoint placed in the VS Code editor sends `CMD_ADD_BREAKPOINT` (**40**), the
stub answers nothing, and DeZog carries on — so the red dot never fires and nothing says why.

---

## 1. The insight the options hang off: each DeZog remote has HALF of what we need

This is the thing to understand before comparing anything.

| | `cspect` remote | `zxnext` remote |
|---|---|---|
| transport | **TCP, hostname configurable** | **serial only** since DeZog 2.6.0 |
| breakpoints | `CMD_ADD_BREAKPOINT` 40 / `REMOVE` 41 | **`CMD_SET_BREAKPOINTS` 13 / `RESTORE_MEM` 14** — what the stub implements |
| the set/restore dance | none — the remote owns breakpoint state | **set all before continue, restore all on break** |
| `CMD_PAUSE` | **sent** — this is what M2 rests on | **refused client-side**: *"use the yellow NMI button"* |

**We took `cspect` for the socket and inherited its breakpoint API; the stub was built against
`zxnext`'s.** Neither remote is right on its own: one cannot reach us over the network, the other
disables the feature M2 exists for.

## 2. The constraint that decides everything: 216 bytes

**The WiFi build has 216 bytes free to the identity block** (measured after M2; `CLAUDE.md`
§Building). The UART build has 2946, and that asymmetry does not help — anything in
`src/commands.asm` is **common code and moves both ROMs**, so the WiFi figure is the budget.

**Re-measure before committing to anything that spends it.** The number is from the M2 merge and
this document does not assume it is still exact.

## 3. The hazard that rules out the CHEAP implementation

The obvious stub-side fix is: on ADD, patch the `RST 0` immediately and remember the opcode; on
REMOVE, put it back. `cmd_set_breakpoints` and `cmd_restore_mem` already do exactly that, so most of
the code exists.

**It does not work, and the reason is not cosmetic.** While the debugger is stopped, DeZog reads
memory and **disassembles it** — that is how it computes instruction lengths and where the 1-2
temporary breakpoints for a step belong (the division of labour `CLAUDE.md` calls a contract). If a
user breakpoint's `0xC7` is sitting in that instruction stream, DeZog disassembles **our patch
instead of the program**, computes the wrong length, and plants its step breakpoints at the wrong
addresses.

**That is precisely why 13/14 exist and why DeZog's serial remote restores every breakpoint on every
break.** Any stub-side implementation therefore has to do the same dance — patch on `CMD_CONTINUE`,
restore before `send_ntf_pause` — not the cheap version.

*(Stated as a mechanism, not a measurement: nothing here has watched DeZog mis-step over a patched
byte. It is why the client that owns this problem solves it that way.)*

---

## 4. Option A — answer honestly, implement nothing

**BUILT AND MERGED, 2026-08-11, build `00.22`.** `cmd_add_breakpoint` and `cmd_remove_breakpoint`,
checks **C24/C25**, shown red four ways. **38 bytes in both ROMs** — the estimate below said 25-40 —
of which 12 are the dispatch: two `cp`s in `get_cmd_pointer`'s `.not_supported` arm rather than
extending the jump table to 42 entries, which would have cost 36 bytes with 32 of them filler.
Free to the identity block is now **UART 2908, WiFi 178**. `UT_get_cmd_pointer` gained the two new
outcomes and the six neighbours (39, 42, 43, 44, 50, 51) that must still fall through, so an
off-by-one in either compare is caught headless. The rest of this section is the design as written
beforehand.

**DZRP already has a way to say "I cannot set a breakpoint there", and we are not using it.**
DeZog's `sendDzrpCmdAddBreakpoint` reads a **2-byte breakpoint id** from the response, and treats
**id 0** as refused: `e.bpId===0 && (e.longAddress=-1)`. The serial remote uses exactly this for
addresses it will not take, and emits *"On the ZXNext you cannot set breakpoints at …"*.

So: `cmd_add_breakpoint` consumes its declared payload and answers `Length=3` with id **0**;
`cmd_remove_breakpoint` consumes its two bytes and answers `Length=1`, as `cmd_pause` does.

- **What it buys**: the ~50 s stall goes, the session is not re-initialised through `drain_main`,
  the `Last Error` on the Next goes, and VS Code shows the breakpoint **unverified** instead of
  looking normal and doing nothing. A silent lie becomes an honest refusal.
- **What it does not buy**: breakpoints.
- **Cost**: the two handlers, plus reaching them — 40 and 41 are out of the jump table's 0…23 range,
  and extending the table to 42 entries costs **36 bytes of table** for 16 filler slots. A `cp 40` /
  `cp 41` special case in `get_cmd_pointer` is ~10. Estimate **25-40 bytes, both ROMs**.
- **The payload must be consumed exactly** — issue #7's lesson: 40 carries three address bytes plus
  a condition string, and leaving them in the stream desynchronises everything after it.

**It is compatible with every option below** and is the only one that improves matters this week.

## 5. Option B — implement 40/41 properly, in the stub

The full shape: an id → (long address, original opcode) table; ADD allocates an id and records;
REMOVE frees it; **`cmd_continue` patches every live entry**; the break path **restores every one**
before `send_ntf_pause`.

- **For**: self-contained. No PC-side component, no upstream dependency, works with a stock DeZog.
- **Against**: it is the most code, in the language with the least room, in **common code that moves
  both ROMs**, against a 216-byte budget — and it **duplicates logic DeZog already has and tests**.
  A table also imposes a breakpoint limit the client does not know about, and `bp_hits_trampoline`'s
  guard (issue #27) has to be honoured on every patch.
- **Feasibility is genuinely open.** Eight entries × 4 bytes is 32; the two handlers, the id
  allocator and the two hooks are not obviously under 180. **Nobody has costed it.**

## 6. Option C — a DeZog remote type that speaks 13/14 over a socket

The plan's **M4**, and the clean answer: a remote that keeps `zxnext`'s breakpoint logic — which the
stub already implements and which C19-C21 verified on hardware — and `cspect`'s socket and
`CMD_PAUSE`. Mechanically it is a small subclass; DeZog is MIT, active, and ships
`design/AddingNewRemotes.md`.

- **For**: zero Z80 bytes; the correct set/restore dance for free, already written and tested;
  it ends the "configuring something called cspect to talk to a Next" awkwardness.
- **Against**: it is **upstream's repository and upstream's release schedule**. Nothing ships until
  Maziac merges and cuts a version. **The licence decision has to be made when the code is written**
  — GPLv3 code cannot go into an MIT project, so this must be authored to be offerable under MIT
  (plan §6).

## 7. Option D — a PC-side proxy that translates 40/41 into 13/14

A small local process between DeZog and the Next: it forwards everything untouched except
breakpoints, holding the same state DeZog's serial remote holds — collect breakpoints from 40/41,
send them as one `CMD_SET_BREAKPOINTS` on `CMD_CONTINUE`, `CMD_RESTORE_MEM` them when the
`NTF_PAUSE` comes back.

- **For**: **zero ROM bytes**, no upstream dependency, works with a stock DeZog **today**, and — the
  part that matters here — **it is testable headless**, against the emulated stub, with the benches
  that already exist. It keeps `CMD_PAUSE`, so M2 is unaffected. `launch.json` already carries a
  *"Real Next over WiFi + local Tap"* configuration pointing at `127.0.0.1:11001`, so the shape is
  precedented.
- **Against**: a second component to run and to explain; a debugging session that now has three
  parties; and it sits against the instinct of §4.2, which refused a PC-side relay. **That refusal
  was about the transport** — a relay *required* for basic function — and this is optional and
  additive, but the objection deserves to be answered rather than waved past.
- It is also the **prototype of C**: the same state machine, in Python, where it can be measured.

## 8. Option E — not recommended, but it explains the shape of the problem

Point DeZog's **`zxnext` serial remote** at the Next through a virtual serial port
(`socat PTY,link=… TCP:<next>:11000`) and build the WiFi ROM **with** the `0xA5` preamble, which is
already an assembly-time property of the transport.

Breakpoints would then work with no new logic anywhere — the stub already implements exactly what
that remote sends. **But that remote refuses `CMD_PAUSE` client-side**, so it trades M2 away. Listed
because that trade is the clearest statement of §1: the two remotes have one half each.

---

## 9. Comparison

| | ROM bytes | works today | breakpoints | Pause | testable headless |
|---|---|---|---|---|---|
| **A** honest refusal | ~25-40, both ROMs | **yes** | no — but *says* so | yes | yes |
| **B** implement in Z80 | large, **budget 216** | yes | yes | yes | yes |
| **C** DeZog remote type | **0** | no — upstream | yes | yes | not by us |
| **D** PC-side proxy | **0** | **yes** | yes | yes | **yes** |
| **E** serial remote + socat | ~0 | yes | yes | **NO** | no |

**Suggested reading of that table** — a recommendation, not a decision:

1. **Do A regardless and soon.** It is small, it is compatible with everything below, and it turns
   the worst property of this bug — silence — into an honest refusal. It is the same move #8 made
   for `CMD_PAUSE` and #9 for the sprite commands.
2. **D for the working fix**, because it is the only one that delivers breakpoints *and* Pause
   without spending ROM we do not have or waiting on someone else's release, and because it can be
   put under the benches.
3. **C when there is appetite for an upstream conversation** — D is its prototype, so the work is
   not wasted.
4. **B only if being self-contained is worth more than the budget**, and only after the 216 bytes is
   re-measured and the design costed.

## 10. DECIDED, 2026-08-11: option C, as a PR, and Maziac has asked for it

**BUILT AND VALIDATED ON HARDWARE THE SAME DAY — PR
[maziac/DeZog#186](https://github.com/maziac/DeZog/pull/186)**, opened as a draft
and taken out of draft by the user the same evening. A breakpoint set
in the VS Code editor is verified and **hit**, Continue from it hits it **again,
repeatedly**, Pause returns control, and `IM` reads `?`. Measured on the user's
own Next at build `00.22`, core 03.02.01, ESP at 460800.

**The shape below is what was designed; the shape built is smaller.** On the
user's "as minimal as possible", the abstract-base extraction this section
prescribes was **not** done: `ZxNextSocketRemote` simply **derives from
`ZxNextSerialRemote`** and overrides three of the four transport members, which
is upstream's own idiom — `ZxNextSerialLoopback` already derives from it the same
way. The fourth, `dataReceived`, became a two-line `usesMessageStartByte` guard
rather than an override — the only change to the **serial path's runtime**
behaviour, and it defaults to the previous one. Everything else in this section
held: the four members were the right four, and `CMD_PAUSE` and the `0xA5`
preamble both needed no flag.

*(An earlier version of this paragraph said that guard was the only change to
existing behaviour in the **whole diff**. It was not: `settings.ts` also lost the
`port` arm of 2.6.0's obsolete-property error, so a leftover 2.5.x `port` beside
a `serial` stopped erroring. Found by the independent review, by running both
trees rather than reading the diff, and fixed — see MEMORY.md.)*

**The claim about pausing was narrowed before it shipped.** "Through a socket the
program can be paused" is true of *this* stub with M2 and a cooperating debuggee
and false of stock dezogif; what the change does is stop the **client** refusing
the command. See MEMORY.md.

**Issue #41 stays open.** `00.22` ships the honest refusal (option A); breakpoints
work only for someone running that branch of DeZog, and only until it is released.


**He offered; the user accepted; he wants the PR.** That retires C's one real objection — plan §7's
*"a PR adding a remote type for a target that does not exist yet is not practically mergeable,
because the maintainer has nothing to test against"* — on both halves: the target now runs on
hardware, and the maintainer has asked. **B is dead** (writing dialect 1 in Z80, in what is now 178
free bytes, to work around a client about to speak our dialect natively). **D is not needed** unless
breakpoints are wanted before his release lands.

**Shape chosen by the user: keep `remoteType: "zxnext"` and select the transport from the
configuration** — `serial` present → serial, `hostname` present → socket. It restores the pre-2.6.0
shape rather than adding a fifth remote name, and a PR is where he can overrule it. The alternative
considered was a new `zxnextsocket` type, which cannot disturb existing users; say so in the PR.

### What the sources say — read 2026-08-11 from `~/src/spectrum/dezog.jorgegv` (fork of maziac/DeZog, `main` @ `283d18ef`), NOT from the minified bundle

`CSpectRemote` (244 lines) and `ZxNextSerialRemote` (704) are **siblings**, both extending
`DzrpBufferRemote`. **`ZxNextSerialRemote` has only four transport-specific members**:

| | |
|---|---|
| `doInitialization()` | opens the `SerialPort` (`serialport` package, 921600) |
| `closeSerialPort()` / `disconnect()` | closes it |
| `sendBuffer()` | writes to it |
| `dataReceived()` | swallows zeroes up to the first `0xA5` |

Everything else is transport-independent: the whole breakpoint dialect (`sendDzrpCmdContinue`'s
set-before / restore-after, `AddBreakpoint`, `RemoveBreakpoint`, `getBreakpointAddresses`,
`checkBreakpoint`), `calcStepBp`, `startCmdRespTimeout`, and every "the Next cannot do this" refusal.

**So the work is: extract an abstract base holding the shared logic, and supply those four from
either a serial or a socket implementation** — the socket one borrowing ~60 lines from
`CSpectRemote`. Then `remotefactory.ts`, the settings schema and `package.json`.

**Three findings that shrink the problem:**

1. **The `CMD_PAUSE` refusal needs no flag, no capability negotiation and no configuration.**
   `sendDzrpCmdPause()` throws *"use the yellow NMI button"* — and that is **a property of the
   transport, not of the machine**: over a cable the stub hands the joy ports back on resume, which
   re-points UART0's RX away from the pin the cable is on, so no PC byte can land while the program
   runs. It stays in the serial class; the socket class simply does not carry it. An earlier draft of
   this document, and of the message to Maziac, proposed a config flag — unnecessary.
2. **The `0xA5` preamble handles itself the same way.** `dataReceived()`'s swallowing is serial-only
   and stays there; the socket path inherits `DzrpBufferRemote`'s plain version, which is exactly
   right for a WiFi build that emits no preamble.
3. **A small honesty bug we did not know we had.** `ZxNextSerialRemote` overrides the register
   decoder with `Z80RegistersZxNextDecoder`, whose only job is `parseIM()` → `NaN`, because a ZX Next
   stub cannot read the interrupt mode back. We use `CSpectRemote`, which uses the standard decoder —
   **so DeZog has been showing an IM value the stub cannot know.** Switching remotes fixes it free.

Compatible on versions: `ZxNextSerialRemote` sets `DZRP_VERSION = [2,1,0]` and our stub answered
exactly `2 1 0` in the 2026-08-11 capture.

### Licensing

New TypeScript, written from scratch, **licensed MIT** so it fits DeZog — decided now rather than
afterwards (plan §6). Nothing from this GPLv3 tree may be pasted into it; nothing there is worth
copying anyway.

### ~~Not started~~ Built

~~No branch, no `upstream` remote on the fork yet, nothing written.~~ Branch
`zxnext-socket-transport` on `jorgegv/DeZog`, `upstream` remote added and level with
`283d18ef` when it was cut. **The commit count and diff stat are deliberately not quoted
here** — they belong to a live PR in somebody else's repository, and an earlier version of
this section quoted them and was falsified within the hour. Read them off
[the PR](https://github.com/maziac/DeZog/pull/186). **The installed extension at
`~/.vscode/extensions/maziac.dezog-3.7.4/` has never been modified** and must not be: development
used VS Code's Extension Development Host against the fork, whose launch args carry
`--disable-extensions`, so the installed DeZog is inert in that window and cannot be what answered.

The test rig is kept: worktree `~/tmp/worktrees/dezogif_ng/dezog-pr-test` (branch `dezog-pr-test`)
carries a `Next: zxnext socket (PR test)` launch configuration and its own build of the
pause-transparency fixture, so the session is one keypress to repeat. It is a separate worktree
because VS Code refuses to open one folder in two windows.

## 11. What this document does not establish

- ~~**Nothing here has been built or run.** Every byte figure is an estimate.~~ **Option A was
  built (`00.22`) and option C is built and validated on hardware — §10.** What is still an
  estimate is every byte figure for **option B**, which is dead, and for option D, which is not
  needed. What option C has **not** exercised: the **serial path**, which is the one existing
  file the PR touches and which has no adapter here; breakpoints at addresses `checkBreakpoint`
  refuses; conditions, LOGPOINTs and ASSERTIONs; and any emulator run, so there is no repeatable
  regression check for it — only a hardware session.
- **The disassembly hazard in §3 is a mechanism, not a measurement.** Nobody has watched DeZog
  mis-step over a patched byte; the argument is that the client which owns this problem solves it by
  restoring.
- **Conditions are untested.** `CMD_ADD_BREAKPOINT` carries a condition string (empty in the
  capture). Whether DeZog expects the remote to evaluate it, or evaluates it itself for a remote that
  ignores it, is not checked here — and it bears on B and D.
- **The breakpoint limit** a table imposes, and what DeZog does when it is exceeded, is unknown.
- **The UART build.** Everything above assumes the WiFi transport; no DeZog client has ever driven
  the serial one.
