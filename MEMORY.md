# MEMORY.md — decision log

Architecture, logic and format decisions, newest first. Each entry: what was
decided, why, and what was rejected. Read this at the start of every session.

---

## 2026-08-04 — WiFi is a prerequisite; the stub holds no credentials

**Decided (user).** In WiFi mode the stub assumes the Next is **already
associated** and will never put it there. It sends no `AT+CWJAP`, stores no
SSID and no passphrase, and only *verifies* that it has an address
(`AT+CIFSR`), reporting clearly on screen when it does not.

The user satisfies the prerequisite once with `/apps/wifi/setup/wifi2.bas`,
the wizard on the NextZXOS SD card, and the ESP-01 keeps the credentials in
its own flash. Documented exhaustively in [doc/WIFI-SETUP.md].

**Rejected: storing credentials in the ROM.** The user's first instinct was to
put them "in the ROM itself", which was a reasonable reading of the constraint
below, and the user then reversed it. **Two reasons, each sufficient on its
own:**

1. **A passphrase in a ROM is cleartext on a removable card.**
   `enNextMf.rom` is a file that gets copied, backed up and mailed to us with
   bug reports. Every copy would be a credential leak, readable by any program
   on the machine. Obfuscation would be theatre.
2. It would need a patch path — a host tool or mfselect — to be usable at all,
   because otherwise changing network means reassembling the ROM.

A third argument — that it buys nothing, because the module persists its own
credentials and auto-reconnects — is **deliberately not counted**, because it
rests on the one thing this entry admits is unverified (see the closing
paragraph). A draft of this entry listed it as a third *sufficient* reason
while flagging the same claim as unmeasured thirty lines below, which is the
contradiction the reviewer caught. **If a reason depends on something we have
not measured, it is not sufficient**, and the decision does not need it.

**The constraint that made "in the ROM" look necessary, and it is real.** The
stub **cannot read the SD card**: nothing in `src/` opens a file, and the only
`rst 8` is inside `MF_BREAK` in `macros.asm`, a macro upstream disabled as
"did not work for me". Nor could it safely — it is an NMI handler running with
the debuggee's banks paged arbitrarily and NextZXOS possibly mid-operation, so
the esxdos API needs guarantees the NMI path cannot make. **So there is no
config file, and with credentials rejected there is nothing that needs one.**

**Consequence for M1, and it is not small.** Bring-up must *check* association
and fail loudly rather than hang or draw a connect string with no address
behind it. That is plan §M3's "clear failure reporting on the Next's screen",
pulled forward to M1 because without it a Next that was never put on WiFi
presents as a broken debugger.

**Measured while writing this up** (jnext 0.99.118, `--esp`): `wifi2.bas` runs
in the emulator and its **read-only half works** — firmware, SSID and IP are
reported — while its **configuring half does not**, because jnext implements
`AT+CIPDNS_CUR?` but not `AT+CIPDNS?`, and none of `CWLAP`, `CWJAP=`,
`CIPSTA=`, `CWDHCP=` or `CIUPDATE`. That is the correct half for us: we only
ever verify. Credentials can only be set on hardware, which is consistent with
this being a prerequisite rather than a feature.

**One prediction was wrong and is worth keeping.** A static trace of the
wizard's commands against jnext's dispatch table said it would die at startup
on the unimplemented `AT+CWMODE=1`. It does not — unknown commands answer
`ERROR` and the wizard shrugs them off. Running it is what showed that.

**Still inferred, not measured:** that the ESP persists credentials across a
power cycle. It is standard ESP-AT behaviour, jnext cannot answer it, and if a
real Next needs re-association at every boot the setup story changes from
"once per machine" to "every boot". First thing to check on hardware.

[doc/WIFI-SETUP.md]: doc/WIFI-SETUP.md

---

## 2026-08-04 — ROM identity is a magic string; the CRC keeps only integrity

**Decided (user), issue #4.** Every `enNextMf.rom` carries a magic string at a
fixed offset, and mfselect uses it to answer "is this ours?". The string, and
its shape is the user's:

    DeZoGiFnG_UART_0001        DeZoGiFnG_WIFI_0001

prefix + transport variant + a four-hex-digit build number from a new
`version.yaml`, bumped by `make bump`, one bump per merge to `main`.

**The two questions that were being conflated.** *Identity* — is this ours,
and which variant — is now the magic. *Integrity* — did these bytes land
intact — stays the CRC in the `.sum` files, which is what it was always good
for. Nothing about the post-copy verification changed.

**Why this was a bug and not a tidy-up, which the first draft of the issue
undersold.** `BUILD_TIME` is stamped into every ROM, so the CRC changes on
*every build*. mfselect's first-run guard — the one that refuses to save
**our** ROM as the user's `original.rom` — was a checksum comparison against
`dezogif.sum`. The moment a user upgraded the stub, the installed ROM and the
`.sum` beside it came from different builds, the comparison failed, the guard
fell silent, and mfselect captured the debug stub as the stock Multiface ROM
with no copy of the real one left on the card. Same shape as the `CREAT_TRUNC`
defect in [[ERRORS.md]]: a guard defeated through a door nobody had checked.

**Proved by reverting it, not by argument.** Bench check **M6** ships a
deliberately stale `dezogif.sum` against our ROM — what an upgraded card looks
like — and requires the guard to hold. With the old checksum guard restored,
**M4 still passed and M6 failed with `original.rom` overwritten by our ROM**.
So M4 could never have caught this, and M6 earns its place.

**Design points worth keeping.**

- **The offset is a permanent contract**: ROM file offset `0x1FE0`, address
  `0xFEA0`. It is the *end* of an image whose size the firmware fixes at 8192,
  chosen because it cannot drift as the code grows. An `ASSERT` in `main.asm`
  fails the build if the debugger grows into it — which also closes a latent
  hole, since the existing assert permitted `0xFF00`, past even the end of the
  region `SAVEBIN` writes.
- **Match the prefix and the variant, never the build number.** Matching a
  per-build value is precisely the fragility this removes.
- **The build number is not derived from `BUILD_TIME` or the git hash**, and
  that is deliberate: `make check-reproducible` must keep passing, so identity
  must not change on every build.
- **An unrecognised variant reports as ours-but-unnamed**, not as UART.
  Guessing would be a false statement about the ROM on the card, which is the
  class of thing this block exists to stop.

**Rejected.** A separate variant *byte* alongside a shorter magic (the user
specified the variant inside the string, and one readable token in a hex dump
beats two fields); putting the block at the ROM's *start*, where the RST
vectors live and where any offset would move as code changed; keeping the
checksum as a second identity check (it cannot be one — it is wrong after
every build, so it could only ever veto a correct answer).

---

## 2026-08-04 — M0(b) first, and M0(a) is off the critical path

**Decided, and it reorders the plan.** M1's WiFi half starts with the **M0(b)
spike** — the ESP brought up as a TCP server in a standalone fixture — and not
with `transport_esp.asm`. Landed as `test/esp_server.asm` + `make test-esp`.

**Why the spike rather than going straight at the transport.** Two unknowns
would otherwise be debugged at once: the AT/`+IPD` protocol, and the
debugger's own constraints. The second is not hypothetical —
`transport_wait_rx` runs with layer-2 read/write possibly mapped and therefore
**no CALLs and no PUSH/POP** (`transport_uart.asm`), which is a bad place to
first meet a framing bug. Plan §9 already said this ("it isolates 'is the ESP
path alive at all' from 'is my `+IPD` parser right'"); the only new thing is
that jnext#210 made it runnable headless, so it costs one bench target instead
of a hardware session.

**The spike is not throwaway, and that is what settles the cost question.** It
is a permanent bench check whose assertions are on **bytes over a socket** —
the first in this repository that are. Every other layer judges pixels or
files, and ERRORS.md already records a pixel check that could not tell success
from noise.

**M0(a) is DROPPED — decided by the user, 2026-08-04.** An earlier version of
this entry called it "deferred, not rejected on merit". The user's call is that
it is scratched definitively, and the justification is that it was never work
worth scheduling in the first place:

1. It spikes a **client**-mode transport (`AT+CIPSTART` + `AT+CIPMODE=1`), and
   §4.2 settles that the Next must be a **server** because DeZog always dials
   out. A client-mode Next needs a PC-side relay nobody intends to write.
2. Its only value — answering "is the ESP path alive at all?" cheaply and
   separately from "is my `+IPD` parser right?" — was collected by (b) on its
   way past.
3. It cannot run here regardless: it needs `AT+CIPMODE`, which jnext does not
   implement and deliberately will not, because server mode forbids
   passthrough.

So **M0 is complete**, and (a) is not outstanding work. If server mode ever
fails on real hardware, §4.2's fallback is where that contingency lives — a
paragraph in the transport section, not a milestone anyone is tracking.

**What M0 did NOT establish is hardware**, and dropping (a) does not change
that either way: (b) and (c) both ran in jnext, so the section's original "on
real hardware" wording is unsatisfied by either of them. That gap is M1's.

**What the bench established, by breaking it on purpose rather than by
argument.** With the `+IPD` connection id hardcoded to `0` — the value the
Espressif documentation leads you to expect — **E2 gets an empty reply**: no
error, no data, exactly the signature the jnext-inbound-id entry below
predicts. With it hardcoded to `1`, E2 and E3 **pass** and only E4 fails. So E4
(a second simultaneous connection) is the only check that catches an id that is
assumed rather than read, and it earns its place.

**One correction from that run, because the first reading of it was wrong.**
The id-`0` control also failed E3 and E4, and the obvious story — the guest had
parked in its failure loop, so it refused the second connection — is false. The
ESP listener lives in the **emulator**, not in the guest, so a wedged guest
refuses nothing. What actually happened is that the jnext run is bounded in
**frames**, not in wall clock, so the process exits while the guest is still
silent — the client's pending read then ends on **EOF** as the socket is torn
down, and the next connection is refused because nothing is listening any more.
The failures after E2 were an artefact of the harness, not evidence.

Note the timeouts do *not* elapse, and the first correction to this paragraph
said they did: the whole failing run takes ~9 s, where two 20 s timeouts alone
would need 40. Measuring it is what showed that; reasoning about it produced
the wrong mechanism **twice in a row**, once in each direction. The client now
labels a silent guest instead of presenting the cascade as three independent
findings.

**Two divergences the emulator cannot show, written down before they bite.**

- **Association.** jnext has no `AT+CWJAP=` at all, only the query form, so the
  emulated module is permanently on a network. Hardware is not, and the stub
  will need a bring-up path the bench can never exercise.
- **Baud.** jnext models baud as *timing* only, so the fixture would have
  passed at any rate. It is pinned to **115200** anyway — what a real ESP-01
  answers at until told otherwise — because a value that only works in the
  emulator is precisely the kind of thing that passes CI and fails on the
  bench-top. Upstream's 921600 is a *joy-port cable* rate, where both ends are
  ours to choose; the ESP's is not. Raising it is M3's baud negotiation and
  must start by talking at 115200.

**Rejected.** Writing `transport_esp.asm` first and testing it through
`make test-dzrp` (two unknowns at once, and the harness has never run against
our stub either — [[#DZRP's two length conventions]]); folding this into
`make test` (it needs a concurrent client and binds a host port, so it cannot
keep that suite's no-external-dependencies promise); asserting on the
fixture's border colour (the socket checks are strictly stronger, and a check
that cannot fail independently is noise — the border stays as *diagnosis*, to
name which step stopped).

---

## 2026-08-04 — DZRP's two length conventions, and where 0xA5 really comes from

**Found by the DZRP conformance suite** ([issue #2]) on its first run against a
reference remote, which is what the suite was built for.

**1. The two directions use different length conventions.** A *command*'s
length counts the **payload only**; a *response*'s counts **from the sequence
byte**. DeZog's spec says exactly this in two tables whose wording differs by a
clause. Sending `CMD_INIT` with a symmetric length produced no reply at all —
the remote sat waiting for two bytes it thought it was owed. The cost of
assuming symmetry is a silent hang, not an error. Confirmed three ways by the
reviewer: our own stub's send and receive paths, DeZog 3.7.4's `sendDzrpCmd`,
and CSpect.

**2. `0xA5` is a documented DZRP extension for the serial link — NOT a leak.**
The first version of this entry called it "a serial artefact that leaks into
`message.asm`" and said "nothing here establishes why the zero noise required
it, only that the comment says so". **Both statements were wrong**, and the
source that disproves them is `doc/legacy/Design.md:30-31`, a file CLAUDE.md
lists as required reading:

> the DZRP protocol was extended by one byte which is sent as first byte of a
> message (only in direction from ZX Next to PC). This is the
> MESSAGE_START_BYTE (0xA5). DeZog will wait on this byte before it recognizes
> messages coming from the Next.

The why is the paragraph above it: a game that grabs the joy port leaves the
Next emitting endless zeroes, and the preamble is how DeZog resynchronises.
DeZog implements the split itself — `ZxNextSerialRemote` strips byte 165,
`CSpectRemote` does not (verified against the installed DeZog 3.7.4,
`~/.vscode/extensions/maziac.dezog-3.7.4/out/extension.js`; both classes
identify themselves by their own log strings, which survive minification).

**So M1's answer is settled, and it is the opposite of "remove it".** The
preamble is **required in UART mode and must be absent in WiFi mode**, which
makes it a property the *transport* contributes — the fourth thing the
assembly-time switch selects, after the byte stream, the lifecycle and the UI.
An earlier draft listed "drop it in both modes and see whether the serial path
needed it" as an option to try; that would have broken interoperability with
DeZog's real `zxnext` remote, i.e. exactly the UART regression CLAUDE.md's hard
rule exists to catch.

**How the error happened, because it is the repeating one.** The claim was
derived from the DZRP spec plus one socket remote, without reading the
project's own frozen upstream design doc. [[ERRORS.md]] already carries an
entry for this shape — deriving a hardware fact instead of reading the VHDL —
and this is the protocol-side repeat. Caught by the independent reviewer, not
by the author.

[issue #2]: https://github.com/jorgegv/dezogif_ng/issues/2

---

## 2026-08-04 — The stub is alive: first liveness evidence, bench T6

**Measured, not decided.** With jnext 0.99.118's `--delayed-nmi`, a real M1
button press against our own `enNextMf.rom` makes the stub **take over and
paint its UI: 90.28% of the screen repainted**, against the stock Multiface
monitor's 91.41%. Now bench check **T6**.

**Why this matters more than the number.** Every check this bench had proved a
*negative*: it assembles, it does not perturb the boot, it correctly ignores a
software NMI. None of them would have failed if the stub had been incapable of
running at all. T6 exercises, in one run, Multiface paging, the relocation of
`MAIN` into a RAM bank at slot 7, `show_ui`, and the core-version check passing
against core 03.02.03.

**It answers plan §8.3 for the entry path, and only that.** That section
proposed dropping upstream's released ROM onto a jnext SD image as third-party
validation of jnext's Multiface/AltROM/stackless-NMI implementations, before
writing new Z80 code. Our own build coming up is the same evidence for
**Multiface paging and the entry side of stackless NMI**. It is *not* evidence
for AltROM or for the return-to-debuggee half — see the scope limit below. An
earlier draft of this entry said "retires §8.3" flatly; that was the same
overclaim, one paragraph up from where I had just corrected it.

**T6 did not replace T4, and both CLAUDE.md and the plan said it would.** That
was wrong and is corrected in both. The two send **different causes** to the
same check in `nmi66h`: T6 a button press, which it accepts; T4 a software
NR `0x02` write, which it rejects. Deleting T4 would have thrown away the
regression check M2 is required to invert when it teaches `nmi66h` to accept a
software cause — the check would have vanished on the day the button arrived,
and nobody would have noticed until M2 broke something silently.

**What T6 does not cover — larger than the first draft of this entry admitted,
and the reviewer had to point it out.** That draft said only that a *second*
press after a resume was untested, which implies the first resume was covered.
It is not. **T6 never resumes at all.** No DZRP client attaches, so the stub
idles in `main.asm`'s `main_loop`, whose `transport_byte_available` poll is a
status-bit read returning immediately; with no byte ever arriving its
`jp nz,cmd_loop` never fires, so `cmd_loop` — and the blocking
`transport_wait_rx` inside it — are never reached at all, and the run ends on
the frame limit. Nothing past "the debugger came up" executes: not the exit
path, not `backup.asm`'s restoration, and not the **return-to-debuggee half of
stackless NMI** — the half plan §3.4 says actually matters, because without it
entering the debugger corrupts the program being debugged. Of stackless NMI,
T6 exercises the **entry side only**.

So the Appendix A row is scoped to that, and the honest summary is: the stub
comes up. Not "the NMI path is sound".

**A green T6 still cannot tell a takeover from a crash**, because it is a
pixel-difference measure and does not know what it is looking at — the lesson
already in [[ERRORS.md]]. One failure mode is now excluded automatically: T6
also requires the result to look *unlike* the stock Multiface monitor, which
catches "our ROM was not actually installed". A crashed machine would still
pass, so the screenshot remains the artefact to inspect.

**Two rounds of review were needed to get this paragraph right, and the second
correction was to the mechanism, not the conclusion.** The first version of it
claimed `cmd_loop` blocks on `transport_wait_rx`. It does not — `cmd_loop` is
never entered. That wrong mechanism had been asserted confidently, propagated
into four files, and was caught only by someone tracing `main.asm:154-191`
against the source. It is the failure ERRORS.md already names: a plausible
mechanism stated instead of a traced one.

**Also fixed while here.** The bench's summary line was hardcoded `5/5` and
would have kept saying so after a sixth check was added — a small lie in
exactly the place a reader trusts. It is derived now.

---

## 2026-08-04 — Merging to `main` is standing-authorized; pushing still is not

**Decided (user), 2026-08-04.** The manager session may merge to `main` without
asking each time, on four conditions, all of which must hold:

1. the issue or task is **finished**;
2. the branch is **ready**;
3. it has been **independently reviewed** by an agent that did not write it,
   with a binary APPROVE;
4. it has been **validated** at the highest testing layer that applies.

Short of all four, ask.

**What this does not change, and the distinction is the point of writing it
down.**

- **Pushing is still per-request, every time.** The entry below records that a
  push was authorized on 2026-08-04 and that it was not standing; this grant
  does not quietly extend it. A merged `main` sits local until the user asks
  for a push. Two permissions, granted separately, still separate.
- **Spawned agents still never write to `main`**, and
  `DEZOGIF_ALLOW_MAIN_WRITE=1` is not theirs to set. The grant is to the
  manager doing the merge, which is already how §Merging step 4 assigns it.
- It is not permission to edit `main` directly. Step 1 — dedicated branch and
  worktree, never edit `main` — is untouched.

**Why record it rather than just act on it.** The failure mode this project
already warns about is a future session reading history and inferring a
permission nobody granted. An unexplained run of merges in the log invites
exactly that; so does a standing grant that quietly grows to cover pushing.
Both are now written down with their edges.

**House form.** `git merge --ff-only` is the default, and a conflict means
rebase or resolve deliberately rather than silently minting a merge commit.

(This entry originally justified that with "`main`'s history is linear — no
merge commits before today". That was already untrue when written: `857a1df`
is a merge commit. The rule stands on its own; the false premise is removed
rather than the conclusion.)

---

## 2026-08-04 — mfselect is z88dk C, and its first run is guarded

**Decided (user).** `mfselect` — the on-Next switcher between the stock
Multiface ROM and ours ([issue #1]) — is written in **z88dk C**, not sjasmplus,
and assumes NextZXOS is present at all times.

**Why this does not contradict the sjasmplus decision below.** That decision is
about the *stub*, and its reason is specific: DeZog cannot do banking with
z88dk, and the stub is nothing but banking. mfselect is a standalone NextZXOS
utility DeZog never sees, so the constraint does not reach it. z88dk also ships
the esxdos API bindings (`esx_f_open`/`read`/`write`/`stat`), which removed the
one genuine unknown — the `RST $08` calling convention — from the task. The
stub stays sjasmplus.

**The design decision worth keeping, and it is not the language.** The obvious
first-run rule — "no backup yet, so save whatever is installed as the original"
— **destroys the stock ROM for exactly the people most likely to run this
first**. Anyone who followed Appendix B.1 step A3 already has *our* ROM at the
official path; capturing that as "the original" labels the debug stub as the
stock Multiface ROM and leaves no copy of the real one on the card. So the
capture refuses when the installed ROM matches `dezogif.sum`, and asks before
capturing anything else — "not ours" is not proof of "stock". Bench check M4
asserts the refusal, answering Y anyway to prove the guard fires before the
question.

**Consequences that shaped the rest.**

- The guard needs our ROM's checksum, and it is read from `dezogif.sum` **at
  run time**, not compiled in. `BUILD_TIME` is stamped into the ROM, so every
  build changes it; a compiled-in constant would silently stop matching the
  moment the stub was rebuilt. The `.sum` is a *build* product for the opposite
  reason: computing it on the card would bless an already-corrupt file.
- CRC-16/CCITT, in two independent implementations (`tools/romsum.py` on the
  host, `crc16()` on the Next). Bench check M2 requires them to agree — the
  `.sum` files are worthless if they do not.
- Every install reads the copy back and re-checksums it. A short write on a
  tired card is the failure this must not hide.

**Not decided.** Whether a soft reset suffices instead of a power cycle. The
on-screen advice says power-cycle, which is safe either way, but nothing has
established that a soft reset is insufficient. It is a tbblue firmware
question, so the project's "read the VHDL" rule gives no answer.

**Rejected.** sjasmplus (the user's call, and the banking constraint does not
apply); a compiled-in checksum constant; 8.3-unsafe names like
`enNextMf.orig.rom` from the issue draft, in favour of `original.rom` /
`dezogif.rom`.

[issue #1]: https://github.com/jorgegv/dezogif_ng/issues/1

---

## 2026-08-04 — jnext's ESP server: inbound connection ids start at 1, not 0

**Recorded from the jnext implementer**, relayed by the user 2026-08-04, about
the server mode delivered by [jnext#210]. Not a decision of ours — a constraint
we have to build against, written down before it is needed.

**The fact.** Inbound connection ids start at **1**. Slot 0's transport is the
only object that can serve an outbound `AT+CIPSTART`, so handing slot 0 to a
peer would cost the guest its outbound capability. That leaves **four** inbound
slots rather than ESP-AT's five, and the numbering is visible to anything
reading `<id>,CONNECT`.

**Why this is not cosmetic.** M1's WiFi transport parses `+IPD,<id>,<len>:` and
prefixes every reply with `AT+CIPSEND=<id>,<len>`. A parser written from the
Espressif documentation would naturally expect the first inbound connection to
be id 0 — and against jnext it will never see one. The dangerous version is
worse than the obvious one: a stub that *assumes* 0 and hardcodes it will send
its replies to the outbound slot, producing no error, no data, and a debug
session that looks like a DZRP bug. Plan §10 already lists `+IPD` framing as
the risk that "looks like a protocol bug"; this is its specific shape.

**What to do.** Take the id from the `+IPD` header and echo that value back on
`AT+CIPSEND`. Never assume, never hardcode. M0(b)'s spike exists precisely to
isolate the parser, so that is where this gets proven.

**Deliberately not claimed.** Whether real ESP-AT firmware also starts inbound
ids at 1. The explanation given is a consequence of reserving slot 0 for
outbound, which is a **jnext design choice**, so hardware may well number
differently. Do not promote this to a hardware fact without measuring it — the
same mistake ERRORS.md records for the UART/ESP mux, where a plausible
derivation was exactly backwards.

[jnext#210]: https://github.com/jorgegv/jnext/issues/210

---

## 2026-08-04 — WiFi mode's UI is a connect string, not a selector

**Decided (user).** In WiFi mode the stub's screen shows a line of the shape:

    dezogif_ng remote debugger active. Connect at: 192.168.1.23:10000

**Why this closes something.** Extracting the transport interface left one
thing still leaking above it, and it was UI rather than protocol: the joy-port
selector (`uart_joyport_selection` in `data.asm`, `read_key_joyport` in
`ui.asm`, the 1/2/N key handling in `main.asm`) and the baud-rate display
(`BAUDRATE`, and the strings in `data_const.asm`). Those are meaningful in UART
mode and meaningless in WiFi mode, so the question was never "how do we hide
them" but "what replaces them". This answers it.

**What follows, for whoever implements it.**

- The two modes need *different* UI, not a shared one with blanks. UART mode
  keeps upstream's selector unchanged; WiFi mode draws a connect string. That
  makes `show_ui` a third thing the assembly-time switch selects, alongside the
  byte stream and the lifecycle — the transport interface grows a UI half.
- The IP is **not** known at assembly time. It comes from the ESP at run time
  (`AT+CIFSR`), so the string is composed, not a constant, and the ESP bring-up
  has to happen before the UI can be drawn — which orders M1's WiFi work:
  bring-up first, then UI, not the reverse.
- The port is ours to choose and belongs with the other build-time settings.
  DeZog's `cspect` remote defaults to 11000; the example above says 10000
  (ZEsarUX's). Pick one deliberately and write it in both the ROM and the
  `launch.json` example in Appendix B, because a mismatch there fails as a
  silent connection refusal.

**Port: 11000** (decided 2026-08-04). DeZog's `cspect` remote default, so a
`launch.json` that omits `port` still works. Must match Appendix B's example.

**What actually changes on that screen, read from `ui.asm` / `data_const.asm`
rather than assumed.** The connect string replaces exactly two things:

- `ESP UART Baudrate: 921600` → the connect string
- the joy-port selector — the `1 = Joy 1` / `2 = Joy 2` / `3 = No joystick
  port` key list and the "Using Joy 2 (right)" status line

Everything else on `show_ui` is mode-independent and stays: the title (minus
"UART"), the program and DZRP versions, `Video timing:`, `R = Reset`,
`B = Border`, and two that are load-bearing —

- **`Core: xx.xx.xx`.** Not decoration. `show_ui` compares it against 03.01.10
  and raises `ERROR_CORE_VERSION_NOT_SUPPORTED` below that. Stackless NMI needs
  it, and that is just as true over WiFi.
- **The red-on-black error area** (bottom 9 rows). It matters *more* in WiFi
  mode, because the connect string can only be drawn after the ESP has
  associated and answered `AT+CIFSR`. Before that there is no IP; if bring-up
  fails there never will be. The screen has to be able to say so rather than
  sit blank — plan §M3's "clear failure reporting on the Next's screen when
  the transport cannot come up", on the same real estate.

**Not decided here.** Exact wording and layout, and what the screen shows
during the window between "stub is up" and "ESP has an IP".

---

## 2026-08-04 — Pushing is authorised per request, and 2026-08-04's was not standing

**Recorded so it is not over-read later.** The user authorised a push on
2026-08-04, covering the five commits pending at that moment (through
`9ccaa93`). That was permission for that push, not a standing grant.

CLAUDE.md's rule is unchanged and still absolute: **never push without
explicit authorisation**, every time. A future session finding pushes in the
history must not infer that pushing is now routine. The same applies to
`DEZOGIF_ALLOW_MAIN_WRITE=1` — every merge to `main` in this history was
individually authorised.

---

## 2026-08-03 — The transport interface: subroutines, plus one macro

**Decided.** The seam M1 needs is `src/transport.asm`, which includes an
implementation (`src/transport_uart.asm`, upstream's serial path). The
interface is seven subroutines for the byte stream — `transport_read_byte`,
`transport_write_byte`, `transport_byte_available`, `transport_wait_rx`,
`transport_flush`, `transport_drain`, `transport_drain_with_timeout` — plus
`transport_init` / `transport_activate`, and **one macro**,
`TRANSPORT_DEACTIVATE`.

**Why a macro for that one.** Its single caller is inline in `backup.asm`'s
resume path, where a `CALL` costs bytes and a stack slot the routine does not
have. As a macro it also expands to *nothing* in a transport with nothing to
hand back, which is what an assembly-time mode switch should do. Subroutines
everywhere else, because upstream already paid for the `CALL` there.

**The gate was byte-identity, and it held.** With `BUILD_TIME` pinned,
`enNextMf.rom`, `main.bin` and `mf_nmi.bin` are byte-for-byte identical before
and after — the whole change is label renames, an include split and one macro
that expands to the instruction it replaced. That is the strongest available
evidence that a refactor of ~60 call sites across eight files changed no
behaviour, and it is worth preserving as the standard for the next one.

**What still leaks, and it is not what I expected.** After the extraction,
`commands.asm`, `message.asm` and `breakpoints.asm` — the three files
CLAUDE.md's rule names — are clean. What remains is **UI**, not protocol:

- `uart_joyport_selection` (`data.asm`), written by `main.asm` and displayed
  by `ui.asm`; `read_key_joyport` in `ui.asm` — the 1/2/N joy-port selector.
- `BAUDRATE` in `constants.asm`, and the on-screen strings in
  `data_const.asm` ("ZX Next UART DeZog Interface", "ESP UART Baudrate: ").

Deliberately **not** resolved tonight: what WiFi mode shows instead of a
joy-port selector is a design question (an IP address and a port, presumably)
and improvising it at 1am would produce the wrong shape. It is the next
decision M1 needs, not a leftover.

**Not done, still deliberately.** No `-DTRANSPORT=…` switch. `transport.asm`
is where it goes and says so, but with one implementation a switch can only
select that one; the reasoning in the entry below still applies.

---

## 2026-08-03 — Renamed `dezogif_esp` → `dezogif_ng`

**Decided.** The project is `dezogif_ng`. Documentation and `.claude/` config
were renamed; **the Z80 sources were deliberately not touched.**

**Why.** `_esp` named a transport, and the transport turned out to be one of
two build modes rather than the identity of the fork ([[#Two build modes]]).
`_ng` names the relationship to upstream instead, which is what actually
distinguishes this project and does not go stale when the transport story
changes again.

**What did not change: the sources.** No string in `src/` carries the project
name in a way a user sees, and churning 8,600 lines of mostly-upstream
assembly for a rename would cost every future `git blame` against
maziac/dezogif for nothing.

**The move, completed the same day.** The GitHub repo, the `origin` remote,
the checkout on disk and the auto-memory directory were all renamed by the
user; the three stale strings left in `.claude/` (WORKTREES.md's layout and
"stay in the worktree" rule, worktree-launch's briefing footer, handover's
memory path) were flipped, and the paragraph explaining the name/path mismatch
was deleted rather than reworded, because it only existed while they disagreed.

**Two things worth knowing from doing it.**

- The **auto-memory directory** was the item flagged as a data-loss risk,
  since Claude Code derives its name from the on-disk path and a move points
  it at a new, empty one. In the event nothing was lost: that directory had
  never had a `memory/` subdirectory, because no handover had ever been saved.
  The hazard is real and simply had not fired yet — it will, the first time
  this repo is moved after handovers exist.
- **`git worktree` registrations do not survive a move.** A leftover review
  worktree's `.git` file still pointed at the old repo path, and
  `git worktree remove` refused it ("not a .git file, error code 7").
  `git worktree repair <path>` fixes the pointer and removal then works. Move
  with no worktrees registered and the problem does not arise.

---

## 2026-08-03 — Two build modes (UART / WiFi), not a transport replacement

**Decided.** The stub keeps upstream's joy-port serial transport and gains an
ESP-01 WiFi one beside it. The mode is chosen **at assembly time**; one mode
per ROM.

**Why.** The serial path works today and costs nothing to keep. It is the
answer for a debuggee that owns the ESP itself — the ESP-contention risk in
plan §10 stops being a limitation and becomes a build choice. It also keeps
upstreaming plausible, since upstream's own transport is still there.

**Consequence, and it is the useful part.** The transport interface is now
load-bearing rather than tidy: `commands.asm`, `message.asm` and
`breakpoints.asm` must be assemblable against either mode without knowing
which. **That makes the UART build a free regression check on the
abstraction** — if a change breaks serial mode, the ESP assumptions leaked.
M1's success criterion now has two halves, WiFi working *and* UART still
equivalent to upstream.

**Not done yet, deliberately.** No `-DTRANSPORT=…` switch, no second Makefile
target, no stub `wifi.asm`. There is no WiFi code to select between, and
scaffolding ahead of the thing it scaffolds is how the switch ends up shaped
wrong. This entry records the decision; M1 implements it.

**Rejected.** Replacing the serial transport outright (the original plan, and
what every document said until now); carrying both modes in one ROM, selected
at runtime. The second was rejected on complexity — a runtime switch buys
nothing a rebuild does not, and it puts a branch in the hot path of every
transport call. A capacity argument is *available* but has not been made: the
~3.3 KB free is measured (`main_end` 0xF1B6 to image end 0xFEC0), the size of
an AT-command stack is not, because none has been written. Do not cite the
budget as though it settled this.

---

## 2026-08-03 — The combined work is GPLv3; upstream's MIT notice is kept

**Decided.** `LICENSE` is the GPLv3 text and covers this project as a whole.
Upstream's MIT licence moved to `NOTICE`, unchanged, with a header explaining
the relationship.

**Why.** MIT is GPL-compatible in one direction: a derivative may be
distributed under GPLv3 provided the MIT notice is preserved. Keeping the
notice in `NOTICE` satisfies that, and aligns this project with jnext, which
is GPLv3.

**Consequence, and it is not small.** Contributing the transport back to
dezogif — §6 of the plan, and milestone M4 — is now a *licensing* problem as
well as a technical one, because GPLv3 code cannot be merged into an MIT
project. Anything genuinely intended for upstream has to be written with the
intent of offering it under MIT too, decided at the time it is written.

**Rejected.** Dual-licensing the whole repo (complexity with no demonstrated
need); staying MIT (the user's call, and GPLv3 matches the rest of the
workspace).

---

## 2026-08-03 — Continue in this fork; do not start a new repo

**Decided.** Keep `dezogif_ng` as a fork of maziac/dezogif (359 upstream
commits, last 2023-06-13) and adapt it, rather than starting a fresh project
that borrows ideas.

**Why.** It builds clean today (0 errors, 0 warnings, 8192-byte ROM) with the
sjasmplus already on this machine. The upstream history is the only existing
documentation of *why* the memory choreography is shaped the way it is, and
~2,600 lines of Z80 unit tests come with it. Adding a second transport is
genuinely localised: `read_uart_byte`/`write_uart_byte` have ~60 call sites but are two
functions, and every DZRP response already computes its length up front
(`send_length_and_seqno`), which is exactly what `AT+CIPSEND=<id>,<len>`
needs. ~3.3 KB of the 8 KB ROM is free (`main_end` 0xF1B6, image ends 0xFEC0).

**Rejected.** A new repo: it would discard the history and the tests and buy
nothing — MIT imposes no obligation beyond the attribution we keep anyway.

---

## 2026-08-03 — sjasmplus, not z88dk

**Decided.** The assembler stays sjasmplus. This is not a preference.

**Why.** DeZog's own `documentation/Usage.md:505`: "Although z88dk can create
object code for banked memory, the .map and .lis files lack this information.
As a consequence, DeZog can not use any banking with z88dk." This stub is
nothing but banking (slot 6 SWAP, slot 7 MAIN, AltROM, MMU), and the SLD
format that carries bank info is sjasmplus-only. Verified against the
installed DeZog 3.7.4.

**Rejected.** z88dk (the usual toolchain elsewhere in this workspace) —
foreclosed by the client, not by taste.

---

## 2026-08-03 — Testing is local, headless, jnext; no CI service, no VS Code

**Decided.** `make test` runs jnext headless and judges screenshots. No
GitHub Actions, no VS Code or DeZog in the loop.

**Why.** A hardware-targeted stub can never have a hosted CI, and the DeZog
unit-test path needs VS Code driving zsim, which is not automatable here.
What *is* automatable is: does it assemble, is the ROM 8192 bytes, is the
build reproducible, does the ROM boot, does the stub take the screen on NMI.

**Rejected.** GitHub Actions (nothing to gain, sjasmplus + a 1 GB SD image to
provision); leaving `src/unit_tests/` as the only test layer (it cannot run
without VS Code, so it gates nothing).

---

## 2026-08-03 — Headless NMI is the software NMI, not the M1 button

**Decided.** `test/nmi_trigger.asm` enters the stub by writing NR `0x02`
bit 3 from guest code, after setting NR `0x06` bit 3.

**Why.** jnext exposes the M1 button only as the F9 *host* key, so
`--delayed-keypress` (which injects Spectrum membrane keys) cannot reach it.
`zxnext.vhd:3832` makes a CPU write of NR `0x02` bit 3 an MF NMI source, and
`zxnext.vhd:2090` ANDs every MF NMI source with NR `0x06` bit 3, whose
power-on value is 0 — though NextZXOS leaves it set, so a guest inherits it
(measured 2026-08-04; see [[ERRORS.md]], which used to credit that gate with a
failure dezogif's own cause check had caused).

**Consequence for the design.** §3.3 of the plan claimed the Copper NMI was
"ungated". It is not. M2's Copper break must set NR `0x06` bit 3 itself and
cope with the debuggee clearing it. The plan has been corrected.

**Rejected.** Driving the GUI with xdotool (unreliable under Wayland); asking
for a jnext CLI flag before proving we need one.

**What it exposed.** The stub does not respond to that NMI, and the reason is
in `mf_rom.asm` `nmi66h`: it reads NR `0x02`, masks `00011100b` and returns
unless the result is zero — *button presses only*. NR `0x02` bit 3 reads back
as `nr_02_generate_mf_nmi`, latched by `zxnext.vhd:3843-3848` on any accepted
bit-3 write and cleared only by an explicit write of bit 3 = 0. So a software
NMI is filtered by design, and the bench's T4 asserts the decline. **M2's
Copper break hits the same gate** (`nmi_gen_nr_mf` covers CPU and Copper
alike, `zxnext.vhd:3832`), so M2 must modify `nmi66h` and invert T4 in the
same change. Found by the independent reviewer of this branch, not by the
author.

---

## 2026-08-03 — Build directory is `build/`, Makefile is semantic

**Decided.** `out/` → `build/`; bare `make` lists targets; the two output
paths in the sources come from the Makefile as `MAIN_BIN` / `MF_NMI_BIN`.

**Why.** Project convention (jnext). The old main target was
`out/dezogif.nex`, a file no build has ever produced, so make re-assembled
everything every time.

**Rejected.** Adding a `SAVENEX` to `main.asm` to make the `.nex` real — the
deliverable is the ROM; a NEX of the debugger has no consumer.

---

## 2026-08-03 — Worktrees live under `~/tmp/worktrees`

**Decided.** Agent worktrees go to `~/tmp/worktrees/dezogif_ng/<name>`.

**Why.** User instruction, 2026-08-03. Never inside the repo (that was the
old `.claude/worktrees/` layout inherited from jnext's docs, which also
contradicted CLAUDE.md's own rule).
