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
;   main                CMD_CLOSE's response is followed by `jp main`
;   main_loop.continue  CMD_LOOPBACK reaches NEITHER of the above: it ends
;                       `pop af` / `jp main_loop.continue`
;
; The fourth path out, CMD_CONTINUE, already calls transport_flush on its way
; (backup.asm's restore_registers). Missing the third cost a bug that showed up
; one DZRP check away from its cause — see ERRORS.md. If a new command handler
; leaves by some other route, it needs the macro too; the exits are worth
; enumerating with grep rather than from memory.
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
