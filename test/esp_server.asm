;===========================================================================
; esp_server.asm
;
; Roadmap M0(b): the ESP-01 brought up as a TCP *server*, so the framing the
; WiFi transport will use can be watched working before any of it is built
; into the debugger.
;
; This is NOT the transport. It is the proof that the path exists and that the
; `+IPD` parser is right, isolated from the stub — which is the whole reason
; plan §9 puts M0(b) before M1's WiFi half:
;
;   "Doing (a) first is deliberate: it isolates 'is the ESP path alive at all'
;    from 'is my +IPD parser right'."
;
; and plan §10 names `+IPD` framing as the risk whose failure "looks like a
; protocol bug".
;
; What it does, in order, each step gating the next:
;
;   ATE0                    echo off. jnext's power-on default is already off;
;                           real ESP-AT firmware boots with echo ON, so this
;                           line is here for the hardware, not the emulator.
;   AT                      the module answers at all
;   AT+CIPMUX=1             multiplexed mode. REQUIRED BEFORE CIPSERVER —
;                           AT+CIPSERVER=1 answers ERROR without it.
;   AT+CIPSERVER=1,11000    listen. Port 11000 is DeZog's `cspect` default and
;                           is what MEMORY.md pins for the real transport.
;   AT+CIFSR                the IP, which M1's connect-string UI needs and
;                           which is only knowable at run time.
;
; then forever: parse `+IPD,<id>,<len>:` and echo the payload straight back
; with `AT+CIPSEND=<id>,<len>`.
;
; THE ECHO IS THE ASSERTION, and it is a stronger one than it looks. The
; connection id is taken from the `+IPD` header and echoed back on CIPSEND. A
; parser that hardcoded 0 — the id the Espressif documentation leads you to
; expect — would address jnext's OUTBOUND slot, get ERROR, and send nothing:
; the bench would see a connection that accepts data and never answers.
; MEMORY.md 2026-08-04 records why: jnext reserves slot 0 for the guest's own
; AT+CIPSTART, so inbound ids start at 1 (esp_at.h simplification 8a). Whether
; real firmware numbers the same way is UNVERIFIED — which is exactly why the
; id is read rather than assumed.
;
; Progress is on the BORDER, because a hang has to be diagnosable from a
; screenshot. Each colour is set on the SUCCESS of a step, so a run stuck at
; colour N means step N+1 is what failed:
;
;   0 black    injected, nothing done yet
;   1 blue     UART up
;   2 red      ATE0 + AT answered OK — the module is alive
;   3 magenta  AT+CIPMUX=1 OK
;   4 green    AT+CIPSERVER=1,11000 OK — listening
;   5 cyan     AT+CIFSR OK — waiting for a client
;   6 yellow   a +IPD was parsed
;   7 white    the echo was sent and acknowledged
;
; Wire formats verified against jnext's own engine (src/esp01/src/esp_at.cpp),
; not against the datasheet, because the bench runs against jnext:
;   AT+CIPSEND accepted -> "\r\nOK\r\n> "   (trailing space)
;   payload complete    -> "\r\nSEND OK\r\n"
;   inbound data        -> "\r\n+IPD,<id>,<len>:" then <len> raw bytes
;===========================================================================

    DEVICE ZXSPECTRUMNEXT

;===========================================================================
; Border progress. A macro so a step costs two instructions and no stack.
; Defined first because sjasmplus needs a macro before its first use.
;===========================================================================
    MACRO STAGE colour?
    ld a,colour?
    out (BORDER),a
    ENDM

;===========================================================================
; Hardware
;===========================================================================

BORDER:                 equ 0xFE

TBBLUE_REGISTER_SELECT: equ 0x243B
TBBLUE_REGISTER_ACCESS: equ 0x253B
REG_VIDEO_TIMING:       equ 0x11    ; bits 2:0 select Fsys

; UART0. ports.txt:
;   0x133B  (R) status, (W) transmit
;   0x143B  (R) receive, (W) 14-bit prescaler in two 7-bit halves
;   0x153B  (W) bit 6 = 0 selects the ESP uart, bit 4 = 1 writes bits 2:0
;               (the prescaler's 3 most significant bits)
;   0x163B  (W) frame format
UART_TX:                equ 0x133B
UART_RX:                equ 0x143B
UART_SELECT:            equ 0x153B
UART_FRAME:             equ 0x163B

; 0x133B status bits
UART_RX_AVAIL:          equ 0       ; 1 = the Rx buffer contains bytes
UART_TX_FULL:           equ 1       ; 1 = the Tx buffer is full

;===========================================================================
; Configuration
;===========================================================================

; The ESP-01's power-on baud rate. NOT the 921600 of upstream's joy-port link:
; that rate is negotiable because both ends of a cable are ours to choose,
; whereas the ESP answers at 115200 until it is told otherwise. jnext models
; baud as timing only, so the emulator would accept any value here — which is
; precisely why it is pinned to the one real hardware needs. Raising it is
; M3's baud negotiation, and it has to start by talking at this rate.
BAUDRATE:               equ 115200

; MEMORY.md 2026-08-04: DeZog's `cspect` remote defaults to this port, so a
; launch.json that omits `port` still works. The ROM and Appendix B must agree.
SERVER_PORT:            equ 11000

; Largest echo payload. A spike bound, not a protocol one. Kept at 255 so the
; length always fits a byte and the payload loops can use DJNZ.
RX_BUFFER_SIZE:         equ 255

; How long to wait for a reply the module already owes us.
;
; The unit is one full 16-bit poll loop, and its wall-clock length depends on
; the CPU speed the fixture inherits — roughly 1.5 s at 3.5 MHz and 0.19 s at
; 28 MHz. 8 is therefore ~1.5 s at worst and ~12 s at best: long enough that a
; slow answer is never called a failure, bounded enough that a real failure
; reaches the border instead of hanging until the bench's own timeout.
;
; Deliberately NOT made exact by forcing a clock speed: the fixture would then
; be testing a machine configuration it had set for itself.
REPLY_TIMEOUT:          equ 8

;===========================================================================

    ORG 0x8000

start:
    di
    ld sp,stack_top

    STAGE 0
    call uart_init
    STAGE 1

    ; --- the module is alive ------------------------------------------------
    ld hl,cmd_ate0
    call send_command_expect_ok
    jp c,failed
    ld hl,cmd_at
    call send_command_expect_ok
    jp c,failed
    STAGE 2

    ; --- multiplexed mode, which CIPSERVER requires --------------------------
    ld hl,cmd_cipmux
    call send_command_expect_ok
    jp c,failed
    STAGE 3

    ; --- listen -------------------------------------------------------------
    ; The port is composed at run time with the same put_decimal that builds
    ; AT+CIPSEND, so SERVER_PORT is the only place it is written down.
    ld hl,cmd_cipserver
    ld de,cmd_buffer
    call copy_string
    ld hl,SERVER_PORT
    call put_decimal
    call put_crlf
    ld hl,cmd_buffer
    call send_command_expect_ok
    jp c,failed
    STAGE 4

    ; --- the address a client has to be told ---------------------------------
    ld hl,cmd_cifsr
    call send_command_expect_ok
    jp c,failed
    STAGE 5

;===========================================================================
; The echo loop. One `+IPD` in, one `AT+CIPSEND` out, forever.
;===========================================================================
echo_loop:
    call wait_for_ipd           ; blocks: a client may take as long as it likes
    jp c,failed
    STAGE 6
    call send_echo
    jp c,failed
    STAGE 7
    jr echo_loop


;===========================================================================
; Something the module owed us never arrived. Park with the border showing
; the last step that DID succeed, so the screenshot names the failure.
;===========================================================================
failed:
    jr failed


;===========================================================================
; UART bring-up: 8N1, the ESP uart selected, prescaler for BAUDRATE.
;
; The prescaler is Fsys/baud (ports.txt, 0x143B) and Fsys depends on the video
; timing in NR 0x11, so the divisor is looked up rather than assumed. It goes
; out in two 7-bit halves, bit 7 selecting which; the three further MSBs ride
; along with the uart selection and are zero for every entry in the table.
;
; Changes: AF, BC, DE, HL
;===========================================================================
uart_init:
    ; 8 bits, one stop bit, no parity, no flow control
    ld bc,UART_FRAME
    ld a,00011000b
    out (c),a

    ; bit 6 = 0: the ESP uart, not the pi one. bit 4 = 1: bits 2:0 are being
    ; written, and they are 0 — every prescaler below fits in 14 bits.
    ld bc,UART_SELECT
    ld a,00010000b
    out (c),a

    ; Fsys index = NR 0x11 bits 2:0
    ld bc,TBBLUE_REGISTER_SELECT
    ld a,REG_VIDEO_TIMING
    out (c),a
    ld bc,TBBLUE_REGISTER_ACCESS
    in a,(c)
    and 00000111b

    ; two bytes per entry
    add a,a
    ld hl,prescaler_table
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
; Send one byte.
; In:      A = byte
; Changes: AF, BC
;===========================================================================
uart_send_byte:
    push af
    ld bc,UART_TX
.wait:
    in a,(c)
    bit UART_TX_FULL,a
    jr nz,.wait
    pop af
    out (c),a
    ret


;===========================================================================
; Read one byte, waiting up to REPLY_TIMEOUT for it.
; Out:     NC and A = byte, or CY on timeout
; Changes: AF, BC, DE
;===========================================================================
uart_read_byte:
    ld d,REPLY_TIMEOUT
.outer:
    ld bc,0
.inner:
    push bc
    ld bc,UART_TX
    in a,(c)
    bit UART_RX_AVAIL,a
    pop bc
    jr nz,.available
    dec bc
    ld a,b
    or c
    jr nz,.inner
    dec d
    jr nz,.outer
    scf                     ; timeout
    ret
.available:
    ld bc,UART_RX
    in a,(c)
    or a                    ; NC
    ret


;===========================================================================
; Read one byte, waiting for as long as it takes.
;
; Used only where there is nothing to time out ON: waiting for a client to
; connect is not a failure however long it lasts, and treating it as one would
; make the bench flaky rather than strict.
;
; Out:     A = byte
; Changes: AF, BC
;===========================================================================
uart_read_byte_blocking:
    ld bc,UART_TX
.wait:
    in a,(c)
    bit UART_RX_AVAIL,a
    jr z,.wait
    ld bc,UART_RX
    in a,(c)
    ret


;===========================================================================
; Send a NUL-terminated string.
; In:      HL = string
; Changes: AF, BC, HL
;===========================================================================
send_string:
    ld a,(hl)
    or a
    ret z
    call uart_send_byte
    inc hl
    jr send_string


;===========================================================================
; Send a command and wait for the module to answer "OK".
;
; Scanning for "OK" rather than comparing a whole reply is deliberate:
; AT+CIFSR answers with two +CIFSR: lines before its OK, and what matters here
; is that the command was ACCEPTED, not what it returned.
;
; In:      HL = NUL-terminated command, CRLF included
; Out:     NC on OK, CY on timeout
; Changes: AF, BC, DE, HL
;===========================================================================
send_command_expect_ok:
    call send_string
    ld hl,str_ok
    ; fall through


;===========================================================================
; Scan the incoming stream until a pattern is seen.
;
; Naive matching, with a restart that RE-TESTS the mismatching byte against
; the first pattern byte — dropping it instead would miss "OOK" against "OK".
; None of the patterns here has a repeated prefix, so nothing cleverer than
; that is needed.
;
; In:      HL = NUL-terminated pattern
; Out:     NC when matched, CY on timeout
; Changes: AF, BC, DE, HL
;===========================================================================
wait_for_string:
    push hl                 ; keep the pattern start for restarts
.next:
    ld a,(hl)
    or a
    jr z,.matched
    call uart_read_byte     ; A = the byte read; HL still points at the pattern
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
; wait_for_string, without the timeout. See uart_read_byte_blocking for why.
; In:      HL = NUL-terminated pattern
; Changes: AF, BC, HL
;===========================================================================
wait_for_string_blocking:
    push hl
.next:
    ld a,(hl)
    or a
    jr z,.matched
    call uart_read_byte_blocking
    cp (hl)
    jr nz,.mismatch
    inc hl
    jr .next
.mismatch:
    pop hl
    push hl
    cp (hl)
    jr nz,.next
    inc hl
    jr .next
.matched:
    pop hl
    ret


;===========================================================================
; Wait for `+IPD,<id>,<len>:` and read the payload that follows it.
;
; Out:     NC, ipd_id / ipd_len / rx_buffer filled; CY on timeout or on a
;          payload too long for the buffer
; Changes: AF, BC, DE, HL
;===========================================================================
wait_for_ipd:
    ; The header may be a long time coming — a client connects when it
    ; connects — so this scan does not time out. Once "+IPD," HAS been seen,
    ; the rest of the header is owed immediately, and those reads do.
    ld hl,str_ipd
    call wait_for_string_blocking

    ; <id>, terminated by the comma. Refuse anything that does not fit a byte
    ; rather than truncating it: this is a value read off the wire, and a
    ; silent narrowing here would send the echo to a different connection than
    ; the one that asked for it — the exact class of bug E4 exists to catch.
    ld c,','
    call read_decimal
    ret c
    ld a,h
    or a
    jr nz,.too_long
    ld a,l
    ld (ipd_id),a

    ; <len>, terminated by the colon
    ld c,':'
    call read_decimal
    ret c
    ld (ipd_len),hl

    ; Refuse rather than overrun. A spike that silently truncated would make
    ; the echo mismatch and send the bench hunting for a parser bug.
    ; RX_BUFFER_SIZE is 255, so "fits" is exactly "the high byte is zero".
    ld a,h
    or a
    jr nz,.too_long

    ; The payload is raw bytes, not a line: exactly <len> of them.
    ld b,l
    ld hl,rx_buffer
    inc b                   ; so that len = 0 reads nothing
    jr .count
.read_payload:
    push bc, hl
    call uart_read_byte
    pop hl, bc
    ret c
    ld (hl),a
    inc hl
.count:
    djnz .read_payload
    or a                    ; NC
    ret

.too_long:
    scf
    ret


;===========================================================================
; Read an unsigned decimal number terminated by a given byte.
; In:      C = the terminator
; Out:     NC and HL = value, or CY on timeout / a non-digit
; Changes: AF, BC, DE, HL
;===========================================================================
read_decimal:
    ld hl,0
.digit:
    push hl, bc
    call uart_read_byte
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
; Echo the payload back on the connection it arrived on.
;
; `AT+CIPSEND=<id>,<len>` — the id comes from ipd_id, never from a constant.
; Under jnext, slot 0 is the guest's outbound connection and is not open, so a
; hardcoded 0 answers ERROR and this routine times out waiting for '>'.
;
; Out:     NC on "SEND OK", CY on timeout
; Changes: AF, BC, DE, HL
;===========================================================================
send_echo:
    ld hl,str_cipsend
    ld de,cmd_buffer
    call copy_string
    ld a,(ipd_id)
    ld l,a
    ld h,0
    call put_decimal
    ld a,','
    ld (de),a
    inc de
    ld hl,(ipd_len)
    call put_decimal
    call put_crlf

    ld hl,cmd_buffer
    call send_string

    ; The module answers "\r\nOK\r\n> " and only then takes the payload. Wait
    ; for the PROMPT, not for the OK: a refusal answers ERROR, which contains
    ; no '>' either, so this one wait covers accepted and refused alike.
    ld hl,str_prompt
    call wait_for_string
    ret c

    ; Exactly ipd_len bytes, raw.
    ld hl,(ipd_len)
    ld b,l
    ld hl,rx_buffer
    inc b                   ; so that len = 0 sends nothing
    jr .count
.send_payload:
    ld a,(hl)
    push bc, hl
    call uart_send_byte
    pop hl, bc
    inc hl
.count:
    djnz .send_payload

    ld hl,str_send_ok
    jp wait_for_string


;===========================================================================
; Copy a NUL-terminated string, leaving DE after the last byte copied.
; In:      HL = source, DE = destination
; Changes: AF, DE, HL
;===========================================================================
copy_string:
    ld a,(hl)
    or a
    ret z
    ld (de),a
    inc hl
    inc de
    jr copy_string


;===========================================================================
; Terminate the command line being built at DE.
; In:      DE = destination
; Changes: AF, DE
;===========================================================================
put_crlf:
    ld a,13
    ld (de),a
    inc de
    ld a,10
    ld (de),a
    inc de
    xor a
    ld (de),a
    ret


;===========================================================================
; Write HL as unsigned decimal, no leading zeros, at DE.
; In:      HL = value, DE = destination
; Out:     DE after the last digit
; Changes: AF, BC, DE, HL
;===========================================================================
put_decimal:
    ; Reset per call. Leaving this set from a previous call is what would make
    ; the SECOND number on a line ("<id>,<len>") keep its leading zeros.
    xor a
    ld (.started),a

    ld bc,-10000
    call .digit
    ld bc,-1000
    call .digit
    ld bc,-100
    call .digit
    ld bc,-10
    call .digit
    ; The units digit is always emitted, so 0 prints as "0".
    ld a,l
    add a,'0'
    ld (de),a
    inc de
    ret

.digit:
    ld a,'0'-1
.loop:
    inc a
    add hl,bc               ; BC is negative; carry set while the result is >= 0
    jr c,.loop
    sbc hl,bc               ; one subtraction too many — carry is clear, so
                            ; this adds |BC| back
    cp '0'
    jr nz,.emit
    ; A zero digit is suppressed only while nothing has been emitted yet.
    ld a,(.started)
    or a
    ld a,'0'
    ret z
.emit:
    ld (de),a
    inc de
    ld a,1
    ld (.started),a
    ret

.started:
    defb 0


;===========================================================================
; Const data
;===========================================================================

cmd_ate0:       defb "ATE0",13,10,0
cmd_at:         defb "AT",13,10,0
cmd_cipmux:     defb "AT+CIPMUX=1",13,10,0
cmd_cipserver:  defb "AT+CIPSERVER=1,",0    ; port appended at run time
cmd_cifsr:      defb "AT+CIFSR",13,10,0

str_ok:         defb "OK",13,10,0
str_ipd:        defb "+IPD,",0
str_prompt:     defb "> ",0
str_send_ok:    defb "SEND OK",0
str_cipsend:    defb "AT+CIPSEND=",0

; Fsys/BAUDRATE for each of the eight video timings in NR 0x11 bits 2:0.
; The Fsys column is upstream's (transport_uart.asm's baudrate_table); only
; the divisor differs, and it is 14 bits wide here rather than 8, because
; 115200 is not representable in upstream's — its own comment says it needs
; 230400 or more.
prescaler_table:
    defw 28000000/BAUDRATE
    defw 28571429/BAUDRATE
    defw 29464286/BAUDRATE
    defw 30000000/BAUDRATE
    defw 31000000/BAUDRATE
    defw 32000000/BAUDRATE
    defw 33000000/BAUDRATE
    defw 27000000/BAUDRATE

;===========================================================================
; Variables
;===========================================================================

ipd_id:                 defb 0
ipd_len:                defw 0
cmd_buffer:             defs 32
rx_buffer:              defs RX_BUFFER_SIZE

                        defs 64
stack_top:

end:

    SAVEBIN ESP_SERVER_BIN, start, end-start
