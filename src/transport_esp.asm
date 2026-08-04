;===========================================================================
; transport_esp.asm
;
; The ESP-01 WiFi transport: DZRP over TCP, with the Next as the server.
; Implements the interface described in transport.asm. Selected at assembly
; time by -DTRANSPORT_WIFI; see constants.asm and the Makefile.
;
; The AT chain, the `+IPD` parser and the `AT+CIPSEND` framing are ported from
; test/esp_server.asm, the M0(b) spike that `make test-esp` exercises against a
; real socket. That fixture exists precisely so this protocol work was already
; proven somewhere it could be debugged without the debugger in the way.
;
;---------------------------------------------------------------------------
; What is different from the serial transport, and why
;---------------------------------------------------------------------------
;
; 1. NO 0xA5 PREAMBLE. TRANSPORT_MESSAGE_START expands to nothing here. The
;    byte is a documented DZRP extension for the SERIAL link only
;    (doc/legacy/Design.md:30-31): a game that grabs the joy port leaves the
;    Next emitting endless zeroes, and DeZog's ZxNextSerialRemote resynchronises
;    on 0xA5. Its CSpectRemote — the socket client this transport is spoken to
;    by — does NOT strip it, so emitting it here would corrupt every frame.
;
; 2. RESPONSES ARE BUFFERED, then framed. `AT+CIPSERVER` requires `AT+CIPMUX=1`
;    and `AT+CIPMUX=1` forbids `AT+CIPMODE=1`, so there is no transparent byte
;    pipe: every outgoing chunk must be announced with `AT+CIPSEND=<id>,<len>`
;    BEFORE its bytes. transport_write_byte therefore appends to a buffer and
;    the buffer is sent when it fills or when the message ends. TCP is a stream,
;    so splitting one DZRP response across several CIPSENDs is invisible to the
;    client.
;
;    "When the message ends" is TRANSPORT_END_MESSAGE, and it sits at the top of
;    `cmd_loop` and of `main` — the two places every completed response and
;    notification passes through. `cmd_continue` is the third path out and it
;    already called transport_flush (backup.asm's restore_registers).
;
; 3. THE CONNECTION ID IS READ, NEVER ASSUMED. It comes out of the `+IPD`
;    header and goes straight back onto the `AT+CIPSEND`. MEMORY.md 2026-08-04:
;    jnext reserves slot 0 for the guest's own outbound AT+CIPSTART, so INBOUND
;    IDS START AT 1. A parser that hardcoded the 0 the Espressif documentation
;    leads you to expect would address the outbound slot, get ERROR, send
;    nothing, and look exactly like a DZRP bug. Whether real firmware numbers
;    the same way is UNVERIFIED, which is the other reason it is read.
;
;    esp_conn_id == 0 therefore means "no client has ever been seen", and
;    transport_flush discards rather than trying to send to nobody. That is what
;    keeps a button NMI with no debugger attached quiet instead of parking on a
;    TX timeout.
;
; 4. THE JOY PORT IS NEVER TAKEN. UART0's RX is on the ESP-01 pin whenever
;    NR 0x0B's joy IO mode is off (zxnext.vhd:3340, :3536), which is the
;    power-on state. transport_activate writes 0 there anyway — seven bytes that
;    remove any dependence on what the debuggee left behind — and
;    TRANSPORT_DEACTIVATE expands to nothing, because there is nothing to hand
;    back.
;
; 5. 115200 BAUD, not upstream's 921600. The ESP answers at its power-on rate
;    until told otherwise (doc/WIFI-SETUP.md; inferred, not measured on
;    hardware). Raising it is M3's baud negotiation and has to start here.
;
;---------------------------------------------------------------------------
; What this file does NOT do, deliberately
;---------------------------------------------------------------------------
;
; * It never configures WiFi. No AT+CWJAP, no SSID, no passphrase — see
;   doc/WIFI-SETUP.md for the three independent reasons. The Next must already
;   be associated.
; * It does not ask for the address (AT+CIFSR). That belongs with the
;   connect-string UI, which is a separate change: reporting an address means
;   parsing it and drawing it, and neither exists yet.
; * A RE-INIT WHILE ALREADY LISTENING REPORTS AN ERROR. Symbol Shift + NMI runs
;   transport_init again, and `AT+CIPSERVER=1,<port>` answers ERROR when a
;   server is already up (jnext esp_at.cpp:648). The link keeps working — the
;   listener is still there — but the screen says "RX Timeout". Clearing that
;   needs a wait that accepts OK *or* ERROR, which nothing else here needs.
;===========================================================================


;===========================================================================
; TRANSPORT_DEACTIVATE — the debugger is about to resume the debuggee.
;
; Nothing to do: this transport never took the joy ports, and the ESP holds
; the listening socket across the resume, which is what lets a byte from the
; PC arrive while the debuggee runs (plan §4).
;===========================================================================
    MACRO TRANSPORT_DEACTIVATE
    ENDM


;===========================================================================
; TRANSPORT_MESSAGE_START — emitted before every response and notification.
;
; Nothing here. See point 1 in the header: the 0xA5 preamble is required in
; UART mode and must be ABSENT in WiFi mode.
;===========================================================================
    MACRO TRANSPORT_MESSAGE_START
    ENDM


;===========================================================================
; TRANSPORT_END_MESSAGE — a complete message has been written.
;
; The serial transport writes bytes straight out and expands this to nothing.
; Here it is what turns the buffer into an AT+CIPSEND.
;===========================================================================
    MACRO TRANSPORT_END_MESSAGE
    call transport_flush
    ENDM


;===========================================================================
; Constants
;===========================================================================

; UART TX. Write=transmit data, Read=status
UART_TX:   equ 0x133b

; UART RX. Read data. Write=prescaler, in two 7-bit halves.
UART_RX:   equ 0x143b

; UART selection. bit 6 = 0 selects the ESP uart; bit 4 = 1 writes the
; prescaler's 3 most significant bits (bits 2:0).
UART_SELECT:   equ 0x153b

; UART frame format.
UART_FRAME:     equ 0x163b

; UART Status Bits (0x133B read):
UART_RX_FIFO_EMPTY: equ 0   ; 0=empty, 1=not empty
UART_RX_FIFO_OVERFLOW:  equ 2   ; 1=overflowed  ; (clears on read)
UART_TX_FULL:       equ 1   ; 1=Tx buffer is full

; The ESP-01's power-on baud rate. See point 5 in the header.
ESP_BAUDRATE:   equ 115200

; DeZog's `cspect` remote defaults to this port, so a launch.json that omits
; `port` still works. MEMORY.md 2026-08-04 pins it; Appendix B's example and
; test/esp_server.asm must agree.
ESP_SERVER_PORT:    equ 11000

; Bytes buffered before a chunk is pushed out. Under 256 so the length fits a
; byte and the send loop can use DJNZ; well under jnext's 2048-byte
; MAX_SEND_LEN and under real firmware's 2048 too. Larger would mean fewer
; round trips and more RAM; this is not a measured optimum, it is a size that
; obviously fits.
ESP_TX_CHUNK:   equ 240

; One pass of the RX poll below, in loop iterations. ~68 T-states each, so at
; 28 MHz (which is where the debugger runs — init_main_bank and enter_debugger
; both set RTM_28MHZ) 40000 is about 100 ms, matching the serial transport's
; per-byte timeout.
ESP_RX_WAIT:    equ 40000

; Passes of that poll during bring-up. The module owes an answer to every
; command in the chain, but a real ESP-01 is slower to first light than an
; emulated one, so the wait is generous exactly once and then dropped to one
; pass for the rest of the session.
ESP_INIT_PASSES:    equ 20

; How long to wait for room in the TX FIFO. One byte at 115200 is ~87 us; this
; loop is ~24 T-states, so 10000 is ~8.5 ms at 28 MHz — two orders of magnitude
; of headroom over a single byte time, and still bounded.
ESP_TX_WAIT:    equ 10000


;===========================================================================
; Const data
;===========================================================================

; Fsys/ESP_BAUDRATE for each of the eight video timings in NR 0x11 bits 2:0.
; The Fsys column is upstream's (transport_uart.asm's baudrate_table); the
; entries are 14 bits wide here rather than 8 because 115200 is not
; representable in upstream's table — 33000000/115200 is 286, and upstream's
; own comment says it needs 230400 or more.
esp_prescaler_table:
    defw 28000000/ESP_BAUDRATE
    defw 28571429/ESP_BAUDRATE
    defw 29464286/ESP_BAUDRATE
    defw 30000000/ESP_BAUDRATE
    defw 31000000/ESP_BAUDRATE
    defw 32000000/ESP_BAUDRATE
    defw 33000000/ESP_BAUDRATE
    defw 27000000/ESP_BAUDRATE

esp_cmd_ate0:       defb "ATE0",13,10,0
esp_cmd_at:         defb "AT",13,10,0
esp_cmd_cipmux:     defb "AT+CIPMUX=1",13,10,0
esp_cmd_cipserver:  defb "AT+CIPSERVER=1,"
    STRINGIFY ESP_SERVER_PORT
    defb 13,10,0

esp_str_ok:         defb "OK",13,10,0
esp_str_ipd:        defb "+IPD,",0
esp_str_prompt:     defb "> ",0         ; the trailing space is part of it
esp_str_send_ok:    defb "SEND OK",0
esp_str_cipsend:    defb "AT+CIPSEND=",0


;===========================================================================
; Variables.
;
; They live here rather than in data.asm because init_main_bank re-copies this
; whole image into MAIN_BANK on every init, so the values below are the state
; every session starts from. (The bank is RAM at run time; upstream's
; self-modifying border flash relies on the same thing.)
;===========================================================================

; Payload bytes still owed by the current +IPD chunk.
esp_rx_remaining:   defw 0

; The connection the last +IPD arrived on, echoed back on AT+CIPSEND.
; 0 = no client has ever been seen. See point 3 in the header.
esp_conn_id:        defb 0

; Outer passes of the RX poll; raised for bring-up, one for the rest.
esp_rx_retries:     defb 1
esp_rx_pass:        defb 1

; Set if the AT chain failed, so transport_activate can put it back into
; last_error after drain_main has cleared it. See transport_activate.
esp_init_error:     defb 0

esp_tx_len:         defb 0
esp_tx_byte:        defb 0
esp_tx_buffer:      defs ESP_TX_CHUNK
esp_cmd_buffer:     defs 24


;===========================================================================
; Raw byte I/O
;===========================================================================

;===========================================================================
; Writes one byte to the UART, waiting for room.
; Parameter:
;  A = the byte to write.
; Returns:
;  A and flags unchanged.
; Changes:
;  BC
;===========================================================================
esp_send_raw:
    push af, de
    ld bc,UART_TX
    ld de,ESP_TX_WAIT
.wait:
    in a,(c)
    bit UART_TX_FULL,a
    jr z,.ready
    dec de
    ld a,d
    or e
    jr nz,.wait
    nop ; LOGPOINT esp_send_raw: ERROR=TIMEOUT
    jp tx_timeout   ; ASSERTION
.ready:
    pop de, af
    out (c),a
    ret


;===========================================================================
; Reads one byte from the UART, waiting up to esp_rx_retries passes.
; Returns:
;  NC and A = the byte, or CY on timeout.
; Changes:
;  AF, BC, DE
;===========================================================================
esp_try_read_raw:
    ld a,(esp_rx_retries)
    ld (esp_rx_pass),a
    ld bc,UART_TX
.pass:
    ld de,ESP_RX_WAIT
.loop:
    in a,(c)					; Read status bits
    bit UART_RX_FIFO_OVERFLOW,a
    jr nz,.rx_overflow
    bit UART_RX_FIFO_EMPTY,a
    jr nz,.byte_received
    dec de
    ld a,d
    or e
    jr nz,.loop
    ; This pass expired
    ld a,(esp_rx_pass)
    dec a
    ld (esp_rx_pass),a
    jr nz,.pass
    scf
    ret

.byte_received:
    inc b	; The low byte stays the same
    in a,(c)
    or a    ; NC
    ret

.rx_overflow:
    ld a,ERROR_RX_OVERFLOW
    jp rxtx_error


;===========================================================================
; Reads one byte from the UART. A timeout does not return to the caller — it
; resets the call stack and re-enters the main loop, exactly as the serial
; transport does, because nothing above the transport checks for one.
; Returns:
;  A = the byte.
; Changes:
;  AF, BC, DE
;===========================================================================
esp_read_raw:
    call esp_try_read_raw
    ret nc
    nop ; LOGPOINT esp_read_raw: ERROR=TIMEOUT
    ; Flow through


; Called if a UART RX timeout occurs.
; As this could happen from everywhere the call stack is reset
; and then the cmd_loop is entered again.
rx_timeout: ; The receive timeout handler
    ld a,ERROR_RX_TIMEOUT
rxtx_error:
    jp drain_main


; Called if a UART TX timeout occurs.
tx_timeout: ; The transmit timeout handler
    ld a,ERROR_TX_TIMEOUT
    jr rxtx_error


;===========================================================================
; String helpers
;===========================================================================

;===========================================================================
; Sends a NUL-terminated string.
; Parameter:
;  HL = the string.
; Changes:
;  AF, BC, HL
;===========================================================================
esp_send_string:
    ld a,(hl)
    or a
    ret z
    call esp_send_raw
    inc hl
    jr esp_send_string


;===========================================================================
; Copies a NUL-terminated string, leaving DE after the last byte copied.
; Parameter:
;  HL = source, DE = destination.
; Changes:
;  AF, DE, HL
;===========================================================================
esp_copy_string:
    ld a,(hl)
    or a
    ret z
    ld (de),a
    inc hl
    inc de
    jr esp_copy_string


;===========================================================================
; Scans the incoming stream until a pattern is seen.
;
; Naive matching, with a restart that RE-TESTS the mismatching byte against the
; first pattern byte — dropping it instead would miss "OOK" against "OK". None
; of the patterns here has a repeated prefix, so nothing cleverer is needed.
;
; Scanning rather than comparing a whole reply is deliberate: the module
; interleaves unsolicited lines (`<id>,CONNECT`, `<id>,CLOSED`) with the
; answers it owes, and skipping past them is exactly what makes this transport
; resynchronise instead of desynchronising.
;
; Parameter:
;  HL = NUL-terminated pattern.
; Returns:
;  NC when matched, CY on timeout.
; Changes:
;  AF, BC, DE, HL
;===========================================================================
esp_wait_string:
    push hl                 ; keep the pattern start for restarts
.next:
    ld a,(hl)
    or a
    jr z,.matched
    call esp_try_read_raw   ; A = the byte read; HL still points at the pattern
    jr c,.timeout
    cp (hl)
    jr nz,.mismatch
    inc hl
    jr .next

.mismatch:
    ; Back to the start of the pattern, then re-test THIS byte against it.
    pop hl
    push hl
    cp (hl)
    jr nz,.next
    inc hl
    jr .next

.matched:
    pop hl
    or a                    ; NC
    ret

.timeout:
    pop hl
    scf
    ret


;===========================================================================
; Reads an unsigned decimal number terminated by a given byte.
; Parameter:
;  C = the terminator.
; Returns:
;  NC and HL = the value, or CY on timeout / a non-digit.
; Changes:
;  AF, BC, DE, HL
;===========================================================================
esp_read_decimal:
    ld hl,0
.digit:
    push hl, bc
    call esp_try_read_raw
    pop bc, hl
    ret c
    cp c
    jr z,.done
    sub '0'
    cp 10
    jr nc,.bad
    ; HL = HL*10 + A. Nothing between here and the final add touches A, so the
    ; digit survives in it without being saved.
    add hl,hl               ; x2
    ld d,h
    ld e,l
    add hl,hl               ; x4
    add hl,hl               ; x8
    add hl,de               ; x10
    ld d,0
    ld e,a
    add hl,de
    jr .digit
.done:
    or a                    ; NC
    ret
.bad:
    scf
    ret


;===========================================================================
; Writes A as unsigned decimal at (DE), no leading zeros.
; Parameter:
;  A = 0..255, DE = destination.
; Returns:
;  DE after the last digit.
; Changes:
;  AF, BC, DE, HL
;===========================================================================
esp_put_decimal:
    ld c,0                  ; nothing emitted yet
    ld b,100
    call .digit
    ld b,10
    call .digit
    ; The units digit is always emitted, so 0 prints as "0".
    add a,'0'
    ld (de),a
    inc de
    ret

.digit:
    ; A = value, B = divisor. Emits the quotient digit unless it is a
    ; suppressed leading zero, and returns the remainder in A.
    ld l,'0'
.sub:
    sub b
    jr c,.underflow
    inc l
    jr .sub
.underflow:
    add a,b                 ; undo the subtraction that went too far
    push af
    ld a,l
    cp '0'
    jr nz,.emit
    ; A leading zero is suppressed only while nothing has been emitted yet.
    ld a,c
    or a
    jr z,.skip
    ld a,'0'
.emit:
    ld (de),a
    inc de
    ld c,1
.skip:
    pop af
    ret


;===========================================================================
; The +IPD parser
;===========================================================================

;===========================================================================
; Scans for `+IPD,<id>,<len>:` and records the id and the payload length.
; The payload itself is NOT buffered — it is read a byte at a time by
; transport_read_byte, which is what keeps this transport's RAM cost a
; constant rather than a function of the largest DZRP command.
; Returns:
;  NC and esp_conn_id / esp_rx_remaining set, or CY on timeout / a malformed
;  header.
; Changes:
;  AF, BC, DE, HL
;===========================================================================
esp_sync_ipd:
    ld hl,esp_str_ipd
    call esp_wait_string
    ret c

    ; <id>, terminated by the comma. Refuse anything that does not fit a byte
    ; rather than truncating it: a silent narrowing here would send the reply
    ; to a different connection than the one that asked for it.
    ld c,','
    call esp_read_decimal
    ret c
    ld a,h
    or a
    jr nz,.bad
    ld a,l
    ld (esp_conn_id),a

    ; <len>, terminated by the colon
    ld c,':'
    call esp_read_decimal
    ret c
    ld (esp_rx_remaining),hl
    or a                    ; NC
    ret

.bad:
    scf
    ret


;===========================================================================
; Makes sure at least one payload byte is owed to us, synchronising to the
; next +IPD header if the previous chunk is used up. Does not return on
; failure — see esp_read_raw.
; Changes:
;  AF, BC, DE, HL
;===========================================================================
esp_require_payload:
    ld hl,(esp_rx_remaining)
    ld a,h
    or l
    ret nz
    call esp_sync_ipd
    jr c,.timeout
    ; A zero-length chunk would loop here forever. jnext never frames one
    ; ("the datagram is dropped rather than framed as an empty +IPD"), so this
    ; is a guard, not a case.
    ld hl,(esp_rx_remaining)
    ld a,h
    or l
    ret nz
.timeout:
    nop ; LOGPOINT esp_require_payload: ERROR=TIMEOUT
    jp rx_timeout   ; ASSERTION


;===========================================================================
; The interface
;===========================================================================

;===========================================================================
; Clears anything pending, and forgets any half-received command and any
; half-built response — a drain is what the error paths use to resynchronise,
; so a fragment must not survive it and go out as the head of the next reply.
; Default is to use a 100ms timeout.
; The timeout is passed via DE. Unit=53/28000=1.9us, i.e. 526 => 1ms.
; Changes:
;   A, BC, DE  (H is preserved: breakpoints.asm parks the break reason there)
;===========================================================================
transport_drain:
    ld de,53000 ; 100 ms
transport_drain_with_timeout:
    ld (.read_next_byte+1),de
    xor a
    ld (esp_rx_remaining),a
    ld (esp_rx_remaining+1),a
    ld (esp_tx_len),a
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

    ; No byte received since at least the timeout.
    ret

.read_byte:
    ; At least 1 byte received, read it
    inc b	; The low byte stays the same
    in a,(c)    ; read one byte
    dec b
    jr .read_next_byte


;===========================================================================
; Just changes the border color.
;
; Duplicated from transport_uart.asm rather than moved somewhere common: it is
; only reachable from main_loop, and moving it would shift every address in the
; serial build, which has to stay byte-identical.
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
; "A byte" here is either a payload byte already owed by a synchronised +IPD,
; or anything at all arriving from the module. The second case is what lets
; this obey the no-CALL rule: the actual header parsing happens afterwards, in
; transport_read_byte, which is allowed to use the stack.
; Changes:
;   A, BC
;===========================================================================
transport_wait_rx:
    ; Write layer 2 previous value
    ld a,(backup.layer_2_port)
    ld bc,LAYER_2_PORT
    out (c),a

.loop:
    ; Payload already owed to us?
    ld a,(esp_rx_remaining)
    or a
    jr nz,.ready
    ld a,(esp_rx_remaining+1)
    or a
    jr nz,.ready

    ; Otherwise anything from the module at all.
    ld a,HIGH UART_TX
    in a,(LOW UART_TX)	; Read status bits
    bit UART_RX_FIFO_EMPTY,a
    jr z,.loop   ; Wait until byte available

.ready:
    ; Disable layer 2 read/write
    ld a,(backup.layer_2_port)
    and 11111010b	; Disable read/write only
    ld bc,LAYER_2_PORT
    out (c),a
    ret       ; RET if byte available


;===========================================================================
; Checks if a DZRP byte is available.
;
; Unlike the serial transport this is not a status-bit read: the module puts
; unsolicited lines on the wire (`<id>,CONNECT` when a client arrives), and
; answering "yes, a byte" for those would send cmd_loop off to read a command
; that is not there and park it on a timeout the user sees as an error. So when
; the module is saying something but nothing is synchronised yet, this
; synchronises — bounded, and silently, because "the client connected but has
; not asked for anything" is not an error.
; Returns:
;   NZ = a payload byte is available
;   Z = nothing
; Changes:
;   AF
;===========================================================================
transport_byte_available:
    push bc, de, hl
    ld hl,(esp_rx_remaining)
    ld a,h
    or l
    jr nz,.ret

    ; Nothing owed. Is the module saying anything at all?
    ld a,HIGH UART_TX
    in a,(LOW UART_TX)
    bit UART_RX_FIFO_EMPTY,a
    jr z,.quiet

    call esp_sync_ipd       ; CY here just means "not a header yet"

.quiet:
    ld hl,(esp_rx_remaining)
    ld a,h
    or l
.ret:
    pop hl, de, bc
    ret


;===========================================================================
; Waits until a DZRP byte is available and returns it.
; A timeout is not returned to the caller — see esp_read_raw.
; Returns:
;   A = the received byte.
; Changes:
;   AF, BC, DE   (HL is preserved: receive_bytes keeps its buffer pointer there)
;===========================================================================
transport_read_byte:
    ; Change border
.flash1:
    ld a,BLUE
    out (BORDER),a

    push hl
    call esp_require_payload
    ld hl,(esp_rx_remaining)
    dec hl
    ld (esp_rx_remaining),hl
    pop hl

    ; Change border. Before the read, not after it, because the read's result
    ; is the return value and this would overwrite it.
.flash2:
    ld a,YELLOW
    out (BORDER),a

    jp esp_read_raw


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
; Queues one byte of the outgoing message.
;
; Nothing leaves here until the buffer fills or the message ends: the frame
; has to carry its own length, and the length is only known once the message
; is complete. See point 2 in the header.
; Parameter:
;  A = the byte to write.
; Returns:
;  A and flags unchanged (cmd_init's name loop and send_ntf_pause both re-test
;  the byte they just sent).
; Changes:
;  -
;===========================================================================
transport_write_byte:
    push af
    ld (esp_tx_byte),a
    push bc, de, hl

    ld hl,esp_tx_buffer
    ld a,(esp_tx_len)
    ld e,a
    ld d,0
    add hl,de
    ld a,(esp_tx_byte)
    ld (hl),a

    ld a,e
    inc a
    ld (esp_tx_len),a
    cp ESP_TX_CHUNK
    ; transport_flush and not esp_flush_chunk: it is the one that knows there
    ; may be nobody to send to.
    call z,transport_flush

    pop hl, de, bc
    pop af
    ret


;===========================================================================
; Sends everything queued and waits until the module has taken it.
;
; With no client ever seen there is nowhere to send: the buffer is dropped
; rather than aimed at connection 0, which under jnext is the guest's own
; outbound slot and is not open. That is what keeps a button NMI with no
; debugger attached from parking on a TX timeout.
; Changes:
;  AF, BC, DE, HL
;===========================================================================
transport_flush:
    ld a,(esp_conn_id)
    or a
    jr nz,.have_client
    ; Nobody has ever connected: drop it.
    xor a
    ld (esp_tx_len),a
    ret
.have_client:
    ld a,(esp_tx_len)
    or a
    ret z
    ; Flow through

;===========================================================================
; Sends the buffered bytes as one AT+CIPSEND on the connection the last +IPD
; arrived on, and clears the buffer.
; Must only be called with esp_tx_len != 0: AT+CIPSEND with a length of 0 is
; answered ERROR (jnext esp_at.cpp, begin_send).
; Changes:
;  AF, BC, DE, HL
;===========================================================================
esp_flush_chunk:
    ; "AT+CIPSEND=<id>,<len>\r\n"
    ld hl,esp_str_cipsend
    ld de,esp_cmd_buffer
    call esp_copy_string
    ld a,(esp_conn_id)
    call esp_put_decimal
    ld a,','
    ld (de),a
    inc de
    ld a,(esp_tx_len)
    call esp_put_decimal
    ld a,13
    ld (de),a
    inc de
    ld a,10
    ld (de),a
    inc de
    xor a
    ld (de),a

    ld hl,esp_cmd_buffer
    call esp_send_string

    ; The module answers "\r\nOK\r\n> " and only then takes the payload. Wait
    ; for the PROMPT, not for the OK: a refusal answers ERROR, which contains
    ; no '>' either, so this one wait covers accepted and refused alike.
    ld hl,esp_str_prompt
    call esp_wait_string
    jr c,.timeout

    ld a,(esp_tx_len)
    ld b,a
    ld hl,esp_tx_buffer
.send_payload:
    ld a,(hl)
    push bc, hl
    call esp_send_raw
    pop hl, bc
    inc hl
    djnz .send_payload

    ; The buffer is spent whatever the module says next.
    xor a
    ld (esp_tx_len),a

    ld hl,esp_str_send_ok
    call esp_wait_string
    ret nc

.timeout:
    xor a
    ld (esp_tx_len),a
    nop ; LOGPOINT esp_flush_chunk: ERROR=TIMEOUT
    jp tx_timeout   ; ASSERTION


;===========================================================================
; Brings the UART up and the ESP into server mode.
;
; Called once, from main_bank_entry, before the UI is drawn. Each step gates
; the next, and CIPSERVER is REFUSED without CIPMUX, so a single "the module
; answered OK" chain is a real check rather than a formality.
;
; A failure is remembered rather than reported here: main_bank_entry falls
; straight into drain_main, which zeroes last_error. transport_activate puts it
; back — see there.
; Returns:
;  -
; Changes:
;  A, BC, DE, HL
;===========================================================================
transport_init:
    call esp_uart_init

    ; A real ESP-AT boots with echo ON; jnext's power-on default is off. This
    ; line is here for the hardware, not the emulator.
    ld a,ESP_INIT_PASSES
    ld (esp_rx_retries),a

    ld hl,esp_cmd_ate0
    call esp_command_ok
    jr c,.failed
    ld hl,esp_cmd_at
    call esp_command_ok
    jr c,.failed

    ; Multiplexed mode. REQUIRED BEFORE CIPSERVER — AT+CIPSERVER=1 answers
    ; ERROR without it, and AT+CIPMUX=1 in turn forbids AT+CIPMODE=1, which is
    ; why there is no transparent byte pipe to fall back on.
    ld hl,esp_cmd_cipmux
    call esp_command_ok
    jr c,.failed

    ld hl,esp_cmd_cipserver
    call esp_command_ok
    jr c,.failed

    xor a
.failed:
    ; A = 0 on success, or the RX timeout error from esp_command_ok's caller.
    ld (esp_init_error),a
    ld a,1
    ld (esp_rx_retries),a
    ret


;===========================================================================
; Sends a command and waits for the module to answer "OK".
; Parameter:
;  HL = NUL-terminated command, CRLF included.
; Returns:
;  NC on OK; on failure CY and A = ERROR_RX_TIMEOUT.
; Changes:
;  AF, BC, DE, HL
;===========================================================================
esp_command_ok:
    call esp_send_string
    ld hl,esp_str_ok
    call esp_wait_string
    ret nc
    ld a,ERROR_RX_TIMEOUT
    scf
    ret


;===========================================================================
; UART bring-up: 8N1, the ESP uart selected, prescaler for ESP_BAUDRATE.
;
; The prescaler is Fsys/baud (ports.txt, 0x143B) and Fsys depends on the video
; timing in NR 0x11, so the divisor is looked up rather than assumed. It goes
; out in two 7-bit halves, bit 7 selecting which; the three further MSBs ride
; along with the uart selection and are zero for every entry in the table.
; Changes:
;  A, BC, DE, HL
;===========================================================================
esp_uart_init:
    ; 8 bits, one stop bit, no parity, no flow control
    ld bc,UART_FRAME
    ld a,00011000b
    out (c),a

    ; bit 6 = 0: the ESP uart. bit 4 = 1: bits 2:0 are being written, and they
    ; are 0 — every prescaler in the table fits in 14 bits.
    ld bc,UART_SELECT
    ld a,00010000b
    out (c),a

    ; Fsys index = NR 0x11 bits 2:0
    ld a,REG_VIDEO_TIMING
    call read_tbblue_reg
    and 0111b

    ; two bytes per entry
    add a,a
    ld hl,esp_prescaler_table
    ld d,0
    ld e,a
    add hl,de
    ld e,(hl)
    inc hl
    ld d,(hl)               ; DE = prescaler

    ld bc,UART_RX
    ld a,e
    and 0x7F                ; bit 7 = 0: the low 7 bits
    out (c),a

    ; The upper 7 bits are prescaler >> 7, which is the high byte of
    ; prescaler << 1, with bit 7 set to say which half this is.
    ex de,hl
    add hl,hl
    ld a,h
    and 0x7F
    or 0x80
    out (c),a
    ret


;===========================================================================
; The debugger is taking over; make the link usable.
;
; UART0's RX comes from the ESP-01 pin whenever joy IO mode is off
; (zxnext.vhd:3340: `uart0_rx <= joy_uart_rx when joy_iomode_uart_en = '1' ...
; else i_UART0_RX`; :3536 for the enable). That is the power-on state, but a
; debuggee that used the joy-port serial itself would have moved it, and the
; link would then be silently dead. Writing 0 here removes that dependency.
;
; It is also where a bring-up failure is put back into last_error: transport_init
; runs before main_bank_entry falls into drain_main, which zeroes it. Guarded on
; esp_init_error so the breakpoint and NMI paths, which also call this, cannot
; overwrite a real error with a stale one.
; Changes:
;  AF
;===========================================================================
transport_activate:
    nextreg REG_JOYSTICK_IO_MODE,0
    ld a,(esp_init_error)
    or a
    ret z
    ld (last_error),a
    ret
