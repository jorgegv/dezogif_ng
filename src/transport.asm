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
; The lifecycle deactivate is a MACRO, not a subroutine, because the one place
; that needs it is already inline in the resume path (`backup.asm`) and a call
; there would cost bytes and a stack slot in a routine that has neither to
; spare. It expands to nothing in a transport that has nothing to hand back.
;
; There is exactly one implementation today. The second (ESP-01 WiFi) is M1's
; other half; when it exists, this file is where the assembly-time choice
; between them goes. It is deliberately not a switch yet — see MEMORY.md.
;===========================================================================

    include "transport_uart.asm"
