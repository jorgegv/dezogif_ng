# Testing on real hardware

    make test-hardware NEXT_IP=192.168.1.42

**It runs on a real ZX Spectrum Next, and as of build 000A every check here passes.** The stub
takes the M1 NMI, brings the ESP-01 up as a TCP server, answers **12 of 12 DZRP conformance
checks on hardware** — including resuming a debuggee — and survives a command arriving while it is
answering another, which is the one thing it demonstrably could not do this morning. The results
are at the bottom of this page, with the numbers.

**That "12" is the count the suite had on the day, and it has grown since**: C13/C14 (issue #9) and
C15 (`CMD_CLOSE`) were added afterwards, so H2 delegated **15** checks — and **the full 15
passed on a real Next: 15 of 15, 2026-08-08 12:37**, recorded under *"The suite at its
full size"* — named rather than counted, because dated sections keep being appended and "the second
table at the bottom" has already gone stale once.

**IT IS 18 SINCE C16-C18 LANDED, AND ALL 18 HAVE NOW PASSED ON A REAL NEXT — 2026-08-09, build
`00.19`, the whole bench 6 of 6.** That run also produced this project's **only red-first pair taken
on silicon**: see *"C18, and the Next we destroyed to earn its green"* below. Read every conformance total on this page as a record of the run that produced
it, not as the size of the suite today — `python3 test/dzrp/conformance.py --help` lists
what it actually carries.

This page is the procedure for repeating that, and `test/hardware-check.py` is the part a PC can
do by itself. Read it end to end before starting: much of it is about what to *observe*, because
a good deal of what hardware can tell us is not reachable over a socket.

**Why it is worth running even when everything is green.** Two evenings of hardware testing have
produced two bugs, and **neither was findable here** — both because jnext's values sit on the safe
side of ours. A connection id of 0 that the stub read as "no client" and a 15-character IP address
its parser refused. Every emulator check stayed green through both. Anything that depends on a
value the emulator holds fixed is untested until this page is run.

## Why an emulator result is not enough

jnext is good enough that the stub was developed entirely against it. Three of its divergences are
known, and all three are in the exact area the WiFi build depends on:

| Divergence | Consequence |
|---|---|
| It models **baud as timing only** | The stub's 115200 would have passed at *any* rate. That the real ESP-01 answers at 115200 until told otherwise is filed in the plan's Appendix A as **inferred**, not verified |
| Its ESP module is **permanently associated** — jnext implements no `AT+CWJAP=` at all, only the query form | Association has never been exercised by any test and never can be. It is a prerequisite the user satisfies once; see [WIFI-SETUP.md](WIFI-SETUP.md) |
| It numbers inbound connection ids **from 1**, because it reserves slot 0 for outbound `AT+CIPSTART` | That is a **jnext design choice**, and MEMORY.md said outright that hardware may number differently. It does: **real firmware assigned the first client id 0**, measured 2026-08-04 by the WiFi build failing completely on a Next. The stub had used `esp_conn_id == 0` as its "no client" marker, so every reply was discarded — see ERRORS.md and H3 below. Fixed by reserving no id at all. **No emulator check can cover this in either direction**, because jnext never issues 0 |

Two more claims were **estimates** — arithmetic, never measured. H4 and H5 replaced them with
numbers on 2026-08-05; see the results table at the end.

## Prerequisites

1. A ZX Spectrum Next with **core ≥ 03.01.10** (stackless NMI; the stub refuses below it) and the
   **Multiface enabled** in the machine configuration.
2. The Next **already on WiFi**. The stub never configures WiFi and holds no credentials — it only
   verifies. Do this once with `/apps/wifi/setup/wifi2.bas`; see [WIFI-SETUP.md](WIFI-SETUP.md).
3. A **backup of the stock `machines/next/enNextMf.rom`** taken before anything is overwritten.
4. The PC on the **same network** as the Next.

## Step 1 — build and install the WiFi ROM

    make TRANSPORT=wifi mf-rom          # build/enNextMf-wifi.rom

Copy it to the card as `machines/next/enNextMf.rom`, keeping the backup from prerequisite 3.

**It must be the WiFi build.** Installing the UART one produces a machine that boots, takes the
NMI, paints its UI and then listens on nothing — and the failure looks like a transport bug rather
than the wrong file. Check the identity block before copying:

    dd if=build/enNextMf-wifi.rom bs=1 skip=8160 count=19 2>/dev/null; echo

must print `DeZoGiFnG_WIFI_nnnn`. That string is at a fixed offset which is a permanent contract
(ROM file offset `0x1FE0`); match the prefix and the variant, **never** the build number.

## Step 2 — find the Next's IP address

**The stub shows it.** Bring it up (step 3) and read the address off the Next's own screen:

```
Remote debugger ACTIVE
Connect at 192.168.1.42:11000
```

That is exactly what goes in `launch.json`. If instead it says `No WiFi address` or
`ESP-01 setup failed`, the fault is upstream of the debugger and step 3's observations say what to
do about it — do not go looking for the address elsewhere and carry on, because the stub is telling
you a client will not be able to reach it either.

**The address on that screen is correct on real hardware** — confirmed by the user, 2026-08-05,
on a Next whose address is `192.168.100.136`. That is **reported on hardware** on Appendix A's
ladder: first-hand and load-bearing, one machine, one reporter, no artefact anyone can re-run.

It closes more than it looks. That address is **15 characters**, which is exactly the length the
connect-string parser used to refuse — its loop bounded DJNZ *passes*, so a maximum-length address
fell out to "too long" before the closing quote was read, and the screen would have said
`No WiFi address` on a perfectly configured machine. jnext's module always answers
`192.168.1.50`, twelve characters, so no check here could ever reach the boundary; it is covered
only by moving the *bound* instead (`make test-ip-boundary`). This confirmation is the first time
the real path has run at its real length on silicon.

**A green bench run would not have closed it**, which is why it was worth asking for. `AT+CIFSR` is
the last step of `transport_init` and the only bring-up step whose failure still leaves a working
listener — so H1 and the whole conformance suite can pass while the screen reads `No WiFi address`.
The socket path and the display path diverge there, and only one of them is machine-checkable.

`wifi2.bas` on the Next and the router's lease table remain the second opinions if the line ever
disagrees with what you expect.

A **static DHCP reservation** on the router is worth the two minutes: the address then never moves.

## Step 3 — bring the stub up

Power on, let NextZXOS boot, then **press the NMI button once — the Multiface one, NOT DRIVE**.

**Which button, since this document calls it "M1" and your case almost certainly does not.** "M1"
is the FPGA's name for the signal, not a label: `zxnext.vhd:2090` reads
`nmi_assert_mf <= '1' when (hotkey_m1 = '1' or nmi_sw_gen_mf = '1') and nr_06_button_m1_nmi_en`,
and NR `0x06` **bit 3** is `nr_06_button_m1_nmi_en`. The line below it is the other one:
`hotkey_drive` → `nmi_assert_divmmc`, gated by NR `0x06` **bit 4** — that is **DRIVE**, the DivMMC
NMI, and it brings up the esxdos browser, not this stub. So of the three buttons — RESET, DRIVE and
NMI — it is the third. In an emulator the same two are **F9** (Multiface) and **F10** (DivMMC),
`zxnext.vhd:6348-6349`.

If the stub's UI appears, you pressed the right one: nothing else on the machine draws that screen.

Record what happens on screen. **S1-S4 the bench can now read for itself** (see below the table);
**S5 it cannot**, and at this point in the procedure nothing is listening yet, so all five are
yours to observe here:

| # | Observation | Why it matters |
|---|---|---|
| **S1** | Does the stub's UI appear at all? | The first hardware evidence that Multiface paging, the relocation of `MAIN` into a RAM bank at slot 7, and `show_ui` work on silicon. In the emulator this is bench T6 |
| **S2** | What does `Core:` read? | The stub compares it against 03.01.10 and raises `ERROR_CORE_VERSION_NOT_SUPPORTED` below that |
| **S3** | Is the **error area** (bottom 9 rows, red on black) clear? | `RX Timeout` there means the AT chain failed — that is still the message, because bring-up failure has no error code of its own. `No WiFi address` means the chain worked and the module has no address to give out |
| **S4** | What do rows 6 and 7 say? | The status block, and the one thing on this screen composed at run time. `Connect at <ip>:11000` is the success case; `No WiFi address...` and `ESP-01 setup failed...` are the two failures, each in words rather than a code. **Confirmed correct on hardware 2026-08-05** at a 15-character address — the length the parser used to refuse, and one jnext can never produce. A green bench run does not cover this: `AT+CIFSR` failing leaves a working listener, so every check can pass while this line reads `No WiFi address` |
| **S5** | Does the machine return to a usable NextZXOS? | The ESP holds the listening socket, so the listener should survive normal use of the machine |

**S1-S4 CAN NOW BE READ FROM THE PC, and S5 cannot.** Once the listener is up,

    make read-screen NEXT_IP=192.168.1.42

fetches the display file with `CMD_READ_MEM 0x4000,6912` and prints every row —
so `Core:`, the status block and the error area come back as **text** rather than as a
photograph somebody has to interpret. See `test/dzrp/screen.py`. Two properties of it matter here:

- **It sends no `CMD_INIT`**, because `cmd_init` does `xor a` / `ld (last_error),a` and then
  repaints — a reader that introduced itself would wipe the very error it was run to read. A bare
  `CMD_READ_MEM` is answered: `cmd_loop` dispatches through `cmd_call` with no session gate.
- **`RX Timeout` in the error area can simply be a client hanging up** — measured against jnext, a
  second after a clean close, and by design (issue #16). Not unconditionally: probe A reads clean
  after its own closes. It is *also* what a failed AT chain shows, so it is only benign in context.

**Photograph the screen anyway.** It is still the only artefact of **S5**, and of the **border**,
which is not in the display file and which no `CMD_READ_MEM` can ever reach.

## Step 4 — run the bench from the PC

    make test-hardware NEXT_IP=192.168.1.42

| Check | What it asserts |
|---|---|
| **H1** | Something is listening on `<ip>:11000` |
| **H2** | DZRP conformance — delegated to `conformance.py`, not reimplemented. **Its coverage is the suite's**, which now includes C10/C11, the resume checks — so a passing H2 means a debuggee was resumed on whatever this was pointed at |
| **H3** | The `+IPD` connection id is **read from the header**, not assumed. **Red on hardware for eight hours on 2026-08-05, for a reason that was not the id** — it failed back-to-back and succeeded with a 1s pause, so it discriminated its own cause. Green since build 000A; see below and issue #11 |
| **H4** | Round-trip latency, **measured** |
| **H5** | Throughput, **measured** |

### H1 carries far more than its one line of code

A completed TCP handshake proves, in one observation: that tbblue loaded our ROM (which answers the
plan's open question 2 — whether the firmware checksums it — with "no"); that the M1 NMI was taken
and `nmi66h` accepted the cause; that `MAIN` is executing from slot 7; that the core check passed;
that UART0 came up at a rate the real module answers at; and that `ATE0`, `AT+CIPMUX=1` and
`AT+CIPSERVER=1,11000` were all accepted. Every one of those is inherited from emulator runs today.

**If H1 fails, the bench runs nothing else and says so.** Four SKIPs are not four findings, they
are one. Work through: is the *WiFi* ROM installed; was M1 pressed since power-on; is the Next
associated; is the IP right; has something else on the machine taken the ESP.

### H3 was RED on hardware, and is now GREEN — the whole bench passes

**Build 000A, 2026-08-05: 3 passed, 0 failed, 2 measured of 5.** The first fully green run of this
bench in the project's history, and the section below is kept as it stood — the diagnosis, the two
wrong hypotheses it corrected and the measurements it rests on — because how it was found is worth
more than the fact that it is fixed.

The fix is issue #11: no scan in `transport_esp.asm` may discard an inbound `+IPD`; one is now
held and served as the next command. **Confirmed here in 3 runs of 3, which is the symmetric
answer to the 3 failures of 3 that opened it.** The same runs say the fix costs nothing
measurable: median round trip 11.3 / 11.4 / 11.5 ms against 11.5 ms before it, and throughput
6.1 / 7.1 / 8.2 KB/s against 8.3 — the top of that spread matching the pre-fix figure, so the low
one is this link's ordinary variation and not a price. Expected, since the work added is one
compare per byte on the *scan* paths and none at all on payload reads.

**The half a bench cannot confirm, and it is the one this section is about.** jnext reproduces the
`AT+CIPSEND` prompt window (check W4) and cannot reach the `SEND OK` window at all, because it
answers instantly. So until these runs, the fix was proven against the *other* window of the same
defect and unproven on the machine that found this one. That gap is now closed by measurement
rather than by argument.

#### What it was, and how it was pinned down

Since 2026-08-05 (build 0008) H3 failed on a real Next, reproducibly. **It was not the connection
id**, and the check says so itself in a single run.

It tries the two exchanges back to back; on failure it reopens and retries with a **1-second
pause**, then reports which of three things it found. On hardware, 3 runs of 3:

    connection 2 got no usable reply ... connection 1 had nothing unread ...
    BUT THE SAME EXCHANGE SUCCEEDS WITH A 1.0s PAUSE before it.

**So it is a timing window.** `esp_flush_chunk` sends the reply and then waits for the module's
`SEND OK`; `esp_wait_string` discards every byte that is not part of the pattern it scans for. A
`+IPD` arriving in that window is destroyed — no error, nothing sent, and the other connection
holding nothing. The race is easy to lose because the module forwards the reply **to the client**
before it tells the **stub** `SEND OK`, so the client can answer while the stub is still scanning.

**Two things measured on 2026-08-05 correct what this section used to say**, and both came from a
sweep the bench does not do:

- **One connection never loses a command**, at any delay from 0 to 250 ms, 3 trials each. So *"a
  single pipelining client would hit it too"* is **not supported** for the send-after-reply shape.
  The discriminator is the *other connection*, not the timing alone — most likely the module holds
  inbound data for the link it is currently sending on and releases data on other links at once.
  That last clause is a reading, not a measurement.
- **The window is 20-50 ms wide** (fails at 0/2/5/10/20 ms, clean at 50/100/250 ms), where a
  nine-character `SEND OK` costs about 2 ms at 115200. Worth knowing before any timeout is sized
  against it.

**H3 reported FAIL for as long as a Next had not said otherwise**, which was the right answer for
the eight hours it took: a check that went green on the strength of an emulator run against a
*different* window of the same bug would have been exactly the over-reading this document exists to
prevent. Issue #11 keeps its four disproven hypotheses on purpose — each was plausible, and two
were killed by nothing more than reading the Next's screen.

### H3, and precisely what it does and does not establish

**What a green H3 means.** Its line reads exactly

    H3   PASS  two simultaneous connections each got their own payload back

and stops there, because that is the *result*. What it **means** is the sentence that used to be
bolted onto the end of it: **the `+IPD` connection id is read from the header, not assumed.** Two
connections are the only way to see that — with one, a stub that hardcoded whatever id it happened
to be given would pass — and that is the whole of why the check opens two.

Its **failure** line is the one place in this bench that runs past the one-sentence budget, and
deliberately: see the note at the call site in `test/hardware-check.py`. It joins three facts, and
it is the combination that discriminates.

Two connections open at once, each given its own payload, each required to get *its own* payload
back. With one connection a stub that ignored the header and hardcoded an id would pass — this is
bench check E4's shape, and E4 earned its place by being the only check that failed when the id was
hardcoded to 1. Verified the same way here: hardcoding the id in `transport_esp.asm` turns H3 red.

A wrong id does not produce an error. It produces a reply delivered to the wrong socket: no error,
no data, and something that reads as a DZRP bug rather than a framing one.

**It does NOT measure the module's id numbering, and no PC-side check can.** H3 shows the id is
read from the header rather than assumed — a property of our code. What the ids actually *are* is
invisible from here: the `+IPD` headers are consumed by the stub, and what reaches the PC is DZRP
frames with the id already stripped. So MEMORY.md's open question — whether real ESP-AT firmware
numbers inbound connections from 1 the way jnext does — **survives a green run of this bench**.
Settling it needs the ids observed on the Next side, which this bench has no channel for.

**That question is now SETTLED, and not by this bench: real firmware numbers from 0.** The first
hardware run answered it by failing. H1 passed, the client connected, commands were executed, and
every reply was discarded — because `transport_flush` used `esp_conn_id == 0` as its "no client"
marker and the module had assigned the client id **0**. See ERRORS.md. The fix reserves no id at
all: validity moved to its own flag (`esp_conn_valid`) and the id became opaque data.

Two things follow for reading this bench. First, the paragraph above is still right about what H3
*can see* — the numbering was learned from a total failure, not from a green run, and a green run
would still not reveal it. Second, **no emulator check covers this**, in either direction: jnext
never issues id 0, so `make test-dzrp-stub` was green while the bug made hardware unusable, and it
is green now. On this specific question the hardware bench is not the strongest evidence, it is the
*only* evidence.

The first version of this page claimed H3 would move that row to `verified`, in two separate
places. It would not have, and the review caught it.

### `[NOT CLEAN: n connect retries]` is a finding, not noise

Getting connected is allowed one retry, because the stub's own RX budget is about 100 ms
(`ESP_RX_WAIT`) against a WiFi round trip nobody has measured, so a single jitter spike makes the
*stub* reset and drop an exchange. That is a transient worth riding out.

**It is not worth hiding.** A transport that needed a retry is not the same machine as one that
answered first time, and everything downstream of the retry succeeds — so without this note an
intermittent link reads as spotless. If you see it, the run is evidence of flakiness even where
every check is green, and it is worth recording alongside the numbers.

### H2 may be red for a reason that is not the hardware's fault

The bench carries a table of checks already known to fail against our own stub **in the emulator**,
so that nobody at a bench-top spends an evening debugging their WiFi over a defect that reproduces
on a machine with no WiFi in it. It **labels** those rather than suppressing them: the check still
fails and the exit code is still non-zero, but the summary says in as many words that the run found
nothing wrong with the hardware. Never "fix" a listed red by weakening the check.

**The table is empty today**, and that is a result rather than an omission: its one entry was `C2`,
[issue #7](https://github.com/jorgegv/dezogif_ng/issues/7) — `cmd_init` ignoring the frame's length
field in `src/commands.asm`, which is common to both builds and which the serial ROM had always
done. It landed, so C2 goes green on its own and the entry went with it.

So every failure here is now new on this remote, and is the part worth investigating.

## Step 4b — the module probes (optional, and NOT part of the bench)

    make probe-jnext                             # FIRST. Always. See below
    make probe-slots      NEXT_IP=192.168.1.42   # probe A
    make probe-vanished   NEXT_IP=192.168.1.42   # probe B — needs sudo
    make probe-idle-drop  NEXT_IP=192.168.1.42 \
         PROBE_ARGS="--expect-timeout 1800 --deadline 400"    # probe C

These are **instruments, not gates**. They print numbers and observations and render no verdict,
they are not part of `make test`, and **none of them can close
[issue #15](https://github.com/jorgegv/dezogif_ng/issues/15) on its own.** Nobody has reproduced
that wedge deliberately; A and B's job is to make a positive reproduction possible.

**Probe C is here for the family rather than for #15.** Its subject is the module's own idle
timeout, which is what *bounds* #19's slot leak — at about three minutes on the firmware default, and at about **thirty** since
[issue #24](https://github.com/jorgegv/dezogif_ng/issues/24) lengthened deliberately — it is in the
shipped ROM as of build 00.14. It is also the only way, from the PC, to show that the value the
stub sends is the value a real module then obeys.

### The hypothesis they test

Issue #15's signature has two halves and only one is explained. The CRLF `SEND OK` swallow band
fixed in build 000E accounts for the `RX Timeout`, the frozen border and the hung client — but a
swallowed command is **transient**, so it accounts for neither the **power cycle** nor the **TCP
accept latency measured degrading 83 ms → 389 ms → timeout** while it was happening. That
degradation is on the **module's** side of the UART: the Z80 does not accept TCP connections and
cannot make one slow.

[Issue #19](https://github.com/jorgegv/dezogif_ng/issues/19) says the module holds a small number of
inbound connections, drops anything past them, and that **nothing in the stub ever freed one** —
`AT+CIPCLOSE=<id>` is the fix, and it was unwritten because jnext could not model it (jnext#211).
A power cycle was believed to be the only thing in the system that reclaimed a slot. That fits the
unexplained half exactly: stub healthy, screen intact, TCP degrading then refusing, recoverable only
by pulling the plug.

**#19 IS PARTLY FIXED AND CLOSED AS WONTFIX, AND IT DOES NOT RETIRE THESE PROBES.**
jnext#211 shipped `AT+CIPCLOSE=<id>`, and `esp_recover` sweeps every link id with it
(`make test-slot-recovery`, 3 checks, green in the emulator). What that reclaims a slot on is a
**recovery**, which needs `ESP_FAULT_LIMIT` **consecutive faults** — so a peer that goes away
without ever making the stub fail a read still holds its slot for as long as the module lets it. The
probes' subject is that residue, and it is exactly the case probe B stages.

**AND THE "ONLY THING" CLAUSE ABOVE IS FALSE, MEASURED 2026-08-08 — WHICH CUTS AGAINST THIS
HYPOTHESIS RATHER THAN FOR IT.** The module reclaims an idle inbound slot by itself at `AT+CIPSTO`,
default **180 s**, enforced (see the 2026-08-08 run below). So a #19 exhaustion is **self-healing** — in
about three minutes then, and about thirty on any build from `00.14`, which sets the timer itself —
and #15 was two wedges that were not — the user power-cycled both times. That
does not refute "#15 IS #19", because nobody recorded how long they waited before reaching for the
switch, and three minutes of a dead debugger is longer than most people's patience. But it is the
first evidence that points *away*, and it gives the hypothesis something new to answer: a #19
exhaustion should have cleared on its own, and #15 is on the record as not having.

**So the hypothesis is that #15 IS #19**, and these probes measure what it rests on. Read the
paragraph two above as the state a Next built before #19's fix is in, and the "only thing" clause as
what this page believed until 2026-08-08.

**#15 WAS CLOSED WITHOUT DEMONSTRATING THAT LINK** — by the user on 2026-08-06, before probe B had
ever run. The probes and their readings stay because the hypothesis was never refuted either, and
because what they measure — the module's ceiling, and what it costs to strand a peer — is the same
whatever the label. See "Issue #19's residual" below for what is and is not known about how often
it can happen.

What does *not* contradict it: #15's own E-C control, 12 rounds of connect + abortive RST on build
000B, found accept latency flat at 4-12 ms and no leak. **An RST frees the slot**, and so does a
FIN. The leak needs a peer that goes away with **neither** — which is probe B's whole mechanism.

### Probe A — the slot-ceiling probe (`make probe-slots`, no root)

Opens connections **one at a time and holds them open**, each given a `CMD_INIT`, with **no
retries**: a connection that needed three goes is the signal, not noise to smooth away. It reports
per connection whether it was `SERVED`, `DROPPED` (accepted at TCP and then hung up on — what a
module out of slots looks like), `SILENT` (open, no reply — what a wedged *stub* looks like) or
`REFUSED`. Then it closes everything cleanly and reopens, to see whether a clean close gives a slot
back. It ends by reporting the accept-latency **trend**, first to last, because #15's number was a
trend and a median would have averaged it away.

**The line that earns the probe is `A1`.** At the first connection that is not served it asks the
**earliest still-open** connection whether it still answers. "The fifth client got nothing" has two
completely different causes — the module is full (the stub is healthy and still serving the
connections it has) or the stub is wedged (nobody is served) — and they are indistinguishable from
the client that got nothing, which is exactly the position #15 was reported from. One extra
exchange separates them.

**What it cannot do**: it cannot see connection ids, so it measures *how many* slots there are and
never *which*; every connection it opens is closed cleanly, and a clean close is measured not to
leak, so it cannot produce a leaked slot at all; and finding a ceiling proves a ceiling exists, not
that a ceiling is what a user hit.

### Probe B — the vanished-peer probe (`make probe-vanished`, needs sudo)

Establishes a connection, has it served, then makes the peer **vanish with neither FIN nor RST** so
the module keeps the slot, and asks whether a fresh ordinary client is still served — repeatedly,
until one is not. Finally it lifts the blackhole and asks once more.

**The exact firewall change, which is auditable before you type a password** —
`test/run-vanished-peer.sh --host <ip> --dry-run` prints it and touches nothing:

    iptables -N DEZOGIF_PROBE
    iptables -I OUTPUT 1 -j DEZOGIF_PROBE
    iptables -A DEZOGIF_PROBE -p tcp -d <NEXT_IP> --sport <local-port> --dport 11000 -j DROP

and the teardown, run from an `EXIT` trap armed **before** the chain is created, at startup as
well, and available on its own as `sudo test/run-vanished-peer.sh --clean`:

    iptables -D OUTPUT -j DEZOGIF_PROBE      # unhook FIRST: traffic is normal again
    iptables -F DEZOGIF_PROBE
    iptables -X DEZOGIF_PROBE

`iptables -S` is printed before and after, so the change and its removal are both in the run's own
transcript, and the removal is **verified** — a leftover produces a loud failure naming the exact
commands to paste.

**Two limits of that teardown, both measured rather than argued.** `SIGKILL` cannot be trapped, so
`kill -9` leaves the chain — and it also leaves the **Python probe running**, still adding rules to
the surviving chain until it finishes. It can only ever touch the chain it was given, so nothing
outside is at risk, but after a `kill -9` do **both**:

    sudo pkill -f vanished-peer-probe.py
    sudo test/run-vanished-peer.sh --clean

And `SIGINT` is unavailable in one invocation shape, which is not the documented one: a script
backgrounded by a **non-interactive shell with no job control** (`sh -c './script &'`) is entered
with SIGINT already `SIG_IGN`, and a signal ignored at exec cannot be trapped afterwards — measured
from `/proc/<pid>/status`, `SigIgn: …0006` against `SigCgt: …14000` for SIGTERM. **The firewall is
never left broken by it**: an ignored signal does not kill the process, the run carries on and its
`EXIT` trap still cleans up. What is unavailable is the early abort, not the teardown. Use SIGTERM
from a harness; it is caught in every shape tested.

**Why a dedicated chain rather than a rule in `OUTPUT` directly.** Because cleanup has to be right
when the script dies badly, and this is the shape where it can be. Teardown is three fixed commands
that do not depend on what was added, so a rule the script never recorded cannot survive it; every
deletion is **by specification**, never by index; **unhooking is first and is sufficient on its
own**, so even if the flush and delete both fail the network is already normal and what is left is
an inert, unreferenced chain; and a leftover chain is harmless, where a leftover
`-A OUTPUT … -j DROP` silently blackholes the user's own Next.

**Why each rule is scoped to one source port.** The blackhole must stay up while the measurement
runs — lift it and our own kernel answers the module's retransmissions with a RST, which frees the
slot and destroys the thing being measured. A rule written as "drop everything to the Next's port
11000" would therefore also blackhole the probe's own later connections. Binding each doomed socket
to a known local port is what lets one connection vanish while every other connection to the same
machine keeps working.

**Read phase 2's recovery narrowly.** Lifting the blackhole lets our kernel finally answer the
module: that is news arriving from outside. A fresh client being served afterwards says the slot
comes back once the module is **told**, never that the module heals on its own.

**That sentence is correct and was read too weakly for two days, which is the opposite of the usual
failure here.** It bounds what *this* phase shows; it is not a finding that the module does **not**
heal on its own, and the module in fact does — at `AT+CIPSTO`, measured 2026-08-08 below. Reading a
correctly-stated limitation as an answer is how a probe that **cannot** ask a question comes to look
like one that asked and got `no`. That is why `--no-lift` below exists.

**`--no-lift` asks the other question, and it is the module's own timer.** With that flag phase 2
does **not** take the blackhole down: the DROP rules stay up across the wait, so no FIN, no RST and
no retransmission of ours ever reaches the module about those peers, and a fresh client served
afterwards is the module reclaiming a slot **by itself**. That is what an enforced `AT+CIPSTO` idle
timeout would look like from here. The teardown is unchanged — the same `EXIT` trap removes the same
three things, whatever flags were passed.

    sudo test/run-vanished-peer.sh --host <ip> --no-lift --recover 210

Three limits, all of them in the probe's own output rather than only here. It says nothing unless
the ceiling was really reached in phase 1 — a client served after a walk that never ran out took a
slot that was free the whole time, and **B3 branches on that** rather than announcing a reclaim it
did not see. It cannot say **which** slot came back, since no PC-side check sees connection ids. And
it cannot say **what** freed it: an idle timeout is the hypothesis, the stub's own `esp_recover`
sweep is a second one, and although a vanished peer is traced to raise no fault and so to trigger no
sweep, nothing here observes that it did not.

**`--recover` is measured from a different moment on the two paths, and `B5` is why that matters.**
Peers are made to vanish **one at a time**, so peer 1 has been silent for the whole length of the
walk by the time the last one is abandoned. Under `--no-lift` the wait therefore runs from the
**last** peer going silent, so every peer has had at least `--recover` seconds; on the default path
it still runs from the lift, because there the thing being timed is how long the module takes to act
on news it has just been given. **B5** reports the oldest and newest peer's age at the end of the
walk on **both** paths — a walk that outlasted the module's idle timeout could free a slot *during*
phase 1, and B1 would then report a ceiling nobody observed.

#### RUN ON A REAL NEXT, 2026-08-06 — five vanished peers exhaust the module

The measurement this probe was written for, on the user's Next at build `00.0F`. Until this it was
an inference from jnext's source; it is now a reading from silicon.

**THIS HEADING USED TO READ "a vanished peer's slot is never given back", AND THAT WAS NEVER THIS
RUN'S TO CONCLUDE.** The table below is unedited and every figure in it still stands; what was wrong
was the conclusion. This run **never asked** whether the module gives a slot back on its own —
phase 2 lifted the blackhole *before* waiting, so from that moment our own kernel was RSTing the
module's retransmissions, and B3's 71 ms is the module acting on news it had just been handed. The
question was then structurally unaskable here, and the 20 s wait would have been nine times too
short to answer it anyway. The 2026-08-08 section below asks it properly, and gets `yes`.

| | |
|---|---|
| B0 baseline | an ordinary client served, connect **58 ms** |
| V1-V4 | each peer vanished, a fresh client **still served** — 3, 3, 4, 4 ms |
| **V5** | the fifth peer vanished; a fresh client **never completed the handshake, 10009 ms** |
| B3 | blackhole lifted, 20 s later a fresh client served in **71 ms** |
| B4 | the stub's error area **CLEAN — 0 bright-red pixels** |

**Five vanished peers exhaust the module exactly, and that cross-checks.** Probe A measured the
inbound ceiling on the same machine at **5** (against jnext's 4). Here, four vanished peers are
survivable and the fifth is not — one slot consumed per peer, with nothing *this run could see*
giving one back. `AT+CIPSERVER=0` does not, and before issue #19 nothing in the stub did.

*(That sentence said "consumed **permanently**" until 2026-08-08. It is not permanent: the module
reclaims it on its own idle timer, in about three minutes **at the firmware default that governed
when this was measured**, which is nine times longer than anything here waited. Corrected in place
rather than left standing, because "permanently" is the word the whole power-cycle conclusion was
built on. The timer is ~1800 s on any build from `00.14`, which sets it — so a reader reproducing
this today waits ten times longer.)*

**The terminal symptom is a TIMEOUT, not a refusal** — 10009 ms. Probe A read the same signature at
the ceiling on the same machine earlier the same day (**10002 ms**, 2026-08-06; that run was
recorded in the session handover and not in this tree, which is why the figure is quoted here with
its provenance rather than cited as if it were already written down). jnext cannot produce it: its
module accepts and then RSTs, which arrives as a fast `DROPPED`. And **B4 says the stub was healthy the whole time**: a clean error area
while the module was answering nobody. Module refusing, screen intact, stub fine, recoverable only
from outside — that is issue #15's reported shape, produced deliberately.

**IT DOES NOT SHOW THAT THIS IS WHAT HAPPENED ON 2026-08-05**, and #15 must not be re-argued from
it. What it shows is what a vanished peer **costs**. Nothing here says what made a peer vanish in
the field, and B3's recovery is the module being *told*, not healing.

**THE UNCOMFORTABLE HALF, AND IT IS ABOUT OUR OWN FIX.** Issue #19's sweep runs from
`esp_recover`, which fires after `ESP_FAULT_LIMIT` **consecutive faults**, and `esp_fault_count` is
incremented in exactly one place — `rxtx_error`. In the state measured above, nothing can reach it:
a **new** client never completes the module's handshake (V5), so the stub sees zero bytes and has
nothing to time out; the **leaked peers** are silent by construction; and an **unprompted send** to
a stale id takes `esp_wait_prompt`'s `ERROR` arm to `.no_client`, which returns quietly and raises
no fault. B4's clean error area is the observable half of that.

**So the fix CANNOT rescue this state — not "would probably not", cannot.** The trigger is
structurally unreachable once the module is full of vanished peers. What #19 buys is a reclaim on
the way INTO trouble, while the transport is still failing loudly; it is not a general reclaim. That
is a real limit, it was traced rather than assumed, and it is written here rather than left for
somebody to discover. Closing it needs a trigger reachable from a quiet stub — a periodic or
connect-time sweep — which is not issue #19.

**What has changed since is the CONSEQUENCE of that limit, not the limit.** This paragraph used to
end "and a power cycle remains the answer to the terminal state". The stub still cannot rescue it —
everything above is unaltered — but **the module rescues itself**, on its own idle timer, within
about three minutes as measured (2026-08-08, below) and about thirty on a current ROM, which sets
`AT+CIPSTO=1800` at bring-up. So the sweep this section is apologising for is answering a
question that mostly answers itself, which is a smaller gap than it looked.

**AND A SYMBOL SHIFT + NMI RE-INIT IS NOT A WAY OUT EITHER**, which is worth knowing because it is
the thing a user would reach for before the power switch. It does not run the sweep at all:
`main_bank_entry` calls `transport_init` directly (`src/main.asm`), never `esp_recover`, so no
`AT+CIPSERVER=0` is sent — and jnext refuses `AT+CIPSERVER=1` outright while a listener is already
running, which it still would be. So the re-init fails at its own AT chain and paints
"ESP-01 setup failed". Nothing the *machine* offers gets you out of the terminal state, which is why
this used to end "a power cycle is the only one the machine currently offers" — and the way out
turns out not to be on the machine at all. It is **waiting**: see 2026-08-08 below.

#### RUN ON A REAL NEXT, 2026-08-08 — the module gives the slot back by itself, in about 3 minutes

**Re-runnable, with the `--no-lift` option described above:**

    sudo test/run-vanished-peer.sh --host <ip> --no-lift --recover 210    # served
    sudo test/run-vanished-peer.sh --host <ip> --no-lift --recover 100    # refused

**Without that flag the question cannot be asked at any `--recover`**, because the default path
lifts the blackhole before it waits — which is the method failure described below, and the reason
this finding took two days longer than the hardware did.

**This reverses the conclusion of the section above, and the mechanism that hid it is worth more
than the number.** Two runs on the user's own Next, differing in one argument, with the firewall
blackhole **left up** across the wait:

| `--recover` | phase 1 | walk length (oldest peer's age at its end) | **B3** |
|---:|---|---:|---|
| **210 s** | 4 vanished, the 5th refused | 13 s | **SERVED in 56 ms** |
| **100 s** | 4 vanished, the 5th refused | 13 s | **REFUSED, timed out** |

Because the rules stayed up, no FIN, no RST and no retransmission of ours reached the module about
those peers. Something on the module's own side let one go, and it did so somewhere in
**(100 s, 210 s]** — measured, as that option measures, from the **last** peer going silent.

**The slot that frees first is the OLDEST peer's, so the reap is bracketed 13 s wider than that.**
`AT+CIPSTO` times each connection separately, and one free slot is all a fresh client needs, so what
B3 actually brackets is the age of the oldest vanished peer at the moment it was served: **(113 s,
223 s]**, the walk having taken 13 s. **180 sits inside that**, which is the cross-check that
matters. The 13 s spread is also why nothing here can say *which* peer's slot came back, only that
the earliest eligible one is the natural candidate.

**And the module says what that something is.** Read off the machine with `.UART`, on an Ai-Thinker
ESP-01 reporting `AT version:1.2.0.0` / `SDK version:1.5.4.1`:

    AT+CIPSTO?
    +CIPSTO:180

**`AT+CIPSTO` is the server's idle timeout, it defaults to 180 s, and this module ENFORCES it** —
which had been assumed to be a setting nothing acted on. Measured directly as well as through the
probe: a DZRP client that connected, sent `CMD_INIT` and then said nothing was dropped by the module
after **182.5 s** and **181.8 s** in two runs. That figure sits inside the bracket the probe gives,
from the opposite direction.

**Those two runs are now re-runnable as `make probe-idle-drop`** — see probe C below, which is
that client promoted out of a scratch script, and which carries a third run against an issue #24
build.

**It is not `esp_recover`, and that is ruled out rather than assumed away.** The sweep is
**fault-counted** — `ESP_FAULT_LIMIT` consecutive faults through `rxtx_error` — and has no timer in
it at all. During phase 2 nothing transmits and the blackholed peers are silent, so no fault can be
raised (traced in full in the section above, and B4's clean error area is its observable half). A
fault-counted mechanism cannot produce a result that **changes with elapsed time alone**, and
elapsed time was the only variable between the two runs.

**THE METHOD FAILURE IS THE TRANSFERABLE PART, and it is not that nobody waited.** Probe B as it
stands on `main` **lifts the blackhole first and then waits** — so its wait was never a test of the
module's patience, it was a test of how fast the module acts on news it had just been handed. Two
independent things had to change to see past that: the ordering, and the horizon. `--recover`
defaults to **20 s**, which is one ninth of the timer being probed, so even a probe that had left
the rules up would have reported `no`. **A negative result from an instrument whose horizon is
shorter than the effect is not a negative result** — it is the instrument's own scale, read back as
a finding. `ERRORS.md` carries the same disease under three other names.

**And the ordering was documented honestly the whole time**, which is what makes this worth writing
down rather than filing as carelessness: probe B's own text says its recovery means *"the slot comes
back once the module is **told**"*, and the section above this one repeats it. Nobody read that
correct sentence as *"therefore this instrument cannot answer the other question at all"*. **A
stated limitation is not the same as a noticed one.**

**What this still does not establish**, since a reversed conclusion is exactly where over-reading
starts:

* **Which** slot came back. No PC-side check sees connection ids, here as everywhere — so "the
  oldest peer's, at its own 180 s" is the natural reading of a per-connection timer and not an
  observation. A walk longer than a few seconds would separate the candidates; this one was 13 s.
* That **180 s is the number on any other module**. `AT+CIPSTO` is settable, its range is 0-7200,
  and `0` disables the timeout entirely — a module someone had set to `0` would behave exactly as
  this document described until 2026-08-08.
* Whether the module emits an `<id>,CLOSED` when it reaps a connection this way. Nobody looked, and
  it matters to issue #23's session line as well as here.
* Anything about a **wedged-but-reachable** peer, as against a vanished one. `AT+CIPSTO` is an
  *idle* timeout, so the same reaping is expected, but probe B stages only the vanished case.

**Issue #24 lengthened this deliberately — it is in the shipped ROM as of build 00.14 — and the
trade is measured on both halves.** Setting
`AT+CIPSTO=1800` at bring-up buys an idle debug session that survives **30 minutes** instead of
dying at 3 — which is the fault a user actually meets, since a debugger stopped at a breakpoint
while somebody reads code is silent for minutes and perfectly healthy. It costs exactly this
self-heal, stretched from about 3 minutes to about 30. Both halves are the same timer, and #19's
entry in `KNOWN-ISSUES.md` says so where a reader will meet it.

#### Issue #19's residual: what it takes to leak a slot, and what is NOT known

Written after probe B's hardware run, and **rewritten after an independent review rejected the
first version for overclaiming** — three of its findings were contradictions with this document's
own text, which is the failure this project keeps paying for. What follows is what is traceable.

**What does NOT leak a slot:**

| | evidence |
|---|---|
| an **abortive close** (RST) | #15's E-C control on build 000B: 12 rounds of connect + RST, accept latency flat at 4-12 ms, no leak. **Hardware, in this tree** |
| a **clean close** (FIN) | probe A's reclaim phase served 2 of 2 fresh clients after closing 5. **Hardware, but recorded in the 2026-08-06 session handover and not in this tree** — quoted with that provenance rather than as a re-runnable artefact |
| a **client killed mid-command** | the next connection was answered in 4 ms (MEMORY.md, 2026-08-05, build 000B). **Read narrowly**: it shows the stub kept serving, i.e. that a slot was free — it does **not** show the killed connection's own slot was reclaimed, since the module had spare slots anyway. That measurement was taken for issue #16 and answers a liveness question, not a slot-accounting one |

So the ordinary endings — DeZog quitting, Shift+F5, a crash, a killed process — all send a FIN or
an RST, and the first two rows say those free the slot.

**What leaks is one thing: a peer that goes away sending NEITHER.** Two separate questions follow,
and the first version of this section ran them together:

* **Staging it deliberately needs root.** `test/run-vanished-peer.sh` uses a firewall rule because
  a process cannot make its own kernel stop transmitting. That is a fact about the *probe*.
* **What produces it in the field is NOT known**, and this document says so three sections down:
  *"a real client crashing, a laptop sleeping or a WiFi drop would produce it differently."* A hard
  crash or power cut on the PC does it. So, plausibly, does **a laptop suspended mid-session and
  resumed on a different network** — the socket's retransmissions never reach the Next again, and
  no RST ever arrives — which is an entirely ordinary thing to do and needs no root at all. An
  earlier version of this section claimed suspend "does not qualify". That was asserted without
  measurement and contradicted the line above; it is withdrawn.

**The five-times compounding is real but the events are NOT independent.** The ceiling is 5
(measured), so five leaks must accumulate **inside one window** for the module to run out. One
persistent cause — a flaky link, a router that reboots nightly, a laptop routinely suspended
mid-session — can strand several without being five separate rare events. **The real-world rate is
unknown.** Nothing here measures it, and "deep in the tail" — which the first version of this
section said — is not supported.

**BUT THE WINDOW IS ABOUT THREE MINUTES, NOT A POWER-ON SESSION**, which is the single largest
change to this argument since it was written. This paragraph used to say the leaks accumulate
"between two power-ons", and reinforced it: *"the Next is not necessarily power-cycled often —
Appendix B.2 of the plan describes a machine left running with the listener alive across normal
use."* That was the whole force of the compounding worry, and `AT+CIPSTO` removes it. The oldest
leak is reaped one `AT+CIPSTO` timeout after it goes quiet, so five must land within roughly one
such window of each other; a machine left running for a fortnight accumulates nothing. **That window
is ~3 minutes on the firmware default and ~30 since build `00.14` sets `AT+CIPSTO=1800`**, so #24
widened it tenfold — the honest direction, and the opposite of what this paragraph implied while it
said three. The rate is still unmeasured —
this narrows the window the rate has to fill, it does not measure the rate — but it moves the
required coincidence from "five times before you next switch off" to "five times inside one
timeout", and those are not the same bet.

**What the shipped fix covers.** `esp_recover`'s sweep reclaims slots when a recovery runs, and a
recovery needs `ESP_FAULT_LIMIT` consecutive faults. A vanished peer **generates no faults itself**
— that is traced above and is structural, not probabilistic — so the sweep helps only when some
**independent** fault source is active at the same time. Whether that combination is common is
**not known**; an earlier version called it "the more plausible real-world pairing", which was
asserted rather than measured and contradicted the traced paragraph above it.

#### What would reopen it, and the one place the instruments cannot help

Stated so a future session neither re-litigates this from a hunch nor dismisses a real recurrence
by pointing at this section:

* a Next **refusing every new connection**, with its screen **clean** — no error area, `Core:` line
  intact — **that is still refusing an hour later**, and **no power cycle since boot**.

**The wait is the load-bearing half of that criterion, and it used not to be there.**
The module reaps an idle inbound connection at `AT+CIPSTO`, so a Next that refuses
everybody and then starts serving again is #19 behaving exactly as measured — not a recurrence, and
not worth reopening anything. What *would* be new is a refusal that **outlasts the timer**: either
five peers went quiet inside one such window, or something is holding slots that idling does
not free, and the second of those is a different fault wearing this one's face. Say which you saw.

**AN HOUR, BECAUSE THE TIMER IS ~1800 s AND NOT 180.** This criterion said *five minutes* until
issue #34, on the firmware default — and since build `00.14` the stub sets `AT+CIPSTO=1800` itself,
so five minutes is a sixth of the governing timeout and **a reader who waited it would have reopened
this issue on ordinary, correct behaviour**. The rule is "comfortably longer than the timeout"; an
hour is that, doubled for margin, and it matches `KNOWN-ISSUES.md` #19's own criterion rather than
restating a second number that can drift away from it.

**`make probe-slots` is NOT a discriminator in that state, and the first version of this section
wrongly said it was.** Its A1 check asks whether an *earlier* connection still answers, and
`test/slot-ceiling-probe.py` only runs that when at least one connection was served
(`first_bad and held`). A module with every slot leaked serves none, so the probe takes the
`elif first_bad` branch and prints exactly what it can honestly say: *"the very first connection was
not served, so there is no earlier one to ask."* The tool admits it cannot tell slot exhaustion
from a wedged stub in precisely the case this criterion describes.

**So the discriminator is at the machine, not on the PC.** A stub that is alive draws a clean
screen, answers its own keyboard (`B` toggles the border, `R` resets) and shows no error text; a
wedged one does not. That is the "AT THE MACHINE" protocol this page already carries, and in this
one state it is the only reading available — every PC-side instrument needs a connection, which is
the thing that cannot be had. Photograph the screen and try the keys **before** power-cycling,
because the power cycle destroys the evidence — and now there is a second reason to keep your hand
off the switch, since **waiting five minutes is both the fix and the discriminator**. A machine that
starts serving again is #19; one that does not is something else, and you still have it to look at.

**The decision to leave this unfixed is a cost judgement against an unmeasured rate**, not a
finding that it will not happen — and it stands on firmer ground since 2026-08-08 than when it was
made, because the fault it declines to fix clears itself unaided rather than needing
the power switch — in about three minutes as measured, and about thirty since issue #24 lengthened
the timer, which is less comfortable than it was but still not the power switch. Closing the criterion properly still needs a sweep reachable from a quiet stub —
periodic, or at connect time — which is a separate change, and one with distinctly less to buy now.

### Probe C — the idle-drop probe (`make probe-idle-drop`, no root)

Opens one connection, gets a `CMD_INIT` answered, then **says nothing and never closes it** — and
times how long the remote leaves it alone. It ends by reading the stub's own screen on a second
connection.

    # a current ROM: the stub sets 1800 itself since issue #24
    make probe-idle-drop NEXT_IP=<ip> PROBE_ARGS="--expect-timeout 1800 --deadline 400"
    # a build before #24, or one whose AT+CIPSTO the module refused
    make probe-idle-drop NEXT_IP=<ip> PROBE_ARGS="--expect-timeout 180"

**`--expect-timeout` HAS NO DEFAULT, AND THAT IS THE WHOLE DESIGN.** The probe cannot read
`AT+CIPSTO?` — that needs `.UART` at the machine — so a number baked into it would be the tool
asserting a property of a module it never asked. Given one, `R2` says whether the measurement and
the expectation agree; given none, `R1`'s number is printed and **nothing is attributed to it**.
Either way the exit code is the same: this renders no verdict, and a disagreement is a *finding*
rather than a failure.

*(An earlier scratch version printed `module reports +CIPSTO:180` unconditionally and concluded
from it. Run against a stub that had raised the value, it announced that no timeout existed — a
conclusion printed without consulting what happened, which is the defect two reviewers had just
rejected elsewhere in this bench. The measurements below were taken with that version; the numbers
are unaffected, the wording around them is not, and this paragraph is why.)*

**"SURVIVED" IS A LOWER BOUND, NEVER AN ABSENCE.** A connection still open at the deadline says the
timeout is *longer than the deadline* and nothing more, and no length of wait can ever say there is
none. The probe words every survival branch that way, and tells you up front when the deadline you
chose is too short for a survival to mean anything.

**AND A MATCH IS CONSISTENCY, NOT ATTRIBUTION.** From the PC every mechanism that closes an idle
inbound link looks identical. What rules `esp_recover` out is the argument two sections up — it is
fault-counted, nothing transmits during the wait, and a fault-counted mechanism cannot produce a
result that varies with elapsed time alone — and that argument is *traced*, not observed by this
probe.

**The rows.** `R0` the `CMD_INIT` round trip, which is also the instrument check: a probe that
reports a survival with `R0` green and a validated screen reader at the end was demonstrably working
at both ends of its wait. `R1` the measurement. `R2` the comparison, or a note that none was asked
for. `R3`-`R5` the closing screen read — the error area, the session line, and the **identity
line**, which is the only thing here that ties a hardware result to a build number, since DZRP's
`PROGRAM_NAME` reports upstream's `dezogif v2.2.1` for every ROM we ship.

#### RUN ON A REAL NEXT — three runs, and the third is an issue #24 build

All on the user's own machine, an Ai-Thinker ESP-01 reporting `AT version:1.2.0.0`:

| date | ROM | expected | outcome | session line afterwards |
|---|---|---:|---|---|
| 2026-08-08 | then-shipped — the stub sent no `AT+CIPSTO`, so the module's own default governed | 180 s | **dropped after 182.5 s** | `Session opened - CMD_INIT` |
| 2026-08-08 | the same, second run | 180 s | **dropped after 181.8 s** | `Session opened - CMD_INIT` |
| 2026-08-09 | `issue-24-cipsto`, **since merged as build 00.14** — the stub sends `AT+CIPSTO=1800` at bring-up | 1800 s | **survived 400 s**, the deadline | **`Session lost - client gone`** |

**SO THE EXPECTATION TO PASS TODAY IS 1800, NOT 180**, and the first two rows are history rather
than a description of the current ROM. Since issue #24 merged, a build that drops a silent client
at ~182 s is **the regression** — `R2` calls it *"EARLIER than the 1800 s expected"* — and that is
the check `make test-cipsto` cannot make, since jnext models `AT+CIPSTO` from the measurement in
those first two rows rather than being a module.

**What these establish.** A real ESP-01 enforces `AT+CIPSTO` against a server-accepted inbound
connection, at its documented default; and it honours a value the **stub** sets, since the same
client that was dropped at ~182 s twice was still connected at 400 s once the stub raised it. That
second half is issue #24's whole acceptance criterion, and nothing else in this tree can observe it.

**What they do NOT establish**, and the first two are easy to over-read:

* **The third run did not measure 1800 s** — it measured "longer than 400 s". Confirming 1800 needs
  a deadline past it, which is a half-hour run nobody has made. Consistent with #24; not a
  measurement of it.
* **None of the three says whether the module emits `<id>,CLOSED` when it REAPS.** The 2026-08-09 session line
  is the first hardware sighting of issue #23's observer working — but the close it saw was **our
  own clean FIN**, sent when the probe gave up at its deadline, not a reap. The 2026-08-08 runs
  *were* reaps and their session line did not move, which is equally uninformative: that build
  predates #23 and had nothing watching. The question in "#19's residual" above stays open.
* **One machine, one reporter, no captured artefact.** These sit on this project's
  **reported on hardware** rung, not on `verified`.
* Nothing about **another module**. `AT+CIPSTO` is settable over 0-7200 and `0` disables it.
* Nothing about a **wedged-but-reachable** peer, or about whether the timer is per-connection or
  global. One connection is timed; probe B's bracket is what bears on the second question.

#### Probe C has no `make probe-jnext` validation, and here is what stands in for it

The rule below is that an instrument is pointed first at a target whose answer is known. There is
no such target for C: **whether jnext models `AT+CIPSTO` at all has never been checked**, so the
emulator has no known answer to check against, and a probe pointed at a module with no timeout
would report the same survival as a broken one.

Two things stand in. In-band, `R0` and the closing screen read bracket the wait with two working
exchanges. Out of band, `test/idle-drop-fake-peer.py` is a ~150-line fake DZRP peer with one
property — an **idle** timer that closes a connection after a settable delay, or never — against
which every branch of the probe's wording is exercised in seconds instead of minutes:

    test/idle-drop-fake-peer.py --port 11987 --drop-after 20 &
    test/idle-drop-probe.py --host 127.0.0.1 --port 11987 --expect-timeout 20 --deadline 60

It is **not a stub and not an emulator**, and a green run against it says only that the probe
describes a peer that behaved in a known way correctly. That is exactly the claim the wording
needed, and nothing wider.

### `make probe-jnext` FIRST, always

**A probe that never worked reports a negative result indistinguishable from a real one.** This
project has already been handed one: the first hardware sweep of the CRLF swallow band reported a
*refutation*, and the refutation was a harness that read a DZRP response length as payload-only
where it counts from the sequence byte, so every trial died on its first command and the verdict
logic scored that as "answered" (`ERRORS.md`). The numbers were real; the instrument was not.

So probes A and B are pointed first at a machine whose ceiling is **known**, and checked against it.
**Probe C is not covered by this target** and cannot be, for the reason in its own section above.
The numbers are derived from jnext's own source, not chosen:

| | jnext | why |
|---|---|---|
| `MAX_CONNECTIONS` | 5 | `esp_at.h:437` — "ESP-AT's own `AT+CIPMUX=1` limit (ids 0..4)" |
| `FIRST_INBOUND_CID` | 1 | `esp_at.h:452` — slot 0 holds the **borrowed outbound** transport (simplification 8a) |
| **inbound slots** | **4** | the difference. `esp_at.cpp:894-902` closes anything past it: *"Real firmware refuses past its own ceiling too; ours is one lower because slot 0 is reserved"* |
| probe A expects | ceiling **4** | four held open, the fifth `DROPPED` |
| probe B expects | **3** survivals | a vanished peer keeps its slot **for the length of the walk** and the fresh client after it needs one of its own, so 4 − 1 |

*(That row said "for ever" until 2026-08-08. A real module reclaims an idle inbound slot at
`AT+CIPSTO`, ~180 s — but the walk is seconds long, far inside any such timer, so the arithmetic is
unchanged and the expectation still holds on both. **Whether jnext models `AT+CIPSTO` at all has not
been checked**, and this row deliberately no longer depends on the answer. What it does now depend
on is the walk staying short, which nothing on `main` reports; if a walk ever grows to minutes, this
expectation is the thing that quietly stops meaning what it says.)*

**Real firmware should be one higher — a ceiling of 5** — by that same comment: nothing on a real
module reserves a slot for outbound when the guest never sends `AT+CIPSTART`, so ids 0..4 are all
available. **That difference is itself a check.** A probe reporting 4 against hardware would be
reproducing an emulator artefact rather than measuring a module — and this project has been bitten
twice by jnext's value sitting on the safe side of ours, with a connection id of 0 and a
15-character IP address, both green in every emulator run.

**Neither expected number is ever asserted against hardware.** `--expect-ceiling` is passed by the
emulator harness and must never be passed at a Next: there the number is the unknown being measured,
and a probe that insisted on an answer would not be an instrument.

### What to watch ON THE MACHINE while a probe runs

**The probes now read the screen themselves, and this list is what is LEFT.** Since the DZRP screen
reader landed, probe A prints the error area twice — **A5** at the moment the ceiling is hit, over
the connection it already holds, and **A6** at teardown — probe B prints it once, as **B4**, at
teardown, and probe C prints it plus the session and identity lines as **R3**-**R5**, also at
teardown. So the observation this section used to ask a human for, and which was once lost by not
being asked, arrives in the output by itself.

Three things still need eyes, and the first two are not a formality:

| Observation | Why it matters |
|---|---|
| the **error area DURING phase 1 of probe B** | **This is the one the probes cannot reach.** B4 reads at the END, after phase 2's wait (on the default path, after it has lifted the blackhole); reading it while fresh clients are being refused would take one of the very slots being exhausted. Clean at that moment is the whole #15-is-#19 hypothesis — it says the stub is not faulting, so what is refusing connections is on the module's side of the UART. Probe A's **A5** *does* reach the equivalent moment, because it reads over a connection already open. And on a `--no-lift` run that ends with the module still refusing, **B4's own connection is refused too and the row does not print at all** — so the screen is the only place the answer exists |
| the **border** | **Not in the display file, so no `CMD_READ_MEM` can ever see it.** Moving means the stub is still cycling; frozen yellow means it is parked in a read (`transport_read_byte` writes yellow after every byte) |
| whether anything changed **DURING** the run | A5, A6, B4 and R3-R5 are point samples. A screen that reddened between two of them and was repainted is invisible to every one |

Photograph it before and after anyway — it costs nothing and it is the only artefact of the three
rows above. Note that `Last Error: RX Timeout` on its own is **not** necessarily a finding here: a
client hanging up can produce it (issue #16), and the probes open and close connections by design.
What would be a finding is any *other* text, or a clean area, and reading the text is exactly what
A5/A6/B4/R3 do that a pixel count cannot.

In the emulator the same reading is also taken from the screenshot by `make probe-jnext`, as a
bright-red pixel count — **0** through both validation runs, i.e. jnext reproduces #15's row 4
(screen intact) alongside rows 1 and 5.

### What the probes cannot establish

- **Probe C measures WHEN an idle connection ended, never WHAT ended it**, and its own section
  above says what a match against `--expect-timeout` is worth. It also cannot see `<id>,CLOSED`,
  so it cannot say whether the module announces a reap to the stub — `R4` reads only what the stub
  concluded.
- **None of the three reproduces issue #15.** (It was closed anyway, by the user on 2026-08-06, before probe
  B had run — recorded above. Read that as the user's call and not as either probe having settled
  it; nothing here reproduces #15 and nothing here refutes it.) Probe A finds a
  ceiling under *cleanly closed* connections, which are measured not to leak. Probe B shows what a
  vanished peer *costs*, not that a vanished peer is what happened on 2026-08-05.
- **Nothing here identifies what made a peer vanish** in the field. Probe B manufactures the
  condition with a firewall rule; a real client crashing, a laptop sleeping or a WiFi drop would
  produce it differently and with different timing.
- **No PC-side check can see connection ids**, so "which slot" is unanswerable from here, exactly as
  it is for H3.
- **None says anything about `esp_recover`**, issue #16's part C. `AT+CIPSERVER=0` does **not**
  close established connections (`esp_at.cpp:619-621`), which is the correction #19 was filed on —
  so a probe finding a wedge is not evidence that the recovery mechanism is broken.
  **Since #19 that recovery DOES sweep every link id with `AT+CIPCLOSE=<id>`**, so it can now
  reclaim what these probes strand — but only when it *runs*, and it runs on `ESP_FAULT_LIMIT`
  consecutive faults. **No probe here produces a fault at all**: probe A's peers are answered and
  then quiet, probe B's are blackholed behind a firewall rule, probe C's is answered and then
  silent, and in every case the stub is healthy throughout. So a probe still measures the module
  with nothing reclaiming, which is the state that matters here — and for probe C it is also what
  keeps `esp_recover` out of the running as the thing that closed its connection.
- **A green `make probe-jnext` says the instruments can find a ceiling in the emulator.** jnext's
  ceiling is four integers in a header file and its "connection" is a host TCP socket; a real
  ESP-01's is firmware with its own buffers, timers and failure modes.

## Step 5 — report

Save the whole run, and send it with the photograph from step 3:

    make test-hardware NEXT_IP=192.168.1.42 2>&1 | tee hardware-run.txt

Worth recording alongside it: the **core version**, whether the Next was **power-cycled** since
WiFi was configured (which is the only way to test that association really does persist), and
anything the screen said.

## What a green run does NOT establish

Stated here because the temptation to over-read the first hardware success will be considerable.

**This list used to be PRINTED by the bench**, as an `UNCOVERED` block after every summary. It was
moved here on 2026-08-05 at the user's request, and the reasoning generalises: a caveat that scrolls
past at the end of every run is read once and then never again, where a document can be revised,
cited and diffed. The same move shortened every verdict line the two Python benches emit to one
sentence — **the check says what happened, this file says what it means.** Nothing was dropped in
either direction; if a line here contradicts a line the harness prints, this file is the one that
was written to be read.

- ~~**The stub has never resumed a debuggee ON HARDWARE.**~~ **It has, 2026-08-05.** C10 and C11
  passed against a real Next: a fixture loaded over DZRP, `CMD_CONTINUE` onto a temporary
  breakpoint, `NTF_PAUSE` back at `0x8016` with the registers as the program left them. So
  `CMD_CONTINUE`, the exit path and `backup.asm`'s restoration are executed code **on silicon**,
  not only in the emulator.

  The struck-through sentence is kept because of *how* it was wrong. It said "this run does not
  attempt it", which was true of `hardware-check.py`'s own code and false of the run: **H2
  delegates to `conformance.py`, and that suite carries C10/C11.** The claim was written from what
  the script does rather than what it runs, and the run that disproved it printed the false
  version underneath its own evidence. When a check delegates, its coverage is the delegate's too.
- ~~**The stackless-NMI *return address*, in either place.**~~ **CLOSED on hardware, 2026-08-05, by
  a human with a real DeZog session.** A `CMD_CONTINUE` carrying no breakpoint set a fixture running
  in its `jr $`; the M1 button was pressed; the `NTF_PAUSE` came back with break reason 1
  (`MANUAL_BREAK`) and `CMD_GET_REGISTERS` reported PC `0x801C`, SP `0x9F00` — where it was spinning,
  on its own stack. `mf_rom.asm`'s dispatch reaches `mf_nmi_button_pressed` only while `prgm_state`
  is `PRGM_RUNNING`, that path calls `save_nmi_return_address` unconditionally, and the only other
  writer of `backup.pc` needs an `RST 0` that no breakpoint was planted for — so the value is that
  routine's and cannot be stale.

  **Which of its two branches ran is NOT established by this, and the difference matters enough to
  say so.** `save_nmi_return_address` reads NR `0xC2`/`0xC3` in stackless mode and the debuggee's
  own stack otherwise, and both would have produced this same correct answer.
  `doc/legacy/Design.md:378` and `:434` say the stackless mode is the *default* from core 03.01.10,
  and this machine reports above that with nothing in `src/` ever clearing NR `0xC0` bit 3 — so
  stackless is the strong presumption, not an observation. **What is observed, and is what §3.4
  actually cares about, is the outcome**: an NMI taken against a running debuggee returned a correct
  PC on an uncorrupted stack. Distinguishing the branches needs NR `0xC0` read back at the moment of
  the break, which nothing does.

  It needed a finger on a button: `--delayed-nmi` counts emulated frames while a client counts wall
  clock, so no bench here can schedule one. The reasoning that made it look unreachable was right
  about benches and wrong about people.
- ~~**AltROM on hardware.**~~ **Covered since 2026-08-05, and the struck line is kept because of
  how it was wrong.** It said the emulator exercised the patched ROM and "nothing has run under a
  patched ROM on a Next" — but H2 delegates to `conformance.py`, and C10 runs there too. The chain:
  while the debuggee runs slot 0 holds `ROM_BANK` (`main.asm:150`, restored at
  `breakpoints.asm:192`) with the AltROM enabled (`altrom.asm:55`, the only enable and nothing
  disables it), so C10's temporary breakpoint — an `RST 0` — can only reach the debugger through
  the code `copy_altrom` installs at 0x0000. **C10 passed on a Next, so the patched AltROM
  executed on silicon.** Same mistake as the resume claim two bullets above: written from what the
  script does rather than from what it runs.
- ~~**DeZog itself.**~~ **Done, 2026-08-05.** A VS Code session with `remoteType: "cspect"` and
  `hostname` pointed at the Next attached, disassembled, read registers and memory, **single-stepped
  thirteen times**, disconnected cleanly and reattached — captured through a logging TCP tap. See
  the plan's M1. **Two cautions for whoever repeats it**: DeZog reads the **entire 64 KB** at attach
  in two 32 KB `CMD_READ_MEM`s, which costs ~9 s at 115200 and looks like a hang if you do not
  expect it; and the workspace's own `CSpect MF ROM` launch config is **not safe to point at
  hardware** — it carries `loadObjs` of `enNextMf.rom` and an `execAddress`, so it would push the
  stub's own image into the running machine. Use a minimal config with no `loadObjs`.
- ~~**The Next's own screen — but only for as long as nobody reads it over the wire.**~~
  **WRITTEN, 2026-08-06** — `test/dzrp/screen.py`, `make read-screen NEXT_IP=<ip>`, and bench row
  **H6**. `CMD_READ_MEM 0x4000,6912` fetches the display file, so **S1-S4 are text in the bench
  output** instead of a photograph and a human, and both issue #15 probes now print what the error
  area said at the moment they measured.

  The struck line said the screen is reachable because `cmd_init` maps banks 10 and 11 at 0x4000,
  and **that reading would have made the reader destroy its own subject.** `cmd_init` also does
  `xor a` / `ld (last_error),a` and repaints, so a reader that sent one would clear the error it
  came to read — which is exactly how an observation was lost on 2026-08-06, when probe A ran
  against a real Next and its reclaim phase's `CMD_INIT`s would have wiped anything the walk
  raised. What is true is that those writes **restore** a mapping already in place: nothing the
  stub runs by itself touches slots 2 or 3, and its own `show_ui` draws through them, which is why
  its UI is visible on the first M1 press with no client attached. Measured against jnext — a
  connection that sent no `CMD_INIT` ever read the screen, and a later `CMD_INIT` changed one
  display row (the session line) and no attribute byte. A **client** can still move that mapping
  with `CMD_SET_SLOT`; nothing here does, and `validate_reader()`'s row-12 check is the backstop.

  **What it still cannot see: the BORDER**, which is not in the display file, and **S5**. Both stay
  a human's job, and the probes still say so.
- **The UART build**, which needs a joy-port cable and a USB serial adapter. The conformance suite
  reaches it directly when someone has that set up:

      make test-dzrp REMOTE=serial:/dev/ttyUSB0:921600

  **This gap has GROWN, and that is worth saying plainly.** The serial path's only standing guard
  has been byte-identity — "the UART ROM did not change" — and issues **#7, #8, #9 and #12 each
  changed it deliberately**, so that guard has answered nothing four times running. **Nothing has
  ever executed the serial transport end to end**, in an emulator or on a machine.
- **Interleaved commands, on hardware.** H3's two exchanges are sequential, deliberately:
  interleaving them asks whether a reply can be flushed to the *wrong* connection because a second
  command arrived and moved `esp_conn_id` first, which is a property of our own buffering rather
  than a hardware fact, and this bench does not conflate the two.

  **That was issue #13 and it is FIXED** — merged 2026-08-05, build 000C — with the emulator suite's
  **W5** as its standing check: a command split across `+IPD` frames, with a second client speaking
  into the middle of it, answered on its own connection from its own payload. So the caveat is no
  longer "an open defect nothing can see"; it is the narrower and permanent one that **W5 proves it
  in jnext and no check here proves it on silicon.**
- **A client that reconnects but has not yet sent anything is invisible**, because only an inbound
  `+IPD` refreshes the connection id. Known, deferred to M3's reconnect work.
- **Anything about a second power cycle**, unless you do one.

## What the run established — measured 2026-08-05, on a real Next

Appendix A of the plan is a ladder — `verified`, `reported on hardware`, `inferred`, `estimate` —
and its rule is that a claim must never sit higher than its evidence. **This table used to be
predictions. These are the results.**

| Claim | Was | Now |
|---|---|---|
| The real ESP-01 answers at 115200 until told otherwise | inferred | **verified** — H1 connected in 274 ms, so the whole AT chain was accepted at that rate |
| Round-trip latency | estimate, "10-100 ms" | **measured: min 10.8 ms, median 13.0 ms, max 23.6 ms.** At the good end of the guess; single-stepping will feel responsive |
| ESP TCP throughput | estimate, "tens of KB/s" | **measured: 8.0 KB/s round trip** — 4096 bytes each way in 1.01 s |
| tbblue does not checksum `enNextMf.rom` | inferred | **verified** — ours booted |
| Inbound connection ids on real firmware | unverified | **verified indirectly: the first client gets id 0.** Not by observation — no PC-side check can see the ids — but by the failure it caused, which is only possible if the id was 0. See the divergence table at the top |
| The `+IPD` id is read rather than assumed | emulator only | **verified on hardware** — H3, two simultaneous connections, each getting its own payload |
| DZRP conformance | emulator only | **12 of 12 on hardware** (build 000A). It was 11 of 12 when first run, the red being `CMD_PAUSE` — issue #8, fixed and now re-measured on a Next |
| **The AltROM patch works on hardware** | C10's `RST 0` breakpoint, which reaches the debugger only through `copy_altrom`'s code at 0x0000, with slot 0 = `ROM_BANK` and the AltROM enabled while the debuggee runs | **verified on hardware** — it was listed as emulator-only until someone followed what H2 actually runs |
| A command arriving while the stub is answering another survives | **red on hardware, 3 runs of 3** — the `SEND OK` window, which no emulator here can reach | **verified on hardware, 3 runs of 3** (build 000A, issue #11). Median round trip and throughput unchanged by the fix: 11.3-11.5 ms and 6.1-8.2 KB/s against 11.5 ms and 8.3 before it |
| The debuggee resumes | emulator only | **verified on hardware** — C10/C11 through H2's delegation |
| The connect string shows a correct address | never read on hardware | **reported on hardware** — correct at **15 characters**, the length the parser used to refuse and one jnext cannot produce |

**The throughput figure deserves reading carefully, because the obvious reading is wrong.** 8.0 KB/s
sounds far below 115200 baud until you count what actually moved: a loopback carries the payload
**twice**, so 8192 bytes crossed the wire in 1.01 s. At 8N1 the line itself can carry 11520 bytes/s,
so the transport achieved **71% of line rate** — the framing and round trips cost the other 29%.
The wire is the bottleneck, not the `AT+CIPSEND` overhead, which is what makes M3's baud
negotiation worth doing and roughly bounds what it can win: about 2.5x before the fixed costs
dominate.

An earlier draft of this section reported that as "about a third of the estimate", by comparing a
one-way payload figure against a line rate. It is recorded here because the arithmetic error
pointed at the wrong optimisation.

## The suite at its full size — measured 2026-08-08 12:37, on a real Next

The run above was 12 checks because that is the size the suite was that day. C13/C14 (issue #9) and
C15 (`CMD_CLOSE`) were added afterwards, and this is the first recorded run carrying all of them.
**`192.168.100.136`, 3 passed / 0 failed / 3 measured / 0 skipped of 6.**

| check | result |
|---|---|
| **H1** | PASS — connected in **242 ms** |
| **H2** | PASS — **15 of 15** conformance, 0 failed, 0 unsupported. C13, C14 and C15 included, so every check in the suite has now run on silicon |
| **H3** | PASS — two simultaneous connections each got their own payload back |
| **H4** | 20 samples: min **10.8**, median **11.2**, max **13.4 ms** |
| **H5** | 4096 bytes in **0.97 s** — 8.3 KB/s round trip, 4.1 KB/s one way |
| **H6** | the error area is **CLEAN**, 0 bright-red pixels on the stub's own screen |

**The latency and throughput agree with the post-issue-#11 measurements** (11.3-11.5 ms median,
up to 8.3 KB/s) rather than with the 13.0 ms of 2026-08-05, so the `+IPD` capture fix continues to
cost nothing measurable. **The build number was not captured** — the DZRP `PROGRAM_NAME` reports
upstream's `dezogif v2.2.1`, not our identity block, which is read off the stub's screen. So this
row cannot be tied to a specific build the way the 000A run can.


## At 460800 baud — measured 2026-08-09, on a real Next, build `00.16`

**The first runs above 115200, and the first time the bring-up probe has executed anywhere.** The
ROM is `make TRANSPORT=wifi BAUD_HIGH=460800 mf-rom` at build `00.16`, i.e. carrying issue #31's
fix — **that matters, because at 460800 without it the stub's own screen is visibly corrupt** and
the "the screen must say 460800" criterion cannot be read honestly off a screen drawing wrong.

**Five consecutive runs, `192.168.100.136`, every one 3 passed / 0 failed / 3 measured of 6, with
15 of 15 conformance.**

| check | result across the five runs |
|---|---|
| **H1** | PASS — connected in 107, 7, 119, 106, 55 ms |
| **H2** | PASS — **15 of 15** every run, 0 failed, 0 unsupported |
| **H3** | PASS — two simultaneous connections each got their own payload back |
| **H4** | median **6.4 / 6.8 / 6.7 / 6.4 / 6.6 ms** (min 6.0, max 12.3) |
| **H5** | 4096 bytes in ~0.39 s — **19.8 / 20.4 / 20.0 / 20.3 / 20.3 KB/s** round trip |
| **H6** | the error area is **CLEAN** every run, 0 bright-red pixels, and no `RX Overflow` |

**Against the 115200 baseline: latency 11.2 → 6.6 ms median, throughput 8.3 → 20.3 KB/s, i.e.
2.45x.** That baseline is the *suite at its full size* run of **2026-08-08 12:37** — named rather than
pointed at, because "above"/"below" goes stale the next time a dated section is added, which is
exactly what happened while this section was being written. So this is a **cross-session**
comparison and
not a same-session A/B with only the rate varied — said out loud because WiFi round trip is not a
controlled quantity. The effect is far larger than the jitter within either set (every one of the
five runs lands between 19.8 and 20.4 KB/s, against 8.3), which is why it is quoted at all. The latency result **contradicts the prediction recorded with the negotiation**, which said
to expect it unchanged because 11.2 ms is WiFi round trip rather than wire time. It nearly halved,
so a material part of that figure was the wire after all.

### The bring-up probe fired — and the conclusion rests on one cited premise

`transport_init` greets the module at 115200 and, on silence, at `ESP_BAUD_HIGH`. That second
greeting is **structurally unreachable in jnext**, whose module answers the first one every time, so
no bench in this repository can execute it. It is also the only recovery the stub ships: a soft reset
leaves the UART prescaler alone (`i_reset_hard` is tied to `'0'`, `zxnext.vhd:3361-3367`) and does
not reset the module either — the stub's `R` key writes `nextreg REG_RESET, 01b` (`src/ui.asm:52`)
with **bit 7 clear**, and bit 7 is the one that would pulse reset to the ESP and the expansion bus.
So after `R` **both ends are still at 460800** while a fresh `esp_uart_init` assumes 115200.

Sequence run at the machine: **M1** (stub up at 460800) → **`R`** → **M1**, and the stub came back
up with row 3 reading 460800. Between the reset and the second press, `.UART` sent `AT` and **got no
answer**.

**Behaviour alone could not have told you anything, which is why that step was needed.** A module
still at 460800 reaches the screen's "460800" *through the probe*; a module back at 115200 reaches
the identical screen by being greeted normally and then negotiated up. The two are
indistinguishable from the outside.

**The conclusion rests on one premise, and it is cited rather than assumed**: `.UART` puts the link
at 115200 **itself**, rather than inheriting whatever prescaler it finds — `doc/WIFI-SETUP.md:148`
records that it sends `ATE0` and `AT+UART=115200,8,1,0,0` on entry. That premise is load-bearing
precisely because the prescaler survives a soft reset, so a `.UART` that inherited it would have
been sitting at 460800 too, and a still-460800 module would then have *answered*. Given the premise,
the silence says the module was not at 115200 — so the stub's own 115200 greeting must have failed
and `ESP_BAUD_HIGH` is the only other rate it tries.

**And the instrument was controlled, which is what the "no answer" needed.** Silence has two causes
— the wrong rate, or a `.UART` that does not work. So: power-cycle, which returns the module to its
115200 firmware default, then `.UART` and `AT` again → **`OK`**. The tool works at 115200; the
earlier silence was the rate. Without that second step the evidence would have been worth nothing,
which is this document's standing rule about negative results from uncontrolled instruments.

**A DeZog `.nex` load at this rate WAS then done, and it is the weakest item on this page.** The
user ran a real F5 over the raised link and reports it worked and felt faster. **No timing was
captured and there is no artefact**, so it is worth exactly that: it says the largest inbound traffic
the stub ever sees — `CMD_WRITE_BANK`, 8-16 KB per bank, far more than C5's largest 4096 bytes, on
the very receive path whose per-byte cost is what stops 600000 working — did not visibly fall over.
It is not a measurement and nothing should be built on it.

**NOT established by these runs.** A **second machine or module**. And, named separately because
"a second module" does not convey it, **a marginal link that ACCEPTS the rate and then corrupts
bits**: every failure the six criteria cover is a clean one — the module refuses, or goes quiet, and
the fallback catches it. A unit with a worse crystal, more RF noise or a longer bus path could take
`AT+UART_CUR=460800` and misbehave on the wire, which would surface as DZRP desynchronisation rather
than as a rate fault, and nothing here would catch it as a refusal. And the probe **against a module at a
rate this ROM was not built for**, which nothing stages: it only ever tries the two rates it knows.

---

## C18, and the Next we destroyed to earn its green — measured 2026-08-09, build `00.16` then `00.19`

**This is the only RED-FIRST PAIR this project has taken on silicon**, and it is the reason the
swap-window bound is believed rather than merely reviewed. Same machine, same client, same
`make test-hardware` invocation. One build apart.

| | build `00.16` (no bound) | build `00.19` (as merged) |
|---|---|---|
| **C18** — a 12288-byte `CMD_LOOPBACK` | **FAIL** — *left the remote not serving* | **PASS** — *a 12288-byte payload was declined and the remote served on* |
| C15, H3 | FAIL — cascade from a stub that had stopped serving | PASS |
| the machine afterwards | **stub destroyed**, power cycle required | healthy |
| the bench | **did not complete** — H1 pass, H2/H3 fail, H4 skip, **H5 and H6 never ran** | **6 of 6**, conformance **18 of 18** |

**THE RED RUN'S TRANSCRIPT, VERBATIM, because summarising it is how this section got it wrong
once.** An earlier version of the table above said *"1 passed, 3 failed of 6"*. There is no such
tally: `hardware-check.py` reports H4, H5 and H6 as **SKIP** rather than FAIL when it cannot connect
(`:715`, `:733`, `:776`), so at most two checks can fail this way — and the run never printed a
summary line at all, because it stopped after H4:

    H1   PASS  connected to 192.168.100.136:11000 in 1037 ms, session opened and closed cleanly
    H2   FAIL  C18, C15 failed; C18, C15 not known-red, so new on this remote
    H3   FAIL  could not open two simultaneous connections: gave up on 192.168.100.136:11000 after 2 attempts — timed out after 0 of 1 bytes
    H4   SKIP  could not connect: gave up on 192.168.100.136:11000 after 2 attempts — timed out after 0 of 1 bytes

**The asymmetry that produced the error is worth more than the error.** The green run was
transcribed line by line from the terminal; the red one was compressed into a summary from memory —
in a section whose own argument is that **the red is worth more than the green**. If a run is worth
citing as evidence, paste it.

**AND THE FIRST ATTEMPT TO PASTE IT TRUNCATED TWO OF THE FOUR LINES, UNDER THIS HEADING.** H3's and
H4's details were shortened to *"gave up after 2 attempts"*, dropping the address and the underlying
cause that `connect()` always embeds (`hardware-check.py:260-264`). The reviewer caught it **without
the original paste**, purely from the tool's format strings — and noticed the tell: the two lines
that match exactly are the ones with no variable boilerplate, and the two that were shortened are
the ones carrying host, port and cause. **That is what reconstruction from memory looks like**, and
a "VERBATIM" heading over it makes it worse rather than better. If you find yourself tidying a
quoted line, it is not a quote.

**What the red was.** `cmd_loopback` buffers into a bank paged at `SWAP_ADDR`, an **8 KB** window,
and — before `00.19` — walked upward for as many bytes as the frame **declared**. One slot on is
`MAIN_SLOT`, the bank the debugger is executing from. Upstream's, since 2020, and until this run it
had only ever been *measured in jnext*.

### Reading the hung machine, which is a procedure worth repeating

Taken off the screen **before** recovering it:

| observation | what it means |
|---|---|
| border **yellow**, and **not cycling** | yellow is the colour `transport_read_byte` leaves while waiting — the value bench **N1** asserts (`182,182,0`). Not cycling means `main_loop` was never reached |
| `B` does nothing | the key poll lives in `main_loop` |
| `R` does nothing | same |
| screen text otherwise intact | the UI was painted before the damage |
| **two small red dots, mid-right** | **unexplained.** Gone after the power cycle, and H6 read clean afterwards — consistent with transient damage, not evidence of it |

**`B` and `R` being dead was predicted from the border colour before it was checked.** That is the
discriminator to reach for first: it separates a wedged Z80 from a healthy stub whose transport has
desynchronised, and it costs two keypresses.

### THE MISTAKE THAT NEARLY WENT INTO THE RECORD

The red was first read as *"the bound holds on hardware but the stub cannot survive its own
refusal"*, complete with a mechanism (backpressure; `drain_main` draining 100 ms against ~267 ms of
wire time at 460800) and an issue — [#35](https://github.com/jorgegv/dezogif_ng/issues/35). **The
build under test had been assumed.** A photograph of the screen then showed **`build 00.16`** in its
first line: the pre-fix ROM, which contains no bound at all, so the walk was expected and the
hypothesis described a code path that build does not have.

**That issue should never have been opened**, and it is closed as `not planned`. The build was
unverified not merely before a *conclusion* but before a **public claim that shipped code was
defective** — so the rule below has a second half: **verify before you file, not only before you
conclude.**

**So: ask for the banner before interpreting a hardware run.** Row 0 carries
`dezogif_ng <variant> NN.NN` for exactly this reason (issue #12), it is free to read, and it is the
only thing on the machine that says which ROM is executing — DZRP's `PROGRAM_NAME` reports
upstream's `dezogif v2.2.1` whatever we ship. The same discipline had been applied twice that
evening to *bench worktrees*, where a suite reporting 15 checks instead of 18 revealed a run in the
wrong tree, and was then not applied here.

### The measurements from the green run

    H1   PASS  connected to 192.168.100.136:11000 in 30 ms, session opened and closed cleanly
    H2   PASS  the DZRP conformance suite passed in full
    H3   PASS  two simultaneous connections each got their own payload back
    H4   MEAS  20 samples: min 5.9, median 6.3, max 13.2 ms
    H5   MEAS  4096 bytes in 0.40 s: 20.0 KB/s round trip, 10.0 KB/s one way
    H6   MEAS  the error area is CLEAN — 0 bright-red pixels on the stub's own screen

    3 passed, 0 failed, 3 measured, 0 skipped of 6

**H2's own line carries no count**, so the `18 of 18` comes from the `conformance.py` block the
bench prints above it, whose summary line was:

    DZRP conformance: 18 passed, 0 failed, 0 unsupported, of 18 checks

**The per-check block itself is NOT reproduced here** — only that summary line and the six bench
lines above were captured. (An earlier version of this parenthetical said the block was "quoted in
full at the top of this section". It is not, anywhere in this file; that was a citation to evidence
that does not exist, caught by `grep` in review.)

**C16 and C17 are the scheduled question, and they pass.** C17 pushes **16384 bytes** in one
`CMD_WRITE_MEM` — **four times** the largest payload that established the 460800 ceiling, on the
same per-byte *receive* path whose cost the rate sweep bracketed at 470-610 T-states. The margin is
there on silicon.

**H4 and H5 reproduce the 460800 figures for a fourth time** (6.3 ms against 6.6, 20.0 KB/s against
20.3), so the rate is now well characterised on this machine.

### `Error: payload too big for databank` was drawn, and H6 still reads CLEAN

The error text `ERROR_PAYLOAD_TOO_BIG` added by `00.19` (`src/ui.asm:28`, `src/data_const.asm:195`)
**appeared on the Next and was read by a human** during the green run — its first outing anywhere.

**H6 nevertheless reports 0 bright-red pixels, and that is not a contradiction.** `cmd_init` clears
`last_error`, and C15's follow-up `CMD_INIT` runs before the bench reads the screen. Written down
because `H6 CLEAN` would otherwise be read as *no error was ever raised*.

### NOT established by this pair

- **The `OSError` arm of `chk_oversize_payload`.** The oversize send completed and was declined
  in-band, so that branch was not taken here either — it remains correct-by-construction and
  unexercised everywhere. See [#33](https://github.com/jorgegv/dezogif_ng/issues/33).
- **The UART build.** `commands.asm` is common code and both ROMs carry the bound, but no hardware
  run has ever driven the serial transport.
- **Build `00.18`'s idle sweep**, which shipped in the same ROM. Nothing here exercises it; its
  300 s period has never been watched anywhere, and no bench stages the vanished peer it exists for.
- **The smallest payload that triggers the pre-fix walk** — 8193 against this run's 12288 — and
  whether the pre-fix hang reproduces at 115200.
- **One machine, one ESP-01, one reporter.**

---

## The AP went away and came back — measured 2026-08-09, on a real Next

**This run is the whole evidence for issue #32 not building half of itself**, and until this
branch it was cited five times across the tree and recorded **nowhere in this repository** — only
in [jnext#246](https://github.com/jorgegv/jnext/issues/246). `KNOWN-ISSUES.md` designates this
document as the home for anything read off a real Next, so it belongs here.

**Method.** The access point was powered **down for five minutes and back up**, with the stub
already up and listening, and nothing done to the Next at any point — no M1 press, no reset.

| | measured |
|---|---|
| does the `AT+CIPSERVER` listener **survive** a de-association and re-association? | **yes** — a full `make test-hardware` passed **6 of 6 with 15 of 15 conformance** afterwards, so the stub was still listening on 11000 and serving |
| does the station address survive? | **yes in that run** — the Next answered a ping and the bench on the same IP. The DHCP lease held across five minutes |
| does the guest see anything go wrong? | **no** — the stub's screen did not change and it raised no error at all |

**Tier: `reported on hardware`** — one machine, one reporter, no re-runnable artefact.

### What this run does NOT establish, and issue #32 rests on the distinction

- **The de-association itself was never observed.** Five minutes without beacons will make an
  ESP8266 declare the AP lost, but **nothing read `AT+CWJAP?` or `AT+CIFSR` during the outage**.
  What was measured is the state on the far side of it.
- **The address CHANGING across an outage was not seen** — the lease held. jnext#247 records that
  it has never been observed on an ESP-01 at all; the emulator models it because whether a DHCP
  address can move across a reconnection is a property of *networks* rather than of ESP-AT
  firmware. **Every one of bench check D1's greens is against that model and not against a
  module.**
- **Therefore whether a real module keeps ACCEPTING after its address changes is unknown.** If it
  does not, issue #32's second half — re-acquisition — is owed for exactly that case, and the
  screen would advertise a new address nothing is listening on: a better-disguised lie than the
  one #32 removes. **This is the first thing to check the next time an AP can be power-cycled.**
- **`make test-wifi-assoc` cannot corroborate any of it.** jnext's own `--help` for
  `--esp-delayed-disassociate-frames` says *"Nothing else changes: open connections keep running
  and no `WIFI DISCONNECT` is sent"*, so a probe finding the listener alive across an emulated
  outage restates the emulator's design decision. Bench check **D6** guards a **stub-side**
  regression only — a fix that retired the listener and rebuilt it — and can never guard a
  module-side one.
- **The unsolicited `WIFI DISCONNECT` / `WIFI CONNECTED` / `WIFI GOT IP` lines** were not looked
  for. Nothing here has ever seen them, which is why the stub polls rather than watching.
- **How long a real re-association takes** is unmeasured, and that is the number that would decide
  whether `ESP_ADDR_CHECK_SECS` at 60 s is the right period.
