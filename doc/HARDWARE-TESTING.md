# Testing on real hardware

    make test-hardware NEXT_IP=192.168.1.42

**It runs on a real ZX Spectrum Next.** The stub takes the M1 NMI, brings the ESP-01 up as a TCP
server, and answered **11 of 12 DZRP conformance checks on hardware** on 2026-08-05 — including
resuming a debuggee. The results are at the bottom of this page, with the numbers.

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

Power on, let NextZXOS boot, then **press the NMI (M1) button once**.

Record what happens on screen — this is observation, not decoration, and the script cannot see any
of it:

| # | Observation | Why it matters |
|---|---|---|
| **S1** | Does the stub's UI appear at all? | The first hardware evidence that Multiface paging, the relocation of `MAIN` into a RAM bank at slot 7, and `show_ui` work on silicon. In the emulator this is bench T6 |
| **S2** | What does `Core:` read? | The stub compares it against 03.01.10 and raises `ERROR_CORE_VERSION_NOT_SUPPORTED` below that |
| **S3** | Is the **error area** (bottom 9 rows, red on black) clear? | `RX Timeout` there means the AT chain failed — that is still the message, because bring-up failure has no error code of its own. `No WiFi address` means the chain worked and the module has no address to give out |
| **S4** | What do rows 6 and 7 say? | The status block, and the one thing on this screen composed at run time. `Connect at <ip>:11000` is the success case; `No WiFi address...` and `ESP-01 setup failed...` are the two failures, each in words rather than a code. **Confirmed correct on hardware 2026-08-05** at a 15-character address — the length the parser used to refuse, and one jnext can never produce. A green bench run does not cover this: `AT+CIFSR` failing leaves a working listener, so every check can pass while this line reads `No WiFi address` |
| **S5** | Does the machine return to a usable NextZXOS? | The ESP holds the listening socket, so the listener should survive normal use of the machine |

**Photograph the screen.** It is the only artefact of S1-S5 and it costs nothing.

## Step 4 — run the bench from the PC

    make test-hardware NEXT_IP=192.168.1.42

| Check | What it asserts |
|---|---|
| **H1** | Something is listening on `<ip>:11000` |
| **H2** | DZRP conformance — delegated to `conformance.py`, not reimplemented. **Its coverage is the suite's**, which now includes C10/C11, the resume checks — so a passing H2 means a debuggee was resumed on whatever this was pointed at |
| **H3** | The `+IPD` connection id is **read from the header**, not assumed |
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

### H3, and precisely what it does and does not establish

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

## Step 5 — report

Save the whole run, and send it with the photograph from step 3:

    make test-hardware NEXT_IP=192.168.1.42 2>&1 | tee hardware-run.txt

Worth recording alongside it: the **core version**, whether the Next was **power-cycled** since
WiFi was configured (which is the only way to test that association really does persist), and
anything the screen said.

## What a green run does NOT establish

Stated here because the temptation to over-read the first hardware success will be considerable.

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
- **The stackless-NMI *return address*, in either place.** This one survives the paragraph above
  intact, and the distinction is narrow enough to be worth spelling out: C10 sets `PC` itself with
  `CMD_SET_REGISTER`, so `backup.pc` never comes from `save_nmi_return_address`, the routine that
  reads NR `0xC2`/`0xC3`. Reaching it needs an M1 press taken while the debuggee is *running* —
  a second NMI landing after a `CMD_CONTINUE` — which no test anywhere performs. §3.4 of the plan
  is clear that this is the half that matters, because without it entering the debugger corrupts
  the program being debugged. **Hardware is the right place to close it**, because the timing race
  that makes it unschedulable under a frame-counting emulator does not exist when a human presses
  the button.
- **AltROM on hardware.** It is exercised in the emulator by C10 — the fixture's breakpoint is an
  `RST 0`, which reaches the debugger only through the code `copy_altrom` installs at
  0x0000/0x0066 — but nothing has run under a patched ROM on a Next.
- **DeZog itself.** The evidence is a conformance suite, not a debugging session. Stepping and
  breakpoints over WiFi are untried; `remoteType: "cspect"` with `hostname` is the configuration to
  try, and Appendix B of the plan carries the `launch.json`.
- **The UART build**, which needs a joy-port cable and a USB serial adapter. The conformance suite
  reaches it directly when someone has that set up:

      make test-dzrp REMOTE=serial:/dev/ttyUSB0:921600

- **Interleaved commands.** H3's two exchanges are sequential. Whether a reply can be flushed to
  the *wrong* connection because a second command arrived and moved `esp_conn_id` first is a
  property of our own buffering, not a hardware fact, and this bench deliberately does not conflate
  the two.
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
| DZRP conformance | emulator only | **11 of 12 on hardware**, the one red being `CMD_PAUSE` (issue #8, since fixed — not yet re-measured on a Next) |
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
