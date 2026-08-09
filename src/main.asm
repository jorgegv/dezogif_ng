;===========================================================================
; main.asm
;===========================================================================

    SLDOPT COMMENT WPMEM, LOGPOINT, ASSERTION

    DEVICE ZXSPECTRUMNEXT

;===========================================================================
; Constants
;===========================================================================

    include "constants.asm"

    ORG MAIN_ADDR

;===========================================================================
; Include modules
;===========================================================================

    ; Define this for some rudimentary debug functionality
    ;DEFINE DEBUG

    include "macros.asm"
    include "zx/zx.inc"
    include "zx/zxnext_regs.inc"
    include "breakpoints.asm"
    include "data_const.asm"
    include "mf.asm"
    include "utilities.asm"
    include "transport.asm"
    include "message.asm"
    include "commands.asm"
    include "backup.asm"
    include "text.asm"
    include "ui.asm"
    include "altrom.asm"
    include "debug.asm"


;===========================================================================
; After loading the program starts here. Moves the bank to the destination
; slot and jumps there.
;===========================================================================
    ;DISP $-MAIN_ADDR   ; Is in MF space.

; In MAIN_BANK/MAIN_SLOT.
main_bank_entry:
    di
    ; Setup stack
    ld sp,debug_stack.top

    ; Init state
    MEMCLEAR tmp_breakpoint_1, 2*TMP_BREAKPOINT

    ; Disable Multiface
    MF_PAGE_OUT

    ; Return from RETN (if called by NMI)
    call nmi_return ; Note: if not called by NMI nothing special will happen.

    ; Initialize the bank for slot 0 with the required code.
    call copy_altrom

    ; NO FONT COPY HERE ANY MORE — issue #31. This used to copy 0x300 bytes from
    ; ROM_FONT to the top of this bank, into a buffer nothing in the source
    ; declared, so the assembler could not see it and a debugger that grew past
    ; its start address silently aliased its own variables onto the glyphs. The
    ; print routines now read the ROM directly; text.init points at it and
    ; text.font_map is what makes the window valid. That gives the bank its top
    ; 768 bytes back, which is most of the headroom M2 was told it already had.

    ; Set baudrate
    call transport_init

    ; Init text printing
    call text.init

    ; The main program has been copied into MAIN_BANK
 IF ROM_VARIANT == ROM_VARIANT_UART
    ld a,2  ; Joy 2 selected
    ld (uart_joyport_selection),a
 ENDIF

    ; Enable flashing border
    call transport_flashing_border.enable

    ; Enable slow border change
    ld a,1
    ld (slow_border_change),a

    ; Return from NMI (Interrupts are disabled)
    call nmi_return

    ; No error
    xor a

;===========================================================================
; main entry - Jump here in case of an error.
; A contains the error.
;===========================================================================
drain_main:
    ; Store error
    ld (last_error),a
    ; Drain
    call transport_drain

    ; Flow through


;===========================================================================
; main routine - The main loop of the program.
;===========================================================================
main:
    di
    ; Setup stack
    ld sp,debug_stack.top

    ; RE-INITIALISE THE DEBUGGEE'S SAVED STATE. Everything below this comment
    ; and above main_redraw belongs to the program being debugged, not to the
    ; debugger's screen — which is why main_redraw exists and why the two are
    ; separate entry points (issue #16). Coming here means "there is no session
    ; to preserve": a fresh start, a CMD_CLOSE, or an error the transport could
    ; not recover from.
    ;
    ; Init clock speed
    ld a,RTM_3MHZ
    ld (backup.speed),a

    ; Init state
    ld a,PRGM_IDLE
    ld (prgm_state),a

    ; Init interrupt state and layer 2 backup
    xor a
    ld (backup.interrupt_state),a
    ld (backup.layer_2_port),a

    ; Init slot 0 bank
    ld a,ROM_BANK
    ld (slot_backup.slot0),a

    ; Flow through


;===========================================================================
; main_redraw - everything `main` does EXCEPT re-initialising the debuggee's
; saved state above.
;
; IT EXISTS BECAUSE main_loop IS NOW REACHABLE WITH A DEBUGGEE LOADED. Before
; issue #16 the only way into main_loop was through `main`, so the keys polled
; there could only ever be pressed while prgm_state was PRGM_IDLE and the reset
; above was a no-op. transport_wait_rx's bound changes that: the debugger drops
; back into main_loop while a client is attached and possibly stopped at a
; breakpoint, and `check_key_border`'s `jp main` would then have discarded the
; debuggee's speed, interrupt state and slot 0 — silently, on a key whose only
; advertised job is toggling the border. The joy-port keys in the UART build had
; the same shape.
;
; So the display/configuration keys come here instead. Behaviour is unchanged on
; every path that existed before: they were only ever reachable after `main` had
; already done that reset, so not repeating it changes nothing.
;===========================================================================
main_redraw:
    di
    ; Setup stack
    ld sp,debug_stack.top

    ; CMD_CLOSE writes its response and then jumps straight to main, so this is
    ; the other end of a completed message. Reached from drain_main there is
    ; nothing to send: the drain discards a half-built one rather than letting
    ; a fragment go out as the head of the next reply.
    TRANSPORT_END_MESSAGE

    ; Black border
    xor a
    out (BORDER),a

    ; Layer 2 out of the way, so the UI is visible. The BACKUP of that port is
    ; the debuggee's and is not touched here.
    ld bc,LAYER_2_PORT
    xor a
    out (c),a

    ; Bring the transport up for the debugger
    call transport_activate

    ; Show the text
    call show_ui

;===========================================================================
; main_idle - the idle loop, with its border-colour timer initialised.
;
; A separate entry point because transport_wait_rx jumps here when its bound
; expires (issue #16), and BC/DE are the timer: arriving with whatever that
; loop happened to leave in them would count the border cadence down from
; undefined state.
;===========================================================================
main_idle:
    ; Border color timer
    ld c,1
    ld de,0
main_loop:
    push bc, de

    ; Check if byte available.
    call transport_byte_available
    ; If so leave loop and enter command loop
    jp nz,cmd_loop
.continue:
    ; CMD_LOOPBACK writes its whole response and then jumps HERE
    ; (commands.asm: `pop af` / `jp main_loop.continue`), bypassing cmd_loop
    ; entirely — so this is the third and last place a completed message can
    ; end up. Measured, not assumed: without it the loopback reply sat in the
    ; buffer until the NEXT command arrived and was then delivered to whichever
    ; connection asked that one, which the DZRP suite saw as a timeout followed
    ; by a sequence mismatch.
    TRANSPORT_END_MESSAGE

.no_uart_byte:
    ; Check keyboard
    call check_key_reset
    call check_key_border
    ; main_redraw, not main: a debuggee may be loaded and stopped by the time
    ; this key is polled — see main_redraw.
    jp z,main_redraw   ; Jump if "B" pressed
 IF ROM_VARIANT == ROM_VARIANT_UART
    ; The joy-port selector. UART mode only — WiFi mode never takes a joy port,
    ; so there is nothing for 1/2/3 to select. See ui.asm's read_key_joyport.
    call read_key_joyport
    inc e
    jr z,.no_keyboard

    ; Key pressed
    dec e
    ld a,e
    ld (uart_joyport_selection),a
    jp main_redraw
 ENDIF

.no_keyboard:
    pop de, bc
    ; Check border color timer
    dec de
    ld a,d
    or e
    jr nz,main_loop
    dec c
    jr nz,main_loop

    ; Change color of the border
    call change_border_color
    ld c,4
    jr main_loop



;===========================================================================
; DATA: All (writable) data needs to be located in
; area 0x2000-0x3FFF.
;===========================================================================

    ; Note: Page and slot doesn't matter as this is bss area and will be located in divmmc.
    ; However for testing (without divmmc) it is better that a bank is mapped
    ;MMU USED_DATA_SLOT e, USED_DATA_BANK
    ;ORG 0x2000

    ; Note: The area does not need to be copied. i.e. is initialized on the fly.
    include "data.asm"


main_end:
    ASSERT main_end <= (MAIN_SLOT+1)*0x2000
    ASSERT main_end <= MAIN_ADDR+0x1F00

    ; The identity block must not be overwritten by a debugger that has grown
    ; into it. This is tighter than the assert above — which permits 0xFF00,
    ; past even the end of the region SAVEBIN writes (0xFEC0), so code growing
    ; beyond that would have been silently truncated rather than rejected.
    ASSERT main_end <= ROM_MAGIC_ADDR

    ; AND THAT IS AGAIN THE TRUE BOUND, WHICH IT HAD NOT BEEN SINCE THE FORK.
    ; Between the fork and issue #31 the real ceiling was 736 bytes lower, at
    ; 0xFBC0, because main_bank_entry copied the ZX font into the top of this
    ; bank and nothing in the source emitted a byte there for the assembler to
    ; notice. Growth past it aliased the debugger's own variables onto the space
    ; and '!' glyphs, in both directions, and no check anywhere could see it.
    ; The copy is gone; the font is read from the ROM. Do not reintroduce a
    ; buffer here without an ASSERT that names its start address.


;===========================================================================
; ROM identity block. See constants.asm for what it is for and why it lives
; at the end of the image. Placed with an explicit ORG so that its FILE OFFSET
; — which is the contract, mfselect reading the file — stays at 0x1FE0. The
; address itself is derived and may move by 16 if mf_nmi.bin grows past its
; ALIGN boundary; the ASSERT below is what keeps the two in step.
;===========================================================================
    ORG ROM_MAGIC_ADDR
rom_magic:
    defb "DeZoGiFnG_"                  ; identity: match on THIS, and only this
 IF ROM_VARIANT == ROM_VARIANT_WIFI
    defb "WIFI"
 ELSE
    defb "UART"
 ENDIF
    defb "_"
    defb BUILD_NUMBER_HEX              ; 4 uppercase hex digits, from version.yaml
    defb 0                             ; NUL, so a C reader can treat it as a string
rom_magic_end:

    ; 20 bytes used of 32 reserved. The slack is deliberate: a longer variant
    ; name or a wider build number must not force the block to move, because
    ; its address is the contract.
    ASSERT rom_magic_end - rom_magic <= ROM_MAGIC_SIZE

    ; The block's reserved space ends exactly at the end of the image SAVEBIN
    ; writes — the last byte of the 8192-byte ROM. If this fires, the image
    ; layout changed and mfselect's fixed offset is now wrong.
    ASSERT ROM_MAGIC_ADDR + ROM_MAGIC_SIZE == 0xE000 + MF_ORIGIN_ROM+0x2000-MF.main_prg_copy


;===========================================================================
; Save bin file.
;===========================================================================

    SAVEBIN MAIN_BIN, 0xE000, MF_ORIGIN_ROM+0x2000-MF.main_prg_copy

    ;SAVENEX CLOSE


;===========================================================================
; ROM for Multiface.
;===========================================================================

    include "mf_rom.asm"
