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
; NEVER MOVE THIS. Its only value is being in the same place in every release
; we have ever shipped and will ever ship. A build that cannot fit below it
; must shrink, which is what the ASSERT in main.asm enforces.
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
;   dezogif_ng WiFi build 0008          26 columns of the 32 there are
;
; IT LIVES HERE, BESIDE rom_magic's DEFINITION, ON PURPOSE. Both say which
; fork, which transport and which build; a screen that disagreed with the
; block mfselect reads would be worse than no screen at all (issue #12). The
; only way to keep them in step is for both to be spelled from the same two
; symbols — ROM_VARIANT and BUILD_NUMBER_HEX — in a place where changing one
; and not the other is visibly wrong. Never introduce a second source for the
; build number: that conflation is what issue #4 and ERRORS.md are about.
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
    defb BUILD_NUMBER_HEX               ; the identity block's number, not a copy
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
; measured on hardware. Raising it is M3's baud negotiation and has to start
; here.
ESP_BAUDRATE:   equ 115200

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
