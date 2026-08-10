;===========================================================================
; mf_rom.asm
;
; Contains mainly the NMI routine and the code to copy the debugger to bank 7.
;===========================================================================

 IFDEF MF_FAKE
; For unit testing:
MF_ORIGIN_ROM:  equ 0x6000  ; For testing another origin is defined
MF_DIFF_TO_RAM:  equ main_end-MAIN_ADDR    ; Just after the debugger program
 ELSE
MF_ORIGIN_ROM:   equ 0x0000
MF_DIFF_TO_RAM:  equ MF_ORIGIN_ROM+0x2000-MF.main_prg_copy ; At 0x2000
 ENDIF


 IFNDEF UNIT_TEST
    OUTPUT MF_NMI_BIN
 ENDIF

;===========================================================================
; ROM for Multiface.
;===========================================================================
    MODULE MF

    ORG MF_ORIGIN_ROM

    defs 0x38
    ei
    ret

    defs MF_ORIGIN_ROM+0x66-$

;===========================================================================
; NMI: 0x0066
; Is executed if the M1 (yellow) button is pressed for the Multiface.
; The NMI cannot be interrupted by a maskable interrupt and it
; will not be interrupted by another NMI as the M1 button is not re-activated
; before paging out the MF ROM/RAM at the end of the routine.
;===========================================================================
nmi66h:
    ; Save the SP
    ld (MF.backup_sp),sp
    ; Change SP to be sure that it is inside RAM, so change it to MF RAM for now.
    ld sp,MF.stack.top

    ; Save to MF stack
    push af, bc

    ; Core 03.01.10: Check for the cause of the NMI and return if not a button press
    ld a,REG_RESET
    ld bc,IO_NEXTREG_REG
    out (c),a
    ; Read register
    inc b
    in a,(c)
    and 00011100b
;    and 0
;    or 1
    jr z,.is_button_cause

    IF 0
    ; Change border to blue
    ld a,BLUE
    out (BORDER),a
    ENDIF

    ; Immediately return if there is some other reason than a button press

    ; Clear reason bits
    in a,(c)    ; Read again
    and 10000000b  ; Preserve esp/expbus bit
    nextreg REG_RESET,a

    ; RETN
    pop bc, af
    ld sp,(MF.backup_sp)
    retn

.is_button_cause:

    IF 0
    ; Change border
    ld a,(MF.border_color)
    inc a
    and 0x07
    ld (MF.border_color),a
    out (BORDER),a
    ENDIF

    ; First backup contents of IO_NEXTREG_REG
    ld bc,IO_NEXTREG_REG
    in a,(c)
    push af

    ; Now backup main slot.
    ld a,REG_MMU+MAIN_SLOT
    out (c),a
    ; Read register
    inc b
    in a,(c)	; A contains the previous bank number for MAIN_SLOT

    ; Page in slot 7
    nextreg REG_MMU+MAIN_SLOT,MAIN_BANK
    ; Remember what slot 7 held — deliberately NOT in slot_backup.slot7.
    ;
    ; Two different questions are being answered from this one byte, and they
    ; only have the same answer when the NMI interrupted a RUNNING debuggee:
    ;   "who was executing?"        — asked below, on every press
    ;   "which bank does the       — meant by slot_backup.slot7, which
    ;    debuggee get back?"          restore_registers pages in on continue
    ; Writing it straight to slot_backup.slot7 conflated them: pressing M1
    ; while the debugger was STOPPED at a breakpoint overwrote the debuggee's
    ; bank (saved by dbg_enter) with MAIN_BANK, because that is what slot 7
    ; holds while the debugger itself executes — and the next CMD_CONTINUE
    ; then paged the DEBUGGER's bank into the debuggee's slot 7.
    ; It lives in MF RAM rather than in the debugger's data because it
    ; describes this NMI entry, like MF.backup_sp beside it, and because MF
    ; RAM costs no bytes of the 8192-byte ROM image.
    ld (MF.nmi_slot7),a

    ; Save IO_NEXTREG_REG and the clock speed — into MF RAM, and deliberately
    ; NOT into backup.*, for MF.nmi_slot7's reason two and eleven instructions
    ; along (issue #37). The same one byte was answering two questions:
    ;   "what was the machine like before this NMI?"  — true on every press,
    ;    and what the immediate return below has to put back
    ;   "what does the debuggee get back?"            — meant by backup.*,
    ;    which restore_registers hands over on continue
    ; They agree only when the NMI interrupted a RUNNING debuggee. Pressing M1
    ; while the debugger was STOPPED overwrote the debuggee's saved clock speed
    ; with the DEBUGGER's, which is 28 MHz — init_main_bank leaves the machine
    ; there and it idles there — so the next CMD_CONTINUE handed the debuggee
    ; back at the wrong speed. Fatal to anything doing contended-memory, tape
    ; or beeper timing, and invisible to everything else, which is why it went
    ; two builds without a check.
    ; .break_into_debuggee does NOT copy these across, unlike nmi_slot7:
    ; mf_nmi_button_pressed does, at .save_registers_continue, and it is that
    ; path's only caller. There rather than here because A must survive to
    ; save_registers, and because these bytes cost the debugger half 12 there
    ; and this half a 16-byte step here — the MF ROM half is exactly full.
    pop af
    ld (MF.nmi_io_next_reg),a

    ; Save clock
    ld a,REG_TURBO_MODE
    dec b   ; IO_NEXTREG_REG
    out (c),a
    ; Read register
    inc b
    in a,(c)
    ld (MF.nmi_speed),a

    ; Check for Symbol Shift being pressed the same time -> Init
    ld bc,PORT_KEYB_BNMSHIFTSPACE
    in a,(c)
    bit 1,a ; Symbol Shift
    jr z,init_main_bank

    ; Speed up
    nextreg REG_TURBO_MODE,RTM_28MHZ

    ; Compare with magic number
    push hl

    if 01
    ld a,(main_prg_copy+magic_number_a)
    ld hl,MAIN_ADDR+magic_number_a
    cp (hl)
    jr nz,init_main_bank
    ld a,(main_prg_copy+magic_number_b)
    inc hl
    cp (hl)
    jr nz,init_main_bank
    ld a,(main_prg_copy+magic_number_c)
    ld hl,MAIN_ADDR+magic_number_c
    cp (hl)
    jr nz,init_main_bank
    ld a,(main_prg_copy+magic_number_d)
    inc hl
    cp (hl)
    jr nz,init_main_bank
    ; Also check build time
    ld a,(main_prg_copy+build_time_rel)
    ld hl,MAIN_ADDR+build_time_rel
    cp (hl)
    jr nz,init_main_bank
    ld a,(main_prg_copy+build_time_rel+1)
    inc hl
 ;inc a
    cp (hl)
    jr nz,init_main_bank
    endif

    pop hl, bc

    ; Check if program was already stopped
    ld a,(prgm_state)
    cp PRGM_RUNNING
    jr z,.break_into_debuggee

    ; No debuggee is running. Upstream read that as "the debugger itself is
    ; executing" and declined the NMI — but a matching magic number and build
    ; time only prove the IMAGE is in MAIN_BANK, not that it is executing:
    ; a soft reset leaves RAM intact, so after one the same state means
    ; NextZXOS is executing over a stale image (issue #26). Declining then is
    ; worse than useless, because the entry path above has already paged
    ; MAIN_BANK into slot 7 and the immediate return never restores it.
    ; The debugger executes FROM MAIN_BANK in slot 7, so what slot 7 held at
    ; this NMI — MF.nmi_slot7, taken above — settles who was executing.
    ; This test must stay AFTER the PRGM_RUNNING one: while a debuggee runs,
    ; slot 7 holds the DEBUGGEE's bank, and testing it first would send every
    ; manual break through init_main_bank.
    ld a,(MF.nmi_slot7)
    cp MAIN_BANK
    jr nz,init_main_bank	; Stale image, NextZXOS executing: re-initialize
    jp mf_nmi_button_pressed_immediate_return

.break_into_debuggee:
    ; The NMI interrupted a running debuggee, so slot 7 held the DEBUGGEE's
    ; bank. THIS is the one path on which that value is what continue must
    ; page back, and the only one that may write it: the immediate return
    ; below leaves slot_backup.slot7 alone so that a press taken while
    ; stopped cannot destroy what dbg_enter saved, and init_main_bank
    ; recopies the image, which resets it anyway.
    ; MF.nmi_io_next_reg and MF.nmi_speed are the same story and are copied the
    ; same way, but in mf_nmi_button_pressed below rather than here — A must
    ; survive the pop into save_registers, and this half has no bytes left.
    ld a,(MF.nmi_slot7)
    ld (slot_backup.slot7),a

    ; Restore registers from MF stack
    pop af

    jp mf_nmi_button_pressed


;===========================================================================
; Initializes the main bank. I.e. copies the code from MF to MAIN_BANK.
;===========================================================================
init_main_bank:
    di
    ; Switch clock
    nextreg REG_TURBO_MODE,RTM_3MHZ
    ; Wait and flash the border
    ld bc,0x4000
.wait:
    ld a,c
    srl a : srl a : srl a
    and 0x07
    out (BORDER),a
    dec bc
    ld a,c
    or b
    jr nz,.wait
    out (BORDER),a  ; a is 0 = BLACK
    ; pop bc, af ; doesn't matter. program control is now moved to dezog.

    ; Maximize clock speed
    nextreg REG_TURBO_MODE,RTM_28MHZ

    ; Reset layer 2 writing/reading
    ld bc,LAYER_2_PORT
    xor a
    out (c),a

    ; The main program needs to be copied to MAIN_BANK
    ; Page in MAIN_BANK
    nextreg REG_MMU+MAIN_SLOT,MAIN_BANK
    MEMCOPY MAIN_ADDR, main_prg_copy, MF_DIFF_TO_RAM

    ; Jump to main bank
    jp main_bank_entry


; Align to 16 bytes.
    ALIGN 16, 0

 IFNDEF UNIT_TEST
    OUTEND
 ENDIF


;===========================================================================
; This here contains a copy of the main debug program.
; It will be copied from here into the MAIN_BANK/MAIN_SLOT.
;===========================================================================

main_prg_copy:
    ; The actual code is copied in the make file target mf_rom.
    ; ...



;===========================================================================
; The MF RAM area.
;===========================================================================
    defs MF_DIFF_TO_RAM


; The Multiface stack. Used only for a very short timeframe.
stack:
    defs 2*20
.top:

; Used to backup the debugged program's SP.
backup_sp:      defw 0

; The bank that was in MAIN_SLOT when this NMI was taken, before the entry
; path paged MAIN_BANK in over it. Scoped to the NMI entry, like backup_sp,
; and NOT the same thing as slot_backup.slot7 — see nmi66h.
nmi_slot7:      defb 0

; The IO_NEXTREG_REG latch and the clock speed as this NMI found them, for
; nmi_slot7's reason and with the same scope — see issue #37 and nmi66h.
; mf_nmi_button_pressed_immediate_return puts them back; only
; mf_nmi_button_pressed, which runs when a RUNNING debuggee was interrupted,
; copies them into backup.*.
; They cost no bytes of the 8192-byte ROM image: OUTEND is above, so nothing
; from here down is emitted.
nmi_io_next_reg: defb 0
nmi_speed:       defb 0

    ENDMODULE
