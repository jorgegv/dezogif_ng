;=============================================================================
; mfwin.asm — the config-mode window, for .mfinstall (issue #21).
;
; THIS IS THE ONLY CODE IN THIS PROJECT THAT WRITES THE MULTIFACE ROM AT RUN
; TIME, and everything about its shape is forced by two measured facts:
;
;   1. A dot command runs at 0x2000 with DivMMC RAM mapped there by CONMEM, and
;      DivMMC page0 and page1 are enabled TOGETHER (divmmc.vhd:94-95), so the
;      DivMMC ROM is necessarily at 0x0000 as well — where it is unconditionally
;      read-only (divmmc.vhd:100). Config mode's own branch sets
;      sram_pre_override <= "110" (zxnext.vhd:3050), which deliberately leaves
;      DivMMC eligible in the SECOND arbiter (:3084), so DivMMC WINS and every
;      config-mode write to bank 5 is SILENTLY DISCARDED. Measured: a probe read
;      back enNxtmmc.rom's bytes, not enNextMf.rom's.
;
;   2. Turning DivMMC off is what fixes that, and relocating above 0x4000 is
;      what makes turning it off SURVIVABLE — everything at 0x2000, the dot
;      command's own code and statics included, vanishes with it. Measured with
;      a one-constant control: the identical routine with DivMMC left ON reads
;      back the DivMMC ROM from the same code location. Relocation alone fixes
;      nothing.
;
; So: assembled at a FIXED address by sjasmplus, copied there by the C side, and
; CALLed. Code, data and stack are ALL >= 0x4000 for the duration of the window.
;
; The area used is the DISPLAY FILE's pixel third (0x4000-0x57FF), which is
; ordinary main RAM at a known address on every Next — MMU2=0x0A, MMU3=0x0B,
; measured — and needs no allocation and no esxdos call to obtain. Everything it
; disturbs there is pixels; the attributes at 0x5800 are never touched, and the
; caller blanks the pixels afterwards.
;
;   0x4000  buffer    4096 bytes of ROM image, filled by the caller with esxdos
;   0x5000  code      (this routine)
;   0x5400  vars      (parameters in, results out, saved machine state)
;   0x5800  stack top (grows DOWN, 0x57FF..0x5500: 768 bytes of headroom)
;
; VHDL citations are to cores/zxnext/src/ — zxnext.vhd unless named otherwise.
; Every one of them was read for issue #21; see doc/CONFIG-MODE-ROM-REPLACEMENT.md.
;=============================================================================

        DEVICE  NOSLOT64K

BUF             EQU     0x4000          ; the caller's 4 KB image buffer
CODE_ORG        EQU     0x5000
VARS            EQU     0x5400
STACK_TOP       EQU     0x5800

; ---- parameters, written by the caller BEFORE the call ---------------------
w_op            EQU     VARS+0x00       ; 1  OP_READ_ID / OP_WRITE
w_dst           EQU     VARS+0x01       ; 2  destination, absolute in the window
w_len           EQU     VARS+0x03       ; 2  bytes to copy (OP_WRITE only)

; ---- results, read by the caller AFTER it returns --------------------------
w_res           EQU     VARS+0x05       ; 1  RES_OK / RES_VERIFY
w_stage         EQU     VARS+0x06       ; 1  how far we got; mirrors the border

; ---- machine state saved across the window ---------------------------------
v_sp            EQU     VARS+0x08       ; 2  the caller's SP
v_e3            EQU     VARS+0x0A       ; 1  port 0xE3 as found  (:2815, :4190)
v_0a            EQU     VARS+0x0B       ; 1  NR 0x0A as found    (:5912)
v_03            EQU     VARS+0x0C       ; 1  NR 0x03 as found    (:5894)
v_50            EQU     VARS+0x0D       ; 1  MMU0 as found
v_81            EQU     VARS+0x0E       ; 1  NR 0x81 as found
v_123b          EQU     VARS+0x0F       ; 1  port 0x123B as found (:2822, :3933)
v_mach          EQU     VARS+0x10       ; 1  NR 0x03 & 7 — the config-mode exit

; ---- the identity block, read back by OP_READ_ID ---------------------------
w_id            EQU     VARS+0x20       ; MAGIC_READ bytes

OP_READ_ID      EQU     0               ; read the live ROM's identity block
OP_SYNC         EQU     1               ; make w_len bytes at w_dst equal BUF —
                                        ; COMPARE first, write only if they
                                        ; differ, and verify what was written

RES_OK          EQU     0               ; the bytes differed; written and verified
RES_VERIFY      EQU     1               ; written, and the read-back disagrees —
                                        ; see the note at .verify
RES_SAME        EQU     2               ; already identical; NOTHING was written

MAGIC_OFF       EQU     0x1FE0          ; the identity block (issue #4), which is
MAGIC_READ      EQU     20              ; at the END of the 8 KB image on purpose

; DIVMMC_OFF — A BENCH SEAM, and the only way the blocked-write path can be
; reached. It is the sixth of its shape in this repository, after IP_MAX,
; RX_WAIT, TX_PASSES, WAIT_SECS, FAULT_LIMIT and LINK_IDS, and it exists for
; their reason: the state a check must be shown red against has to be reachable
; by a BUILD, or the red is a story about a scratch tree nobody can re-run.
;
;   1  (shipped) turn DivMMC off for the window
;   0  do NOT touch NR 0x0A or port 0xE3 at all — relocation alone
;
; Everything else — the relocation, MMU0, layer 2, NR 0x81, config mode, the op,
; the exit and every other restore — is identical between the two. That is what
; makes the difference attributable: `DIVMMC_OFF=0` reproduces the blocked write
; measured from a dot command's ORDINARY context, from a different code
; location, so relocating above 0x4000 is not what fixes this and turning DivMMC
; off is. Bench check I7.
        IFNDEF DIVMMC_OFF
DIVMMC_OFF      EQU     1
        ENDIF

; ---- border stage marks ----------------------------------------------------
; THE ONLY INSTRUMENT THAT SURVIVES A HANG. If the routine never returns, the
; screenshot's border says where it stopped. `out (0xFE),a` is I/O, so nothing
; the window does to memory mapping can affect it. Carried over from the
; measurement probe, where nothing needed it — which is not a reason to drop it.
ST_ENTER        EQU     1               ; blue    — di done, SP switched high
ST_DIVMMC_OFF   EQU     2               ; red     — automap off, CONMEM off
ST_CONFIG_IN    EQU     3               ; magenta — config mode on, NR04=5
ST_OP_DONE      EQU     4               ; green   — the read or the write is done
ST_CONFIG_OUT   EQU     5               ; cyan    — config mode left
ST_RESTORED     EQU     6               ; yellow  — MMU0/0x123B/NR81/NR0A back
ST_BRIDGE       EQU     7               ; white   — CONMEM bridge set, rst 8 next
ST_DONE         EQU     0               ; black   — returned, everything restored

        ORG     CODE_ORG

;-----------------------------------------------------------------------------
; window — no arguments and no return value in registers. Everything goes
; through VARS, because the caller's own statics are at 0x2000 and are gone for
; the duration.
;-----------------------------------------------------------------------------
window:
        di                              ; NOT optional. Config mode remaps the
                                        ; WHOLE of 0x0000-0x3FFF (:3029), the
                                        ; IM1 vector at 0x0038 and the RSTs
                                        ; included, so an interrupt taken inside
                                        ; the copy would fetch its handler out of
                                        ; the bank being overwritten.
        ld      (v_sp),sp               ; the caller's stack may be DivMMC RAM.
        ld      sp,STACK_TOP            ; Measured at 0xFF2B, i.e. already high,
                                        ; so this is defensive rather than
                                        ; load-bearing — for THIS invocation
                                        ; path. `--auto` from AUTOEXEC.BAS has
                                        ; since been shown to SURVIVE on real
                                        ; hardware, which is not the same as
                                        ; having had its SP read back.

        xor     a
        ld      (w_res),a               ; RES_OK until something says otherwise

        ld      a,ST_ENTER
        ld      (w_stage),a
        out     (0xFE),a

        ; -- port 0xE3 AS FOUND. Readable: port_e3_rd (:2727), port_e3_rd_dat
        ;    (:2815), port_e3_dat = reg(7:6) & "00" & reg(3:0) (:4190).
        ;    Bit 7 = CONMEM, bit 6 = MAPRAM, bits 3:0 = the DivMMC bank. This
        ;    is what makes the restore EXACT instead of guessed, and it is the
        ;    reason there is no "which bank do we page back?" problem here.
        in      a,(0xE3)
        ld      (v_e3),a

        ; -- NR 0x0A: save, then clear bit 4 (nr_0a_divmmc_automap_en, :5196).
        ;    Clearing it forces divmmc_automap_reset (:4112), which zeroes
        ;    automap_hold AND automap_held outright. This is the off switch.
        ld      bc,0x243B
        ld      a,0x0A
        out     (c),a
        inc     b
        in      a,(c)
        ld      (v_0a),a
        IF DIVMMC_OFF = 1
        and     0xEF
        out     (c),a

        ; -- CONMEM off. MAPRAM is STICKY (port_e3_reg(6) <= cpu_do(6) or
        ;    port_e3_reg(6), :4182) so writing 0 cannot clear it — harmless,
        ;    because DivMMC is off either way once CONMEM and automap are.
        xor     a
        out     (0xE3),a
        ENDIF

        ld      a,ST_DIVMMC_OFF
        ld      (w_stage),a
        out     (0xFE),a

        ; -- NR 0x03 as found. nr_03_machine_type is initialised "011" and only
        ;    ever assigned 001/010/011/100 (:1103, :5139-5142), so bits 2:0 are
        ;    NEVER 000 and writing them back is always a valid "leave config
        ;    mode" (:5147-5151). ASK the machine rather than choosing a value:
        ;    this corrects the sketch in doc/CONFIG-MODE-ROM-REPLACEMENT.md §1.3,
        ;    which said to write back the machine type you want.
        ld      bc,0x243B
        ld      a,0x03
        out     (c),a
        inc     b
        in      a,(c)
        ld      (v_03),a
        and     0x07
        ld      (v_mach),a

        ; -- port 0x123B: save, then clear the two layer-2 MAPPING bits.
        ;    sram_layer2_map_en (:3077) is checked by the same second arbiter
        ;    DivMMC is, and config mode's override value "110" (:3050) leaves
        ;    layer 2 eligible too. Bit 0 = map_wr_en, bit 2 = map_rd_en
        ;    (:3916-3918); the read-back has bit 4 = 0 (:3933), so writing it
        ;    back takes the same branch it came from.
        ld      bc,0x123B
        in      a,(c)
        ld      (v_123b),a
        and     0xFA
        out     (c),a

        ; -- NR 0x81 bit 5: the ONE NMI source config mode does NOT suppress.
        ;    :2102-2105 clears nmi_mf/nmi_divmmc/nmi_expbus continuously while
        ;    config mode is set, but nmi_generate_n's third term (:2168) is
        ;    gated on neither nmi_state nor nmi_activated, so an expansion-bus
        ;    NMI with debounce disabled still latches and would be serviced
        ;    mid-copy — and LDIR re-checks NMI_s every iteration
        ;    (cpu/t80n_mcode.vhd:2095-2101, t80n.vhd:1757-1766). Default is 0
        ;    (:1222); this is belt and braces against something having set it.
        ld      bc,0x243B
        ld      a,0x81
        out     (c),a
        inc     b
        in      a,(c)
        ld      (v_81),a
        and     0xDF
        out     (c),a

        ; -- MMU0: save and set to 0xFF (the ROM mapping). The SECOND branch of
        ;    the four-way pre-arbiter, mmu_A21_A13(8) = '0' (:3036), BEATS
        ;    config mode, so slot 0 must not hold a RAM page. Measured already
        ;    0xFF under NextZXOS; forced anyway, because a value that happens to
        ;    be right is not a value that was checked.
        ld      bc,0x243B
        ld      a,0x50
        out     (c),a
        inc     b
        in      a,(c)
        ld      (v_50),a
        ld      a,0xFF
        out     (c),a

        ; -- enter config mode and select 16K config bank 5 -------------------
        ;    NR 0x03 bits 2:0 = 111 (:5147) — SEVEN, not one, and not "clear the
        ;    bottom three bits": both Discord accounts in issue #21 are wrong as
        ;    stated, and 000 hits neither branch and does nothing at all.
        ;    Bit 3 clear so user_dt_lock is not toggled (it is an XOR, :5135);
        ;    bit 7 clear so the machine TIMING case is not entered (:5124-5133).
        ;    NR 0x04 = 5 puts the MF ROM at 0x0000-0x1FFF and MF RAM at
        ;    0x2000-0x3FFF, WRITABLE (:3044-3050).
        ld      bc,0x243B
        ld      a,0x03
        out     (c),a
        inc     b
        ld      a,0x07
        out     (c),a
        dec     b
        ld      a,0x04
        out     (c),a
        inc     b
        ld      a,0x05
        out     (c),a

        ld      a,ST_CONFIG_IN
        ld      (w_stage),a
        out     (0xFE),a

        ;---------------------------------------------------------------------
        ; THE WINDOW IS OPEN. Everything between here and the exit runs with
        ; 0x0000-0x1FFF = the Multiface ROM, writable.
        ;---------------------------------------------------------------------
        ld      a,(w_op)
        cp      OP_SYNC
        jr      z,.sync

        ; -- OP_READ_ID: the live ROM's identity block ------------------------
        ; This is what makes the tool idempotent, and it can only be done HERE:
        ; outside the window 0x1FE0 is somebody else's memory entirely.
        ;
        ; It has no verify of its own, and that degrades safely: if DivMMC were
        ; somehow still on, this would read the DivMMC ROM's bytes, which carry
        ; no magic, so the caller would conclude "not ours" and go on to install
        ; — where the write's own verify catches the real fault.
        ld      hl,MAGIC_OFF
        ld      de,w_id
        ld      bc,MAGIC_READ
        ldir
        jr      .op_done

.sync:
        ; -- OP_SYNC: COMPARE, write only if different, then verify -----------
        ;
        ; THE COMPARE IS WHAT MAKES THE TOOL IDEMPOTENT, and it is idempotent BY
        ; CONSTRUCTION rather than by rule. The caller used to decide whether to
        ; write by matching the identity block's variant field — which answers
        ; "is a WiFi ROM live", not "are these the bytes". A stub rebuilt without
        ; a version bump is a different ROM wearing the same identity, and its
        ; developer is exactly who runs this repeatedly. So the question asked
        ; here is the only one that cannot be wrong: do the bytes differ?
        ;
        ; It costs one extra pass over 4 KB and no extra window entry, because
        ; the caller has already put the bytes in BUF in order to write them.
        call    .compare
        jr      nz,.differs

        ld      a,RES_SAME
        ld      (w_res),a
        jr      .op_done

.differs:
        ; The LDIR writes THROUGH 0x0000, 0x0008, 0x0038 and 0x0066 — every
        ; DivMMC automap entry point — because it is copying an image over them.
        ; That cannot re-trigger automap: automap_hold only updates on
        ; `i_cpu_mreq_n = '0' and i_cpu_m1_n = '0'` (divmmc.vhd:126-131) and the
        ; divmmc_automap_*_q inputs are cleared whenever cpu_m1_n = '1'
        ; (:4115-4119). M1 FETCHES ONLY; a write cannot do it. Worth stating
        ; because the live `automap` expression at divmmc.vhd:148 has had its
        ; `not i_cpu_m1_n` term commented out, so the gating is not where a
        ; reader looks for it.
        ld      hl,BUF
        ld      de,(w_dst)
        ld      bc,(w_len)
        ldir

.verify:
        ; VERIFYING INSIDE THE WINDOW IS THE WHOLE POINT, and it is not belt and
        ; braces. Outside it there is nothing to read: 0x0000 is the DivMMC ROM
        ; again. A silently discarded write is this mechanism's ENTIRE failure
        ; mode — it is what a naive dot command does, every time — so a tool that
        ; reported success on having reached the end of a routine would report
        ; success on doing nothing at all.
        ;
        ; It is the SAME routine the compare above uses, deliberately: two copies
        ; of one loop is two places for a later correction to miss, and the
        ; second call is what turns "we wrote" into "it is there".
        call    .compare
        jr      z,.op_done
        ld      a,RES_VERIFY
        ld      (w_res),a

.op_done:
        ld      a,ST_OP_DONE
        ld      (w_stage),a
        out     (0xFE),a

        ; -- leave config mode, writing back the machine type we READ ---------
        ld      bc,0x243B
        ld      a,0x03
        out     (c),a
        inc     b
        ld      a,(v_mach)
        out     (c),a

        ld      a,ST_CONFIG_OUT
        ld      (w_stage),a
        out     (0xFE),a

        ; -- restore MMU0, NR 0x81, NR 0x0A, port 0x123B ----------------------
        ; NR 0x04 is NOT restored, and that is not an omission: it is
        ; WRITE-ONLY — nextreg.txt:85-90 documents no read, and the register
        ; read mux goes X"03" straight to X"05" (:5893-5896), so a read returns
        ; 0x00 from `when others`. It also does not need restoring, being
        ; consulted nowhere outside the config-mode branch (:3045).
        ld      bc,0x243B
        ld      a,0x50
        out     (c),a
        inc     b
        ld      a,(v_50)
        out     (c),a

        dec     b
        ld      a,0x81
        out     (c),a
        inc     b
        ld      a,(v_81)
        out     (c),a

        IF DIVMMC_OFF = 1
        dec     b
        ld      a,0x0A
        out     (c),a
        inc     b
        ld      a,(v_0a)
        out     (c),a
        ENDIF

        ld      bc,0x123B
        ld      a,(v_123b)
        out     (c),a

        ld      a,ST_RESTORED
        ld      (w_stage),a
        out     (0xFE),a

        ;---------------------------------------------------------------------
        ; Bring DivMMC back, so the dot command at 0x2000 exists again.
        ;
        ; Restoring NR 0x0A does NOT restore automap_held — clearing bit 4
        ; zeroed it (:4112), and automap only re-arms on an M1 fetch at an entry
        ; point, which by then is unreachable because the command at 0x2000 is
        ; gone. So CONMEM is used as a bridge, with the ORIGINAL bank and MAPRAM
        ; bits, and one `rst 8` provides the M1 fetch at 0x0008, where
        ; i_automap_active (= sram_pre_override(2), :3137) is true because
        ; cpu_a(15 downto 14) = "00".
        ;
        ; MEASURED: this invocation had CONMEM ALREADY SET (E3 = 0x82), so
        ; `saved | 0x80` == `saved` and the bridge is a no-op — a control run
        ; with the `rst 8` removed entirely also survived. IT IS KEPT ANYWAY,
        ; and the reason is a limit of the measurement rather than a preference:
        ; 0x82 is what THIS NextZXOS gave THIS dot command typed at THIS command
        ; line. Nothing shows a dot command is always CONMEM-mapped. If one is
        ; ever automapped with CONMEM = 0, the exact restore alone puts DivMMC
        ; back OFF and the return to 0x2000 lands nowhere. Six bytes.
        ;
        ; `--auto` from AUTOEXEC.BAS has since run on a real Next and the whole
        ; sequence SURVIVED it — which retires the worry that that path might be
        ; broken, and NOT the reason this is here: nobody read 0xE3 back there,
        ; so which mapping it ran under is still unobserved.
        IF DIVMMC_OFF = 1
        ld      a,(v_e3)
        or      0x80                    ; CONMEM on, original MAPRAM and bank
        out     (0xE3),a

        ld      a,ST_BRIDGE
        ld      (w_stage),a
        out     (0xFE),a

        rst     8
        defb    0x88                    ; M_DOSVERSION — takes no arguments and
                                        ; only reports a version. The stack it
                                        ; uses is ours, high and 768 deep.

        ld      a,(v_e3)                ; exact restore of CONMEM/MAPRAM/bank
        out     (0xE3),a
        ENDIF

        ld      a,ST_DONE
        ld      (w_stage),a
        out     (0xFE),a

        ld      sp,(v_sp)               ; the caller's stack is mapped again
        ei
        ret

;-----------------------------------------------------------------------------
; .compare — Z when the w_len bytes at BUF equal the w_len bytes at w_dst.
;
; CALLed, which is safe and is worth saying once: the stack is at STACK_TOP in
; high RAM, and config mode remaps only 0x0000-0x3FFF (:3029), so a return
; address pushed inside the window is still there when it is popped.
;
; Only ever reached with the window open, so it reads the Multiface ROM.
;-----------------------------------------------------------------------------
.compare:
        ld      hl,BUF
        ld      de,(w_dst)
        ld      bc,(w_len)
.cmp_loop:
        ld      a,(de)
        cp      (hl)
        ret     nz                      ; differ: NZ, and BC/DE/HL say where
        inc     hl
        inc     de
        dec     bc
        ld      a,b
        or      c
        jr      nz,.cmp_loop
        ret                             ; equal: `or c` left Z set

window_end:

        ; The routine must not run into its own variables. VARS is where the
        ; caller writes the parameters, so an overrun would be a routine that
        ; overwrites its own arguments — silently, and only once it grew.
        ASSERT  window_end <= VARS

        ; And the caller's 4 KB buffer must end exactly where this begins.
        ASSERT  BUF + 4096 <= CODE_ORG

        ; The output path comes from the Makefile, as every other assembled
        ; fixture here does it (-DNMI_TRIGGER_BIN, -DCOPPER_NMI_BIN, ...), so
        ; nothing is written into the source tree.
        SAVEBIN MFWIN_BIN, window, window_end - window
