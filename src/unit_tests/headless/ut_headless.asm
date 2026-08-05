;========================================================
; ut_headless.asm
;
; Collects and executes all unit tests, HEADLESS — no VS Code, no DeZog.
;
; This is the headless twin of src/unit_tests/unit_tests.asm. That file is
; upstream's and is left exactly as it is, so `make unit-tests` and the DeZog
; path in VS Code keep working unchanged (issue #3 requires that).
;
; Three things differ here:
;
;   1. src/unit_tests/headless/ut_headless.inc replaces unit_tests.inc, so the
;      assertions compile into real Z80 code instead of `nop`s carrying
;      comments for DeZog to evaluate on the PC.
;   2. The test bodies come from build/ut_headless/, where
;      tools/ut-headless-gen.py has rewritten the inline `; ASSERTION <cond>`
;      comments into calls to those macros. The transformation touches only
;      those lines; everything else is copied byte for byte.
;   3. ut_runner.asm drives the tests from inside the guest and reports to
;      jnext's magic debug port, and the NEX entry point is the runner rather
;      than nothing (upstream's ut.nex has PC=0 because DeZog sets PC itself).
;
; The include order below is the same as upstream's, so the test bodies land
; in the same order and the generated table matches.
;========================================================

    DEVICE ZXSPECTRUMNEXT

    DEFINE UNIT_TEST

    DEFINE MF_FAKE  ; For some tests of the NMI

; Required labels:
main_bank_entry:    equ 0x0000  ; Not used
main_end:    equ 0xE100  ; Not used

; The program is loaded here for testing (NEX file)
LOADED_BANK:    EQU 92

    include "constants.asm"

    MMU MAIN_SLOT e, LOADED_BANK ; e -> Everything should fit into one page, error if not.
    ORG MAIN_ADDR    ; 0xE000

    include "macros.asm"
    include "zx/zx.inc"
    include "zx/zxnext_regs.inc"
    include "breakpoints.asm"
    include "data_const.asm"
    include "mf.asm"
    include "utilities.asm"
    include "transport.asm"
    include "message.asm"
    include "commands.asm"
    include "backup.asm"
    include "text.asm"
    include "data.asm"
    include "ui.asm"
    include "altrom.asm"
    include "debug.asm"

    include "mf_rom.asm"


    ORG 0x7000
PRG_START:
    include "unit_tests/headless/ut_headless.inc"
    include "unit_tests/headless/ut_runner.asm"

    ; The rewritten test bodies. Same files, same order, as upstream's
    ; unit_tests.asm — the generated table depends on that order only for
    ; readability, but keeping it makes the two builds directly comparable.
    include "ut_headless/ut_utilities.asm"
    include "ut_headless/ut_uart.asm"
    include "ut_headless/ut_backup.asm"
    include "ut_headless/ut_commands.asm"
    include "ut_headless/ut_message.asm"
    include "ut_headless/ut_breakpoints.asm"
    include "ut_headless/ut_nmi.asm"

; Required labels:
main_loop.continue:     ret
; transport_wait_rx jumps here when its bound expires (issue #16). No test
; reaches it — nothing here calls that routine — so this exists to link, like
; ut_uart.asm's drain_main.
main_idle:              ret

    ; Initialization routine. Called by the runner before EVERY test.
    UNITTEST_INITIALIZE
    ; Page in main bank
    nextreg REG_MMU+MAIN_SLOT,LOADED_BANK
    ret

    ; The generated test table: one entry per test label, in source order.
    include "ut_headless/ut_table.asm"
PRG_END:


; Check to avoid that program is put in a memory area that is used
; in unit testing.
    ASSERT PRG_END <= 0xBFFF

; The runner keeps a pristine copy of the program bank and pages it through
; the swap slot, so nothing of ours may live in slot 6 or 7.
    ASSERT PRG_END < SWAP_ADDR

    ; Save NEX file. Unlike upstream's, this one carries an entry point: there
    ; is no DeZog here to set PC.
    SAVENEX OPEN BIN_FILE, ut_main, ut_stack
    SAVENEX CORE 2, 0, 0        ; Next core 2.0.0 required as minimum
    SAVENEX AUTO
    SAVENEX CLOSE
