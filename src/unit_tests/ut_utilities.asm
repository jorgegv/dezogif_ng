;========================================================
; ut_utilities.asm
;
; Unit tests for the miscelleanous subroutines.
;========================================================


    MODULE ut_utilities

; Data area for testing

    nop

; Test that register is set correctly.
UT_write_read_slot:
.free_slot:	equ ((UT_write_read_slot+2*0x2000)>>13)&0x07
    ; Remember currently used bank
    ld a,.free_slot+REG_MMU
    call read_tbblue_reg
    push af		; Remember

    ; Write
    ;ld a,.free_slot+REG_MMU
    ;ld d,29	; bank 29
    ;call write_tbblue_reg
    WRITE_TBBLUE_REG .free_slot+REG_MMU,29	; bank 29

    ; Read
    ld a,.free_slot+REG_MMU
    call read_tbblue_reg
    nop ; TEST ASSERTION A == 29

    ; Restore previous used bank
    pop de
    ;ld a,.free_slot+REG_MMU
    ;call write_tbblue_reg
    WRITE_TBBLUE_REG .free_slot+REG_MMU,d
 TC_END


; Test division routine.
; HL = HL/E
UT_div_hl_e:
    ld hl,0
    ld e,7
    call div_hl_e
    nop ; TEST ASSERTION HL == 0

    ld hl,2*3
    ld e,3
    call div_hl_e
    nop ; TEST ASSERTION HL == 2

    ld hl,2*3+1
    ld e,3
    call div_hl_e
    nop ; TEST ASSERTION HL == 2

    ld hl,2*3+2
    ld e,3
    call div_hl_e
    nop ; TEST ASSERTION HL == 2

    ld hl,7*89
    ld e,89
    call div_hl_e
    nop ; TEST ASSERTION HL == 7

    ld hl,65535
    ld e,1
    call div_hl_e
    nop ; TEST ASSERTION HL == 65535

    ld hl,65535
    ld e,2
    call div_hl_e
    nop ; TEST ASSERTION HL == 32767

 TC_END


; Test integer to ascii routine (2 digits).
UT_itoa_2digits:
    ld de,.output
    ld a,7
    call itoa_2digits
    nop ; TEST ASSERTION DE == ut_utilities.UT_itoa_2digits.output+1
    TEST_MEMORY_BYTE .output, '0'
    TEST_MEMORY_BYTE .output+1, '7'
    TEST_MEMORY_BYTE .output+2, 0

    ld de,.output
    ld a,0
    call itoa_2digits
    TEST_MEMORY_BYTE .output, '0'
    TEST_MEMORY_BYTE .output+1, '0'
    TEST_MEMORY_BYTE .output+2, 0

    ld de,.output
    ld a,10
    call itoa_2digits
    TEST_MEMORY_BYTE .output, '1'
    TEST_MEMORY_BYTE .output+1, '0'
    TEST_MEMORY_BYTE .output+2, 0

    ld de,.output
    ld a,21
    call itoa_2digits
    TEST_MEMORY_BYTE .output, '2'
    TEST_MEMORY_BYTE .output+1, '1'
    TEST_MEMORY_BYTE .output+2, 0

    ld de,.output
    ld a,19
    call itoa_2digits
    TEST_MEMORY_BYTE .output, '1'
    TEST_MEMORY_BYTE .output+1, '9'
    TEST_MEMORY_BYTE .output+2, 0

    ld de,.output
    ld a,99
    call itoa_2digits
    TEST_MEMORY_BYTE .output, '9'
    TEST_MEMORY_BYTE .output+1, '9'
    TEST_MEMORY_BYTE .output+2, 0

    ; Invalid input: check that only 2 bytes are written
    ld de,.output
    ld a,100
    call itoa_2digits
    nop ; TEST ASSERTION DE == ut_utilities.UT_itoa_2digits.output+1
    TEST_MEMORY_BYTE .output, '?'
    TEST_MEMORY_BYTE .output+1, '?'
    TEST_MEMORY_BYTE .output+2, 0

    ; Invalid input: check that only 2 bytes are written
    ld de,.output
    ld a,255
    call itoa_2digits
    nop ; TEST ASSERTION DE == ut_utilities.UT_itoa_2digits.output+1
    TEST_MEMORY_BYTE .output, '?'
    TEST_MEMORY_BYTE .output+1, '?'
    TEST_MEMORY_BYTE .output+2, 0
 TC_END
.output:	defb 0,0,0



; Test integer to ascii routine (5 digits).
UT_itoa_5digits:
    ld de,.output
    ld hl,7
    call itoa_5digits
    nop ; TEST ASSERTION DE == ut_utilities.UT_itoa_5digits.output+4
    TEST_MEMORY_BYTE .output, '0'
    TEST_MEMORY_BYTE .output+1, '0'
    TEST_MEMORY_BYTE .output+2, '0'
    TEST_MEMORY_BYTE .output+3, '0'
    TEST_MEMORY_BYTE .output+4, '7'
    TEST_MEMORY_BYTE .output+5, 0

    ld de,.output
    ld hl,0
    call itoa_5digits
    TEST_MEMORY_BYTE .output, '0'
    TEST_MEMORY_BYTE .output+1, '0'
    TEST_MEMORY_BYTE .output+2, '0'
    TEST_MEMORY_BYTE .output+3, '0'
    TEST_MEMORY_BYTE .output+4, '0'
    TEST_MEMORY_BYTE .output+5, 0

    ld de,.output
    ld hl,99
    call itoa_5digits
    TEST_MEMORY_BYTE .output, '0'
    TEST_MEMORY_BYTE .output+1, '0'
    TEST_MEMORY_BYTE .output+2, '0'
    TEST_MEMORY_BYTE .output+3, '9'
    TEST_MEMORY_BYTE .output+4, '9'
    TEST_MEMORY_BYTE .output+5, 0

    ld de,.output
    ld hl,100
    call itoa_5digits
    TEST_MEMORY_BYTE .output, '0'
    TEST_MEMORY_BYTE .output+1, '0'
    TEST_MEMORY_BYTE .output+2, '1'
    TEST_MEMORY_BYTE .output+3, '0'
    TEST_MEMORY_BYTE .output+4, '0'
    TEST_MEMORY_BYTE .output+5, 0

    ld de,.output
    ld hl,2345
    call itoa_5digits
    TEST_MEMORY_BYTE .output, '0'
    TEST_MEMORY_BYTE .output+1, '2'
    TEST_MEMORY_BYTE .output+2, '3'
    TEST_MEMORY_BYTE .output+3, '4'
    TEST_MEMORY_BYTE .output+4, '5'
    TEST_MEMORY_BYTE .output+5, 0

    ld de,.output
    ld hl,0xFFFF
    call itoa_5digits
    TEST_MEMORY_BYTE .output, '6'
    TEST_MEMORY_BYTE .output+1, '5'
    TEST_MEMORY_BYTE .output+2, '5'
    TEST_MEMORY_BYTE .output+3, '3'
    TEST_MEMORY_BYTE .output+4, '5'
    TEST_MEMORY_BYTE .output+5, 0

 TC_END
.output:	defb 0,0,0,0,0,0


; Tests that copper_break_arm REFUSES to install the asynchronous-break Copper
; list unless prgm_state says nothing is loaded, running or stopped.
;
; THE DIRECTION TESTED HERE IS THE DANGEROUS ONE. If the guard ever goes inert —
; and the way it goes inert is quiet, by somebody moving cmd_init's call BELOW
; the write of PRGM_LOADING two instructions under it — then a re-attach to a
; running debuggee installs over that debuggee's OWN Copper list. The list is
; write-only (zxnext.vhd:3959-3976, :3980-3998), so its raster effects are gone
; for the session and nothing can put them back. That path is ordinary: the
; client vanishes with no CMD_CLOSE, a new one connects, its CMD_INIT is the
; first byte the poll sees, and cmd_call dispatches on the command byte with no
; prgm_state guard of its own. Found in review, 2026-08-15.
;
; The OTHER direction — a first attach really does install — is covered end to
; end by bench W10, whose three-byte fixture installs no list of its own and is
; still stopped by CMD_PAUSE. It is deliberately not repeated here: asserting it
; would mean leaving a live Copper list raising a Multiface NMI 50 times a
; second inside a unit-test run whose SD image carries the STOCK Multiface ROM,
; which would take the screen. Refusing installs nothing, so this test starts no
; Copper and cannot flake that way.
;
; NR 0x06 bit 3 is the observable, and it is the FIRST thing copper_break_install
; writes (through mf_nmi_enable), so it is set whenever the guard lets anything
; through. It reads back (zxnext.vhd:5900) and shipped code already relies on
; that read, unlike NR 0x62's.
;
; SHOWN RED, and the red did two things. With the three guard instructions taken
; out and nothing else changed, this test reports UT-FAIL — so it can fail, and
; it fails on exactly the thing it is about. It ALSO took the whole suite down
; with it: 5 of 71 cases ran and no UT-DONE line was printed, because the install
; it should have refused left a Copper list raising a Multiface NMI 50 times a
; second and the image's stock Multiface ROM took the machine. That is the
; hazard the paragraph above gives as the reason for not asserting the install
; direction here, measured rather than argued.
UT_copper_break_arm_refuses_re_attach:
    ; The "C" key is on, so the only thing that can refuse is the guard.
    MEMSETBYTE copper_break_enabled, 1
    ; A debuggee exists. PRGM_STOPPED is what a re-attach really sees: the poll
    ; breaks in through send_ntf_pause, which sets it, before cmd_loop reads the
    ; command that caused the break.
    MEMSETBYTE prgm_state, PRGM_STOPPED

    ; Clear the MF NMI gate so that "still clear" means "nothing installed".
    ; The ORIGINAL byte is kept, not the masked one, so the restore below puts
    ; back what was there rather than asserting what it must have been.
    ld a,REG_PERIPHERAL_2
    call read_tbblue_reg
    push af		; The original, bit 3 and all
    and 11110111b
    nextreg REG_PERIPHERAL_2,a

    call copper_break_arm

    ld a,REG_PERIPHERAL_2
    call read_tbblue_reg
    and 00001000b
    nop ; TEST ASSERTION A == 0

    ; Put the gate back exactly as it was found. Safe with no list installed:
    ; the Copper is not running, so re-arming the gate cannot produce an NMI.
    pop af
    nextreg REG_PERIPHERAL_2,a
 TC_END


    ENDMODULE
