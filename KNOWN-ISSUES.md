# KNOWN-ISSUES.md — faults that are understood, deliberately unfixed, and rare

Each entry here is a **real** fault: reproduced, with a traced mechanism, and closed as **WONTFIX**
rather than solved. None is speculative, and none is a fault in something else wearing our name.

**Why a file rather than a closed issue.** A closed issue is read by whoever goes looking for it.
These are things somebody will meet *first* and search for *afterwards* — so the symptom is the
heading, and the first thing under it is how to tell it apart from a bug that is worth reporting.

**One fact, one home.** Where the measurements live somewhere else — `doc/HARDWARE-TESTING.md` for
anything read off a real Next, `MEMORY.md` for why a decision went the way it did — this file
points at them instead of restating them. Two renderings of one fact drifting apart is a failure
this project has paid for repeatedly; see `ERRORS.md`.

**#19's home is `doc/HARDWARE-TESTING.md`, beside the probe run that measured it. #18 has no such
home, so this file IS its home** — its figures were measured on hardware on 2026-08-05 and until
now lived only in the GitHub issue, which is not diffable and not readable offline.

**None of these is a reason to distrust a green bench.** Both are states no bench here reaches, and
both were found on hardware.

---

## 1. The debugger stops answering while one client is not reading

**Issue [#18](https://github.com/jorgegv/dezogif_ng/issues/18) · WONTFIX · WiFi build only**

### In one line

**Don't leave a client connected without reading from it. If you do, wait — it clears by itself
within about 3 s of that client going away.** The stub *could* prevent this, and deliberately does
not: see "why this is not fixed" below.

### Symptom

The Next stops answering DZRP entirely — a second connection gets nothing, and the machine's own
`R` and `B` keys do not respond either — for as long as one client holds a socket open without
reading from it. Then everything recovers on its own.

**The dead keyboard is the discriminator against #19 below**, which produces a very similar picture
from the PC side but leaves the stub idle and its keys working.

### What causes it

A client that asks for a large response and stops draining its socket. Measured on a real Next,
build `000B`, 2026-08-05: `SO_RCVBUF` 256, `CMD_READ_MEM` for 16384 bytes, never read. The client's
TCP window closes, and **every `AT+CIPSEND` chunk still succeeds — slowly**. There are roughly 68 of
them, each taking up to about a second.

That is why no existing timeout reaches it: `ESP_TX_PASSES` and `ESP_RX_WAIT` bound a *single*
chunk, and the defect is in the *total*. Nothing in the transport has a time source with which to
bound the total (`MEMORY.md`, issue #16's entry, records the same conclusion).

The keyboard is dead in the same window for a structural reason rather than a mysterious one: the
key poll is in `main_loop` (`src/main.asm`, `.no_uart_byte`), which is not reached while a response
is being flushed. **That part is traced, not measured** — the 33 s figure below is the socket, and
nobody has timed the keys.

### What does NOT cause it

**DeZog in normal use.** It drains its socket, so an ordinary debugging session does not produce
this. It takes a client that has stopped reading: a suspended laptop, a debugging proxy that stalls,
a process killed with its kernel buffer already full.

### Impact, and why it is smaller than the issue title suggests

The title says it blocks *every other client*. In practice there is normally **one** client — DeZog
opens a single connection — so the peer being starved is usually the same session that is already
broken. **It recovers by itself within about 3 s** of the offending client going away; 33 s was
observed only because the test client held on that long deliberately.

### What to do

Nothing, usually — wait. If the client is a suspended laptop, resuming or closing it ends the
window. No power cycle is needed and no state is lost: the debuggee is untouched.

### What is not known

**How often this happens in real use.** Nobody has measured it. A suspended laptop mid-session is
ordinary, so "rare" here means "bounded and self-healing", not "unlikely".

### Why this is not fixed

**This one is a cost judgement, not an impossibility** — and saying otherwise would be the easy
overclaim. The stub *can* bound it: count the total time spent flushing one response and close the
connection when it runs over. What that buys is ending a self-healing 3 s stall slightly sooner,
for a debugger that normally has exactly one client — the same client whose laptop just went to
sleep. What it costs is Z80 in the transport, a new bound to get wrong, and a decision about what a
peer sees when a response is abandoned mid-stream, which DZRP has no way to express. That trade was
judged not worth making (user, 2026-08-06).

### What would make it worth fixing

Any of: a report of it lasting long enough to matter; a client that is *not* a stalled peer
triggering it; or evidence that the dead keyboard costs somebody a debugging session. The design is
already settled if it comes to that — bound the **total** elapsed time across chunks by counting
expired RX passes (one pass ≈ 100 ms, counted at a label that only runs when a pass expires, so the
hot path is untouched), close the connection when the bound is hit, and keep all of it inside
`src/transport_esp.asm`: `TRANSPORT_MESSAGE_START` already exists as a transport-owned hook, so
`src/message.asm` does not need to change and the UART build's byte-identity gate stays intact.

---

## 2. The Next refuses every connection until it is power-cycled

**Issue [#19](https://github.com/jorgegv/dezogif_ng/issues/19) · WONTFIX · WiFi build only**

### In one line

**Don't let a machine with an open debug session vanish off the network — crash it, cut its power,
or suspend it and reopen it somewhere else. If you do it five times without power-cycling the Next,
power-cycle the Next.** The stub is told nothing when a peer vanishes, so it cannot *detect* this;
what it could do instead is described under "why this is not fixed", and like #18 that is a cost
judgement rather than an impossibility.

### Symptom

TCP connections to the Next stop completing — they time out rather than being refused — while the
stub's own screen stays **clean**: no error text, `Core:` line intact. A power cycle fixes it.
Nothing else does.

**THE KEYBOARD IS WHAT TELLS THIS APART FROM #18**, and from the outside they otherwise look almost
identical — connections not completing, screen clean. Here the stub is perfectly healthy and idle,
so **`B` still toggles the border and `R` still resets**. In #18 it is stuck inside a flush and the
keys do nothing. Try the keys before concluding anything, and before power-cycling.

### What causes it

The ESP module holds a small number of inbound connections (**5**, measured on a real Next) and
nothing frees a slot belonging to a peer that went away **without sending a FIN or an RST**. Five
such peers and the module has nothing left to give anyone.

Measured on a real Next, build `00.0F`, 2026-08-06 — four vanished peers are survivable, the fifth
is not. The full run, the cross-check against the module's ceiling, and what the shipped fix does
and does not cover are in **[doc/HARDWARE-TESTING.md](doc/HARDWARE-TESTING.md)**, under probe B.

### What does NOT cause it

All of these free the slot, and all were measured on hardware:

- closing the connection normally (**FIN**) — DeZog quitting, Shift+F5, a clean disconnect;
- an **RST** — a crash, a killed process, a refused socket;
- a client killed mid-command.

So the ordinary ways a debug session ends are all safe.

### What does

A peer whose **whole host** stops transmitting: a hard crash or power cut, a VM destroyed, or a
**laptop suspended mid-session and resumed on a different network** — the socket's retransmissions
never reach the Next again and no RST ever arrives. The last of those needs no special privileges
and is entirely ordinary.

### What to do

**Power-cycle the Next.** A Symbol Shift + NMI re-init does not help — it calls `transport_init`
directly and never runs the sweep, and `AT+CIPSERVER=1` is refused while a listener is already up,
so the re-init fails at its own AT chain.

**Before you power-cycle, photograph the screen and try the `B` key.** That is the only way to tell
this from a wedged stub, and the power cycle destroys the evidence — see below.

### What is not known

**The rate.** Nothing measures how often a peer vanishes this way in the field. The five leaks must
accumulate between two power-ons, but they are **not independent events**: one persistent cause — a
flaky link, a router that reboots nightly, a habitually suspended laptop — can strand several.

### What would reopen it

Connections refused, screen clean, and no power cycle since boot. **`make probe-slots` cannot
settle it in that state** and it is important not to expect it to: its discriminating check asks
whether an *earlier* connection still answers, and a module with every slot leaked has no earlier
connection to ask. The tool says so itself. **The discriminator is the machine's own screen** — a
live stub draws cleanly and answers its keys, a wedged one does not.

### Why this is not fixed

**The stub cannot DETECT this, and that part is solid.** A vanished peer sent no FIN and no RST, so
the module still believes the connection is open and the stub is told nothing at all. Every
application-layer signal it might lean on is unavailable or wrong: `<id>,CLOSED` never arrives for a
peer that vanished; DZRP has no keepalive; and **idleness cannot be the trigger**, because a DeZog
session stopped at a breakpoint while somebody reads code is silent for minutes and perfectly
healthy — which is exactly why issue #16's idle wait is deliberately not counted as a fault.

**But "cannot detect" is not "cannot prevent", and an earlier version of this entry said the
stronger thing.** It was rejected in review for contradicting the sentence three paragraphs below,
which describes a fix. Two mechanisms exist that are not "closing on suspicion", and each has a
real cost rather than being impossible:

* **Sweep at connect time.** When a client attaches, close the *other* link ids. Leaks would then
  never accumulate to the ceiling, because each new debugging session clears whatever the last one
  stranded. It does **not** rescue the terminal state — by then no client can connect to trigger it
  — and it costs the multi-client behaviour this transport deliberately built and tests (issues #11
  and #13; bench checks W4 and W5 rely on two clients being served at once).
* **A TCP-level keepalive on the module.** ESP-AT does carry the concept — `AT+CIPSTART`'s fourth
  TCP argument is a keepalive, which jnext parses and discards — but that is the **outbound** form,
  and whether a server-accepted inbound link can be given one is **unverified**. jnext does not
  model it, so no bench here can answer the question; it needs the real firmware's documentation or
  the module itself. If it exists, the module's own stack would decide liveness and the stub would
  need no guesswork at all.

Neither has been scoped, and the decision is to leave both unscoped rather than that neither could
work.

### What already shipped

Build `00.10` added a sweep: on recovery, the stub closes every link id with `AT+CIPCLOSE=<id>`.
That reclaims slots when the leak coincides with some **independent** transport fault. It cannot
reach the state above, because a vanished peer generates no faults at all — traced in
`src/transport_esp.asm`'s `esp_recover` header and in `doc/HARDWARE-TESTING.md`.

One leg of that trace is **jnext-grounded rather than hardware-verified**, and this project hedges
that distinction everywhere else so it is hedged here: the claim that an unprompted send to a stale
id is answered `ERROR` at once, and so raises no fault, is jnext's modelled behaviour. A real module
might instead sit on such a send until the stub's own budget expires, which *would* raise a fault —
and would, ironically, make the shipped sweep more useful than this entry credits it for. Nobody has
measured it. The primary leak path does not depend on this leg: a peer that vanishes while nothing
is being sent to it produces no traffic in either direction.

Closing the gap properly needs a sweep reachable from a **quiet** stub — periodic, or at connect
time — which is a change nobody has scoped.
