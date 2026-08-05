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
- **The Next's own screen — but only for as long as nobody reads it over the wire.** While the
  debugger is stopped `cmd_init` maps 8K banks 10 and 11 at 0x4000 (`commands.asm`), which is 128K
  bank 5: the display file the ULA is showing, and the one `ula.print_char` writes to. So
  **`CMD_READ_MEM 0x4000,6912` fetches the stub's own screen**, and the S1-S5 observations in step 3
  could be assertions in this bench instead of a photograph and a human. Nobody has written that.
  Until somebody does, S1-S5 are recorded by hand and the photograph is their only artefact.
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
