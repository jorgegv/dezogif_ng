;===========================================================================
; transport.asm
;
; Selects the transport implementation. Everything above this file — the DZRP
; command layer, the message framing, the breakpoint code — talks to the
; interface below and must not be able to tell which implementation it was
; assembled against.
;
; The interface, in two halves:
;
;   Byte stream (subroutines, called from common code)
;     transport_read_byte           A = next byte, blocking with a timeout
;     transport_write_byte          send A
;     transport_byte_available      NZ = a byte is waiting
;     transport_wait_rx             block until a byte is waiting
;     transport_flush               block until everything queued has gone out
;     transport_drain               discard anything pending (100ms quiet)
;     transport_drain_with_timeout  same, DE = timeout
;     transport_poll_traffic        NZ = the link has something for us. O(1),
;                                   AF-only, and called from inside an NMI —
;                                   see below
;
;   A read or write that times out does NOT return to its caller. It jumps to
;   the implementation's timeout handler, which stores an error and re-enters
;   the main loop via drain_main. Every caller above already depends on that —
;   none of them check for a timeout — so a second implementation has to
;   preserve it rather than returning an error code.
;
;   transport_poll_traffic IS NOT A CHEAPER transport_byte_available, AND THE
;   DIFFERENCE IS ITS WHOLE JUSTIFICATION. It is called by mf.asm's mf_nmi_poll,
;   from inside the NMI the asynchronous break raises ~50 times a second while
;   the DEBUGGEE is running (issue #22), so it is bound by three things the
;   ordinary poll is not:
;
;     * O(1), ALWAYS. It may read status registers and its own variables and
;       nothing else. It must never scan, parse or wait — esp_sync_ipd can spend
;       ~100 ms, and 100 ms inside an NMI fifty times a second is not a poll.
;     * AF ONLY. BC, DE and HL belong to the interrupted debuggee. (BC is on the
;       MF stack at the call site, but the contract is stated at its narrowest so
;       a future caller cannot be surprised.)
;     * IT MAY NOT CONSUME. A byte it reported must still be there for cmd_loop.
;
;   The cost of those bounds is that it answers "is there a byte", not "is there
;   a command", so an ESP module's unsolicited line reads as traffic. That is a
;   decision with a user-visible consequence and it is argued at mf_nmi_poll.
;
;   AND IT COSTS A DIAGNOSTIC, WHICH IS A SECOND COST AND NOT THE SAME ONE.
;   Reading the UART status register clears the STICKY RX overflow and framing
;   bits (serial/uart.vhd:530-539 — the flags are cleared on `uart0_tx_rd_fe`,
;   the falling edge of a read of 0x133B). mf_nmi_poll asks its prgm_state
;   question first, which keeps this away from a RACE with the debugger's own
;   reads — but it does NOT stop the poll extinguishing an overflow that
;   happened while the debuggee was RUNNING. At ~50 reads a second, an overflow
;   during a free run is very unlikely to survive long enough for anything to
;   report it, so `Last Error: RX Buffer overflow` will in practice never be
;   seen for one.
;
;   That is a lost DIAGNOSTIC, not a lost correctness guarantee: the bytes are
;   already gone when the flag is set, and their loss still surfaces — as a DZRP
;   desynchronisation or a timeout — by exactly the routes it would have anyway.
;   What is lost is being told WHICH fault it was. Nothing here covers it, and no
;   run stages an overflow while a debuggee runs.
;
;   Lifecycle (called at the points where the debugger takes and gives back
;   the machine)
;     transport_init                once, when MAIN is first entered
;     transport_activate            debugger is taking over; make the link usable
;     TRANSPORT_DEACTIVATE          macro: debugger is resuming the debuggee
;
;   Framing (macros, so that a transport which needs neither costs nothing)
;     TRANSPORT_MESSAGE_START       before the first byte of a response or
;                                   notification. The 0xA5 preamble lives here:
;                                   required over serial, forbidden over a
;                                   socket — see transport_uart.asm.
;     TRANSPORT_END_MESSAGE         after the last byte of one. Where a
;                                   transport that must announce a frame's
;                                   length before its bytes sends the frame.
;
;   Session events (macros, for the same reason)
;     TRANSPORT_CLIENT_ATTACHED     CMD_INIT was received: a debug client has
;                                   just opened a session
;     TRANSPORT_CLIENT_DETACHED     CMD_CLOSE was received: it closed one
;
;   Housekeeping (a macro, for TRANSPORT_DEACTIVATE's reason)
;     TRANSPORT_IDLE_TICK           main_loop went round once with nothing to
;                                   do: the debugger is idle
;
;   These exist so the transport can SAY SO on the Next's own screen, which is
;   the one channel the PC side does not have (issue #14). They are macros, and
;   the interface's rule about common code is why: cmd_init and cmd_close are in
;   commands.asm, which must not be able to tell which transport it was
;   assembled against, so the mode-specific part cannot be an `IF ROM_VARIANT`
;   there. A transport with nothing to report expands them to nothing, and the
;   UART build's bytes do not move.
;
;   THEY REPORT EVENTS, NOT A LIVE CONNECTION. CMD_INIT and CMD_CLOSE are the
;   only two moments a transport ABOVE THE BYTE STREAM can observe, and neither
;   is TCP: a socket can be open before the first and after the second, and a
;   client that vanishes without CMD_CLOSE produces neither. Whatever an
;   implementation draws must therefore claim only what these two prove — see
;   esp_client_state in transport_esp.asm, where the wording is chosen for
;   exactly that reason.
;
;   A transport is free to learn more from BELOW, and the ESP one now does: it
;   watches the module's `<id>,CONNECT` / `<id>,CLOSED` lines and matches them
;   against the connection CMD_INIT arrived on, so a client that vanishes is
;   reported instead of leaving the screen claiming a session that ended
;   (issue #23). That is entirely inside the implementation — these two events
;   are still the only thing common code hands it, and a transport with no such
;   channel simply says less.
;
;   AF is free at both call sites (commands.asm), so an implementation may use
;   it without saving; nothing else is.
;
;   TRANSPORT_IDLE_TICK exists because a transport can own resources ON THE
;   OTHER SIDE OF THE WIRE that common code knows nothing about and that leak
;   without a peer to free them — the ESP's inbound connection slots, which a
;   client that vanishes without closing keeps until something asks the module
;   to let go (issue #24). Nothing above the byte stream can see such a thing,
;   and nothing below it has a moment at which to act, so the idle loop is where
;   the transport is handed one. A transport with no such resource expands it to
;   nothing, which is what UART mode does.
;
;   IT IS NOT A CLOCK AND NOTHING MAY ASSUME A RATE. main_loop runs as fast as
;   it runs, and transport_byte_available can spend ~100 ms inside one turn of
;   it, so an implementation that needs elapsed time must measure it — see
;   esp_idle_tick, which reads the free-running video line counter rather than
;   counting turns.
;
;   BC and DE are the border-colour timer and are pushed at the top of the loop,
;   so an implementation may use them; AF and HL are free outright.
;
; The lifecycle deactivate is a MACRO, not a subroutine, because the one place
; that needs it is already inline in the resume path (`backup.asm`) and a call
; there would cost bytes and a stack slot in a routine that has neither to
; spare. It expands to nothing in a transport that has nothing to hand back.
; The two framing macros are macros for the same reason: both expand to nothing
; in one of the two implementations, and a CALL to an empty subroutine on every
; message would be a cost paid for nothing.
;
; TRANSPORT_END_MESSAGE goes WHEREVER THE DEBUGGER GOES IDLE, and there are
; three such places rather than the two that are obvious:
;
;   cmd_loop            a command's response returns here, and an NTF_PAUSE is
;                       followed by `jp cmd_loop` (mf.asm, breakpoints.asm)
;   main_redraw         CMD_CLOSE's response is followed by `jp main`, which
;                       falls through to main_redraw where the macro now sits.
;                       The border and joy-port keys enter at main_redraw
;                       directly, and drain_main comes through main as before —
;                       one macro still covers all three (issue #16).
;   main_loop.continue  CMD_LOOPBACK reaches NEITHER of the above: it ends
;                       `pop af` / `jp main_loop.continue`
;
; The fourth path out, CMD_CONTINUE, already calls transport_flush on its way
; (backup.asm's restore_registers). Missing the third cost a bug that showed up
; one DZRP check away from its cause — see ERRORS.md. If a new command handler
; leaves by some other route, it needs the macro too; the exits are worth
; enumerating with grep rather than from memory.
;
; THE FIFTH WAY OUT NEEDS NO MACRO, and the reason is worth stating so nobody
; adds one: transport_wait_rx's bound expires to main_idle, which is BELOW
; main_redraw, and it can only expire with the outgoing buffer already flushed
; by the cmd_loop entry immediately above it. Nothing is pending there to send.
;
; The implementation is chosen at assembly time, defaulting to UART. See
; constants.asm for the switch and the Makefile for how it is driven; MEMORY.md
; 2026-08-03 records why one mode per ROM rather than a runtime branch.
;===========================================================================

 IF ROM_VARIANT == ROM_VARIANT_WIFI
    include "transport_esp.asm"
 ELSE
    include "transport_uart.asm"
 ENDIF
