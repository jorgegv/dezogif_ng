;===========================================================================
; ui.asm
;
; The simple UI.
; Text output and keyboard input.
;===========================================================================



;===========================================================================
; Const data
;===========================================================================

; Error definitions
ERROR_RX_TIMEOUT:			equ 1
ERROR_RX_OVERFLOW:          equ 2
ERROR_TX_TIMEOUT:			equ 3
ERROR_WRONG_FUNC_NUMBER:	equ 4
ERROR_WRITE_MAIN_BANK:	    equ 5
ERROR_CORE_VERSION_NOT_SUPPORTED:  equ 6
ERROR_CMD_NOT_SUPPORTED:    equ 7

; A frame declared more payload than the 8 KB swap window can hold, so honouring
; it would have written over whatever sits above that window — for SWAP_SLOT,
; the bank the debugger is running from. Raised by cmd_loopback and
; cmd_write_bank; see error_payload_too_big in commands.asm for why the client
; gets no answer at all.
ERROR_PAYLOAD_TOO_BIG:      equ 8

 IF ROM_VARIANT == ROM_VARIANT_WIFI
; WiFi mode only: the module answered, the listener is up, and it has no
; address to hand out. Raised by transport_init; see transport_esp.asm.
ERROR_NO_WIFI_ADDRESS:      equ 9

; WiFi mode only, and NOT a fault of its own: the stub met ESP_FAULT_LIMIT
; transport faults in a row and ran the AT chain again by itself (issue #16,
; part C). It replaces the fifth fault's own code, because "I have just
; re-established the module, and any connection you had is gone" is the thing a
; user needs to know — the fifth timeout is a symptom of it. A recovery that
; then failed reports ITS failure instead, through transport_activate.
ERROR_ESP_REINIT:           equ 10
 ENDIF


;===========================================================================
; Checks key "R".
; If pressed a reset is done.
;===========================================================================
check_key_reset:
    ; Read port
    ld bc,PORT_KEYB_TREWQ
    in a,(c)
    bit 3,a ; "R"
    ret nz
    ; Wait on key release
.wait_on_release:
    call wait_on_key_release
    ; Reset
    nextreg REG_RESET, 01b


;===========================================================================
; Checks key "B".
; For turning slow border change on/off.
; Returns:
;   Z = B pressed
;   NZ = B not pressed
;===========================================================================
check_key_border:
    ; Read port
    ld bc,PORT_KEYB_BNMSHIFTSPACE
    in a,(c)
    bit 4,a ; "B"
    ret nz
    ; Wait on key release
    call wait_on_key_release
    ; Toggle
    ld a,(slow_border_change)
    xor 1
    ld (slow_border_change),a
    jr nz,.ret
    ; Turn border black
    xor a
    out (BORDER),a
.ret:
    xor a   ; Z
    ret


 IF ROM_VARIANT == ROM_VARIANT_UART
;===========================================================================
; Reads the joyport from the keyboard.
;
; UART MODE ONLY. WiFi mode never touches the joy ports (transport_esp.asm,
; point 4), so there is nothing for 1/2/3 to select and no line on the screen
; for them to change.
; Returns:
;  E: 0x00=00b => "3": no joystick port used
;     0x01=01b => "1": joyport 1
;     0x02=10b => "2": joyport 2
;     0xFF => no key pressed
;===========================================================================
read_key_joyport:
    ; Read port
    ld bc,PORT_KEYB_54321
    in a,(c)
    ld e,0xFF   ; Default
    bit 0,a ; "1"
    jr nz,.no_key_1
    ld e,0x01
    jr .cont
.no_key_1:
    bit 1,a ; "2"
    jr nz,.no_key_2
    ld e,0x02
    jr .cont
.no_key_2:
    bit 2,a ; "3"
    ret nz
    ld e,0x00

.cont:
    ; Flow through wait_on_key_release
 ENDIF


;===========================================================================
; Waits on key release.
; Parameters:
;   BC = the port to usefor the keys.
; Changes:
;   AF
;===========================================================================
wait_on_key_release:
    in a,(c)
    and 0x1F
    cp 0x1F
    jr nz,wait_on_key_release
    ret


;===========================================================================
; Switches to ULA mode and shows the intro text.
; Displaying which keys can be used to change the joy port.
;===========================================================================
; A SHELL, AND THE SHELL IS THE POINT. Since issue #31 the glyphs are read live
; from the ROM rather than from a copy in this bank, so painting needs the window
; text.font_map opens — and needs it given back, because MMU slot 1 has no backup
; anywhere and is what cmd_get_registers reports and what the debuggee resumes
; with.
;
; IT IS A SHELL RATHER THAN A PROLOGUE AND EPILOGUE INSIDE THE BODY because the
; body has TWO exits: an early `ret z` when there is no error to report, and a
; tail `jp` into print_string. A restore written at "the end" of the routine runs
; on one of them, and ERRORS.md carries that failure twice already
; ("Enumerating a control flow's exits by reading the ones you expected").
; Wrapping a `call` cannot miss an exit that has not been thought of.
show_ui:
    call text.font_map
    call show_ui_body
    jp text.font_unmap


show_ui_body:
    ; Switch to ULA
    nextreg REG_ULA_X_OFFSET, 0
    nextreg REG_ULA_Y_OFFSET, 0
    nextreg REG_ULA_CONTROL, 0
    nextreg REG_DISPLAY_CONTROL, 0
    nextreg REG_SPRITE_LAYER_SYSTEM, 00010000b   ; USL
    ; Turn off clipping (might have been used by screensaver)
    nextreg REG_CLIP_WINDOW_CONTROL, RCWC_RESET_ULA_CLIP_INDEX
    nextreg REG_CLIP_WINDOW_ULA, 0
    nextreg REG_CLIP_WINDOW_ULA, 255
    nextreg REG_CLIP_WINDOW_ULA, 0
    nextreg REG_CLIP_WINDOW_ULA, 191

    ; Clear the screen
    MEMCLEAR SCREEN, SCREEN_SIZE
    ; Black on white
    MEMFILL COLOR_SCREEN, WHITE+(BLACK<<3), COLOR_SCREEN_SIZE+15*COLOR_SCREEN_WIDTH
    ; Red on black for a probable error report
    MEMFILL COLOR_SCREEN+15*COLOR_SCREEN_WIDTH, RED+BRIGHT, 9*COLOR_SCREEN_WIDTH

    ; Print text
    ld de,INTRO_TEXT
    call text.ula.print_string

    ; Show core version
    ld a,REG_VERSION
    call read_tbblue_reg
    ld h,a  ; Save major and minor number
    ; Shift major number
    rra : rra : rra : rra
    and 0x0F
    ld de,text_core_version.major
    call itoa_2digits
    ; Minor version
    ld a,h
    and 0x0F
    ld de,text_core_version.minor
    call itoa_2digits
    ; Subminor
    ld a,REG_SUB_VERSION
    call read_tbblue_reg
    ld l,a    ; save subminor
    ld de,text_core_version.subminor
    call itoa_2digits

    ; Check version against core version 3.01.10 (minimum version)
    ; (hl = current version)
    ld de,(3 << 12) + (1 << 8) + (10)
    sbc hl,de   ; current version - 3.01.10
    jp p,.core_version_continue

    ; Core version not supported
    ld a,(last_error)
    or a
    jr nz,.core_version_continue	; There is already an error

    ; Report "core version not supported" error
    ld a,ERROR_CORE_VERSION_NOT_SUPPORTED
    ld (last_error),a

.core_version_continue:
    ; Print
    ld de,text_core_version
    call text.ula.print_string

    ; Get display timing
    ld a,REG_VIDEO_TIMING
    call read_tbblue_reg
    and 0111b			;video timing is in bottom 3 bits, e.g. HDMI=111b
    ; Print the number
    add '0' ; convert to ASCII
    ld (text_one_char.char),a
    ld de,text_one_char
    call text.ula.print_string

    ; The transport's own status block, at rows 6 and 7. This is the UI half of
    ; the assembly-time switch (MEMORY.md 2026-08-05): it is the one part of
    ; this screen whose content is a property of the transport, so the two
    ; modes fill it with different things rather than sharing a line that would
    ; be false in one of them.
 IF ROM_VARIANT == ROM_VARIANT_WIFI
    ; The connect address, or why there is not one.
    call esp_show_status
 ELSE
    ; Show right selected joy port option
    ld hl,SELECTED_TEXT_TABLE
    ld a,(uart_joyport_selection)
    add a   ; *2
    add hl,a
    ld de,(hl)
    call text.ula.print_string
 ENDIF

    ; Show border option
    ld de,BORDER_ON_TEXT
    ld a,(slow_border_change)
    or a
    jr z,.print_border
    ld de,BORDER_OFF_TEXT
.print_border:
    call text.ula.print_string

    ; Print 3 lines debugging
 IFDEF DEBUG
    ; Caclulate screen address
    ld de,256*8*debug.TEXT_START_POSITION_LINE + 8*debug.TEXT_START_POSITION_CLMN
    call text.ula.calc_address
    ld de,debug.text
    call text.ula.print_string
 ENDIF

    ; Show possibly error
    ld a,(last_error)
    or a
    ret z	; 0 = no error

    ; Print "Last error:"
    ld de,TEXT_LAST_ERROR
    call text.ula.print_string
    push hl	; Save pointer to screen

    ; Print error message
    ld a,(last_error)
    dec a
    add a	; 2*A
    ld hl,ERROR_TEXT_TABLE
    add hl,a
    ld de,(hl)
    pop hl	; Restore pointer to screen
    jp text.ula.print_string
