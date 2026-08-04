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
; 3. THE CONNECTION ID IS OPAQUE, AND NO VALUE OF IT IS RESERVED. It comes out
;    of the `+IPD` header, goes straight back onto the `AT+CIPSEND`, and nothing
;    here assumes anything about its range, its first value or how the module
;    allocates it.
;
;    THIS COST A NIGHT ON REAL HARDWARE, so it is worth stating what went wrong.
;    An earlier version of this file used `esp_conn_id == 0` as the marker for
;    "there is nobody to send to", on the strength of MEMORY.md's note that
;    jnext reserves slot 0 for the guest's own outbound AT+CIPSTART and numbers
;    inbound connections from 1. That note also said, in as many words, that
;    jnext's numbering is a JNEXT DESIGN CHOICE and must not be promoted to a
;    hardware fact without measuring it. It was measured: **real ESP-AT firmware
;    assigns link id 0 to the first inbound connection.** So on a real Next the
;    listener came up, the client connected, commands were parsed and executed —
;    and every single reply was discarded, because a perfectly valid id read as
;    "no client". No error, no data; every DZRP check timed out.
;
;    The defect was the reservation itself, not the value chosen. So there is no
;    replacement magic id: "which client" (esp_conn_id) and "is there one"
;    (esp_conn_valid) are now two variables. The id holds whatever arrived and
;    means nothing else; the flag is the state. They are written together in
;    esp_sync_ipd and must stay that way.
;
;    The flag starts clear, an inbound `+IPD` sets it, and an `AT+CIPSEND`
;    answered ERROR — which is how the module says the peer has gone — clears it
;    again. **All three matter.** Without the last one the id of a closed
;    connection survived for the rest of the power-on session, and every later
;    unprompted NTF_PAUSE (the M1 button, or a leftover RST 0 through
;    breakpoints.asm) parked on a TX timeout and was discarded. See .no_client
;    in esp_flush_chunk, and bench check W2.
;
;    NOTE FOR ANYONE ADDING A TEST: jnext cannot reproduce this bug, because it
;    never hands out id 0. `make test-dzrp-stub` was green before the fix and is
;    green after it. Only real hardware can tell.
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
; 6. IT DRAWS ITS OWN SCREEN. show_ui is the third thing the assembly-time
;    switch selects, after the byte stream and the lifecycle, and the reason is
;    the same one that made a shared transport impossible: a joy-port selector
;    and a cable baud rate are meaningless here, and the address a client has to
;    dial is meaningless in UART mode. Until this existed the WiFi ROM drew
;    upstream's screen — a baud rate the hardware was NOT running at, and a
;    selector for a port it never touches — and the two builds were
;    indistinguishable on a real machine — which is the same hardware session
;    point 3 cost a night to. See esp_query_address and esp_show_status, and
;    MEMORY.md 2026-08-05.
;
;---------------------------------------------------------------------------
; What this file does NOT do, deliberately
;---------------------------------------------------------------------------
;
; * It never configures WiFi. No AT+CWJAP, no SSID, no passphrase — see
;   doc/WIFI-SETUP.md for the three independent reasons. The Next must already
;   be associated. It only ever ASKS (AT+CIFSR) and reports what it is told.
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

; ESP_BAUDRATE and ESP_SERVER_PORT are in constants.asm, beside BAUDRATE — the
; UI has to name both and is assembled before this file. See there.

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

; The longest dotted quad, "255.255.255.255". Bounds the copy out of AT+CIFSR's
; answer, so a stream that never produces the closing quote cannot run off the
; end of the buffer.
;
; OVERRIDABLE ON PURPOSE, and it is the only way this boundary can be tested.
; jnext's emulated module answers AT+CIFSR with 192.168.1.50 and nothing can
; change that — `STA_IP` is a `static constexpr` in
; esp01/include/esp01/esp_at.h with no command-line option behind it. Twelve
; characters never reach a bound of fifteen, so every bench in this repository
; was green while an address of exactly fifteen was being refused. Lowering the
; bound to 12 makes jnext's own answer the maximum-length case and to 11 makes
; it the too-long case, which is what test/run-ip-boundary.sh does. The
; alternative was a host-side model of the loop, which would have tested a
; transcription of this code rather than this code.
 IFNDEF ESP_IP_MAX
ESP_IP_MAX:     equ 15
 ENDIF

; What the UI has to say about the link. Decided once, during bring-up, because
; show_ui is re-entered on every redraw and an AT round trip per redraw would
; buy nothing — the address cannot change while we hold the module.
ESP_LINK_OK:            equ 0   ; associated, listening, and the address is known
ESP_LINK_NO_ADDRESS:    equ 1   ; the module answered, but has no usable address
ESP_LINK_FAILED:        equ 2   ; the AT chain did not complete
; ESP_LINK_FAILED covers every way the chain can stop — silence, or a command
; refused — because from the screen's point of view they are one situation and
; have one first move. Splitting them would need the module to have said
; something to tell them apart, which in the silent case it has not.


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
esp_cmd_cifsr:      defb "AT+CIFSR",13,10,0

esp_str_ok:         defb "OK",13,10,0
esp_str_ipd:        defb "+IPD,",0
esp_str_error:      defb "ERROR",0
esp_str_send_ok:    defb "SEND OK",0
esp_str_cipsend:    defb "AT+CIPSEND=",0

; The anchor in AT+CIFSR's answer, opening quote included. ESP-AT reports one
; `+CIFSR:<what>,"<value>"` line per interface — the access point's address and
; MAC as well as the station's — so the station address is matched BY NAME
; rather than by taking the first quoted string it sees. (jnext emits only
; STAIP and STAMAC, which is the subset that would have let a looser match pass
; here and fail on hardware.)
esp_str_staip:      defb "+CIFSR:STAIP,",34,0

; Appended to the address to make the line a user can copy into launch.json.
esp_str_port:       defb ":"
    STRINGIFY ESP_SERVER_PORT
    defb 0
esp_str_port_end:
; Length including the NUL, which is what gets written after the address.
ESP_PORT_LEN:   equ esp_str_port_end - esp_str_port


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

; The connection the last +IPD arrived on, echoed back on AT+CIPSEND. Pure
; data: every value the module can hand out is an ordinary connection, 0
; included, and this byte is meaningless unless esp_conn_valid says otherwise.
; Its initial value is therefore arbitrary and is never read.
esp_conn_id:        defb 0

; Non-zero when esp_conn_id names a connection worth sending to. Separate from
; the id ON PURPOSE — folding "no client" into an id value is the bug that made
; the debugger unusable on real hardware, where the first client gets id 0. See
; point 3 in the header.
esp_conn_valid:     defb 0

; Outer passes of the RX poll; raised for bring-up, one for the rest.
esp_rx_retries:     defb 1
esp_rx_pass:        defb 1

; Set if the AT chain failed, so transport_activate can put it back into
; last_error after drain_main has cleared it. See transport_activate.
esp_init_error:     defb 0

; Which of the three status blocks below show_ui draws. NO_MODULE is the state
; before transport_init has run, so a UI drawn without a bring-up says "the
; module did not answer" rather than claiming an address it never asked for.
esp_link_state:     defb ESP_LINK_FAILED

;---------------------------------------------------------------------------
; The UI half of the transport interface (MEMORY.md 2026-08-04).
;
; Two lines at rows 6 and 7 — exactly where UART mode draws its joy-port
; selection, and the only part of this screen composed at run time. Composed,
; because the address comes from the ESP and is not known at assembly time.
;
; All three alternatives are TWO lines, so a failure replaces the whole block
; rather than leaving "Connect at" standing over a blank. The half-built line
; is the failure this must not produce.
;---------------------------------------------------------------------------
esp_text_connect:
    defb AT, 0, 6*8
    defb "Remote debugger active."
    defb AT, 0, 7*8
    ; There is no room for the colon MEMORY.md's sketch put after "at", and the
    ; ASSERTs below are why: this prefix plus the longest address plus the port
    ; already ends exactly at column 32.
esp_connect_prefix:
    defb "Connect at "
esp_connect_address:
    ; "<address>:<port>" + NUL, written by esp_query_address.
    defs 24, 0
esp_connect_address_end:

; The two bounds this line has to respect, checked by the assembler rather than
; by hand — the by-hand version of the first one is exactly what shipped an
; off-by-one in the loop that fills it.
;
; 1. The buffer holds the longest address, the port and its NUL.
    ASSERT esp_connect_address_end - esp_connect_address >= ESP_IP_MAX + ESP_PORT_LEN
; 2. The whole line fits the 32-column screen. The NUL is not drawn, hence the
;    -1; nothing follows it on that row, so print_string returns at the NUL and
;    the 32-column case never takes the wrap at all.
    ASSERT (esp_connect_address - esp_connect_prefix) + ESP_IP_MAX + ESP_PORT_LEN - 1 <= 32

esp_text_no_address:
    defb AT, 0, 6*8
    defb "No WiFi address. Set the Next"
    defb AT, 0, 7*8
    defb "up first: run wifi2.bas", 0

esp_text_failed:
    defb AT, 0, 6*8
    defb "ESP-01 setup failed. Check it"
    defb AT, 0, 7*8
    defb "is fitted and enabled.", 0

; Indexed by esp_link_state, which esp_show_status does not range-check — so
; the table must have an entry for every state, and the assembler says so
; rather than a reader counting them.
esp_status_text_table:
    defw esp_text_connect
    defw esp_text_no_address
    defw esp_text_failed
esp_status_text_table_end:
    ASSERT (esp_status_text_table_end - esp_status_text_table) / 2 == ESP_LINK_FAILED + 1

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
; Waits for AT+CIPSEND's answer, which is one of two things.
;
; TWO PATTERNS IN ONE PASS, and the second one is what stops a dead connection
; from becoming a wedged debugger. `AT+CIPSEND` on a cid that is not open is
; answered ERROR (jnext esp_at.cpp, begin_send), and that is not a module
; failure — it is the module saying the peer has gone. Waiting only for '>'
; would turn it into a TX timeout, which resets the call stack, discards the
; message and reports an error the user cannot act on.
;
; Matching is naive with a restart that re-tests the mismatching byte, as in
; esp_wait_string. '>' is tested first and separately because it is a single
; character; nothing the module sends between the command and its answer
; contains one (`<id>,CONNECT`, `<id>,CLOSED`, `SEND OK` and `+IPD` headers are
; the whole vocabulary).
;
; Returns:
;   NC              the '>' prompt: send the payload
;   CY and A = 0    ERROR: this connection is not usable
;   CY and A = 1    silence: the module is not answering at all
; Changes:
;   AF, BC, DE, HL
;===========================================================================
esp_wait_prompt:
    ld hl,esp_str_error
.next:
    call esp_try_read_raw
    jr c,.silent
    cp '>'
    jr z,.prompt
    cp (hl)
    jr nz,.mismatch
    inc hl
    ld a,(hl)
    or a
    jr nz,.next
    ; The whole of "ERROR" matched.
    xor a
    scf
    ret

.mismatch:
    ; Back to the start of the pattern, then re-test THIS byte against it.
    ld hl,esp_str_error
    cp (hl)
    jr nz,.next
    inc hl
    jr .next

.prompt:
    or a                    ; A is '>', so this only clears the carry
    ret

.silent:
    ld a,1
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
;  NC and esp_conn_id / esp_conn_valid / esp_rx_remaining set, or CY on timeout
;  / a malformed header.
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
    ; The id and its validity are set together, and this is the only place that
    ; sets either. Whatever the header said is a usable connection — 0 is not
    ; special, and neither is anything else.
    ld a,1
    ld (esp_conn_valid),a

    ; <len>, terminated by the colon
    ld c,':'
    call esp_read_decimal
    ret c
    ld (esp_rx_remaining),hl
    or a                    ; NC
    ret

.bad:
    ; A header this routine cannot parse is abandoned WHERE IT STANDS: the rest
    ; of it stays in the stream and the next scan will step over it looking for
    ; "+IPD,", which costs one timeout before things line up again. Left as is
    ; rather than resynchronised, because the only ways to get here are an id
    ; that does not fit a byte (ESP-AT ids are 0..4) or a non-digit inside the
    ; header — neither of which any module produces. It is the safety net for a
    ; corrupt stream, not a case with a caller.
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
;
; THE COST IS LATENCY, AND IT DIVERGES FROM THE SERIAL TRANSPORT. Upstream's is
; an O(1) status-bit read that always returns at once. This one returns at once
; too when the wire is quiet or a payload is already owed, but an unsolicited
; line — `<id>,CONNECT` is the common one — makes it scan for a header that is
; not there and give up only on the RX timeout, ~100 ms at 28 MHz. So main_loop
; can stall for that long, once per such line. It is bounded, it costs nothing
; while idle, and the alternative (an incremental parser driven a byte at a time
; across calls) buys latency nobody has asked for yet. Worth knowing before
; anything is built on "this poll returns immediately", which is a statement
; about the SERIAL build.
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
; With no client there is nowhere to send, so the buffer is dropped rather than
; aimed at a connection that is not open — which is what keeps a button NMI with
; no debugger attached from parking on a TX timeout.
;
; The question asked here is esp_conn_valid, NOT the value of esp_conn_id: on
; real hardware the first client is id 0, so no id can answer it.
; Changes:
;  AF, BC, DE, HL
;===========================================================================
transport_flush:
    ld a,(esp_conn_valid)
    or a
    jr nz,.have_client
    ; No client: drop it.
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
; answered ERROR (jnext esp_at.cpp, begin_send). And only with esp_conn_valid
; set — esp_conn_id is read here without being questioned, because every value
; it can hold is a real connection. transport_flush is the only way in and it
; checks both; there is no `call esp_flush_chunk` anywhere.
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

    ; The module answers "\r\nOK\r\n> " and only then takes the payload — or it
    ; answers ERROR, which here means the connection is gone rather than the
    ; module being broken. The two are told apart, because treating the first
    ; as the second wedges the debugger; see esp_wait_prompt and .no_client.
    call esp_wait_prompt
    jr nc,.have_prompt
    or a
    jr nz,.timeout          ; A = 1: the module said nothing at all
    jr .no_client           ; A = 0: ERROR

.have_prompt:
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

.no_client:
    ; THE PEER HAS GONE, and forgetting the connection is the whole point.
    ; Without this the id of a connection that had closed stayed live for the
    ; rest of the power-on session, so every later unprompted send — an NTF_PAUSE
    ; from the M1 button, or from a leftover RST 0 — was aimed at a dead cid,
    ; waited for a '>' that could not come, and diverted to drain_main, which
    ; threw the notification away and painted "TX Timeout" on a machine with
    ; nothing wrong with it.
    ;
    ; Clearing the VALIDITY FLAG is what forgetting means here. esp_conn_id is
    ; left holding the dead id, deliberately: it is data, it is never read while
    ; the flag is clear, and writing some other value into it would be reserving
    ; an id again. That puts us back in the state before any client was seen,
    ; where transport_flush discards without asking (see there), so the NEXT such
    ; send costs nothing at all.
    ;
    ; The message itself is still lost, and that is correct: there is nobody to
    ; receive it. What is NOT covered is a client that has reconnected but not
    ; yet sent anything — esp_conn_id is only refreshed by an inbound +IPD, so
    ; an unprompted notification in that window still goes nowhere. Closing that
    ; means tracking `<id>,CONNECT` as well, which belongs with M3's reconnect
    ; work rather than here.
    xor a
    ld (esp_conn_valid),a
    ld (esp_tx_len),a
    ret


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
    jr c,.no_bringup
    ld hl,esp_cmd_at
    call esp_command_ok
    jr c,.no_bringup

    ; Multiplexed mode. REQUIRED BEFORE CIPSERVER — AT+CIPSERVER=1 answers
    ; ERROR without it, and AT+CIPMUX=1 in turn forbids AT+CIPMODE=1, which is
    ; why there is no transparent byte pipe to fall back on.
    ld hl,esp_cmd_cipmux
    call esp_command_ok
    jr c,.no_bringup

    ld hl,esp_cmd_cipserver
    call esp_command_ok
    jr c,.no_bringup

    ; The address, for the UI. Asked for HERE rather than from show_ui because
    ; show_ui is re-entered on every redraw — the "B" key, CMD_CLOSE, an error
    ; report — and an AT round trip per redraw would be paid for an answer that
    ; cannot have changed. It is also the last step on purpose: it is the only
    ; one whose failure still leaves a working listener.
    call esp_query_address
    ld a,(esp_link_state)
    or a
    jr nz,.no_address

    xor a
    jr .done

.no_address:
    ; The listener is up and nobody can be told where to find it, which the user
    ; has to act on — so it goes in the error area as well as the status block.
    ; See doc/WIFI-SETUP.md.
    ld a,ERROR_NO_WIFI_ADDRESS
    jr .done

.no_bringup:
    ; A carries esp_command_ok's error and must survive to .done, so the state
    ; is written through HL rather than through A.
    ld hl,esp_link_state
    ld (hl),ESP_LINK_FAILED
.done:
    ld (esp_init_error),a
    ld a,1
    ld (esp_rx_retries),a
    ret


;===========================================================================
; Asks the module for the station's address and composes the connect line.
;
; AT+CIFSR answers with one `+CIFSR:<what>,"<value>"` line per interface and
; then OK. Only STAIP is wanted, and it is matched by name — see esp_str_staip.
;
; A failure here is NOT a bring-up failure: the listener is already up, and the
; only thing lost is being able to tell the user where it is. So this never
; jumps to the timeout handler; it returns with esp_link_state saying so.
; Returns:
;  esp_link_state = ESP_LINK_OK and esp_connect_address composed, or
;  ESP_LINK_NO_ADDRESS.
; Changes:
;  AF, BC, DE, HL
;===========================================================================
esp_query_address:
    ld a,ESP_LINK_NO_ADDRESS
    ld (esp_link_state),a

    ld hl,esp_cmd_cifsr
    call esp_send_string
    ld hl,esp_str_staip
    call esp_wait_string
    ret c

    ; Copy the address up to the closing quote.
    ;
    ; B COUNTS WHAT HAS BEEN STORED, and the bound is tested BEFORE storing —
    ; it is not a DJNZ pass count. That distinction is the whole of a bug this
    ; routine shipped with: bounding the passes meant the pass that would have
    ; read the closing quote after a maximum-length address had already been
    ; spent on the last character, so an address of exactly ESP_IP_MAX
    ; characters was refused as "too long". 192.168.100.136 is 15 characters
    ; and is an ordinary private address, so this was not an edge case.
    ;
    ; No test here could have caught it: jnext's module always answers
    ; 192.168.1.50 (esp01/include/esp01/esp_at.h, a constexpr — there is no
    ; option for it), which is 12 characters and never reaches the bound. That
    ; is what ESP_IP_MAX being overridable is for; see its definition and
    ; test/run-ip-boundary.sh.
    ld de,esp_connect_address
    ld b,0                      ; characters stored so far
.char:
    push bc, de
    call esp_try_read_raw
    pop de, bc
    ret c
    cp 34                       ; the closing quote ends the address
    jr z,.end_of_address
    ; Not the quote, so it has to go in the buffer — and if the buffer is
    ; already full the address is longer than any address can be.
    ld c,a                      ; esp_try_read_raw's byte, kept out of A's way
    ld a,b
    cp ESP_IP_MAX
    ret nc
    ld a,c
    ld (de),a
    inc de
    inc b
    jr .char

.end_of_address:
    ; Nothing stored means the module reported an empty address.
    ld a,b
    or a
    ret z

    ; An unassociated module reports 0.0.0.0. The whole of 0.0.0.0/8 is "this
    ; network" and can never be a host address, so the first two characters
    ; settle it without a string compare.
    ld hl,esp_connect_address
    ld a,(hl)
    cp '0'
    jr nz,.usable
    inc hl
    ld a,(hl)
    cp '.'
    ret z

.usable:
    ; DE is just past the last character of the address.
    ld hl,esp_str_port
    call esp_copy_string
    xor a
    ld (de),a
    ld (esp_link_state),a       ; A is 0 = ESP_LINK_OK

    ; Swallow the rest of the answer — the STAMAC line and the OK — so a later
    ; scan does not have to step over it. A timeout here is not a failure: the
    ; address is already in hand, and main_bank_entry falls into drain_main,
    ; which discards anything still on the wire.
    ld hl,esp_str_ok
    jp esp_wait_string


;===========================================================================
; Draws WiFi mode's status block, where UART mode draws its joy-port selection.
; Called from show_ui; see the data above.
; Changes:
;  AF, BC, DE, HL
;===========================================================================
esp_show_status:
    ld hl,esp_status_text_table
    ld a,(esp_link_state)
    add a                       ; *2
    add hl,a
    ld de,(hl)
    jp text.ula.print_string


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
