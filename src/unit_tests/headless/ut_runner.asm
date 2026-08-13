;========================================================
; ut_runner.asm
;
; The in-guest driver for the Z80 unit tests, replacing DeZog.
;
; DeZog's z80-unit-test framework puts the driver on the PC: it enumerates the
; test labels from the SLD file, patches UNITTEST_CALL_ADDR to point at each
; one, runs the machine and decides pass/fail by which breakpoint is hit. That
; needs VS Code, so the suite gates nothing (issue #3).
;
; Here the guest drives itself. The test table is generated at assembly time
; by tools/ut-headless-gen.py from the same labels DeZog would enumerate, and
; the verdict is written to jnext's magic debug port, which puts bytes on the
; emulator's stderr (--magic-port 0xCAFE --magic-port-mode line). One headless
; jnext run therefore prints a full test report that a shell bench can read.
;
;--------------------------------------------------------
; THE OUTPUT PROTOCOL, and why it is shaped this way
;--------------------------------------------------------
;
;   UT-RUN <count>          the runner started and intends to run <count>
;   UT-BEGIN <idx> <name>   about to enter test <idx>            <-- BEFORE
;   UT-PASS <idx>           test <idx> reached TC_END
;   UT-FAIL <idx> <addr>    an assertion at <addr> failed
;   UT-DONE <ran> <pass> <fail>
;
; All numbers are hex.
;
; UT-BEGIN is emitted BEFORE the test runs, and that is the single most
; important property of this design. A test that hangs or crashes never emits
; PASS or FAIL and never reaches UT-DONE, so the run ends on jnext's frame
; budget with the offending test's UT-BEGIN as the last line. Silence is
; therefore a FAILURE that names its own culprit, and can never be read as a
; pass. The bench requires UT-DONE to be present and its counts to match the
; pinned total, so "the runner stopped early" and "the runner ran nothing" are
; both loud.
;
; UT-RUN appearing more than once means the machine reset and the runner
; restarted; the bench treats that as a failure too, because a restart would
; otherwise duplicate passes.
;
;--------------------------------------------------------
; ISOLATION BETWEEN TESTS
;--------------------------------------------------------
;
; Under DeZog each test case starts from the state the initialization routine
; left. Several tests here make that non-trivial, because they SELF-MODIFY the
; debugger they are testing and never undo it:
;
;   ut_uart.asm  patches transport_read_byte.timeout with a JP into itself
;   ut_nmi.asm   patches MF.nmi66h.is_button_cause with a JP into itself
;   ut_backup.asm / ut_commands.asm patch save_registers.ret_jump,
;                restore_registers.ret_jump1/2, and more
;
; Run back to back with no reset, a later test calling transport_read_byte
; would jump into ut_uart's leftover trampoline, land on its TC_END, and be
; reported as a PASS it never earned. So before every test the runner
;
;   1. restores all eight MMU slot registers to what they were at startup
;      (tests page banks 28/29/39/40/70/75/76 into slots 0, 6 and 7 and do
;      not always put them back), and
;   2. copies a pristine image of the 8 KB program bank back over it.
;
; The pristine copy is taken once at startup into UT_SNAPSHOT_BANK, chosen to
; be a bank no test touches.
;
; The runner reads and writes the MMU registers itself rather than calling the
; debugger's helpers, because it must keep working while the bank holding
; those helpers is being overwritten. (write_tbblue_reg is commented out in
; utilities.asm anyway.)
;========================================================

    MODULE ut_runner

; jnext's magic debug port. Writes to it are echoed to the emulator's stderr.
; 0xCAFE is jnext's own convention for this (test/00regression/scripts/
; magic-port-func.sh). The handler is registered with a full 16-bit mask, and
; jnext's port dispatch is most-specific-match-wins (port_dispatch.cpp), so
; this write does NOT also reach the ULA's partially decoded port 0xFE — no
; border or speaker side effect.
UT_MAGIC_PORT:      equ 0xCAFE

; Bank holding the pristine copy of the program bank. Must be a bank no test
; uses: the suite touches 28, 29, 39, 40, 70, 75, 76 and the debugger's own
; 91 (LOOPBACK_BANK), 92 (TMP_BANK, = LOADED_BANK here), 93 and 94.
UT_SNAPSHOT_BANK:   equ 80


;--------------------------------------------------------
; Entry point. The NEX header points here.
;--------------------------------------------------------
@ut_main:
    di
    ld sp,ut_stack

    ; Remember the MMU layout the loader left, so it can be restored between
    ; tests. Read back rather than assumed.
    ; E holds the register number and BC is saved across the call: the
    ; nextreg helpers below talk to IO_NEXTREG_REG and so clobber BC.
    ld hl,mmu_backup
    ld e,REG_MMU
    ld b,8
.mmu_save:
    ld a,e
    push bc
    push hl
    call read_nextreg
    pop hl
    pop bc
    ld (hl),a
    inc hl
    inc e
    djnz .mmu_save

    ; Take the pristine copy of the program bank (slot 7) into the snapshot
    ; bank, reached through the swap slot.
    nextreg REG_MMU+MAIN_SLOT,LOADED_BANK
    nextreg REG_MMU+SWAP_SLOT,UT_SNAPSHOT_BANK
    ld hl,MAIN_ADDR
    ld de,SWAP_ADDR
    ld bc,0x2000
    ldir

    ; Announce the run.
    ld hl,str_run
    call puts
    ld a,UT_TEST_COUNT
    call puthex8
    call putnl

    xor a
    ld (pass_count),a
    ld (fail_count),a
    ld (skip_count),a
    ; Diagnostic mode: -DUT_ONLY=<n> runs exactly one test, in its own
    ; process. That is how the skip list below was established — by running
    ; every test alone and watching which ones hang — rather than by reading
    ; the zsim plugin and assuming.
  IFDEF UT_ONLY
    ld a,UT_ONLY
  ENDIF
    ld (test_index),a

;--------------------------------------------------------
; The test loop.
;--------------------------------------------------------
@ut_next_test:
    ld a,(test_index)
  IFDEF UT_ONLY
    cp UT_ONLY+1
  ELSE
    cp UT_TEST_COUNT
  ENDIF
    jr nc,finished

    call load_entry

    ; Tests that depend on DeZog's zsim customCode plugin (src/simulation/
    ; uart.js) are reported and stepped over rather than quietly left out of
    ; the table: an exclusion that does not appear in the output is an
    ; exclusion nobody will ever notice. See tools/ut-headless-gen.py for how
    ; the list is derived, and doc/UNIT-TESTS.md for why they cannot run.
    ld a,(test_index)
    ld l,a
    ld h,0
    ld de,ut_skip_flags
    add hl,de
    ld a,(hl)
    or a
    jr z,.run

    ld hl,str_skip
    call puts
    call emit_idx_name
    ld hl,skip_count
    inc (hl)
    jp advance

.run:
    ; Undo whatever the previous test did to the machine.
    call restore_state

    ; Per-test initialization: exactly the routine DeZog would run, i.e. the
    ; code the collector places immediately after UNITTEST_INITIALIZE.
    call UNITTEST_START

    ; Announce the test BEFORE running it, so a hang or a crash leaves its
    ; name as the last thing on the wire.
    ld hl,str_begin
    call puts
    call emit_idx_name

    ; Enter the test. Upstream's wrapper CALLs it and parks on the
    ; instruction after, so a test that plainly `ret`s counts as a success;
    ; the same shape is kept here. Tests normally leave via TC_END, which
    ; jumps straight to UNITTEST_TEST_READY_SUCCESS.
    ld sp,ut_stack
    call enter_test
    jp UNITTEST_TEST_READY_SUCCESS

finished:
    ld hl,str_done
    call puts
    ld a,(test_index)
    call puthex8
    ld a,' '
    call putc
    ld a,(pass_count)
    call puthex8
    ld a,' '
    call putc
    ld a,(fail_count)
    call puthex8
    ld a,' '
    call putc
    ld a,(skip_count)
    call puthex8
    call putnl

.forever:
    jr .forever


; Indirect entry to the test whose address emit_begin cached.
enter_test:
    ld hl,(test_addr)
    jp (hl)


;--------------------------------------------------------
; Test outcome handlers. Both may be reached with an arbitrary SP.
;--------------------------------------------------------

; Reached from TC_END (see ut_headless.inc), which has already reset SP.
@ut_test_passed:
    ld hl,str_pass
    call puts
    ld a,(test_index)
    call puthex8
    call putnl
    ld hl,pass_count
    inc (hl)
    jr advance

; Reached from a failed assertion; ut_assert_fail has recorded the address
; and reset SP.
@ut_test_failed:
    ld hl,str_fail
    call puts
    ld a,(test_index)
    call puthex8
    ld a,' '
    call putc
    ld hl,(fail_addr)
    call puthex16
    call putnl
    ld hl,fail_count
    inc (hl)
    ; fall through

advance:
    ld hl,test_index
    inc (hl)
    jp ut_next_test


; Called (never jumped to) by every assertion macro in ut_headless.inc when
; the assertion is false. The return address the CALL pushed is the address
; inside the failing macro expansion, and that is what identifies the
; assertion — no per-assertion id has to be allocated or kept in step with
; the source.
@ut_assert_fail:
    pop hl                      ; HL = address just after the failing call
    ld (fail_addr),hl
    ld sp,ut_stack
    jp ut_test_failed


;--------------------------------------------------------
; Restore the machine to its startup state before each test.
;--------------------------------------------------------
restore_state:
    ld hl,mmu_backup
    ld e,REG_MMU
    ld b,8
.mmu_restore:
    ld a,(hl)
    ld d,a
    ld a,e
    push bc
    push hl
    call write_nextreg
    pop hl
    pop bc
    inc hl
    inc e
    djnz .mmu_restore

    ; Copy the pristine program bank back over the live one.
    nextreg REG_MMU+MAIN_SLOT,LOADED_BANK
    nextreg REG_MMU+SWAP_SLOT,UT_SNAPSHOT_BANK
    ld hl,SWAP_ADDR
    ld de,MAIN_ADDR
    ld bc,0x2000
    ldir

    ; Put the swap slot back the way the loader had it.
    ld a,(mmu_backup+SWAP_SLOT)
    ld d,a
    ld a,REG_MMU+SWAP_SLOT
    jp write_nextreg


; A = register number -> A = value. Clobbers BC.
read_nextreg:
    ld bc,IO_NEXTREG_REG
    out (c),a
    inc b                       ; IO_NEXTREG_DAT
    in a,(c)
    ret

; A = register number, D = value. Clobbers BC.
write_nextreg:
    ld bc,IO_NEXTREG_REG
    out (c),a
    inc b
    out (c),d
    ret


;--------------------------------------------------------
; Output primitives. Everything goes to jnext's magic port.
;--------------------------------------------------------

; Cache the current test's entry address and name pointer from the table.
;
; THE ×4 IS DONE IN 16 BITS, AND IT WAS DONE IN 8 UNTIL 2026-08-13. `add a,a`
; twice overflows the accumulator at index 0x40, so every test from the 65th
; onwards read the entry of `index & 0x3F`: the runner CALLED the wrong test's
; code and printed the wrong test's name, while the skip flags — looked up one
; byte per entry, below, with no multiply — stayed correct. With 69 cases that
; silently re-ran tests 0x00-0x02 in place of 0x40-0x42 and reported them
; passing under the right index, so the counts, both pins and every check in
; run-unit-tests.sh agreed while three real breakpoint tests never executed.
;
; LIVE SINCE THE TABLE CROSSED 64 ENTRIES, which is issue #41. It is exactly the
; failure the two-place pinning exists to catch and the one shape it cannot see:
; the totals are right because a duplicate is counted in place of the test it
; displaced. UT_EXPECTED_* pins how many, never WHICH.
load_entry:
    ld a,(test_index)
    ld l,a
    ld h,0
    add hl,hl
    add hl,hl                   ; 4 bytes per table entry, in 16 bits
    ld de,ut_test_table
    add hl,de
    ld e,(hl)                   ; entry address
    inc hl
    ld d,(hl)
    inc hl
    ld (test_addr),de
    ld e,(hl)                   ; name pointer
    inc hl
    ld d,(hl)
    ld (test_name),de
    ret

; Emit "<idx> <name>" and a newline, after a caller-supplied prefix.
emit_idx_name:
    ld a,(test_index)
    call puthex8
    ld a,' '
    call putc
    ld hl,(test_name)
    call puts
    jp putnl

; A = character
putc:
    push bc
    ld bc,UT_MAGIC_PORT
    out (c),a
    pop bc
    ret

putnl:
    ld a,13
    jr putc

; HL = pointer to a NUL-terminated string
puts:
    ld a,(hl)
    or a
    ret z
    call putc
    inc hl
    jr puts

; A = byte, printed as two hex digits
puthex8:
    push af
    rrca
    rrca
    rrca
    rrca
    call .nibble
    pop af
.nibble:
    and 0x0F
    add a,'0'
    cp '9'+1
    jr c,.emit
    add a,'A'-'0'-10
.emit:
    jr putc

; HL = word, printed as four hex digits
puthex16:
    ld a,h
    call puthex8
    ld a,l
    jr puthex8


;--------------------------------------------------------
; Runner state. Deliberately outside the program bank, which is wiped and
; rewritten between tests, and outside the tests' own data areas.
;--------------------------------------------------------
test_index:     defb 0
pass_count:     defb 0
fail_count:     defb 0
skip_count:     defb 0
test_addr:      defw 0
test_name:      defw 0
fail_addr:      defw 0
mmu_backup:     defs 8

; Scratch for UT_ASSERT_HL, which has no spare 16-bit register.
@ut_tmp16:      defw 0

                defs 128
@ut_stack:      defw 0

str_run:        defb "UT-RUN ",0
str_begin:      defb "UT-BEGIN ",0
str_skip:       defb "UT-SKIP ",0
str_pass:       defb "UT-PASS ",0
str_fail:       defb "UT-FAIL ",0
str_done:       defb "UT-DONE ",0

    ENDMODULE
