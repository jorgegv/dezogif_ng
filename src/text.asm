;========================================================
; text.asm
;========================================================


; Code to use in strings for positioning: AT x, y (in pixels)
AT:             equ 0x16


; Routines that draw text on the ULA or layer2 screen.
; Can be used as substitute for the original ZX Spectrum
; text drawing routines.
    MODULE text


; Points the printing routines at the ZX font IN THE ROM, at ROM_FONT (0x3D00),
; and no longer at a copy in this bank.
;
; UNTIL ISSUE #31 main_bank_entry copied 0x300 bytes here, to the top of
; MAIN_BANK, and this pointed there. That buffer was an UNDECLARED reservation —
; nothing in the source emitted a byte into it — so the assembler could not see
; it, the three asserts on main_end were all far looser than its start address,
; and a debugger that grew past it silently aliased its own variables onto the
; glyph bitmaps. At BAUD_HIGH=460800 that is exactly what happened: every space
; printed on the stub's own screen carried two bytes of text_core_version.
;
; Reading the ROM directly costs no bank space at all and removes the trap
; rather than guarding it. WHAT IT COSTS INSTEAD is that printing now depends on
; machine state, which a copy made it immune to — see text.font_map, which every
; caller of the print routines must hold open.
; IN:
;   -
; OUT:
;   -
; Changed registers:
;   HL, DE, BC
init:
    ; Store the used font address. The font starts normally at char index 0, so
    ; it's lower than the original address.
    ld hl,ROM_FONT-0x20*8
    ; Flow through


; Sets the font address.
; IN:
;   HL = address of font to use. Contains 256 character, but the first 8 bytes are not used (0).
; OUT:
;   -
; Changed registers:
;   -
set_font:
    ; Store the used font address.
    ld (font_address),hl
    ret


;===========================================================================
; Makes 0x2000-0x3FFF read the ZX font, and remembers what was there.
;
; SINCE ISSUE #31 the glyphs are read live out of the ROM instead of a copy in
; MAIN_BANK, so printing depends on two pieces of machine state that a debuggee
; — or a client's CMD_SET_SLOT — is free to have left elsewhere:
;
;   MMU slot 1 (NR 0x51) must map ROM (ROM_BANK), or 0x2000-0x3FFF is some bank.
;   NR 0x8C bit 5 locks the Alt ROM to its 48K half. Without it the half served
;   follows port 0x7FFD bit 4 (zxnext.vhd:2981-3006) — and copy_modify_altrom
;   only ever writes the 48K half, so a debuggee that had selected the 128K ROM
;   would have us read a half nobody initialised. That is the same mechanism as
;   upstream's "your program cannot use any of the other ROMs" constraint: the
;   patched image carrying the RST 0 hooks is in that one half too.
;
; BOTH ARE SAVED, because neither has a backup anywhere else. slot_backup holds
; slots 0 and 7 only, and cmd_get_registers reports slots 0-6 by reading the MMU
; live — so a slot left wrong is BOTH reported wrong to DeZog AND handed to the
; debuggee on its next CMD_CONTINUE. That is issue #26, one slot along.
;
; THE ORDER IS NOT ARBITRARY AND NR 0x8E IS NOT USED. Writing NR 0x8E — or ports
; 0x7FFD / 0x1FFD / 0xDFFD / 0xEFF7 — re-derives MMU0 and MMU1 from scratch
; (zxnext.vhd:3811-3814, :4619-4645), which would silently undo the slot set
; here. copy_altrom gets away with NR 0x8E only because it writes it BEFORE its
; MMU writes. NR 0x8C is in no such list, and reads back exactly
; (zxnext.vhd:6155-6156) — unlike NR 0x04, which is write-only.
;
; What this does NOT have to handle: Layer 2, which save_layer2_rw has already
; turned off for the whole debug session; and DivMMC, which outranks the Alt ROM
; in the same arbiter but which the RST 0 breakpoint path already depends on
; being absent, so this adds no exposure that was not there.
; IN:
;   -
; OUT:
;   -
; Changed registers:
;   AF, BC — BC because read_tbblue_reg uses it (utilities.asm). Harmless at
;   both call sites today, and stated because M2 is told to hold this window
;   open from a poll handler, which is a caller that does not exist yet.
;===========================================================================
font_map:
    ld a,REG_ALTROM
    call read_tbblue_reg
    ld (font_map_backup),a
    or 00100000b            ; bit 5 = lock ROM1, the 48K half
    nextreg REG_ALTROM,a
    ld a,REG_MMU+1
    call read_tbblue_reg
    ld (font_map_backup+1),a
    nextreg REG_MMU+1,ROM_BANK
    ret


;===========================================================================
; Puts back exactly what font_map found. Reverse order, which costs nothing and
; keeps the discipline visible.
; Changed registers:
;   AF
;===========================================================================
font_unmap:
    ld a,(font_map_backup+1)
    nextreg REG_MMU+1,a
    ld a,(font_map_backup)
    nextreg REG_ALTROM,a
    ret


; -----------------------------------------------------------------------
; ULA routines.

; Calculates the address in the screen from x and y position.
; Use this before you call any 'print' subroutine.
; In general this uses the PIXELDN instructions to calculate
; the screen address. But additionally it sets the B register
; with X mod 8, so that it can be used by the print sub routines.
; IN:
;   E = x-position, [0..255]
;   D = y-position, [0..191]
; OUT:
;   HL = points to the corresponding address in the ULA screen.
;   B = x mod 8
; Changed registers:
;   HL, B
ula.calc_address:
    ; Get x mod 8
    ld a,e
    and 00000111b
    ld b,a
    ; Calculate screen address
    PIXELAD
    ret

; Prints a single character at ULA screen address in HL.
; IN:
;   HL = screen address to write to.
;   B = x mod 8, i.e. the number to shift the character
;   A = character to write.
; OUT:
;   -
; Changed registers:
;   DE, BC, IX
ula.print_char:
    push hl
    push hl
    ; Calculate offset of character in font
    ld e,a
    ld d,8  ; 8 byte per character
    mul d,e
    ; Add to font start address
    ld hl,(font_address)
    add hl,de
    ld ix,hl    ; ix points to character in font
    ; Now copy the character to the screen
    pop hl

    ld c,8  ; 8 byte per character
.loop:
    ldi d,(ix)  ; Load from font
    ld e,0
    bsrl de,b   ; shift
    ; XOR screen with character (1)
    ld a,(hl)
    xor d
    ld (hl),a
    ; Next address on screen
    inc l
    ; XOR screen with character (2)
    ld a,(hl)
    xor e
    ld (hl),a
    ; Correct x-position
    dec l
    ; Next line
    PIXELDN
    ; Next
    dec c
    jr nz,.loop

    ; Restore screen address
    pop hl
    ret


; Prints a complete string (until 0) at ULA screen address in HL.
; IN:
;   HL = screen address to write to. If (DE) start with an AT then HL can be omitted.
;   DE = pointer to 0-terminated string
;   B = x mod 8, i.e. the number to shift the character
; OUT:
;   HL (or better L only) increased by 1, pointing to the next screen address.
; Changed registers:
;   AF, HL, DE, C
ula.print_string:
.loop:
    ld a,(de)
    or a
    ret z   ; Return on 0

    ; Check for AT
    cp AT
    jr z,.at

    ; print one character
    push de
    call ula.print_char
    pop de

    ; Next
    inc de
    inc l   ; Increase x-position
    jr .loop
    ret

.at:
    ; AT x, y (pixels)
    inc de
    ldi a,(de)  ; x
    ld l,a
    ldi a,(de)   ; y
    push de
    ld e,l
    ld d,a
    call ula.calc_address
    pop de
    jr .loop

    ENDMODULE
