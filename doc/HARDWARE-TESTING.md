# Testing on real hardware

    make test-hardware NEXT_IP=192.168.1.42

**Nothing in this project has ever run on a ZX Spectrum Next.** Every result the repository holds
was produced inside jnext. This page is the procedure for changing that, and `test/hardware-check.py`
is the part of it a PC can do by itself.

Read it end to end before starting. Most of it is about what to *observe*, because the majority of
what hardware can tell us is not reachable over a socket.

## Why an emulator result is not enough

jnext is good enough that the stub was developed entirely against it. Three of its divergences are
known, and all three are in the exact area the WiFi build depends on:

| Divergence | Consequence |
|---|---|
| It models **baud as timing only** | The stub's 115200 would have passed at *any* rate. That the real ESP-01 answers at 115200 until told otherwise is filed in the plan's Appendix A as **inferred**, not verified |
| Its ESP module is **permanently associated** — jnext implements no `AT+CWJAP=` at all, only the query form | Association has never been exercised by any test and never can be. It is a prerequisite the user satisfies once; see [WIFI-SETUP.md](WIFI-SETUP.md) |
| It numbers inbound connection ids **from 1**, because it reserves slot 0 for outbound `AT+CIPSTART` | That is a **jnext design choice**, and MEMORY.md said outright that hardware may number differently. It does: **real firmware assigned the first client id 0**, measured 2026-08-04 by the WiFi build failing completely on a Next. The stub had used `esp_conn_id == 0` as its "no client" marker, so every reply was discarded — see ERRORS.md and H3 below. Fixed by reserving no id at all. **No emulator check can cover this in either direction**, because jnext never issues 0 |

Two more claims are **estimates** — arithmetic, never measured. H4 and H5 exist to replace them
with numbers.

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

**The stub does not show it yet.** The connect-string UI is M1's last open item: WiFi mode still
draws upstream's baud line and joy-port selector, and no `AT+CIFSR` is sent, so there is nothing on
screen to read. Until that lands, get the address from `wifi2.bas` on the Next, or from the
router's lease table.

A **static DHCP reservation** on the router is worth the two minutes: the address then never moves.

## Step 3 — bring the stub up

Power on, let NextZXOS boot, then **press the NMI (M1) button once**.

Record what happens on screen — this is observation, not decoration, and the script cannot see any
of it:

| # | Observation | Why it matters |
|---|---|---|
| **S1** | Does the stub's UI appear at all? | The first hardware evidence that Multiface paging, the relocation of `MAIN` into a RAM bank at slot 7, and `show_ui` work on silicon. In the emulator this is bench T6 |
| **S2** | What does `Core:` read? | The stub compares it against 03.01.10 and raises `ERROR_CORE_VERSION_NOT_SUPPORTED` below that |
| **S3** | Is the **error area** (bottom 9 rows, red on black) clear? | `RX Timeout` there means ESP bring-up failed. That is the message bring-up failure currently produces — it is not a distinct error code, deliberately, because adding one would change common code the UART byte-identity gate protects |
| **S4** | Does the machine return to a usable NextZXOS? | The ESP holds the listening socket, so the listener should survive normal use of the machine |

**Photograph the screen.** It is the only artefact of S1-S4 and it costs nothing.

## Step 4 — run the bench from the PC

    make test-hardware NEXT_IP=192.168.1.42

| Check | What it asserts |
|---|---|
| **H1** | Something is listening on `<ip>:11000` |
| **H2** | DZRP conformance — delegated to `conformance.py`, not reimplemented |
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

- **The stub has never resumed a debuggee — anywhere.** Not on hardware, not in the emulator.
  `CMD_CONTINUE`, the exit path, `backup.asm` and the **return-to-debuggee half of stackless NMI**
  are unexecuted code. Of stackless NMI only the *entry* side has ever run, and §3.4 of the plan is
  clear that the return half is the one that matters, because without it entering the debugger
  corrupts the program being debugged. That is [issue
  #2](https://github.com/jorgegv/dezogif_ng/issues/2), and no amount of green here touches it.
- **AltROM.** Nothing has run under a patched ROM, in either place.
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

## What a green run *would* let the documents claim

Appendix A of the plan is a ladder — `verified`, `reported on hardware`, `inferred`, `estimate` —
and its rule is that a claim must never sit higher than its evidence. A hardware run moves these,
and nothing else:

| Claim | Today | After |
|---|---|---|
| The real ESP-01 answers at 115200 until told otherwise | inferred | verified, if H1 passes |
| ESP TCP throughput | estimate | measured, by H5 |
| Round-trip latency 10-100 ms | estimate | measured, by H4 |
| tbblue does not checksum `enNextMf.rom` | inferred | verified, if the ROM boots |
| Inbound connection ids on real firmware | unverified | **still unverified** — H3 cannot see them, and neither can any PC-side check |

**Update Appendix A when the run happens, and put the numbers in it.** A measurement nobody wrote
down is an estimate again by the next session.
