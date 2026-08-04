# MEMORY.md — decision log

Architecture, logic and format decisions, newest first. Each entry: what was
decided, why, and what was rejected. Read this at the start of every session.

---

## 2026-08-04 — FIRST RUN ON REAL HARDWARE: the stub comes up on a Next

**Measured, not decided.** A real ZX Spectrum Next, our WiFi ROM installed by
mfselect, M1 button pressed: **the stub takes over and paints its UI.** Core
reported **03.02.01**, above the 03.01.10 stackless NMI needs, so the version
check passed. The error area was clear.

Everything this project had ever produced ran in jnext. This is the first
evidence that any of it works on silicon, and it lands three separate results
at once:

1. **The stub runs.** Multiface paging, the relocation of `MAIN` into a RAM
   bank at slot 7, `show_ui` and the core-version check all work on real
   hardware, not just in the emulator. It also answers plan open question 2 —
   tbblue does **not** checksum `enNextMf.rom`, because ours booted.
2. **mfselect runs, on its first ever hardware outing**, and did the whole job:
   identified the installed ROM as not-ours, captured it as `original.rom`
   (**CRC 6320**), installed the WiFi build, read it back and verified it
   (**B5C6**).
3. **The stock Multiface ROM's CRC is 6320 on real hardware — the same value
   bench check M2 reports in the emulator.** So jnext's reference SD image
   carries the authentic Multiface ROM, and mfselect's on-Next CRC16 agrees
   with `tools/romsum.py` on silicon as well as under emulation. Neither was
   certain before; both were assumed.

**What this run does NOT establish, and the reason is a UI gap rather than a
doubt about the stub.** The screen **cannot tell you which build is running**.
The connect-string UI is M1's last unbuilt item, so the WiFi build still draws
upstream's UART screen — byte for byte the same screen the UART build draws.
Whether the ESP came up and is listening is therefore **not visible**, and an
observer's "it looks like it started listening" is an inference from the
absence of an error, not evidence. `make test-hardware NEXT_IP=<ip>` (check H1)
is what settles it.

**And the screen states a baud rate that is wrong for the build it is running.**
`data_const.asm` draws `BAUDRATE` unconditionally, which is upstream's joy-port
921600, while the WiFi build's UART is set from `transport_esp.asm`'s own
`ESP_BAUDRATE` = 115200 with its own prescaler table. So a WiFi ROM reports
"ESP UART Baudrate: 921600" while running the ESP at 115200. Not a functional
defect — the peripheral really is at 115200 — but the screen lies, in exactly
the place somebody would look first when the ESP misbehaves. It makes the
connect-string UI a correctness fix, not only a nicety.
---

## 2026-08-04 — the frame's length decides where a command ends, not its content

**Decided, issue #7.** `cmd_init.inner` consumes exactly the number of payload
bytes the frame declared. It used to read three version bytes by count and then
the remote's program name **until a NUL**, ignoring the length field entirely,
so a `CMD_INIT` whose length disagreed with its payload left the stream
desynchronised — silently, and for the rest of the session.

**The rule, stated once so it does not have to be re-derived per command.** The
length field is framing; the NUL is content. Content may tell a handler how to
*interpret* what it read, and must never decide how much leaves the stream.
Every other handler in `commands.asm` already worked that way —
`cmd_loopback`, `cmd_write_mem`, `cmd_restore_mem`, `cmd_write_bank`,
`cmd_exec_asm` all take their count from `receive_buffer.length` — so this was
the one place that did not, not a new policy.

**The bytes are read and dropped, and that is deliberate.** The response is
built from our own `DZRP_VERSION` and `PROGRAM_NAME`, so nothing above ever
looked at the remote's version or name; upstream stored the three version bytes
and no code has ever read them. Storing a client-chosen count into the 102-byte
payload buffer would need a bound check that buys nothing. Net effect on the
image: **one byte smaller** (`main_end` 0xF1B6 → 0xF1B5).

**Every hostile boundary the issue named falls out of that one rule, with no
special case for any of them** — which is the argument for the rule rather than
for a validator: a name filling the frame with no NUL (only the declared bytes
are taken; what follows is the client's next frame by definition); a length
below 3 (fewer than three bytes are read, so there is no over-read waiting for
version bytes nobody promised); a length of 0 (nothing is read); a length longer
than what was sent (the read blocks, and the transport's own RX timeout resets
the call stack, drains and reports — the recovery every other over-declared
command already gets).

**Rejected: rejecting the frame with an error.** DZRP has no framing-error
response, so "reject" could only mean an error code in a *response* — which is
itself a frame, sent onto a stream whose position we would be admitting we do
not know. Consuming the declared count is the only answer that keeps the two
ends agreeing about where the next command starts. Also rejected: keeping the
version bytes with a bounded copy (a `min()` and a second loop for data nothing
reads); validating that the name is NUL-terminated inside the frame (bytes for a
case DeZog never produces, and the length already makes it harmless).

**THIS CHANGED THE SERIAL ROM'S BYTES, ON PURPOSE, AND IT IS THE FIRST CHANGE
HERE THAT SHOULD.** `src/commands.asm` is common code, so the UART byte-identity
gate — this project's standing proof that a refactor changed no behaviour — is
*expected* to differ, and a merge that preserved it would have meant the fix did
not reach the serial build. With `BUILD_TIME=1700000000` and `BUILD_NUMBER=3`
pinned: UART `13217f12…` → `dc21bcbb…`, WiFi `d144ccb2…` → `62dbedb0…`. The
diff was checked against the symbol tables rather than eyeballed: 412 labels
before and after, none added or removed, everything below `cmd_init.inner`
identical, `cmd_init.read_loop` −5 and every label after `cmd_init` −1.

**C9 exists because C2 can only see half of this**, and the half it cannot see
is the one that desynchronises a *well-formed* session. C2 over-declares the
length and requires silence, so it proves the remote reads **at least** as far
as it was promised; it would stay green for a fix that read too little. C9 sends
an honest length whose payload carries four bytes past the name's NUL and then a
second ordinary `CMD_INIT` behind it: a remote that frames on the NUL leaves
those four bytes to be read as the next command's header. **Shown failing
first**, against the pre-fix WiFi ROM: C9 red with `timed out after 0 of 1
bytes` — the stub had answered the padded frame and then never answered
anything again. Post-fix, `make test-dzrp-stub` is **9 passed, 0 failed, 0
unsupported of 9**, with W1 and W2 still green.

**The issue's own acceptance criteria contradict each other**, and this is the
reading taken: it asks for 8 passed *and* for a new check that a well-formed
`CMD_INIT` still works. Those cannot both be true. C1 already sends a
well-formed `CMD_INIT`, so the literal request would have been the "strictly
weaker duplicate" a reviewer rejected from C2 once already; C9 is the same
intent in the only form that can fail for a reason C1 cannot.

---

## 2026-08-04 — mfselect offers three ROMs; the card carries both of ours

**Decided, issue #5.** mfselect's menu is now four entries — the stock
Multiface ROM, our **WiFi** build, our **UART** build, Exit — and both of our
ROMs live on the card as `dezowifi.rom`/`.sum` and `dezouart.rom`/`.sum`,
8.3-safe, replacing the single `dezogif.rom`/`.sum` pair.

**The UART build is not a legacy leftover**, which is the whole justification:
one ESP, one user of it, so a debuggee that owns the ESP cannot be debugged
over WiFi and the serial ROM is the plan's stated answer to that (§10,
"this is the reason the UART build is kept"). Buildable-but-not-installable
sent exactly those users back to swapping files on a card in a PC, which is
what mfselect exists to remove.

**`make mfselect` builds BOTH, in one command.** It recurses once per variant
with a single captured `BUILD_TIME`, so the five files a card needs are always
a coherent set. Every other target here builds exactly one variant on purpose —
the two ROM paths are deliberately separate so `make TRANSPORT=wifi` cannot
leave a WiFi ROM where `make test` reads one — and mfselect is the one consumer
that genuinely needs both regardless of how it was invoked. A two-command
ritual would have shipped one ROM with the other's checksum eventually.

**Nothing had to be invented to tell the two apart**: issue #4's magic string
already answered it, and `installed_name()` already returned "dezogif_ng UART"
/ "dezogif_ng WiFi". What was missing was a second ROM to install. That is the
payoff #4 was written for, and it is worth noting that the *guard* keys off the
**prefix** alone, so it protects both variants — and will protect a third
transport written by someone who never touches mfselect.

**Three bench checks, and each was seen to fail before it was believed.**

- **M7** — the first-run guard refuses our **UART** ROM as well as our WiFi one.
  Not M4 with a different file: a guard that recognised only the variant it was
  written against would destroy the stock ROM for exactly the users who chose
  the other transport. Control: guard changed to `id == ID_WIFI`; **M4 passed,
  M7 failed with the UART ROM captured as `original.rom`.**
- **M8** — the fourth menu entry reaches the file it names, two Downs from the
  top. Control: the UART entry pointed at the WiFi pair — the copy-paste bug —
  and **M3 passed while M8 failed**, naming the wrong CRC.
- **M9** — mfselect names the installed variant **correctly** on screen, which
  no file on the card can show. **This one was got wrong first, rejected in
  review, and rebuilt; see below.**
- **M10** — and nothing else on that row differs between the two runs.

**M9's first version was REJECTED, and the correction is the useful part of
this entry.** It compared the two runs *against each other*: WiFi installed vs
UART installed, and the status rows had to differ in exactly the four columns of
the transport name. The control I ran was `installed_name()` returning **one**
string for both variants, which failed it with an empty differing-column set —
and I reported that as evidence the check discriminated. It does not. The
reviewer **swapped** the two return strings, so each variant reported the
other's name, rebuilt, and the bench passed **9/9 with M9 green**: two labels
exchanged still differ in exactly those columns.

The degenerate control probed only the case where the labels **collapse**, and
passing that says nothing about the case where they **cross**. Nothing else on
the bench covers it either — M3 and M8 assert on the bytes of the installed
file, which say nothing about what the screen claims about them.

**The fix is ground truth internal to each screenshot, and it needed no new
asset.** mfselect's menu renders `dezogif_ng WiFi (ESP-01)` and
`dezogif_ng UART (joy port)` whatever is installed, in the same ROM font and
under the same attribute as the status row — so both correct labels are already
in every picture. M9 now requires each run's status field to **match the right
menu entry and differ from the other**, judged inside one image. A swap cannot
satisfy that; nor can one label used twice, so the new check subsumes the old
control instead of trading one break for another. Both were re-run: **swap → M9
red, M10 green; one-label → M9 and M10 both red; restored → 10/10.**

Every column falls out of one fact — all these strings begin with the 11
characters `dezogif_ng ` — so the transport field is 11 cells in: status row 2
columns 23-26, menu rows 6 and 7 columns 13-16. Pixel comparison means the
attributes must match too, and they do: the status row and the *unselected* menu
rows are both `ATTR_BODY`, and the selected row in these runs is row 5.

**M10 keeps what M9 gave up.** M9 reads four cells; M10 covers the other
twenty-eight, so a name of a different length — shifting the build number after
it — cannot hide behind a correct transport field.

**Neither is a percentage, deliberately.** Two status lines differing in four
characters differ in ~0.05% of the screen, which no threshold separates from
noise: the exact failure ERRORS.md records for T4.

**The lesson, and it is a new shade of one this project keeps paying for.**
ERRORS.md already says a fix never tested by *removing* it is a correlation, and
that "the screen changed" is not "the stub took over". This is the third shape:
**a control that breaks a thing in the easiest direction proves only that
direction.** Collapsing two labels into one is the degenerate break; exchanging
them is the adversarial one, and only the second distinguishes "these differ"
from "this one is right". When a check compares two observations, ask what it
knows about *either* of them on its own — and if the answer is nothing, it is a
consistency check, not a correctness check.

**M6 was moved onto the WiFi ROM at the same time**, and that is not cosmetic.
It had installed the UART ROM, so the guard control above turned M6 red too —
a check failing for a reason outside its own subject, which ERRORS.md names as
a defect in the check rather than a finding. M6's subject is checksum skew;
M7's is the UART guard; they should not be able to fail together.

**Two compile-time asserts** guard the menu, because the failure modes are
silent. `menu_fits_above_messages` — the menu must still end above `ROW_MSG`,
or a fifth entry paints over the first line of every message. 
`exit_is_the_last_menu_entry` — `main()`'s dispatch ends in an `else` that
installs the UART ROM, so an entry added *after* Exit would be selectable,
unnamed, and would quietly install something the user did not choose. Both were
verified to fire by compiling with `MENU_ITEMS` at 5 and 6; an earlier assert
comparing `sizeof(menu_text)` against `MENU_ITEMS` was **removed after being
shown useless** — the array's bound is `MENU_ITEMS`, so the two can never
disagree.

**Rejected.** Keeping `dezogif.rom` for one variant and adding a second name
only for the other (asymmetric, and it makes "which one is this" a question
about the filename rather than the ROM); naming them `enNextMf-wifi.rom` on the
card (not 8.3-safe, the constraint that already rejected `enNextMf.orig.rom`);
identifying the installed variant by checksum (that conflation was the
data-loss bug of #4 — see ERRORS.md); a `make mfselect-wifi` / `make
mfselect-uart` pair (it is one deployable directory, not two).

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

**NOW EVIDENCED ON HARDWARE, which is not quite the same as measured.** The
user reports (2026-08-04) that their Next **comes up already associated**: once
WiFi is set up, the ESP is associated and ready from then on, exactly as jnext
models it. So the setup story is **once per machine**, not once per boot, and
the "verify, do not configure" design rests on first-hand hardware evidence
rather than on ESP-AT documentation.

**Calibrated deliberately**, after a reviewer pointed out that the first draft
tagged this "verified on hardware" and gave it the same rung as claims anyone
can re-run with a grep or an emulator run. It is one machine, one reporter, no
captured artefact. That is the strongest evidence obtainable — no emulator can
produce it — and it is still weaker than a re-runnable check. The ladder now
has a rung for it: **reported on hardware**.

Note this does *not* re-promote the discarded third reason above. That reason
is now true, but the decision never needed it and the lesson stands: it was
counted as sufficient while unmeasured, and that was the error — not the claim
itself.

[doc/WIFI-SETUP.md]: doc/WIFI-SETUP.md

---

## 2026-08-04 — ROM identity is a magic string; the CRC keeps only integrity

**Decided (user), issue #4.** Every `enNextMf.rom` carries a magic string at a
fixed offset, and mfselect uses it to answer "is this ours?". The string, and
its shape is the user's:

    DeZoGiFnG_UART_0001        DeZoGiFnG_WIFI_0001

prefix + transport variant + a four-hex-digit build number from a new
`version.yaml`, bumped by `make bump`, one bump per merge to `main` **that
changes a ROM**.

**That qualifier was added the same day, after the rule met its first
counter-example** (user, 2026-08-04). The original wording was "one bump per
merge", full stop, and the very next merge was documentation. Measured rather
than argued: building both sides with `BUILD_TIME` and `BUILD_NUMBER` pinned
gave a **byte-identical ROM**. Bumping there would have minted a new identity
for a ROM that had not changed — asserting a difference that does not exist,
which is precisely the opposite of what the number is for.

The check is mechanical, not a judgement call —
`git diff --name-only main..<branch> -- src/ Makefile`, empty means
no bump — and deliberately conservative: a touched `Makefile` may leave
the ROM identical, and bumping anyway costs nothing, whereas failing to bump
when a ROM *did* change leaves two different ROMs claiming to be the same
build. With two variants (#5) the rule is *any* of them; they share sources, so
one check covers both.

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
  emulated module is permanently on a network. ~~Hardware is not, and the stub
  will need a bring-up path the bench can never exercise.~~ **Both halves of
  that turned out wrong, later the same day.** Hardware *is* already associated
  — a configured Next comes up that way (reported on hardware, 2026-08-04) —
  and the stub therefore needs **no bring-up path at all**: WiFi is a
  prerequisite the user satisfies once with `wifi2.bas`, and the stub only
  verifies it has an address. See the WiFi entry at the top of this file. What
  survives is the narrow original point: the bench cannot exercise association
  either way, so nothing here can ever test it.
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

## 2026-08-04 — M1's second half: the ESP transport, and the switch

**Built and measured.** `src/transport_esp.asm` implements the whole
`transport.asm` interface over the ESP-01 in TCP server mode, selected by
`make TRANSPORT=wifi` (`-DTRANSPORT_WIFI` → `ROM_VARIANT`). The AT chain, the
`+IPD` parser and the `AT+CIPSEND` framing are ported from `test/esp_server.asm`,
the M0(b) spike — which is the whole reason that fixture was built first.

**The measurement that matters: `make test-dzrp-stub` — W1 pass, then 7 of 8
DZRP checks pass.** A headless Next with our WiFi ROM as the Multiface ROM, an
emulated M1 press, and the conformance suite talking DZRP over a socket to the
debugger. Loopback is exact at 0, 1, 255, 256 and **1024** bytes, which is the
multi-chunk path; sequence numbers echo across five commands; registers and a
memory round trip come back right. Before this the strongest evidence in the
project was a pixel count.

**Three decisions worth keeping.**

1. **The 0xA5 preamble is a macro, not an `IF`.** `TRANSPORT_MESSAGE_START`
   expands to upstream's two instructions in UART mode and to nothing in WiFi
   mode, so `message.asm` cannot tell which it was assembled against — the rule
   CLAUDE.md states. Asserted rather than assumed: the bench passes
   `--expect-preamble none`.
2. **Responses are buffered and framed, because `AT+CIPSERVER` forbids
   passthrough.** `transport_write_byte` appends; `TRANSPORT_END_MESSAGE`
   flushes as an `AT+CIPSEND=<id>,<len>`. TCP is a stream, so a long response
   spanning several CIPSENDs is invisible to the client.
3. **The connection id is read from `+IPD` and echoed back, never assumed** —
   the note recorded below about jnext's inbound ids starting at 1, now used
   rather than only written down.

**The bug that only a real client could have found, and the shape of it is the
lesson.** `TRANSPORT_END_MESSAGE` was placed at the top of `cmd_loop` and of
`main`, which looked exhaustive: a response returns to `cmd_loop`, `NTF_PAUSE`
is followed by `jp cmd_loop`, `CMD_CLOSE` by `jp main`, `CMD_CONTINUE` already
flushed in `backup.asm`. **`cmd_loopback` reaches none of them** — it ends
`pop af` / `jp main_loop.continue`, bypassing `cmd_loop` entirely. So its reply
sat in the buffer until the *next* command arrived and was then delivered to
whichever connection had asked that one. The suite saw a timeout followed by a
sequence mismatch on the *following* check, i.e. the symptom appeared one check
away from the cause. Found by reading jnext's `esp01=trace` log against the
source, not by reasoning about it.

**Two things the independent review rejected, both real, both fixed and both
now defended by a test.**

1. **The `+IPD` reassembly path had no committed test.** jnext splits inbound
   TCP at `MAX_IPD_CHUNK = 2048` (`esp_at.h:448`), and the loopback sweep
   stopped at 1024 — so *every* payload in the transport's evidence had arrived
   in a single frame, and the most novel code in the diff was never executed by
   anything. The reviewer ran 2000/2048/2049/3000/4096/8192 by hand and all six
   round-tripped, so the code was right; what was missing was the standing
   check. The sweep now runs 2047/2048/2049/4096, straddling the boundary
   rather than jumping over it. Real traffic crosses this constantly —
   `CMD_WRITE_BANK` pushes 8-16 KB per bank when DeZog loads a `.nex`.

2. **`esp_conn_id` was never cleared, which broke the NMI-button fallback.** It
   was set by an inbound `+IPD` and nothing ever reset it, so after a client
   disconnected the id of a closed connection survived for the rest of the
   power-on session. Every later *unprompted* `NTF_PAUSE` — the M1 button, or a
   leftover `RST 0` through `breakpoints.asm` — was addressed to it, got
   `ERROR` from `AT+CIPSEND`, waited for a `>` that could not come, and diverted
   to `drain_main`, which discarded the notification and painted **"Last Error:
   TX Timeout"** on a machine with nothing wrong with it. Plan §4.3 calls the
   button "always available"; it silently stopped being so after the first
   disconnect.

   **Fixed by reading `AT+CIPSEND`'s refusal rather than by parsing
   `<id>,CLOSED`**, and the choice matters: `ERROR` covers *every* reason a cid
   stops being usable — closed by the peer, closed by the module, never opened —
   at one point in the code, where a `CLOSED` parser only covers the one case it
   was written for and adds a second pattern to the RX hot path. So
   `esp_wait_prompt` now matches `'>'` **or** `"ERROR"`, and on `ERROR` the id
   goes back to 0, which is the "nobody to send to" state `transport_flush`
   already discards in.

   **The residual is stated rather than fixed:** a client that has reconnected
   but not yet sent anything is invisible, because only an inbound `+IPD`
   refreshes the id, so an unprompted notification in that window still goes
   nowhere. Closing it needs `<id>,CONNECT` tracking, which belongs with M3's
   reconnect work.

**The test for (2) was shown failing first, which is the only reason it is
worth anything.** Bench check **W2**: a client sends `CMD_CONTINUE` and closes
in the same breath; with nothing loaded the debuggee resumes at PC=0 and runs
into a stray `RST 0` (measured: address 0x6417, break reason 2), so the stub
sends an `NTF_PAUSE` to a connection that has gone — no button press and no
timing luck required. W2 asserts the *precondition* from jnext's own log (an
`AT+CIPSEND` really was refused), that the stub still serves a new client, and
that its screen reports no error, counted as **bright-red pixels** — jnext
renders non-bright components as 182 and bright as 255, and `out (BORDER),a`
carries no bright bit, so the error text is the only thing on that screen that
can be exactly `(255,0,0)`. Pre-fix: **824**. Post-fix: **0**.

**What is NOT done, and none of it is hidden.**

- **`AT+CIFSR` is not sent and no address is shown.** Reporting an address means
  parsing and drawing it, which is the connect-string UI decided on 2026-08-04
  and deliberately left to its own change. WiFi mode currently draws upstream's
  baud line and joy-port selector, both meaningless there.
- **A re-init while already listening reports an error.** Symbol Shift + NMI
  runs `transport_init` again and `AT+CIPSERVER=1,<port>` answers ERROR when a
  server is up. The link keeps working; the screen lies. `esp_wait_prompt` now
  shows how to fix it — the same two-pattern shape applied to `esp_command_ok` —
  so this is a small follow-up rather than an open question.
- **`transport_byte_available` can stall `main_loop` for ~100 ms** when the
  module puts an unsolicited line on the wire (`<id>,CONNECT` is the common
  one): it scans for a header that is not there and gives up on the RX timeout.
  Upstream's is an O(1) status read. Bounded, free while idle, and worth knowing
  before anything is built on "that poll returns immediately", which is a
  statement about the serial build.
- **Bring-up failure shows as "RX Timeout"**, because adding an error code
  means adding a string and a table entry to `data_const.asm` — common code
  whose bytes the UART gate protects. `transport_activate` carries the flag past
  `drain_main`'s reset of `last_error`, which is the only trick involved.
- **C2 of the DZRP suite is red, and it is pre-existing.** `cmd_init` reads the
  remote's program name until a NUL and ignores the frame length, so a length
  that disagrees with the payload desynchronises silently. `commands.asm` is
  untouched and the UART ROM is byte-identical to `main`'s, so this is what the
  serial build has always done. Fixing it changes the serial ROM and belongs on
  its own branch. **CLOSED — issue #7, on its own branch as predicted; see the
  entry at the top of this file.**
- **Nothing has run on hardware.** jnext models baud as timing only and its
  module is permanently associated (no `AT+CWJAP=` at all), so the 115200
  pinning, the ESP-AT echo default and every timeout constant are reasoned, not
  measured.

**The gate held.** With `BUILD_TIME` and the build number pinned the UART ROM
hashes `2387fc96…`, identical to `main`'s, across a change that added a
transport, two framing macros, three macro call sites in common code and a
Makefile variant split. That is the same standard the interface extraction was
landed to, and it is worth keeping as the price of admission for M2.

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

**~~Not decided.~~ ANSWERED ON HARDWARE, 2026-08-04: a soft reset is NOT
enough.** This entry used to say the question was open, that the advice was
"safe either way", and that the project's "read the VHDL" rule could not settle
it because it is a tbblue firmware question. The user settled it by doing it:
after installing our WiFi ROM, a **Reset button press** followed by NMI brought
up the **stock Multiface menu** — the old ROM, still live. A **power cycle**
then brought up ours. So the firmware reads the Multiface ROM at power-on and
nothing short of that re-reads it, and mfselect's yellow POWER-CYCLE advice is
correct rather than merely cautious.

Worth keeping for the method as much as the answer: this cost one button press
to establish and had sat unanswerable for a day, because no emulator run and no
amount of VHDL could reach it. Some questions are only hardware's to answer,
and the cheap ones should be asked the moment hardware is available.

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
