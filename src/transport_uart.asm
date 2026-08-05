;===========================================================================
; transport_uart.asm
;
; The joy-port serial transport: upstream dezogif's, unchanged.
; Implements the interface described in transport.asm.
;
; Routines for the lowel handling of the UART.
; I.e.
; - Check the port for received byte.
; - Get received byte.
; - Send one byte.
;
; Speed:
; The routine runs at 28MHz. I.e. 7MHz for 4 T-States.
; Or about 7 million simple instructions per second.
; Baudrate:
; The baudrate maximum is 1958400.
; Good results were achieved with 921600.
; Which is approx. 100 kBytes per second.
; That means download of a 64k Z80 program would take up to 0.5 seconds.
;
;===========================================================================


;===========================================================================
; TRANSPORT_DEACTIVATE — the debugger is about to resume the debuggee.
;
; The joy ports were taken over for the serial link while the debugger had the
; machine; this hands them back. Clearing NR 0x0B is also what re-points
; UART0's RX away from the joystick pin and onto the ESP-01 pin
; (zxnext.vhd:3340, :3536) — which is why a byte from the PC cannot arrive
; while the debuggee runs in this mode. See plan §4.
;
; A macro rather than a subroutine: the single caller is inline in
; backup.asm's restore path, where a CALL would cost bytes and a stack slot it
; does not have. A transport with nothing to hand back expands this to nothing.
; Changes:
;   -   (NEXTREG reg,imm is ED 91 nn nn; it touches no Z80 register)
;===========================================================================
    MACRO TRANSPORT_DEACTIVATE
    ; Disable joy port IO mode to enable the joysticks
    nextreg REG_JOYSTICK_IO_MODE,0
    ENDM


;===========================================================================
; TRANSPORT_MESSAGE_START — emitted before every response and notification.
;
; The 0xA5 preamble. NOT a defect and not a leak: upstream extended DZRP by
; this byte for the SERIAL link, and says so (doc/legacy/Design.md:30-31) —
; "DeZog will wait on this byte before it recognizes messages coming from the
; Next", because a game that grabs the joy port leaves the Next transmitting
; endless zeroes. DeZog implements the split itself: ZxNextSerialRemote scans
; for and strips byte 165, CSpectRemote does not.
;
; So it is REQUIRED here and must be ABSENT over a socket, which makes it a
; property the transport contributes rather than something message.asm should
; decide. Removing it in both modes would break interoperability with DeZog's
; real `zxnext` remote.
;===========================================================================
    MACRO TRANSPORT_MESSAGE_START
    ld a,MESSAGE_START_BYTE
    call transport_write_byte
    ENDM


;===========================================================================
; TRANSPORT_END_MESSAGE — a complete message has been written.
;
; Nothing to do: bytes went out as they were written. A transport that has to
; announce a frame's length before its bytes needs this, and expands it into
; the flush that sends the frame.
;===========================================================================
    MACRO TRANSPORT_END_MESSAGE
    ENDM


;===========================================================================
; TRANSPORT_CLIENT_ATTACHED / TRANSPORT_CLIENT_DETACHED — CMD_INIT, CMD_CLOSE.
;
; Nothing here, and that is a statement rather than a gap. Over a cable there
; is no connection to report: the joy-port link exists whenever the debugger
; holds the port, whether or not anything is on the other end of it, so a line
; saying "client connected" would be an assertion this transport cannot make.
; The two commands would still tell it a session had been opened and closed —
; but a screen that says so here and cannot say when the peer went would be
; less honest than one that says nothing, and issue #14's acceptance criterion
; is precisely that the line must not lie in the states the transport cannot
; see. So UART mode keeps upstream's screen, unchanged and unclaiming.
;===========================================================================
    MACRO TRANSPORT_CLIENT_ATTACHED
    ENDM

    MACRO TRANSPORT_CLIENT_DETACHED
    ENDM


;===========================================================================
; Constants
;===========================================================================


; UART baudrate
;BAUDRATE:   equ 1958400


; UART TX. Write=transmit data, Read=status
UART_TX:   equ 0x133b

; UART RX. Read data.
UART_RX:   equ 0x143b


; UART selection.
UART_SELECT:   equ 0x153b

/*
0x163B UART Frame
(R/W) (hard reset = 0x18)
bit 7 = 1 to immediately reset the Tx and Rx modules to idle and empty fifos
bit 6 = 1 to assert break on Tx (Tx = 0) when Tx reaches idle
bit 5 = 1 to enable hardware flow control *
bits 4:3 = number of bits in a frame
  11 = 8 bits
  10 = 7 bits
  01 = 6 bits
  00 = 5 bits
bit 2 = 1 to enable parity check
bit 1 = 0 for even parity, 1 for odd parity
bit 0 = 0 for one stop bit, 1 for two stop bits
* The esp ignores hardware flow control
* In joystick i/o mode only cts is available
*/
UART_FRAME:     equ 0x163b



; UART Status Bits:
UART_RX_FIFO_EMPTY: equ 0   ; 0=empty, 1=not empty
UART_RX_FIFO_OVERFLOW:  equ 2   ; 1=overflowed  ; (clears on read)
;UART_RX_FIFO_NEAR_FULL:  equ 3   ; 1=buffer is near full (3/4)
UART_TX_FULL:       equ 1   ; 1=Tx buffer is full
UART_TX_EMPTY:      equ 4   ; 1=Tx buffer is empty



;===========================================================================
; Const data.
;===========================================================================

; Baudrate timing calculation table.
; BAUDRATE must be 230400 at least otherwise a 1 byte table is not sufficient.
baudrate_table:
    defb 28000000/BAUDRATE
    defb 28571429/BAUDRATE
    defb 29464286/BAUDRATE
    defb 30000000/BAUDRATE
    defb 31000000/BAUDRATE
    defb 32000000/BAUDRATE
    defb 33000000/BAUDRATE
    defb 27000000/BAUDRATE



;===========================================================================
; Clears the receive FIFO.
; Default is to use a 100ms timeout.
; For return from the breakpoints a faster version is used,
; transport_drain_with_timeout.
; The timeout is passed via DE. Unit=53/28000=1.9us, i.e. 526 => 1ms.
; Changes:
;   A, BC, DE
;===========================================================================
transport_drain:
    ld de,53000 ; 100 ms
transport_drain_with_timeout:
    ld (.read_next_byte+1),de
    ld bc,UART_TX

.read_next_byte:
    ld de,53000 ; 100ms
    ; 53 T-states => 265*53/28000 = 0.5ms
.read_loop:
    in a,(c)					; Read status bits
    bit UART_RX_FIFO_EMPTY,a
    jr nz,.read_byte

    ; Wait
    dec de
    ld a,d
    or e
    jr nz,.read_loop

    ; No byte received since at least 100ms.
    ret

.read_byte:
    ; At least 1 byte received, read it
    inc b	; The low byte stays the same
    in a,(c)    ; read one byte
    dec b
    jr .read_next_byte


;===========================================================================
; Just changes the border color.
;===========================================================================
change_border_color:
    ld a,(slow_border_change)
    or a
    ret z   ; Don't change color if off
    ld a,(border_color)
    inc a
    and 0x07
    ld (border_color),a
    out (BORDER),a
    ret


;===========================================================================
; Waits until an RX byte is available.
; Note: This runs when possibly the layer 2 read/write is set. I.e. it is not
; allowed to read/write data.
; I.e. also no CALLs, no PUSH/POP.
;
; IT IS BOUNDED, and it did not used to be. On expiry it goes back to main_loop
; — NOT to rx_timeout, and not to anything that reports an error: this wait is
; the debugger's idle state once a client has attached, so expiry means "nobody
; has said anything for a while", which is not a fault and must cost a healthy
; session nothing. See TRANSPORT_WAIT_RX_SECONDS in constants.asm for the whole
; argument. The no-CALL/no-PUSH rule is not in the way: BC and DE are untouched
; between the two layer-2 writes either side of the loop, so the countdown lives
; in registers and needs neither the stack nor a memory cell.
; Changes:
;   A, DE, BC
;===========================================================================

 IF TRANSPORT_WAIT_RX_SECONDS
; 59 T-states per iteration when nothing has arrived — 7+11+8+7 for the status
; read and its not-taken branch, 6+4+4+12 for the countdown — times 65536
; iterations per outer pass, at the 28 MHz the debugger runs at.
UART_WAIT_RX_PASSES:    equ (28000000/59) * TRANSPORT_WAIT_RX_SECONDS / 65536
    ASSERT UART_WAIT_RX_PASSES > 0
 ENDIF

transport_wait_rx:
    ; Write layer 2 previous value
    ld a,(backup.layer_2_port)
    ld bc,LAYER_2_PORT
    out (c),a

 IF TRANSPORT_WAIT_RX_SECONDS
    ld bc,UART_WAIT_RX_PASSES
    ld de,0                 ; the inner counter wraps to 65536 on its first dec
 ENDIF

.loop:
    ; Check if byte available.
    ld a,HIGH UART_TX
    in a,(LOW UART_TX)	; Read status bits
    bit UART_RX_FIFO_EMPTY,a
 IF TRANSPORT_WAIT_RX_SECONDS
    jr nz,.ready
    ; Nothing yet: spend one iteration of the bound.
    dec de
    ld a,d
    or e
    jr nz,.loop
    dec bc
    ld a,b
    or c
    jr nz,.loop

    ; The bound expired. THE LAYER-2 PORT IS PUT BACK BEFORE LEAVING — the
    ; epilogue below is repeated here rather than jumped to, because leaving
    ; with layer-2 read/write still enabled would send every subsequent memory
    ; access to layer 2, and there is no register left to carry "expired" past
    ; a shared epilogue that clobbers A and BC.
    ld a,(backup.layer_2_port)
    and 11111010b	; Disable read/write only
    ld bc,LAYER_2_PORT
    out (c),a
    ; Back to the idle loop, which resets no debuggee state and re-enters
    ; cmd_loop on the next byte. SP is reset because cmd_loop is reached by JP
    ; from arbitrary depth and this call's frame would otherwise leak two bytes
    ; per expiry.
    ld sp,debug_stack.top
    jp main_idle
 ELSE
    jr z,.loop   ; Wait until byte available
 ENDIF

.ready:
    ; Disable layer 2 read/write
    ld a,(backup.layer_2_port)
    and 11111010b	; Disable read/write only
    ld bc,LAYER_2_PORT
    out (c),a
    ret       ; RET if byte available


;===========================================================================
; Checks if a byte is available at the UART.
; Returns:
;   NZ = Byte available
;   Z = No byte available
; Changes:
;   AF
;===========================================================================
transport_byte_available:
    ld a,HIGH UART_TX
    in a,(LOW UART_TX)
    ; Read status bits
    bit UART_RX_FIFO_EMPTY,a
    ret

;===========================================================================
; Waits until an RX byte is available and returns it.
; Waits max. 100ms for the next byte, otherwise a timeout error is thrown.
; Returns:
;   A = the received byte.
; Changes:
;   BC, DE
;===========================================================================
transport_read_byte:
    ; Change border
.flash1:
    ld a,BLUE
    out (BORDER),a

    ; Wait on byte
    ld de,40000 ; => 100ms
    ld bc,UART_TX

    ; 68 T-states => 200*68/27Mhz = 0.5ms
.wait_loop:
    in a,(c)					; Read status bits
    bit UART_RX_FIFO_OVERFLOW,a
    jr nz,.rx_overflow
    bit UART_RX_FIFO_EMPTY,a
    jr nz,.byte_received
    dec de
    ld a,d
    or e
    jr nz,.wait_loop


    ; "Timeout"
.timeout:
    nop ; LOGPOINT transport_read_byte: ERROR=TIMEOUT
    jp rx_timeout   ; ASSERTION

.byte_received:
.flash2:
    ; Change border
    ld a,YELLOW
    out (BORDER),a

    ; At least 1 byte received, read it
    inc b	; The low byte stays the same
    in a,(c)
    ret


; Called if a UART RX buffer overflow occurred.
.rx_overflow: ; The receive timeout handler
    ld a,ERROR_RX_OVERFLOW
    jr rxtx_error


; Called if a UART RX timeout occurs.
; As this could happen from everywhere the call stack is reset
; and then the cmd_loop is entered again.
rx_timeout: ; The receive timeout handler
    ld a,ERROR_RX_TIMEOUT
rxtx_error:
    jp drain_main


; Called if a UART TX timeout occurs.
; As this could happen from everywhere the call stack is reset
; and then the cmd_loop is entered again.
tx_timeout: ; The receive timeout handler
    ld a,ERROR_TX_TIMEOUT
    jr rxtx_error



;===========================================================================
; Enables flashing of the border while receiving data.
;===========================================================================
transport_flashing_border.enable:
    ld a,0x3E   ; LD A,n
    ld (transport_read_byte.flash1),a
    ld (transport_read_byte.flash2),a
    ld a,BLUE
    ld (transport_read_byte.flash1+1),a
    ld a,YELLOW
    ld (transport_read_byte.flash2+1),a
    ret


;===========================================================================
; Disables flashing of the border while receiving data.
;===========================================================================
transport_flashing_border.disable:
    ld a,0x18   ; JR 2
    ld (transport_read_byte.flash1),a
    ld (transport_read_byte.flash2),a
    ld a,2
    ld (transport_read_byte.flash1+1),a
    ld (transport_read_byte.flash2+1),a
    ret


;===========================================================================
; Waits until TX is ready on the UART and writes one byte to the UART.
; Parameter:
;  A = the byte to write.
; Returns:
;  -
; Changes:
;  BC
;===========================================================================
transport_write_byte:
    push de, af
    ; Wait for TX ready
    call wait_for_uart_tx
    ; Transmit byte
    pop af, de
    out (c),a
    ret


;===========================================================================
; Waits until the next byte can be sent over the UART.
; In Core 03.01.10 the uart tx buffer is 64 byte.
; If it takes too long an error is generated.
; Changes:
;  AF, BC (=PORT_UART_TX), E
;===========================================================================
wait_for_uart_tx:
    ; Send response back
    ld bc,UART_TX
    ; Check if ready for transmit
    ld e,0
.wait_tx:
    in a,(c)
    bit UART_TX_FULL,a
    ret z

    ;bit UART_TX_EMPTY,a
    ;ret nz

    dec e
    jr nz,.wait_tx

    nop ; LOGPOINT wait_for_uart_tx: ERROR=TIMEOUT
    jp tx_timeout   ; ASSERTION


;===========================================================================
; Waits until the UART TX buffer is completely empty.
; Is used to wait until the joy port can be switched.
; Changes:
;  AF, BC (=PORT_UART_TX), E
;===========================================================================
transport_flush:
    ; Send response back
    ld bc,UART_TX
    ; Check if ready for transmit
    ld de,64*256    ; max. 64 characters
    ld e,0
.wait_tx:
    in a,(c)
    bit UART_TX_EMPTY,a
    ret nz  ; 1 if empty
    dec de
    ld a,d
    or e
    jr nz,.wait_tx

    nop ; LOGPOINT transport_flush: ERROR=TIMEOUT
    jp tx_timeout   ; ASSERTION



;===========================================================================
; Sets the UART baud rate.
; Source code is taken from NDS, https://github.com/Ckirby101/NDS-NextDevSystem.
; See also https://dl.dropboxusercontent.com/s/a4c4k9fsh2aahga/UsingUART2andWIFI.txt?dl=0
; The baudrate timings depend on the video timings in register 0x11.
; They don't depend on video mode being 50 or 60 Hz.
; Sets also 8 bit mode.
; Returns:
;  -
; Changes:
;  A, BC, DE, HL
;===========================================================================
transport_init:
    ; Set 8 bit
    ld bc,UART_FRAME
    ld a,00011000b   ; 8 bit
    out	(c),a

    ; Select UART and clear prescaler MSB
    ld bc,UART_SELECT
    ld a,00010000b
    out	(c),a

    ; Get display timing
    ld a,REG_VIDEO_TIMING
    call read_tbblue_reg
    and 0111b			;video timing is in bottom 3 bits, e.g. HDMI=111b

    ; Get baudrate prescale values from table
    ld hl,baudrate_table
    add hl,a
    ld a,(hl)
    ; ignoring the high byte

    ; Write low byte of prescaler
    ld bc,UART_RX ; Writing=set baudrate
    ld l,a
    and 0x7F
    out	(c),a		;set lower 7 bits

    ; Write 2nd byte of prescaler
    rlc l
    ld a,0x40
    rla
    out	(c),a		;set to upper bits

    ret


;===========================================================================
; Sets up the ESP UART at joystick port.
; TX = PIN 7 both joystick ports
; RX = PIN 9 Joystick 2
; These pins are not used on normal Joystick.
; Only for Sega Genesis controller which cannot be used.
; Parameters:
;  uart_joyport_selection:
;     0x0=00b => no joystick port used
;     0x1=01b => joyport 1
;     0x2=10b => joyport 2
; Changed:
;  AF, BC, HL
;===========================================================================
transport_activate:
    ; Core 3.01.10
    ld a,(uart_joyport_selection)
    dec a
    jr nz,.joy_port_cont
    ; Joy port 1 selected
    nextreg REG_JOYSTICK_IO_MODE,10100000b  ; Left joy port
    ret
.joy_port_cont:
    dec a
    jr nz,.joy_port_none
    ; Joy port 2 selected
    nextreg REG_JOYSTICK_IO_MODE,10110000b  ; Right joy port
    ret
.joy_port_none:
    ; No joy port selected
    nextreg REG_JOYSTICK_IO_MODE,0  ; Disable joy IO mode
    ret


;===========================================================================
; Waits for a certain number of scanlines.
; Parameters:
;  H = the number of scanlines to wait.
; Changed:
;  AF, BC, HL
;===========================================================================
 IF 0
wait_scan_lines:
    ld bc,IO_NEXTREG_REG
    ld a,REG_ACTIVE_VIDEO_LINE_L
    out (c),a
    inc b
    ; Read first value
    in a,(c)
    ld l,a
    ; Loop
.loop:
    in a,(c)        ; read the raster line LSB
    cp l
    jr z,.loop
    ; Line changed
    ld l,a
    dec h
    jr nz,.loop
    ret
 ENDIF
