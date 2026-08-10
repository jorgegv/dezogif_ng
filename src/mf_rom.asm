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
; Is executed if the M1 (yellow) button is pressed for the Multiface, and —
; since M2 — if a SOFTWARE Multiface NMI is raised, which is what the
; asynchronous break's Copper list does 50 times a second.
; The NMI cannot be interrupted by a maskable interrupt and it
; will not be interrupted by another NMI as the M1 button is not re-activated
; before paging out the MF ROM/RAM at the end of the routine.
;
; THREE WAYS OUT, and each has its own tail:
;   .is_button_cause    the M1 button — upstream's path, unchanged
;   .software_cause     the M2 poll — see there
;   .other_cause        a DivMMC NMI or an I/O trap: not ours, decline
;===========================================================================
nmi66h:
    ; Save the SP
    ld (MF.backup_sp),sp
    ; Change SP to be sure that it is inside RAM, so change it to MF RAM for now.
    ld sp,MF.stack.top

    ; Save to MF stack
    push af, bc

    ; THE DEBUGGEE'S NEXTREG SELECT LATCH, READ BEFORE ANYTHING HERE SELECTS
    ; ANOTHER REGISTER — AND THAT ORDER IS A FIX, NOT A TIDY-UP.
    ;
    ; Upstream read it at .is_button_cause, i.e. AFTER the cause check has done
    ; `out (c),REG_RESET`, so what was saved was ALWAYS REG_RESET (2) and the
    ; debuggee's real latch was destroyed on every press. Measured 0x00 -> 0x02
    ; while issue #37's check was being written, and left alone there: it is a
    ; SECOND, pre-existing defect in the same three instructions, and it was
    ; harmless in practice because it needs a press to land between a debuggee's
    ; `out (c),reg` and its following `out (c),value` — once per button press,
    ; astronomically unlikely.
    ;
    ; M2 MAKES IT LIKELY. The poll takes this path ~50 times a second while the
    ; debuggee runs, so "astronomically unlikely per press" becomes a silent,
    ; recurring corruption of the program being debugged. So the latch is read
    ; ONCE, here, before the cause check selects anything — which serves every
    ; path below and is 4 bytes CHEAPER than the version it replaces, because
    ; .is_button_cause no longer has to re-select IO_NEXTREG_REG to read it.
    ;
    ; Every exit that returns to the interrupted code puts it back: .other_cause
    ; and .poll_decline through .return_to_interrupted below, and
    ; mf_nmi_button_pressed_immediate_return in mf.asm, which already read this
    ; byte and now finds the right value in it. The break paths hand it to
    ; backup.io_next_reg, which likewise now holds the debuggee's latch.
    ld bc,IO_NEXTREG_REG
    in a,(c)
    ld (MF.nmi_io_next_reg),a

    ; Core 03.01.10: Check for the cause of the NMI and return if not a button press
    ld a,REG_RESET
    out (c),a
    ; Read register
    inc b
    in a,(c)
    and 00011100b
;    and 0
;    or 1
    jr z,.is_button_cause

    ; BIT 3 IS A SOFTWARE MULTIFACE NMI, and since M2 that is a cause we serve.
    ; The three bits the mask keeps are, from zxnext.vhd:5890-5891:
    ;   bit 4  nr_02_iotrap                the I/O trap on 0x2FFD/0x3FFD
    ;   bit 3  nr_02_generate_mf_nmi       a CPU or Copper write — OURS
    ;   bit 2  nr_02_generate_divmmc_nmi   the DivMMC (drive) button
    ; It latches on any accepted NR 0x02 bit-3 write (:3843-3848), from the CPU
    ; or from the Copper alike — the two are muxed onto one untagged bus before
    ; nmi_gen_nr_mf computes (:4775-4777), so they CANNOT be told apart and the
    ; poll below is shaped so that it does not need to.
    ;
    ; BIT 4 IS THE OTHER SOFTWARE SUB-CAUSE OF A MULTIFACE NMI —
    ; `nmi_sw_gen_mf <= nmi_gen_nr_mf or nmi_gen_iotrap` (:3837) — and is still
    ; declined, deliberately: an I/O trap fires on a debuggee's port access, not
    ; on a raster line, so it is not the Copper's and is not a poll. Bit 2 is not
    ; ours at all.
    ;
    ; THE ANSWER IS TAKEN NOW AND CARRIED IN F ACROSS THE LATCH CLEAR, because
    ; both non-button causes have to clear it and doing it once is worth the
    ; three bytes of push/pop — not for the bytes alone, but because this is the
    ; read-modify-write whose mask is load-bearing (below) and one copy of it
    ; cannot drift from another.
    bit 3,a
    push af

    IF 0
    ; Change border to blue
    ld a,BLUE
    out (BORDER),a
    ENDIF

    ; Clear the cause bits — for BOTH non-button causes.
    ;
    ; NOT to re-arm the NMI: the hardware does that on RETN with no help from
    ; here. `cpu_retn_seen_i` is a generic ED-45 decoder
    ; (device/im2_control.vhd:236, wired at zxnext.vhd:4287), it clears mf_enable
    ; and nmi_active (device/multiface.vhd:137-148, :170-184), nmi_state then
    ; walks S_NMI_HOLD -> S_NMI_END -> S_NMI_IDLE (zxnext.vhd:2135-2148) where
    ; nmi_mf is cleared (:2102-2105) and nmi_accept_cause is true again (:2164).
    ; And nmi_gen_nr_mf is a write-EVENT pulse rather than a level off this latch
    ; (:3829-3832), so the next `MOVE $02,$08` re-triggers whatever it holds.
    ;
    ; What it buys is CAUSE REPORTING FOR THE NEXT NMI. Leave bit 3 set and the
    ; next genuine M1 BUTTON press reads a non-zero 00011100b mask above and is
    ; misrouted down the poll path — a button press that silently became a poll.
    ;
    ; `and 10000000b` is upstream's mask and is LOAD-BEARING: bits 1:0 WRITTEN
    ; trigger a soft/hard reset (zxnext.vhd:6370-6371) while READ they are reset
    ; history (:1306, :1732-1739) and are non-zero in ordinary operation, so a
    ; read-modify-write of this register resets the machine — and on the poll
    ; path that would be 50 times a second.
    in a,(c)    ; Read again
    and 10000000b  ; Preserve esp/expbus bit
    nextreg REG_RESET,a

    pop af      ; the bit-3 answer, and A back to the masked cause
    jr nz,.software_cause

    ; Some other reason than a button press: immediately return.
    ;
    ; Put the debuggee's NextREG select latch back and RETN. Shared with
    ; .poll_decline, which arrives with the latch already cleared too.
    ;
    ; NOTHING PAGES THE MULTIFACE OUT HERE, and that is not an omission: RETN
    ; does it in hardware. `mf_enable <= '0'` on cpu_retn_seen_i
    ; (device/multiface.vhd:178), which is also what clears nmi_active (:144)
    ; and so re-arms the next NMI. Upstream's decline has always relied on it.
.return_to_interrupted:
    ld bc,IO_NEXTREG_REG
    ld a,(MF.nmi_io_next_reg)
    out (c),a

    ; RETN
    pop bc, af
    ld sp,(MF.backup_sp)
    retn


;===========================================================================
; A SOFTWARE MULTIFACE NMI: the asynchronous-break poll (issue #22, M2).
;
; Raised by a two-instruction Copper list — `WAIT line,0` / `MOVE $02,$08` —
; that THE DEBUGGED PROGRAM installs, not the debugger. That division is the
; whole design and it is worth stating here, because the obvious alternative
; costs something irrecoverable: the Copper's 1024-instruction list is
; WRITE-ONLY (both RAMs discard their CPU-side read output, zxnext.vhd:3959-3976
; and :3980-3998; NR 0x60/0x63 have no read decode, :6286-6287), so a debugger
; that installed the list could never restore what it overwrote. A program that
; carries the two instructions itself keeps its own Copper program, and one that
; does not simply gets no asynchronous break. See
; doc/ASYNCHRONOUS-BREAK-DESIGN.md.
;
; THIS PATH RUNS ~50 TIMES A SECOND WHILE THE DEBUGGEE RUNS, so it is written
; to leave as fast as it can and to touch as little as possible:
;
;   * IT DOES NOT CHANGE THE CLOCK SPEED unless it breaks in. The button path
;     switches to 28 MHz before it has decided anything; doing that here would
;     move the machine's clock 50 times a second, which for contended-memory,
;     tape or beeper code is a different and worse perturbation than the stolen
;     cycles themselves (plan §10). The poll runs at the DEBUGGEE's clock.
;   * IT NEVER REACHES init_main_bank. Symbol Shift is not polled and a magic
;     mismatch declines rather than re-initialising — a poll that re-copied the
;     debugger over a running session would be catastrophic and it fires by
;     itself, with nobody's finger on anything.
;   * IT RESTORES MMU SLOT 7. The button path's immediate return deliberately
;     does not, because it only ever runs while the DEBUGGER executes and slot 7
;     legitimately holds MAIN_BANK. This fires while the DEBUGGEE executes, so
;     not restoring it is issue #26 again, on a timer.
;
; The magic check is the safety gate and is not optional: prgm_state lives in
; MAIN_BANK, so its value cannot be trusted — nor may anything be CALLED there —
; until the bank has been shown to hold OUR image. Two bytes rather than the
; button path's six, because this runs every frame; a bank that matches both by
; accident and is not ours is one chance in 65536 of a jump into it, against a
; button path that has always accepted the same evidence plus four more bytes.
;===========================================================================
.software_cause:
    ; The cause latch is already cleared — see above, where both non-button
    ; causes share that read-modify-write.
    ;
    ; Save what slot 7 held and page MAIN_BANK in. Same byte and same meaning as
    ; the button path's: "who was executing", answered for THIS NMI.
    call .save_slot7_page_in

    ; IS OUR IMAGE REALLY THERE? Compared as one word rather than two bytes:
    ; magic_number_a and magic_number_b are adjacent (data_const.asm), so
    ; `ld hl,(...)` / `ld bc,(...)` / `sbc hl,bc` checks both in 4 bytes fewer
    ; than the button path's cp/inc pair. BC is dead after this — every path out
    ; of here reloads it.
    push hl
    ld hl,(MAIN_ADDR+magic_number_a)
    ld bc,(main_prg_copy+magic_number_a)
    or a
    sbc hl,bc
    pop hl
    jr nz,.poll_decline

    ; Ours. The rest of the decision needs no MF ROM bytes and is in the
    ; debugger's own bank — mf.asm's mf_nmi_poll, which comes back to
    ; .poll_decline below or leaves through .break_into_debuggee.
    jp mf_nmi_poll

    ; The poll declines: put slot 7 back before returning, or the debuggee gets
    ; its machine back with the debugger's bank at 0xE000.
.poll_decline:
    ld a,(MF.nmi_slot7)
    nextreg REG_MMU+MAIN_SLOT,a
    jr .return_to_interrupted


;===========================================================================
; Read the bank in MAIN_SLOT into MF.nmi_slot7 and page MAIN_BANK in over it.
;
; A SUBROUTINE BECAUSE BOTH SERVED CAUSES NEED IT AND THIS HALF IS THE
; EXPENSIVE ONE: fifteen bytes twice costs a 16-byte ALIGN step here AND
; sixteen bytes of the debugger half, because the image ends at
; 0xE000 + 0x2000 - MF.main_prg_copy and ROM_MAGIC_ADDR comes down with it. A
; call is safe here — SP is MF.stack, which has 20 words and two of them used.
;
; What the byte means, and why it is NOT slot_backup.slot7, is at its
; definition and at .break_into_debuggee (issue #26).
;
; Entry: BC = IO_NEXTREG_DAT.  Exit: BC = IO_NEXTREG_DAT, A = the saved bank.
;===========================================================================
.save_slot7_page_in:
    dec b       ; IO_NEXTREG_REG
    ld a,REG_MMU+MAIN_SLOT
    out (c),a
    ; Read register
    inc b
    in a,(c)	; A contains the previous bank number for MAIN_SLOT
    ld (MF.nmi_slot7),a
    ; Page in slot 7
    nextreg REG_MMU+MAIN_SLOT,MAIN_BANK
    ret


.is_button_cause:

    IF 0
    ; Change border
    ld a,(MF.border_color)
    inc a
    and 0x07
    ld (MF.border_color),a
    out (BORDER),a
    ENDIF

    ; IO_NEXTREG_REG was backed up at the top of nmi66h — see there.

    ; Now backup main slot, and page MAIN_BANK in over it.
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
    call .save_slot7_page_in

    ; Save the clock speed — into MF RAM, and deliberately NOT into backup.*,
    ; for MF.nmi_slot7's reason two instructions along (issue #37). The NextREG
    ; latch beside it is the same story and is now taken at the very top of
    ; nmi66h instead of here, which fixes a second defect and pays for itself —
    ; see there. The same one byte was answering two questions:
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
    ; uncaught: five ROM-moving builds shipped between #37 being filed and this.
    ; .break_into_debuggee does NOT copy these across, unlike nmi_slot7:
    ; mf_nmi_button_pressed does, at .save_registers_continue, and it is that
    ; path's only caller. There rather than here because A must survive to
    ; save_registers, and because these bytes cost the debugger half 12 there
    ; and this half a 16-byte step here — the MF ROM half is exactly full.

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

; Non-zero when THIS break was caused by the M2 poll rather than by the M1
; button, so that mf_nmi_button_pressed can skip its transport_drain — issue
; #22. The drain discards everything until 100 ms of quiet, which is right for a
; button press (nobody sent anything, and junk on the link should go) and WRONG
; for a poll break, whose whole cause is a CMD_PAUSE sitting in the RX FIFO:
; draining would throw the command away and leave DeZog blocked on a response
; that could never come.
;
; A byte and not a register: .break_into_debuggee's `pop af` and save_registers
; between here and there consume every one of them. In MF RAM because it costs
; no ROM bytes, and it is NMI-entry-scoped exactly like the three above.
;
; It is read AND CLEARED by mf_nmi_button_pressed, so a button press that
; follows a poll break drains normally. main_bank_entry clears it too, because
; MF RAM is undefined at power-on and the first button press would otherwise
; read whatever was there.
nmi_poll_break:  defb 0

    ENDMODULE
