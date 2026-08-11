;===========================================================================
; pause_transparency.asm
;
; A DEBUGGEE THAT CARRIES THE ASYNCHRONOUS-BREAK COPPER LIST AND WATCHES
; WHETHER THE POLL GIVES ITS MACHINE BACK UNCHANGED — over minutes, not over
; the one second bench check W8 runs for.
;
; It is built for TWO ways of being driven, from one source:
;
;   build/pause-transparency.bin   written over DZRP by
;                                  test/dzrp/pause-transparency.py, which
;                                  resumes it with no breakpoint, lets it run,
;                                  and then sends CMD_PAUSE.
;   build/pause-transparency.nex   loaded by DeZog in VS Code, so that the
;                                  Pause BUTTON can be clicked at it — which it
;                                  was, on a real Next, 2026-08-11. That was the
;                                  last path in M2 nothing had exercised: W8 and
;                                  H7 both speak DZRP directly.
;
; WHY A DETECTOR AT ALL: a healthy poll is INVISIBLE — that is its whole
; specification — so there is nothing about one for a test to observe. What can
; be observed is the interrupted program noticing that it was not given its
; machine back. The poll fires ~50 times a second, so a leak that is invisible
; in W8's one second gets 3000 chances a minute here.
;
; WHAT IT WATCHES, and both are state doc/ASYNCHRONOUS-BREAK-DESIGN.md says the
; poll path must save and restore:
;
;   MMU slot 7        the poll pages MAIN_BANK in to reach the debugger's image
;                     and must page the interrupted program's bank back.
;                     Forgetting is issue #26 — which hung a real Next — on a
;                     50 Hz timer.
;   the NextREG       nmi66h selects NR 0x02 to read the NMI cause and NR 0x57
;   select latch      to move slot 7, so the program's own selected register
;                     must be put back. Forgetting it is harmless once per
;                     button press and a recurring corruption of the debuggee
;                     at 50 Hz, which is why M2 had to fix it (issue #37).
;
; THE LATCH HALF IS THE ONE test/copper_poll.asm CANNOT DO, AND THAT WAS
; MEASURED THERE RATHER THAN ARGUED. T9's fixture watches slot 7 by selecting
; NR 0x57 and never writing port 0x243B again, so that one `in` reads the bank
; if the latch survived. It cannot also watch the latch: the poll's own
; `.save_slot7_page_in` writes 0x243B with 0x57, so a build with the latch
; restore DELETED leaves the latch holding exactly the value that fixture
; wanted, and its red-first came out GREEN.
;
; This one watches a register that is NOT 0x57 — so a poll that fails to
; restore the latch leaves 0x57 selected and the watch read returns PROBE_BANK
; instead of the captured value. That inverts the trap: the value a broken poll
; leaves behind is the one value this fixture is certain to notice.
;
; AND IT REFUSES TO BE BLIND. The detection above fails in exactly one case —
; the watch register's value happening to equal PROBE_BANK — so the two are
; compared at startup and FAULT_BLIND is latched if they collide, rather than
; the check silently becoming a check of nothing. The watch register's value is
; whatever the machine reports, so a probability argument would have been the
; wrong instrument.
;
; WHY THE WATCH REGISTER IS NR 0x07: it reads back the CPU clock, so one `in`
; covers the latch AND the design's claim that the poll does not change the
; machine's speed (bits 5:4 = actual, 1:0 = programmed; zxnext.vhd:5903). On a
; fault the two are told apart by asking for NR 0x07 by name and reading again:
; if it matches then, the selection had moved; if it still differs, the
; selection was fine and the clock changed.
;
; NO `ei : halt : di` PROLOGUE, DELIBERATELY, and test/copper_poll.asm having
; one is not a precedent for this file. That prologue works around jnext's
; `--inject` never clearing the CPU's HALTED flag (jnext#248), and nothing here
; is injected: the DZRP client writes this with CMD_WRITE_MEM and the .nex is
; loaded by a loader. In both cases the CPU has long since left the `halt`
; NextZXOS idles in.
;
; THIS PROGRAM DOES NOT RETURN. It repoints MMU slot 7, which is where
; NextZXOS's stack lives, and then spins for ever with interrupts off. That is
; what makes it a debuggee: the only ways out are the debugger and the reset
; button. Reset the machine when the run is over.
;
; Instruction encoding, from device/copper.vhd:91-104:
;
;   WAIT   bit 15 = 1, bits 14:9 = hpos, bits 8:0 = line
;   MOVE   bit 15 = 0, bits 14:8 = NextREG number, bits 7:0 = value
;===========================================================================

    DEVICE ZXSPECTRUMNEXT

TBBLUE_REGISTER_SELECT: equ 0x243B
TBBLUE_REGISTER_ACCESS: equ 0x253B

REG_RESET:              equ 0x02    ; bit 3 = generate Multiface NMI
REG_PERIPHERAL_2:       equ 0x06    ; bit 3 = M1 button / MF NMI enable
REG_TURBO_MODE:         equ 0x07    ; the watch register; see the header
REG_MMU7:               equ 0x57    ; the bank in 0xE000-0xFFFF
REG_COPPER_DATA:        equ 0x60    ; 8-bit write, auto-increment
REG_COPPER_ADDR_LSB:    equ 0x61
REG_COPPER_CONTROL:     equ 0x62    ; bits 7:6 start control, bits 2:0 addr MSB

REG_WATCH:              equ REG_TURBO_MODE

COPPER_LINE:            equ 100     ; mid-screen, well clear of the border
COPPER_STOP:            equ 00000000b
COPPER_RUN_LOOP:        equ 01000000b

COPPER_WAIT:            equ 0x8000 + COPPER_LINE
COPPER_WAIT_HI:         equ (COPPER_WAIT >> 8) & 0xFF
COPPER_WAIT_LO:         equ COPPER_WAIT & 0xFF
COPPER_MOVE:            equ (REG_RESET << 8) | 0x08
COPPER_MOVE_HI:         equ (COPPER_MOVE >> 8) & 0xFF
COPPER_MOVE_LO:         equ COPPER_MOVE & 0xFF

; PROBE_BANK is 30 for test/copper_poll.asm's reasons, which hold here too: it
; must not be MAIN_BANK (94), which is what a poll that failed to restore slot 7
; leaves behind; and it must be above 3, because a lost latch can leave NR 0x02
; selected, whose read is the esp/expbus bit plus two bits of reset history —
; 0x00-0x03 or 0x80-0x83 — and a probe bank in that range could be mistaken for
; a healthy read.
PROBE_BANK:             equ 30

; The bottom-right attribute cell. LIVENESS A HUMAN CAN SEE, and deliberately
; NOT the border: doc/ASYNCHRONOUS-BREAK-USER-HOWTO.md tells a user that the
; border resuming its cycle is how they know the DEBUGGER is executing again,
; so a debuggee that painted the border would destroy the one signal that
; procedure depends on.
LIVE_CELL:              equ 0x5AFF

STACK_TOP:              equ 0x9F00  ; in slot 4, so it survives the slot-7 move

FAULT_NONE:             equ 0
FAULT_WATCH:            equ 1       ; the select latch moved
FAULT_SPEED:            equ 2       ; the clock moved (the latch did not)
FAULT_SLOT7:            equ 3       ; MMU slot 7 came back wrong
FAULT_BLIND:            equ 4       ; the watch value collides with PROBE_BANK

    ORG 0x8000

start:
    di
    ld sp,STACK_TOP

    ; --- the results start clean, whichever way this was loaded -------------
    ; Done here rather than by the client so that the .nex path gets it too,
    ; and so that a re-run cannot inherit a stale verdict.
    ld hl,results
    ld de,results + 1
    ld bc,results_end - results - 1
    ld (hl),FAULT_NONE
    ldir

    ; --- NR 0x06 |= bit 3 : without this every MF NMI source is gated off ---
    ; zxnext.vhd:2090 ANDs every Multiface NMI source with it, the Copper one
    ; included, and its power-on value is 0. NextZXOS leaves it set, so these
    ; seven bytes remove a dependency on what the firmware left behind.
    ld bc,TBBLUE_REGISTER_SELECT
    ld a,REG_PERIPHERAL_2
    out (c),a
    ld bc,TBBLUE_REGISTER_ACCESS
    in a,(c)
    or 0x08
    out (c),a

    ; --- a known bank in slot 7, so that a lost restore is visible ----------
    ; NextZXOS's stack goes with it, which is why nothing below this line uses
    ; the stack: no CALL, no PUSH. The NMI does not need it either — nmi66h
    ; switches SP to MF RAM on entry and back on exit.
    nextreg REG_MMU7,PROBE_BANK

    ; --- capture what the machine says, rather than what this file assumes --
    ld bc,TBBLUE_REGISTER_SELECT
    ld a,REG_MMU7
    out (c),a
    ld bc,TBBLUE_REGISTER_ACCESS
    in a,(c)
    ld (slot7_expect),a

    ld bc,TBBLUE_REGISTER_SELECT
    ld a,REG_WATCH
    out (c),a
    ld bc,TBBLUE_REGISTER_ACCESS
    in a,(c)
    ld (watch_expect),a

    ; --- refuse to be a check of nothing ------------------------------------
    ; A poll that loses the latch leaves NR 0x57 selected, so the watch read
    ; returns the slot-7 bank. If that is what the watch register reads anyway,
    ; the two states are indistinguishable and this fixture cannot see the
    ; fault it exists for. Say so instead of passing.
    ld hl,slot7_expect
    cp (hl)
    jr nz,.armed
    ld a,FAULT_BLIND
    ld (fault_code),a
.armed:

    ; --- stop the Copper and put the write pointer at index 0 ---------------
    nextreg REG_COPPER_CONTROL,COPPER_STOP
    nextreg REG_COPPER_ADDR_LSB,0

    ; --- the list, MSB first: WAIT line,0 then MOVE $02,$08 -----------------
    nextreg REG_COPPER_DATA,COPPER_WAIT_HI
    nextreg REG_COPPER_DATA,COPPER_WAIT_LO
    nextreg REG_COPPER_DATA,COPPER_MOVE_HI
    nextreg REG_COPPER_DATA,COPPER_MOVE_LO

    ; --- run it from index 0, looping. The break is live from here. ---------
    nextreg REG_COPPER_CONTROL,COPPER_RUN_LOOP

    ; --- arm the detector ---------------------------------------------------
    ld bc,TBBLUE_REGISTER_SELECT
    ld a,REG_WATCH
    out (c),a

.loop:
    ; 1) THE LATCH AND THE CLOCK, in one read: the watch register is still
    ;    selected from the previous pass, so this reads it only if the poll put
    ;    the selection back.
    ld bc,TBBLUE_REGISTER_ACCESS
    in a,(c)
    ld hl,watch_expect
    cp (hl)
    jr nz,.fault_watch

    ; 2) MMU slot 7
    ld bc,TBBLUE_REGISTER_SELECT
    ld a,REG_MMU7
    out (c),a
    ld bc,TBBLUE_REGISTER_ACCESS
    in a,(c)
    ld hl,slot7_expect
    cp (hl)
    jr nz,.fault_slot7

    ; 3) re-select the watch register for the next pass
    ld bc,TBBLUE_REGISTER_SELECT
    ld a,REG_WATCH
    out (c),a

    ; 4) the iteration counter, 32-bit little-endian, read back over DZRP
    ld hl,counter
    inc (hl)
    jr nz,.counted
    inc hl
    inc (hl)
    jr nz,.counted
    inc hl
    inc (hl)
    jr nz,.counted
    inc hl
    inc (hl)
.counted:

    ; 5) liveness a human can see across a room
    ld a,(counter + 1)
    ld (LIVE_CELL),a
    jr .loop

.fault_watch:
    ; A = the observed byte, HL -> watch_expect. Ask for NR 0x07 BY NAME and
    ; read again: if it matches now, the selection had moved; if it still
    ; differs, the selection was fine and the clock changed under us.
    ld d,a
    ld bc,TBBLUE_REGISTER_SELECT
    ld a,REG_WATCH
    out (c),a
    ld bc,TBBLUE_REGISTER_ACCESS
    in a,(c)
    ld hl,watch_expect
    cp (hl)
    ld c,FAULT_WATCH                ; `ld` does not touch the flags
    jr z,.fault_watch_record
    ld c,FAULT_SPEED
.fault_watch_record:
    ld a,d                          ; A = the observed byte again
    jr .record

.fault_slot7:
    ; A = the observed byte, HL -> slot7_expect
    ld c,FAULT_SLOT7

.record:
    ; A = observed, C = the fault code, HL -> the expected byte.
    ; ONLY THE FIRST FAULT IS KEPT: once the poll has damaged the machine there
    ; is no reason to believe the next reading, and the counter snapshot says
    ; how long it survived before it did.
    ld d,(hl)                       ; D = expected
    ld e,a                          ; E = observed
    ld a,(fault_code)
    or a
    jr nz,.recorded
    ld a,c
    ld (fault_code),a
    ld a,e
    ld (fault_observed),a
    ld a,d
    ld (fault_expected),a
    ld hl,counter
    ld de,fault_counter
    ld bc,4
    ldir
.recorded:
    ; Keep running rather than latching a spin, so that the client can still
    ; break in and read the record back — a fixture that stopped would make the
    ; pause itself untestable in exactly the run that found a fault.
    ld bc,TBBLUE_REGISTER_SELECT
    ld a,REG_WATCH
    out (c),a
    jr .loop

code_end:

;---------------------------------------------------------------------------
; The results, read back over DZRP after the break.
;
; THE ADDRESS IS PINNED BY AN ASSERT rather than shipped as a constant the
; client is trusted to keep in step. A client carrying a stale address would
; read a byte nothing writes and report a green it had not earned; making it a
; build error instead is the move src/main.asm already makes for
; ROM_MAGIC_ADDR. test/dzrp/pause-transparency.py carries the same numbers and
; says that this file is what pins them.
;
; They are OUTSIDE the saved image on purpose: the fixture zeroes them itself,
; so the .nex path gets a clean start too and the image stays the size of the
; code rather than the size of the gap.
;---------------------------------------------------------------------------
    ORG 0x9000
results:
counter:            defb 0, 0, 0, 0     ; iterations, 32-bit little-endian
fault_code:         defb 0              ; FAULT_*, 0 = nothing went wrong
fault_counter:      defb 0, 0, 0, 0     ; the iteration the first fault landed on
fault_observed:     defb 0
fault_expected:     defb 0
watch_expect:       defb 0              ; NR 0x07 as the machine reported it
slot7_expect:       defb 0              ; NR 0x57 as the machine reported it
results_end:

    ASSERT results == 0x9000
    ASSERT results_end - results == 13
    ASSERT code_end <= results           ; the code must not reach the results
    ASSERT STACK_TOP > results_end       ; nor the stack, if anything ever pushes

    SAVEBIN PAUSE_TRANSPARENCY_BIN, start, code_end - start

    SAVENEX OPEN PAUSE_TRANSPARENCY_NEX, start, STACK_TOP
    SAVENEX CORE 3, 1, 10               ; stackless NMI needs >= 03.01.10
    SAVENEX AUTO
    SAVENEX CLOSE
