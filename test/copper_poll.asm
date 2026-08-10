;===========================================================================
; copper_poll.asm
;
; Bench check T9's fixture (issue #22, M2): a Copper list that raises the
; Multiface NMI every frame, plus a loop that WATCHES WHETHER THE POLL GAVE THE
; MACHINE BACK UNCHANGED.
;
; It is the debuggee's half of the asynchronous break, in the shape a real user
; would write it — the two Copper instructions live in the DEBUGGED PROGRAM,
; not in the debugger, because the Copper's instruction list is write-only and a
; debugger that installed its own could never restore what it overwrote (see
; doc/ASYNCHRONOUS-BREAK-DESIGN.md). Anything here beyond `start` .. the list is
; the detector and would not appear in a user's program.
;
; WHY A DETECTOR AT ALL: the poll is supposed to be INVISIBLE, so there is
; nothing about a healthy one for a bench to photograph. What can be
; photographed is the interrupted program noticing that it was NOT given its
; machine back, and that is what this does. It watches the two pieces of state
; nmi66h's poll path disturbs and must put back:
;
;   MMU slot 7   the poll pages MAIN_BANK in to reach the debugger's image, so
;                it must page the interrupted program's bank back. Forgetting is
;                issue #26 — which cost a real Next a hang — on a 50 Hz timer.
;   the NextREG  nmi66h selects NR 0x02 to read the NMI's cause, so the
;   select latch program's own selected register must be put back. Forgetting is
;                harmless once per button press and a recurring corruption at
;                50 Hz, which is why M2 had to fix it.
;
; IT WATCHES MMU SLOT 7 AND NOT THE LATCH, AND THAT LIMIT WAS MEASURED RATHER
; THAN CHOSEN. The obvious design watches both at once: select NR 0x57 through
; port 0x243B, never write that port again, and every `in a,(0x253B)` then
; returns slot 7's bank IF the latch survived and some other register's value if
; it did not. The selection really does survive the poll's `nextreg`
; instructions — `nr_register` is written ONLY by a port 0x243B write
; (zxnext.vhd:4597) and the Z80N instruction takes its register number from its
; own operand (:4744) — but the poll's own `.save_slot7_page_in` writes 0x243B
; with 0x57, so a build with the latch restore DELETED leaves the latch at
; exactly the value this fixture wanted. Built and run: that red-first came out
; GREEN. So the latch half is NOT covered here; see T9's notes in
; test/run-headless.sh for what does and does not cover it.
;
; PROBE_BANK IS 30 AND EVERY PART OF THAT MATTERS. It must not be MAIN_BANK
; (94), which is what a poll that failed to restore slot 7 would leave; and it
; must be above 3, because a lost latch leaves NR 0x02 selected, whose read is
; the esp/expbus bit plus two bits of reset history — 0x00-0x03 or 0x80-0x83 —
; and a probe bank in that range could be mistaken for a healthy read.
;
; Instruction encoding, from device/copper.vhd:91-104 — not from a wiki, and
; the same two instructions test/copper_nmi.asm installs:
;
;   WAIT   bit 15 = 1, bits 14:9 = hpos, bits 8:0 = line
;          fires when  vcount = line  and  hcount >= hpos*8 + 12
;   MOVE   bit 15 = 0, bits 14:8 = NextREG number, bits 7:0 = value
;
; so `MOVE $02,$08` — NextREG 0x02 bit 3, the Multiface NMI — is 0x0208, and
; `WAIT line,0` is 0x8000 + line.
;
; NR 0x06 bit 3 must be set first. zxnext.vhd:2090 ANDs *every* Multiface NMI
; source with it — the Copper one included — and its power-on value is 0.
; NextZXOS happens to leave it set (measured 2026-08-04), so this is seven bytes
; that remove a dependency on what the firmware left behind.
;===========================================================================

    DEVICE ZXSPECTRUMNEXT

TBBLUE_REGISTER_SELECT: equ 0x243B
TBBLUE_REGISTER_ACCESS: equ 0x253B
BORDER:                 equ 0xFE

REG_RESET:              equ 0x02    ; bit 3 = generate Multiface NMI
REG_PERIPHERAL_2:       equ 0x06    ; bit 3 = M1 button / MF NMI enable
REG_MMU7:               equ 0x57    ; the bank in 0xE000-0xFFFF
REG_COPPER_DATA:        equ 0x60    ; 8-bit write, auto-increment
REG_COPPER_ADDR_LSB:    equ 0x61
REG_COPPER_CONTROL:     equ 0x62    ; bits 7:6 start control, bits 2:0 addr MSB

COPPER_LINE:            equ 100     ; mid-screen, well clear of the border
COPPER_STOP:            equ 00000000b
COPPER_RUN_LOOP:        equ 01000000b

COPPER_WAIT:            equ 0x8000 + COPPER_LINE
COPPER_WAIT_HI:         equ (COPPER_WAIT >> 8) & 0xFF
COPPER_WAIT_LO:         equ COPPER_WAIT & 0xFF
COPPER_MOVE:            equ (REG_RESET << 8) | 0x08
COPPER_MOVE_HI:         equ (COPPER_MOVE >> 8) & 0xFF
COPPER_MOVE_LO:         equ COPPER_MOVE & 0xFF

PROBE_BANK:             equ 30      ; see the header
BORDER_OK:              equ 4       ; green
BORDER_BAD:             equ 2       ; red

    ORG 0x8000

start:
    ; No maskable interrupts: NextZXOS's own ISR would page banks under us and
    ; the verdict below would be about that rather than about the poll. The NMI
    ; is unaffected — that is the whole point of it.
    di

    ; --- NR 0x06 |= bit 3 : without this every MF NMI source is gated off ---
    ld bc,TBBLUE_REGISTER_SELECT
    ld a,REG_PERIPHERAL_2
    out (c),a
    ld bc,TBBLUE_REGISTER_ACCESS
    in a,(c)
    or 0x08
    out (c),a

    ; --- a known bank in slot 7, so that a lost restore is visible ---
    ; Our own stack goes with it (NextZXOS's SP is up there), which is why
    ; nothing below this line uses the stack: no CALL, no PUSH. The NMI does not
    ; need it either — nmi66h switches SP to MF RAM on entry and back on exit.
    nextreg REG_MMU7,PROBE_BANK

    ; --- stop the Copper and put the write pointer at index 0 ---
    nextreg REG_COPPER_CONTROL,COPPER_STOP
    nextreg REG_COPPER_ADDR_LSB,0

    ; --- the list, MSB first: WAIT line,0 then MOVE $02,$08 ---
    nextreg REG_COPPER_DATA,COPPER_WAIT_HI
    nextreg REG_COPPER_DATA,COPPER_WAIT_LO
    nextreg REG_COPPER_DATA,COPPER_MOVE_HI
    nextreg REG_COPPER_DATA,COPPER_MOVE_LO

    ; --- run it from index 0, looping ---
    nextreg REG_COPPER_CONTROL,COPPER_RUN_LOOP

    ; --- arm the detector: select MMU slot 7 and never touch 0x243B again ---
    ld bc,TBBLUE_REGISTER_SELECT
    ld a,REG_MMU7
    out (c),a
    ld bc,TBBLUE_REGISTER_ACCESS

; THE NOPS ARE NOT PADDING FOR ITS OWN SAKE — THEY WORK AROUND A SEPARATE,
; PRE-EXISTING DEFECT THAT WOULD OTHERWISE SWAMP THIS ONE, AND IT MUST NOT BE
; MISTAKEN FOR SOMETHING M2 INTRODUCED.
;
; Measured 2026-08-10, and reproduced on `main`'s OWN ROM as well as on M2's: a
; software Multiface NMI, taken repeatedly and returned from, does not always
; put the CPU back on the instruction it interrupted. Within about two NMIs a
; tight loop of one-byte instructions derails — a `xor a` / `jr nz` pair takes
; the branch — while the SAME loop with eight NOPs either side of the pair runs
; 18132 iterations across ~400 NMIs untouched. Registers, flags, SP and PC are
; all intact in a snapshot afterwards, which is what says the fault is WHERE the
; return lands rather than what it carries.
;
; It is not this fixture's subject and it is not M2's: `main`'s decline path
; reproduces it identically, and nothing in this project had ever returned from
; a software NMI more than once before, so nobody could have seen it. Whether
; the cause is upstream's handler or jnext's NMI model is unresolved — see the
; NOT COVERED notes at T9 in test/run-headless.sh.
;
; So the loop is padded, deliberately and with this said out loud, so that T9
; can measure the leak it exists to measure instead of measuring that.
.loop:
    nop : nop : nop : nop : nop : nop : nop : nop

    ; ONE READ. PROBE_BANK back means MMU slot 7 was restored; anything else
    ; means it was not, and the screenshot plus this file say which.
    in a,(c)
    cp PROBE_BANK
    jr nz,.fail

    nop : nop : nop : nop : nop : nop : nop : nop

    ld a,BORDER_OK
    out (BORDER),a
    jr .loop

.fail:
    ; Latched, not flashed: once the poll has damaged the machine there is no
    ; reason to believe the next reading. A bench sampling the border at one
    ; frame must not be able to catch a good moment of a broken run.
    ld a,BORDER_BAD
    out (BORDER),a
.stop:
    jr .stop
end:

    SAVEBIN COPPER_POLL_BIN, start, end-start
