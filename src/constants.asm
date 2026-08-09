;===========================================================================
; constants.asm
;
; Definition of the main constants.
;===========================================================================



; Is temporarily used. E.g. to change the AltROM. The debugged program can use this bank.
TMP_BANK:       EQU 92
TMP_BANKB:       EQU 93

; The 8k memory bank to store the code to.
; Debugged programs cannot use this bank.
MAIN_BANK:      EQU 94  ; Last 8k bank on unexpanded ZXNext.

MAIN_SLOT:      EQU 7   ; 0xE000
SWAP_SLOT:      EQU 6   ; 0xC000, used only temporary

LOOPBACK_BANK:  EQU 91 ; Used for the loopback test. Could be any bank as the loopback test is not done with a running debugged program.

; The address that correspondends to the main bank.
MAIN_ADDR:      EQU MAIN_SLOT*0x2000

; The address that correspondends to the swap slot bank.
SWAP_ADDR:      EQU SWAP_SLOT*0x2000

; Use the build time
BUILD_TIME16: equ BUILD_TIME & 0xFFFF
; DISPLAY "BUILD_TIME: ", BTIME


;===========================================================================
; ROM identity block — issue #4.
;
; A fixed marker saying "this enNextMf.rom is ours, and which variant it is".
; It answers IDENTITY. The CRC in the .sum files answers INTEGRITY, and the
; two must not be confused again: a CRC identifies one BUILD, because
; BUILD_TIME is stamped into every ROM, so it changes on every rebuild and
; every release. Using it for identity meant that after any upgrade mfselect
; no longer recognised our own ROM — and its first-run guard, which exists to
; stop it saving OUR ROM as the user's `original.rom`, stopped firing.
;
; AT THE VERY END OF THE IMAGE, and that is the whole point of the address.
; tbblue.fw loads exactly 8192 bytes, so the last of them are the one anchor
; in this file that cannot drift as the code grows. Anything measured from the
; start would move the first time something above it changed size.
;
;   ROM file offset 0x1FE0 .. 0x1FFF   =   address 0xFEA0 .. 0xFEBF
;   (the image is mf_nmi.bin, 0x140 bytes, followed by main.bin from 0xE000,
;    so offset = 0x140 + address - 0xE000)
;
; THE FILE OFFSET IS THE CONTRACT — NOT THIS ADDRESS. Its only value is being
; at the same place in the FILE in every release we have ever shipped and will
; ever ship, because tools/mfselect/mfselect.c reads the file. The address is
; derived: offset = main_prg_copy + address - 0xE000.
;
; So this constant MAY be moved, in one case and only one: if mf_nmi.bin grows
; past its ALIGN 16 boundary, main_prg_copy moves up 16 and this must move
; DOWN 16 to keep the offset at 0x1FE0. The ASSERT in main.asm enforces exactly
; that relationship, so getting it wrong is a build error and never a silently
; misplaced block. Probed 2026-08-08: +16 with this moved builds clean, the ROM
; stays 8192 bytes and the block still reads at 0x1FE0.
;
; An earlier version of this comment said "NEVER MOVE THIS", which was wrong
; and sat directly above the constant that M2's entry path may have to move.
; What is true is that a build which cannot fit below it must shrink.
; See doc/ASYNCHRONOUS-BREAK-DESIGN.md §4.5.
;===========================================================================
;   DeZoGiFnG_UART_00A3
;   DeZoGiFnG_WIFI_00A3
;   \________/ \__/ \__/
;    identity   |    build number, 4 uppercase hex digits, from version.yaml
;               transport variant
;
; THE PREFIX IS THE IDENTITY AND THE SUFFIX IS NOT. A reader must match
; "DeZoGiFnG_" to answer "is this ours", then the variant field to answer
; "which one". The build number is information to *show* the user, never
; something to match on — matching it would reintroduce exactly the
; per-build fragility this block exists to remove.
;
; ITS FOUR DIGITS STAY BARE, and a reader who has just seen the debugger's
; banner say "build 00.A3" should not come here and add the dot (issue #20).
; This field's format is a contract with tools/mfselect/mfselect.c; the dot is
; a rendering applied where a person reads the number, and putting it in the
; stored form would give the same value two spellings to drift between.
ROM_MAGIC_ADDR:     equ MAIN_ADDR + 0x1EA0  ; 0xFEA0 = ROM offset 0x1FE0
ROM_MAGIC_SIZE:     equ 32                  ; reserved; the string is 20 bytes

; Which transport this ROM was assembled against, and THE assembly-time switch
; the whole two-mode design turns on. `transport.asm` includes an
; implementation according to it and `main.asm` stamps the name into the magic
; string, so `make TRANSPORT=wifi` produces a ROM that both behaves and
; identifies itself as the WiFi one. Issue #5 is the consumer that needs to tell
; two of our ROMs apart — no CRC can, since both change on every build.
;
; Driven from the command line as -DTRANSPORT_WIFI (the Makefile's
; TRANSPORT=wifi). A bare define rather than -DTRANSPORT=<value> because
; sjasmplus processes -D before the source, so a symbolic value would name a
; constant that does not exist yet, and a numeric one would put a bare 0 or 1 in
; the build command where a reader cannot tell which is which.
ROM_VARIANT_UART:   equ 0
ROM_VARIANT_WIFI:   equ 1

 IFDEF TRANSPORT_WIFI
ROM_VARIANT:        equ ROM_VARIANT_WIFI
 ELSE
ROM_VARIANT:        equ ROM_VARIANT_UART
 ENDIF


;===========================================================================
; The same three facts as the identity block, for the debugger's own screen.
;
;   dezogif_ng WiFi build 00.08         27 columns of the 32 there are
;
; IT LIVES HERE, BESIDE rom_magic's DEFINITION, ON PURPOSE. Both say which
; fork, which transport and which build; a screen that disagreed with the
; block mfselect reads would be worse than no screen at all (issue #12). The
; only way to keep them in step is for both to be spelled from the same two
; symbols — ROM_VARIANT and the build number — in a place where changing one
; and not the other is visibly wrong. Never introduce a second source for the
; build number: that conflation is what issue #4 and ERRORS.md are about.
;
; THE SCREEN'S NUMBER IS DOTTED AND THE BLOCK'S IS NOT, and that is one source
; with two renderings rather than two sources (issue #20). BUILD_NUMBER_HEX and
; BUILD_NUMBER_SHOWN are both handed in by the Makefile, the second derived from
; the first on the line below it, so nothing here can make them disagree. The
; block keeps four bare digits because its format is a contract mfselect parses;
; the dot is for the person reading the screen, to whom "0010" reads as ten.
;
; It is a MACRO rather than a label because it is emitted inside INTRO_TEXT's
; AT-terminated stream (data_const.asm), which has no room for a call.
;===========================================================================
    MACRO IDENTITY_LINE
    defb "dezogif_ng "
 IF ROM_VARIANT == ROM_VARIANT_WIFI
    defb "WiFi"
 ELSE
    defb "UART"
 ENDIF
    defb " build "
    defb BUILD_NUMBER_SHOWN             ; the identity block's number, dotted
    ENDM



; UART baudrate — UART MODE ONLY. This is the joy-port cable's rate, where both
; ends are ours to choose. It is NOT what WiFi mode runs the peripheral at; see
; ESP_BAUDRATE below, and do not let the two be shown by the same UI again.
;BAUDRATE:   equ 2000000
;BAUDRATE:   equ 1958400
;BAUDRATE:   equ 1228800
BAUDRATE:   equ 921600
;BAUDRATE:   equ 614400
;BAUDRATE:   equ 460800
;BAUDRATE:   equ 230400


;===========================================================================
; WiFi mode's two build-time settings.
;
; THEY LIVE HERE RATHER THAN IN transport_esp.asm BECAUSE THE UI NAMES THEM.
; data_const.asm holds the on-screen text and is included BEFORE
; transport.asm, so a STRINGIFY there cannot see a value defined inside the
; transport implementation. Putting them beside BAUDRATE also puts the two
; rates next to each other, which is where the confusion they caused belongs.
;===========================================================================

; The ESP-01's power-on baud rate. The module answers at this until told
; otherwise (doc/WIFI-SETUP.md) — inferred from the ESP-AT documentation, not
; measured on hardware. EVERY bring-up starts here, whatever ESP_BAUD_HIGH
; below says, because the stub has to be able to talk to a module it has just
; met.
ESP_BAUDRATE:   equ 115200


;===========================================================================
; The rate the link is negotiated UP to once the module has answered — issue
; #25. It lives beside ESP_BAUDRATE because the screen names whichever of the
; two is live, and data_const.asm is assembled before the transport.
;
; WHICH RATE TO ASK FOR IS TWO QUESTIONS, and they do not have the same answer.
; The first is which targets the hardware can even express, and it is settled
; below by arithmetic. The second is which of those this stub can keep up with,
; and it is settled by measurement in the paragraph after that — 1000000 wins
; the first and loses the second, which is why the default ends up where it does.
;
; ONE MILLION, AND IT IS THE ARITHMETIC THAT PICKS IT RATHER THAN TASTE. The
; prescaler is Fsys/baud and Fsys depends on the video timing in NR 0x11, so
; the same target lands on eight different divisors — and the divisor is an
; integer, so most targets are wrong at most timings. Computed over the whole
; Fsys table in transport_esp.asm, with the rounding that table now does:
;
;    target     exact at   worst error
;    460800     0 of 8      -0.69%
;    921600     0 of 8      -1.36%
;   1000000     6 of 8      +1.60%
;   1152000     0 of 8      +1.90%
;   2000000     3 of 8      -3.57%
;
; The budget those are spent against: the receiver samples mid-bit, so by the
; last of ten bit times the two ends' errors together must stay under
; 0.5/9.5 = 5.3%. Everything above is OURS alone, before the module's own
; crystal is counted, which is why 2000000's -3.57% is refused — it leaves
; under two points for the other end — while 1000000's +1.60% leaves three
; and a half, and is paid at only two of the eight timings.
;
; 921600 IS NOT UNIFORMLY WORSE, and issue #25's own feasibility comment says
; it is. Checked: 1000000 is EXACT at six timings where 921600 is exact at
; none, but at Fsys 28571429 and 29464286 — NR 0x11 states 1 and 2 — 921600
; lands on +0.006% and -0.091% against 1000000's -1.48% and +1.60%. So the
; choice is "exact almost everywhere, with two mediocre timings" against
; "mediocre everywhere", which is still 1000000, for a different reason than
; the one that was written down.
;
; IT DEFAULTED TO ESP_BAUDRATE UNTIL 2026-08-09, i.e. THE NEGOTIATION WAS OFF IN
; THE SHIPPED ROM — everything from here to the "THE DEFAULT IS NOW 460800" block
; below is the reasoning for that, kept because it is what any future rate has to
; argue against. It was a measurement rather than caution. Two things decided it:
;
;   * 1000000 — the rate this was built for — FAILS the conformance suite. A
;     CMD_LOOPBACK of 1024 bytes or more overflows the UART's 512-byte Rx FIFO
;     and the stub reports RX Overflow. Measured, bench check L5, three dropped
;     bytes in jnext's own uart log.
;
;     THE COST IS THE PER-BYTE RECEIVE PATH, AND NOTHING TO DO WITH SENDING.
;     An earlier version of this comment said `cmd_loopback` interleaves reading
;     and sending, stopping every ESP_TX_CHUNK bytes for an AT+CIPSEND. It does
;     not: commands.asm:959-1018, upstream and unmodified, drains the WHOLE
;     payload into the swap bank before it reaches send_length_and_seqno, and
;     ESP_TX_CHUNK is referenced only by the transmit path. Read off
;     build/baud-l5.log instead of reasoned about: the previous response's
;     SEND OK is fully delivered, the 1030-byte +IPD header goes out, and the
;     first dropped byte follows 2 ms later with ZERO guest TX writes and zero
;     AT+CIPSEND in the window. The overflow happens entirely inside a receive.
;
;     So what does not fit in a byte time is transport_read_byte and what it
;     calls — two border writes, esp_require_payload's guard, the 16-bit
;     esp_rx_remaining decrement, the held-vs-wire source test, and
;     esp_try_read_raw re-arming its retry and pass counters — plus the caller's
;     own store loop. At 28 MHz one byte time is prescaler x 10 T-states, and
;     the sweep brackets the cost between two of them:
;
;         230400 (1220 T)  pass, 0        600000 (470 T)  FAIL, 2
;         460800  (610 T)  pass, 0        750000 (370 T)  FAIL, 2
;                                         921600 (300 T)  FAIL, 2
;                                        1000000 (280 T)  FAIL, 3
;
;     i.e. ABOVE 470 AND AT MOST 610 T-states per byte. 460800 also passes the
;     whole suite, 15 of 15 with W1-W6.
;
;     AND IT IS NOT AN ECHO PROBLEM, which is the reason this matters more than
;     one failing check: a receive-side cost applies to ANY large inbound
;     payload. CMD_WRITE_BANK pushes 8-16 KB per bank every time DeZog loads a
;     .nex, and it is affected exactly as the loopback is. Whoever raises this
;     ceiling must optimise the RECEIVE path; the send path is not in it.
;
;   * AND NOTHING HAS RUN ON HARDWARE. The rate a real ESP-01 will take, and
;     what the module's own AT+CIPSEND latency does to the same backlog — it is
;     tens of milliseconds on silicon against jnext's zero, so the emulator
;     UNDERSTATES this — are hardware's alone. Changing the rate the shipped ROM
;     runs the ESP at, on emulator evidence, is exactly the move that has twice
;     cost this project a hardware evening.
;
; ALL OF THAT IS THE HISTORY OF THIS CONSTANT AND IS KEPT DELIBERATELY. It is
; why the default was ESP_BAUDRATE — the negotiation assembled OUT — from the day
; the machinery landed until 2026-08-09.
;
;---------------------------------------------------------------------------
; THE DEFAULT IS NOW 460800, EARNED ON 2026-08-09 (user, on their own Next)
;
; Every one of the six results below was produced at build 00.16, and the build
; matters: at 460800 an earlier ROM draws its own screen WRONG (issue #31, a
; 768-byte font buffer the assembler could not see), so criterion 1 could not
; have been read honestly off it. Measured:
;
;   1. the screen reads 460800, and is clean;
;   2. `make test-hardware` FIVE runs of five, H2 = 15 of 15 every time;
;   3. H6 clean every run, 0 bright-red pixels, no `RX Overflow`;
;   4. H5 median 20.3 KB/s against the 8.3 baseline — 2.45x, criterion was 2x;
;   5. H4 median 6.6 ms against 11.2, i.e. 41% BETTER. Note this DISPROVES the
;      prediction in criterion 5 below, which expected it unchanged;
;   6. M1, `R`, M1 — and the probe was shown to have fired, not assumed: with
;      the machine sitting after the reset `.UART` got no answer at 115200,
;      where after a power cycle it gets `OK`. See doc/HARDWARE-TESTING.md.
;
; The confirmation asked for below — a real DeZog F5 loading a `.nex` — was also
; done, and is the WEAKEST item here: the user reports it worked and felt faster,
; with no timing captured and no artefact. Recorded at that strength in
; doc/HARDWARE-TESTING.md and worth nothing more than that.
;
; WHAT IS STILL NOT MEASURED, because a met criterion list is not a proof:
; a SECOND machine or module — every figure here is one Next, one ESP-01, one
; reporter — and the probe against a module at a rate this ROM was not built
; for, which nothing stages.
;
; AND ONE RESIDUAL THAT NONE OF THE SIX CRITERIA REACHES, named because "a second
; module" does not convey it: every failure they cover is a CLEAN one — the module
; refuses, or goes silent, and the fallback catches it. A different unit with a
; worse crystal, more RF noise or a longer bus path could ACCEPT
; AT+UART_CUR=460800 and then corrupt bits on the wire, which is a different
; shape and which nothing here would catch as a refusal. DZRP's own framing would
; surface it as desynchronisation rather than as a rate fault.
;
; THE FALLBACK IS WHAT MAKES THIS SAFE TO DEFAULT. A module that refuses
; AT+UART_CUR leaves the stub at 115200 and serving (bench L2), and a module
; found at the raised rate after a reset is recovered by the bring-up probe
; (criterion 6). Neither needs a power cycle. `BAUD_HIGH=115200` assembles the
; negotiation back out if a machine ever needs it.
;
;---------------------------------------------------------------------------
; THE SIX CRITERIA, KEPT AS WRITTEN, because they are what any FUTURE rate has
; to meet — 921600 included, which needs the per-byte RECEIVE cost brought below
; 300 T-states from a figure bracketed only as 470 < C <= 610.
;
; Install a ROM at the candidate rate, then:
;
; 1. THE SCREEN MUST READ `ESP Baudrate: 460800`. If it reads 115200 the module
;    refused and there is nothing to measure — the fallback worked, and the
;    answer for that module is no. `make read-screen NEXT_IP=<ip>` reads it back
;    over DZRP; row 3.
;
; 2. `make test-hardware NEXT_IP=<ip>`, THREE RUNS, H2 = 15 of 15 EVERY TIME.
;    Three and not one because issue #11's cost measurement needed three before
;    an outlier could be discounted. **C5 is the check that matters** — the
;    loopback sweep is what L5 shows going red at 1000000, so it is the ceiling
;    arriving, not a random failure.
;
; 3. H6 CLEAN ON ALL THREE, AND SPECIFICALLY NOT `RX Overflow`. That string is
;    disqualifying even if every check passed, because it means the Rx FIFO
;    reached its limit and the margin is gone. It is a DIFFERENT string from
;    `RX Timeout`, which has other causes and which a disconnect can leave
;    behind by itself (MEMORY.md 2026-08-08).
;
; 4. H5 THROUGHPUT: median of the three at least twice the 115200 baseline,
;    i.e. >= ~16 KB/s round trip against the 8.3 KB/s recorded on 2026-08-08.
;    Below that the module's own TCP stack is the limit rather than the wire,
;    and the rate is not buying what it risks.
;
; 5. H4 LATENCY IS NOT THE CRITERION, and reading it as one is the easy mistake.
;    The median at 115200 is 11.2 ms and is dominated by the WiFi round trip,
;    not by the wire — a command is tens of bytes — so expect it roughly
;    UNCHANGED. What would be a red flag is it getting materially WORSE, say a
;    median past ~20 ms, which suggests retransmission.
;
; 6. AND THE ONE NO BENCH ANYWHERE COVERS: press M1, then the stub's own `R`,
;    then M1 again. The debugger must come back up. That is the bring-up probe,
;    which is dead code in the emulator because jnext's module answers at the
;    first rate asked. If this fails, do not flip the default whatever the
;    throughput says — a reset leaves both ends at the raised rate, so this is
;    the path a user meets first and most often. (A bit-7 pulse of NR 0x02 would
;    reset the module too — nextreg.txt:37-49 — but it takes the expansion bus
;    with it and no bench here can run it; see transport_init.)
;
; A real DeZog F5 loading a `.nex` is the confirmation worth having on top of
; all six: CMD_WRITE_BANK is the largest inbound traffic this stub ever sees.
;---------------------------------------------------------------------------
;
; OVERRIDABLE, and this is the SEVENTH seam of the ESP_IP_MAX / ESP_RX_WAIT /
; ESP_TX_PASSES / TRANSPORT_WAIT_RX_SECONDS / ESP_FAULT_LIMIT / ESP_LINK_IDS /
; ESP_SERVER_TIMEOUT family. Four settings each reach a state no other can:
;
;   * ESP_BAUDRATE ITSELF, which assembles the whole negotiation OUT. That is
;     no longer the default, but it is still the "before" control L3 needs, and
;     it is the setting to reach for if a machine ever cannot sustain the rate;
;   * 460800, WHAT NOW SHIPS: the negotiation happens and everything above the
;     transport has to keep working across it;
;   * a rate the module REFUSES, which is the only way to execute the arm that
;     declines to switch. jnext answers ERROR above 5000000;
;   * 1000000, the ceiling above, kept as a checked fact rather than a paragraph.
;
; See test/run-baud.sh.
 IFNDEF ESP_BAUD_HIGH
ESP_BAUD_HIGH:  equ 460800
 ENDIF

; STRINGIFY renders exactly seven decimal digits' worth (macros.asm), so an
; eight-digit rate would emit ':' where its leading digit belongs and the
; module would be sent a command nobody could read. Nothing else bounds it.
    ASSERT ESP_BAUD_HIGH < 10000000
    ASSERT ESP_BAUD_HIGH >= ESP_BAUDRATE

; The TCP port WiFi mode listens on. DeZog's `cspect` remote defaults to this,
; so a launch.json that omits `port` still works. MEMORY.md 2026-08-04 pins it;
; Appendix B's example, test/run-dzrp-stub.sh and the address the UI draws must
; all agree, because a mismatch fails as a silent connection refusal.
ESP_SERVER_PORT:    equ 11000


;===========================================================================
; How long transport_wait_rx sits in cmd_loop before going back to the idle
; loop — BOTH transports. Issue #16, part A.
;
; IT USED TO SIT THERE FOR EVER, and it is the only wait in this program that
; ever did. Every other one is bounded: esp_try_read_raw by
; esp_rx_retries x ESP_RX_WAIT, esp_send_raw by ESP_TX_WAIT, transport_drain by
; its own countdown, and every scan inherits the read's bound. This one had no
; timeout by design, because it runs where CALLs are forbidden — which is not
; the same thing as where a countdown is impossible. BC and DE are untouched
; between the two layer-2 writes either side of the loop, so the counter lives
; in registers and needs neither the stack nor a memory cell.
;
; WHAT EXPIRY DOES IS THE WHOLE DESIGN, AND IT IS NOT A TIMEOUT. It does NOT
; report an error and it does NOT go through drain_main. It resets SP and jumps
; to main_loop — the same loop the debugger sits in before any client attaches.
;
; That is forced, not preferred. `cmd_loop` (message.asm) ends `jr cmd_loop`, so
; this wait IS the debugger's idle state once a client has attached: what it is
; waiting for is the next thing the user does in DeZog, and somebody reading
; code for a minute before pressing F10 is the normal session, not an unusual
; one. The stub cannot tell "the module went quiet" from "the person is
; thinking" — nothing in DZRP polls — so ANY finite bound fires on healthy
; sessions, and the destination has to be one that costs a healthy session
; nothing. drain_main is not: it falls through into main, which re-initialises
; prgm_state, backup.speed, backup.interrupt_state, backup.layer_2_port and
; slot_backup.slot0, i.e. the DEBUGGEE's saved state. A debuggee stopped at a
; breakpoint would then resume at 3.5 MHz with interrupts off and the wrong
; slot 0, silently. main_loop resets none of it and re-enters cmd_loop on the
; next byte, so the session simply carries on.
;
; Nothing is half-received at the moment of expiry, provably: the loop can only
; get there with esp_rx_remaining zero, no frame held and the RX FIFO empty —
; those are its own conditions — and cmd_loop's TRANSPORT_END_MESSAGE already
; flushed the outgoing buffer. So there is no fragment for either end to
; resynchronise, which is exactly why leaving is safe HERE and would not be from
; a wait for bytes already owed.
;
; It also REMOVES a hazard rather than trading one. Parked in this wait, an
; unsolicited `<id>,CONNECT` or `<id>,CLOSED` from the module ends it and then
; fails to parse as a +IPD header, which reaches rx_timeout and therefore the
; reset described above — the WiFi build does that today, every time a client
; disconnects while the stub is idle. In main_loop the same line is consumed
; silently by transport_byte_available.
;
; FIVE SECONDS. Long enough that no gap inside an interaction reaches it —
; DeZog's stepping traffic is milliseconds apart — and short enough that the
; border and the keyboard come back within five seconds of the last command
; rather than never. The cost of being wrong on the short side is a poll loop
; the debugger already runs whenever no client is attached.
;
; ONE NUMBER, TWO LOOPS, DIFFERENT COSTS. Each transport turns this into its own
; pass count from its own measured per-iteration T-state cost, so both land near
; the same wall time; see UART_WAIT_RX_PASSES and ESP_WAIT_RX_PASSES.
;
; ZERO MEANS NO BOUND, and it is not a tuning value: it assembles the loop
; exactly as it was before this existed, which is the negative control
; test/run-no-hang.sh needs. See there.
 IFNDEF TRANSPORT_WAIT_RX_SECONDS
TRANSPORT_WAIT_RX_SECONDS:  equ 5
 ENDIF


; Program states
PRGM_IDLE:		equ 1	; Waiting for a new program (at program start and after CMD_CLOSE)
PRGM_LOADING:	equ 2	; After CMD_INIT until the first CMD_CONTINUE
PRGM_STOPPED:	equ 3	; After breakpoint or NMI
PRGM_RUNNING:	equ 4	; After CMD_CONTINUE
