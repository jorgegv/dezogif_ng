;========================================================
; ut_headless.inc
;
; HEADLESS replacement for src/unit_tests/unit_tests.inc.
;
; It defines exactly the same macro names, with the same parameters, so the
; upstream test bodies in src/unit_tests/ut_*.asm assemble against it
; unchanged. What differs is where the assertion is EVALUATED.
;
; Upstream's macros do not test anything. They arrange registers and then
; emit a `nop` carrying an `; ASSERTION <cond>` comment, e.g.
;
;       ld hl,addr : ld l,(hl) : ld h,value
;       nop ; ASSERTION L == H
;
; sjasmplus copies that comment into the SLD file (see `SLDOPT COMMENT ...
; ASSERTION` at the top of unit_tests.asm) and DeZog — running in VS Code —
; sets a conditional breakpoint at the nop's address and evaluates `L == H`
; ON THE PC. The Z80 never checks anything; the `nop` is deliberately inert
; so that the assertion disturbs no register and no flag.
;
; Headless there is no PC-side evaluator, so every assertion is compiled into
; real Z80 code here. The hard requirement inherited from that design is that
; an assertion must still disturb NOTHING: upstream writes runs of assertions
; on different registers back to back
;
;       nop ; TEST ASSERTION bc == 0x2B2C
;       nop ; TEST ASSERTION de == 0x2D2E
;       nop ; TEST ASSERTION hl == 0x2122
;
; and a check that clobbered a register or a flag would break the assertions
; after it. So every macro below saves and restores AF and any scratch
; register it uses, and the comparison result is consumed by a CONDITIONAL
; CALL rather than a jump, because `ld` between the `cp` and the `call` does
; not touch the flags and no label is needed inside the macro.
;
;   ...
;   cp value
;   call nz,ut_assert_fail      ; never returns
;   ...
;
; ut_assert_fail pops its own return address off the stack, which is the
; address INSIDE this macro expansion, and reports it. That is what names the
; failing assertion in the output with no per-assertion identifier to
; allocate, thread through, or get out of step with the source.
;
; The stack is used, and that is not a new requirement: upstream's own
; TEST_MEMORY_BYTE already does `push hl` / `pop hl`, so every assertion site
; in this suite has always needed a working SP.
;========================================================


    ; Entry/exit scaffolding. Same shape as upstream's UNITTEST_INITIALIZE,
    ; minus the wrapper DeZog patches (UNITTEST_CALL_ADDR): the runner in
    ; ut_runner.asm calls each test itself, so nothing is patched at run time.
    MACRO UNITTEST_INITIALIZE

; A test signals success by jumping here, via TC_END. Upstream parks on a
; `jr $` and lets DeZog see which breakpoint was hit; here it returns to the
; runner, which records the pass and moves to the next test.
@UNITTEST_TEST_READY_SUCCESS:
        ld sp,ut_stack
        jp ut_test_passed

; Kept because upstream's tests reference it (ut_uart.asm restores SP from
; its own backup, others rely on the wrapper having set it).
@UNITTEST_STACK_BOTTOM:
        defw 0
        defs 2*50
@UNITTEST_STACK:
        defw 0

    ; The per-test initialization, provided by the collector immediately
    ; after this macro and terminated by its own `ret`. The runner CALLs it
    ; before every test.
@UNITTEST_START:
        di

    ENDM


    ; End of a test case. Upstream's definition, unchanged.
    MACRO TC_END
        jp UNITTEST_TEST_READY_SUCCESS
    ENDM


;--------------------------------------------------------
; The assertion primitives.
;
; UT_ASSERT_R8   reg,value     8-bit register against a constant expression
; UT_ASSERT_R8R8 reg,reg       8-bit register against another register
; UT_ASSERT_BC/DE/HL/IX/IY     16-bit register against a constant expression
; UT_ASSERT_HL_DE              HL against DE
; UT_ASSERT_FALSE              always fails (upstream's `ASSERTION false`)
;
; The generator tools/ut-headless-gen.py rewrites the inline
; `; ASSERTION <cond>` comments in the upstream test bodies into these.
;--------------------------------------------------------

    ; 8-bit register == constant expression.
    ; `ld a,reg?` is `ld a,a` when reg? is a, which is correct and free:
    ; after `push af` the original A is still in A.
    MACRO UT_ASSERT_R8 reg?, value?
        push af
        ld a,reg?
        cp value?
        call nz,ut_assert_fail
        pop af
    ENDM

    ; 8-bit register == 8-bit register.
    MACRO UT_ASSERT_R8R8 reg1?, reg2?
        push af
        ld a,reg1?
        cp reg2?
        call nz,ut_assert_fail
        pop af
    ENDM

    ; BC == constant. HL is the scratch; `sbc hl,bc` leaves BC alone.
    MACRO UT_ASSERT_BC value?
        push af
        push hl
        ld hl,value?
        or a            ; clear carry for sbc
        sbc hl,bc
        call nz,ut_assert_fail
        pop hl
        pop af
    ENDM

    ; DE == constant.
    MACRO UT_ASSERT_DE value?
        push af
        push hl
        ld hl,value?
        or a
        sbc hl,de
        call nz,ut_assert_fail
        pop hl
        pop af
    ENDM

    ; HL == constant. HL is both operand and the only 16-bit comparator, so
    ; it is stashed in memory and reloaded with `ld hl,(nn)`, which does NOT
    ; affect the flags — that is what lets the `call nz` still see the result
    ; of the `sbc`.
    MACRO UT_ASSERT_HL value?
        push af
        push de
        ld (ut_tmp16),hl
        ld de,value?
        or a
        sbc hl,de
        ld hl,(ut_tmp16)
        call nz,ut_assert_fail
        pop de
        pop af
    ENDM

    ; HL == DE.
    MACRO UT_ASSERT_HL_DE
        push af
        push hl
        or a
        sbc hl,de
        call nz,ut_assert_fail
        pop hl
        pop af
    ENDM

    ; IX == constant.
    MACRO UT_ASSERT_IX value?
        push af
        push hl
        push de
        push ix
        pop hl
        ld de,value?
        or a
        sbc hl,de
        call nz,ut_assert_fail
        pop de
        pop hl
        pop af
    ENDM

    ; IY == constant.
    MACRO UT_ASSERT_IY value?
        push af
        push hl
        push de
        push iy
        pop hl
        ld de,value?
        or a
        sbc hl,de
        call nz,ut_assert_fail
        pop de
        pop hl
        pop af
    ENDM

    ; Unconditional failure.
    MACRO UT_ASSERT_FALSE
        call ut_assert_fail
    ENDM


;--------------------------------------------------------
; Upstream's macro surface, reimplemented on the primitives above.
; Same names, same parameters, same observable effect on the machine.
;--------------------------------------------------------

    ; Tests a memory address for a specific byte value.
    MACRO TEST_MEMORY_BYTE addr?, value?
        push hl
        ld hl,addr?
        ld l,(hl)
        ld h,value?
        UT_ASSERT_R8R8 l, h
        pop hl
    ENDM

    ; Tests a memory address for a specific word value.
    MACRO TEST_MEMORY_WORD addr?, value?
        push hl, de
        ld hl,addr?
        ld e,(hl)
        inc hl
        ld d,(hl)
        ld hl,value?
        UT_ASSERT_HL_DE
        pop de, hl
    ENDM

    ; Creates a failure when reached.
    MACRO TEST_FAIL
        UT_ASSERT_FALSE
    ENDM


    ; Compares 2 memory areas containing null terminated strings.
    MACRO TEST_STRING_PTR addr1?, addr2?
        push af
        push hl
        push de
        ld de,addr2?
        ld hl,addr1?
.loop:
        ld a,(de)
        ; Check for null termination
        cp (hl)
        jr nz,.not_equal
        or a
        jr z,.null_found
        inc de
        inc hl
        jr .loop

.not_equal:
        ; Strings are not equal
        pop de
        pop hl
        pop af
        UT_ASSERT_FALSE
        jr .end

.null_found:
        pop de
        pop hl
        pop af
.end:
    ENDM


    ; Tests a memory address for a specific string.
    MACRO TEST_STRING addr?, string?, term0?
        push af
        push hl
        push de
        ld de,.comp_string
        ld hl,addr?
.loop:
        ld a,(de)
        ; Check for null termination
        or a
        jr z,.null_found
        cp (hl)
        inc de
        inc hl
        jr z,.loop

.not_equal:
        ; Strings are not equal
        pop de
        pop hl
        pop af
        UT_ASSERT_FALSE
        jr .end

.comp_string:
        defb string?, 0

.null_found:
        ; We are at the end of the compare string.
      IF term0? == 0
        cp (hl)
        jr nz,.not_equal
      ENDIF

        pop de
        pop hl
        pop af
.end:
    ENDM


    ; Tests a memory area on equality.
    MACRO TEST_MEM_CMP addr1?, addr2?, count?
        push af
        push hl
        push de
        push bc
        ld de,addr2?
        ld hl,addr1?
        ld bc,count?
.loop:
        ld a,(de)
        ; Compare
        cpi      ; cp (hl++); dec bc
        jr nz,.not_equal
        inc de
        jp pe,.loop

        ; Memory is equal
        pop bc
        pop de
        pop hl
        pop af
        jr .end

.not_equal:
        ; Memory areas are not equal
        pop bc
        pop de
        pop hl
        pop af
        UT_ASSERT_FALSE
        jr .end
.end:
    ENDM

    ; Initializes the registers with default values.
    MACRO DEFAULT_REGS
        ld a,0xAA
        ld bc,0xBBCC
        ld de,0xDDEE
        ld hl,0x8899
    ENDM

    MACRO TEST_UNCHANGED_BC
        UT_ASSERT_BC 0xBBCC
    ENDM

    MACRO TEST_UNCHANGED_DE
        UT_ASSERT_DE 0xDDEE
    ENDM

    MACRO TEST_UNCHANGED_HL
        UT_ASSERT_HL 0x8899
    ENDM

    MACRO TEST_UNCHANGED_BC_DE
        TEST_UNCHANGED_BC
        TEST_UNCHANGED_DE
    ENDM

    MACRO TEST_UNCHANGED_BC_DE_HL
        TEST_UNCHANGED_BC_DE
        TEST_UNCHANGED_HL
    ENDM

    MACRO TEST_UNCHANGED_A
        UT_ASSERT_R8 a, 0xAA
    ENDM

    MACRO TEST_UNCHANGED_B
        UT_ASSERT_R8 b, 0xBB
    ENDM

    MACRO TEST_UNCHANGED_C
        UT_ASSERT_R8 c, 0xCC
    ENDM

    MACRO TEST_UNCHANGED_D
        UT_ASSERT_R8 d, 0xDD
    ENDM

    MACRO TEST_UNCHANGED_E
        UT_ASSERT_R8 e, 0xEE
    ENDM

    MACRO TEST_UNCHANGED_H
        UT_ASSERT_R8 h, 0x88
    ENDM

    MACRO TEST_UNCHANGED_L
        UT_ASSERT_R8 l, 0x99
    ENDM


    ; Macro to test flags for Z. Testcase fails for NZ.
    ; `push af` does not disturb the flags, so the incoming Z is still live
    ; at the conditional call.
    MACRO TEST_FLAG_Z
        push af
        call nz,ut_assert_fail
        pop af
    ENDM


    ; Macro to test flags for NZ. Testcase fails for Z.
    MACRO TEST_FLAG_NZ
        push af
        call z,ut_assert_fail
        pop af
    ENDM


    ; This macro uses all registers, also the shadow registers.
    MACRO USE_ALL_REGS
        ld a,0xCD
        ld bc,0xBBCC
        ld de,0xDDEE
        ld hl,0xFF11
        ld ix,0x7788
        ld iy,0x99AA
        exx
        ld a,0xDC
        ld bc,0x1122
        ld de,0x3344
        ld hl,0x5566
        exx
    ENDM
