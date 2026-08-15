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
; machine; this hands them back. Clearing NR 0x0B is also what re-points the
; UART's RX away from the joystick pin (zxnext.vhd:3341, :3536) — which is why
; a byte from the PC could not arrive while the debuggee ran in this mode.
;
; ON JOY PORT 2 IT NO LONGER CLEARS IT, AND THAT IS ASYNCHRONOUS BREAK IN UART
; MODE. Leaving io mode on keeps the joystick pin wired to UART1's receiver
; while the debuggee runs, so a CMD_PAUSE from the PC lands in a FIFO that
; mf_nmi_poll's transport_poll_traffic can see. The poll and the Copper
; machinery are M2's and unchanged; the only thing that ever stopped them
; working over a cable was this macro. See doc/ASYNCHRONOUS-BREAK-DESIGN.md §8.
;
; PORT 1 STILL CLEARS IT, AND THE ASYMMETRY IS DELIBERATE (user, 2026-08-12):
; the enable is global and the mode field names exactly one connector, so the
; cable and a real joystick cannot share a port. Keeping port 1's old behaviour
; is what leaves that connector free for the debugged program's own joystick —
; Kempston and MD reads survive io mode, so a game using those really does get
; a working stick there. It also means asynchronous break exists only on the
; port-2 selection, which show_ui and the HOWTO both say.
;
; A macro rather than a subroutine: the single caller is inline in
; backup.asm's restore path, and a transport with nothing to hand back expands
; this to nothing rather than paying for a CALL and a RET.
;
; The registers are free here. This runs in restore_registers immediately after
; `call transport_flush` — which itself changes AF and BC — and before
; `ld sp,backup.r`, so every one of the debuggee's values is still on the stack
; and is popped afterwards. Nothing this touches is live.
; Changes:
;   AF
;===========================================================================
    MACRO TRANSPORT_DEACTIVATE
    ; Joy port 2 keeps io mode, so the PC can still break in. Anything else
    ; hands the port back and gives up the break with it.
    ld a,(uart_joyport_selection)
    cp 2
    jr z,.transport_deactivate_keep
    ; Disable joy port IO mode to enable the joysticks
    nextreg REG_JOYSTICK_IO_MODE,0
.transport_deactivate_keep:
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
; TRANSPORT_IDLE_TICK — main_loop went round once with nothing to do.
;
; Nothing to do, and again that is a statement rather than a gap. The ESP
; transport uses this to reclaim the module's inbound connection slots when the
; debugger has been idle for a while (issue #24), because a peer that vanishes
; without closing leaves one held and only a module has such slots to leak.
; There is no module under a joy-port cable and no per-connection resource of
; any kind, so there is nothing here to house-keep — and the UART build's bytes
; do not move.
;===========================================================================
    MACRO TRANSPORT_IDLE_TICK
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

; 0x153B IS A SHARED POINTER, NOT A RESOURCE WE OWN, AND THAT IS WHY THE
; CONSTANTS BELOW EXIST. Bit 6 says which of the machine's two UARTs every one
; of 0x133B, 0x143B and 0x163B refers to at the instant of the access
; (ports.txt:370, serial/uart.vhd:335-372) — so a read of 0x133B means "the
; status of whichever channel is selected", where we mean "the status of OUR
; channel". Those coincide only while nothing else has moved the pointer, and a
; debuggee legitimately using the OTHER UART must move it. Issue #42.
;
; Writing these values back has BIT 4 CLEAR, which is what makes the correction
; safe: with bit 4 clear the write changes only the select and leaves both
; 17-bit prescalers alone (ports.txt:371-372, serial/uart.vhd:280-287). A write
; with bit 4 set would take bits 2:0 as the prescaler's top three bits.
;
; BIT 6 IS WHERE THE HARDWARE REPORTS THE SELECT ON A READ (serial/uart.vhd:355
; and :371, ports.txt:370 in words), and the mask below is that bit and no
; other. It was a build seam until 2026-08-13: jnext reported the select in bit
; 3, so the shipped mask read back as always-clear there and — in a build whose
; channel is 01000000b — inverted the poll, taking `.borrow_select` on every
; call and leaving the select on UART0 where transport_init put UART1. The
; common path a real Next takes every frame was, until that day, executed by no
; run in this repository at all. jnext#253 fixed the read-back and jnext#251
; gave the joy port an RX source, so the mask is exercised as shipped AND the
; common path now runs: `make test-uart-break` resumes a debuggee whose Copper
; list drives this poll while a byte waits in the FIFO. Kept as history because
; it is the reason this paragraph is long: DO NOT mask both bits to accommodate
; an emulator.
UART_SELECT_CHANNEL: equ 01000000b  ; the select bit, for masking a read

; WHICH CHANNEL IS OURS IS A RUNTIME QUESTION, AND ISSUE #44 IS WHAT IT COST TO
; ASSUME OTHERWISE. It was `equ 01000000b` — UART1, always — because io mode
; with NR 0x0B bit 0 clear idles the ESP-01's TX and de-asserts its RTR
; (zxnext.vhd:3343, :3349), so a port-2 resume that left io mode on would sever
; the module for the whole session. Bit 0 SET routes the joystick pin to UART1
; and leaves the ESP alone, which is what buys asynchronous break over a cable.
;
; But that reasoning covers only the selections that TURN IO MODE ON. With it
; off — the "no joystick port" selection, i.e. a serial adapter on the WiFi
; connector CN9, which is upstream's original setup — the two channels listen to
; different pins (zxnext.vhd:3340-3341):
;
;   uart0_rx <= joy_uart_rx when ... nr_0b_joy_iomode_0 = '0' else i_UART0_RX;
;   uart1_rx <= joy_uart_rx when ... nr_0b_joy_iomode_0 = '1' else pi_uart_rx;
;
; UART0's else-branch is the CN9 pin the cable is on; UART1's is the Raspberry
; Pi header. Selecting UART1 unconditionally therefore pointed the debugger at
; the wrong pin for that selection and it received nothing at all — reported by
; Maziac on real hardware, 2026-08-15.
;
; So the channel follows the selection: UART1 for a joystick port, UART0 for
; CN9. With io mode off there is no ESP to sever, so the CN9 case is upstream's
; behaviour exactly.
UART_SELECT_JOY:     equ 01000000b  ; UART1, fed by the joystick pin in io mode
UART_SELECT_CN9:     equ 00000000b  ; UART0, fed by i_UART0_RX — the ESP header

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
; Variables.
;===========================================================================

; The 0x153B select byte for the channel the debugger is using — UART_SELECT_JOY
; or UART_SELECT_CN9, chosen from uart_joyport_selection by transport_init. See
; the constants above for why it is not one of them.
;
; It is in the image copied into MAIN_BANK, so it is re-initialised on every
; init_main_bank; the value below is only what the first transport_init would
; overwrite anyway, and matching the shipped default costs nothing.
uart_select_ours:   defb UART_SELECT_JOY



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
;
; ONE ROUTINE UNDER TWO NAMES, AND THE SECOND COSTS NOTHING. Over a cable there
; is no framing above the byte stream and no module putting unsolicited lines on
; the wire, so "is a byte waiting" already satisfies every bound the NMI poll
; imposes on transport_poll_traffic (transport.asm): one status read, AF only,
; and it does not pop the RX FIFO — reading 0x133B is the STATUS register, where
; 0x143B is the data one. The ESP build cannot share them, because its
; transport_byte_available scans.
;
; It does clear the RX overflow and framing flags on every read
; (serial/uart.vhd:536-539, `uart0_tx_rd_fe`). That is pre-existing here — the
; idle loop already reads this register continuously — and mf_nmi_poll asks its
; prgm_state question first so that this is never touched while the debugger is
; using the link itself.
;
; THIS IS REACHED WITH A DEBUGGEE RUNNING NOW, WHICH IT WAS NOT BEFORE. Until
; TRANSPORT_DEACTIVATE stopped clearing NR 0x0B on joy port 2, the RX source was
; severed before the poll could ever see a byte, so this half of asynchronous
; break was shipping dead code.
;
; IT BORROWS THE UART SELECT, AND THAT IS NOT DEFENSIVE PROGRAMMING AGAINST THE
; DEBUGGEE — IT IS THIS READ BEING UNDER-SPECIFIED WITHOUT IT (issue #42). The
; `in a,(0x133B)` below means "the status of whichever channel 0x153B selects";
; what it INTENDS is "the status of ours". Those coincide only while nothing has
; moved the pointer since transport_init, and the machine has two UARTs
; precisely so that two owners can coexist — the debugger on one, the debuggee
; on the other. Documenting "do not write 0x153B" would charge the debuggee for
; a resource we are not using; borrowing the pointer for one read costs it
; nothing at all. See uart_select_ours above and §8.5 of the design doc.
;
; THE COMMON PATH DOES NOT WRITE. It reads the select, compares, and falls
; straight through — about 70 T-states against the poll's measured ~1288 per
; frame, of which the push/pop of HL and the fetch of uart_select_ours are the
; ~31 that issue #44 added by making the channel a runtime value. Only a
; debuggee that has actually moved the pointer pays for the correction, and it
; gets its value back before the NMI returns.
;
; Returns:
;   NZ = Byte available
;   Z = No byte available
; Changes:
;   AF
;===========================================================================
transport_poll_traffic:
transport_byte_available:
    ; Is 0x133B about our channel? Which channel that IS is a runtime value
    ; since issue #44 — UART1 on a joystick port, UART0 on CN9 — so this reads
    ; it rather than comparing against a constant. HL is pushed for it and
    ; restored on both paths, so the AF-only contract above still holds.
    push hl
    ld hl,uart_select_ours
    ld a,HIGH UART_SELECT
    in a,(LOW UART_SELECT)
    and UART_SELECT_CHANNEL
    cp (hl)
    jr nz,.borrow_select
    pop hl

    ld a,HIGH UART_TX
    in a,(LOW UART_TX)
    ; Read status bits
    bit UART_RX_FIFO_EMPTY,a
    ret

.borrow_select:
    ; The debuggee owns the pointer and is still running, so this is a loan:
    ; point it at our channel, read, and put its value straight back. BC is
    ; free here in practice (mf.asm:205 — the debuggee's is on the MF stack),
    ; but the interface promises it preserved, so the promise is kept. The
    ; stack is MF RAM, switched by nmi66h before this path exists.
    push bc
    ld bc,UART_SELECT
    ld a,(hl)
    out (c),a

    ; The debuggee's channel is the other one — there are only two, and the
    ; compare above has just shown it is not ours. Computed HERE rather than
    ; after the read, because `xor` sets the flags and the read is what puts
    ; the verdict in them.
    xor UART_SELECT_CHANNEL
    ld h,a

    ld a,HIGH UART_TX
    in a,(LOW UART_TX)
    bit UART_RX_FIFO_EMPTY,a

    ; NEITHER `ld a,r` NOR `out (c),a` TOUCHES THE FLAGS, so the verdict the
    ; caller reads survives the restore with no push/pop of AF. `in a,(n)` does
    ; not either, unlike `in r,(c)` — which is why the read above can sit
    ; between the two writes. `pop` leaves them alone too.
    ld a,h
    out (c),a
    pop bc
    pop hl
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
;
; ON A JOYSTICK PORT WE USE UART1, THE "PI" UART, AND NOT UART0 — and that is
; what makes asynchronous break possible in this mode. NR 0x0B bit 0 chooses
; which UART the joystick pin feeds, and with bit 0 CLEAR the same io mode holds
; the ESP-01's TX line idle and de-asserts its RTR (zxnext.vhd:3343, :3349). So a
; build that left io mode on with bit 0 clear — which is what buys the break —
; would sever the ESP for the whole session, for precisely the population the
; UART build exists to serve. Bit 0 SET leaves both those signals alone.
; See doc/ASYNCHRONOUS-BREAK-DESIGN.md §8.3.
;
; ON THE "NO JOYSTICK PORT" SELECTION WE USE UART0, AND ISSUE #44 IS WHAT IT
; COST TO GET THAT WRONG. That selection means the cable is on the WiFi
; connector CN9, and with io mode off UART1's receiver is wired to the
; Raspberry Pi header instead (zxnext.vhd:3341) — so the debugger sat listening
; to a pin the cable is not on and received nothing. See UART_SELECT_JOY above.
;
; THE CHANNEL IS THEREFORE CHOSEN HERE, FROM uart_joyport_selection, AND THAT
; PUTS AN ORDERING CONSTRAINT ON main.asm: the selection must be established
; before this runs, or the first configure lands on the wrong channel. It also
; means this routine is called again from transport_activate whenever the
; debugger takes control, so that the selector keys reconfigure rather than
; leaving a channel at whatever baud rate the machine happened to have.
;
; THE SELECT MUST BE WRITTEN BEFORE THE FRAME REGISTER, AND THAT ORDER IS
; LOAD-BEARING. Every one of 0x133B, 0x143B and 0x163B acts on whichever
; channel 0x153B bit 6 selects at the instant of the access
; (serial/uart.vhd:293-306 frame, :311-330 prescaler LSB, :335-372 the read
; mux) — they are two independent sets of registers, not one. Written the other
; way round, the frame byte lands on UART0 and UART1 keeps whatever it had.
; It would LOOK right, because 0x163B's documented default is 0x18 and that is
; exactly the value we write — but that default is restored only by
; `i_reset_hard`, which zxnext.vhd:3367 ties to the constant '0' ("hard_reset
; done by core load"). So NO reset a guest can cause ever puts it back, and a
; program that had configured UART1 differently would leave us running at its
; frame settings. Verified rather than assumed; see the design doc §8.
;
; Returns:
;  -
; Changes:
;  A, BC, HL
;  DE IS PRESERVED, and that is load-bearing rather than incidental:
;  transport_activate calls this, and breakpoints.asm holds the break reason in
;  D across that call. The header claimed DE until issue #44 and never touched
;  it — read_tbblue_reg changes A, BC and F only.
;===========================================================================
transport_init:
    ; Which of the two UARTs is ours? UART1 when the cable is on a joystick
    ; port, UART0 when it is on CN9.
    ;
    ; THE TEST MUST AGREE WITH transport_activate's, WHICH TAKES EVERY VALUE
    ; BUT 1 AND 2 AS "no joystick port" — including the pathological 3 that
    ; ut_uart.asm drives at it. `dec a : cp 2` carries for exactly 1 and 2,
    ; where 0 wraps to 0xFF and 3 becomes 2, and neither carries. `ld a,n` does
    ; not touch the flags, so the jump below is still testing that `cp`.
    ld a,(uart_joyport_selection)
    dec a
    cp 2
    ld a,UART_SELECT_JOY
    jr c,.channel_chosen
    ld a,UART_SELECT_CN9
.channel_chosen:
    ld (uart_select_ours),a

    ; Select it, and clear the prescaler MSB with it (bit 4 = these bits are
    ; being written, bits 2:0 = 0). This comes FIRST: it is what makes the two
    ; writes below land on our channel rather than on the other one.
    or 00010000b
    ld bc,UART_SELECT
    out	(c),a

    ; Set 8 bit
    ld bc,UART_FRAME
    ld a,00011000b   ; 8 bit
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
; Sets up the UART at a joystick port.
; TX = PIN 7 both joystick ports
; RX = PIN 9 Joystick 2
; These pins are not used on normal Joystick.
; Only for Sega Genesis controller which cannot be used.
;
; BIT 0 IS SET ON BOTH PORTS, AND IT IS THE WHOLE OF WHY ASYNCHRONOUS BREAK IS
; REACHABLE HERE. It routes the joystick pin to UART1 instead of UART0, which
; leaves the ESP-01's TX and RTR lines untouched (zxnext.vhd:3343, :3349, both
; conditioned on bit 0 = 0). That matters twice over: it is what lets
; TRANSPORT_DEACTIVATE leave io mode ON across a resume — see there — and it
; also means this routine no longer disturbs the ESP AT ALL, where before it
; idled the module's TX line for as long as the debugger held the machine, on
; either port. See doc/ASYNCHRONOUS-BREAK-DESIGN.md §8.3, and transport_init
; for the matching channel select.
;
; What it costs instead is the Raspberry Pi header UART, whose TX is idled and
; whose RTR is de-asserted while io mode is on (zxnext.vhd:3344, :3350) — far
; rarer on a real Next than the ESP, and only if NR 0xA0 has configured it.
; NR 0xA0 is NOT a precondition for the joystick routing itself: it is not a
; term of the uart1_rx mux (zxnext.vhd:3341), so nothing has to be set up here.
;
; IT ALSO RECLAIMS THE UART SELECT, AND WITHOUT THAT THE POLL'S GUARD WOULD BE
; HALF A FIX (issue #42). Nothing else re-establishes 0x153B once MAIN has been
; entered. So a debuggee that moved the pointer and then stopped — at a
; breakpoint, on the button, or through the poll's own break-in — would hand the
; debugger a link whose every read and write went to the OTHER UART, and the
; session would be mute rather than merely unbreakable. Guarding the poll alone
; would therefore have converted "Pause does nothing" into "Pause stops the
; machine and the debugger never speaks again", which is worse.
;
; IT RECLAIMS THE FRAME REGISTER AND THE PRESCALER WITH IT, by calling
; transport_init rather than writing the select by hand — those are per-channel
; too, so the same argument covers them. That is also what makes the selector
; keys work: since issue #44 the channel FOLLOWS uart_joyport_selection, and a
; user pressing "3" comes back through here (read_key_joyport -> main_redraw),
; where the newly selected channel gets configured before anything reads it.
;
; REPROGRAMMING THE LINK AT EVERY ENTRY CANNOT DISTURB A BYTE IN FLIGHT, which
; matters because the poll can break in on a CMD_PAUSE with more of the client's
; traffic still arriving. The receiver latches its prescaler and frame bits when
; it sees a start bit and holds them for the whole character
; (serial/uart_rx.vhd:51, :143-151), and the transmitter samples at the moment a
; byte is sent (uart_tx.vhd:37-38) — so a write landing mid-character is picked
; up by the NEXT one. The one bit that WOULD abort a transfer is the frame
; register's bit 7, and transport_init always writes it clear.
;
; This is the right single place: all three entries into the debugger come
; through here (main.asm, mf.asm, breakpoints.asm) and none of them has touched
; the link yet.
;
; IT DOES NOT PUT THE DEBUGGEE'S SELECTION BACK ON RESUME, and that is a known
; gap rather than an oversight — the same shape as backup.io_next_reg, and it
; wants the same treatment: the value belongs with the other break-time
; captures, not here, because this routine also runs when the debugger is
; ALREADY executing (main.asm's path through drain_main and cmd_close), where
; the value it would read is its own. Saving unconditionally here is issue #26's
; defect one register along. See the design doc §8.5.
;
; Parameters:
;  uart_joyport_selection:
;     0x0=00b => no joystick port used
;     0x1=01b => joyport 1
;     0x2=10b => joyport 2
; Changed:
;  AF, BC, HL
;===========================================================================
transport_activate:
    ; Reclaim the channel — select, frame register and prescaler — before
    ; anything uses the link. DE survives this; see transport_init's header.
    call transport_init

    ; Core 3.01.10
    ld a,(uart_joyport_selection)
    dec a
    jr nz,.joy_port_cont
    ; Joy port 1 selected
    nextreg REG_JOYSTICK_IO_MODE,10100001b  ; Left joy port, UART1
    ret
.joy_port_cont:
    dec a
    jr nz,.joy_port_none
    ; Joy port 2 selected
    nextreg REG_JOYSTICK_IO_MODE,10110001b  ; Right joy port, UART1
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
