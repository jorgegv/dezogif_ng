;===========================================================================
; ui.asm
;
; The simple UI.
; Text output and keyboard input.
;===========================================================================



;===========================================================================
; Const data
;===========================================================================

; Error definitions
ERROR_RX_TIMEOUT:			equ 1
ERROR_RX_OVERFLOW:          equ 2
ERROR_TX_TIMEOUT:			equ 3
ERROR_WRONG_FUNC_NUMBER:	equ 4
ERROR_WRITE_MAIN_BANK:	    equ 5
ERROR_CORE_VERSION_NOT_SUPPORTED:  equ 6
ERROR_CMD_NOT_SUPPORTED:    equ 7

; A frame declared more payload than the 8 KB swap window can hold, so honouring
; it would have written over whatever sits above that window — for SWAP_SLOT,
; the bank the debugger is running from. Raised by cmd_loopback and
; cmd_write_bank; see error_payload_too_big in commands.asm for why the client
; gets no answer at all.
ERROR_PAYLOAD_TOO_BIG:      equ 8

 IF ROM_VARIANT == ROM_VARIANT_WIFI
; WiFi mode only: the module answered, the listener is up, and it has no
; address to hand out. Raised by transport_init; see transport_esp.asm.
ERROR_NO_WIFI_ADDRESS:      equ 9

; WiFi mode only, and NOT a fault of its own: the stub met ESP_FAULT_LIMIT
; transport faults in a row and ran the AT chain again by itself (issue #16,
; part C). It replaces the fifth fault's own code, because "I have just
; re-established the module, and any connection you had is gone" is the thing a
; user needs to know — the fifth timeout is a symptom of it. A recovery that
; then failed reports ITS failure instead, through transport_activate.
ERROR_ESP_REINIT:           equ 10
 ENDIF


;===========================================================================
; Checks key "R".
; If pressed a reset is done.
;===========================================================================
check_key_reset:
    ; Read port
    ld bc,PORT_KEYB_TREWQ
    in a,(c)
    bit 3,a ; "R"
    ret nz
    ; Wait on key release
.wait_on_release:
    call wait_on_key_release
    ; Reset
    nextreg REG_RESET, 01b


;===========================================================================
; Checks key "B".
; For turning slow border change on/off.
; Returns:
;   Z = B pressed
;   NZ = B not pressed
;===========================================================================
check_key_border:
    ; Read port
    ld bc,PORT_KEYB_BNMSHIFTSPACE
    in a,(c)
    bit 4,a ; "B"
    ret nz
    ; Wait on key release
    call wait_on_key_release
    ; Toggle
    ld a,(slow_border_change)
    xor 1
    ld (slow_border_change),a
    jr nz,.ret
    ; Turn border black
    xor a
    out (BORDER),a
.ret:
    xor a   ; Z
    ret



;===========================================================================
; Installs the two-instruction Copper list that raises a Multiface NMI once per
; frame - the clock mf_nmi_poll rides on, and therefore the whole of
; PC-initiated break.
;
;   WAIT line,0    = 0x8000 | (hpos<<9) | line
;   MOVE $02,$08   = (reg<<8) | value   -> NR 0x02 bit 3, the Multiface NMI
;
; Encoding from device/copper.vhd:91-104. It is the same listing a user's own
; program carries in doc/ASYNCHRONOUS-BREAK-USER-HOWTO.md.
;
; WHY THE DEBUGGER MAY INSTALL THIS AT ALL, having deliberately not done so
; since M2 was built. The Copper's instruction list is WRITE-ONLY - both
; instruction RAMs discard their CPU-side read output (zxnext.vhd:3959-3976,
; :3980-3998) and NR 0x60/0x63 have no read decode (:6286-6287) - so whatever
; is installed here can never be given back. That fact is unchanged and is why
; the debugger did not install one. What makes it acceptable is WHEN: the only
; caller is cmd_init, which runs as a debug client opens a session, BEFORE it
; has pushed the program's banks and long before the program has run. There is
; nothing there yet to destroy. A program that uses the Copper installs its own
; list when it runs, overwriting this one - so it keeps its raster effects and
; carries the two instructions itself, exactly as the HOWTO already tells it to.
;
; IT FOLLOWS THAT THIS MUST NOT BE CALLED FROM A RESUME OR FROM A BREAK. By
; then the debuggee's own list may be live, and re-installing would destroy it
; on every single CMD_CONTINUE - which would take the HOWTO's route away from
; precisely the programs it was written for.
;
; AND "cmd_init RUNS BEFORE THE PROGRAM HAS RUN" IS ONLY TRUE OF A *FIRST*
; ATTACH, WHICH IS WHY prgm_state IS TESTED BELOW. Found in review, and the
; path is ordinary rather than exotic: a debuggee resumed with CMD_CONTINUE and
; no breakpoint is exactly this feature's headline use case; the client's
; connection can then be lost with no CMD_CLOSE (KNOWN-ISSUES.md #18/#19, and
; nothing detects that while a debuggee is genuinely running); a new client
; connects and its CMD_INIT is the first byte the poll sees, which breaks in and
; dispatches it here. cmd_call has no prgm_state guard of its own - the dispatch
; is on the command byte alone - so without the test below that reconnect would
; silently overwrite the debuggee's own live list, irrecoverably.
;
; PRGM_IDLE is exact for the question: it holds only while nothing is loaded,
; running or stopped. Anything else means a debuggee exists and may own the
; Copper. The break itself is not lost by refusing - the list installed on the
; first attach is still running unless the debuggee replaced it, and the "C" key
; forces an install if a user really wants one.
;
; WHAT THIS DOES *NOT* GUARD, AND THE REASON IS BETTER THAN THE ONE THIS COMMENT
; FIRST GAVE. Nothing stops the Copper when a session ends, so a later CMD_INIT
; installs over whatever the previous program left running. That is reached from
; FIVE places, not the one this note used to name: `main`'s prologue is what
; writes PRGM_IDLE, and it is entered from cmd_close (commands.asm) and from
; drain_main's four callers - cmd_not_supported, error_payload_too_big,
; error_write_main_bank, and rx_timeout/rxtx_error in BOTH transports. Only the
; first of those is "the client said the session is over"; an RX timeout is the
; stub deciding so after a network hiccup. Enumerated in review, 2026-08-15.
;
; It is accepted for all five, and by ONE argument rather than five: `main`'s
; prologue says in its own comment that coming there means "there is no session
; to preserve", and it acts on that - it resets backup.speed,
; backup.interrupt_state, backup.layer_2_port and slot_backup.slot0. So by the
; time PRGM_IDLE is readable the debuggee can no longer be correctly resumed
; whatever we do about the Copper, and destroying its list is a consequence of a
; loss that has already happened rather than a new one. Nothing stages it.
;
; THAT ARGUMENT IS ALSO WHY THE OBVIOUS STRUCTURAL FIX IS WRONG. Calling
; copper_break_stop from main's prologue would make "PRGM_IDLE implies no live
; Copper" a real invariant - and would stop a Copper-using debuggee's raster
; effects on every RX timeout, including the ones after which nobody re-attaches
; and nothing else was lost. Strictly worse, and three bytes there are not free.
; Changes:
;   AF, BC
;===========================================================================
copper_break_arm:
    ; A FIRST attach only. Its caller reads prgm_state BEFORE overwriting it
    ; with PRGM_LOADING - see the ordering note at the call site in cmd_init,
    ; because getting that wrong makes this test silently inert.
    ld a,(prgm_state)
    cp PRGM_IDLE
    ret nz
    ; The "C" key's state, tested here rather than at the call site so that
    ; cmd_init carries one call and no branch.
    ld a,(copper_break_enabled)
    or a
    ret z
    ; Flow through


copper_break_install:
    ; NR 0x06 bit 3 gates EVERY Multiface NMI source and its power-on value is
    ; 0. NextZXOS leaves it set, so this is insurance rather than setup - but a
    ; debuggee that had cleared it would otherwise kill the break silently, and
    ; nothing else here would ever put it back.
    call mf_nmi_enable

    ; Stop the Copper and put its write pointer at index 0.
    nextreg REG_COPPER_CONTROL_H,RCCH_COPPER_STOP
    nextreg REG_COPPER_CONTROL_L,0

    ; The list, MSB first.
    nextreg REG_COPPER_DATA,HIGH (0x8000+COPPER_BREAK_LINE)
    nextreg REG_COPPER_DATA,LOW (0x8000+COPPER_BREAK_LINE)
    nextreg REG_COPPER_DATA,REG_RESET
    nextreg REG_COPPER_DATA,00001000b

    ; Run from index 0, looping. The mode CHANGING to 01 is what resets the
    ; pointer (device/copper.vhd:69-78), which the stop above guarantees.
    nextreg REG_COPPER_CONTROL_H,RCCH_COPPER_RUN_LOOP_RESET
    ret


;===========================================================================
; Stops the Copper outright.
;
; Note what this does NOT do: remove our two instructions. The list cannot be
; read, so it cannot be edited - stopping the Copper is the only "off" there
; is, and it stops a debuggee's OWN list too if the debuggee installed one.
; That is the honest cost of the "C" key, and it is why the key exists rather
; than the feature simply being unconditional.
; Changes:
;   nothing. `nextreg n,n` is the Z80N immediate-immediate form (ED 91 rr nn)
;   and touches no register; this header said "AF, BC" until the review counted
;   the bytes. Its one caller clobbers AF on return regardless.
;===========================================================================
copper_break_stop:
    nextreg REG_COPPER_CONTROL_H,RCCH_COPPER_STOP
    ret


;===========================================================================
; Checks key "C".
; Turns PC-initiated break on and off. Off is worth having for two reasons: the
; poll costs ~1288 T-states a frame, which is 0.230% of a frame at 28 MHz but
; 1.84% at 3.5 MHz, and a program that owns the Copper may want the debugger to
; keep its hands off it.
; Returns:
;   Z = C pressed
;   NZ = C not pressed
;===========================================================================
check_key_copper:
    ; Read port
    ld bc,PORT_KEYB_VCXZCAPS
    in a,(c)
    bit 3,a ; "C"
    ret nz
    ; Wait on key release. BC still holds the port, as check_key_border relies
    ; on too.
    call wait_on_key_release
    ; Toggle
    ld a,(copper_break_enabled)
    xor 1
    ld (copper_break_enabled),a
    jr z,.off
    call copper_break_install
    jr .ret
.off:
    call copper_break_stop
.ret:
    xor a   ; Z
    ret


 IF ROM_VARIANT == ROM_VARIANT_UART
;===========================================================================
; Reads the joyport from the keyboard.
;
; UART MODE ONLY. WiFi mode never touches the joy ports (transport_esp.asm,
; point 4), so there is nothing for 1/2/3 to select and no line on the screen
; for them to change.
; Returns:
;  E: 0x00=00b => "3": no joystick port used
;     0x01=01b => "1": joyport 1
;     0x02=10b => "2": joyport 2
;     0xFF => no key pressed
;===========================================================================
read_key_joyport:
    ; Read port
    ld bc,PORT_KEYB_54321
    in a,(c)
    ld e,0xFF   ; Default
    bit 0,a ; "1"
    jr nz,.no_key_1
    ld e,0x01
    jr .cont
.no_key_1:
    bit 1,a ; "2"
    jr nz,.no_key_2
    ld e,0x02
    jr .cont
.no_key_2:
    bit 2,a ; "3"
    ret nz
    ld e,0x00

.cont:
    ; Flow through wait_on_key_release
 ENDIF


;===========================================================================
; Waits on key release.
; Parameters:
;   BC = the port to usefor the keys.
; Changes:
;   AF
;===========================================================================
wait_on_key_release:
    in a,(c)
    and 0x1F
    cp 0x1F
    jr nz,wait_on_key_release
    ret


;===========================================================================
; Puts the display file under 0x4000 for the duration of a paint, and remembers
; what was there — issue #28.
;
; show_ui writes the whole screen area through 0x4000, opening with a MEMCLEAR
; of SCREEN_SIZE, and 0x4000 is the display file ONLY while MMU slot 2 says so.
; `CMD_SET_SLOT 2,<bank>` is an ordinary DZRP command — a client inspecting a
; bank — and cmd_set_slot writes the MMU register directly for every slot but 7,
; telling this file nothing. So any later redraw (the "B" key through
; main_redraw, a CMD_CLOSE through `jp main`, or any drain_main) cleared
; 0x4000-0x5CDF of the CLIENT'S bank instead of the screen — 6144 bytes of
; MEMCLEAR plus 1248 of attribute MEMFILL, 7392 in all, plus the glyphs drawn
; inside it. (Issue #28 says "8 KB"; that is the size of the SLOT, not of the
; write.) Permanently: only slot_backup.slot0 and .slot7 are ever saved, so no
; per-bank backup exists to put it back, and the debuggee is handed the wreckage
; on its next CMD_CONTINUE. Upstream's, and in both builds.
;
; IT FORCES AND RESTORES RATHER THAN CHECKING AND ABANDONING, which is the other
; shape and is what esp_refresh_client_line does one row along. Abandoning is
; right there: that painter keeps a single line current, and skipping it costs a
; stale row until the next full repaint. It is wrong here, because show_ui IS
; the debugger's screen — a "B" press or a CMD_CLOSE that drew nothing would
; leave the machine showing whatever happened to be on it, and `last_error`
; would go unreported in the one place a user is told to look. Forcing also ends
; a second, older defect for free: an M1 press against a debuggee whose own slot
; 2 was not the screen used to paint the UI into that debuggee's memory and
; leave the display untouched, which reads as a stub that did not come up.
;
; NR 0x52 READS BACK the live MMU2 (zxnext.vhd:6059-6081, returning the same
; MMUn that decodes CPU addresses at :2952-2964; slot 2's decode is untouched by
; the Multiface and config-mode overrides, which are scoped to slots 0/1 at
; :3029-3066). So the original goes back exactly and no caller has to be told
; anything — which is what keeps this out of commands.asm, whose hard rule is
; that it must not be able to tell which transport it was assembled against, and
; away from the enumeration hazard a macro at every `nextreg REG_MMU...` site
; would carry (see esp_refresh_client_line, which rejected exactly that).
;
; AND THE FORCE SURVIVES THE FIRST THING show_ui_body DOES, which had to be
; checked rather than assumed: issue #31 records that a write of NR 0x8E or of
; ports 0x7FFD/0x1FFD/0xDFFD/0xEFF7 RE-DERIVES the MMU and would silently undo a
; slot just set, and show_ui_body's very first act is `nextreg
; REG_DISPLAY_CONTROL,0`, which reaches port_7ffd_reg(3). It is safe because
; nr_69_we is NOT a term of port_memory_change_dly (zxnext.vhd:3813) — that list
; is port_7ffd_wr, port_1ffd_wr, port_dffd_wr, port_eff7_wr, nr_8e_we and
; nr_8f_we_dly, i.e. actual PORT writes and two other registers. So the NextREG
; route into that bit does not trigger the re-derivation and this force holds.
;
; THE BACKUP IS A BYTE IN MEMORY AND NOT THE STACK, for font_map's reason: this
; sits either side of a `call` and must not be under the return address. One
; save area is enough because show_ui does not nest.
; Changed registers:
;   AF, BC
;===========================================================================
screen_map:
    ld a,REG_MMU+2
    call read_tbblue_reg
    ld (screen_map_backup),a
    nextreg REG_MMU+2,SCREEN_BANK
    ret


;===========================================================================
; Puts back exactly what screen_map found.
; Changed registers:
;   AF
;===========================================================================
screen_unmap:
    ld a,(screen_map_backup)
    nextreg REG_MMU+2,a
    ret


;===========================================================================
; Switches to ULA mode and shows the intro text.
; Displaying which keys can be used to change the joy port.
;===========================================================================
; A SHELL, AND THE SHELL IS THE POINT. Painting needs two windows that are not
; the debugger's to keep: MMU slot 2, so that 0x4000 is the screen (issue #28,
; screen_map above), and MMU slot 1, so that the glyphs can be read out of the
; ROM since issue #31 stopped copying them into this bank (text.font_map).
; NEITHER SLOT HAS A BACKUP ANYWHERE — slot_backup holds slots 0 and 7 only — so
; the MMU register is itself the debuggee's storage for both, and each is what
; cmd_get_registers reports and what the debuggee resumes with.
;
; IT IS A SHELL RATHER THAN A PROLOGUE AND EPILOGUE INSIDE THE BODY because the
; body has TWO exits: an early `ret z` when there is no error to report, and a
; tail `jp` into print_string. A restore written at "the end" of the routine runs
; on one of them, and ERRORS.md carries that failure twice already
; ("Enumerating a control flow's exits by reading the ones you expected").
; Wrapping a `call` cannot miss an exit that has not been thought of.
show_ui:
    call screen_map
    call text.font_map
    call show_ui_body
    call text.font_unmap
    jp screen_unmap


show_ui_body:
    ; Switch to ULA
    nextreg REG_ULA_X_OFFSET, 0
    nextreg REG_ULA_Y_OFFSET, 0
    nextreg REG_ULA_CONTROL, 0
    nextreg REG_DISPLAY_CONTROL, 0
    nextreg REG_SPRITE_LAYER_SYSTEM, 00010000b   ; USL
    ; Turn off clipping (might have been used by screensaver)
    nextreg REG_CLIP_WINDOW_CONTROL, RCWC_RESET_ULA_CLIP_INDEX
    nextreg REG_CLIP_WINDOW_ULA, 0
    nextreg REG_CLIP_WINDOW_ULA, 255
    nextreg REG_CLIP_WINDOW_ULA, 0
    nextreg REG_CLIP_WINDOW_ULA, 191

    ; Clear the screen
    MEMCLEAR SCREEN, SCREEN_SIZE
    ; Black on white
    MEMFILL COLOR_SCREEN, WHITE+(BLACK<<3), COLOR_SCREEN_SIZE+15*COLOR_SCREEN_WIDTH
    ; Red on black for a probable error report
    MEMFILL COLOR_SCREEN+15*COLOR_SCREEN_WIDTH, RED+BRIGHT, 9*COLOR_SCREEN_WIDTH

    ; Print text
    ld de,INTRO_TEXT
    call text.ula.print_string

    ; Show core version
    ld a,REG_VERSION
    call read_tbblue_reg
    ld h,a  ; Save major and minor number
    ; Shift major number
    rra : rra : rra : rra
    and 0x0F
    ld de,text_core_version.major
    call itoa_2digits
    ; Minor version
    ld a,h
    and 0x0F
    ld de,text_core_version.minor
    call itoa_2digits
    ; Subminor
    ld a,REG_SUB_VERSION
    call read_tbblue_reg
    ld l,a    ; save subminor
    ld de,text_core_version.subminor
    call itoa_2digits

    ; Check version against core version 3.01.10 (minimum version)
    ; (hl = current version)
    ld de,(3 << 12) + (1 << 8) + (10)
    sbc hl,de   ; current version - 3.01.10
    jp p,.core_version_continue

    ; Core version not supported
    ld a,(last_error)
    or a
    jr nz,.core_version_continue	; There is already an error

    ; Report "core version not supported" error
    ld a,ERROR_CORE_VERSION_NOT_SUPPORTED
    ld (last_error),a

.core_version_continue:
    ; Print
    ld de,text_core_version
    call text.ula.print_string

    ; Get display timing
    ld a,REG_VIDEO_TIMING
    call read_tbblue_reg
    and 0111b			;video timing is in bottom 3 bits, e.g. HDMI=111b
    ; Print the number
    add '0' ; convert to ASCII
    ld (text_one_char.char),a
    ld de,text_one_char
    call text.ula.print_string

    ; The transport's own status block, at rows 6 and 7. This is the UI half of
    ; the assembly-time switch (MEMORY.md 2026-08-05): it is the one part of
    ; this screen whose content is a property of the transport, so the two
    ; modes fill it with different things rather than sharing a line that would
    ; be false in one of them.
 IF ROM_VARIANT == ROM_VARIANT_WIFI
    ; The connect address, or why there is not one.
    call esp_show_status
 ELSE
    ; Show right selected joy port option
    ld hl,SELECTED_TEXT_TABLE
    ld a,(uart_joyport_selection)
    add a   ; *2
    add hl,a
    ld de,(hl)
    call text.ula.print_string
 ENDIF

    ; Show border option
    ld de,BORDER_ON_TEXT
    ld a,(slow_border_change)
    or a
    jr z,.print_border
    ld de,BORDER_OFF_TEXT
.print_border:
    call text.ula.print_string

    ; Show PC-break option. Row 14, which was the one free row on BOTH screens
    ; - the benches that read this screen as text read rows 7, 8 and 12, so
    ; nothing they look at moves.
    ld de,COPPER_OFF_TEXT
    ld a,(copper_break_enabled)
    or a
    jr z,.print_copper
    ld de,COPPER_ON_TEXT
.print_copper:
    call text.ula.print_string

    ; Print 3 lines debugging
 IFDEF DEBUG
    ; Caclulate screen address
    ld de,256*8*debug.TEXT_START_POSITION_LINE + 8*debug.TEXT_START_POSITION_CLMN
    call text.ula.calc_address
    ld de,debug.text
    call text.ula.print_string
 ENDIF

    ; Show possibly error
    ld a,(last_error)
    or a
    ret z	; 0 = no error

    ; Print "Last error:"
    ld de,TEXT_LAST_ERROR
    call text.ula.print_string
    push hl	; Save pointer to screen

    ; Print error message
    ld a,(last_error)
    dec a
    add a	; 2*A
    ld hl,ERROR_TEXT_TABLE
    add hl,a
    ld de,(hl)
    pop hl	; Restore pointer to screen
    jp text.ula.print_string
