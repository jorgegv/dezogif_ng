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
; 7. THE MODULE GETS LONGER TO ANSWER A SEND THAN TO SAY ANYTHING ELSE, and
;    those two budgets are deliberately not one number. Every read here goes
;    through esp_try_read_raw, whose patience is the variable esp_rx_retries.
;    One pass (~100 ms) is right for a SPECULATIVE read — main_loop's idle poll
;    asks "is the module saying anything?" many times a second and must not
;    stall — and it is wrong for the two reads where the module OWES an answer
;    to a command it has already been given: AT+CIPSEND's '>' prompt, and the
;    "SEND OK" that closes the chunk.
;
;    THIS ALSO COST A HARDWARE SESSION. With one budget for both, a real
;    ESP-01 that took longer than 100 ms over an AT+CIPSEND made the stub
;    abandon a send that was working: bench H3 failed three runs of three and
;    H5 truncated a 4097-byte loopback at 236 bytes — about one ESP_TX_CHUNK
;    delivered and then nothing — with "Last Error: TX Timeout" on the Next's
;    screen. Issue #11. jnext answers instantly, so every bench here was green
;    throughout, exactly as in point 3.
;
;    So esp_flush_chunk raises the budget around those two calls and lowers it
;    immediately after. Raising it globally would have been one line and would
;    have multiplied the idle poll's worst case by the same factor — see
;    transport_byte_available on why that poll can stall at all.
;
; 8. NO SCAN MAY DESTROY AN INBOUND FRAME, and one of them used to. Every wait
;    here skips what it is not looking for — that is what lets it step over the
;    module's unsolicited lines instead of desynchronising on them — and a
;    `+IPD` arriving mid-scan was skipped in exactly the same way, i.e. read off
;    the wire and thrown away. The client was answered by nothing at all.
;
;    THIS COST A THIRD HARDWARE SESSION, and unlike points 3 and 7 it also
;    reproduces here. Two windows, measured separately:
;
;      * AT+CIPSEND's '>' (esp_wait_prompt). Two commands queued back to back
;        put the second one's whole frame in the FIFO ahead of the prompt. In
;        jnext this fails 4 runs out of 4, and its esp01 log shows both headers
;        emitted and one answered — bench check W4.
;      * "SEND OK" (esp_wait_string). The module forwards the reply to the
;        client before it tells us the send finished, so a client that answers
;        at once lands inside the wait. Measured on a real Next as a 20-50 ms
;        window; invisible here, because jnext answers instantly. Hardware
;        bench H3.
;
;    So esp_read_scan captures the frame — header parsed, payload held — and
;    the scan carries on looking for its own pattern. esp_require_payload then
;    serves the held frame as the next command. The buffer is ESP_HOLD_MAX and
;    exactly one frame deep, which is the shape of the traffic: a frame is only
;    captured while we are answering the previous command.
;
;    WHAT IS NOT COVERED. A frame longer than the buffer, or a second one while
;    the first is still held, is read off the wire and dropped — losing the
;    command, as before, but leaving the stream framed, which the old code did
;    not. And a scan whose own pattern begins with '+' cannot capture: that is
;    esp_sync_ipd and the "+CIFSR:STAIP," in esp_query_address, so a client
;    connecting inside bring-up's one AT+CIFSR exchange can still lose its
;    first command.
;
; 9. A MESSAGE BELONGS TO ONE CONNECTION AND A COMMAND IS ASSEMBLED FROM ONE
;    CONNECTION'S FRAMES, and neither used to be true. Issue #13.
;
;    Three handlers send their response header and THEN read payload bytes —
;    cmd_get_tbblue_reg, cmd_set_breakpoints, cmd_restore_mem. If the command's
;    payload does not all arrive in one `+IPD`, those reads reach
;    esp_require_payload, which takes the next frame off the wire or out of the
;    hold and writes esp_conn_id on the way past. Two separate things then go
;    wrong, and one fix does not cover both:
;
;      * THE REPLY GOES TO WHOEVER SPOKE LAST. transport_flush is reached after
;        the reads, so the AT+CIPSEND carries the new id. Fixed by LATCHING:
;        TRANSPORT_MESSAGE_START snapshots the connection into esp_tx_conn_id /
;        esp_tx_conn_valid, and the flush uses the snapshot, so a response
;        cannot be redirected once its first byte has been written.
;      * THE PAYLOAD IS READ OUT OF SOMEBODY ELSE'S FRAME. The latch does
;        nothing for this — the correctly-addressed reply just carries the
;        wrong answer, and for cmd_set_breakpoints it is breakpoint addresses
;        built from two clients' bytes and then written into the debuggee as
;        RST 0. Fixed by OWNERSHIP: esp_cmd_id names the connection whose
;        command is being received, and esp_require_payload will not continue
;        it with a frame from anywhere else — see there.
;
;    NEITHER IS REACHABLE BY DeZog, which opens one connection and is strictly
;    request/response. It takes a second client and a command split across
;    frames, which is bench check W5.
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
; No preamble byte. See point 1 in the header: the 0xA5 preamble is required in
; UART mode and must be ABSENT in WiFi mode.
;
; What it does instead is LATCH THE CONNECTION this message is going to. See
; point 9 in the header for why a reply could otherwise be redirected between
; its first byte and its last.
;===========================================================================
    MACRO TRANSPORT_MESSAGE_START
    call esp_latch_tx
    ENDM


;===========================================================================
; TRANSPORT_END_MESSAGE — a complete message has been written.
;
; The serial transport writes bytes straight out and expands this to nothing.
; Here it is what turns the buffer into an AT+CIPSEND — and, since issue #13,
; also the one marker the transport has for "the debugger is idle", which is
; what releases the connection that owned the command just finished. See
; transport_end_message and point 9 in the header.
;===========================================================================
    MACRO TRANSPORT_END_MESSAGE
    call transport_end_message
    ENDM


;===========================================================================
; TRANSPORT_CLIENT_ATTACHED / TRANSPORT_CLIENT_DETACHED — CMD_INIT, CMD_CLOSE.
;
; The two moments a debug session can be observed from above the byte stream.
; Each records one in esp_client_state, which esp_show_status draws; the redraw
; itself is not done here, because both call sites already reach show_ui —
; cmd_init calls it, cmd_close leaves through `jp main`. That is what keeps the
; line off the per-command path: nothing here repaints anything.
;
; AF only, and it is free at both sites. See transport.asm for why these are
; macros and what they are allowed to claim.
;===========================================================================
    MACRO TRANSPORT_CLIENT_ATTACHED
    ld a,ESP_CLIENT_ATTACHED
    ld (esp_client_state),a
    ENDM

    MACRO TRANSPORT_CLIENT_DETACHED
    ld a,ESP_CLIENT_DETACHED
    ld (esp_client_state),a
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

; How much of an inbound frame met MID-SCAN can be held (issue #11, point 8 in
; the header). Every DZRP command that a second client can plausibly have in
; flight while we are answering the first fits: CMD_INIT is ~32 bytes here,
; CMD_CONTINUE 11, CMD_READ_MEM 5, and H3's loopbacks 30. What does not fit is
; a bulk write — CMD_WRITE_BANK pushes 8-16 KB — and that is the documented
; residual rather than an oversight: a buffer that could hold one is a buffer
; the size of the largest DZRP command, which is exactly the RAM cost this
; transport is built not to pay (see esp_sync_ipd).
;
; OVERRIDABLE, like ESP_IP_MAX and ESP_RX_WAIT, and for the identical reason:
; the "too long to hold" path cannot be reached by any bench that sends
; ordinary commands, so the only way to exercise it is to bring the bound down
; to meet the traffic.
 IFNDEF ESP_HOLD_MAX
ESP_HOLD_MAX:   equ 256
 ENDIF

; One pass of the RX poll below, in loop iterations. ~68 T-states each, so at
; 28 MHz (which is where the debugger runs — init_main_bank and enter_debugger
; both set RTM_28MHZ) 40000 is about 100 ms, matching the serial transport's
; per-byte timeout.
;
; OVERRIDABLE ON PURPOSE, for the same reason as ESP_IP_MAX below and with the
; same shape of justification. The failure this and ESP_TX_PASSES exist to
; prevent is "the module answered later than the budget allowed", and jnext
; answers at once — so no run here can reach the timeout path unless the budget
; is brought down to meet the emulator's own latency. Shrinking one pass to
; roughly the time jnext takes to put its first reply byte on the wire makes a
; single pass too short and several passes enough, which is the real shape of
; the hardware failure on a machine that can be re-run. See
; test/run-tx-patience.sh.
 IFNDEF ESP_RX_WAIT
ESP_RX_WAIT:    equ 40000
 ENDIF

; Passes of that poll during bring-up. The module owes an answer to every
; command in the chain, but a real ESP-01 is slower to first light than an
; emulated one, so the wait is generous exactly once and then dropped to one
; pass for the rest of the session.
ESP_INIT_PASSES:    equ 20

; Passes of that poll while the module owes an answer to an AT+CIPSEND — the
; '>' prompt, and the "SEND OK" that closes the chunk. See point 7 in the
; header for why this is not the same number as the idle poll's.
;
; THE VALUE IS A JUDGEMENT CALL AND IS LABELLED AS ONE. Nothing we trust
; documents a real ESP-01's AT+CIPSEND latency under load, and no bench here
; can establish it: jnext answers at once, so the timeout path is never taken
; in the emulator. What IS known from hardware is the negative — one pass
; (~100 ms) is too short, measured as issue #11's H3 and H5 failures.
;
; Ten passes is ~1 s. The reasoning, such as it is: an order of magnitude more
; than a budget hardware demonstrated to be insufficient; past a single
; retransmit inside the module's own TCP stack, whose minimum RTO is a few
; hundred ms; and still short enough that a genuinely dead module surfaces as
; an error within a second rather than reading as a hang. Bring-up's 20 passes
; would also have been defensible; this is deliberately the smaller of the two,
; because unlike bring-up this budget can be paid once per chunk.
;
; What it costs when the module answers SEND FAIL rather than SEND OK: that
; line never matches, so the wait runs to the end of the budget before
; reporting TX Timeout — 1 s instead of 100 ms. A real failure reported a
; second late is the right trade against a working send abandoned.
;
; OVERRIDABLE, and 1 is the interesting override: it makes these two waits
; behave exactly as they did before this scoping existed, so it is the control
; run for test/run-tx-patience.sh rather than a tuning knob.
 IFNDEF ESP_TX_PASSES
ESP_TX_PASSES:      equ 10
 ENDIF

; How long to wait for room in the TX FIFO. One byte at 115200 is ~87 us; this
; loop is ~24 T-states, so 10000 is ~8.5 ms at 28 MHz — two orders of magnitude
; of headroom over a single byte time, and still bounded.
;
; NOTE FOR ANYONE READING "TX Timeout" OFF THE SCREEN: this budget expiring and
; esp_flush_chunk's RX budget expiring both report ERROR_TX_TIMEOUT, so the
; screen alone does not tell them apart. They were told apart from the VHDL
; instead. This one can only expire if the transmitter stops draining the FIFO,
; and uart_tx.vhd:180 starts a frame on `i_Tx_en = '1' and (i_cts_n = '0' or
; i_frame(5) = '0')` — bit 5 of the frame register is the hardware-flow-control
; enable, esp_uart_init writes 00011000b, so CTS is ignored and the shifter is
; never held off. 8.5 ms is ~98 byte times at that rate. So the "TX Timeout"
; issue #11 saw was the module's silence, not the Next's own FIFO — which also
; makes the plan's open question 4 (is CTS/RTR populated?) irrelevant to this
; path, since nothing here consults it.
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

; How many consecutive transport faults bring the AT chain back up — issue #16,
; part C. drain_main never re-ran transport_init, so a module that had lost its
; listener, or its mind, stayed lost until somebody power-cycled the Next.
;
; FIVE, AND THE NUMBER MATTERS LESS THAN WHAT IS COUNTED. Only rxtx_error
; increments it: a read or a send that failed while the module OWED an answer.
; cmd_loop's idle wait expiring does NOT, and must not — it is indistinguishable
; from a client that is simply thinking (see TRANSPORT_WAIT_RX_SECONDS), and a
; recovery is not free: it retires the listener and puts it back, refusing
; connections in between, clears esp_conn_valid so anything half-built is
; dropped, and costs an AT chain. A successful chunk clears the count, so five
; means five faults with nothing having got through in between.
;
; It is a backstop and it is not a fix for issue #15. That machine's symptom was
; a module still accepting TCP and no longer forwarding anything, which produces
; no faults at all — nothing arrives to fail. What this covers is the family
; where the module answers badly rather than not at all.
 IFNDEF ESP_FAULT_LIMIT
ESP_FAULT_LIMIT:    equ 5
 ENDIF

; How many link ids esp_recover sweeps with AT+CIPCLOSE — issue #19. ESP-AT
; numbers connections 0-4 and jnext accepts exactly that range (esp_at.cpp,
; cmd_cipclose_id parses against MAX_CONNECTIONS-1); 5 is refused there on
; purpose, because real firmware reads it as "close every connection" and that
; is a promise the engine declines to make.
;
; THE SWEEP IS BLIND, AND THAT IS THE DESIGN RATHER THAN A SHORTCUT. This
; program does not know which ids are open: learning that means tracking the
; module's <id>,CONNECT / <id>,CLOSED lines, which is M3's reconnect work and a
; second pattern in the RX hot path. AT+CIPCLOSE=<id> on an id with nothing
; behind it is answered ERROR, which costs one line of RX and nothing else, so
; asking about all five is cheaper than knowing which one to ask about.
;
; It is also what keeps this NUMBERING-AGNOSTIC, which matters more here than
; the saving. jnext's inbound ids start at 1 because it reserves slot 0 for an
; outbound AT+CIPSTART the stub never sends; real firmware's first inbound
; connection IS 0. Encoding either was the bug that made every reply vanish on
; a real Next while every emulator check stayed green — see esp_conn_valid and
; ERRORS.md. Nothing here encodes which end of the range is real.
;
; OVERRIDABLE, AND 0 IS THE ONLY INTERESTING OVERRIDE: it assembles esp_recover
; exactly as it was before issue #19, sweeping nothing. That is the negative
; control for test/run-slot-recovery.sh, and it is the fifth seam of this shape
; here for the fourth time's reason — the behaviour a check must be shown red
; against has to be reachable by a build, or the red is a story about a scratch
; tree nobody can re-run. It is not a tuning knob: a value between 0 and the
; module's real ceiling would leave some slots leaking and some not, which is
; not a state anyone should ship.
 IFNDEF ESP_LINK_IDS
ESP_LINK_IDS:   equ 5
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

; What the UI has to say about the debug SESSION (issue #14). Set by
; TRANSPORT_CLIENT_ATTACHED / TRANSPORT_CLIENT_DETACHED, i.e. by CMD_INIT and
; CMD_CLOSE and by nothing else.
;
; THESE ARE EVENTS THAT HAPPENED, NOT A LIVE CONNECTION, AND THE WORDING BELOW
; IS PICKED SO THE SCREEN CANNOT CLAIM MORE THAN THAT. What this transport can
; see is frames, not connections: the id is refreshed by an inbound `+IPD` and a
; departed peer is discovered only when an AT+CIPSEND is answered ERROR. So
;
;   * a client that opens TCP and says nothing is invisible — ATTACHED is about
;     CMD_INIT, not about a socket;
;   * a client that vanishes without CMD_CLOSE leaves ATTACHED standing, which
;     is why that state's line says a session was OPENED rather than that one is
;     open. It states what was observed and stops there.
;
; Closing the second gap means reading the module's unsolicited `<id>,CONNECT`
; and `<id>,CLOSED` lines, which is the same tracking the "residual" note in
; esp_flush_chunk's .no_client defers to M3's reconnect work. Until that exists,
; saying less is the only honest option — a line reading "client connected" ten
; minutes after the client left is worse than no line at all.
ESP_CLIENT_NONE:        equ 0   ; no CMD_INIT since the debugger came up
ESP_CLIENT_ATTACHED:    equ 1   ; a CMD_INIT arrived, and no CMD_CLOSE since
ESP_CLIENT_DETACHED:    equ 2   ; a CMD_CLOSE arrived

; The row the session line is drawn on. Under the connect block at rows 6 and 7,
; which is where a reader looking for "has my session arrived" is already
; looking, and clear of the key list — WiFi mode's starts at row 11.
ESP_CLIENT_ROW:         equ 8


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
; Only esp_recover sends this. AT+CIPSERVER=1 is refused while a server is
; already up (jnext esp_at.cpp:648, and real ESP-AT does the same), so a
; re-init that skipped it would report a failure on a module that was working.
esp_cmd_cipserver_off:  defb "AT+CIPSERVER=0",13,10,0
; Only esp_recover sends this, once per link id, with the id and a CRLF built
; on after it in esp_cmd_buffer. See ESP_LINK_IDS for why every id is asked
; rather than only the ones this program believes are open.
esp_cmd_cipclose:       defb "AT+CIPCLOSE=",0
esp_cmd_cipclose_end:

esp_str_ok:         defb "OK",13,10,0
esp_str_ipd:        defb "+IPD,",0
esp_str_error:      defb "ERROR",0
; THE CRLF IS PART OF THE PATTERN, AND LEAVING IT OUT COULD SWALLOW A COMMAND.
; The module answers "\r\nSEND OK\r\n"; matching only the seven characters left
; the trailing CRLF in the RX FIFO, and cmd_loop's transport_wait_rx ends on ANY
; byte from the module — so it returned at once and receive_bytes asked for a
; command that was not there.
;
; WHAT HAPPENED NEXT DEPENDED ENTIRELY ON WHEN THE CLIENT SPOKE AGAIN, and that
; is the part a first write-up of this got wrong by calling it "after every
; response". esp_sync_ipd does not fail on seeing "\r\n": it keeps scanning for
; a full ESP_RX_WAIT pass, ~97 ms at 28 MHz. So:
;
;   * a command arriving INSIDE that scan is found by it and answered normally.
;     Nothing is lost and nothing is reported. This is the pipelined case, and
;     it is why the conformance suite never saw any of this.
;   * a command arriving AFTER the scan gives up but INSIDE the 100 ms
;     transport_drain that rx_timeout then runs is READ OFF THE WIRE AND
;     DISCARDED — the drain's whole job is to empty the FIFO. The client is
;     never answered and waits for ever.
;   * a command arriving after the drain has finished is answered, but the stub
;     has been through drain_main: "Last Error: RX Timeout" on a healthy
;     machine, prgm_state back to PRGM_IDLE, the backup fields re-initialised.
;
; MEASURED, on two ROMs differing only in this string, with a drain counter and
; ten CMD_INITs at a fixed gap (wall clock; headless jnext advances emulated
; time ~5.5x faster than real, so these are roughly a fifth of the stub's own
; budgets):
;
;   gap    without the CRLF          with it
;   0-20   10/10 answered, 1 drain   10/10, 0 drains
;   25-40  1/10 ANSWERED, 1 drain    10/10, 0 drains
;   60+    10/10 answered, 1 drain per command    10/10, 0 drains
;
; and a full 14-check conformance run — dozens of commands — cost 2 drains, not
; dozens, with C10/C11 green throughout. That is the reconciliation: the suite
; pipelines, so it lives in the first row.
;
; esp_str_ok already ends in CRLF, for the same reason. esp_str_error does not,
; and esp_wait_prompt's ERROR arm therefore leaves the same two bytes behind —
; noted rather than changed, because that arm is only reached when the peer has
; gone and the stub is on its way to idle anyway.
esp_str_send_ok:    defb "SEND OK",13,10,0
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

;---------------------------------------------------------------------------
; The held frame — issue #11, and point 8 in the header.
;
; A scan that discards what it is not looking for destroys an inbound command
; that arrives while it is running. These four hold the one frame such a scan
; may meet, so it can be served to the command layer afterwards instead.
;
; The states are:
;   esp_hold_len != 0                a frame is held and not yet started
;   esp_rx_from_hold != 0            the current chunk IS that frame, being read
;   both clear                       the buffer is free
; A capture is allowed only when both are clear, which is what stops a second
; frame overwriting one that is held or half-read.
;---------------------------------------------------------------------------
esp_hold_len:       defw 0
; The connection the held frame came from. NOT copied into esp_conn_id at
; capture time, deliberately: a capture can happen halfway through a response
; being flushed, and esp_conn_id names the connection THAT is being answered.
; The two are joined only when the frame is adopted — esp_require_payload.
esp_hold_id:        defb 0
esp_hold_ptr:       defw 0
esp_rx_from_hold:   defb 0
esp_hold_buf:       defs ESP_HOLD_MAX

; Set by whichever entry point of esp_wait_string is running: a scan looking
; for a line that starts with '+' cannot also capture one (esp_sync_ipd's own
; "+IPD," and esp_query_address's "+CIFSR:STAIP,"). Written at every entry,
; never inherited.
esp_scan_hold:      defb 0

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

;---------------------------------------------------------------------------
; Where the message BEING WRITTEN is going — issue #13, point 9 in the header.
;
; A snapshot of the pair above, taken by TRANSPORT_MESSAGE_START, i.e. before
; the first byte of any response or notification. esp_flush_chunk sends to this
; and never to the live pair, so a command that arrives while the response is
; still being assembled cannot redirect it. The live pair goes on tracking
; whatever is inbound, which is what it is for.
;---------------------------------------------------------------------------
esp_tx_conn_id:     defb 0
esp_tx_conn_valid:  defb 0

;---------------------------------------------------------------------------
; Which connection's command is being received — issue #13, point 9.
;
; A DZRP command may span several `+IPD` frames, and with two clients the next
; frame on the wire is not necessarily the next frame OF THIS COMMAND. These
; two say whose bytes may continue it:
;
;   esp_cmd_active == 0    the debugger is idle; the next frame, from any
;                          connection, starts a command and becomes its owner
;   esp_cmd_active != 0    esp_cmd_id owns the command being received, and only
;                          its frames may continue it
;
; Claimed in esp_require_payload, released by transport_end_message and by
; transport_drain — the three places the debugger goes idle or gives up. It is
; NOT released by transport_flush, which is also called mid-message whenever
; ESP_TX_CHUNK bytes have piled up.
;---------------------------------------------------------------------------
esp_cmd_id:         defb 0
esp_cmd_active:     defb 0

; Outer passes of the RX poll. One, except in the two windows where the module
; has been asked something and owes an answer: the whole of bring-up
; (ESP_INIT_PASSES) and each of esp_flush_chunk's two waits (ESP_TX_PASSES).
; Everything else reads speculatively and must not stall — see point 7 in the
; header. Whoever raises it lowers it again, and rxtx_error lowers it for the
; paths that leave without getting the chance.
esp_rx_retries:     defb 1
esp_rx_pass:        defb 1

; Set if the AT chain failed, so transport_activate can put it back into
; last_error after drain_main has cleared it. See transport_activate.
esp_init_error:     defb 0

; Consecutive transport faults since the last chunk the module acknowledged.
; When it reaches ESP_FAULT_LIMIT the AT chain is run again — issue #16, part C.
; Cleared by transport_init and by esp_flush_chunk's SEND OK, which together
; mean "the whole path from here to the peer worked".
esp_fault_count:    defb 0

; Non-zero while esp_recover is running. Its own AT chain reads and writes the
; module, so a fault inside it comes straight back to rxtx_error — and without
; this the recovery would start another recovery, for ever. transport_init
; zeroing the count is NOT enough on its own: it makes the very next fault the
; first of a new run, which is exactly what re-triggers a limit of one.
esp_recovering:     defb 0

; Which of the three status blocks below show_ui draws. NO_MODULE is the state
; before transport_init has run, so a UI drawn without a bring-up says "the
; module did not answer" rather than claiming an address it never asked for.
esp_link_state:     defb ESP_LINK_FAILED

; Which of the three SESSION lines show_ui draws (issue #14). Written only by
; TRANSPORT_CLIENT_ATTACHED / TRANSPORT_CLIENT_DETACHED.
;
; Its lifetime is deliberately the debugger's, not a command's: this whole block
; is part of the image mf_rom.asm's init_main_bank copies into MAIN_BANK, and
; that copy happens on the FIRST M1 press after power-on and on a Symbol Shift
; re-init, not on every press (mf_rom.asm:130-172 takes the magic-number path
; straight to mf_nmi_button_pressed). So breaking into a running debuggee with
; the button leaves the line saying what it said, which is correct — the session
; is still there — and a re-init resets it to NONE, which is also correct.
esp_client_state:   defb ESP_CLIENT_NONE

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
    defb "Remote debugger ACTIVE"
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


;---------------------------------------------------------------------------
; The session line (issue #14), one row under the block above.
;
; EACH OF THESE IS A PAST-TENSE STATEMENT ABOUT SOMETHING THAT WAS OBSERVED, and
; the phrasing is the substance of the change rather than decoration. See
; ESP_CLIENT_NONE and following for what this transport can and cannot see; the
; short version is that CMD_INIT and CMD_CLOSE are the only two events above the
; byte stream, so "a session was opened" is sayable and "a client is connected"
; is not. Naming the command that was seen is what makes the limit legible to
; whoever reads the screen: it is plainly a report of protocol traffic, not of a
; socket.
;
; A line per state, drawn in every link state including FAILED, where it is
; merely uninteresting rather than wrong. There is no blank alternative: a row
; that appears and disappears is the "screen with holes in it" the status block
; above already refuses to be.
;
; The 32-column bound is an ASSERT per string, not arithmetic in a comment. The
; longest of them is 27 characters today and the temptation with any of these is
; to spend the slack; ERRORS.md carries three entries about bounds nothing
; checked, one of them in the line directly above this one.
;---------------------------------------------------------------------------
esp_text_client_none:
    defb AT, 0, ESP_CLIENT_ROW*8
.text:
    defb "No debug session yet."
.end:
    defb 0
    ASSERT .end - .text <= 32

esp_text_client_attached:
    defb AT, 0, ESP_CLIENT_ROW*8
.text:
    defb "Session opened - CMD_INIT"
.end:
    defb 0
    ASSERT .end - .text <= 32

esp_text_client_detached:
    defb AT, 0, ESP_CLIENT_ROW*8
.text:
    defb "Session closed - CMD_CLOSE"
.end:
    defb 0
    ASSERT .end - .text <= 32

; Indexed by esp_client_state, which esp_show_status does not range-check —
; same rule as the table above, and the assembler counts rather than a reader.
esp_client_text_table:
    defw esp_text_client_none
    defw esp_text_client_attached
    defw esp_text_client_detached
esp_client_text_table_end:
    ASSERT (esp_client_text_table_end - esp_client_text_table) / 2 == ESP_CLIENT_DETACHED + 1

esp_tx_len:         defb 0
esp_tx_byte:        defb 0

; Set when something went wrong DURING a chunk that had already been announced.
; It is not reported where it happens, because reporting means leaving, and
; leaving is the one thing esp_flush_chunk may not do between announcing a
; length and writing it (issue #16, part B). So the fault is remembered, the
; transaction is completed, and the report comes afterwards.
esp_tx_fault:       defb 0

; The error code rxtx_error is carrying into drain_main. In memory rather than
; in A because the recovery it may run needs both A and a stack.
esp_fault_error:    defb 0
esp_tx_buffer:      defs ESP_TX_CHUNK
esp_cmd_buffer:     defs 24
esp_cmd_buffer_end:
; The longest line built here is esp_recover's, and this is an ASSERT rather
; than the sum in a comment that three earlier bounds in this project turned
; out to be (ERRORS.md). esp_put_decimal emits up to three digits whatever the
; caller knows about its value. Watched to fail: six characters added to the
; string above is exactly 24 and assembles, seven is 25 and goes red here.
    ASSERT (esp_cmd_cipclose_end - esp_cmd_cipclose - 1) + 3 + 2 + 1 <= esp_cmd_buffer_end - esp_cmd_buffer


;===========================================================================
; Raw byte I/O
;===========================================================================

;===========================================================================
; Writes one byte to the UART, waiting for room, and SAYS whether it got out.
;
; The bounded primitive. esp_send_raw below is the "a failure here is fatal"
; wrapper, and the payload loop in esp_flush_chunk is the one caller that must
; not use it: once a length has been announced, stopping in the middle of the
; payload is the one thing that cannot be allowed (issue #16, part B).
; Parameter:
;  A = the byte to write.
; Returns:
;  NC and A unchanged if it was written, CY and A unchanged if the FIFO stayed
;  full for the whole budget.
; Changes:
;  F, BC
;===========================================================================
esp_send_try:
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
    ; The FIFO never drained. The byte is NOT written — writing into a full
    ; FIFO loses it in hardware, so there is nothing to gain by trying.
    pop de, af
    scf
    ret
.ready:
    pop de, af
    out (c),a
    or a                    ; NC; A is the byte and survives
    ret


;===========================================================================
; Writes one byte to the UART. A failure does not return to the caller — it
; resets the call stack and re-enters the main loop, as everything else in this
; transport's error paths does.
; Parameter:
;  A = the byte to write.
; Returns:
;  A unchanged.
; Changes:
;  F, BC
;===========================================================================
esp_send_raw:
    call esp_send_try
    ret nc
    nop ; LOGPOINT esp_send_raw: ERROR=TIMEOUT
    jp tx_timeout   ; ASSERTION


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
    ; EVERY FAULT THAT REACHES HERE IS COUNTED, and after enough of them in a
    ; row the module is brought back up rather than left as it is — issue #16,
    ; part C. Only this label counts: a read or a send that failed while the
    ; module owed us an answer. cmd_loop's idle wait expiring goes to main_idle
    ; and never comes here, deliberately, because an idle client is not a fault
    ; and a recovery driven by one would close a healthy session's connection.
    ;
    ; The error code is put in memory rather than kept in A, because the
    ; recovery below needs a stack and A both, and because it may be replaced.
    ld (esp_fault_error),a

    ; THE RX BUDGET MUST NOT ESCAPE THROUGH HERE RAISED, and this is the one
    ; path on which it could. esp_flush_chunk pairs every esp_rx_budget_long
    ; with an esp_rx_budget_short and calls nothing in between that returns
    ; anywhere else — but esp_try_read_raw's overflow arm jumps straight to this
    ; label from INSIDE those waits, and transport_init's bring-up window has
    ; the same shape (esp_rx_retries is ESP_INIT_PASSES until .done, which an
    ; overflow never reaches). Either would otherwise leave main_loop's idle
    ; poll nursing a long budget for the rest of the power-on session, which is
    ; precisely the regression the scoping exists to avoid — reintroduced
    ; through the error path instead of the happy one.
    ;
    ; drain_main means "abandon this and go idle", and idle is exactly the state
    ; that wants the short budget, so 1 is the right value and not merely a
    ; restore.
    ld a,1
    ld (esp_rx_retries),a

    ld a,(esp_fault_count)
    inc a
    ld (esp_fault_count),a
    cp ESP_FAULT_LIMIT
    jr c,.report

    ; A fault raised BY the recovery does not start another one.
    ld a,(esp_recovering)
    or a
    jr nz,.report

    ; ENOUGH IN A ROW: BRING THE MODULE BACK UP. The stack is reset FIRST — this
    ; label is jumped to from any depth, and the recovery is the only thing here
    ; that needs a stack of its own. drain_main resets it a moment later anyway,
    ; so nothing below is being thrown away that was not already.
    ld sp,debug_stack.top
    call esp_recover
    ; What the screen says is the recovery, not the fault that triggered it —
    ; unless the recovery ITSELF failed, in which case transport_activate
    ; overwrites this from esp_init_error on the way through main. Both are what
    ; a user needs to see; neither is what the fifth timeout was.
    ld a,ERROR_ESP_REINIT
    ld (esp_fault_error),a

.report:
    ; Both ways out of a recovery reach here — its ordinary return above, and a
    ; fault inside its own AT chain, which jumps to this label and never goes
    ; back. So this is where the re-entry guard is released. See esp_recover.
    xor a
    ld (esp_recovering),a
    ld a,(esp_fault_error)
    jp drain_main


; Called if a UART TX timeout occurs.
tx_timeout: ; The transmit timeout handler
    ld a,ERROR_TX_TIMEOUT
    jr rxtx_error


;===========================================================================
; Brings the ESP back up after ESP_FAULT_LIMIT consecutive faults.
;
; THE LISTENER IS STOPPED FIRST, and that is not optional: AT+CIPSERVER=1 is
; answered ERROR while one is already running, so a re-init without this would
; make transport_init report a failure on a module that was fine and paint
; "ESP-01 setup failed" over a working listener.
;
; IT DOES NOT FREE ANY ESTABLISHED CONNECTION, AND AN EARLIER VERSION OF THIS
; COMMENT CLAIMED IT DID. `AT+CIPSERVER=0` retires the LISTENER and leaves live
; connections alone — jnext says so in as many words (esp_at.cpp:683,
; "Established connections are deliberately left alone: the guest asked to stop
; ACCEPTING"), and that is real ESP-AT behaviour rather than a jnext
; simplification: ESP-AT's own `AT+CIPSERVER=0,<close_all>` argument is
; **refused rather than ignored** (esp_at.cpp:665, test SRV-12) precisely so
; a caller cannot believe it asked for closure and silently not get it. jnext
; flags its deliberate deviations; there is no flag here. The `1,CLOSED` line
; that appears in N4's log is `note_peer_close` firing for the bench client
; hanging up its own socket, not this command.
;
; SO THE SLOTS ARE FREED HERE INSTEAD, EXPLICITLY — issue #19. The module has a
; small number of inbound slots (jnext: MAX_CONNECTIONS 5 less the reserved
; outbound slot 0, esp_at.h; a real ESP-01 measured at 5, 2026-08-06) and drops
; or strands any connection past them. Until this loop existed, nothing in this
; program ever freed one: a peer that wedged rather than closing kept its slot
; for the rest of the power-on session, and recovery after recovery could not
; reclaim it. Four or five such peers — which is what a user retrying a hang
; produces — and the module refuses every new client while this routine goes on
; reporting success. That is a hang with issue #15's exact outward signature.
;
; ISSUE #16 CLAIMED PART C "SUBSUMES THE STALE LINK SLOTS PROBLEM". IT DID NOT,
; and the gap is what this loop closes. It could not be written when #16 landed:
; freeing a multiplexed connection needs `AT+CIPCLOSE=<id>`, and jnext's
; AT+CIPCLOSE then took no argument and acted on the outbound slot only, so the
; code would have been unexecutable by every bench here — the trade this project
; refuses. jnext#211 shipped it (esp_at.cpp, cmd_cipclose_id, a separate table
; entry from the bare spelling), so the code below is exercised rather than
; reasoned about; see test/run-slot-recovery.sh.
;
; THE ORDER IS FORCED, and both halves of it. The listener is stopped BEFORE the
; sweep, so no client can take a slot between freeing it and the re-listen —
; between those two points there is no listener at all. And the sweep runs
; BEFORE transport_init, because that is what makes its AT+CIPSERVER=1 land on a
; module with room; running it afterwards would leave the first client after a
; recovery competing with the corpses.
;
; WHAT IT COSTS is one AT line and one drain per id, paid only on a recovery —
; which is already an AT chain at bring-up budgets — and a healthy client's
; connection, which is closed along with the wedged ones. That is deliberate:
; ESP_FAULT_LIMIT consecutive faults means nothing has got through in between,
; so a connection surviving that is not a session worth preserving.
;
; WHAT THE CLIENT DOES NEXT IS NOT ASSUMED, and an earlier version of this
; comment asserted it: it said "and DeZog reconnects", which is FALSE. DeZog
; 3.7.4 has no reconnect logic at all — no `reconnect` symbol anywhere in its
; bundle, and CSpectRemote's socket close handler only logs. So the session ends
; and the user starts another, which is what a power cycle cost before this and
; is now the price of one recovery. Distinguishing a healthy connection from a
; wedged one would need per-id state this program does not have (ESP_LINK_IDS).
;
; Changes:
;  A, BC, DE, HL
;===========================================================================
esp_recover:
    ld a,1
    ld (esp_recovering),a

    ld hl,esp_cmd_cipserver_off
    call esp_send_string
    ; Read the answer away without caring what it was: OK if a server was
    ; running, ERROR if not, and both are fine here. The drain also eats
    ; anything the module was still owed from a send that never completed.
    ;
    ; IT DOES NOT PRODUCE `<id>,CLOSED` LINES, and an earlier version of this
    ; comment said it did — the same retracted claim the header above corrects,
    ; left standing thirty lines below the correction. Stopping the listener
    ; leaves established connections alone; the `1,CLOSED` in N4's log was
    ; jnext's note_peer_close firing for the bench client hanging up its own
    ; socket. The `<id>,CLOSED` lines this routine really does produce are the
    ; sweep's, below, and they are drained there.
    call transport_drain

    ; Free every inbound slot, id by id (issue #19). Blind and numbering-
    ; agnostic on purpose: see ESP_LINK_IDS.
    ;
    ; The IF is the bench seam and not a runtime choice: ESP_LINK_IDS=0 leaves
    ; this out altogether, which is the pre-#19 routine. `ld b,0` would run the
    ; loop 256 times rather than none, so it cannot be left to djnz.
 IF ESP_LINK_IDS > 0
    ld b,ESP_LINK_IDS
.close_link:
    push bc
    ld a,b
    dec a                       ; B counts ESP_LINK_IDS..1, so ids run 4..0
    call esp_close_link
    pop bc
    djnz .close_link
 ENDIF

    ; NOW every connection the module had really is gone, which is what lets
    ; this line say so. Before the sweep it was a statement about a thing that
    ; had not happened — and with the seam at 0 it still is, which is exactly
    ; what that control run exists to show.
    xor a
    ld (esp_conn_valid),a
    ; esp_recovering is cleared by rxtx_error's .report, NOT here, because that
    ; is the one place BOTH ways out of this pass through: the ordinary return
    ; below, and a fault inside this chain that jumps to rxtx_error and never
    ; comes back. Clearing it here would leave that second way out with the flag
    ; set for the rest of the power-on session, and no recovery would ever run
    ; again.
    jp transport_init


;===========================================================================
; Closes one link id, and does not care whether there was anything to close.
;
; Parameter:
;  A = link id.
;
; The module answers "\r\n<id>,CLOSED\r\n\r\nOK\r\n" when it closed something,
; and "\r\nERROR\r\n" when that id had nothing behind it — jnext refuses that
; case deliberately rather than answering OK, "a guest told OK here would
; believe it had freed a slot that was never taken" (esp_at.cpp,
; cmd_cipclose_id), which is real firmware's answer too.
;
; BOTH ARE READ AWAY WITH A DRAIN RATHER THAN MATCHED, and that is the whole
; reason this is nine lines instead of a scan. The caller has no decision to
; make either way: an id that was already free is the expected case, not a
; fault. A wait for "OK" would sit out its entire budget on every free id — most
; of them, every time — and would then have to be told not to treat that as the
; failure it looks like. A drain also cannot destroy an inbound frame the way a
; scan can (issue #11), and there is nothing inbound to protect here anyway:
; this runs with no listener up and every connection about to be closed.
;
; The cost is one drain's quiet period per id. That is real, and it is paid only
; on a recovery, which already runs the whole AT chain at bring-up budgets.
; Changes:
;  AF, BC, DE, HL
;===========================================================================
esp_close_link:
    ; The id is parked in C because esp_copy_string destroys A, and read back
    ; before esp_put_decimal, which destroys BC.
    ld c,a
    ld hl,esp_cmd_cipclose
    ld de,esp_cmd_buffer
    call esp_copy_string
    ld a,c
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
    jp transport_drain


;===========================================================================
; The RX budget, raised and lowered around the two reads where the module owes
; an answer. See point 7 in the header and ESP_TX_PASSES.
;
; esp_rx_budget_short preserves A and the flags because its callers sit between
; a wait and the test of that wait's result; esp_rx_budget_long does not need
; to, because at both of its call sites A is dead.
; Changes:
;  AF (esp_rx_budget_long only)
;===========================================================================
esp_rx_budget_long:
    ld a,ESP_TX_PASSES
    ld (esp_rx_retries),a
    ret

esp_rx_budget_short:
    push af
    ld a,1
    ld (esp_rx_retries),a
    pop af
    ret


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
; Reads one byte FOR A SCAN, capturing an inbound frame instead of eating it.
;
; This is the whole of issue #11's fix. The scans in this file skip whatever
; they are not looking for, which is what lets them step over the module's
; unsolicited lines — and it is also what destroyed a `+IPD` that arrived while
; one of them was running. Measured in two places, both real:
;
;   * waiting for AT+CIPSEND's '>' — two commands queued back to back, and the
;     second one's whole frame sits in the FIFO ahead of the prompt. jnext
;     reproduces this 4 times out of 4, and its own log shows both +IPD headers
;     emitted and only one answered.
;   * waiting for SEND OK — the module forwards the reply to the client before
;     it tells us the send completed, so a client that answers at once lands
;     inside the wait. Hardware only: measured on a real Next as a 20-50 ms
;     window, invisible in jnext, which answers instantly.
;
; A '+' is the only thing that can start an inbound frame, and nothing else the
; module says while it owes us an answer begins with one (`SEND OK`, `ERROR`,
; `OK`, `<id>,CONNECT`, `<id>,CLOSED`, `busy`). So a '+' hands over to
; esp_capture_ipd and the scan then carries on looking for its own pattern.
;
; Returns:
;  NC and A = a byte that is not part of an inbound frame, or CY on timeout.
; Changes:
;  AF, BC, DE  (HL is preserved: both callers hold their pattern there)
;===========================================================================
esp_read_scan:
    call esp_try_read_raw
    ret c
    cp '+'
    jr z,.frame
    ; CARRY MUST BE CLEAR HERE. Both callers read it as "timed out", and `cp`
    ; sets it for every byte below '+' — which is most of a DZRP payload. `or a`
    ; clears it and leaves the byte alone.
    or a
    ret

.frame:
    ld a,(esp_scan_hold)
    or a                        ; also clears the carry for the return below
    jr nz,.capture
    ld a,'+'                    ; this scan is looking for a '+' line itself
    ret

.capture:
    push hl
    call esp_capture_ipd
    pop hl
    jr esp_read_scan


;===========================================================================
; Takes an inbound `+IPD,<id>,<len>:` frame off the wire and holds it, having
; already read the '+'.
;
; It is called from inside a wait, so it must ALWAYS come back — a frame it
; cannot hold is still read off the wire and dropped, because leaving half of
; one in the stream would desynchronise the scan that called us. That is
; already an improvement on what this replaced, where the scan consumed an
; unknown number of payload bytes and could match its pattern inside them.
;
; It does NOT touch esp_conn_id or esp_conn_valid; see esp_hold_id.
; Changes:
;  AF, BC, DE, HL
;===========================================================================
esp_capture_ipd:
    ; "IPD," has to follow. esp_str_ipd+1 IS that string — sharing it with the
    ; parser's own pattern is what stops the two drifting apart.
    ld hl,esp_str_ipd+1
.verify:
    ld a,(hl)
    or a
    jr z,.header
    push hl
    call esp_try_read_raw
    pop hl
    ret c
    cp (hl)
    ret nz                      ; some other `+` line: those bytes are gone
    inc hl
    jr .verify

.header:
    ld c,','
    call esp_read_decimal
    ret c
    ld a,h
    or a
    ret nz                      ; an id that does not fit a byte: not ours
    ld a,l
    push af                     ; the id, until the length is known
    ld c,':'
    call esp_read_decimal
    pop bc                      ; B = the id
    ret c
    ; Flow through


;===========================================================================
; Holds a frame whose header has already been read, or reads its payload away.
;
; Parameters:
;  B = the connection id, HL = the payload length, the payload still on the
;  wire.
;
; ALWAYS RETURNS. A frame it cannot hold — the buffer is busy, or the frame is
; longer than ESP_HOLD_MAX — is read off the wire and dropped: the command is
; lost, but the stream stays framed, where consuming an unknown number of bytes
; would leave the next scan matching its pattern inside somebody's payload.
;
; It does NOT touch esp_conn_id or esp_conn_valid; see esp_hold_id.
;
; TWO CALLERS, and the second is not a capture. esp_capture_ipd falls in here
; from inside a scan; esp_require_payload calls it to park a frame that belongs
; to a different connection from the command it is assembling (issue #13).
; Changes:
;  AF, BC, DE, HL
;===========================================================================
esp_hold_frame:
    ; Hold it only if the buffer is free AND big enough; otherwise read it away,
    ; which keeps the stream framed.
    ld a,(esp_rx_from_hold)
    or a
    jr nz,.drop
    ld de,(esp_hold_len)
    ld a,d
    or e
    jr nz,.drop
    ld de,ESP_HOLD_MAX
    push hl
    or a
    sbc hl,de                   ; len - ESP_HOLD_MAX
    pop hl
    jr z,.keep                  ; exactly full still fits
    jr c,.keep
.drop:
    ; Read the payload away. The command is lost — the same loss this used to
    ; have for every frame, now narrowed to one that is too big to hold or one
    ; arriving while another is still held.
    ld a,h
    or l
    ret z
    push hl
    call esp_try_read_raw
    pop hl
    ret c
    dec hl
    jr .drop

.keep:
    ld a,b
    ld (esp_hold_id),a
    ld (esp_hold_len),hl
    ld de,esp_hold_buf
.copy:
    ld a,h
    or l
    ret z
    push hl, de
    call esp_try_read_raw
    pop de, hl
    jr c,.truncated
    ld (de),a
    inc de
    dec hl
    jr .copy

.truncated:
    ; The module stopped mid-frame. What was read is not a command, so the hold
    ; goes back to empty rather than being served as one.
    ld hl,0
    ld (esp_hold_len),hl
    ret


;===========================================================================
; Reads the next byte of the held frame.
; Returns:
;  A = the byte.
; Changes:
;  AF  (HL is preserved: transport_read_byte's contract)
;===========================================================================
esp_hold_read_byte:
    push hl
    ld hl,(esp_hold_ptr)
    ld a,(hl)
    inc hl
    ld (esp_hold_ptr),hl
    pop hl
    ret


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
; TWO ENTRY POINTS, and which one a caller uses is not a matter of taste.
; esp_wait_string_hold captures an inbound frame met while scanning (issue #11,
; esp_read_scan); esp_wait_string eats it, as everything here used to.
;
; The rule is mechanical: **a scan whose own pattern starts with '+' cannot
; capture**, because the capture would swallow the very line it is looking for.
; That is esp_sync_ipd's "+IPD," and esp_query_address's "+CIFSR:STAIP,"" — and
; it is the residual this fix does not close: a client connecting during the
; one AT+CIFSR exchange of bring-up can still lose its first command. Every
; other scan here holds.
;
; Parameter:
;  HL = NUL-terminated pattern.
; Returns:
;  NC when matched, CY on timeout.
; Changes:
;  AF, BC, DE, HL
;===========================================================================
esp_wait_string_hold:
    ld a,1
    jr esp_wait_string.set
esp_wait_string:
    xor a
.set:
    ld (esp_scan_hold),a
    push hl                 ; keep the pattern start for restarts
.next:
    ld a,(hl)
    or a
    jr z,.matched
    call esp_read_scan      ; A = the byte read; HL still points at the pattern
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
    ; It captures: its only caller is esp_flush_chunk, and this is the window
    ; that loses a command when two arrive back to back — the one jnext
    ; reproduces. See esp_read_scan.
    ld a,1
    ld (esp_scan_hold),a
    ld hl,esp_str_error
.next:
    call esp_read_scan
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
    ; The current chunk is now the WIRE's, so the held-frame buffer is free
    ; again. It is cleared HERE rather than in esp_require_payload because this
    ; is the only routine that makes a wire chunk current, and it has two
    ; callers: transport_byte_available polls through it directly, and leaving
    ; that path out meant a spent hold stayed selected and the next command was
    ; read out of a buffer that had already been consumed. Measured, not
    ; reasoned: the frame arrived, nothing was sent, and the client timed out.
    xor a
    ld (esp_rx_from_hold),a
    ret                     ; NC, from the xor

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
; next +IPD header if the previous chunk is used up — and, since issue #13,
; making sure that chunk belongs to the command being received rather than to
; whoever spoke next. Does not return on failure — see esp_read_raw.
;
; It is also where a command's connection is CLAIMED: this is the one routine
; every payload byte passes through, and claiming at sync time instead would be
; inert, because main_loop's poll synchronises a frame BEFORE cmd_loop's
; TRANSPORT_END_MESSAGE releases the previous command.
; Changes:
;  AF, BC, DE, HL
;===========================================================================
esp_require_payload:
    ld hl,(esp_rx_remaining)
    ld a,h
    or l
    jr nz,.claim_if_idle        ; the current chunk still owes bytes

    ; ONE COMMAND, ONE CONNECTION — issue #13, point 9 in the header. If a
    ; command is already being received, only frames from ITS connection may
    ; continue it. Splicing another client's bytes into a half-read command is
    ; silent corruption: for cmd_set_breakpoints it is a breakpoint address
    ; assembled from two clients and then written into the debuggee as RST 0.
    ld a,(esp_cmd_active)
    or a
    jr z,.any                   ; idle: whoever speaks next starts a command

    ; A HELD FRAME COMES BEFORE ANYTHING STILL ON THE WIRE, because it arrived
    ; first — it was taken off the wire by a scan that would otherwise have
    ; destroyed it (esp_capture_ipd). But only if it is ours; if it is not, it
    ; STAYS HELD and the wire is asked instead, so it is still served, as the
    ; next command, once this one is finished.
    ld hl,(esp_hold_len)
    ld a,h
    or l
    jr z,.wire
    ld a,(esp_hold_id)
    ld hl,esp_cmd_id
    cp (hl)
    jr z,.adopt_held

.wire:
    call esp_next_wire_chunk
    ld a,(esp_conn_id)
    ld hl,esp_cmd_id
    cp (hl)
    ret z

    ; Somebody else's command, arriving mid-command. Park it if the hold buffer
    ; is free and drop it framed if not — esp_hold_frame decides — and then go
    ; on looking for our own continuation. Parking is what keeps the other
    ; client's command alive; the losses are esp_hold_frame's documented ones.
    ;
    ; esp_conn_id is left naming that frame until the next sync overwrites it.
    ; It is only ever read while a chunk is current, and after this there is
    ; none; the message being written is protected by the latch, not by it.
    ld a,(esp_conn_id)
    ld b,a
    ld hl,(esp_rx_remaining)
    ld de,0
    ld (esp_rx_remaining),de
    call esp_hold_frame
    jr .wire

.any:
    ld hl,(esp_hold_len)
    ld a,h
    or l
    jr nz,.adopt_held
    call esp_next_wire_chunk
    ; Flow through

.claim_if_idle:
    ; The first byte of a command fixes whose command it is, for as long as it
    ; takes to receive and answer. Released by transport_end_message.
    ld a,(esp_cmd_active)
    or a
    ret nz
    ld a,(esp_conn_id)
    ld (esp_cmd_id),a
    ld a,1
    ld (esp_cmd_active),a
    ret

.adopt_held:
    ; The hold's own length goes to zero here and esp_rx_from_hold takes over as
    ; "the buffer is busy", so a capture during the response to THIS command
    ; cannot overwrite what is still being read.
    ld hl,(esp_hold_len)
    ld (esp_rx_remaining),hl
    ld hl,0
    ld (esp_hold_len),hl
    ld hl,esp_hold_buf
    ld (esp_hold_ptr),hl
    ld a,(esp_hold_id)
    ld (esp_conn_id),a
    ld a,1
    ld (esp_conn_valid),a
    ld (esp_rx_from_hold),a
    jr .claim_if_idle


;===========================================================================
; Synchronises to the next `+IPD` on the wire and makes it the current chunk.
; Does not return on failure — see esp_read_raw.
; Changes:
;  AF, BC, DE, HL
;===========================================================================
esp_next_wire_chunk:
    ; esp_sync_ipd is what releases the hold buffer, because it is also
    ; reachable from transport_byte_available.
    call esp_sync_ipd
    jr c,.timeout
    ; A zero-length chunk would loop the caller here forever. jnext never frames
    ; one ("the datagram is dropped rather than framed as an empty +IPD"), so
    ; this is a guard, not a case.
    ld hl,(esp_rx_remaining)
    ld a,h
    or l
    ret nz
.timeout:
    nop ; LOGPOINT esp_next_wire_chunk: ERROR=TIMEOUT
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
    ; A held frame is a fragment too. A drain means "abandon this and go idle",
    ; and serving a command captured before whatever went wrong would put the
    ; two ends back out of step in a new way.
    ld (esp_hold_len),a
    ld (esp_hold_len+1),a
    ld (esp_rx_from_hold),a
    ; And with the half-received command abandoned, nobody owns the next one:
    ; idle is exactly the state esp_cmd_active == 0 describes. Leaving it set
    ; would make the next client's first frame look like a foreign continuation
    ; of a command that no longer exists.
    ld (esp_cmd_active),a
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
;
; IT IS BOUNDED, and it did not used to be — the only wait in either transport
; that was not (issue #16, part A). On expiry it goes back to main_idle, NOT to
; rx_timeout and not to anything that reports: this wait is the debugger's idle
; state once a client has attached, so expiry means "nobody has said anything
; for a while", which is not a fault. TRANSPORT_WAIT_RX_SECONDS in constants.asm
; carries the whole argument, including why drain_main would have been the wrong
; destination and why leaving here loses nothing.
;
; DO NOT READ IT AS A FIX FOR ISSUE #15. A real Next, build 000B, was driven at
; four candidate triggers on 2026-08-05 — a client dying mid-command, a client
; that stops reading mid-response, connection churn, and an RST landing while
; the stub was blocked mid-flush — and none of them wedged it. The first of
; those is precisely this loop with five payload bytes owed and the peer gone,
; and the next connection was answered in 4 ms: the loop also ends on ANY byte
; from the module, and a new connection makes the module speak. So an unbounded
; wait here is survivable in practice, and what this change buys is that the
; debugger returns to a loop where the border moves and the keyboard answers,
; not a rescue from a state anybody has reproduced.
;
; The no-CALL/no-PUSH rule is not in the way: BC and DE are untouched between
; the two layer-2 writes either side of the loop, so the countdown lives in
; registers and needs neither the stack nor a memory cell.
; Changes:
;   A, BC, DE
;===========================================================================

 IF TRANSPORT_WAIT_RX_SECONDS
; 155 T-states per iteration when nothing has arrived — the four memory tests
; below are 24 T-states each with their branches not taken, the status read and
; its branch 33, the countdown 26 — times 65536 iterations per outer pass, at
; the 28 MHz the debugger runs at. Slower per pass than the serial transport's
; loop, which is exactly why the pass count is derived rather than shared.
ESP_WAIT_RX_PASSES:     equ (28000000/155) * TRANSPORT_WAIT_RX_SECONDS / 65536
    ASSERT ESP_WAIT_RX_PASSES > 0
 ENDIF

transport_wait_rx:
    ; Write layer 2 previous value
    ld a,(backup.layer_2_port)
    ld bc,LAYER_2_PORT
    out (c),a

 IF TRANSPORT_WAIT_RX_SECONDS
    ld bc,ESP_WAIT_RX_PASSES
    ld de,0                 ; the inner counter wraps to 65536 on its first dec
 ENDIF

.loop:
    ; Payload already owed to us?
    ld a,(esp_rx_remaining)
    or a
    jr nz,.ready
    ld a,(esp_rx_remaining+1)
    or a
    jr nz,.ready

    ; Or a whole frame held by a scan, which is a command that has already
    ; arrived and will never make the FIFO test below true again. Without this
    ; the wait spins for ever when the module has nothing more to say — there
    ; is no timeout in this loop, by design (see the no-CALL note above).
    ld a,(esp_hold_len)
    or a
    jr nz,.ready
    ld a,(esp_hold_len+1)
    or a
    jr nz,.ready

    ; Otherwise anything from the module at all.
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

    ; A frame captured by a scan is a command that has already arrived, and
    ; main_loop would otherwise never go and read it.
    ld hl,(esp_hold_len)
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

    ; THE BUFFER IS FREE THE MOMENT ITS LAST BYTE IS TAKEN, and getting that
    ; wrong is what the first version of this shipped. esp_rx_from_hold was
    ; cleared only when a later chunk came off the WIRE, so between finishing a
    ; held command and the next wire chunk the buffer read as busy and every
    ; capture was refused — the second collision lost its command, silently and
    ; for exactly the reason the first one no longer did. Reproduced 11 times
    ; out of 11 by the reviewer with three clients; W4 could not see it, because
    ; one collision never reaches the state. Clearing it HERE covers every path,
    ; because this is the only place esp_rx_remaining is decremented.
    ;
    ; The flag also says where THIS byte comes from, so it is read before it is
    ; cleared and the answer is carried in C across the border write —
    ; .flash2 is patched by transport_flashing_border and there must go on being
    ; exactly one of it.
    ld c,0                      ; source: the wire
    ld a,(esp_rx_from_hold)
    or a
    jr z,.source_chosen
    inc c                       ; source: the held frame
    ld a,h
    or l
    jr nz,.source_chosen
    ld (esp_rx_from_hold),a     ; A is 0: this byte empties the chunk
.source_chosen:
    pop hl

    ; Change border. Before the read, not after it, because the read's result
    ; is the return value and this would overwrite it.
.flash2:
    ld a,YELLOW
    out (BORDER),a

    ld a,c
    or a
    jp z,esp_read_raw
    jp esp_hold_read_byte


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
; Latches the connection the message about to be written is going to.
;
; Invoked by TRANSPORT_MESSAGE_START, which sits before the first byte of every
; response (send_4bytes_length_and_seqno) and every notification
; (send_ntf_pause). See point 9 in the header.
;
; A is dead at both call sites — the response path loads it from E immediately
; afterwards, the notification path has just written prgm_state — so nothing is
; saved here. DE and HL are live at both and are not touched.
; Changes:
;  AF
;===========================================================================
esp_latch_tx:
    ld a,(esp_conn_id)
    ld (esp_tx_conn_id),a
    ld a,(esp_conn_valid)
    ld (esp_tx_conn_valid),a
    ret


;===========================================================================
; A complete message has been written and the debugger is going idle.
;
; Invoked by TRANSPORT_END_MESSAGE, which sits at the three places a finished
; message can end up: cmd_loop, main, and main_loop.continue (transport.asm
; enumerates them and why there are three).
;
; RELEASING THE COMMAND'S CONNECTION IS THE HALF transport_flush CANNOT DO, and
; that is why this entry point exists at all. transport_flush is also called
; from transport_write_byte every ESP_TX_CHUNK bytes, i.e. in the middle of a
; message, so it is not a marker for "idle" — releasing there would let the
; three handlers that read payload after answering (issue #13) take the rest of
; their command from whoever spoke next.
; Changes:
;  AF, BC, DE, HL
;===========================================================================
transport_end_message:
    xor a
    ld (esp_cmd_active),a
    ; Flow through


;===========================================================================
; Sends everything queued and waits until the module has taken it.
;
; With no client there is nowhere to send, so the buffer is dropped rather than
; aimed at a connection that is not open — which is what keeps a button NMI with
; no debugger attached from parking on a TX timeout.
;
; The question asked here is esp_tx_conn_valid, NOT the value of esp_tx_conn_id:
; on real hardware the first client is id 0, so no id can answer it.
; Changes:
;  AF, BC, DE, HL
;===========================================================================
transport_flush:
    ld a,(esp_tx_conn_valid)
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
; Sends the buffered bytes as one AT+CIPSEND on the connection LATCHED when the
; message started, and clears the buffer.
; Must only be called with esp_tx_len != 0: AT+CIPSEND with a length of 0 is
; answered ERROR (jnext esp_at.cpp, begin_send). And only with esp_tx_conn_valid
; set — esp_tx_conn_id is read here without being questioned, because every value
; it can hold is a real connection. transport_flush is the only way in and it
; checks both; there is no `call esp_flush_chunk` anywhere.
;
; THE LATCHED PAIR AND NOT THE LIVE ONE, which is issue #13: a long response is
; flushed in chunks, and three handlers read payload between chunks, so the live
; id can change under a message that has already begun. See point 9.
; Changes:
;  AF, BC, DE, HL
;===========================================================================
esp_flush_chunk:
    xor a
    ld (esp_tx_fault),a

    ; "AT+CIPSEND=<id>,<len>\r\n"
    ld hl,esp_str_cipsend
    ld de,esp_cmd_buffer
    call esp_copy_string
    ld a,(esp_tx_conn_id)
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
    ;
    ; It is owed one of those two, so it gets ESP_TX_PASSES rather than the idle
    ; poll's single pass. The pair is tight ON PURPOSE: esp_wait_prompt is the
    ; only thing called with the budget raised, and it always returns — the
    ; sends either side of it can divert to tx_timeout, and they run at the
    ; short budget. rxtx_error covers the one arm that can still leave from
    ; inside (an RX overflow); see there.
    call esp_rx_budget_long
    call esp_wait_prompt
    call esp_rx_budget_short
    jr nc,.have_prompt
    or a
    jr z,.no_client         ; A = 0: ERROR, and the module never took the send

    ; A = 1: SILENCE. THE LENGTH IS ALREADY ANNOUNCED, SO THE TRANSACTION MUST
    ; BE COMPLETED (issue #16, part B). The old code jumped to .timeout here —
    ; walking away with the module owed <len> bytes, which is a state a module
    ; should never be left in: ESP-AT counts every byte it is given afterwards
    ; against that promise, so the next AT command line is eaten as payload and
    ; nothing is answered again until the count runs out. jnext models exactly
    ; that (esp_at.cpp:496 enters payload mode with the prompt, :181 counts, no
    ; timeout between), and bench N3 is red on the commit before this one.
    ;
    ; The real payload goes out rather than filler, and that is not thrift: if
    ; the module was merely slow, its prompt arrives while these bytes are still
    ; being shifted, it takes them, and the client gets the reply it was owed —
    ; which is measurably what happens under the injected budget N3 uses. If it
    ; was not slow but broken, the bytes are noise it was going to be sent
    ; anyway.
    ;
    ; NOT PROOF THAT THIS WEDGES REAL HARDWARE. Issue #15 offers the abandoned
    ; send as its best explanation for a Next that needed a power cycle and says
    ; plainly that it is a reading; four candidate triggers driven at a real
    ; Next on 2026-08-05 — this one among them — all recovered within ~3 s.
    ld a,1
    ld (esp_tx_fault),a
    ; Flow through: write the bytes.

.have_prompt:
    ld a,(esp_tx_len)
    ld b,a
    ld hl,esp_tx_buffer
.send_payload:
    ld a,(hl)
    push bc, hl
    ; esp_send_try, NOT esp_send_raw: a diverted send here would stop the frame
    ; half-written, which is the same defect one level down. Each byte still
    ; gets its own bounded wait, so this cannot spin, and the loop always runs
    ; to its full DJNZ count.
    ;
    ; WHAT IT STILL CANNOT PROMISE, because no bounded loop can. A byte whose
    ; ESP_TX_WAIT expires is NOT written — writing into a full FIFO loses it in
    ; hardware — so the module receives fewer bytes than the length announced
    ; and is left owed the difference: part B's own hazard, in miniature and
    ; narrowed from "the rest of the frame" to "the bytes that individually
    ; failed". The only way to close it completely is an unbounded wait for FIFO
    ; room, which is the thing part A exists to remove, so the bound wins and
    ; the residual is stated rather than hidden.
    ;
    ; It is also as close to unreachable as anything here: the wait is ~8.5 ms,
    ; about 98 byte times at 115200, and uart_tx.vhd:180 starts a frame on
    ; `i_Tx_en = '1' and (i_cts_n = '0' or i_frame(5) = '0')` — esp_uart_init
    ; writes 00011000b, so hardware flow control is off and the shifter is never
    ; held off by the module. It takes a transmitter that has stopped, and a
    ; transmitter that has stopped will fail the next chunk too.
    call esp_send_try
    jr nc,.byte_sent
    ld a,1
    ld (esp_tx_fault),a
.byte_sent:
    pop hl, bc
    inc hl
    djnz .send_payload

    ; The buffer is spent whatever the module says next.
    xor a
    ld (esp_tx_len),a

    ; Anything that went wrong is reported HERE, after the promise has been
    ; kept, rather than where it happened.
    ld a,(esp_tx_fault)
    or a
    jr nz,.timeout

    ; Owed too, and slower than the prompt: the module only says this once its
    ; TCP stack has taken the segment. Same tight pair, same reason.
    ld hl,esp_str_send_ok
    call esp_rx_budget_long
    call esp_wait_string_hold
    call esp_rx_budget_short
    jr c,.timeout

    ; THE WHOLE PATH WORKED — announced, taken, acknowledged — so whatever went
    ; wrong before this is not consecutive any more. This and transport_init are
    ; the only two places the count goes back to zero (issue #16, part C).
    xor a
    ld (esp_fault_count),a
    ret

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
    ;
    ; BOTH VALIDITY FLAGS, and the latched one is not optional. Its own chunk is
    ; already lost; clearing it is what stops the REST of the same message
    ; re-announcing itself to a connection that has just been refused, once per
    ; chunk. transport_flush reads the latched flag, so leaving it set would
    ; make a long response pay the whole ERROR round trip again and again.
    xor a
    ld (esp_conn_valid),a
    ld (esp_tx_conn_valid),a
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
    ; A fresh chain: nothing before it is consecutive with anything after it.
    ; Also stops a recovery that fails its own AT chain from immediately
    ; recovering again — the count starts from zero either way.
    xor a
    ld (esp_fault_count),a

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
    jp esp_wait_string_hold


;===========================================================================
; Draws WiFi mode's status block, where UART mode draws its joy-port selection.
; Called from show_ui; see the data above.
;
; Two independent things: the LINK (rows 6-7, decided once during bring-up) and
; the SESSION (row 8, from CMD_INIT/CMD_CLOSE). They are drawn from separate
; tables because they answer separate questions — "where do I connect" and "did
; anyone" — and neither state constrains the other. Both strings begin with
; their own AT, so the second does not depend on where the first ended.
; Changes:
;  AF, BC, DE, HL
;===========================================================================
esp_show_status:
    ld hl,esp_status_text_table
    ld a,(esp_link_state)
    add a                       ; *2
    add hl,a
    ld de,(hl)
    call text.ula.print_string

    ld hl,esp_client_text_table
    ld a,(esp_client_state)
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
    call esp_wait_string_hold
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
