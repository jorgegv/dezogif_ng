;===========================================================================
; copper_cost.asm
;
; MEASURES WHAT THE ASYNCHRONOUS-BREAK POLL COSTS THE DEBUGGEE, in the only
; currency that matters to a program being debugged: how much less of the CPU
; it gets. Issue #22, milestone M2, whose acceptance criteria name this
; measurement explicitly — and plan §10 and doc/ASYNCHRONOUS-BREAK-DESIGN.md §5
; both carry "~100-200 T-states/frame (≈0.3%)" as an ESTIMATE NOBODY MEASURED.
;
; THE METHOD IS A COUNT, NOT A CLOCK. The fixture spins in a loop of known,
; fixed length and counts iterations in HL; the driver snapshots HL at two
; frame counts and takes the DIFFERENCE, so the fixture's own start-up and the
; snapshot's own overhead cancel. Two builds, differing in ONE assembler
; constant — the Copper list installed or not — so the shortfall is
; attributable to the polls and to nothing else. That is the `IP_MAX` /
; `RX_WAIT` / `LINK_IDS` build-seam idiom this project already uses whenever a
; check has to reach behaviour a single build cannot show.
;
; `ei : halt : di` IS LOAD-BEARING AND IS NOT DECORATION. jnext's
; `--inject` (`Emulator::inject_binary`, src/core/emulator.cpp:6683) sets PC, SP
; and IFF1/IFF2 and never clears the CPU's HALTED flag. NextZXOS idles in a
; `halt`, so an injected fixture starts with `halted = 1`, and a fixture running
; DI'd can never clear it — after which the FIRST NMI takes jnext's
; `z80.halted ? pc + 1 : pc` branch (src/cpu/z80_cpu.cpp:636) and returns one
; byte late. Exactly one late return, but this loop has no slack to absorb it
; and would derail rather than mis-count. The `halt` here is a REAL one that is
; really woken, which is what clears the flag. See test/copper_poll.asm, which
; carries the full account, and ERRORS.md.
;
; THE CLOCK IS REPORTED, NOT ASSUMED. The poll runs at whatever speed the
; DEBUGGEE is running at, and the same absolute cost is a very different
; fraction of a frame at 3.5 MHz than at 28 MHz — so the fixture reads
; NR 0x07 back into D, where the driver can see it in the snapshot, rather than
; leaving the reader to infer it from T-states per iteration.
;
; Instruction encoding for the list, from device/copper.vhd:91-104, identical to
; test/copper_nmi.asm's and test/copper_poll.asm's.
;===========================================================================

    DEVICE ZXSPECTRUMNEXT

TBBLUE_REGISTER_SELECT: equ 0x243B
TBBLUE_REGISTER_ACCESS: equ 0x253B

REG_RESET:              equ 0x02    ; bit 3 = generate Multiface NMI
REG_PERIPHERAL_2:       equ 0x06    ; bit 3 = M1 button / MF NMI enable
REG_TURBO_MODE:         equ 0x07    ; the clock, reported in D
REG_COPPER_DATA:        equ 0x60
REG_COPPER_ADDR_LSB:    equ 0x61
REG_COPPER_CONTROL:     equ 0x62

COPPER_LINE:            equ 100
COPPER_STOP:            equ 00000000b
COPPER_RUN_LOOP:        equ 01000000b

COPPER_WAIT:            equ 0x8000 + COPPER_LINE
COPPER_MOVE:            equ (REG_RESET << 8) | 0x08

; THE ONE CONSTANT THE TWO BUILDS DIFFER IN. 1 installs and starts the list, so
; the Multiface NMI fires every frame and the stub's poll path runs; 0 writes
; the identical list and never starts it, so the machine is in every other
; respect the same and no NMI is raised at all.
    IFNDEF COPPER_ON
COPPER_ON:              equ 1
    ENDIF

; The delay is sized so that HL cannot wrap inside the driver's window: about
; 4500 iterations per frame at 28 MHz, so twelve frames is ~54000 of the 65536
; HL can hold. A loop short enough to wrap would need the driver to guess how
; many times, which is exactly the mistake the first attempt at this made.
DELAY_COUNT:            equ 8

    ORG 0x8000

start:
    ; CLEAR THE INHERITED HALTED FLAG — see the header. This must come before
    ; the `di`, and the halt must really be woken, which the ROM's 50 Hz
    ; interrupt does.
    ei
    halt
    di

    ; --- report the clock the debuggee is running at, in D ---
    ld bc,TBBLUE_REGISTER_SELECT
    ld a,REG_TURBO_MODE
    out (c),a
    ld bc,TBBLUE_REGISTER_ACCESS
    in a,(c)
    ld d,a

    ; --- NR 0x06 |= bit 3 : every MF NMI source is ANDed with it ---
    ld bc,TBBLUE_REGISTER_SELECT
    ld a,REG_PERIPHERAL_2
    out (c),a
    ld bc,TBBLUE_REGISTER_ACCESS
    in a,(c)
    or 0x08
    out (c),a

    ; --- the list, written in BOTH builds so they differ only in the start ---
    nextreg REG_COPPER_CONTROL,COPPER_STOP
    nextreg REG_COPPER_ADDR_LSB,0
    nextreg REG_COPPER_DATA,(COPPER_WAIT >> 8) & 0xFF
    nextreg REG_COPPER_DATA,COPPER_WAIT & 0xFF
    nextreg REG_COPPER_DATA,(COPPER_MOVE >> 8) & 0xFF
    nextreg REG_COPPER_DATA,COPPER_MOVE & 0xFF

    IF COPPER_ON
    nextreg REG_COPPER_CONTROL,COPPER_RUN_LOOP
    ENDIF

    ; --- the counted loop: fixed length, and nothing in it can be skipped ---
    ld hl,0
.loop:
    ld b,DELAY_COUNT
.delay:
    djnz .delay
    inc hl
    jr .loop
end:

    SAVEBIN COPPER_COST_BIN, start, end-start
