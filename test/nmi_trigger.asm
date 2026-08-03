;===========================================================================
; nmi_trigger.asm
;
; Test fixture for the headless jnext bench: fires a Multiface NMI from
; guest code, then parks.
;
; Why this exists: the M1 (yellow) button is a HOST control in jnext (the
; F9 key / toolbar button), so it cannot be reached from --delayed-keypress,
; which only injects Spectrum membrane keys. Without this fixture there is
; no way to enter the stub in a headless run.
;
; The mechanism is the software NMI, not the button:
;
;   zxnext.vhd:3832
;     nmi_gen_nr_mf <= (nmi_cpu_02_we and cpu_requester_dat(3))
;                       or (nmi_cu_02_we and copper_nr_dat(3));
;   zxnext.vhd:3837
;     nmi_sw_gen_mf <= nmi_gen_nr_mf or nmi_gen_iotrap;
;   zxnext.vhd:2090
;     nmi_assert_mf <= '1' when (hotkey_m1 = '1' or nmi_sw_gen_mf = '1')
;                      and nr_06_button_m1_nmi_en = '1' else '0';
;
; i.e. a CPU write of NR 0x02 with bit 3 set raises the Multiface NMI, but
; ONLY while NR 0x06 bit 3 is set (zxnext.vhd:5166). That gate applies to
; every MF NMI source including the Copper one, so it is not optional.
; NR 0x06 reads back (zxnext.vhd:5900), so the enable is a read-modify-write
; and leaves the other bits of NR 0x06 alone.
;
; Note what this fixture can and cannot reach today. The NMI *is* delivered —
; the stock Multiface ROM proves it (bench T3) — but mf_rom.asm's nmi66h then
; reads NR 0x02, masks 00011100b and returns unless it is zero, i.e. it serves
; button presses only. NR 0x02 bit 3 reads back as nr_02_generate_mf_nmi
; (zxnext.vhd:3843-3848), set by this very write, so the stub declines. That
; is the bench's T4 expectation, and M2's Copper break will hit the same gate.
;===========================================================================

    DEVICE ZXSPECTRUMNEXT

TBBLUE_REGISTER_SELECT: equ 0x243B
TBBLUE_REGISTER_ACCESS: equ 0x253B

REG_RESET:              equ 0x02    ; bit 3 = generate Multiface NMI
REG_PERIPHERAL_2:       equ 0x06    ; bit 3 = M1 button / MF NMI enable

    ORG 0x8000

start:
    ; NR 0x06 |= bit 3 — without this the NMI is gated off.
    ld bc,TBBLUE_REGISTER_SELECT
    ld a,REG_PERIPHERAL_2
    out (c),a
    ld bc,TBBLUE_REGISTER_ACCESS
    in a,(c)
    or 0x08
    out (c),a

    ; NR 0x02 = bit 3 — raise the Multiface NMI.
    ld bc,TBBLUE_REGISTER_SELECT
    ld a,REG_RESET
    out (c),a
    ld bc,TBBLUE_REGISTER_ACCESS
    ld a,0x08
    out (c),a

    ; Park. The NMI takes the CPU away from here; if it never fires, the
    ; bench sees an unchanged screen and reports the failure.
.hang:
    jr .hang
end:

    SAVEBIN NMI_TRIGGER_BIN, start, end-start
