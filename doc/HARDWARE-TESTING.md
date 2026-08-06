# Testing on real hardware

    make test-hardware NEXT_IP=192.168.1.42

**It runs on a real ZX Spectrum Next, and as of build 000A every check here passes.** The stub
takes the M1 NMI, brings the ESP-01 up as a TCP server, answers **12 of 12 DZRP conformance
checks on hardware** — including resuming a debuggee — and survives a command arriving while it is
answering another, which is the one thing it demonstrably could not do this morning. The results
are at the bottom of this page, with the numbers.

**That "12" is the count the suite had on the day, and it has grown since**: C13/C14 (issue #9) and
C15 (`CMD_CLOSE`) were added afterwards, so H2 now delegates **15** checks. The added ones have
never run on silicon. Read every conformance total on this page as a record of the run that
produced it, not as the size of the suite today — `python3 test/dzrp/conformance.py --help` lists
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
Remote debugger active.
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

## Step 4b — the issue #15 probes (optional, and NOT part of the bench)

    make probe-jnext                             # FIRST. Always. See below
    make probe-slots      NEXT_IP=192.168.1.42   # probe A
    make probe-vanished   NEXT_IP=192.168.1.42   # probe B — needs sudo

These two are **instruments, not gates**. They print numbers and observations and render no
verdict, they are not part of `make test`, and **neither can close
[issue #15](https://github.com/jorgegv/dezogif_ng/issues/15) on its own.** Nobody has reproduced
that wedge deliberately; their job is to make a positive reproduction possible.

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
A power cycle was the only thing in the system that reclaimed a slot. That fits the unexplained
half exactly: stub healthy, screen intact, TCP degrading then refusing, recoverable only by pulling
the plug.

**#19 IS NOW FIXED, AND THE PAST TENSE ABOVE IS DELIBERATE — BUT IT DOES NOT RETIRE THESE PROBES.**
jnext#211 shipped `AT+CIPCLOSE=<id>`, and `esp_recover` sweeps every link id with it
(`make test-slot-recovery`, 3 checks, green in the emulator). What that reclaims a slot on is a
**recovery**, which needs `ESP_FAULT_LIMIT` **consecutive faults** — so a peer that goes away
without ever making the stub fail a read still holds its slot indefinitely, and the module still
has no other way to give one back. The probes' subject is that residue, and it is exactly the case
probe B stages. Read the paragraph above as the state a Next built before that fix is in.

**So the hypothesis is that #15 IS #19**, and these probes measure what it rests on.

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

### `make probe-jnext` FIRST, always

**A probe that never worked reports a negative result indistinguishable from a real one.** This
project has already been handed one: the first hardware sweep of the CRLF swallow band reported a
*refutation*, and the refutation was a harness that read a DZRP response length as payload-only
where it counts from the sequence byte, so every trial died on its first command and the verdict
logic scored that as "answered" (`ERRORS.md`). The numbers were real; the instrument was not.

So both probes are pointed first at a machine whose ceiling is **known**, and checked against it.
The numbers are derived from jnext's own source, not chosen:

| | jnext | why |
|---|---|---|
| `MAX_CONNECTIONS` | 5 | `esp_at.h:437` — "ESP-AT's own `AT+CIPMUX=1` limit (ids 0..4)" |
| `FIRST_INBOUND_CID` | 1 | `esp_at.h:452` — slot 0 holds the **borrowed outbound** transport (simplification 8a) |
| **inbound slots** | **4** | the difference. `esp_at.cpp:894-902` closes anything past it: *"Real firmware refuses past its own ceiling too; ours is one lower because slot 0 is reserved"* |
| probe A expects | ceiling **4** | four held open, the fifth `DROPPED` |
| probe B expects | **3** survivals | a vanished peer keeps its slot for ever and the fresh client after it needs one of its own, so 4 − 1 |

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
the connection it already holds, and **A6** at teardown — and probe B prints it once, as **B4**, at
teardown. So the observation this section used to ask a human for, and which was once lost by not
being asked, arrives in the output by itself.

Three things still need eyes, and the first two are not a formality:

| Observation | Why it matters |
|---|---|
| the **error area DURING phase 1 of probe B** | **This is the one the probes cannot reach.** B4 reads at the END, after phase 2 has lifted the blackhole; reading it while fresh clients are being refused would take one of the very slots being exhausted. Clean at that moment is the whole #15-is-#19 hypothesis — it says the stub is not faulting, so what is refusing connections is on the module's side of the UART. Probe A's **A5** *does* reach the equivalent moment, because it reads over a connection already open |
| the **border** | **Not in the display file, so no `CMD_READ_MEM` can ever see it.** Moving means the stub is still cycling; frozen yellow means it is parked in a read (`transport_read_byte` writes yellow after every byte) |
| whether anything changed **DURING** the run | A5, A6 and B4 are point samples. A screen that reddened between two of them and was repainted is invisible to all three |

Photograph it before and after anyway — it costs nothing and it is the only artefact of the three
rows above. Note that `Last Error: RX Timeout` on its own is **not** necessarily a finding here: a
client hanging up can produce it (issue #16), and the probes open and close connections by design.
What would be a finding is any *other* text, or a clean area, and reading the text is exactly what
A5/A6/B4 do that a pixel count cannot.

In the emulator the same reading is also taken from the screenshot by `make probe-jnext`, as a
bright-red pixel count — **0** through both validation runs, i.e. jnext reproduces #15's row 4
(screen intact) alongside rows 1 and 5.

### What neither probe can establish

- **Neither reproduces issue #15**, and **#15 must not be closed on either.** Probe A finds a
  ceiling under *cleanly closed* connections, which are measured not to leak. Probe B shows what a
  vanished peer *costs*, not that a vanished peer is what happened on 2026-08-05.
- **Nothing here identifies what made a peer vanish** in the field. Probe B manufactures the
  condition with a firewall rule; a real client crashing, a laptop sleeping or a WiFi drop would
  produce it differently and with different timing.
- **No PC-side check can see connection ids**, so "which slot" is unanswerable from here, exactly as
  it is for H3.
- **Neither says anything about `esp_recover`**, issue #16's part C. `AT+CIPSERVER=0` does **not**
  close established connections (`esp_at.cpp:619-621`), which is the correction #19 was filed on —
  so a probe finding a wedge is not evidence that the recovery mechanism is broken.
  **Since #19 that recovery DOES sweep every link id with `AT+CIPCLOSE=<id>`**, so it can now
  reclaim what these probes strand — but only when it *runs*, and it runs on `ESP_FAULT_LIMIT`
  consecutive faults. Neither probe produces a fault at all: probe A's peers are answered and then
  quiet, probe B's are blackholed behind a firewall rule, and in both cases the stub is healthy
  throughout. So a probe still measures the module with nothing reclaiming, which is the state
  that matters here.
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
