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
;
;   A read or write that times out does NOT return to its caller. It jumps to
;   the implementation's timeout handler, which stores an error and re-enters
;   the main loop via drain_main. Every caller above already depends on that —
;   none of them check for a timeout — so a second implementation has to
;   preserve it rather than returning an error code.
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
;   These exist so the transport can SAY SO on the Next's own screen, which is
;   the one channel the PC side does not have (issue #14). They are macros, and
;   the interface's rule about common code is why: cmd_init and cmd_close are in
;   commands.asm, which must not be able to tell which transport it was
;   assembled against, so the mode-specific part cannot be an `IF ROM_VARIANT`
;   there. A transport with nothing to report expands them to nothing, and the
;   UART build's bytes do not move.
;
;   THEY REPORT EVENTS, NOT A LIVE CONNECTION. CMD_INIT and CMD_CLOSE are the
;   only two moments a transport above the byte stream can observe, and neither
;   is TCP: a socket can be open before the first and after the second, and a
;   client that vanishes without CMD_CLOSE produces no event at all. Whatever an
;   implementation draws must therefore claim only what these two prove — see
;   esp_client_state in transport_esp.asm, where the wording is chosen for
;   exactly that reason. Tracking the module's `<id>,CONNECT` / `<id>,CLOSED`
;   lines is what would close the gap, and it is M3's reconnect work.
;
;   AF is free at both call sites (commands.asm), so an implementation may use
;   it without saving; nothing else is.
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
