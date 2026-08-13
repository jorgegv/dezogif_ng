;========================================================
; ut_uart.asm
;
; Unit tests for the UART.
; Not much to test here as this requires HW.
;========================================================


    MODULE ut_uart


; To save the sp value
sp_backup:  defw    0

; Test data is written to this port, and read back through PORT_UART_RX.
PORT_TEST_DATA:	equ 0x8000

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


; Tests that entering the debugger RECLAIMS the UART channel select (issue #42).
;
; 0x153B bit 6 says which of the machine's two UARTs ports 0x133B, 0x143B and
; 0x163B refer to AT THE INSTANT OF THE ACCESS. transport_init points it at our
; channel exactly once, when MAIN is first entered, and until this fix nothing
; ever re-established it — so a debuggee legitimately using the other UART could
; move the pointer, and a debugger entered afterwards would read and write the
; WRONG CHANNEL for the rest of the session. Not merely unbreakable: mute.
;
; THE ASSERTION IS `a == 1` RATHER THAN A LITERAL CHANNEL VALUE, DELIBERATELY.
; UART_SELECT_OURS is 01000000b in this build and 0 in the WiFi one, so
; comparing against the variant's own constant is what makes one test source
; correct for both — and it is exactly what a transposition of the two
; constants would fail, which a literal 0x40 here would not.
UT_transport_select_reclaimed:
    ; A debuggee has pointed the select at the other channel.
    ld bc,UART_SELECT
    ld a,UART_SELECT_OTHER
    out (c),a

    ; Entering the debugger must take it back.
    MEMSETBYTE uart_joyport_selection, 2
    call transport_activate

    ld a,HIGH UART_SELECT
    in a,(LOW UART_SELECT)
    and UART_SELECT_CHANNEL
    cp UART_SELECT_OURS
    ld a,0
    jr nz,.not_ours	; ld a,0 does not touch the flags, so this is still the cp
    inc a
.not_ours:
    nop ; TEST ASSERTION a == 1

 TC_END


; Tests that the asynchronous-break poll BORROWS the select rather than keeping
; it, and that its verdict survives the restore (issue #42).
;
; The poll runs while the DEBUGGEE is executing, so it may not leave the pointer
; moved. The subtle half is the flag: the borrow path puts the pointer back
; AFTER the `bit` that sets the verdict, with no push/pop of AF, on the grounds
; that neither `ld a,n` nor `out (c),a` touches the flags. Both cases below
; assert the verdict AND the restore, so a build that saved the flags wrongly
; fails the first assertion and one that kept the pointer fails the second.
;
; WHAT THIS DOES NOT ESTABLISH: that the borrow reads the RIGHT channel.
; uart.js models one channel, so the status is the same whichever way the
; pointer points; what is shown is that borrowing does not break the read. Only
; hardware can show the other half. Nor can it distinguish "did not write the
; register" from "wrote back the same value" on the common path — the model
; sees only the final value.
UT_transport_poll_borrows_select:
    ; The debuggee owns the pointer and has it on the other channel.
    ld bc,UART_SELECT
    ld a,UART_SELECT_OTHER
    out (c),a

    ; Nothing on the link: the poll must answer "quiet"...
    call transport_poll_traffic
    ld a,0
    jr nz,.quiet_verdict
    inc a
.quiet_verdict:
    nop ; TEST ASSERTION a == 1

    ; ...and must have handed the pointer back exactly as it found it.
    ld a,HIGH UART_SELECT
    in a,(LOW UART_SELECT)
    and UART_SELECT_CHANNEL
    cp UART_SELECT_OTHER
    ld a,0
    jr nz,.quiet_select
    inc a
.quiet_select:
    nop ; TEST ASSERTION a == 1

    ; Now with a byte waiting, which is the case that would be lost if the
    ; restore disturbed the flags.
    ld bc,PORT_TEST_DATA
    ld a,0xA5
    out (c),a

    ld bc,UART_SELECT
    ld a,UART_SELECT_OTHER
    out (c),a

    call transport_poll_traffic
    ld a,0
    jr z,.busy_verdict
    inc a
.busy_verdict:
    nop ; TEST ASSERTION a == 1

    ld a,HIGH UART_SELECT
    in a,(LOW UART_SELECT)
    and UART_SELECT_CHANNEL
    cp UART_SELECT_OTHER
    ld a,0
    jr nz,.busy_select
    inc a
.busy_select:
    nop ; TEST ASSERTION a == 1

    ; Drain the byte. unitTestData lives in the JS simulation and not in guest
    ; memory, so the runner's memory restore cannot clear it and a byte left
    ; queued here would be read by whatever test runs next.
    ld a,HIGH UART_RX
    in a,(LOW UART_RX)

 TC_END


    ENDMODULE
