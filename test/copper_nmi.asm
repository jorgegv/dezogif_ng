;===========================================================================
; copper_nmi.asm
;
; Roadmap M0(c): a Copper list that raises the Multiface NMI at a chosen
; raster line, so the mechanism M2 depends on can be watched working before
; anything is built on it.
;
; This is NOT the stub's break mechanism — it is the proof that the hardware
; path exists and that jnext models it. Run against the SD image's stock
; Multiface ROM it must produce a takeover; run against our stub it must not,
; for the reason in test/nmi_trigger.asm — which since issue #22 is no longer
; "nmi66h serves button causes only" but "the poll declines where no debugger
; image is in MAIN_BANK", which is the state this fixture's run is in. Same
; outcome, different reason. test/copper_poll.asm is the fixture that exercises
; the poll itself rather than its decline.
;
; Instruction encoding, from device/copper.vhd:91-104 — not from a wiki:
;
;   WAIT   bit 15 = 1, bits 14:9 = hpos, bits 8:0 = line
;          fires when  vcount = line  and  hcount >= hpos*8 + 12
;   MOVE   bit 15 = 0, bits 14:8 = NextREG number, bits 7:0 = value
;          a MOVE of register 0 is a NOP and emits no write pulse
;
; so `MOVE $02,$08` — NextREG 0x02 bit 3, the Multiface NMI — is 0x0208, and
; `WAIT line,0` is 0x8000 + line.
;
; The list is written through NR 0x60 (8-bit write, auto-incrementing), MSB
; first, after NR 0x61 / NR 0x62 have been zeroed to put the write pointer at
; index 0. NR 0x62 bits 7:6 then start it: 01 = run from index 0 and loop
; (nextreg.txt:632-640).
;
; NR 0x06 bit 3 must be set first. zxnext.vhd:2090 ANDs *every* Multiface NMI
; source with it — the Copper one included — and its power-on value is 0.
; That gate is the correction recorded in ERRORS.md; do not remove it.
;===========================================================================

    DEVICE ZXSPECTRUMNEXT

TBBLUE_REGISTER_SELECT: equ 0x243B
TBBLUE_REGISTER_ACCESS: equ 0x253B

REG_RESET:              equ 0x02    ; bit 3 = generate Multiface NMI
REG_PERIPHERAL_2:       equ 0x06    ; bit 3 = M1 button / MF NMI enable
REG_COPPER_DATA:        equ 0x60    ; 8-bit write, auto-increment
REG_COPPER_ADDR_LSB:    equ 0x61
REG_COPPER_CONTROL:     equ 0x62    ; bits 7:6 start control, bits 2:0 addr MSB

COPPER_LINE:            equ 100     ; mid-screen, well clear of the border
COPPER_STOP:            equ 00000000b
COPPER_RUN_LOOP:        equ 01000000b

; WAIT line,0  =  0x8000 | (hpos<<9) | line , hpos = 0
COPPER_WAIT:            equ 0x8000 + COPPER_LINE
COPPER_WAIT_HI:         equ (COPPER_WAIT >> 8) & 0xFF
COPPER_WAIT_LO:         equ COPPER_WAIT & 0xFF
; MOVE $02,$08  =  (reg << 8) | value
COPPER_MOVE:            equ (REG_RESET << 8) | 0x08
COPPER_MOVE_HI:         equ (COPPER_MOVE >> 8) & 0xFF
COPPER_MOVE_LO:         equ COPPER_MOVE & 0xFF

    ORG 0x8000

start:
    ; --- NR 0x06 |= bit 3 : without this every MF NMI source is gated off ---
    ld bc,TBBLUE_REGISTER_SELECT
    ld a,REG_PERIPHERAL_2
    out (c),a
    ld bc,TBBLUE_REGISTER_ACCESS
    in a,(c)
    or 0x08
    out (c),a

    ; --- stop the Copper and put the write pointer at index 0 ---
    ; (Z80N `nextreg reg,imm`; the read above needed ports, a write does not.)
    nextreg REG_COPPER_CONTROL,COPPER_STOP
    nextreg REG_COPPER_ADDR_LSB,0

    ; --- the list, MSB first: WAIT line,0 then MOVE $02,$08 ---
    nextreg REG_COPPER_DATA,COPPER_WAIT_HI
    nextreg REG_COPPER_DATA,COPPER_WAIT_LO
    nextreg REG_COPPER_DATA,COPPER_MOVE_HI
    nextreg REG_COPPER_DATA,COPPER_MOVE_LO

    ; --- run it from index 0, looping ---
    nextreg REG_COPPER_CONTROL,COPPER_RUN_LOOP

    ; Park. The NMI takes the CPU away from here; if it never fires, the bench
    ; sees an unchanged screen and says so.
.hang:
    jr .hang
end:

    SAVEBIN COPPER_NMI_BIN, start, end-start
