;========================================================
; ut_uart.asm
;
; Unit tests for the UART.
; Not much to test here as this requires HW.
;========================================================


    MODULE ut_uart


; To save the sp value
sp_backup:  defw    0

; uart routines jump here in case of errors.
@drain_main:
    ret


; Test that subroutine returns correctly.
UT_transport_read_byte_timeout:
    ld (sp_backup),sp
    ; Redirect timeout jump
    ld hl,transport_read_byte.timeout
    ldi (hl),0xC3	; JP
    ldi (hl),.timeout&0xFF
    ld (hl),.timeout>>8

    ; Test
    call transport_read_byte
    ; Should never return
    TEST_FAIL		; So FAIL if it returns

.timeout:
    ; Instead the timeout should be reached
    ld sp,(sp_backup)	; Restore SP
 TC_END


; Tests setting of the joystick IO mode.
;
; BIT 0 IS THE ONE TO WATCH IN EVERY ASSERTION BELOW. It routes the joystick pin
; to UART1 rather than UART0, which is what keeps the ESP-01's TX and RTR lines
; out of io mode's way (zxnext.vhd:3343, :3349) and so is what lets
; TRANSPORT_DEACTIVATE leave io mode on for asynchronous break. A build that
; regressed it to 0 would still pass every bench in this project — the link
; works either way — and would silently sever the ESP for the whole session.
; See doc/ASYNCHRONOUS-BREAK-DESIGN.md §8.3.
UT_transport_activate:
    ; Joy port 1
    MEMSETBYTE uart_joyport_selection, 1
    call transport_activate
    ; Read value
    xor a :	in a,(4)
    nop ; TEST ASSERTION a == 10100001b

    ; Joy port 2
    MEMSETBYTE uart_joyport_selection, 2
    call transport_activate
    ; Read value
    xor a :	in a,(4)
    nop ; TEST ASSERTION a == 10110001b

    ; No joy port
    MEMSETBYTE uart_joyport_selection, 0
    call transport_activate
    ; Read value
    xor a :	in a,(4)
    nop ; TEST ASSERTION a == 0

    ; Pathologic case
    MEMSETBYTE uart_joyport_selection, 3
    call transport_activate
    ; Read value
    xor a :	in a,(4)
    nop ; TEST ASSERTION a == 0

 TC_END


; Tests that the resume path keeps io mode for joy port 2 and gives it back for
; anything else — i.e. that asynchronous break is armed on exactly one
; selection. This is the whole of the UART half of M2: the poll and the Copper
; machinery were always there, and this macro is what used to sever the RX
; source before the poll could see a byte.
;
; It drives TRANSPORT_DEACTIVATE through a local copy rather than through
; restore_registers, which cannot be called from a test — it does not return.
UT_transport_deactivate:
    ; Joy port 2: io mode must SURVIVE, so the PC can still break in.
    MEMSETBYTE uart_joyport_selection, 2
    call transport_activate
    call .deactivate
    ; Read value
    xor a :	in a,(4)
    nop ; TEST ASSERTION a == 10110001b

    ; Joy port 1: io mode must be handed back, leaving the connector usable.
    MEMSETBYTE uart_joyport_selection, 1
    call transport_activate
    call .deactivate
    ; Read value
    xor a :	in a,(4)
    nop ; TEST ASSERTION a == 0

    ; No joy port: nothing was taken, nothing is kept.
    MEMSETBYTE uart_joyport_selection, 0
    call transport_activate
    call .deactivate
    ; Read value
    xor a :	in a,(4)
    nop ; TEST ASSERTION a == 0

 TC_END

.deactivate:
    TRANSPORT_DEACTIVATE
    ret


    ENDMODULE
