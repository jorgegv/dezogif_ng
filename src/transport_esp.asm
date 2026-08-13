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
; 5. 115200 BAUD, not upstream's 921600, and EVERY BRING-UP STILL STARTS THERE
;    even though point 12 raises it afterwards. The ESP answers at its power-on
;    rate until told otherwise (doc/WIFI-SETUP.md; inferred, not measured on
;    hardware), and the stub has to be able to greet a module it has just met.
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
; 10. THE MODULE'S `<id>,CONNECT` AND `<id>,CLOSED` LINES ARE WATCHED, BY AN
;    OBSERVER THAT READS NOTHING. Issue #23.
;
;    Every wait here already steps over those lines; until now nothing looked at
;    them, so the only way this transport learned a peer had gone was an
;    AT+CIPSEND answered ERROR — after the fact, and only if it had something to
;    send. The visible cost was the session line at row 8: a client that
;    vanished without CMD_CLOSE left it reading "Session opened - CMD_INIT" for
;    the rest of the session (issue #14, which offered exactly this as the
;    honest alternative and built the cheap one).
;
;    ISSUE #11 IS WHY THIS IS SHAPED THE WAY IT IS. A second pattern in the RX
;    hot path is what #11 and #16 both declined to add, and #11 is the record of
;    what a scan that eats what it is not looking for costs: an inbound `+IPD`
;    destroyed and a client answered by nothing. So esp_watch_line does not read
;    the wire. It is handed each byte esp_read_scan has ALREADY read, keeps four
;    bytes of state between calls, and returns the byte untouched. It cannot
;    consume, cannot desynchronise a scan and cannot lose a frame, whatever it
;    concludes — which is a property of its position, not of its logic.
;
;    AND IT WRITES ONLY THE SESSION LINE'S OWN STATE. Not esp_conn_id, not
;    esp_conn_valid, not the latch, not esp_cmd_*: nothing the byte stream
;    reads. One of those abstentions was measured rather than chosen — see
;    esp_line_event, where clearing esp_conn_valid on a `<id>,CLOSED` is shown
;    to break bench W2's own precondition. Acting on the observation is
;    reconnect policy and belongs to issues #24 and #25; this is the state they
;    are waiting on.
;
;    WHAT IT STILL CANNOT SEE: anything transport_drain swallows, because that
;    reads with raw `in` and hands the bytes to nobody. So a line arriving
;    inside a 100 ms drain is missed — which is why a `<id>,CONNECT` on the
;    session's own id ends the session too: the module cannot hand an id to a
;    new client while the old one holds it, so it is a second, independent
;    witness for exactly the case where the CLOSED was eaten.
;
; 11. THE MODULE'S OWN IDLE TIMEOUT IS SET, BECAUSE ITS DEFAULT KILLS SESSIONS.
;    Issue #24, and it is the first thing in this file measured on a real Next
;    BEFORE it was written rather than after.
;
;    `AT+CIPSTO` is the TCP *server* idle timeout: a client that says nothing
;    for `<time>` seconds is hung up on by the module, with no involvement from
;    the guest at all. The user's Next (AT 1.2.0.0 / SDK 1.5.4.1) reports
;    `+CIPSTO:180` and ENFORCES it — a client that connected, sent CMD_INIT and
;    then stayed silent was dropped after 182.5 s and 181.8 s on two runs.
;
;    THAT IS A DEZOG SESSION PARKED AT A BREAKPOINT. Neither side transmits
;    while the user reads code: this stub never speaks unprompted, and DeZog
;    sends only when a panel asks it to. Confirmed with the real client at the
;    machine — the registers view, the memory view and the debug toolbar all
;    vanished, i.e. DeZog ended the session, and DeZog 3.7.4 has no reconnect
;    logic of any kind. The stub was perfectly healthy throughout, its border
;    still cycling; the module had simply hung up on it and said nothing about
;    it. There is NO indication on the Next that anything happened.
;
;    Worse for this transport specifically: on ESP8266, server-initiated
;    traffic does NOT restart the timer (esp-at v2.2.0.0_esp8266's own wording;
;    v1.5.4, which matches this firmware, is silent, and jnext models the
;    clause the requirement implies). So our own replies do not keep a
;    connection alive. Only the client's bytes do.
;
;    1800, NOT 0 AND NOT 7200, and the middle value is the one a measurement
;    picked. `AT+CIPSTO=0` means "never time out", which would make a peer that
;    vanished without TCP cleanup hold its inbound slot until the machine is
;    power-cycled — deliberately creating the permanent fault KNOWN-ISSUES.md
;    #19 describes, and Espressif's own documentation attaches "we don't
;    recommend that" to it. 7200 was chosen first, on the reasoning that the
;    leak was already permanent so stretching the timer cost nothing. It is
;    not: `make probe-vanished PROBE_ARGS="--no-lift --recover 210"` on the
;    user's Next has a fresh client SERVED after four vanished peers, with the
;    blackhole still up throughout, and the same run at `--recover 100` REFUSED
;    — one constant apart, so the reclaim is a timer of roughly 180 s and not
;    our own esp_recover sweep, which has no timer and could not have fired.
;    So the leak self-heals, and 7200 would have stretched a three-minute fault
;    into a two-hour one. 1800 keeps the whole practical benefit — nobody reads
;    code for half an hour without touching the debugger — and leaves the leak
;    self-healing on a human timescale.
;
;    IT IS RE-SENT ON EVERY BRING-UP, because `AT+CIPSTO` is absent from
;    v1.5.4's list of commands that write to flash: the module's 180 is the
;    firmware's compiled-in default and not something a previous session left.
;
;    AND IT IS SENT AFTER `AT+CIPSERVER`, WHICH IT WAS NOT UNTIL 2026-08-11.
;    A module with no server running REFUSES it — measured interactively under
;    `.UART`, with nothing of ours involved: bare, `AT+CIPSTO=` answers ERROR at
;    1800, 900, 240, 180 and 60 alike, so it is not the value; after
;    `AT+CIPMUX=1` and `AT+CIPSERVER=1,11000` the same `AT+CIPSTO=1800` answers
;    OK and `AT+CIPSTO?` reads back `+CIPSTO:1800`. So from build 00.14, when
;    this was written, until 00.21 the command was refused on every bring-up and
;    the refusal was invisible, because the wait below accepts ERROR by design.
;    The 182-second default governed every session in that window. See the call
;    site for what the new order trades, and jnext#249: the emulator accepts the
;    command in either position, which is why `make test-cipsto` was 4 of 4
;    throughout.
;
;    AND ITS ANSWER IS READ, THOUGH NOT RECORDED. See esp_command_ok_or_error:
;    a module too old for the command answers ERROR, which is not a reason to
;    refuse to debug, so neither arm fails bring-up. Reading it is what keeps
;    the chain synchronous — an answer left in the FIFO is matched by the NEXT
;    step's scan — and that, rather than any byte of state, is what this buys.
;    NOTHING ANYWHERE OBSERVES WHICH ARM WAS TAKEN, which is a real gap and is
;    measured rather than assumed: the bench passes 4 of 4 against a build that
;    sends the command and never waits. Closing it means putting a refusal on
;    the screen, and that is its own issue.
;
; 12. THE LINK IS NEGOTIATED UP, AND THE HARD PART IS COMING BACK DOWN. Issue
;    #25. After the module has answered at 115200 the stub asks it to move to
;    ESP_BAUD_HIGH (constants.asm, 460800 as shipped) with `AT+UART_CUR=`, moves
;    its own prescaler to match, and says `AT` up there to see whether anything
;    survived. See esp_negotiate_baud and esp_uart_set_rate.
;
;    WHY IT IS WORTH DOING: at 115200 the link is already at 71% of the line
;    rate on real hardware — 8192 bytes in 1.01 s, measured 2026-08-05 — so the
;    WIRE is the ceiling, not the module and not this code. DeZog pushes 8-16 KB
;    per bank through CMD_WRITE_BANK every time it loads a .nex, and that is felt
;    on every F5.
;
;    THE FAILURE THIS MUST NOT PRODUCE IS A HALF-SWITCHED LINK, and it is
;    reachable by two paths that have nothing to do with a failed negotiation.
;    A rate, once set, survives everything the machine can do to itself: the
;    UART's prescaler is restored only by i_reset_hard, which is tied to the
;    constant '0' (zxnext.vhd:3361-3367, serial/uart.vhd:313-320), so a Z80 SOFT
;    RESET — the stub's own `R` key — leaves both ends up there. So after a reset
;    the next M1 press would have run esp_uart_init, dropped THIS side to 115200
;    alone, and reported "ESP-01 setup failed" on a healthy module — and
;    esp_recover, which ends `jp transport_init`, would have repeated that for
;    every fault.
;
;    THE MODULE *CAN* BE RESET IN SOFTWARE, and an earlier version of this said
;    it could not. NR 0x02 bit 7 asserts reset to the expansion bus AND the ESP
;    (nextreg.txt:37-49; zxnext.vhd:60, :1579, :5119; and mf_rom.asm:72 has said
;    so here since the fork). It is not used, because it cannot be aimed at the
;    ESP alone, because the re-association that follows is unmeasured, and
;    because no bench here can execute it — see transport_init.
;
;    THE ANSWER IS A PROBE AT BRING-UP RATHER THAN A GUARD AT THE SWITCH.
;    transport_init greets the module at 115200 and, if nothing comes back, at
;    ESP_BAUD_HIGH before giving up. That is what converts every way this can go
;    wrong from "power-cycle the Next" into "press M1 again", and it is the only
;    recovery this stub SHIPS — the paragraph above is why the other one is not
;    used rather than why it does not exist.
;
;    WHAT NO RUN HERE CAN SHOW. jnext paces both directions from the GUEST's own
;    prescaler (uart.cpp:83-87), and its module never compares the rate it was
;    asked for against the rate it is spoken to — `requested_baud_` is stored and
;    never read. So a stub that told the module and forgot to move its own side,
;    or moved its own and never told the module, is byte-for-byte
;    indistinguishable there from a correct switch. The half-switched link is
;    structurally unreachable in the emulator, and no seam on OUR side can reach
;    it, because the missing behaviour is the emulator's. Hardware is the only
;    judge of the rate; see test/run-baud.sh, which is careful to claim only the
;    sequence.
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
;   listener is still there — but the screen says "RX Timeout".
;
;   THE WAIT THAT WOULD CLEAR THIS NOW EXISTS, and until issue #24 it did not:
;   this line used to end "which nothing else here needs". esp_command_ok_or_error
;   accepts OK *or* ERROR and is what the CIPSTO step uses. Pointing the
;   CIPSERVER step at it as well is a ONE-LINE change and is deliberately not
;   made here: it would move the meaning of a failed bring-up — today a refused
;   CIPSERVER is the difference between "the module is listening" and "nobody
;   told us it isn't" — and that decision wants its own issue and its own check.
;===========================================================================


;===========================================================================
; TRANSPORT_DEACTIVATE — the debugger is about to resume the debuggee.
;
; Nothing to hand back: this transport never took the joy ports, and the ESP
; holds the listening socket across the resume, which is what lets a byte from
; the PC arrive while the debuggee runs (plan §4).
;
; What it does do is note that THE SCREEN IS NO LONGER OURS. The debuggee is
; about to draw on it, so the session line must not be repainted over it later —
; see esp_refresh_client_line, which is the only reader of this byte. Four
; bytes, inline, at a site where AF is dead (backup.asm's restore_registers has
; just returned from transport_flush).
;===========================================================================
    MACRO TRANSPORT_DEACTIVATE
    xor a
    ld (esp_ui_shown),a
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
; SINCE ISSUE #23 THEY ALSO RECORD WHICH CONNECTION THE SESSION IS ON, which is
; what lets the module's own `<id>,CLOSED` be matched against it. That is more
; than fits in a macro body worth reading, so both are calls now; AF is still
; the only register touched, and it is free at both sites.
;
; See transport.asm for why these are the transport's own rather than an
; `IF ROM_VARIANT` in commands.asm, and what they are allowed to claim.
;===========================================================================
    MACRO TRANSPORT_CLIENT_ATTACHED
    call esp_client_attached
    ENDM

    MACRO TRANSPORT_CLIENT_DETACHED
    call esp_client_detached
    ENDM


;===========================================================================
; TRANSPORT_IDLE_TICK — main_loop went round once with nothing to do.
;
; Issue #24. It is a macro, and for TRANSPORT_DEACTIVATE's reason rather than
; TRANSPORT_CLIENT_ATTACHED's: main_loop is in main.asm, which is common code,
; so the mode-specific part cannot be an `IF ROM_VARIANT` there — and a CALL to
; an empty subroutine on every turn of the idle loop is a cost the UART build
; would pay for nothing. It expands to nothing there, and the UART ROM's bytes
; do not move.
;
; WHAT IT MAY TOUCH is fixed by where it is called from: main_loop holds the
; border-colour timer in BC and DE and has pushed them, so BC and DE are free
; inside the loop body, and AF and HL are free outright. Nothing else is.
;
; A transport with no housekeeping expands it to nothing, which is what UART
; mode does: there is no module underneath it to have leaked anything.
;===========================================================================
    MACRO TRANSPORT_IDLE_TICK
    call esp_idle_tick
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

; 0x153B IS A SHARED POINTER, NOT A RESOURCE WE OWN, AND THAT IS WHY THE THREE
; CONSTANTS BELOW EXIST. Bit 6 says which of the machine's two UARTs every one
; of 0x133B, 0x143B and 0x163B refers to at the instant of the access
; (ports.txt:370, serial/uart.vhd:335-372) — so a read of 0x133B means "the
; status of whichever channel is selected", where we mean "the status of OUR
; channel". Those coincide only while nothing else has moved the pointer, and a
; debuggee legitimately using the OTHER UART must move it. Issue #42.
;
; THIS BUILD OWNS UART0 AND LEAVES UART1 ENTIRELY FREE, which is what makes the
; case concrete rather than hypothetical: a program using the Raspberry Pi
; header UART while being debugged over WiFi contends with nothing at all, and
; used to blind asynchronous break simply by selecting its own channel.
;
; Writing these values back has BIT 4 CLEAR, which is what makes the correction
; safe: with bit 4 clear the write changes only the select and leaves both
; 17-bit prescalers alone (ports.txt:371-372, serial/uart.vhd:280-287). A write
; with bit 4 set would take bits 2:0 as the prescaler's top three bits.
; BIT 6 IS WHERE THE HARDWARE REPORTS THE SELECT ON A READ, and the mask below
; is that bit and no other. serial/uart.vhd:371 returns `"01000" &
; uart1_prescalar_msb_r` for the UART1 case and `"00000" & ...` for UART0
; (:355), i.e. bit 6, and bit 3 = 0 in both; ports.txt:370 says bit 6 in words.
;
; IT WAS A BUILD SEAM UNTIL 2026-08-13, of the ESP_IP_MAX / ESP_RX_WAIT /
; ESP_LINK_IDS family and for their reason: jnext returned the select in bit 3
; (`(select_ ? 0x08 : 0x00)`), so the shipped 0x40 mask read back as always-clear
; and bench W9 could not go green against a shipped ROM however correct that ROM
; was — measured, one constant apart. jnext#253 moved it to bit 6, so W9 now
; runs the SHIPPED ROM and the seam is gone.
;
; DO NOT "FIX" A FUTURE VERSION OF THIS BY MASKING BOTH BITS IN THE SHIPPED ROM.
; That would put an emulator's defect into the bytes a real Next executes, to
; make a check pass.
UART_SELECT_CHANNEL: equ 01000000b  ; the select bit, for masking a read
UART_SELECT_OURS:    equ 00000000b  ; UART0, the ESP's channel — see transport_init
UART_SELECT_OTHER:   equ 01000000b  ; UART1, the Pi header's

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
; program does not know which ids are open. Issue #23 watches the module's
; `<id>,CONNECT` / `<id>,CLOSED` lines (esp_watch_line) but keeps no open-set
; from them, on purpose: an open-set that nothing reads is state to maintain and
; get wrong, and the sweep would not want it anyway. AT+CIPCLOSE=<id> on an id
; with nothing behind it is answered ERROR, which costs one line of RX and
; nothing else, so asking about all five stays cheaper than knowing which one to
; ask about — and, crucially, a set built only from lines this stub HAPPENED to
; be scanning when they arrived would be a set with holes in it (every byte
; transport_drain eats is one the observer never sees), which is worse than no
; set at all for a routine whose job is to leave nothing behind.
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

; The module's own TCP-server idle timeout, in seconds — issue #24, and point 11
; in the header, which carries the whole argument for the value. In one line:
; the firmware default of 180 hangs up on a DeZog session while its user reads
; code, 0 would turn issue #19's self-healing slot leak into a permanent one,
; and 1800 is the measured middle. The range the firmware documents is 0..7200
; inclusive.
;
; OVERRIDABLE, and this is the SIXTH seam of the ESP_IP_MAX / ESP_RX_WAIT /
; ESP_TX_PASSES / TRANSPORT_WAIT_RX_SECONDS / ESP_FAULT_LIMIT / ESP_LINK_IDS
; family. Two settings earn a check and neither is reachable otherwise:
;
;   * a SHORT value, because the shipped 1800 cannot be observed to fire inside
;     any bench anyone will run — half an hour per run — while a client dropped
;     at ten seconds shows that the value THIS ROM SENT is the value that
;     governs, which is the whole claim;
;   * an OUT-OF-RANGE value, which the module refuses, so that the ERROR arm of
;     esp_command_ok_or_error is executed rather than reasoned about. jnext
;     answers `ERROR` above 7200 exactly as the firmware documents.
;
; See test/run-cipsto.sh.
 IFNDEF ESP_SERVER_TIMEOUT
ESP_SERVER_TIMEOUT: equ 1800
 ENDIF

; The bench seam that assembles the CIPSTO step the WRONG way — waiting for OK
; alone, so that a refusal is a bring-up failure. Nothing ships with this set;
; it exists because the behaviour a check must be shown red against has to be
; reachable by a BUILD, which is the same argument ESP_LINK_IDS=0 carries, and
; a refusal is otherwise indistinguishable from a stub that simply never sent
; the command. See test/run-cipsto.sh's K4.
 IFNDEF ESP_CIPSTO_STRICT
ESP_CIPSTO_STRICT:  equ 0
 ENDIF

; How long the stub sits idle, with no DZRP session and nothing arriving, before
; it frees the module's inbound slots once — issue #24, in seconds. 0 disables
; the sweep entirely, which is this seam's control.
;
; WHY A TIMER AT ALL, when issue #19 already built the sweep. Because nothing
; could reach it. esp_recover fires on ESP_FAULT_LIMIT consecutive faults, and
; the state that strands a user raises none: measured on a real Next
; (doc/HARDWARE-TESTING.md, probe B), four peers that vanished without FIN or
; RST are survivable and the fifth stops the module serving anybody — after
; which a new client never completes the module's handshake, so the stub sees no
; bytes to time out; the leaked peers are silent by construction; and an
; unprompted send to a stale id takes esp_wait_prompt's ERROR arm and returns
; quietly. The trigger was structurally unreachable rather than merely unlikely,
; and the mechanism sat there unable to run.
;
; IT IS DELIBERATELY NOT A CONNECT-TIME TRIGGER, which is what issue #24
; proposed and which cannot be built. Two reasons and either is sufficient. It
; would close the OTHER ids when a client arrives, and this suite deliberately
; holds several at once: test/dzrp/queued-commands.py opens THREE and INITs every
; one, split-command.py holds TWO across its exchange, and hardware H3 two. So
; bench checks W4 and W5 — and H3 — would go red for a change that broke nothing
; they were written to measure. And it cannot reach the state above anyway: by
; then no client can connect, so nothing would trigger it. KNOWN-ISSUES.md #19
; says the second half in as many words.
;
; WHAT MAKES A TIMER SAFE where "close on suspicion" is forbidden (issue #24's
; own What NOT to do, and KNOWN-ISSUES.md #19's reasoning) is that it does not
; run while a session is open: a DeZog session stopped at a breakpoint is silent
; for minutes and perfectly healthy, and esp_idle_tick returns without counting
; for as long as esp_session_valid is set. So the sweep can only happen with no
; DZRP session to lose.
;
; WHAT THAT LEAVES UNPROTECTED IS A SOCKET WITH NO SESSION ON IT, and it is
; deliberate rather than overlooked. esp_session_valid is set by CMD_INIT, so a
; peer that connected and never introduced itself — or one that has been silent
; since CMD_CLOSE — is closed by a sweep, once nothing at all has arrived for
; the whole period. That is this transport's standing position and not a new
; one: "a socket is not a session" is what bench check N1 asserts and what issue
; #23's esp_line_event is written around. Note also that ANY inbound frame
; restarts the timer, from any connection and whether or not it opened a
; session, so what is at risk is only a connection that is silent for five
; minutes while every other peer is silent too.
;
; AND IT USED TO BE WORSE THAN THAT SENTENCE ADMITS — issue #40. The timer was
; restarted only by a parsed +IPD, and a bare TCP connect never reaches one, so
; a socket the module accepted while the stub was idle got not "five minutes"
; but whatever happened to be left of a period somebody else had started, down
; to nothing at all. The module's `<id>,CONNECT` now restarts it too
; (esp_line_event), which is what makes "five minutes" true of a newly arrived
; socket rather than only of one that has already spoken. See ESP_CONNECT_RESET
; for what that costs.
;
; AND THE CONVERSE IS THE ONE THAT LIMITS WHAT THIS BUYS, so it is written here
; rather than left to be discovered: the guard also keeps the sweep away from
; KNOWN-ISSUES.md #19's OWN HEADLINE CASE. esp_session_valid is cleared by
; exactly two things — CMD_CLOSE (esp_client_detached) and the module reporting
; <id>,CLOSED for that same session (esp_line_event) — and a peer that VANISHES
; sends neither, which is the whole definition of the fault #19 describes. So
; when the connection that vanished is the one that most recently sent CMD_INIT,
; this routine never counts a single tick and never sweeps, globally, until the
; module's own AT+CIPSTO reap eventually produces a <id>,CLOSED — if it announces
; one at all, which nobody has checked.
;
; That is the guard working, not a hole in it: sweeping while a session looks
; open is exactly the "close on suspicion" forbidden above, and weakening it to
; reach this case would trade a bounded fault for a debugger that hangs up on a
; user reading code. What it means is that this trigger reaches the OTHER shapes
; — a socket that never introduced itself, and one superseded by a later session
; that closed cleanly — and that the module's ~1800 s remains the backstop for
; the headline one. KNOWN-ISSUES.md #19's "What to do" and "What would reopen it"
; are both written against that 1800 rather than against this 300, for exactly
; this reason. Do not "fix" the asymmetry by relaxing the guard.
;
; 300 SECONDS, and the number is bounded from both sides rather than picked. It
; must be well under the module's own AT+CIPSTO reap — 1800 since this same
; issue's first half — or the module gets there first and this buys nothing. And
; it must be far longer than any gap in a real session, which is what the
; session guard already covers, so the remaining risk is only the refusal window
; below. Five minutes sits an order of magnitude inside both.
;
; WHAT IT COSTS, once per idle period: five AT+CIPCLOSE lines and their answers.
; A client that connects during them keeps its slot — the listener is NOT
; retired, unlike esp_recover's sweep — but it may be closed by a later id in
; the same pass, and would have to reconnect. That is the whole downside, it is
; bounded by the length of one sweep, and it is why this fires ONCE per idle
; period rather than repeating: see esp_idle_armed.
 IFNDEF ESP_IDLE_SWEEP_SECS
ESP_IDLE_SWEEP_SECS:    equ 300
 ENDIF

; The same thing in ticks, which is what esp_idle_tick counts. ONE TICK IS ONE
; FRAME — the video line counter passing its maximum and starting again.
;
; 50 A SECOND, because that is the frame rate of every 50 Hz timing mode; the
; 60 Hz ones give 60, so a period built from this arrives at five sixths of its
; nominal length there. For a housekeeping timer whose only hard requirement is
; to be well under the module's own 1800-second reap, a sixth either way is
; nothing — but it is a real spread and not the "about 3%" an earlier version of
; this comment claimed.
;
; THAT EARLIER VERSION WAS WRONG BY A FACTOR OF NEARLY TWO, AND THE MISTAKE IS
; WORTH LEAVING WRITTEN DOWN because it was made with a VHDL citation attached.
; It counted a tick as 256 lines — a wrap of the LOW BYTE of NR 0x1F — and
; derived 61 a second from the length of a line. But the counter behind NR
; 0x1E/0x1F is `cvc`, which does not run to 511 and wrap: it resets when it
; reaches c_max_vc (video/zxula_timing.vhd:457-470), and c_max_vc is 319, 311,
; 310 or 263 (:168,204,238,270,298) — never a multiple of 256. So the low byte
; decreases TWICE per frame, once at line 256 and once at the reset, and a
; detector that counts every decrease was counting about 100 a second while the
; constant was built for 61. The shipped 300 seconds would have been ~180.
;
; SO THE TICK IS BIT 8 INSTEAD, read from NR 0x1E, and it is exactly one per
; frame BY CONSTRUCTION rather than by arithmetic: both values the counter can
; be reset to are below 256 — 0 at c_max_vc, and NR 0x64's offset at the vactive
; anchor, which is 8 bits and so at most 255 — while c_max_vc is at least 263.
; The counter therefore climbs through 256 exactly once per frame and is put
; back below it exactly once, whatever the timing mode and whatever NR 0x64
; holds. Reading the one byte also avoids the tearing a two-byte read of NR
; 0x1E/0x1F has at that same rollover.
ESP_IDLE_SWEEP_TICKS:   equ ESP_IDLE_SWEEP_SECS * 50
    ASSERT ESP_IDLE_SWEEP_TICKS < 65536      ; the counter is 16 bits

; Whether the module's `<id>,CONNECT` restarts the timer above — issue #40. 0
; assembles that out, which is what shipped before this and is the ONLY reason
; the seam exists: bench check S9 has to be red against something.
;
; WHAT IT FIXES. Before this, only a parsed +IPD restarted the countdown, and a
; bare TCP connect never reaches one — so a socket the module accepted while the
; stub was idle sat inside a period it had not started, and was reaped by it
; after whatever was left. Reproduced deterministically at IDLE_SWEEP=10, 60
; closures out of 60. Restarting on the connect gives such a socket a WHOLE
; period instead, which for the shipped 300 seconds is every client that speaks
; at all promptly.
;
; WHAT IT COSTS, and it is accepted rather than avoided: a genuinely leaked
; socket now holds its slot for one period longer than it would have. That is
; free in practice because the module reaps on its own AT+CIPSTO regardless —
; 1800 seconds since issue #24's first half — so the backstop is unmoved and
; only this stub's own housekeeping is deferred.
;
; THAT IS THE COST PER EVENT AND CONNECTS CAN REPEAT, so read it as a deferral
; and not as a one-off: a stream of accepted-but-silent connects pushes the
; sweep back for as long as it keeps arriving. It is self-limiting rather than
; unbounded, and by the mechanism this whole feature runs on — at the ceiling
; the module refuses the connection and emits NO line for it, so the state where
; a sweep is most wanted is exactly the one in which nothing can defer it. The
; module's own reap bounds the rest. KNOWN-ISSUES.md #19 carries the case a user
; meets.
;
; IT IS NOT A CONNECT-TIME SWEEP, which is the thing #24 examined and could not
; build (see above). Nothing is closed here; a timer is restarted, and the sweep
; still fires from the same place on the same rule.
;
; REJECTED: per-id state recording which connections have arrived since the last
; sweep, so that only THOSE are spared. It is more state and a subtler rule for
; a case the module's own timeout already bounds (user, 2026-08-10).
 IFNDEF ESP_CONNECT_RESET
ESP_CONNECT_RESET:      equ 1
 ENDIF

; The three sites below share one condition, and it is written once so that they
; cannot drift: with the sweep itself assembled out there is no counter to
; restart, so IDLE_SWEEP=0 takes this with it.
;
; ITS NAME MUST NOT BEGIN WITH THE SEAM'S, and that is a build-time trap rather
; than a style rule: sjasmplus substitutes a -D textually, so with
; -DESP_CONNECT_RESET=0 a symbol called ESP_CONNECT_RESET_ON becomes `0_ON` and
; every use of it is a hard error. Written the other way round for that reason,
; and the multiply is what stands in for a logical AND.
ESP_RESET_ON_CONNECT:   equ ESP_CONNECT_RESET * (ESP_IDLE_SWEEP_TICKS > 0)

; How long the stub sits idle, with no DZRP session, before it asks the module
; again whether it still has the address the screen is advertising — issue #32,
; in seconds. 0 disables the re-query entirely, which is this seam's control and
; is what shipped before this: one AT+CIFSR at bring-up and never another.
;
; WHY A PERIODIC QUERY AND NOT AN EVENT. A real module puts unsolicited `WIFI
; DISCONNECT` / `WIFI CONNECTED` / `WIFI GOT IP` lines on the wire at these
; edges, and a stub that watched for them would need no timer at all. It is not
; done, for the reason this project declines every unverified mechanism: nobody
; here has ever observed those lines, jnext models none of them (jnext#246 left
; them out deliberately, for exactly that reason), and so a watcher for them
; would be Z80 no bench could execute — issue #19's trade, refused again.
; Polling is what can be checked, so polling is what is written.
;
; BOTH DIRECTIONS MATTER, and the second is the commoner one. Losing the
; association leaves `Connect at <ip>:11000` on the screen naming an address
; that no longer reaches the machine. But a Next switched on BEFORE its router
; is ready comes up with no address at all, and then the screen says "No WiFi
; address. Set the Next up first: run wifi2.bas" — which is not merely stale, it
; is wrong ADVICE: the machine is set up correctly and the router simply was not
; there yet. Before this, the only cure for either was an M1 press.
;
; 60 SECONDS, and what bounds it is the cost below rather than taste. It has to
; be short enough that somebody standing at the machine, wondering why their
; debugger will not attach, sees the screen put itself right while they are
; still standing there — a minute passes that test and five does not. There is
; no upper constraint worth naming: nothing else in the system depends on this
; number, unlike ESP_IDLE_SWEEP_SECS, which has to stay well inside the module's
; own AT+CIPSTO reap.
;
; WHAT IT COSTS, once a minute: one AT+CIFSR and its three-line answer. The
; window that matters inside that is esp_query_address's wait for
; `+CIFSR:STAIP,"` — a scan whose pattern begins with '+', which by
; esp_wait_string_hold's rule is one of the only two scans in this transport
; that CANNOT capture an inbound frame instead of destroying it. So a client
; whose first command lands inside that window loses it, which is issue #10's
; residual turned from a once-per-bring-up window into a recurring one.
;
; WHAT MAKES THAT ACCEPTABLE IS THE WIDTH OF EACH EVENT, not how often it comes
; round. A scan reads only until it matches — the module answers AT+CIFSR at
; once — so the window is the handful of milliseconds the reply takes, against a
; period of sixty seconds: on the order of 0.01% of the time, and only while no
; DZRP session is open. It is the same KIND of window esp_idle_tick's own sweep
; already opens, and a narrower one: that sweep drains each of five AT+CIPCLOSE
; answers with transport_drain, which reads with raw `in`, hands the bytes to
; NOBODY, and does not stop until 100 ms of quiet.
;
; AN EARLIER VERSION ARGUED THIS ON FREQUENCY AND HAD IT BACKWARDS, saying the
; sweep costs "five drains every ESP_IDLE_SWEEP_SECS" so that one scan a minute
; was the cheaper. The sweep runs ONCE PER IDLE PERIOD, not once per period for
; ever — esp_idle_armed, cleared when it runs and re-armed only by esp_sync_ipd
; — which this file says thirty lines above at esp_idle_armed and which bench
; check S5 measures. So on a quiet machine the sweep costs five drains IN TOTAL
; and this costs one scan a minute for ever, which is the opposite comparison.
; The conclusion survives on per-event width; the arithmetic it was first given
; did not.
;
; AND THE GUARD KEEPS IT AWAY FROM A LIVE SESSION ENTIRELY. See
; esp_check_address: nothing is asked while esp_session_valid is set, so a
; client that has introduced itself with CMD_INIT — which is every real DeZog
; session — can never have a command eaten by this. What remains exposed is the
; gap between a socket being accepted and its first command arriving, which is
; measured in milliseconds against a period measured in minutes.
;
; THE SAME GUARD SILENCES THE CHECK ON WHAT MAY BE ITS COMMONEST REAL TRIGGER,
; and that is the exact shape #24 documents for its own sweep — "the sweep cannot
; fire for KNOWN-ISSUES.md #19's own headline case". esp_session_valid is cleared
; by exactly two things: CMD_CLOSE, and the module reporting <id>,CLOSED for that
; session's connection. A mid-session association loss produces NEITHER — that is
; what "the WiFi went away" means. So: DeZog attached, the router reboots, the
; WiFi returns on a new DHCP address, and the user walks to the Next to find out
; where to reconnect — and finds the old address still on the screen, because the
; gate never cleared and no tick was ever counted. It stays that way until the
; module's own AT+CIPSTO reap at 1800 s produces an <id>,CLOSED, IF it announces
; one at all, which KNOWN-ISSUES.md #2 records as unverified. Possibly for ever.
;
; THAT IS THE GUARD WORKING AND MUST NOT BE "FIXED" by dropping it: asking while
; a session looks open is close-on-suspicion, which #24's acceptance criteria
; forbid, and a DeZog session parked at a breakpoint is silent and healthy. What
; the re-query reaches is every other shape — no session yet, or one that ended
; cleanly — and an M1 press reaches the rest.
 IFNDEF ESP_ADDR_CHECK_SECS
ESP_ADDR_CHECK_SECS:    equ 60
 ENDIF

; The same thing in ticks. ONE TICK IS ONE FRAME, and the whole argument for why
; that is exactly true in every timing mode is above, at ESP_IDLE_SWEEP_TICKS —
; this counter is stepped by the same edge, in the same routine, on the same
; read of NR 0x1E bit 0.
ESP_ADDR_CHECK_TICKS:   equ ESP_ADDR_CHECK_SECS * 50
    ASSERT ESP_ADDR_CHECK_TICKS < 65536      ; the counter is 16 bits

 IF ESP_BAUD_HIGH != ESP_BAUDRATE
; How many times esp_negotiate_baud says `AT` at the new rate before deciding
; the rate does not work. Two, and the second one is what the constant is for:
; see the routine, where the module may still be reconfiguring its own UART when
; the first goes out. It is not a bench seam and nothing overrides it — one and
; two are not two interesting states, they are a coin toss about somebody else's
; firmware timing, and the cost of the extra attempt is paid only on the arm that
; is about to fail anyway.
ESP_BAUD_TRIES:     equ 2

; Which of the two rates the prescaler is currently programmed to, and so which
; one the screen names. Written by esp_uart_init and esp_uart_init_high and by
; NOTHING ELSE — those two routines are the only writers of the prescaler as
; well, so this byte cannot disagree with the hardware without somebody adding a
; third writer of one and not the other.
;
; THAT INVARIANT IS THE POINT OF THE BYTE. The line it drives used to be a
; constant assembled from ESP_BAUDRATE, and a ROM that negotiated up would then
; have gone on stating the rate its own peripheral was NOT running at — which is
; the exact defect MEMORY.md 2026-08-05 records this line being fixed for, in
; this same row, in the first place anyone looks when the ESP misbehaves.
ESP_BAUD_IS_LOW:    equ 0
ESP_BAUD_IS_HIGH:   equ 1
 ENDIF

; What the UI has to say about the link. Decided at bring-up and, since issue
; #32, revisited from the idle path — see ESP_ADDR_CHECK_SECS and
; esp_check_address.
;
; IT IS STILL NOT DECIDED FROM show_ui, which is what this comment used to say
; and half of which is still right: show_ui is re-entered on every redraw and an
; AT round trip per redraw would be paid every time the border key is pressed.
; The half that was WRONG is the reason it gave — "the address cannot change
; while we hold the module". It can. Holding the module says nothing about
; whether the module is still on a network, and the whole of issue #32 is that
; the screen went on advertising an address after it had stopped being one.
ESP_LINK_OK:            equ 0   ; associated, listening, and the address is known
ESP_LINK_NO_ADDRESS:    equ 1   ; the module answered, but has no usable address
ESP_LINK_FAILED:        equ 2   ; the AT chain did not complete
; ESP_LINK_FAILED covers every way the chain can stop — silence, or a command
; refused — because from the screen's point of view they are one situation and
; have one first move. Splitting them would need the module to have said
; something to tell them apart, which in the silent case it has not.

; What the UI has to say about the debug SESSION (issue #14, then #23).
;
; THESE ARE EVENTS THAT HAPPENED, NOT A LIVE CONNECTION, AND THE WORDING OF
; EVERY LINE BELOW IS PICKED SO THE SCREEN CANNOT CLAIM MORE THAN THAT. Three
; of the four come from above the byte stream — CMD_INIT and CMD_CLOSE, the only
; two moments a DZRP session can be seen to start and stop — and the fourth
; comes from the module itself.
;
;   * a client that opens TCP and says nothing is still invisible. ATTACHED is
;     about CMD_INIT, not about a socket, and bench check N1 asserts that;
;   * a client that vanishes WITHOUT CMD_CLOSE used to leave ATTACHED standing
;     for the rest of the session. That is what LOST closes: the module's own
;     `<id>,CLOSED` (or a `<id>,CONNECT` handing that id to somebody else) is
;     matched against the connection the session was opened on. Issue #23,
;     point 10 in the header, esp_watch_line;
;   * ATTACHED's line still says a session was OPENED rather than that one is
;     open, and that is not a leftover. It is the state's whole meaning: this
;     transport sees frames, not sockets, and between the last frame and a
;     `<id>,CLOSED` there is a window in which nothing at all is known.
;
; WHAT LOST DOES NOT MEAN. Not "the client crashed" — a clean socket close from
; a client that simply did not send CMD_CLOSE produces exactly the same line.
; Not "the debugger is idle" either: prgm_state, the breakpoints and the
; debuggee's saved state are untouched by this, which is why the line names the
; client rather than the session's contents.
ESP_CLIENT_NONE:        equ 0   ; no CMD_INIT since the debugger came up
ESP_CLIENT_ATTACHED:    equ 1   ; a CMD_INIT arrived, and no CMD_CLOSE since
ESP_CLIENT_DETACHED:    equ 2   ; a CMD_CLOSE arrived
ESP_CLIENT_LOST:        equ 3   ; the module says that connection has gone

; The FIRST of the two rows the link status block is drawn on; the second is the
; one below it. Every one of the three alternatives below is two rows, so this is
; the whole of what that block occupies.
;
; A CONSTANT SINCE ISSUE #32 rather than the `6*8` it was written as three times,
; because esp_check_address has to BLANK exactly the rows those strings occupy
; before redrawing them, and a blank that was one row out would leave half of a
; longer previous line standing under a shorter new one. Two renderings of one
; fact is how they drift.
ESP_LINK_ROW:           equ 6

; The row the session line is drawn on. Under the connect block at rows 6 and 7,
; which is where a reader looking for "has my session arrived" is already
; looking, and clear of the key list — WiFi mode's starts at row 11.
ESP_CLIENT_ROW:         equ 8


;===========================================================================
; Const data
;===========================================================================

; Fsys/baud for each of the eight video timings in NR 0x11 bits 2:0. The Fsys
; column is upstream's (transport_uart.asm's baudrate_table); the entries are
; 14 bits wide here rather than 8 because 115200 is not representable in
; upstream's table — 33000000/115200 is 286, and upstream's own comment says it
; needs 230400 or more.
;
; THEY ROUND RATHER THAN TRUNCATE, and at 115200 that is a nicety while at the
; negotiated rate it is not. sjasmplus divides integers by truncating, which at
; 115200 happens to be within 0.31% everywhere and so never mattered; above it
; the divisors are small enough that one count is percent-scale. Adding
; baud/2 before the divide costs no bytes at all — it is assembler arithmetic —
; and moves two of the 115200 entries: Fsys 29464286 from 255 (+0.301%) to 256
; (-0.091%), and 32000000 from 277 (+0.281%) to 278 (-0.080%). Both old values
; worked and both new ones are closer; NO BENCH HERE COVERS EITHER, because
; jnext's reference image boots at video timing 0, where truncation and
; rounding agree. See ESP_BAUD_HIGH in constants.asm for what it buys upstairs.
    MACRO PRESCALERS baud?
    defw (28000000 + baud?/2)/baud?
    defw (28571429 + baud?/2)/baud?
    defw (29464286 + baud?/2)/baud?
    defw (30000000 + baud?/2)/baud?
    defw (31000000 + baud?/2)/baud?
    defw (32000000 + baud?/2)/baud?
    defw (33000000 + baud?/2)/baud?
    defw (27000000 + baud?/2)/baud?
    ENDM

esp_prescaler_table:
    PRESCALERS ESP_BAUDRATE

 IF ESP_BAUD_HIGH != ESP_BAUDRATE
; The same eight, for the rate esp_negotiate_baud asks the module to move to.
; A second table rather than arithmetic at run time: the divide is the one
; thing the assembler can do for free and the Z80 cannot.
esp_prescaler_table_high:
    PRESCALERS ESP_BAUD_HIGH
 ENDIF

; The two bounds every entry in both tables has to respect, and the reason this
; is an ASSERT and not a comment is that ESP_BAUD_HIGH is a build seam somebody
; will move. Checked at the extremes of the Fsys column, which is monotonic in
; the divisor: the largest Fsys gives the largest prescaler and the smallest the
; smallest.
;
; BOTH ARE BACKSTOPS RATHER THAN LIVE BOUNDS TODAY, and saying so is the
; difference between an assertion and a comment with a keyword in front of it.
; constants.asm's own pair — ESP_BAUD_HIGH under 10000000 and at or above
; ESP_BAUDRATE — is strictly tighter than either of these, so with those in
; place no setting can reach here: the 14-bit one needs a rate below ~2014 baud
; and the floor one a rate above ~13.5 MHz. The first was nevertheless WATCHED
; TO FIRE, by taking constants.asm's floor out and building at 2000 baud; the
; second cannot be reached at all without removing both guards, and is kept for
; the day somebody raises STRINGIFY's seven-digit ceiling.
;
; 1. 14 BITS. esp_uart_set_rate writes bits 2:0 of the select — the prescaler's
;    three most significant bits — as ZERO and sends only two 7-bit halves, so
;    an entry of 16384 or more would be sent as that value modulo 16384 and the
;    link would come up at a rate nobody chose.
    ASSERT (33000000 + ESP_BAUD_HIGH/2)/ESP_BAUD_HIGH < 16384
; 2. AT LEAST TWO. The receiver halves the divisor to find the middle of a bit
;    (uart_rx.vhd; jnext models it as `rx_timer_ = rx_prescaler_snap_ >> 1`), so
;    a divisor of 1 would sample at the edge it just detected.
    ASSERT (27000000 + ESP_BAUD_HIGH/2)/ESP_BAUD_HIGH >= 2

esp_cmd_ate0:       defb "ATE0",13,10,0
esp_cmd_at:         defb "AT",13,10,0
esp_cmd_cipmux:     defb "AT+CIPMUX=1",13,10,0
esp_cmd_cipserver:  defb "AT+CIPSERVER=1,"
    STRINGIFY ESP_SERVER_PORT
    defb 13,10,0
; Issue #24, and point 11 in the header. Sent BEFORE the listener opens, for two
; reasons: no client can then be accepted while the module's own 180-second
; default is still in force, and — since nothing is listening yet — no
; `<id>,CONNECT` can land inside the wait for this command's answer.
esp_cmd_cipsto:     defb "AT+CIPSTO="
    STRINGIFY ESP_SERVER_TIMEOUT
    defb 13,10,0
 IF ESP_BAUD_HIGH != ESP_BAUDRATE
; Issue #25, and point 12 in the header. `_CUR` and NOT `_DEF`: the CUR form
; leaves the module's flash alone, so a rate this board turns out not to like
; is forgotten the moment the module loses power, where _DEF would persist it
; and hand the user a module the stub could no longer greet. That is the
; difference between "press M1 again" and "take the SD card to a PC and hope".
;
; ,8,1,0,0 = 8 data bits, 1 stop bit, no parity, no flow control — the same
; frame esp_uart_set_rate writes into 0x163B as 00011000b, and they have to
; agree. Flow control stays OFF at both ends deliberately: it is wired to real
; pins only on issue 4 and issue 5 boards (zxnext_top_issue4.vhd:2277-2278,
; issue5:2461-2462) and is dead in the design on an issue 2
; (zxnext_top_issue2.vhd:2387-2388, `i_UART0_CTS_n => '0'`), so a build that
; leaned on it would work on some machines and not others.
esp_cmd_uart_high:  defb "AT+UART_CUR="
    STRINGIFY ESP_BAUD_HIGH
    defb ",8,1,0,0",13,10,0
 ENDIF
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

; The tails of the module's two unsolicited connection lines, `<id>,CONNECT` and
; `<id>,CLOSED` — issue #23, and esp_watch_line, which is the only reader.
;
; THEY START AT THE SECOND LETTER because that is where the two words first
; differ, and the observer branches there: `<digit>` `,` `C` then 'O' or 'L'
; picks one of these and the rest is matched literally. The CR is part of the
; pattern, so only a COMPLETE line fires the event — the same reason
; esp_str_send_ok carries its own CRLF, one defect along.
esp_str_connect_tail:   defb "NNECT",13,0
esp_str_closed_tail:    defb "OSED",13,0

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

;---------------------------------------------------------------------------
; The connection-line observer — issue #23, point 10 in the header.
;
; esp_watch_line's position in `<id>,CONNECT` / `<id>,CLOSED`, kept between
; calls because it is fed one byte at a time by whatever scan happens to be
; running. It reads nothing itself; see there for why that is the whole safety
; argument.
;
;   0  nothing seen             3  the 'C'; 'O' or 'L' picks a tail
;   1  a digit (expect ',')     4  matching a tail at esp_line_ptr
;   2  the ',' (expect 'C')
;
; A mismatch in any state re-tests the offending byte as a fresh leading digit,
; so `11,CLOSED` and a line arriving straight after another one both work.
;---------------------------------------------------------------------------
esp_line_state:     defb 0
esp_line_id:        defb 0
esp_line_ptr:       defw 0      ; meaningful in state 4 only

 IF ESP_RESET_ON_CONNECT
; WHICH of the two lines is being matched — 'O' for CONNECT, 'L' for CLOSED,
; the byte that chose the tail. Issue #40 is the first consumer that cares, and
; only one of them is one: a CONNECT restarts the idle sweep's timer and a
; CLOSED must not, because a closed connection is a slot the module has just
; handed back and deferring the sweep for it would be backwards.
;
; Meaningful in state 4 only, exactly as esp_line_ptr is, and written on the
; same two paths that set it.
;
; IT CANNOT BE READ STALE, AND THE ARGUMENT IS AN ENUMERATION RATHER THAN A
; HABIT — which is why it is written down here instead of being rediscovered.
; esp_line_state is set to 4 in exactly one place, .tail_start, and that place
; writes this byte unconditionally on the way past; state 4 dispatches to
; .want_tail and nowhere else; and .want_tail is the only caller of
; esp_line_event. So every read of this byte is preceded by a write of it in the
; same line's own match.
;
; ANYTHING THAT ADDS A SECOND WAY INTO STATE 4 BREAKS THAT SILENTLY: the stale
; value would still be one of 'O' or 'L', so the timer would simply be reset on
; the wrong line, with nothing to see. Set this byte there too, or do not.
esp_line_kind:      defb 0
 ENDIF

;---------------------------------------------------------------------------
; Which connection the DZRP session is on — issue #23.
;
; Written by CMD_INIT and cleared by CMD_CLOSE, so it names a session rather
; than a socket, and it is what the observer above matches an id against. The
; validity flag is separate from the id for the reason point 3 in the header
; cost a hardware evening: every value an id can take is a real connection, 0
; included, so no value of esp_session_id can mean "nobody".
;---------------------------------------------------------------------------
esp_session_id:     defb 0
esp_session_valid:  defb 0

; The session line no longer says what esp_client_state says, and something
; should redraw it. Set by esp_line_event, cleared by esp_show_client_line — so
; ANY repaint satisfies it, including the show_ui that drain_main reaches after
; a disconnect. See esp_refresh_client_line.
esp_ui_dirty:       defb 0

; Whether the screen currently holds the debugger's own UI. show_ui sets it;
; TRANSPORT_DEACTIVATE clears it, because the debuggee is about to draw. Read
; only by esp_refresh_client_line, and only so that one row of our UI is never
; painted over a stopped debuggee's display.
esp_ui_shown:       defb 0

; The 8K bank MMU slot 2 held the last time we drew that row, i.e. the bank
; 0x4000 MEANT then. Read back from NR 0x52 at draw time and compared against
; NR 0x52 again before any redraw — see esp_refresh_client_line, where it is the
; guard that stops a redraw becoming a write into somebody else's memory.
;
; CAPTURED RATHER THAN A CONSTANT, and not for tidiness. cmd_init writes bank 10
; there (commands.asm), so `cp 10` would work today — and it would be this file
; encoding a fact that lives in another one, which is how two renderings of one
; number drift apart. What is actually wanted is "the window still points where
; it pointed when the row was drawn", and that is answerable without knowing
; which bank it was.
;
; SINCE ISSUE #28 THE VALUE IS ALWAYS SCREEN_BANK, AND THE GUARD IS STRONGER FOR
; IT. show_ui now maps the display file under 0x4000 itself and puts back what
; was there (ui.asm's screen_map), and this byte is read inside that window — so
; what is recorded is the screen's bank, and the comparison below has become "is
; 0x4000 the screen RIGHT NOW" instead of "has the mapping moved since I drew".
; The second was the weaker question, and it had a case: an M1 press against a
; debuggee whose own slot 2 was not the screen used to record the DEBUGGEE's
; bank here, after which a redraw would match it and XOR the session line into
; the program being debugged. Nothing else about this changes — the capture is
; kept for the reason above, and `cp SCREEN_BANK` would now tie this file to
; show_ui's choice of window as well as to the number.
esp_ui_bank:        defb 0

; Which state's string is currently ON the row. Not the same question as
; esp_client_state, which is what the row SHOULD say, and the two differ for
; exactly as long as esp_ui_dirty is set. It exists because ula.print_char XORs:
; the only way to take a line off the screen without clearing the whole thing is
; to draw it a second time, and that needs to know which line it was. See
; esp_refresh_client_line.
esp_client_drawn:   defb ESP_CLIENT_NONE

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

 IF ESP_IDLE_SWEEP_TICKS > 0 || ESP_ADDR_CHECK_TICKS > 0
; THE SHARED FRAME EDGE, and it is shared because there is only one clock: bit 8
; of the active video line counter as it was last seen, so that its 1->0 edge
; can be recognised. Both idle timers below are stepped by it, in one place, on
; one NextREG read per turn of main_loop — see esp_idle_tick.
;
; It sits outside either feature's own IF for that reason, and the condition
; above is an OR: a build with the sweep assembled out (IDLE_SWEEP=0, bench S7)
; still needs the edge if the address check is in, and the reverse.
;
; Its initial value is a don't-care: 0 is what the first sample will most often
; read anyway, and the worst a wrong guess can cost is one missed tick.
esp_idle_line:      defb 0
 ENDIF

 IF ESP_IDLE_SWEEP_TICKS > 0
; Issue #24's idle sweep — see ESP_IDLE_SWEEP_SECS for why it exists and why it
; is a timer rather than a connect-time trigger, and esp_idle_tick for how these
; bytes are used.
;
; Frames since the last inbound frame. Reset by esp_sync_ipd, so ANY traffic
; restarts the countdown — and, since issue #40, by esp_line_event on the
; module's `<id>,CONNECT`, so a socket that has been accepted but has not spoken
; yet restarts it too. Those are the only two that RESET it; esp_idle_tick
; INCREMENTS it, so there are three writers in all and a fourth would be news.
esp_idle_ticks:     defw 0
 ENDIF

 IF ESP_ADDR_CHECK_TICKS > 0
; Frames counted towards the next AT+CIFSR re-query — issue #32. Stepped by the
; same edge as the counter above, in the same routine, and reset to zero each
; time it fires, because unlike the sweep this one REPEATS: closing connections
; over and over would open a refusal window every period for as long as the
; machine was switched on, while asking the module a question does nothing to
; anybody. So there is no `armed` byte beside it.
;
; AND IT IS NOT RESET BY INBOUND TRAFFIC, where esp_idle_ticks is. That is a
; deliberate difference and not an oversight. The sweep is about PEERS, so
; traffic is evidence about its subject and rightly restarts its clock; this is
; about the module's own association, which no amount of traffic says anything
; about. A stub that a client connects to every thirty seconds would otherwise
; never check at all, and that is a debugger in use — the one this matters most
; to. What keeps a live session safe is the session guard rather than the reset;
; see esp_check_address.
esp_addr_ticks:     defw 0
 ENDIF

 IF ESP_IDLE_SWEEP_TICKS > 0
; Whether a sweep is still owed for this idle period. Cleared when one runs and
; set again by esp_sync_ipd, which is what makes this fire ONCE per idle period
; instead of every ESP_IDLE_SWEEP_SECS for as long as the machine is switched
; on — see ESP_IDLE_SWEEP_SECS on the refusal window a sweep opens.
;
; IT STARTS ARMED, not clear, and that is deliberate: the leaked-slot state
; survives everything except a power cycle of the MODULE, and a Symbol Shift
; re-init or an esp_recover is exactly a moment when the stub has no idea what
; the module is still holding.
esp_idle_armed:     defb 1
 ENDIF

 IF ESP_BAUD_HIGH != ESP_BAUDRATE
; Issue #25. See ESP_BAUD_IS_LOW for why this exists and who may write it. It
; starts LOW because that is where esp_uart_init leaves the peripheral, and a UI
; drawn before any bring-up must not claim a rate nobody negotiated.
esp_baud_state:     defb ESP_BAUD_IS_LOW
 ENDIF

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
    defb AT, 0, ESP_LINK_ROW*8
    defb "Remote debugger ACTIVE"
    defb AT, 0, (ESP_LINK_ROW+1)*8
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

 IF ESP_BAUD_HIGH != ESP_BAUDRATE
;---------------------------------------------------------------------------
; The rate, at row 3, column 14 — where "ESP Baudrate: " ends. Issue #25.
;
; Two strings and no renderer: both rates are known at assembly time, so the
; alternative would be a decimal conversion routine on the Z80 to print one of
; two numbers the assembler can already spell. The AT is in pixels (text.asm),
; hence 14*8.
;
; THE LABELS AROUND THE DIGITS ARE FULL NAMES AND NOT `.text` / `.end`, which
; every other bounded string in this file uses. STRINGIFY assigns to plain
; symbols of its own (macros.asm), so the assembler attaches a dot-local written
; after it to the LAST of those instead of to the string — `Duplicate label:
; divisor.end`, which is a confusing way to be told that.
;---------------------------------------------------------------------------
esp_text_baud_low:
    defb AT, 14*8, 3*8
esp_text_baud_low_digits:
    STRINGIFY ESP_BAUDRATE
esp_text_baud_low_end:
    defb 0

esp_text_baud_high:
    defb AT, 14*8, 3*8
esp_text_baud_high_digits:
    STRINGIFY ESP_BAUD_HIGH
esp_text_baud_high_end:
    defb 0

; 14 columns of label plus the number, on a 32-column screen. An ASSERT and not
; arithmetic in a comment, because ESP_BAUD_HIGH is a build seam somebody will
; move and print_char would silently clip the overflow at column 32.
    ASSERT 14 + (esp_text_baud_low_end - esp_text_baud_low_digits) <= 32
    ASSERT 14 + (esp_text_baud_high_end - esp_text_baud_high_digits) <= 32

; Indexed by esp_baud_state, which esp_show_status does not range-check — the
; same rule as the two tables below, and the assembler counts rather than a
; reader.
esp_baud_text_table:
    defw esp_text_baud_low
    defw esp_text_baud_high
esp_baud_text_table_end:
    ASSERT (esp_baud_text_table_end - esp_baud_text_table) / 2 == ESP_BAUD_IS_HIGH + 1
 ENDIF

esp_text_no_address:
    defb AT, 0, ESP_LINK_ROW*8
    defb "No WiFi address. Set the Next"
    defb AT, 0, (ESP_LINK_ROW+1)*8
    defb "up first: run wifi2.bas", 0

esp_text_failed:
    defb AT, 0, ESP_LINK_ROW*8
    defb "ESP-01 setup failed. Check it"
    defb AT, 0, (ESP_LINK_ROW+1)*8
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

; NOT "No debug session yet.", and the difference is the point of issue #23.
; Reusing NONE would make this state indistinguishable from a stub that never
; saw a CMD_INIT at all — so a bench check for it would go green against a ROM
; that had simply failed to light the line in the first place, which is
; mfselect's M9 in a new costume (ERRORS.md). A line of its own can only be
; drawn by having observed the connection go.
;
; It names the CLIENT rather than the command, because unlike the three above it
; is not a DZRP event: what was seen is the module reporting that a connection
; is no longer there. "gone" covers both ways that happens — a socket closed
; without CMD_CLOSE, and an id handed on to somebody else.
esp_text_client_lost:
    defb AT, 0, ESP_CLIENT_ROW*8
.text:
    defb "Session lost - client gone"
.end:
    defb 0
    ASSERT .end - .text <= 32

; Indexed by esp_client_state, which esp_show_status does not range-check —
; same rule as the table above, and the assembler counts rather than a reader.
esp_client_text_table:
    defw esp_text_client_none
    defw esp_text_client_attached
    defw esp_text_client_detached
    defw esp_text_client_lost
esp_client_text_table_end:
    ASSERT (esp_client_text_table_end - esp_client_text_table) / 2 == ESP_CLIENT_LOST + 1

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
; until the MODULE reclaimed it, and recovery after recovery could not
; reclaim it. Four or five such peers and the module refuses every new client
; while this routine goes on reporting success — a hang with issue #15's exact
; outward signature, and five is all it takes, measured on a real Next
; (doc/HARDWARE-TESTING.md, probe B). How a peer comes to vanish in the field is
; NOT claimed here: nothing has measured that, and an earlier version of this
; comment asserted a user's retry loop as though it had.
;
; "UNTIL THE MODULE RECLAIMED IT" USED TO READ "for the rest of the power-on
; session", AND THAT WAS FALSE — issue #29. The module reclaims a vanished
; peer's slot itself, on its own AT+CIPSTO idle timeout, with no involvement
; from this program at all. Measured on a real Next 2026-08-08, with the
; firewall blackhole held UP for the whole wait so that nothing of ours ever
; told the module anything: a fresh client was SERVED in 56 ms after 210 s of
; peer silence, and REFUSED at 100 s — one argument apart, bracketing the
; +CIPSTO:180 the module reports. `make probe-vanished
; PROBE_ARGS="--no-lift --recover 210"`.
;
; SO THE LEAK IS BOUNDED, not permanent, and the bound moved twice: ~180 s on
; the firmware default, and ~1800 s since issue #24 has the stub set
; AT+CIPSTO=1800 at bring-up. What is NOT changed by any of that is this
; routine's reason to exist — nothing on the Z80's side of the UART frees a
; slot, and a stub that wants one back inside those minutes has to ask. The
; sibling claim in KNOWN-ISSUES.md #19 was corrected on its own branch, which
; deliberately kept an empty src/ diff and so could not reach this comment;
; that is why this one outlived it by a day.
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

    ; Free every inbound slot, id by id (issue #19).
    call esp_close_all_links

    ; esp_recovering is cleared by rxtx_error's .report, NOT here, because that
    ; is the one place BOTH ways out of this pass through: the ordinary return
    ; below, and a fault inside this chain that jumps to rxtx_error and never
    ; comes back. Clearing it here would leave that second way out with the flag
    ; set for the rest of the power-on session, and no recovery would ever run
    ; again.
    jp transport_init


;===========================================================================
; Frees every one of the module's inbound slots — issue #19, and since issue
; #24 this has two callers rather than one.
;
; Blind and numbering-agnostic on purpose: see ESP_LINK_IDS.
;
; THE TWO CALLERS ARRIVE IN DIFFERENT STATES AND THAT IS DELIBERATE. esp_recover
; has already retired the listener, so nothing can take a slot between freeing
; it and the re-listen. esp_idle_tick has NOT, and must not: the listener is the
; only thing that can bring a user back after a leak, and in the state this
; exists for it is still up and simply has no slots to hand out. What that costs
; is one client's connection if it lands mid-sweep — bounded by one sweep, and
; the reason the idle trigger fires once per idle period.
;
; Changes:
;  AF, BC, DE, HL
;===========================================================================
esp_close_all_links:
    ; The IF is the bench seam and not a runtime choice: ESP_LINK_IDS=0 leaves
    ; the loop out altogether, which is the pre-#19 routine. `ld b,0` would run
    ; it 256 times rather than none, so it cannot be left to djnz.
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
    ret


;===========================================================================
; One turn of main_loop with nothing to do — issues #24 and #32.
;
; TWO TIMERS AND ONE CLOCK. The sweep (issue #24) frees the module's inbound
; slots once per idle period; the address check (issue #32) asks the module
; whether it still has the address the screen is advertising, every period, for
; ever. ESP_IDLE_SWEEP_SECS and ESP_ADDR_CHECK_SECS carry the whole argument for
; each — why a timer rather than a connect-time hook, why a timer may close
; connections at all where "close on suspicion" is forbidden, and why one
; repeats and the other does not. This is only how the counting works.
;
; THEY SHARE THE SESSION GUARD AND THE FRAME EDGE AND NOTHING ELSE. Sharing the
; guard is not a saving, it is the same requirement twice: a DZRP session parked
; at a breakpoint is silent and healthy, and neither closing its peers nor
; putting an AT command in front of its next reply is allowed. Sharing the edge
; is one NextREG read per turn of main_loop instead of two.
;
; THE CLOCK IS NR 0x1E BIT 0 — bit 8 of the active video line counter — and one
; tick is one frame, taken on its 1->0 edge. That register is free-running and
; ungated: nothing in the VHDL enables it, and in particular no IFF1/IFF2, no DI
; and no NMI, which is what makes it the only usable clock in a debugger that
; runs with interrupts off and the ROM's FRAMES sysvar dead.
;
; ONE EDGE PER FRAME IS BY CONSTRUCTION, not by arithmetic, and the argument is
; in ESP_IDLE_SWEEP_TICKS along with the factor-of-two error it replaces: every
; value the counter can be reset to is below 256 and its maximum is at least
; 263, so bit 8 goes up once a frame and comes back down once a frame in every
; timing mode and for every value of NR 0x64.
;
; Reading ONE byte also avoids the tearing a two-byte read of NR 0x1E/0x1F has
; at that same rollover, where MSB-then-LSB can return 0 for 255.
;
; THE COUNT RUNS SLOW UNDER LOAD AND NEVER FAST, which is the right direction.
; A turn of main_loop is a few hundred T-states, so bit 8's high window — 7
; lines at its shortest, ~450 us — is sampled thousands of times. But
; transport_byte_available can spend up to ~100 ms synchronising when the module
; puts an unsolicited line on the wire, and every frame boundary inside that is
; unseen. A missed frame lengthens the timer; nothing here can shorten it.
;
; THE SWEEP'S CLOCK STOPS WHILE A SESSION IS OPEN rather than being reset, so it
; is not restarted by the session ending — which means a client that vanishes
; without CMD_CLOSE is swept for that much sooner. That is the case it exists
; for, so the direction is right; and its counter cannot be stale in the other
; direction, because esp_sync_ipd resets it on every inbound frame. The address
; check's counter is deliberately NOT reset by traffic; see esp_addr_ticks.
;
; A FAULT INSIDE EITHER IS NOT SPECIAL-CASED. esp_close_link and
; esp_query_address both send and read, so a module that has stopped answering
; can raise faults here exactly as transport_byte_available already can from the
; same loop, and enough of them reach esp_recover through rxtx_error. That is an
; escalation from housekeeping to a full re-init on a module that is genuinely
; broken, which is the right answer and is why nothing here suppresses it.
;
; THE ORDER OF THE TWO OPENING TESTS CHANGED WITH ISSUE #32, and it is behaviour
; and not tidying. The sweep's "already done this period" test used to come
; first, as the cheapest question — but it also stopped the frame edge being
; sampled at all once the sweep had run, which is fine for a timer that fires
; once and wrong for one that repeats. The session guard leads now because it is
; the one both timers share, and the sweep's own armed test has moved down to
; where the sweep is counted. Both are side-effect-free early returns, so the
; sweep's behaviour is unchanged in every way that can be observed.
;
; NOT quite "exactly as it did", which is what this said first. esp_idle_line is
; now sampled while the sweep is DISARMED, where the armed test used to return
; ahead of it — so the edge state stays current across an idle period instead of
; going stale, which can move the very first tick after re-arming by at most one
; frame in ESP_IDLE_SWEEP_TICKS (15000), and in the direction of more accuracy
; rather than less. Bench checks S5 and S6 are unmoved by it, measured.
;
; Changes:
;  AF, BC, DE, HL — see TRANSPORT_IDLE_TICK for why those and no others.
;===========================================================================
esp_idle_tick:
 IF ESP_IDLE_SWEEP_TICKS > 0 || ESP_ADDR_CHECK_TICKS > 0
    ; A DZRP session stops both clocks. Not "defers them" — stops them, so that
    ; no amount of a user reading code at a breakpoint can add up to a sweep, or
    ; put an AT command in front of the reply they are waiting for.
    ld a,(esp_session_valid)
    or a
    ret nz

    ld a,REG_ACTIVE_VIDEO_LINE_H
    call read_tbblue_reg
    and 1                       ; bit 8 of the line counter, and nothing else
    ld hl,esp_idle_line
    cp (hl)                     ; CY only on 1 -> 0, which is one frame
    ld (hl),a
    ret nc

  IF ESP_ADDR_CHECK_TICKS > 0
    ; Issue #32. FIRST of the two, because it is the one that repeats: putting
    ; it after the sweep's `ret c` would have made it unreachable for every
    ; period but the sweep's own.
    ld hl,(esp_addr_ticks)
    inc hl
    ld (esp_addr_ticks),hl
    ld de,ESP_ADDR_CHECK_TICKS
    or a                        ; A is the line byte; this only clears the carry
    sbc hl,de
    jr c,.no_address_check
    ; Time is up. Zero the counter BEFORE the query, for the reason the sweep
    ; disarms before sweeping: esp_query_address can leave through rxtx_error
    ; rather than returning, and an idle loop that re-entered the query every
    ; 20 ms afterwards would be far worse than one that skipped a period.
    ld hl,0
    ld (esp_addr_ticks),hl
    call esp_check_address
.no_address_check:
  ENDIF

  IF ESP_IDLE_SWEEP_TICKS > 0
    ; Issue #24. This idle period has already had its sweep?
    ld a,(esp_idle_armed)
    or a
    ret z

    ld hl,(esp_idle_ticks)
    inc hl
    ld (esp_idle_ticks),hl
    ld de,ESP_IDLE_SWEEP_TICKS
    or a                        ; A is esp_idle_armed; this only clears the carry
    sbc hl,de
    ret c

    ; Time is up. Disarm FIRST: the sweep can leave through rxtx_error rather
    ; than returning, and an idle loop that re-entered a half-finished sweep
    ; every 16 ms would be far worse than one that skipped a sweep.
    xor a
    ld (esp_idle_armed),a
    jp esp_close_all_links
  ENDIF
    ret
 ELSE
    ; Both seams at 0 — nothing counts, nothing is swept and nothing is asked.
    ret
 ENDIF


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
; IT IS ALSO WHERE THE CONNECTION-LINE OBSERVER IS FED, and that placement is
; the whole of issue #23's safety argument: this routine is the one point every
; byte of the module's own chatter passes through, and by the time
; esp_watch_line sees a byte the byte has already been read. An observer that
; reads nothing cannot destroy an inbound frame, which is what #11 and #16 both
; declined to risk. What can and cannot reach it — including the one window in
; which payload does — is in esp_watch_line's own header.
;
; Returns:
;  NC and A = a byte that is not part of an inbound frame, or CY on timeout.
; Changes:
;  AF, BC, DE  (HL is preserved: both callers hold their pattern there)
;===========================================================================
esp_read_scan:
    call esp_try_read_raw
    ret c
    call esp_watch_line         ; preserves A and HL; reads nothing
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
; Watches one byte of the module's chatter for `<id>,CONNECT` / `<id>,CLOSED`.
; Issue #23, and point 10 in the header.
;
; IT CONSUMES NOTHING, AND THAT IS THE DESIGN RATHER THAN AN OPTIMISATION.
; Every byte it sees has already been read by esp_read_scan and is handed to the
; waiting scan afterwards untouched; this routine never goes near the UART. A
; second pattern in the RX hot path is what issues #11 and #16 both declined to
; add, and #11 is the record of the cost — a scan that ate an inbound `+IPD`
; left a client answered by nothing at all. An observer positioned behind the
; read cannot do that, whatever it decides, and the argument does not depend on
; its logic being right.
;
; WHAT REACHES IT. esp_read_scan is on the path of the module's LINE-ORIENTED
; output: `OK`, `ERROR`, `SEND OK`, `busy`, the leading '+' of a header, and the
; two unsolicited lines wanted here. DZRP payload does not normally arrive —
; transport_read_byte, esp_capture_ipd's header verify, esp_read_decimal and
; esp_hold_frame's copy all read through esp_try_read_raw directly. Nor do the
; `<id>,CLOSED` lines esp_recover's own AT+CIPCLOSE sweep produces: those are
; drained with raw `in` and are ours rather than a peer's.
;
; "DOES NOT NORMALLY" AND NOT "CANNOT", because there is one window and it is
; already known. A scan runs with the wire between frames on every ordinary
; path, but a response long enough to fill ESP_TX_CHUNK mid-message flushes
; while its own command's payload is still owed — the three handlers of issue
; #13, at 240 response bytes — and then esp_wait_prompt's scan reads payload.
; That is the window esp_capture_ipd has always lived in (a '+' in payload
; already misleads it), not one this adds.
;
; SO THE WORST CASE HERE IS A WRONG LINE ON THE SCREEN, and it is worst because
; of what esp_line_event refuses to touch rather than because the pattern is
; improbable: it takes nine specific bytes in that window, and if they occur the
; only thing that happens is that row 8 reports a session that is still open.
;
; The matching is naive and its restart re-tests the offending byte as a fresh
; leading digit, which is what makes back-to-back lines and a two-digit id
; harmless. Only a complete line — CR included — reaches esp_line_event.
;
; Parameter:
;  A = the byte just read.
; Returns:
;  A and HL unchanged. The flags are not preserved: esp_read_scan re-tests the
;  byte immediately afterwards.
; Changes:
;  F, C, DE  (D carries the byte; esp_read_scan already declares BC and DE, so
;  this is inside its contract)
;===========================================================================
esp_watch_line:
    push af
    push hl
    ld d,a                      ; the byte, out of A's way
    ld hl,(esp_line_ptr)
    ld a,(esp_line_state)
    dec a
    jr z,.want_comma
    dec a
    jr z,.want_c
    dec a
    jr z,.want_word
    dec a
    jr z,.want_tail
    ; State 0: nothing seen yet. Flow through.

.first:
    ; Also the restart: whatever broke a partial match may itself be the start
    ; of the next line, and the module does put them back to back.
    ld a,d
    sub '0'
    cp 10
    jr nc,.reset
    ld (esp_line_id),a
    ld a,1
    ld (esp_line_state),a
    jr .out

.reset:
    xor a
    ld (esp_line_state),a
.out:
    pop hl
    pop af
    ret

.want_comma:
    ld a,d
    cp ','
    jr z,.have_comma

    ; A FURTHER DIGIT IS ACCUMULATED, NOT A RESTART, so that nothing here encodes
    ; how many digits an id has. ESP-AT numbers connections 0-4 and jnext 1-4, so
    ; "10,CONNECT" cannot arrive today — and MEMORY.md 2026-08-05 is explicit
    ; that no value of a connection id is special and that this transport must
    ; "encode nothing anywhere about its range, its first value or how the module
    ; allocates it". That entry exists because a reserved id cost a hardware
    ; evening; taking only the last digit would be the same assumption wearing a
    ; parser's clothes. esp_read_decimal, which parses the id in a real `+IPD`
    ; header, already accumulates and already refuses what will not fit a byte —
    ; this is the same rule in the same file.
    ld a,d
    sub '0'
    cp 10
    jr nc,.first            ; not a digit at all: it may start a new line
    ld e,a
    ld a,(esp_line_id)
    cp 26                   ; anything larger cannot survive the *10 below
    jr nc,.reset
    add a,a                 ; x2
    ld c,a
    add a,a                 ; x4
    add a,a                 ; x8
    add a,c                 ; x10
    add a,e
    jr c,.reset             ; ...nor the final digit
    ld (esp_line_id),a
    jr .out

.have_comma:
    ld a,2
    ld (esp_line_state),a
    jr .out

.want_c:
    ld a,d
    cp 'C'
    jr nz,.first
    ld a,3
    ld (esp_line_state),a
    jr .out

.want_word:
    ; CONNECT and CLOSED first differ here, so this is where the tail is chosen.
    ld a,d
    cp 'O'
    jr z,.connect
    cp 'L'
    jr nz,.first
    ld hl,esp_str_closed_tail
    jr .tail_start
.connect:
    ld hl,esp_str_connect_tail
.tail_start:
 IF ESP_RESET_ON_CONNECT
    ; A still holds the byte that chose the tail — 'O' or 'L' — which is the
    ; cheapest possible record of which line this is. Kept because issue #40
    ; needs the two told apart; see esp_line_kind, and esp_line_event, which is
    ; where the difference is acted on.
    ld (esp_line_kind),a
 ENDIF
    ld (esp_line_ptr),hl
    ld a,4
    ld (esp_line_state),a
    jr .out

.want_tail:
    ; WHICH of the two matched is remembered in esp_line_kind and nowhere else:
    ; they mean the same thing to esp_line_event's SESSION half, which is why
    ; this used to remember nothing at all, and opposite things to the idle
    ; timer that issue #40 added there.
    ld a,(hl)
    cp d
    jr nz,.first
    inc hl
    ld (esp_line_ptr),hl
    ld a,(hl)
    or a
    jr nz,.out
    call esp_line_event
    jr .reset


;===========================================================================
; A complete `<id>,CONNECT` or `<id>,CLOSED` line has been seen — issue #23.
;
; WHAT IT IS ALLOWED TO TOUCH IS THE WHOLE OF THIS DESIGN, and the list is four
; bytes long: esp_session_valid, esp_client_state, esp_ui_dirty and — since
; issue #40 — esp_idle_ticks. It does NOT write esp_conn_id, esp_conn_valid, the
; esp_tx_conn_* latch, esp_cmd_* or any of the esp_rx_* state. So no message in
; flight can be redirected, no command being assembled can change owner and no
; frame can be lost — which is what leaves bench checks W4 and W5, where two
; clients are served at once, measuring exactly what they measured before. That
; list is the invariant; its length is not.
;
; ONE OF THOSE ABSTENTIONS WAS MEASURED RATHER THAN CHOSEN, and it is the
; interesting one. Clearing esp_conn_valid here — "the module says the peer has
; gone, so stop sending to it" — is the obvious next step and it breaks bench
; W2: that check's own PRECONDITION is that an AT+CIPSEND really was refused by
; the module, and a stub that had already forgotten the connection never issues
; one, so W2 would go red having tested nothing. The fact is still learned one
; round trip later, in esp_flush_chunk's .no_client. Acting on it earlier is
; reconnect policy and belongs to issues #24 and #25.
;
; BOTH LINES MEAN THE SAME THING HERE, AND CONNECT IS NOT REDUNDANT. `<id>,
; CLOSED` says that connection went. `<id>,CONNECT` on the SAME id says the
; module has handed that id to somebody else, which proves the previous holder
; is gone just as well — and it is the only witness left when the CLOSED was
; missed, which happens whenever one lands inside a transport_drain.
;
; Only the connection a DZRP session was opened on is interesting: any other id
; belongs to a client this stub has never been introduced to, and reporting on
; it would be the screen claiming to see sockets again.
;
; THE IDLE TIMER IS THE ONE THING HERE THAT IS NOT ABOUT THE SESSION, and it is
; deliberately first — issue #40. Every id matters to it, session or not, which
; is exactly what the two early returns below throw away; and the state it cares
; about is the one in which they always return. See ESP_CONNECT_RESET.
; Changes:
;  AF, HL
;===========================================================================
esp_line_event:
 IF ESP_RESET_ON_CONNECT
    ; A CONNECT and only a CONNECT. The idle sweep exists to reap sockets
    ; nobody is using, and one that has just arrived is the opposite of that —
    ; so it gets a whole period to introduce itself in, rather than whatever was
    ; left of a period somebody else started. A CLOSED is left alone on purpose:
    ; that slot has just come BACK, and deferring the sweep for it would delay
    ; the housekeeping this whole timer exists to do.
    ;
    ; NOTHING IS RE-ARMED, only reset. esp_idle_armed stays where it is, so a
    ; period that has already swept is not given a second one, and a stream of
    ; connects can never buy more sweeps than traffic would.
    ;
    ; IT ALSO RESETS THE COUNTER WHILE A SESSION IS OPEN, which touches a
    ; decision #24 took deliberately and so is spelled out rather than left to
    ; be found. esp_idle_tick FREEZES the counter during a session instead of
    ; zeroing it, on the reasoning that a peer which then vanishes is swept that
    ; much sooner. This runs before that guard — it has to, since the state it
    ; exists for is the one where the guard returns — so a CONNECT arriving on
    ; some OTHER connection while a session is open unfreezes nothing but does
    ; put the frozen value back to zero, and a peer that vanishes afterwards
    ; waits a full period rather than the remainder of one.
    ;
    ; That is the same "one period longer" already accepted above, reached by a
    ; second route, and it is bounded by the module's own AT+CIPSTO exactly as
    ; the first is. Deferring the reset until the session closes would need
    ; another byte to remember it by, for a case the module already reaps.
    ld a,(esp_line_kind)
    cp 'O'                      ; 'O' of CONNECT; 'L' is CLOSED
    jr nz,.not_connect
    ld hl,0
    ld (esp_idle_ticks),hl
.not_connect:
 ENDIF
    ld a,(esp_session_valid)
    or a
    ret z
    ld a,(esp_line_id)
    ld hl,esp_session_id
    cp (hl)
    ret nz

    xor a
    ld (esp_session_valid),a
    ld a,ESP_CLIENT_LOST
    ld (esp_client_state),a
    ; THE SCREEN IS NOT PAINTED FROM HERE. This runs inside a scan, several
    ; frames deep, with the caller's pattern on the stack and the module owing
    ; an answer — a screen write in the RX hot path is exactly the sort of thing
    ; this file exists to keep out of it. The row is redrawn by whoever gets
    ; there first: drain_main's show_ui after the scan times out, or
    ; esp_refresh_client_line from main_loop's poll.
    ld a,1
    ld (esp_ui_dirty),a
    ret


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
    ;
    ; TRAFFIC ALSO RESTARTS THE IDLE SWEEP'S TIMER AND RE-ARMS IT (issue #24),
    ; and it belongs here for the same reason: this is the one routine that
    ; makes a wire chunk current, so it is the one point that sees every inbound
    ; frame however the caller got here. Re-arming is what makes the sweep fire
    ; once per idle period rather than once every ESP_IDLE_SWEEP_SECS for as
    ; long as the machine is switched on.
 IF ESP_IDLE_SWEEP_TICKS > 0
    ld hl,0
    ld (esp_idle_ticks),hl
    ld a,1
    ld (esp_idle_armed),a
 ENDIF

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

    ; The module said something, which is the only way the connection-line
    ; observer can have fired since the last time round this loop — so this is
    ; where a session line invalidated by a departed client is put right.
    ; Nothing is drawn unless it was, and a quiet wire never reaches this line
    ; at all. See esp_refresh_client_line.
    call esp_refresh_client_line

.quiet:
    ld hl,(esp_rx_remaining)
    ld a,h
    or l
.ret:
    pop hl, de, bc
    ret


;===========================================================================
; THE O(1) HALF OF THE ABOVE, for the asynchronous-break poll — issue #22.
;
; transport_byte_available is not usable from mf_nmi_poll and the reason is one
; line of it: `call esp_sync_ipd`, which scans for a `+IPD` header and can spend
; a whole ESP_RX_WAIT pass — ~100 ms at 28 MHz — before giving up. That is fine
; in main_loop, where it is bounded and paid only when the module has spoken. It
; is not fine inside an NMI that fires 50 times a second while the debuggee runs:
; the debuggee would lose ~100 ms per frame and the poll would starve itself.
;
; So this is the same three questions with the scan removed:
;   - is a chunk still owed from a frame already parsed?
;   - is a captured frame held, waiting to be served as the next command?
;   - is the module saying anything at all?
;
; WHAT IT GIVES UP BY NOT SCANNING is the ability to tell a DZRP command from
; one of the module's unsolicited `<id>,CONNECT` / `<id>,CLOSED` lines, so such
; a line breaks a running debuggee in. Argued at mf_nmi_poll, where the
; alternative — parsing inside the NMI — is worse.
;
; NO HL, DELIBERATELY, so that DE and HL can be left entirely alone: the byte
; pairs are read a byte at a time rather than through `ld hl,(nn)`. The caller's
; HL and DE belong to the interrupted debuggee.
;
; IT CANNOT CONSUME. The two counters are only read, and 0x133B is the UART's
; STATUS register — the data register is 0x143B — so the byte it reports is
; still in the FIFO for cmd_loop. It does clear the RX overflow and framing
; flags (serial/uart.vhd:536-539); mf_nmi_poll's ordering is what keeps that
; away from the debugger's own reads.
;
; IT BORROWS THE UART SELECT, AND THAT IS NOT DEFENSIVE PROGRAMMING AGAINST THE
; DEBUGGEE — IT IS THIS READ BEING UNDER-SPECIFIED WITHOUT IT (issue #42). The
; `in a,(0x133B)` below means "the status of whichever channel 0x153B selects";
; what it INTENDS is "the status of ours". Those coincide only while nothing has
; moved the pointer since transport_init, and this build leaves UART1 entirely
; free — so a debuggee using the Pi header contends with nothing, moves the
; pointer for its own channel, and silently blinds the break. Documenting "do
; not write 0x153B" would charge it for a UART we are not using; borrowing the
; pointer for one read costs it nothing. See UART_SELECT_OURS above.
;
; THE COMMON PATH DOES NOT WRITE. It reads the select, compares, and falls
; straight through — about 39 T-states against the poll's measured ~1288 per
; frame. Only a debuggee that has actually moved the pointer pays for the
; correction, and it gets its value back before the NMI returns.
;
; The two counter tests come FIRST and are deliberately left in front of it:
; they answer from MAIN_BANK without touching the UART at all, so a poll that
; already has a reason to break in never goes near the debuggee's register.
;
; Returns:
;   NZ = there is something for us
;   Z  = the link is quiet
; Changes:
;   AF   (BC, DE and HL are preserved — see transport.asm)
;===========================================================================
transport_poll_traffic:
    ld a,(esp_rx_remaining)
    or a
    ret nz
    ld a,(esp_rx_remaining+1)
    or a
    ret nz

    ld a,(esp_hold_len)
    or a
    ret nz
    ld a,(esp_hold_len+1)
    or a
    ret nz

    ; Is 0x133B about our channel?
    ld a,HIGH UART_SELECT
    in a,(LOW UART_SELECT)
    and UART_SELECT_CHANNEL
    cp UART_SELECT_OURS
    jr nz,.borrow_select

    ld a,HIGH UART_TX
    in a,(LOW UART_TX)
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
    ld a,UART_SELECT_OURS
    out (c),a

    ld a,HIGH UART_TX
    in a,(LOW UART_TX)
    bit UART_RX_FIFO_EMPTY,a

    ; NEITHER `ld a,n` NOR `out (c),a` TOUCHES THE FLAGS, so the verdict the
    ; caller reads survives the restore with no push/pop of AF. `in a,(n)` does
    ; not either, unlike `in r,(c)` — which is why the read above can sit
    ; between the two writes.
    ld a,UART_SELECT_OTHER
    out (c),a
    pop bc
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
    ; an unprompted notification in that window still goes nowhere.
    ;
    ; ISSUE #23 NOW WATCHES `<id>,CONNECT`, AND DELIBERATELY DOES NOT ADOPT IT
    ; HERE. Seeing the line is the cheap half; deciding that a connection nobody
    ; has spoken on is the one to answer is a policy question with two wrong
    ; answers — adopt unconditionally and a second client's CONNECT redirects
    ; the reply to a command already received (bench W5's subject), adopt only
    ; when esp_conn_valid is clear and the case this paragraph describes is
    ; still missed, because .no_client has not run yet. That is issue #24's, and
    ; esp_watch_line is the state it is waiting on.
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
 IF ESP_BAUD_HIGH != ESP_BAUDRATE
    jr nc,.awake

    ; NOTHING AT 115200. THE MODULE MAY BE WHERE WE LEFT IT — issue #25, and
    ; this is the step that keeps a raised rate from ever needing a power cycle.
    ;
    ; A rate this stub negotiated survives everything the machine can do to
    ; itself. The UART's prescaler is restored only by i_reset_hard, which
    ; zxnext.vhd:3361-3367 ties to the constant '0' (serial/uart.vhd:313-320 for
    ; the gate), so a Z80 soft reset — the stub's own `R` key, or NextZXOS's —
    ; leaves BOTH ends up there.
    ;
    ; A SOFTWARE RESET OF THE MODULE DOES EXIST, and this comment claimed the
    ; opposite until it was checked against the primary reference. nextreg.txt
    ; 37-49 gives NR 0x02 (W) `bit 7 = Assert and hold reset to the expansion bus
    ; and the esp wifi`, and the core agrees throughout: zxnext.vhd:60 declares
    ; `o_RESET_PERIPHERAL ... asserted under sw control for esp / exp bus reset`,
    ; :1579 drives it from :5119's nr_02_bus_reset, and this repository's own
    ; mf_rom.asm:72 has said `Preserve esp/expbus bit` since the fork.
    ;
    ; IT IS NOT USED HERE, FOR THREE REASONS AND NOT FOR THE ONE THIS COMMENT
    ; USED TO GIVE. It is not separable from the expansion bus — one line,
    ; `bus_rst_n_io`, on every board revision, whose own comment says it "makes
    ; more sense if exp bus reset and esp reset are separated", which only parses
    ; because they are not — so pulsing it resets whatever the user has plugged
    ; in, which this stub knows nothing about. The module would then reboot and
    ; have to re-associate, and NOTHING HERE HAS MEASURED how long that takes;
    ; until it has an address there is no connect string to draw. And no bench
    ; here can execute it: jnext models no path from NR 0x02 to its ESP, so it
    ; would be Z80 nothing could run, which is the trade issue #19 refused.
    ;
    ; So the probe below is the FIRST move rather than the only one, and a bit-7
    ; pulse is a real escape hatch behind it if the probe ever proves
    ; insufficient. Building that wants its own issue and a jnext model.
    ;
    ; Without this, the M1 press after a reset would run esp_uart_init, drop THIS
    ; side to 115200 while the module stayed up, and paint "ESP-01 setup failed"
    ; on a module that was working perfectly — recoverable only by power-cycling
    ; the machine. esp_recover would make it worse rather than better, since it
    ; ends `jp transport_init` and would re-run the same wrong assumption for
    ; every fault.
    ;
    ; So the assumption is replaced by a LOOK: greet the module again at the only
    ; other rate this ROM knows about. It costs one ESP_INIT_PASSES budget, and
    ; only on a bring-up that was already failing.
    call esp_uart_init_high
    ld hl,esp_cmd_ate0
    call esp_command_ok
.awake:
 ENDIF
    jr c,.no_bringup
    ld hl,esp_cmd_at
    call esp_command_ok
    jr c,.no_bringup

 IF ESP_BAUD_HIGH != ESP_BAUDRATE
    ; UP, IF THE MODULE WILL — issue #25. See esp_negotiate_baud.
    ;
    ; HERE, AND NOT AT THE END OF THE CHAIN, for two reasons that point the same
    ; way. The switch empties both UART FIFOs, which is what makes it atomic —
    ; and with a listener already open that would silently destroy a command a
    ; client had just sent, which is issue #11's whole family of defect. Nothing
    ; can be listening this early. And putting it first means the four commands
    ; after it are all spoken at the new rate, so a rate that is marginal rather
    ; than dead is caught by the chain rather than by a client later; that is
    ; also why esp_negotiate_baud's own fallback needs no verification of its
    ; own.
    ;
    ; It is idempotent, which is what lets the probe above leave the module up
    ; here without a special case: asking a module already at ESP_BAUD_HIGH to
    ; move to ESP_BAUD_HIGH is answered OK and changes nothing.
    call esp_negotiate_baud
 ENDIF

    ; Multiplexed mode. REQUIRED BEFORE CIPSERVER — AT+CIPSERVER=1 answers
    ; ERROR without it, and AT+CIPMUX=1 in turn forbids AT+CIPMODE=1, which is
    ; why there is no transparent byte pipe to fall back on.
    ld hl,esp_cmd_cipmux
    call esp_command_ok
    jr c,.no_bringup

    ld hl,esp_cmd_cipserver
    call esp_command_ok
    jr c,.no_bringup

    ; The module's own idle timeout — issue #24, point 11 in the header, and
    ; ESP_SERVER_TIMEOUT for the value.
    ;
    ; AFTER THE LISTENER, AND THAT ORDER IS THE WHOLE OF IT. This step used to
    ; come BEFORE `AT+CIPSERVER`, for two reasons that were sound in intent and
    ; are given up here deliberately: no client could then be accepted while the
    ; firmware's 180-second default still governed it, and — nothing being
    ; listening yet — no `<id>,CONNECT` could land inside the wait for this
    ; command's answer.
    ;
    ; IT DOES NOT WORK THERE. `AT+CIPSTO=` is refused by a module with no server
    ; running, and the refusal is silent because the wait below accepts ERROR on
    ; purpose — so the value has never been in force since issue #24 shipped it
    ; at build 00.14. Measured on the user's own Next (AT 1.2.0.0), 2026-08-11,
    ; interactively under `.UART` and with nothing of ours in the picture:
    ;
    ;   AT+CIPSTO=1800                                  -> ERROR
    ;   AT+CIPSTO=900 / =240 / =180 / =60               -> ERROR   (not the value)
    ;   AT+CIPMUX=1 ; AT+CIPSERVER=1,11000 ; AT+CIPSTO=1800 -> OK
    ;   AT+CIPSTO?                                      -> +CIPSTO:1800
    ;
    ; What it cost, before anyone thought to type that: a debuggee left running
    ; under M2's asynchronous break is silent by definition, so the module hung
    ; up on the session at the default 182 s and its `<id>,CLOSED` then broke the
    ; debuggee in — three minutes of thinking time, not thirty.
    ;
    ; WHAT THE MOVE TRADES, stated rather than discovered later. A client that
    ; connects between these two commands is governed by the 180-second default
    ; for the life of that connection; the window is one AT round trip against a
    ; timeout that otherwise applies always, which is not a close call. And a
    ; `<id>,CONNECT` can now land inside this wait — esp_read_scan captures an
    ; inbound frame rather than destroying it (issue #11) and esp_watch_line
    ; still sees the line, so the exposure is the ordinary one, not issue #10's.
    ;
    ; NEITHER ANSWER STOPS THE CHAIN. A module too old for the command says
    ; ERROR, and the only consequence is that an idle session will still be
    ; dropped at whatever that firmware's default is — a worse debugger, not a
    ; broken one, and refusing to come up over it would be strictly worse again.
    ; The answer is read rather than left on the wire, which is what keeps the
    ; rest of the chain's scans matching their own replies; nothing records
    ; which arm it was, and esp_command_ok_or_error says why not.
 IF ESP_CIPSTO_STRICT == 0
    ld hl,esp_cmd_cipsto
    call esp_command_ok_or_error
 ELSE
    ; The bench seam, never shipped: the refusal treated as a bring-up failure,
    ; which is what the two-pattern wait exists to avoid. See ESP_CIPSTO_STRICT.
    ;
    ; SINCE THE MOVE ABOVE, A STRICT FAILURE LEAVES THE LISTENER UP, because
    ; AT+CIPSERVER has already succeeded by the time this runs. K4 asserts what
    ; that build does and had to move with it — see test/run-cipsto.sh.
    ld hl,esp_cmd_cipsto
    call esp_command_ok
    jr c,.no_bringup
 ENDIF

    ; The address, for the UI. Asked for HERE rather than from show_ui because
    ; show_ui is re-entered on every redraw — the "B" key, CMD_CLOSE, an error
    ; report — and an AT round trip per redraw would be paid every time somebody
    ; pressed a key. It is also the last step on purpose: it is the only one
    ; whose failure still leaves a working listener.
    ;
    ; IT IS NO LONGER THE ONLY ASK. This comment used to end "for an answer that
    ; cannot have changed", and issue #32 is the whole of why that was wrong: the
    ; module's association can go after bring-up, and the screen went on naming
    ; an address that no longer reached the machine. esp_check_address asks again
    ; from the idle path, every ESP_ADDR_CHECK_SECS.
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
    ; address is already in hand.
    ;
    ; WHAT HAPPENS TO ANY REMAINDER DEPENDS ON THE CALLER, and this comment used
    ; to give only the bring-up one. From transport_init, main_bank_entry falls
    ; into drain_main, which discards whatever is still on the wire. From
    ; esp_check_address (issue #32) nothing drains: the idle loop simply carries
    ; on, so a leftover STAMAC line is met by the next transport_byte_available,
    ; which fails to parse it as a +IPD header and gives up on its own budget —
    ; up to ~100 ms of wasted poll on an idle debugger, no fault raised and no
    ; client affected. Benign, but it is the caller's business rather than a
    ; property of this routine.
    ;
    ; The EARLY returns above leave more than this one does — the whole tail from
    ; wherever they gave up — and are reached only when the module is already
    ; misbehaving, so the same paragraph covers them.
    ld hl,esp_str_ok
    jp esp_wait_string_hold


 IF ESP_ADDR_CHECK_TICKS > 0
;===========================================================================
; Asks the module again whether it still has the address on the screen, and
; puts the screen right — issue #32.
;
; THE DEFECT IT CLOSES. AT+CIFSR was asked exactly once, at the end of
; transport_init, so `Connect at <ip>:11000` was decided at bring-up and never
; revisited. A Next that dropped off the WiFi afterwards went on advertising an
; address that no longer reached it, and one switched on before its router was
; ready went on telling its owner to go and run wifi2.bas on a machine that was
; already set up correctly. Nothing on the screen ever changed either way, and
; from the PC side both look exactly like KNOWN-ISSUES.md #2 and issue #18 —
; states this project has already paid to learn to tell apart.
;
; ONE CALL DOES BOTH HALVES OF THE ISSUE, and that fell out rather than being
; designed. esp_query_address rewrites esp_link_state AND recomposes
; esp_connect_address from whatever the module now answers, so "detect that the
; address has gone" and "advertise the new one when it comes back" are the same
; instruction. What the issue called re-ACQUISITION — picking the listener back
; up — is not built, and the evidence for that rests on ONE observation: on a
; real Next across a five-minute AP outage the AT+CIPSERVER listener SURVIVED a
; de-association and re-association, with a full hardware bench passing 6/6
; afterwards and no M1 press or reset in between. See doc/HARDWARE-TESTING.md;
; tier `reported on hardware` — one machine, one reporter, no re-runnable
; artefact.
;
; THE EMULATOR CANNOT CORROBORATE THAT, and an earlier version of this comment
; offered it as though it could. jnext's own --help for
; --esp-delayed-disassociate-frames says "Nothing else changes: open connections
; keep running and no WIFI DISCONNECT is sent", so a probe finding the listener
; alive across the outage RESTATES a design decision of the emulator's and could
; not have come out any other way. It is not a second data point.
;
; So bench check D6 guards a STUB-SIDE regression only — a fix that retired the
; listener and rebuilt it — and can never guard a module-side one.
;
; AND THE CASE D1 IS BUILT AROUND HAS NO HARDWARE EVIDENCE ON EITHER HALF. The
; hardware run was A -> down -> A; whether a real module keeps ACCEPTING after
; its address CHANGES is unobserved, and jnext#247 records that an address
; changing across an outage has never been seen on an ESP-01 at all. If it does
; not, re-acquisition is owed for exactly that case, and the screen would then
; advertise a new address nothing is listening on — a better-disguised lie than
; the one this removes. That is the first thing to check on real hardware.
;
; WHY IT IS NOT CALLED FROM show_ui, which is where a reader will look for it
; first: show_ui is re-entered on every redraw — the border key, CMD_CLOSE, any
; error report — so an AT round trip there would be paid every time somebody
; pressed "B". That half of transport_init's old comment was always right; the
; half that was wrong is quoted at ESP_LINK_OK.
;
; A TIMEOUT LEAVES IT SAYING "NO ADDRESS" FOR ONE PERIOD, which is a real cost
; of polling and is accepted rather than worked around. esp_query_address sets
; ESP_LINK_NO_ADDRESS on entry and only clears it on success, so a module that
; simply did not answer inside the read budget flips the screen to the "no
; address" block until the next check, which puts it back because this one
; repeats. Distinguishing "no answer" from "no address" would need a fourth
; screen state and a wait that can tell silence from a refusal, for a condition
; nothing here has ever produced.
;
; THAT SELF-CORRECTION IS TRUE OF `OK -> NO_ADDRESS` AND FALSE OF
; `FAILED -> NO_ADDRESS`, and an earlier version of this paragraph claimed it
; for both — the case a real user with an absent ESP actually meets. Nothing
; repeating can undo that one, because a successful query is what would be
; needed and there is no module to answer it. The guard at the top of
; esp_check_address is what stops it arising at all; see there.
;
; THE BUFFER IS LEFT INCONSISTENT ON THE 0.0.0.0 PATH and that is safe only
; because of what is drawn. esp_query_address writes the address into
; esp_connect_address as it reads it and only appends ":<port>" and the NUL once
; it has decided the address is usable — so after an unassociated module answers
; 0.0.0.0 the buffer holds the first characters of "0.0.0.0" over the tail of
; whatever was there before. Nothing ever draws it, because esp_link_state is
; then not OK and esp_status_text_table sends the painter to the "no address"
; block instead. Anyone adding a fourth state that draws the connect line must
; read this paragraph first.
;
; Changes:
;  AF, BC, DE, HL — IX is saved, because print_char uses it as its font pointer
;  and TRANSPORT_IDLE_TICK promises its caller everything else.
;===========================================================================
esp_check_address:
    ; A FAILED BRING-UP IS NEVER REVISITED, and this guard is the whole of what
    ; stops this routine RECREATING the defect it exists to remove.
    ;
    ; esp_query_address writes ESP_LINK_NO_ADDRESS on ENTRY and clears it only on
    ; success, so calling it unconditionally overwrites ESP_LINK_FAILED with
    ; ESP_LINK_NO_ADDRESS at the first tick — and PERMANENTLY, because the only
    ; thing that sets FAILED again is transport_init, reachable from an M1 or
    ; Symbol Shift re-init or from esp_recover — and esp_recover cannot fire in
    ; this state, which takes five consecutive faults through rxtx_error.
    ;
    ; NOT because nothing here CAN reach rxtx_error: an earlier version of this
    ; said "neither esp_wait_string's timeout nor esp_send_raw reaches it", and
    ; esp_send_raw plainly does — `jp tx_timeout`, which is `jr rxtx_error`
    ; — as does esp_try_read_raw's .rx_overflow arm, which esp_wait_string reads
    ; through. Both are real paths and the enumeration was wrong twice.
    ;
    ; They cannot FIRE here, which is a different claim and the one that holds.
    ; The TX FIFO always drains: esp_uart_set_rate writes 00011000b to 0x163B, so
    ; bit 5 is clear, and uart_tx.vhd:180 leaves S_IDLE on
    ; `i_Tx_en = '1' and (i_cts_n = '0' or i_frame(5) = '0')` — the shifter starts
    ; whatever CTS does, so esp_send_try never runs out its bound. And nothing
    ; arrives to overflow the 512-byte RX FIFO, because the premise of this state
    ; is that no module is answering. Only esp_wait_string's own timeout is left,
    ; and that is a bare `ret c` which counts nothing.
    ;
    ; The PERMANENCE was measured rather than deduced from any of that: at frame
    ; 40000, thirteen query periods in, the unguarded build was still wrong.
    ;
    ; So a machine whose ESP is absent, disabled or not answering at
    ; 115200 would stop saying so after one minute and start telling a correctly
    ; set-up user to go and run wifi2.bas. Measured, one build apart, with no
    ; --esp: main keeps "ESP-01 setup failed" at frames 3000, 9000 and 40000; the
    ; unguarded build says "No WiFi address" from 9000 onwards. Bench check D7.
    ;
    ; There is also nothing to be gained by asking: the AT chain did not
    ; complete, so there is no module answering and no listener for a recovered
    ; address to reach. The two screens are doc/WIFI-SETUP.md's user diagnostic
    ; and they distinguish "your Next is not on the WiFi" from "your ESP is not
    ; there", which is exactly the distinction this must not blur.
    ;
    ; NOTE THIS IS NOT THE TIMEOUT CASE BELOW. An OK -> NO_ADDRESS flip from a
    ; module that simply did not answer in time is transient and self-correcting,
    ; because this repeats. A FAILED -> NO_ADDRESS flip is neither.
    ld a,(esp_link_state)
    cp ESP_LINK_FAILED
    ret z

    call esp_query_address

    ; A lost address goes in the error area too, which is what transport_init
    ; does for the identical condition and where a user is trained to look.
    ; NEVER OVER AN ERROR ALREADY STANDING: this runs on a timer and would
    ; otherwise be able to bury a TX Timeout or an RX Overflow that a human
    ; still needs to see. Same guard, and for the same reason, as show_ui's
    ; core-version check.
    ;
    ; It is not DRAWN here, only recorded: painting the error area means
    ; erasing whatever is in it, which is nine rows and a second painter. It
    ; reaches the screen at the next full repaint. The actionable words are on
    ; rows 6 and 7 in any case — "No WiFi address. Set the Next up first: run
    ; wifi2.bas" — and those are repainted below.
    ;
    ; AND IT IS NEVER CLEARED WHEN THE ADDRESS COMES BACK, deliberately. The OK
    ; path below falls straight to .paint, so after a lost-and-regained address
    ; rows 6/7 advertise the new one while the error area still reads "No WiFi
    ; address" until something else clears it — cmd_init does, on the next
    ; session. That is what the area is FOR: it is labelled "Last Error" and
    ; reports history, not live status, which is exactly why it must not be
    ; cleared on somebody else's behalf — the value standing there may be a TX
    ; Timeout this routine never wrote. The two rows are the live statement and
    ; they are the ones repainted.
    ld a,(esp_link_state)
    or a
    jr z,.paint
    ld a,(last_error)
    or a
    jr nz,.paint
    ld a,ERROR_NO_WIFI_ADDRESS
    ld (last_error),a

.paint:
    ; Is the debugger's own screen what is on the display? main_loop is
    ; reachable with a debuggee STOPPED and its picture up — transport_wait_rx's
    ; bound expires to main_idle, below main_redraw's show_ui — so without this
    ; a timer would paint two rows of the debugger's UI over the program being
    ; debugged. Same guard, same reason, as esp_refresh_client_line's.
    ld a,(esp_ui_shown)
    or a
    ret z

    push ix
    ; IT FORCES THE WINDOW RATHER THAN CHECKING AND ABANDONING, which is the
    ; opposite of what esp_refresh_client_line does one row along, and the
    ; difference is issue #28's own argument applied to this painter. 0x4000 is
    ; the display file only while MMU slot 2 says so and CMD_SET_SLOT lets any
    ; client move it. Abandoning is right for the session line: a stale row
    ; costs nothing until the next full repaint. It is wrong here, because a
    ; screen that goes on naming an address that does not work IS the defect,
    ; and a painter that declines to fix it whenever a client has looked at a
    ; bank would leave the machine lying for exactly as long as before.
    ;
    ; Forcing is also what makes this correct BEFORE any client has connected,
    ; which is the state it spends most of its life in: nothing has put
    ; SCREEN_BANK in slot 2 at that point except show_ui itself, which puts back
    ; whatever it found. screen_map reads NR 0x52, forces, and screen_unmap
    ; restores exactly — so no debuggee-visible state moves either way.
    ;
    ; The single save area screen_map uses is safe because this cannot nest
    ; inside show_ui: it is reached from main_loop's idle tick and from nowhere
    ; else.
    call screen_map
    ; The glyphs come from the ROM since issue #31, so this needs slot 1 too,
    ; and this is an AUTONOMOUS painter — it must hand both back on the one path
    ; out, which is why the routine has exactly one.
    call text.font_map

    ; ERASE BY BLANKING, not by drawing the old string again. The XOR trick
    ; esp_refresh_client_line uses needs the bytes that were drawn, and the
    ; string drawn here is esp_text_connect, whose tail is the mutable
    ; esp_connect_address buffer that esp_query_address has just overwritten.
    ; XORing "the old line" would XOR the NEW address off a screen holding the
    ; OLD one and leave neither — visible garbage on the one line that has to be
    ; readable. Keeping a shadow copy of the old text would be a second
    ; rendering of a buffer another routine writes in place, which is how two
    ; renderings of one fact drift apart; blanking needs no such copy and is
    ; correct for any pair of strings.
    ;
    ; Two character rows, eight scanlines, 32 columns: 0x40C0 upwards with the
    ; usual 0x100 stride, because rows 6 and 7 are adjacent within each scanline
    ; block. Both are in the screen's first third, so no third boundary is
    ; crossed and the stride does not change.
    ld hl,SCREEN + ESP_LINK_ROW*32
    ld b,8
.blank_scanline:
    push bc
    push hl
    MEMCLEARHL 2*32
    pop hl
    pop bc
    inc h
    djnz .blank_scanline

    call esp_put_status_block
    call text.font_unmap
    call screen_unmap
    pop ix
    ret
 ENDIF


;===========================================================================
; Draws WiFi mode's status block, where UART mode draws its joy-port selection.
; Called from show_ui; see the data above.
;
; Two independent things: the LINK (rows 6-7, decided at bring-up and revisited
; from the idle path since issue #32 — see esp_check_address, which calls
; esp_put_status_block below to repaint exactly these two rows) and
; the SESSION (row 8, from CMD_INIT/CMD_CLOSE). They are drawn from separate
; tables because they answer separate questions — "where do I connect" and "did
; anyone" — and neither state constrains the other. Both strings begin with
; their own AT, so the second does not depend on where the first ended.
; Changes:
;  AF, BC, DE, HL
;===========================================================================
esp_show_status:
 IF ESP_BAUD_HIGH != ESP_BAUDRATE
    ; The rate, at row 3 where data_const.asm's "ESP Baudrate: " label stopped.
    ; Drawn rather than assembled because this build has two rates it can be at;
    ; see ESP_BAUD_IS_LOW. Safe to draw with no erase because show_ui has just
    ; MEMCLEARed the screen — this is show_ui's only caller — and the shorter of
    ; the two numbers can therefore never leave a digit of the longer behind.
    ld hl,esp_baud_text_table
    ld a,(esp_baud_state)
    add a                       ; *2
    add hl,a
    ld de,(hl)
    call text.ula.print_string
 ENDIF
    ; A CALL AND NOT A FALL-THROUGH, because the fall-through below it is
    ; already spoken for: this routine's whole shape is "the link block, then
    ; the session line", and esp_show_client_line has to stay the next thing
    ; executed.
    call esp_put_status_block
    ; Flow through


;===========================================================================
; Draws the session line, row 8, ONTO A BLANK ROW.
;
; A separate entry point because esp_refresh_client_line redraws that row on its
; own when the connection-line observer has invalidated it between two show_ui
; calls (issue #23). Reached from show_ui, which has just MEMCLEARed the whole
; screen, so there is nothing to erase here.
;
; Every path through here leaves the row agreeing with esp_client_state, which
; is what lets the dirty flag be cleared unconditionally rather than only on the
; path that noticed it was set.
; Changes:
;  AF, BC, DE, HL
;===========================================================================
esp_show_client_line:
    ; WHAT 0x4000 MEANS RIGHT NOW, recorded so that a later redraw can check it
    ; has not changed. Taken here because this is reached from show_ui, which has
    ; just MEMCLEARed the screen through that same window — so whatever slot 2
    ; holds at this instant is, demonstrably, the memory the UI is being drawn
    ; into. NR 0x50-0x57 read back the live MMU registers (zxnext.vhd:6059-6081,
    ; returning the same MMUn that decodes CPU addresses at :2952-2964), which is
    ; a mechanism this stub already uses — send_ntf_pause reads a slot's bank the
    ; same way to report it.
    ld a,REG_MMU+2
    call read_tbblue_reg
    ld (esp_ui_bank),a
    ; Nothing is owed after this, and the debugger's own screen is what is on
    ; the display — the second of those is what lets the refresh below draw over
    ; it later without landing on a debuggee's picture.
    xor a
    ld (esp_ui_dirty),a
    inc a
    ld (esp_ui_shown),a
    ld a,(esp_client_state)
    ld (esp_client_drawn),a
    ; Flow through


;===========================================================================
; Prints the session line for the state in A, and keeps no bookkeeping.
;
; Parameter:
;  A = one of the ESP_CLIENT_* states.
; Changes:
;  AF, BC, DE, HL
;===========================================================================
esp_put_client_line:
    ld hl,esp_client_text_table
    add a                       ; *2
    add hl,a
    ld de,(hl)
    jp text.ula.print_string


;===========================================================================
; Prints the link status block — rows ESP_LINK_ROW and the one below — for
; whatever esp_link_state currently says, and keeps no bookkeeping.
;
; A ROUTINE OF ITS OWN SINCE ISSUE #32, where it was six instructions inline in
; esp_show_status, because it has a second caller: esp_check_address repaints
; those two rows on a timer. It is CALLED from esp_show_status rather than
; flowed into, and it sits down here rather than up there, for the same one
; reason — esp_show_status's fall-through is esp_show_client_line's and must
; stay so. A status painter that flowed on into the session line would XOR that
; line off row 8 every time the timer fired.
;
; IT DRAWS ONTO WHATEVER IS THERE. show_ui has just MEMCLEARed the screen and
; esp_check_address has just blanked these two rows, so both callers arrive with
; them empty; the glyphs are XORed on (text.asm), so drawing over a non-blank
; row would leave a mixture of the two strings and not the second one. Anyone
; adding a third caller owes it the same.
; Changes:
;  AF, BC, DE, HL, IX
;===========================================================================
esp_put_status_block:
    ld hl,esp_status_text_table
    ld a,(esp_link_state)
    add a                       ; *2
    add hl,a
    ld de,(hl)
    jp text.ula.print_string


;===========================================================================
; Redraws the session line if the observer has invalidated it — issue #23.
;
; WHY NOT WHERE THE OBSERVATION HAPPENS: see esp_line_event. The observer only
; records; this is where the record reaches the screen on the paths that do not
; repaint by themselves. The other path needs nothing — a scan that meets a
; `<id>,CLOSED` and then finds no header times out into drain_main, whose
; show_ui draws the row and clears the flag on the way past.
;
; IT IS CALLED ONLY WHERE THE MODULE HAS JUST SPOKEN, which is what keeps it off
; the hot path entirely: main_loop spins on transport_byte_available thousands
; of times a second and an observation can only have happened on the one branch
; that ran a scan. A quiet wire costs nothing at all.
;
; AND ONLY WHILE OUR OWN SCREEN IS UP. main_loop is reachable with a debuggee
; stopped and ITS display on the screen — transport_wait_rx's bound expires to
; main_idle, which is below main_redraw's show_ui — so without esp_ui_shown this
; would paint one row of the debugger's UI over the program being debugged.
;
; AND ONLY WHILE 0x4000 STILL MEANS WHAT IT MEANT WHEN THE ROW WAS DRAWN, which
; is a SECOND guard and not a restatement of the first. AN EARLIER VERSION OF
; THIS COMMENT CLAIMED THEY WERE THE SAME FACT — that esp_ui_shown could not be
; set while the mapping was wrong, because show_ui MEMCLEARs through the same
; window. That is false, and the counterexample is an ordinary DZRP command:
;
;     CMD_INIT                  -> show_ui runs, esp_ui_shown := 1
;     CMD_SET_SLOT 2,<bank X>   -> commands.asm's self-modifying `nextreg
;                                  REG_MMU+<slot>` retargets slot 2, and touches
;                                  nothing this file reads
;     the client's connection is reported <id>,CLOSED while the stub is idle
;
; which is N4/N5's scenario with one command in between. The guard would still
; read 1, and this routine would XOR the session line INTO BANK X — permanently,
; since no per-bank backup exists (only slot_backup.slot0 and .slot7 are saved),
; and visibly to the debuggee afterwards. A network-triggered writer with no
; backstop, which is what the independent review of this branch rejected.
;
; SO IT ASKS THE MACHINE INSTEAD OF TRACKING EVENTS THAT IMPLY THE ANSWER.
; NR 0x52 reads back the live MMU2 (zxnext.vhd:6059-6081, :2952-2964), so the
; question "does 0x4000 still address what it addressed when I drew this row"
; is answerable directly, in ten bytes, from inside this file.
;
; WHY NOT A MACRO FROM cmd_set_slot, which is the shape issue #14 established
; and the reviewer's own first preference. Two reasons, and the second is the
; one that decided it. It would put transport-specific state into commands.asm,
; which CLAUDE.md's hard rule says must not be able to tell which transport it
; was assembled against. And it would only be correct for as long as the
; enumeration behind it stayed correct: there are FORTY `nextreg REG_MMU...`
; sites across eight files in this tree, one of them self-modifying and able to
; write any slot, and a macro has to be invoked from every present and future
; one that can leave slot 2 elsewhere. ERRORS.md already carries that failure
; twice — "Enumerating a control flow's exits by reading the ones you expected"
; and "Clearing a flag in the obvious routine, which one caller bypasses". A
; register read cannot be forgotten by the next person to add an MMU write.
;
; WHAT WAS NOT FIXED HERE HAS SINCE BEEN FIXED THERE — issue #28. show_ui had
; the same hazard and was older and larger: it opens with a MEMCLEAR of the
; whole screen area, so through a retargeted slot 2 it wiped 7392 bytes of that
; bank rather than one row of it. It was reported rather than fixed on a branch
; scoped to issue #23, and #28 closed it the other way round — ui.asm's
; screen_map FORCES the window and restores it, because show_ui is the
; debugger's own screen and abandoning a repaint of that would leave the machine
; showing nothing. Abandoning is still right here, for the reason above: one
; stale row until the next full repaint costs nothing.
;
; (That paragraph also said the defect "needs a human at the machine". It did
; not: `jp main` from cmd_close reaches the same main_redraw, and DeZog sends
; CMD_CLOSE on every Shift+F5. Bench N8 uses that, and no key is pressed.)
;
; THE OLD LINE IS ERASED BY DRAWING IT AGAIN, and that is not a trick to be
; clever with: text.asm's ula.print_char XORs its glyph onto the screen
; (text.asm:100-108), so a second string written over a first leaves neither.
; Measured, not reasoned — bench N5 read back `????e? ?l????I???e` from the first
; version of this routine, which drew the new line straight over the old. show_ui
; never has this problem because it clears the whole screen first; this is the
; one caller that does not. esp_client_drawn is what says which string is up
; there, and every writer of the row maintains it.
; Changes:
;  AF, BC, DE, HL
;===========================================================================
esp_refresh_client_line:
    ld a,(esp_ui_dirty)
    or a
    ret z
    ld a,(esp_ui_shown)
    or a
    ret z
    ; Does 0x4000 still address what it addressed when this row was drawn? If a
    ; client has retargeted slot 2 — CMD_SET_SLOT — the answer is no and the
    ; redraw is ABANDONED, not adapted: esp_ui_dirty is deliberately left set, so
    ; the row is put right by the next show_ui instead, which draws through a
    ; window it has just proved by clearing.
    ld a,REG_MMU+2
    call read_tbblue_reg
    ld hl,esp_ui_bank
    cp (hl)
    ret nz
    ; IX, because text.asm's ula.print_char uses it as its font pointer and
    ; transport_byte_available — the one caller — promises its own callers AF
    ; and nothing else. Inside the two tests above, so a quiet poll does not pay
    ; for it.
    push ix
    ; Since issue #31 the glyphs come from the ROM, so this needs the same window
    ; show_ui does — and this is the AUTONOMOUS painter, driven by the network
    ; from main_loop's poll, so it must hand it back on the one path out. It has
    ; exactly one, below, unlike show_ui's body.
    call text.font_map
    ld a,(esp_client_drawn)
    call esp_put_client_line    ; XOR the old line off
    call esp_show_client_line
    call text.font_unmap
    pop ix
    ret


;===========================================================================
; CMD_INIT was received: a debug client has opened a session.
;
; Invoked by TRANSPORT_CLIENT_ATTACHED, from cmd_init, BEFORE its show_ui — so
; the redraw there is the one that draws the line and nothing here repaints on
; its own account.
;
; esp_cmd_id AND NOT esp_conn_id. The two are the same at this instant and stop
; being so a moment later: esp_cmd_id names the connection whose COMMAND this is
; (issue #13) and is fixed for as long as CMD_INIT takes to receive, where the
; live id follows whatever arrives next — a second client's frame included. The
; session belongs to the client that asked for it.
; Changes:
;  AF
;===========================================================================
esp_client_attached:
    ld a,ESP_CLIENT_ATTACHED
    ld (esp_client_state),a
    ld a,(esp_cmd_id)
    ld (esp_session_id),a
    ld a,1
    ld (esp_session_valid),a
    ret


;===========================================================================
; CMD_CLOSE was received: the client closed the session cleanly.
;
; THE OBSERVER IS SWITCHED OFF FOR THIS SESSION HERE, and it has to be. A client
; that says CMD_CLOSE almost always drops its socket a moment afterwards, and
; the `<id>,CLOSED` that follows would otherwise overwrite "Session closed -
; CMD_CLOSE" with "Session lost - client gone" — replacing what the client said
; with a weaker inference about the same event. Bench check N3 is what would go
; red.
; Changes:
;  AF
;===========================================================================
esp_client_detached:
    ld a,ESP_CLIENT_DETACHED
    ld (esp_client_state),a
    xor a
    ld (esp_session_valid),a
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
    call esp_wait_string_hold
    ret nc
    ld a,ERROR_RX_TIMEOUT
    scf
    ret


;===========================================================================
; Sends a command and waits for OK or ERROR, treating NEITHER as a failure.
; Issue #24, and point 11 in the header.
;
; WHY NOT esp_command_ok. That waits for "OK" alone, so a refusal is
; indistinguishable from silence and costs the full read budget — the whole of
; ESP_INIT_PASSES, ~2 s at bring-up — before saying so, and then says the wrong
; thing: `jr c,.no_bringup` would abandon a module that had just answered
; perfectly clearly. AT+CIPSTO's refusal is an ordinary answer from an older
; firmware, and a debugger that declined to start over it would be worse than
; one whose sessions time out.
;
; THE MATCHER IS THE SAME NAIVE RESTART esp_wait_string USES, generalised to two
; patterns by committing on the first character: a byte that is not inside a
; pattern selects one by being 'O' or 'E', and a mismatch inside a pattern
; re-offers THAT byte to the same choice. One cursor, because esp_read_scan
; preserves only HL and a second would have had to live in memory.
;
; IT IS NAIVE IN THE SAME WAY esp_wait_string IS — USUALLY RIGHT, NOT EXACT —
; AND AN EARLIER VERSION OF THIS COMMENT CLAIMED A PROOF THAT DOES NOT HOLD.
; It argued that neither pattern repeats its own first letter, so a restart
; always recovers, and offered "ERROK\r\n" as an example that still matches OK.
; It does not: that input returns a TIMEOUT. Traced, and reproduced by an
; independent simulation of this routine's control flow.
;
; The hole is CROSS-pattern, which is exactly what a self-overlap argument
; cannot see: "ERROR"'s fourth character is 'O', the leading character of
; "OK\r\n". In "ERROK" the 'O' is consumed as a body match at ERROR[3], so it is
; never re-offered to the choice above, and the 'K' that follows restarts
; nothing. ("EOK\r\n" *does* match, because there the mismatch happens at
; ERROR[1] and the 'O' is re-offered — which is why the wrong claim looked
; right.) A proper two-pattern matcher would need to back up over bytes already
; consumed, which this one cannot do.
;
; SO WHAT MAKES IT SAFE HERE IS THE WINDOW, NOT THE MATCHER. Between this
; command and its answer the module sends exactly one clean line — "\r\nOK\r\n"
; or "\r\nERROR\r\n" — and nothing else is expected, which is what jnext's own
; esp01 log shows for every run of test/run-cipsto.sh. Neither line contains a
; sequence that can strand the other.
;
; **A CALLER IN A NOISIER WINDOW MUST NOT ASSUME THIS.** The routine is written
; to be reusable and issue #25 is the second caller; anything that can put
; module chatter between the command and its answer needs this re-examined, not
; trusted. That is the whole reason the counter-example above is spelled out
; rather than summarised.
;
; It captures, like every other wait here — esp_scan_hold — so an inbound frame
; met mid-scan is held rather than destroyed (point 8). The flag is set
; UNCONDITIONALLY rather than on the caller's assurance that nothing can be
; listening: transport_init does send AT+CIPSTO before AT+CIPSERVER, but that
; only holds for a FIRST bring-up. Symbol Shift + M1 reaches init_main_bank from
; nmi66h's keyboard test (mf_rom.asm:136-139), which runs BEFORE the
; PRGM_RUNNING test, so the chain can re-run with an earlier listener up and a
; client still connected. Harmless, and only because the flag does not depend on
; the claim — which is the property to preserve if a second caller appears.
;
; WHAT IS LEFT ON THE WIRE, on the ERROR arm: the two bytes of the trailing CRLF,
; because esp_str_error carries none — see the note beside it. That is safe here
; for the same reason it is safe in esp_wait_prompt: the next step in the chain
; is another scan, and a scan skips what it is not looking for. AT+CIPSERVER's
; wait for "OK\r\n" steps over CR and LF without matching either.
;
; IT REPORTS NOTHING, AND THE FIRST VERSION OF IT DID — a byte recording which
; arm was taken. It was dropped rather than kept, because nothing read it and
; nothing here CAN: no bench reads the debugger's own RAM, and the value is not
; drawn. A byte whose only justification is a distinction that nothing can make
; is residue, and residue outlives its reason. If a refusal should be visible —
; and it should, since it means an idle session will still be dropped at the
; firmware's own default — the place is this file's own WiFi status block, which
; would not move the UART ROM, and it wants its own issue and its own check.
;
; SO WHAT DOES THE WAIT BUY, IF IT RECORDS NOTHING? Two things, and only the
; second is checked here:
;
;   * IT KEEPS THE CHAIN SYNCHRONOUS. Fire-and-forget leaves the module's answer
;     in the RX FIFO, so AT+CIPSERVER's own wait for "OK\r\n" matches the OK
;     that belongs to AT+CIPSTO, and every answer for the rest of bring-up is
;     off by one. That is the desynchronisation class this transport has already
;     been bitten by twice, and it is REASONED here rather than measured: see
;     the NOT COVERED note in test/run-cipsto.sh, which records that the bench
;     passes 4 of 4 against a fire-and-forget build.
;   * IT BOUNDS THE COST OF A REFUSAL AND DOES NOT ACT ON IT. esp_command_ok
;     spends the whole of ESP_INIT_PASSES and then abandons bring-up — measured,
;     as bench check K4, where AT+CIPSERVER is never sent and nothing listens.
;
; Parameter:
;  HL = NUL-terminated command, CRLF included.
; Returns:
;  Nothing. There is no carry contract and no state: both answers are ordinary,
;  and the caller has no decision to make either way.
; Changes:
;  AF, BC, DE, HL
;===========================================================================
esp_command_ok_or_error:
    call esp_send_string
    ld a,1
    ld (esp_scan_hold),a
.hunt:
    call esp_read_scan          ; A = the byte read; HL is preserved
    ret c                       ; silence: neither answer came, and neither acts
.classify:
    ; Does this byte start either pattern? One cursor, because only HL survives
    ; esp_read_scan. It is NAIVE and not exact — a byte already consumed as a
    ; body match is never re-offered here, so "ERROK\r\n" strands rather than
    ; matching OK. Safe because of the window, not the matcher; see the header.
    ld hl,esp_str_ok+1          ; the 'O' has just been consumed
    cp 'O'
    jr z,.body
    ld hl,esp_str_error+1       ; likewise the 'E'
    cp 'E'
    jr nz,.hunt
.body:
    ld a,(hl)
    or a
    ret z                       ; the whole of one pattern matched
    call esp_read_scan
    ret c
    cp (hl)
    jr nz,.classify             ; a mismatching byte may start a pattern itself
    inc hl
    jr .body


;===========================================================================
; UART bring-up: 8N1, the ESP uart selected, and one of the two rates this
; build knows about programmed into the prescaler.
;
; The prescaler is Fsys/baud (ports.txt, 0x143B) and Fsys depends on the video
; timing in NR 0x11, so the divisor is looked up rather than assumed. It goes
; out in two 7-bit halves, bit 7 selecting which; the three further MSBs ride
; along with the uart selection and are zero for every entry in the tables.
;
; TWO ENTRY POINTS, AND THE SECOND IS NOT A CONVENIENCE — issue #25. A rate
; survives everything the machine can do to itself: a Z80 soft reset leaves the
; peripheral's prescaler exactly where it was, because zxnext.vhd:3361-3367 ties
; the UART's i_reset_hard to the constant '0' and serial/uart.vhd:313-320 gates
; the prescaler's default on i_reset_hard ALONE. So after a reset both ends are
; still up there, and the M1 press that follows must not assume otherwise; see
; transport_init, which greets the module at both rates rather than at one.
;
; THESE TWO ROUTINES ARE THE ONLY WRITERS OF esp_baud_state, which is what makes
; that byte — and so the rate the screen names — true by construction rather
; than by a promise somebody has to keep.
; Changes:
;  A, BC, DE, HL
;===========================================================================
esp_uart_init:
    ld hl,esp_prescaler_table
 IF ESP_BAUD_HIGH != ESP_BAUDRATE
    xor a
    ld (esp_baud_state),a
    jr esp_uart_set_rate

esp_uart_init_high:
    ld hl,esp_prescaler_table_high
    ld a,ESP_BAUD_IS_HIGH
    ld (esp_baud_state),a
 ENDIF

;---------------------------------------------------------------------------
; HL = the prescaler table to use.
;---------------------------------------------------------------------------
esp_uart_set_rate:
    ; BOTH ENGINES ARE HELD ACROSS THE THREE WRITES BELOW, and that is the
    ; whole of what makes a rate change atomic on this side.
    ;
    ; There is no double buffering and no commit strobe anywhere in
    ; serial/uart.vhd: uart_select_wr, uart_rx_wr and uart_frame_wr each drive
    ; an independent directly-clocked register, so between the select and the
    ; two halves of the divisor the live value (:404, :464) is a MIXTURE of old
    ; and new bits. A receiver that saw a start bit in that window would latch
    ; the mixture and frame garbage out of a good byte.
    ;
    ; Bit 7 of the frame register closes the window, and it does exactly three
    ; things, all of them wanted: it holds the transmitter at S_IDLE and the
    ; receiver at S_PAUSE (uart_tx.vhd:166-172, uart_rx.vhd:216-224); it empties
    ; BOTH FIFOs (uart.vhd:385, :570 -> :424, :491), which discards whatever the
    ; old rate left half-read; and it does NOT touch the prescaler, because
    ; uart_frame_wr appears in neither prescaler process. The last of those is
    ; the one this depends on and it is structural, not incidental.
    ;
    ; Bytes already in flight are safe without any of this — each engine copies
    ; the divisor only while it is idle and freezes it for the frame — so what
    ; is being closed is the window between frames, not a mid-byte one.
    push hl
    ld bc,UART_FRAME
    ld a,10011000b
    out (c),a

    ; bit 6 = 0: the ESP uart, and it is bit 6 of THIS write that names which
    ; uart's MSBs bit 4 writes (uart.vhd:279-287). bit 4 = 1: bits 2:0 are the
    ; prescaler's three most significant bits, and they are 0 — the ASSERTs
    ; beside the tables are what keep every entry inside the 14 bits that
    ; leaves. The select is a latched register and stays put afterwards, so it
    ; must be the most recent one before the two 0x143B writes below.
    ld bc,UART_SELECT
    ld a,00010000b
    out (c),a

    ; Fsys index = NR 0x11 bits 2:0
    ld a,REG_VIDEO_TIMING
    call read_tbblue_reg
    and 0111b

    ; two bytes per entry
    add a,a
    ld d,0
    ld e,a
    pop hl
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

    ; Release both engines: 8 bits, one stop bit, no parity, no flow control.
    ; This write is load-bearing rather than a restoration of a default — the
    ; framing register resets to 0x18 on i_reset_hard only (uart.vhd:294-308),
    ; the same input that is tied to '0' here, so nothing at run time ever puts
    ; it back by itself.
    ld bc,UART_FRAME
    ld a,00011000b
    out (c),a
    ret


 IF ESP_BAUD_HIGH != ESP_BAUDRATE
;===========================================================================
; Asks the module to move up to ESP_BAUD_HIGH, and comes back down if it will
; not or if the link does not survive the move. Issue #25, point 12 in the
; header.
;
; THE MODULE HAS TO AGREE IN SO MANY WORDS BEFORE THIS SIDE MOVES, and that is
; the whole of the safety argument. esp_command_ok is what says so: it waits for
; "OK\r\n" ALONE, so a refusal — an older firmware without AT+UART_CUR, or one
; that dislikes the rate — comes back as carry, exactly as silence does. Both
; mean DO NOT MOVE, and conflating them is deliberate rather than a shortcut:
; a refusal is proof the module is still at ESP_BAUDRATE, and silence is no
; evidence at all, so the conservative reading is right for both.
;
; THIS STEP DOES NOT INHERIT esp_command_ok_or_error's CAVEAT, and it is worth
; saying so explicitly because that routine's header names issue #25 as its
; second caller. It has none: this is a ONE-pattern wait, and the hole there is
; a CROSS-pattern one — "ERROR"[3] being "OK"[0].
;
; The single pattern is exact against ANY input rather than against a clean
; window, which is a stronger property than the CIPSTO step has. "OK\r\n" has no
; proper border: 'K', CR and LF are none of them 'O', so its failure function is
; all zeros, and naive restart with the mismatching byte re-offered is then
; exactly correct. The match can be DELAYED by whatever else is on the wire; it
; cannot be lost.
;
; That matters because this window is not always as quiet as the chain suggests.
; On a first bring-up nothing is listening — AT+CIPSERVER has not been sent — but
; Symbol Shift + M1 and esp_recover both re-enter transport_init with a listener
; already up, so `+IPD`, `<id>,CONNECT` and `<id>,CLOSED` can all land here. None
; of them can strand the matcher, and a `+IPD` is held rather than eaten
; (esp_scan_hold, point 8).
;
; AND EVERY ARM LEAVES THE FIFO EMPTY, so the next step in the chain reads a
; clean stream: the agreeing arm consumes exactly "OK\r\n"; the refusing and
; silent arms scan until their budget expires, which drains whatever came,
; trailing CRLF included; and the fallback arm's esp_uart_init empties both FIFOs
; on the way past.
;
; NOTE THIS IS THE OPPOSITE CHOICE FROM AT+CIPSTO's, one step down the same
; chain, and the reason is that the two commands are answering different
; questions. A refused CIPSTO changes nothing about how to talk to the module,
; so paying the whole read budget to learn about it would be waste, and
; esp_command_ok_or_error exists to avoid that. A refused UART_CUR decides
; whether this side is about to reprogram its own prescaler, so the budget buys
; the decision. (esp_command_ok_or_error could not be used here even if the cost
; were acceptable: it reports which arm was taken to nobody.)
;
; AND IT LEAVES THE STREAM SYNCHRONOUS ON EVERY ARM, which matters more here
; than anywhere else in this chain because the arms straddle a rate change and
; a leftover byte would have been TRANSMITTED at one rate and READ at another.
; On the agreeing arm it consumes "OK\r\n" and no more. On the refusing and the
; silent arms it scans until its budget runs out, which drains whatever came,
; and this side never moves — so AT+CIPMUX after it reads a clean FIFO at the
; rate its answer was sent at. On the fallback arm the two spent verifications
; have drained theirs, and esp_uart_init empties both FIFOs on the way past
; anyway.
;
; WHAT HAPPENS IF THE MODULE MOVED AND ITS `OK` WAS LOST: this side stays down
; here, AT+CIPMUX gets no answer, and bring-up fails visibly with "ESP-01 setup
; failed". It is NOT a wedge — the next M1 press probes both rates and finds it
; (transport_init) — but it does cost that press, and it is the one case where
; reading the refusal apart from the silence would have saved a bring-up.
; Changes:
;  AF, BC, DE, HL
;===========================================================================
esp_negotiate_baud:
    ld hl,esp_cmd_uart_high
    call esp_command_ok
    ret c                       ; refused, or nothing came back: stay put

    call esp_uart_init_high

    ; TWICE, BECAUSE THE FIRST ONE CAN BE SPOKEN INTO A DEAF MODULE. ESP-AT
    ; answers OK and only then reconfigures its own UART, and nothing we trust
    ; documents how long that takes — so an `AT` sent immediately afterwards may
    ; simply not be heard, and a single attempt would read that as "the rate does
    ; not work" and give up on one that does. The second attempt is sent a whole
    ; read budget later, by which time a module that was ever going to be ready
    ; is. Nothing here can measure the real figure; jnext's module has no
    ; reconfiguration to do at all.
    ld b,ESP_BAUD_TRIES
.verify:
    push bc
    ld hl,esp_cmd_at
    call esp_command_ok
    pop bc
    ret nc                      ; it answered up here: the link is the new rate
    djnz .verify

    ; It did not. Go back to where a module that never heard us still is, and
    ; where one that DID hear us is not — the rest of the chain is what notices
    ; the difference, and it does not need a probe of its own to do it.
    jp esp_uart_init
 ENDIF


;===========================================================================
; The debugger is taking over; make the link usable.
;
; UART0's RX comes from the ESP-01 pin whenever joy IO mode is off
; (zxnext.vhd:3340: `uart0_rx <= joy_uart_rx when joy_iomode_uart_en = '1' ...
; else i_UART0_RX`; :3536 for the enable). That is the power-on state, but a
; debuggee that used the joy-port serial itself would have moved it, and the
; link would then be silently dead. Writing 0 here removes that dependency.
;
; IT ALSO RECLAIMS THE UART SELECT, AND WITHOUT THAT THE POLL'S GUARD WOULD BE
; HALF A FIX (issue #42). transport_init points 0x153B at UART0 exactly once,
; when MAIN is first entered; nothing has re-established it since. So a debuggee
; that moved the pointer to reach UART1 and then stopped — at a breakpoint, on
; the button, or through the poll's own break-in — would hand the debugger a
; link whose every read and write went to the Pi header, and the session would
; be mute rather than merely unbreakable. Guarding the poll alone would
; therefore have converted "Pause does nothing" into "Pause stops the machine
; and the debugger never speaks again", which is worse.
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
; defect one register along. See doc/ASYNCHRONOUS-BREAK-DESIGN.md §8.5.
;
; It is also where a bring-up failure is put back into last_error: transport_init
; runs before main_bank_entry falls into drain_main, which zeroes it. Guarded on
; esp_init_error so the breakpoint and NMI paths, which also call this, cannot
; overwrite a real error with a stale one.
; Changes:
;  AF, BC   (BC is new with the select reclaim above; the UART build's
;            transport_activate has always changed AF, BC and HL, and it is
;            called from the same three sites, so no caller can depend on it)
;===========================================================================
transport_activate:
    nextreg REG_JOYSTICK_IO_MODE,0

    ; Reclaim the UART select before anything uses the link. Bit 4 clear, so
    ; only the channel moves and neither prescaler is touched.
    ld bc,UART_SELECT
    ld a,UART_SELECT_OURS
    out (c),a

    ld a,(esp_init_error)
    or a
    ret z
    ld (last_error),a
    ret
