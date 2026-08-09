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

**#19's home is `doc/HARDWARE-TESTING.md`, beside the probe runs that measured it. #18 has no such
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

## 2. The Next refuses every connection, and starts working again by itself

**Issue [#19](https://github.com/jorgegv/dezogif_ng/issues/19) · WONTFIX · WiFi build only**

### In one line

**Don't let a machine with an open debug session vanish off the network — crash it, cut its power,
or suspend it and reopen it somewhere else. Do it five times in quick succession and the Next stops
answering anybody. WAIT — it clears itself. Do not power-cycle.** The stub is told nothing when a
peer vanishes, so it cannot *detect* this; the module underneath it reaps the dead connections on
its own idle timer, which is what ends the fault.

**HOW LONG YOU WAIT DEPENDS ON THE BUILD, and on any build from `00.14` it is THIRTY minutes rather
than three.** The timer is the module's `AT+CIPSTO`, and since issue #24 the stub *sets* it:

| build | the stub sends | you wait |
|---|---|---|
| before `00.14` | nothing — the firmware default governs | **~3 min** |
| **`00.14` and later** | **`AT+CIPSTO=1800`** at bring-up | **~30 min** |

**That is a deliberate trade, not a regression.** The firmware's 180 s was hanging up on **idle
debug sessions** — a DeZog session parked at a breakpoint while somebody reads code is silent for
minutes and perfectly healthy, and the module was dropping it. #24 bought that back at the cost of
this entry's self-heal. The common fault got fixed; the rare one got slower.

**Build `00.18` adds a stub-side sweep at five minutes, and it does NOT generally apply here** — it
only counts while the stub believes no DZRP session is open, and a vanished peer never clears that
belief. See "What to do" for which shapes it reaches. **Do not read "five minutes" as the answer to
this entry.**

**This entry said "power-cycle the Next" until 2026-08-08, and that was wrong.** See "why the old
advice was wrong" below — the mechanism of the error is more useful than the corrected number.

### Symptom

TCP connections to the Next stop completing — they time out rather than being refused — while the
stub's own screen stays **clean**: no error text, `Core:` line intact. **It ends by itself** — after
about **thirty minutes** on a current build, three on one older than `00.14` — and the machine
serves normally again with nothing done to it.

**THE KEYBOARD IS WHAT TELLS THIS APART FROM #18**, and from the outside they otherwise look almost
identical — connections not completing, screen clean. Here the stub is idle, so **`B` should still
toggle the border and `R` should still reset**. In #18 it is stuck inside a flush and the keys do
nothing. Try the keys before concluding anything.

**The clock is a second discriminator, and a coarse one is enough**: #18 clears within about **3
seconds** of the offending client going away, this within about **1800** on a current build (180 on
one older than `00.14`). Two or three orders of magnitude apart is not a distinction anybody has to
measure carefully — and the gap got *wider* with #24, not narrower, so this discriminator is safer
than it was.

**TRACED, NOT MEASURED — the same hedge #18's half of this carries, and it matters more here.**
Nobody has pressed a key during a live five-slot exhaustion on hardware: `test/vanished-peer-probe.py`
neither presses one nor reads the border. The trace is that nothing in the terminal state occupies
the Z80 — a new client never completes its handshake, so no `+IPD` ever arrives (probe B's V5,
10009 ms), and the leaked peers carry no traffic in either direction, so `main_loop` reaches
`.no_uart_byte`'s key poll every iteration exactly as it does when idle. That is a solid trace and it
is still not a measurement, which is worth knowing **because this is the discriminator you reach for
first**. It is also far easier to collect than it was: the fault is now bounded rather than lasting
until the power switch, so there is time to try the keys, and nothing you do destroys the evidence
the way a power cycle did. On a current build that window is **half an hour**, which is ample.

### What causes it

The ESP module holds a small number of inbound connections (**5**, measured on a real Next) and
**nothing on the Z80's side of the UART** frees a slot belonging to a peer that went away *without
sending a FIN or an RST* — not the stub, and not anything a user can type at the machine. Five such
peers and the module has nothing left to give anyone.

What ends it is the module's own **`AT+CIPSTO` idle timeout**, and it is enforced. It reaps **each
connection separately**, `<time>` seconds after *that* peer last spoke — so the slots come back one
at a time, oldest first, and one is all it takes to start serving again.

**`<time>` IS NOT A CONSTANT, and this is the paragraph the rest of the entry's numbers come from.**
The firmware default is **180 s**, which is what the module reports and what was measured. **Since
issue #24 the stub sets it to 1800 at every bring-up** (the value does not persist to flash, so it
is re-sent each time), and from build `00.14` that is what governs. `AT+CIPSTO?` at the machine,
with `.UART`, is what settles which you have.

**So the clock starts at the OLDEST vanished peer, not the newest**, and one full timeout after the
*last* one is therefore a safe over-estimate rather than the figure. Nothing here can separate the
two: the probe's peers all vanished inside a 13 s walk, which is well under the resolution needed.
Quoted the conservative way round on purpose, since the cost of waiting slightly too long is
nothing and the cost of concluding "it should have recovered by now" is a power cycle.

Measured on a real Next, build `00.0F`, 2026-08-06 — four vanished peers are survivable, the fifth
is not — and the self-heal measured on 2026-08-08, two runs bracketing the timer from either side.
The full runs, the `AT+CIPSTO?` reading off the module, why it cannot be the stub's own sweep, and
what the shipped fix does and does not cover are all in
**[doc/HARDWARE-TESTING.md](doc/HARDWARE-TESTING.md)**, under probe B.

### Why the old advice was wrong, which is worth more than the corrected number

This entry told you to power-cycle, on the strength of a probe that had **never asked the question**.
Two things were wrong with the instrument, and either alone was enough to keep the answer out of
reach — though not in the same way, which is the part worth reading twice:

* **The ordering.** Phase 2 lifted the firewall blackhole *before* it waited, so our own kernel
  began RSTing the module's retransmissions the instant the wait started. That does not measure the
  module's patience at all — it measures how fast the module acts on news it has just been handed.
  "Does it give the slot back **unprompted**" was not answered badly here; it was **unaskable**.
* **The horizon.** `--recover` defaults to **20 s**, against a timer of **180**. So even a probe
  that had left the blackhole up would have given up nine times too early.

**Fixing either alone leaves the question unanswered**, and the horizon half is the subtler of the
two: the 2026-08-06 run at the default 20 s **did** come back served, in 71 ms
(`doc/HARDWARE-TESTING.md`). So a longer wait on the lift-first path does not turn a `no` into a
`yes` — it was never returning `no` in the first place. What was missing there was not the answer
but the **interpretation**: with the blackhole down, "served" cannot tell self-heal from told. Both
had to be fixed together, and were — `--no-lift` for the ordering, `--recover 210` for the horizon.

Both are on `main` now, so this is re-runnable:

    sudo test/run-vanished-peer.sh --host <ip> --no-lift --recover 210

**Two lessons, and the second is the one this project keeps paying for.** A negative result from an
instrument whose horizon is shorter than the effect is not a negative result — it is the
instrument's own scale, read back as a finding about the world. And an instrument that **cannot
reach** the state it is pointed at reports a confident `no` that looks exactly like a measurement:
the lift-first ordering was documented, honestly, in the probe's own text the whole time — it said
its recovery meant "the module was **told**" — and nobody noticed that this made the interesting
question unanswerable rather than answered. `ERRORS.md` carries both under other names.

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

**Wait, then reconnect — about five minutes in some cases and about thirty in the worst one.** That
is the whole procedure, and it is also the diagnosis: a machine that starts serving again was this,
and one that does not is something else.

**Two separate things clear this, and WHICH ONE YOU GET DEPENDS ON WHETHER THE STUB THINKS A DEBUG
SESSION IS STILL OPEN:**

| what | after | since |
|---|---|---|
| **the stub** sweeps every link id with `AT+CIPCLOSE`, once it has been idle with **no DZRP session it knows of** | **~5 min** | build `00.18`, issue #24 |
| **the module** reaps each idle inbound connection itself, on `AT+CIPSTO` | **~30 min** | the value the stub sets at bring-up, issue #24 |

**AND THE HEADLINE CASE OF THIS ENTRY IS THE ONE THE STUB'S FIVE MINUTES DOES NOT REACH**, which is
worth stating plainly because it is the opposite of what "whichever is shorter" would suggest. The
stub only counts while `esp_session_valid` is clear, and that byte is set by `CMD_INIT` and cleared
by exactly two things: a `CMD_CLOSE`, or the module reporting `<id>,CLOSED` for **that** session's
own connection. A peer that **vanishes** sends neither — no FIN, no RST, no `CMD_CLOSE` — so if the
connection that vanished is the one that most recently sent `CMD_INIT`, the stub goes on believing a
session is open, never counts a tick, and never sweeps. The wait is then the module's ~30 minutes,
and only if the module announces its reap as an `<id>,CLOSED` at all — which nobody has checked (see
"What is not known").

**That is not a defect and must not be fixed by weakening the guard.** Sweeping while a session
looks open is "close on suspicion", which is the thing this entry's "why this is not fixed" section
refuses: a DeZog session parked at a breakpoint is silent for minutes and perfectly healthy.

**So the stub's five minutes helps the cases where the vanished sockets are not the tracked
session** — peers that connected and never sent `CMD_INIT`, and peers superseded by a later session
that ended cleanly. Those are real and they are what S4-S7 stage.

**On an older build there is no stub-side sweep at all and the wait is the module's alone**, which
is ~3 minutes before `AT+CIPSTO=1800` shipped and ~30 after it. And `AT+CIPSTO` is settable: **`0`
disables the module's half entirely**, on which module only the stub's five minutes remain, in the
cases it reaches — and before `00.18`, nothing at all did, which is when the old power-cycle advice
was right. `AT+CIPSTO?` at the machine is what settles which you have.

**Do not power-cycle**, which this entry used to tell you to do. It works, but it costs you the
debuggee, the machine's state and — if you were about to report anything — the only evidence there
was.

**While you are waiting, photograph the screen and try the `B` key.** Waiting tells you the same
thing eventually, but the keys tell you *now* and give you something to put in a report — and unlike
the old advice this evidence now costs nothing to collect, because you are standing there anyway.

A Symbol Shift + NMI re-init does **not** shorten it — it calls `transport_init` directly and never
runs the sweep, and `AT+CIPSERVER=1` is refused while a listener is already up, so the re-init fails
at its own AT chain and paints "ESP-01 setup failed" over a module that was going to recover anyway.

### What is not known

**The rate.** Nothing measures how often a peer vanishes this way in the field. The five leaks are
**not independent events** — one persistent cause, a flaky link, a router that reboots nightly, a
habitually suspended laptop, can strand several.

**But the window they must fall into is now known, and it is small.** Five leaks have to land within
one timeout of each other, because the oldest is reaped while the later ones are still
arriving. **That window is ~3 minutes before `00.14` and ~30 after it, so #24 made this
coincidence EASIER to hit, not harder** — the honest direction, and the opposite of what the
rest of this paragraph's reassurance would suggest if the number were left at three.

**By how much is deliberately not quantified.** The window is ten times wider; the *coincidence* is
five independent rare events landing inside it, which does not scale linearly with its width, and
the underlying rate has never been measured. "Ten times easier" was in an earlier draft of this
sentence and is arithmetic dressed as a finding — the direction is what is established. This entry used to say they accumulate "between two power-ons" — a window of days on a
machine left running, which was the whole force of the worry. Narrowing the window is not measuring
the rate, and the rate is still unmeasured; it does move the required coincidence a long way.

**Whether 180 s is the number on every module.** `AT+CIPSTO` is settable, its range is 0-7200, and
**`0` disables the timeout altogether** — on a module somebody had set that way, the old advice in
this entry would be correct again. The reading here is from one Ai-Thinker ESP-01,
`AT version:1.2.0.0`.

**Whether the module announces the reap.** Nobody has looked for an `<id>,CLOSED` at the moment it
frees one. If it emits one, the stub could in principle see this happen; issue #23's session line
would also be affected. Unmeasured, and stated here so it is not assumed either way.

### What would reopen it

Connections refused, screen clean, and **still refused an hour after the last traffic**, with no
power cycle since boot.

**AN HOUR, AND IT IS BUILT ON THE MODULE'S THIRTY MINUTES RATHER THAN THE STUB'S FIVE** — because
the stub's five is exactly what the headline case does not get. Since build `00.18` two things can
clear this, but they do not both apply to every instance:

- the **stub** sweeps the link ids after **five minutes** idle (issue #24, `ESP_IDLE_SWEEP_SECS`) —
  but only while it believes no DZRP session is open, so a vanished peer that was the tracked
  session suppresses it entirely (see "What to do");
- the **module** reaps on its own `AT+CIPSTO` after **thirty**, and that one has no such condition.

So the criterion has to be built on the timer that always applies, doubled for margin. **A criterion
built on the stub's five minutes would fire on ordinary, correct behaviour** every time the vanished
peer happened to be the one holding the session — which is the common shape, not an exotic one.

**The "still refused" clause is the load-bearing one.** A Next that refuses everybody and then
recovers is #19 doing exactly what it is now measured to do, and is not worth reopening anything
for. A refusal that **outlasts the module's timer** is the finding: either five peers really went
quiet inside one window, or something is holding slots that idling does not free — and the second is
a different fault wearing this one's face.

**If it recovers between five and thirty minutes, that is informative and not a fault**: it says the
stub's own sweep ran, i.e. it did not think a session was open. Worth noting in a report, because
nothing here has ever observed that sweep repair a real leak — see "What already shipped".

**`make probe-slots` cannot settle it in that state** and it is important not to expect it to: its
discriminating check asks whether an *earlier* connection still answers, and a module with every
slot leaked has no earlier connection to ask. The tool says so itself.

**Two different questions, two different discriminators, and they are not alternatives.** *Is the
stub alive, or wedged?* — the **machine's own screen**: a live stub draws cleanly and answers its
keys. *Is this #19, or something new?* — the **clock**: #19 recovers when the timer runs, and
anything still refusing long afterwards is not #19 however clean the screen looks.

### Why this is not fixed

**The stub cannot DETECT this in time to act, and that part is solid.** A vanished peer sent no FIN
and no RST, so the module still believes the connection is open and the stub is told nothing at all.
Every application-layer signal it might lean on is unavailable or wrong: no `<id>,CLOSED` arrives
**at the moment the peer goes**, which is the only moment at which knowing would help; DZRP has no
keepalive; and **idleness cannot be the trigger**, because a DeZog session stopped at a breakpoint
while somebody reads code is silent for minutes and perfectly healthy — which is exactly why issue
#16's idle wait is deliberately not counted as a fault.

*(That said "`<id>,CLOSED` never arrives for a peer that vanished", flatly, which does not survive
the `AT+CIPSTO` finding: the module may well emit one when it **reaps** the connection, one timeout
later. Nobody has looked — it is in "what is not known" above. Either way the detection argument
holds, because a signal that arrives at the same time as the cure is not a signal you could have
acted on.)*

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
  and whether a server-accepted inbound link can be given one is unverified.

**THE SECOND BULLET HAS BEEN OVERTAKEN, AND BY THE THING THAT ENDS THIS FAULT.** It went on to wish
for a module-side liveness mechanism — *"if it exists, the module's own stack would decide liveness
and the stub would need no guesswork at all"* — and asked for the real firmware or its documentation
to settle it, since no bench here could. The module was asked, on 2026-08-08, and the answer is
**`AT+CIPSTO`**: a server-side idle timeout that applies to exactly these inbound links, on by
default at 180 s, enforced. That is the mechanism the bullet hoped for, already present and already
doing the job — which is why this entry now ends in a wait rather than a power cycle.

Neither of the stub-side mechanisms has been scoped, and the decision is to leave both unscoped.
That decision is on **firmer ground than when it was made**: it declines to spend Z80 bytes and
multi-client behaviour on a fault that resolves itself unaided, where before it was
declining to fix one that needed the power switch. The cost side is unchanged and the benefit side
shrank sharply.

**THAT ARGUMENT IS WEAKER THAN WHEN IT WAS WRITTEN, AND SAYING SO IS THE POINT OF THIS PARAGRAPH.**
It was made when the self-heal was ~3 minutes; issue #24 stretched it to ~30. So the benefit of a
stub-side fix is roughly ten times larger than it was on the day the decision was taken, and the
window in which five leaks must coincide is ten times wider too. **The decision still stands** — half
an hour is a rare fault clearing itself, against Z80 bytes and the multi-client behaviour W4/W5
depend on — but it stands with less margin, and a report of this actually biting somebody would be
enough to reopen it where before it would not have been.

**ONE OF THEM WAS SCOPED AFTER ALL, AND IT IS NEITHER OF THOSE TWO — issue #24, build `00.18`.**
The first bullet was examined and **cannot be built as written**: `test/dzrp/queued-commands.py`
opens **three** simultaneous connections and INITs every one, `split-command.py` holds **two** across
its exchange and hardware H3 two — so a sweep fired by any `<id>,CONNECT` closes the earlier ones and
bench checks W4, W5 and H3 all go red, and it still could not reach the terminal state, exactly as
the bullet says. A **periodic**
trigger can: the terminal state leaves the stub sitting in `main_loop` with nothing able to reach
it, which is the one place a timer still runs.

So `esp_idle_tick` sweeps once when the stub has been idle `ESP_IDLE_SWEEP_SECS` (300) with **no
DZRP session and nothing arriving**. The session guard is what keeps it clear of the rule three
paragraphs up — with no session there is nothing to close on suspicion *of* — and "once per idle
period" is what stops a machine left switched on opening a refusal window every five minutes.
Bench checks S4-S7 in `make test-slot-recovery`, with `IDLE_SWEEP=0` as the control.

**It does not change what this entry tells a user to do**, and it changes less than it looks like it
should. The wait is still the answer: the stub's period is five minutes and the module's is thirty,
and waiting is what ends it either way.

**BUT THE SESSION GUARD IS ALSO WHAT KEEPS THE NEW SWEEP AWAY FROM THIS ENTRY'S OWN HEADLINE CASE**,
and that is the honest reading of what shipped. `esp_session_valid` is set by `CMD_INIT` and cleared
only by `CMD_CLOSE` or by the module reporting `<id>,CLOSED` for that same session. A peer that
vanishes sends none of those — so when the vanished connection *is* the tracked session, the stub
never counts a tick and this trigger never fires. What it reaches is the rest: sockets that never
opened a session, and ones superseded by a later session that closed cleanly.

That is a guard doing its job rather than a gap to close — sweeping while a session looks open is
the "close on suspicion" this entry refuses — but it means the five minutes is **not** a general
replacement for the module's thirty, and "What to do" and "What would reopen it" are both written
against the thirty for that reason.

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

**Closing the gap from the stub's side needed a sweep reachable from a quiet stub — periodic, or at
connect time — and build `00.18` shipped the periodic one** (issue #24; connect time was examined
and cannot be built, see above). `esp_idle_tick` calls the same sweep after five minutes of idling
with no session.

**IT DOES NOT REPLACE THE MODULE'S THIRTY MINUTES, AND THIS SENTENCE USED TO SAY IT DID.** The sweep
only counts while the stub believes no DZRP session is open, and a peer that vanishes never clears
that belief — so for **this entry's own headline case** the trigger does not fire at all, and the
module's `AT+CIPSTO` remains the thing that ends the fault. What the trigger reaches is the other
shapes: sockets that never sent `CMD_INIT`, and ones superseded by a later session that closed
cleanly. "What to do" and "What would reopen it" are both written against the module's thirty for
exactly this reason, and neither should be re-derived from the five.

**That does not retire this entry and must not be read as doing so.** What ships is a **trigger**
for a mechanism whose repair value no run anywhere has demonstrated: no emulator can leak a slot to
a peer that vanished, so S4-S7 show the sweep fires from a quiet stub and nothing more — and
because a vanished peer is precisely what they cannot stage, **no bench here exercises the trigger
in the state this entry is about**. Whether a real module hands the slots back when asked in this
state is unmeasured, and the wait remains the advice above.

### The one thing that made this worse, deliberately — and it has SHIPPED

**Issue [#24](https://github.com/jorgegv/dezogif_ng/issues/24) sets `AT+CIPSTO=1800` at bring-up,
and has done since build `00.14`** — this section described it in the future tense for two builds
after it landed, which is what issue #34 was filed to fix. It stretches the self-heal above from
about **3 minutes to about 30**, so every figure in this entry is the second column below unless you
are on an older ROM. It is the same timer read from both ends, and the trade is measured on both
halves rather than argued:

| | at the default 180 s | at #24's 1800 s |
|---|---|---|
| an **idle debug session** — stopped at a breakpoint while somebody reads code | **dropped after 3 minutes**, which is the fault a user actually meets | survives 30 minutes |
| this entry's **vanished-peer exhaustion** | clears itself in ~3 minutes | clears itself in ~30 minutes |

The first row is why #24 is being built: a debugger that hangs up on you for thinking is a real,
frequent, unambiguous fault, and #16's idle wait is deliberately not counted as one for exactly that
reason. The second row is this entry's, and it is the price. Both are rare-versus-common in the same
direction, which is what makes the trade an easy one — but it does mean **the "wait three minutes"
advice above becomes "wait thirty" on a build carrying #24**, and the reopen criterion scales with
it. Check what the module is actually set to before concluding anything from a long refusal.
