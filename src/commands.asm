;===========================================================================
; commands.asm
;
;
;===========================================================================



;===========================================================================
; Structs
;===========================================================================

    ; Used in backup/restore of the slots.
    STRUCT SLOT_BACKUP
slot0:		defb	; Saved when entering debugging (RST 0), restored on continue. At the moment this must be 0xFF=ROM. I.e. saving/restoring has no real meaning. In future, when using UART interrupts, this will make more sense.
slot7:		defb	; Saved when entering debugging (RST 0), restored on continue.
tmp_slot:	defb	; Normally SWAP_SLOT but could be also other.
    ENDS



;===========================================================================
; Const data.
;===========================================================================

; DZRP version 2.1.0
DZRP_VERSION.MAJOR:		equ 2
DZRP_VERSION.MINOR:		equ 1
DZRP_VERSION.PATCH:		equ 0



; The own program name and version
PROGRAM_NAME:	defb "dezogif "
                PRG_VERSION
                defb 0
.end


; Command number <-> subroutine association
cmd_jump_table:
                    defw cmd_not_supported		; 0 = reserved
.init:				defw cmd_init				; 1
.close:				defw cmd_close				; 2
.get_registers:		defw cmd_get_registers		; 3
.set_register:		defw cmd_set_register		; 4
.write_bank:		defw cmd_write_bank			; 5
.continue:			defw cmd_continue			; 6
.pause:				defw cmd_pause				; 7, acknowledged; see cmd_pause
.read_mem:			defw cmd_read_mem			; 8
.write_mem:			defw cmd_write_mem			; 9
.set_slot:			defw cmd_set_slot			; 10
.get_tbblue_reg:	defw cmd_get_tbblue_reg		; 11
.set_border:		defw cmd_set_border			; 12
.set_breakpoints:	defw cmd_set_breakpoints	; 13
.restore_mem:		defw cmd_restore_mem		; 14
.loopback:			defw cmd_loopback			; 15
.get_sprites_palette:	defw cmd_get_sprites_palette	; 16
.get_sprites_clip_window_and_control:	defw cmd_get_sprites_clip_window_and_control	; 17
.get_sprites:		defw cmd_get_sprites		; 18, answered but empty; see there
.get_sprite_patterns:	defw cmd_get_sprite_patterns	; 19, ditto
.get_port:			defw cmd_read_port	; 20
.write_port:		defw cmd_write_port	; 21
.exec_asm:			defw cmd_exec_asm	; 22
.interrupt_on_off:	defw cmd_interrupt_on_off	; 23
.end

;.add_breakpoint:		defw 0		; not supported (see set_breakpoints/restore_mem)
;.remove_breakpoint:	defw 0	; not supported (see set_breakpoints/restore_mem)
;.add_watchpoint:		defw 0	; not supported
;.remove_watchpoint:	defw 0	; not supported

;.read_state:			defw 0	; not supported
;.write_state:			defw 0	; not supported


;===========================================================================
; Jumps to the correct command according the jump table.
; Parameters:
;	(receive_buffer.command) = the command, e.g. CMD_GET_CONFIG
; Changes:
;  NA
;===========================================================================
cmd_call:	; Get pointer to subroutine
    call get_cmd_pointer
    ; jump to subroutine
    jp (hl)
get_cmd_pointer:	; For unit tests this is a separate function.
    ld a,(receive_buffer.command)
    ; Check that command number is in range
    ld l,(cmd_jump_table.end-cmd_jump_table)/2
    sub l
    jr nc,.not_supported
    ; Use table
    add l
    add a,a
    ld hl,cmd_jump_table
    add hl,a
    ldi a,(hl)
    ld h,(hl)
    ld l,a
    ret
.not_supported:
    ld hl,cmd_not_supported
    ret


;===========================================================================
; CMD not supported.
; Is called for a command that is not supported.
; Creates an error output.
; Changes:
;  NA
;===========================================================================
cmd_not_supported:
    ; LOGPOINT [CMD] cmd_not_supported
    ld a,ERROR_CMD_NOT_SUPPORTED
    jp drain_main


;===========================================================================
; CMD_INIT
; Sends a response with the supported features.
; Changes:
;  NA
;===========================================================================
cmd_init:
    ; LOGPOINT [CMD] cmd_init
    ; DBG_LOG 'i'
    call .inner
    ; Reset slots to ZX128 default: ROM0, 5, 2, 0 => ROM0, ROM0, 10, 11, 4, 5, 0, 1
    ld hl,slot_backup
    ldi (hl),ROM_BANK	; Slot 0
    ld (hl),1	; Slot 7
    ; Other slots are set directly
    nextreg REG_MMU+1,ROM_BANK
    nextreg REG_MMU+2,10
    nextreg REG_MMU+3,11
    nextreg REG_MMU+4,4
    nextreg REG_MMU+5,5
    nextreg REG_MMU+6,0
    ; Reset error
    xor a
    ld (last_error),a
    ; Program state
    ld a,PRGM_LOADING
    ld (prgm_state),a
    ; Enable flashing border
    call transport_flashing_border.enable
    ; A debug client has opened a session. The transport decides whether it can
    ; honestly say so on the Next's screen; this is only the event (issue #14).
    ; Before show_ui, so the redraw below is the one that draws it — nothing
    ; here repaints on its own account.
    TRANSPORT_CLIENT_ATTACHED
    ; Afterwards start all over again / show	; Afterwards start all over again / show the "UI"
    call show_ui

.response:
    ; Send length and seq-no
    ld de,PROGRAM_NAME.end-PROGRAM_NAME + 1+5
    call send_length_and_seqno
    ; No error
    xor a
    call transport_write_byte
    ; Send config
    ; DZRP version
    ld a,DZRP_VERSION.MAJOR
    call transport_write_byte
    ld a,DZRP_VERSION.MINOR
    call transport_write_byte
    ld a,DZRP_VERSION.PATCH
    call transport_write_byte
    ; Machine type: 4 = ZX Next
    ld a,4
    call transport_write_byte
    ; Send own program name and version
    ld hl,PROGRAM_NAME
.write_prg_name_loop:
    ldi a,(hl)
    call transport_write_byte
    or a
    jr nz,.write_prg_name_loop
    ret

.inner:
    ; Consume exactly the payload the frame declared: 3 version bytes followed
    ; by the remote's NUL-terminated program name, none of which is used here.
    ;
    ; THE LENGTH DECIDES HOW MUCH OF THE STREAM BELONGS TO THIS COMMAND, NOT
    ; THE NUL. Upstream read the version by count and then the name until a zero
    ; byte, ignoring the length field entirely, so a length that disagreed with
    ; the payload desynchronised the stream silently and for the rest of the
    ; session (issue #7). Every other handler in this file already trusts the
    ; length — cmd_loopback, cmd_write_mem, cmd_restore_mem, cmd_exec_asm — and
    ; this one now does too. The NUL is a property of the payload's contents;
    ; framing is not its job.
    ;
    ; The bytes are read and dropped. The response is built from our own
    ; DZRP_VERSION and PROGRAM_NAME, so nothing above ever looks at the remote's
    ; version or name, and storing a client-chosen count into the 102-byte
    ; payload buffer would need a bound check that buys nothing.
    ;
    ; The boundaries a hostile client can reach all fall out of that one rule,
    ; with no special case for any of them:
    ;  - a name that fills the frame with no NUL: only the declared bytes leave
    ;    the stream, and what follows is the client's next frame by definition;
    ;  - a length below 3: fewer than three bytes are read, so there is no
    ;    over-read waiting for version bytes that were never promised;
    ;  - a length of 0: nothing is read;
    ;  - a length longer than what was actually sent: the read blocks and the
    ;    transport's own RX timeout resets the call stack, drains and reports —
    ;    the same recovery any other over-declared command already gets.
    ;
    ; Only the low 16 bits are used, as everywhere else here.
    ld de,(receive_buffer.length)
.read_loop:
    ld a,d
    or e
    ret z
    dec de
    push de
    call transport_read_byte	; Changes DE; HL is not used here
    pop de
    jr .read_loop


;===========================================================================
; CMD_CLOSE
; Closes the debug session.
; Changes:
;  NA
;===========================================================================
cmd_close:
    ; LOGPOINT [CMD] cmd_close
    ; Send response
    ld de,1
    call send_length_and_seqno
    ; Program state
    ld a,PRGM_IDLE
    ld (prgm_state),a
    ; Enable flashing border
    call transport_flashing_border.enable
    ; The session was closed cleanly, which is the only ending this stub can
    ; observe (issue #14). `jp main` reaches show_ui, so the line is drawn there.
    TRANSPORT_CLIENT_DETACHED
    ; Afterwards start all over again / show the "UI"
    jp main


;===========================================================================
; CMD_READ_REGS
; Reads all register and slot values and sends them in the response.
; Changes:
;  NA
;===========================================================================
cmd_get_registers:
    ; LOGPOINT [CMD] cmd_get_regs
    ; Send response
    ld de,38
    call send_length_and_seqno

    ; Loop all register values
    ld hl,backup.pc
    ld de,-3
    ld b,14
.loop:
    push bc
    ldi a,(hl)
    call transport_write_byte
    ld a,(hl)
    call transport_write_byte
    ; Next
    add hl,de
    pop bc
    djnz .loop

    ; Now the slot values
    ld a,8	; 8 slots
    call transport_write_byte

    ; Send the first 7 slots
    ld de,256*REG_MMU+7	; Load D and E at the same time
.slot_loop:
    ; Get bank for slot
    ld a,d
    call read_tbblue_reg	; Result in A
    ; Send
    call transport_write_byte
    inc d
    dec e
    jr nz,.slot_loop

    ; Get and send slot 7
    ld a,(slot_backup.slot7)
    ; LOGPOINT cmd_get_slots slot0: ${A}
    jp transport_write_byte


;===========================================================================
; CMD_WRITE_REG
; Writes one register.
; Changes:
;  NA
;===========================================================================
cmd_set_register:
    ; LOGPOINT [CMD] cmd_set_reg
    ; Read rest of message
    ld hl,receive_buffer.payload
    ld de,3
    call receive_bytes
    ; Execute command
    call cmd_set_register.inner
    ; Send response
    ld de,1
    jp send_length_and_seqno

.inner:	; jump label for unit tests
    ; Get value in DE
    ld hl,payload_set_reg.register_value+1
    ldd d,(hl)
    ldd e,(hl)
    ; Which register
    ld a,(hl)	; hl=receive_buffer.register_number
    sub 13
    jr nc,.next2

    ; Double register. A is -13 to -2
    neg ; A is 13 to 2
    add a,a	; a*2: 26 to 4
    ld hl,backup.hl2-4
    add hl,a
    ldi (hl),e
    ld (hl),d
    ret

.next2:
    ; Single register
    jr nz,.next4
    ; IM is directly set
    ld hl,backup.im
    inc e
    dec e
    jr nz,.not_im0
    ld (hl),0
    im 0
    ret
.not_im0:
    dec e
    jr nz,.not_im1
    ld (hl),1
    im 1
    ret
.not_im1:
    dec e
    ret nz	; IM number wrong
    ld (hl),2
    im 2
    ret

.next4:
    ; Here: F=1, A=2, ...., I'=22
    sub 23
    ; Here: F=-22, A=-21, ...., I'=-1
    ret nc	; Otherwise unknown
    ; Single register. A is -22 to -1
    neg ; A is 22 to 1; I'=1, R'=2, D'=3, E'=4
    dec a
    ; A is 21 to 0; I'=0, R'=1, D'=2, E'=3
    xor 0x01	; The endianess need to be corrected.
    ; A is 21 to 0; R'=0, I'=1, E'=2, D'=3
    ld hl,backup.r
    add hl,a
    ; Store register
    ld (hl),e
    ret


;===========================================================================
; CMD_WRITE_BANK
; Writes one memory bank.
; If MAIN_BANK should be written an error occurs.
; Changes:
;  NA
;===========================================================================
cmd_write_bank:
    ; LOGPOINT [CMD] cmd_write_bank
    ; Execute command
    call cmd_write_bank.inner
    ; Send response
    ld de,3
    call send_length_and_seqno
    ; No error
    xor a
    call transport_write_byte
    ; No error string
    jp transport_write_byte


.inner:
    ; THE DECLARED LENGTH IS CHECKED BEFORE ANYTHING IS READ, and until this
    ; guard existed there was nothing at all bounding the write below. The bank
    ; is paged into SWAP_SLOT, an 8 KB window at SWAP_ADDR, and receive_bytes
    ; walks upward from there for as many bytes as the FRAME SAYS — a number the
    ; client chooses. One byte past the window is 0xE000, which is MAIN_SLOT:
    ; the bank the debugger is executing out of. So a length above 8193 handed
    ; the client the running debugger to overwrite with its own payload.
    ;
    ; Not reachable from DeZog, which sends exactly 8193 — one bank byte and
    ; 8192 of bank — and not reachable from anything that means well. It is a
    ; guard against a malformed frame and a mis-sized client, and it is upstream
    ; code that has been unbounded since the fork; see cmd_loopback, which had
    ; the identical hole into the identical window.
    ; One bank byte, then the bank itself, so the first length that does not fit
    ; is SWAP_SIZE + 2.
    ld hl,(receive_buffer.length)
    ld de,SWAP_SIZE+2
    or a
    sbc hl,de
    jr nc,error_payload_too_big

    ; Read bank number of message
    call transport_read_byte

    ; Check if it is own bank
    cp MAIN_BANK
    jr z,error_write_main_bank

    ; Remember current bank for slot
    ld e,a
    call save_swap_slot
    ld a,e

    ; Change bank for slot
    nextreg REG_MMU+SWAP_SLOT,a

    ; Read bytes from the transport and put into bank
    ld hl,SWAP_ADDR		;.slot<<13	; Start address
    ld de,(receive_buffer.length)	; Bank size
    dec de
    call receive_bytes

    ; Restore slot/bank (D)
    jp restore_swap_slot

;===========================================================================
; A frame declared more payload than the 8 KB swap window can hold.
;
; IT REPORTS AND DOES NOT ANSWER, which is deliberate and is the lesser of two
; bad options rather than a good one. DZRP has no error response for either of
; the two commands that come here — CMD_LOOPBACK's reply IS the data and
; CMD_WRITE_BANK's error field cannot say "your frame was malformed" without
; the payload having been consumed first — and a reply of the wrong length
; desynchronises the stream for every command after it. So this takes
; error_write_main_bank's established route: put the reason on the Next's own
; screen and go to drain_main, which empties the link and leaves the debugger
; idle and healthy. The client waits and times out.
;
; That is the SAME silence issues #8 and #9 called a defect, and the difference
; is what produced it. There the stub refused a command a real client legitimately
; sends; here the frame cannot be honoured by any means, and the alternative on
; offer is not a better answer but a corrupted debugger.
;===========================================================================
error_payload_too_big:
    ld a,ERROR_PAYLOAD_TOO_BIG
    jp drain_main

error_write_main_bank:
    ld a,ERROR_WRITE_MAIN_BANK
    jp drain_main


;===========================================================================
; CMD_CONTINUE
; Continues debugged program execution.
; Restores the back'uped registers and jumps to the last
; execution point.
; Changes:
;  NA
;===========================================================================
cmd_continue:
    ; LOGPOINT [CMD] cmd_continue
    ; Read breakpoints etc. from message
    ld hl,receive_buffer.payload
    ld de,PAYLOAD_CONTINUE
    call receive_bytes

    ; Send response
    ld de,1
    call send_length_and_seqno

    ; Get breakpoints
    ld a,(payload_continue.bp1_enable)
    or a
    jr z,.bp2
    ; Set temporary bp 1
    ld hl,(payload_continue.bp1_address)
    ld de,tmp_breakpoint_1
    call set_tmp_breakpoint
.bp2:
    ld a,(payload_continue.bp2_enable)
    or a
    jr z,.start
    ; Set temporary bp 2
    ld hl,(payload_continue.bp2_address)
    ld de,tmp_breakpoint_2
    call set_tmp_breakpoint
.start:
    ; Check program state
    ld a,(prgm_state)
    cp PRGM_LOADING
    jr nz,.not_loading
    ; Loading finished: Set border color after loading
    ld a,(backup.border_color)
    out (BORDER),a
    ; Disable flashing border
    call transport_flashing_border.disable
.not_loading:
    ; Continue
    jp restore_registers


;===========================================================================
; CMD_PAUSE
; Acknowledges the command. Sends the Length=1 response the specification
; requires — the sequence number and nothing else — and returns to cmd_loop.
;
; ANSWERING IS THE WHOLE OF IT, AND DOING MORE WOULD BE WRONG. This handler is
; only ever reached from cmd_loop, which runs only while the debugger is
; stopped, so the command cannot arrive in any other state and there is nothing
; here to pause. In particular it must NOT touch prgm_state: a client may
; legitimately send CMD_PAUSE before the first CMD_CONTINUE — our own
; conformance check C12 does exactly that, CMD_INIT then CMD_PAUSE — which
; means it can arrive while prgm_state is PRGM_LOADING. Overwriting that with
; PRGM_STOPPED would make the next cmd_continue skip its "loading
; finished" branch (.start, above) and leave the flashing border on. Nor does
; it send an NTF_PAUSE — that notification reports a TRANSITION into the
; stopped state, and no transition happens here. CSpect's plugin behaves the
; same way: its Pause() stops the CPU and calls SendResponse(), while the
; notification is emitted later and only if the state actually changed.
;
; Breaking into a FREELY RUNNING debuggee is a different problem and is
; milestone M2, not this: mf_rom.asm's nmi66h serves button NMIs only (bench
; check T4 asserts that decline deliberately), so while the debuggee runs
; nothing polls the link and no command can be received at all.
;
; Upstream routed command 7 to cmd_not_supported, which stores an error and
; jumps to drain_main: the frame was consumed and NOTHING was sent, so a client
; waited forever. That was invisible upstream because DeZog's ZxNextSerialRemote
; overrides sendDzrpCmdPause() to throw "To pause execution use the yellow NMI
; button of the ZX Next" and never puts the command on the wire. Our WiFi mode
; is driven by the cspect remote (plan §7), which does NOT override it and so
; inherits DzrpRemote's `await this.sendDzrpCmd(7)` — it sends command 7 and
; blocks on the response. Issue #8; conformance check C12.
; Changes:
;  NA
;===========================================================================
cmd_pause:
    ; LOGPOINT [CMD] cmd_pause
    ; Send response: the sequence number alone
    ld de,1
    jp send_length_and_seqno


;===========================================================================
; CMD_READ_MEM
; Reads a memory area.
; Special is that if slot 7 area is read,
; then the memory bank of slot_backup.slot7 is temporarily paged into
; SWAP_SLOT and read.
; Changes:
;  NA
;===========================================================================
cmd_read_mem:
    ; LOGPOINT [CMD] cmd_read_mem
    ; Read address and size from message
    ld hl,receive_buffer.payload
    ld de,PAYLOAD_READ_MEM
    call receive_bytes

    ; Send response
    ld hl,(payload_read_mem.mem_size)
    ld de,1		; Add 1 for the sequence number
    add hl,de
    ex hl,de
    jr c,.hl_correct	; If C then hl already contains 1.
    ld l,0	; If NC then we need to reset HL to 0.
.hl_correct:
    call send_4bytes_length_and_seqno

.inner:		; For unit testing
    ld de,(payload_read_mem.mem_size)
    ld hl,(payload_read_mem.mem_start)
    ld bc,cmd_read_mem.read
    jp memory_loop

; The inner call
cmd_read_mem.read:
    ; Get byte
    ld a,(hl)
    ; Send
    jp transport_write_byte


;===========================================================================
; CMD_WRITE_MEM
; Writes a memory area.
; Special is that if slot 7 area is read,
; then the memory bank of slot_backup.slot7 is temporarily paged into
; SWAP_SLOT and written.
; Changes:
;  NA
;===========================================================================
cmd_write_mem:
    ; LOGPOINT [CMD] cmd_write_mem
    ; Read address from message
    ld hl,receive_buffer.payload
    ld de,PAYLOAD_WRITE_MEM
    call receive_bytes

.inner:
    call save_swap_slot
    ; Read length and subtract 3
    ld hl,(receive_buffer.length)
    ld de,-PAYLOAD_WRITE_MEM
    add hl,de
    ex de,hl
    ; Read bytes from the transport and put into memory
    ld hl,(payload_write_mem.mem_start)
    ld bc,.write
    call memory_loop

    ; Send response
    ld de,1
    jp send_length_and_seqno


; The inner call
.write:
    ; Get byte
    push de
    call transport_read_byte
    ; Write
    ld (hl),a
    pop de
    ret


;===========================================================================
; CMD_SET_SLOT
; Sets a 8k-banks/slot association.
; Changes:
;  NA
;===========================================================================
cmd_set_slot:
    ; LOGPOINT [CMD] cmd_set_slot

    ; Get slot
    call transport_read_byte
    ld l,a
    ; Get bank
    call transport_read_byte
    cp 0xFE
    jr nz,.no_fe
    inc a	; Change 0xFE to 0xFF
.no_fe:
    ; A = bank

    ; Get slot
    inc l
    bit 3,l	; check for 0
    jr z,.not_slot7

    ; LOGPOINT cmd_set_slot slot0: ${A}

    ; Slot 7 is handled especially: don't change the slot but only the backed up value
    ld (slot_backup.slot7),a
    jr .end

.not_slot7:
    ld h,a	; H = bank
    dec l
    ld a,l	; slot
    add a,REG_MMU
    ld (.nextreg_register+2),a	; Modify opcode
    ld a,h	; A = bank
.nextreg_register:
    nextreg 0x00,a	; Self-modifying code
.end:
    ; Send response
    ld de,2
    call send_length_and_seqno
    xor a	; no error
    jp transport_write_byte

;.error:
;	call transport_read_byte	; read dummy value
;	ld a,1	; error
;	jp transport_write_byte


;===========================================================================
; CMD_GET_TBBLUE_REG
; Reads the tbblue register.
; Changes:
;  NA
;===========================================================================
cmd_get_tbblue_reg:
    ; LOGPOINT [CMD] cmd_get_tbblue_reg
    ; Send response
    ld de,2
    call send_length_and_seqno
    ; Read register number
    call transport_read_byte	; Register number
    call read_tbblue_reg	; Result in A
    ; Send
    jp transport_write_byte


;===========================================================================
; CMD_GET_SPRITES / CMD_GET_SPRITE_PATTERNS
;
; THE NEXT CANNOT READ EITHER OF THESE BACK, and that is checked in the VHDL
; rather than taken from upstream. Ports 0x57 (attribute upload) and 0x5B
; (pattern upload) have NO read decode at all: zxnext.vhd:651-652 declares
; port_57_wr and port_5b_wr and no read counterpart, and neither appears in the
; port read mux (zxnext.vhd:2803-2806) or the data mux (:2837-2840). Port
; 0x303B IS readable but returns the sprite STATUS byte (sprites.vhd:748 —
; collision and max-per-line), not attributes. Nor is there a back door through
; the NextReg mirrors 0x35-0x39 / 0x75-0x79, which `nextreg.txt` describes in a
; way that reads as if they might be bidirectional: the read-mux case statement
; has no entry for any of them, only the write side exists. Checked in review,
; because if any read path existed the right answer would be to implement these
; for real rather than to answer zeros. So this is a property of the silicon, which is why upstream's jump table sent both to
; cmd_not_supported and why DeZog's own ZxNextSerialRemote throws "The sprite
; attributes can't be read on a ZX Next unfortunately" before the command ever
; reaches a wire.
;
; AN EMULATOR IS NOT SUBJECT TO THIS AND WE ARE. CSpect's DeZog plugin answers
; these for real, because it runs in the HOST, where the sprite arrays are
; ordinary variables; jnext's own DZRP server (its issue #12) will be able to do
; the same. Our stub is Z80 code running INSIDE the machine, so it is bounded by
; what the CPU can reach — in jnext exactly as on hardware, since jnext models
; the write-only-ness faithfully. The same DeZog session will therefore show a
; populated sprite view against an emulator and an empty one against a real
; Next: a capability difference in the target, not a fault in either. Plan
; section 8.4 lists this family among the tier no hardware target can implement.
;
; SO WHY ANSWER AT ALL. Because the client this transport is spoken to by is a
; DIFFERENT one. DeZog's CSpectRemote — the `cspect` remote WiFi mode uses —
; overrides neither, and inherits `await this.sendDzrpCmd(18, …)`: it sends the
; command and blocks. And cmd_not_supported does not merely stay silent, it
; jumps to drain_main, which re-initialises the debugger — prgm_state to
; PRGM_IDLE, the clock and backup state reset, the screen repainted. Opening
; DeZog's sprite view therefore hung the client AND tore the session down
; underneath it. Issue #9, and the same shape as #8's CMD_PAUSE: adopting a new
; client re-exposes what the old one hid.
;
; THE ANSWER IS ZEROS, AT EXACTLY THE LENGTH ASKED FOR, and the length is not
; ours to choose. DeZog asserts it — `assert(count*5 == r.length)` for sprites
; and `assert(r.length == 256*count)` for patterns, verified in the installed
; 3.7.4 — so a short reply is a desync rather than a refusal, and DZRP has no
; error response to send instead. A zeroed attribute has its visible bit clear,
; so the sprite view renders empty: the closest thing to "there is nothing I can
; show you" that this wire format can say.
;
; The index is read and dropped: with no data to index into it selects nothing.
; Changes:
;  NA
;===========================================================================
cmd_get_sprites:
    ; LOGPOINT [CMD] cmd_get_sprites
    call sprites_read_count     ; A = count
    ; 5 bytes per sprite: HL = A*5, which cannot carry (255*5 = 1275).
    ld l,a
    ld h,0
    add hl,hl               ; *2
    add hl,hl               ; *4
    ld e,a
    ld d,0
    add hl,de               ; *5
    jr sprites_send_zeros

cmd_get_sprite_patterns:
    ; LOGPOINT [CMD] cmd_get_sprite_patterns
    call sprites_read_count     ; A = count
    ; 256 bytes per pattern, so the count IS the high byte. 255*256 = 65280,
    ; and the length field below adds one for the sequence number: 65281 still
    ; fits the 16 bits send_length_and_seqno takes.
    ld h,a
    ld l,0
    ; Flow through

sprites_send_zeros:
    ; HL = how many payload bytes to send.
    push hl
    inc hl                  ; + the sequence number
    ex de,hl
    call send_length_and_seqno
    pop hl
.loop:
    ld a,h
    or l
    ret z
    xor a
    call transport_write_byte
    dec hl
    jr .loop

sprites_read_count:
    ; The payload is <index><count>. The index is read so the stream stays in
    ; step and then dropped.
    call transport_read_byte
    jp transport_read_byte


;===========================================================================
; CMD_SET_BORDER
; Sets the border color.
; Changes:
;  NA
;===========================================================================
cmd_set_border:
    ; LOGPOINT [CMD] cmd_set_border
    ; Read border color
    call transport_read_byte
    ld (backup.border_color),a
    ; Send response
    ld de,1
    jp send_length_and_seqno


;===========================================================================
; CMD_SET_BREAKPOINTS
; Sets all breakpoints.
; Changes:
;  NA
;===========================================================================
cmd_set_breakpoints:
    ; LOGPOINT [CMD] cmd_set_breakpoints
    call save_swap_slot
    ; Calculate the count
    ld hl,(receive_buffer.length)	; Read only the lower bytes
    ; Divide by 3
    ld e,3
    call div_hl_e	; hl = hl/3
    ; Send response
    ld de,hl
    push de
    inc de
    call send_length_and_seqno
    pop de 	; count

.loop:
    ; Check for end
    ld a,e
    or d
    ret z
    ; Loop
    push de
    ; Get breakpoint address
    call transport_read_byte
    ld l,a
    call transport_read_byte
    ld h,a
    ; Get bank+1
    call transport_read_byte
    or a
    jr z,.handle_64k_address

    ; Handle long address
    dec a	; A = bank
    ; Page in bank in upper memory
    jr .page_in_bank

.handle_64k_address:
    ; Normal 64k address:
    ; Check memory area. LD A,H FIRST, and it is the whole of issue #38: A still
    ; holds the bank+1 byte here, which on this path is zero BY DEFINITION — it
    ; is what the jump above tested — so the compare was always 0 < 0xE0 and
    ; .normal always won. A 64K address at 0xE000 or above then took the direct
    ; write, into MAIN_SLOT, i.e. into MAIN_BANK: the bank this code is running
    ; out of. The address to judge is in HL, exactly as in set_tmp_breakpoint
    ; and clear_tmp_breakpoint (breakpoints.asm) and memory_loop (backup.asm),
    ; which are the other three sites making this decision and all get it right.
    ; Bench check C22.
    ld a,h
    cp HIGH MAIN_ADDR	; 0xE000
    jr c,.normal

    ; Page in bank
    ld a,(slot_backup.slot7)
.page_in_bank:
    nextreg REG_MMU+SWAP_SLOT,a
    ld a,h
    and 0x1F
    add HIGH SWAP_ADDR	; 0xC0
    ld h,a
    ; Get memory
    ld a,(hl)	; LOGPOINT [CMD] BP=${HL:hex}h, ${HL} (SWAP)
    ; Set breakpoint
    ld (hl),BP_INSTRUCTION

    ; Restore slot/bank
    ld e,a
    call restore_swap_slot

    ; Restore a
    ld a,e
    jr .next

.normal:
    ; Refuse the debugger's own trampoline (see bp_hits_trampoline). The opcode
    ; found there is still reported, so the client is told what was at the
    ; address and simply gets no breakpoint — which is what it got before this
    ; write was able to land at all.
    call bp_hits_trampoline
    ; Get memory. AFTER the guard, which uses A, and before the write, which
    ; makes the real ROM serve reads.
    ld a,(hl)	; LOGPOINT [CMD] BP=${HL:hex}h, ${HL}
    jr c,.next
    ; Set breakpoint
    push af	; The opcode .next sends back
    ld a,BP_INSTRUCTION
    call write_debuggee_byte
    pop af

.next:
    ; Send memory
    call transport_write_byte
    pop de
    dec de
    jr .loop



;===========================================================================
; CMD_RESTORE_MEM
; Restores the memory at the addresses.
; Changes:
;  NA
;===========================================================================
cmd_restore_mem:
    ; LOGPOINT [CMD] cmd_restore_mem
    ;call save_rom_slots
    call save_swap_slot
    ; Send response
    ld de,1
    call send_length_and_seqno

    ; Calculate the count
    ld de,(receive_buffer.length)	; Read only the lower bytes

.loop:
    ; Check for end
    ld a,e
    or d
    ;jp z,restore_rom_slots	; Returns
    jp z,restore_swap_slot	; Returns
    ; Loop
    push de
    ; Get memory address
    call transport_read_byte
    ld l,a
    call transport_read_byte
    ld h,a
    ; Get bank+1
    call transport_read_byte
    or a
    jr z,.handle_64k_address

    ; Handle long address
    dec a	; A = bank
    ; Page in bank in upper memory
    jr .page_in_bank

.handle_64k_address:
    ; Check memory area. The second copy of issue #38, and worse than
    ; cmd_set_breakpoints' because the byte written below is the CLIENT'S rather
    ; than a fixed RST 0 — an arbitrary value at an arbitrary offset of the
    ; running debugger's bank. See the same comment there for why A is not the
    ; register to test. Bench check C23.
    ld a,h
    cp HIGH MAIN_ADDR	; 0xE000
    jr c,.normal

    ld a,(slot_backup.slot7)
.page_in_bank:
    nextreg REG_MMU+SWAP_SLOT,a
    ld a,h
    and 0x1F
    add HIGH SWAP_ADDR	; 0xC0
    ld h,a
    ; Get value
    call transport_read_byte
    ; Set memory
    ld (hl),a

    ; Restore slot/bank
    ld e,a
    call restore_swap_slot

    ; Restore a
    ld a,e
    jr .next

.normal:
    ; Get value. Read whatever happens next, so the stream stays in step even
    ; when the write below is refused; parked in E, because the guard uses A.
    call transport_read_byte
    ld e,a

    ; REFUSE THE TRAMPOLINE HERE TOO. This is a client-controlled write of a
    ; client-chosen byte, and until write_debuggee_byte existed it could not
    ; reach ROM space at all — so leaving it open would reopen C18's defect one
    ; command along: a client overwriting the running debugger.
    ;
    ; An earlier version left it unguarded, arguing that a breakpoint which can
    ; be set and not removed is worse than one that never happened. That
    ; argument does not survive the guard's own existence: bp_hits_trampoline is
    ; a pure function of the address, so an address it refuses here is one
    ; cmd_set_breakpoints refused to patch in the first place, and refusing the
    ; restore can never strand a legitimate un-patch.
    ;
    ; clear_tmp_breakpoint deliberately stays unguarded, and the difference is
    ; who chose the address: its comes from tmp_breakpoint_X.bp_address, which
    ; only set_tmp_breakpoint.store writes and only on the path where this same
    ; guard already passed. A trampoline address cannot get in there.
    call bp_hits_trampoline
    ld a,e	; The value to write. LD does not disturb the carry.
    jr c,.next

    ; Set memory
    call write_debuggee_byte

.next:
    ; Next address
    pop de
    add de,-4
    jr .loop



;===========================================================================
; CMD_LOOPBACK
; The received data is looped back to the sender.
; Changes:
;  NA
;===========================================================================
cmd_loopback:
    ; LOGPOINT [CMD] cmd_loopback
    ; THE SAME UNBOUNDED WRITE cmd_write_bank had, into the same 8 KB window and
    ; for the same reason: the loop below walks upward from SWAP_ADDR for as
    ; many bytes as the FRAME declared, and 8193 of them reach 0xE000 — the bank
    ; the debugger is executing out of. The whole payload is buffered before any
    ; of it is sent (see below), so the window is the ceiling and nothing else
    ; was enforcing it.
    ;
    ; Nothing legitimate approaches it — DeZog's loopback is a handful of bytes
    ; and the conformance sweep stops at 4096 — which is exactly why it survived
    ; from the fork: the one thing that would have found it is a suite pushing
    ; 8 KB, and adding one is what did.
    ld hl,(receive_buffer.length)
    ld de,SWAP_SIZE+1
    or a
    sbc hl,de
    jp nc,error_payload_too_big

    ; Save swap slot
    call save_swap_slot

    ; Page in bank for storage
    nextreg REG_MMU+SWAP_SLOT,LOOPBACK_BANK
    ; Get length
    ld de,(receive_buffer.length)

    ; Read all data in swap slot
    ld hl,SWAP_ADDR
    jr .rcv_check_end

.rcv_loop:
    ; Loop
    push de
    ; Get value
    call transport_read_byte
    ; Store
    ldi (hl),a
    ; Next
    pop de
    dec de
.rcv_check_end:
    ; Check for end
    ld a,e
    or d
    jr nz,.rcv_loop

    ; Send response
    ld de,(receive_buffer.length)
    inc de
    call send_length_and_seqno

    ; Send all data
    ld de,(receive_buffer.length)
    ld hl,SWAP_ADDR
    jr .send_check_end

.send_loop:
    ; Loop
    ; Get value
    ldi a,(hl)
    ; Send
    call transport_write_byte
    ; Next
    dec de
.send_check_end:
    ; Check for end
    ld a,e
    or d
    jr nz,.send_loop

    ; Restore slot
    call restore_swap_slot
    ; Continue
    pop af	; swallow return address
    jp main_loop.continue


;===========================================================================
; CMD_GET_SPRITES_PALETTE
; Returns the values of the requested palette.
; Changes:
;  NA
;===========================================================================
cmd_get_sprites_palette:
    ; LOGPOINT [CMD] cmd_get_sprites_palette
    ; Start response
    ld de,513
    call send_length_and_seqno
    ; Save current values
    ld a,REG_PALETTE_CONTROL
    call read_tbblue_reg	; Result in A
    ld d,a	; eUlaCtrlReg
    ld a,REG_PALETTE_INDEX
    call read_tbblue_reg	; Result in A
    ld e,a	; indexReg
    ld a,REG_PALETTE_VALUE_8
    call read_tbblue_reg	; Result in A
    ld l,a	; colorReg
    ld a,REG_MACHINE_TYPE
    call read_tbblue_reg	; Result in A
    ld h,a	; machineReg
    ; Save
    push hl		; h = machineReg, l = colorReg
    push de 	; d = eUlaCtrlReg, e = indexReg

    ; Select sprites
    ld a,d	; eUlaCtrlReg
    and 0x0F
    or 00100000b
    ld l,a
    ; Get palette index
    call transport_read_byte
    bit 0,a
    ld a,l
    jr z,.palette_0
    or 01000000b	; Select palette 1
.palette_0:
    NEXTREG REG_PALETTE_CONTROL,a

/*
           // Store current values
            var cspect = Main.CSpect;
            byte eUlaCtrlReg = cspect.GetNextRegister(REG_PALETTE_CONTROL);
            byte indexReg = cspect.GetNextRegister(REG_PALETTE_INDEX);
            byte colorReg = cspect.GetNextRegister(REG_PALETTE_VALUE_8);
            // Bit 7: 0=first (8bit color), 1=second (9th bit color)
            byte machineReg = cspect.GetNextRegister(REG_MACHINE_TYPE);
            // Select sprites
            byte selSprites = (byte)((eUlaCtrlReg & 0x0F) | 0b0010_0000 | (paletteIndex << 6));
            cspect.SetNextRegister(0x43, selSprites); // Resets also 0x44
  */

    // Read palette
    ld d,0	; Index
.loop:
    ; Set index
    ; d = index
;	ld a,REG_PALETTE_INDEX
;	call write_tbblue_reg ; Result in A
    WRITE_TBBLUE_REG REG_PALETTE_INDEX,d
    // Read color
    ld a,REG_PALETTE_VALUE_8
    call read_tbblue_reg ; Result in A
    call transport_write_byte
    ld a,REG_PALETTE_VALUE_16  ; color9th
    call read_tbblue_reg ; Result in A
    call transport_write_byte
    inc d
    jr nz,.loop		; Loop 256x

    /*
             // Read palette
            for (int i = 0; i < 256; i++)
            {
                // Set index
                cspect.SetNextRegister(REG_PALETTE_INDEX, (byte)i);
                // Read color
                byte colorMain = cspect.GetNextRegister(REG_PALETTE_VALUE_8);
                SetByte(colorMain);
                byte color9th = cspect.GetNextRegister(REG_PALETTE_VALUE_16);
                SetByte(color9th);
                //Log.WriteLine("Palette index={0}: 8bit={1}, 9th bit={2}", i, colorMain, color9th);
            }
    */

    // Restore values
    pop de 		; d = eUlaCtrlReg, e = indexReg
    pop hl		; h = machineReg, l = colorReg
    ; d = eUlaCtrlReg
    WRITE_TBBLUE_REG REG_PALETTE_CONTROL,d
    ; e = indexReg
    WRITE_TBBLUE_REG REG_PALETTE_INDEX,e

    ; If bit 7 set, increase 0x44 index.
    bit 7,h
    ret z

    ; Write it to increase the index
    ; l = colorReg
    WRITE_TBBLUE_REG REG_PALETTE_VALUE_16,e
    ret

    /*
            // Restore values
            cspect.SetNextRegister(REG_PALETTE_CONTROL, eUlaCtrlReg);
            cspect.SetNextRegister(REG_PALETTE_INDEX, indexReg);
            if ((machineReg & 0x80) != 0)
            {
                // Bit 7 set, increase 0x44 index.
                // Write it to increase the index
                cspect.SetNextRegister(REG_PALETTE_VALUE_16, colorReg);
            }
    */


;===========================================================================
; CMD_GET_SPRITES_CLIP_WINDOW_AND_CONTROL
; Returns the sprites clip window and the control byte (regsiter (0x15).
; Changes:
;  NA
;===========================================================================
cmd_get_sprites_clip_window_and_control:
    ; LOGPOINT [CMD] cmd_get_sprites_clip_window_and_control
    ; Prepare response
    ld de,6
    call send_length_and_seqno

    ; Get index
    ld a,REG_CLIP_WINDOW_CONTROL
    call read_tbblue_reg
    rra : rra
    and 011b	; A contains the index

    ; Get xl, xr, yt or yb
    ld d,4
.loop:	; 4x: for xl, xr, yt and yb
    push af
    ld a,REG_CLIP_WINDOW_SPRITES
    call read_tbblue_reg
    ; Increase index by writing the same value
    nextreg REG_CLIP_WINDOW_SPRITES, a
    ld e,a
    ; Store
    pop af
    ld hl,tmp_clip_window
    add hl,a
    ld (hl),e
    inc a
    and 011b
    dec d
    jr nz,.loop

    ; Send xl, xr, yt or yb
    ld d,4
    ld hl,tmp_clip_window
.send_loop:
    ldi a,(hl)
    call transport_write_byte 	; Send xl, xr, yt or yb
    dec d
    jr nz,.send_loop

    ; Get sprite control byte
    ld a,REG_SPRITE_LAYER_SYSTEM
    call read_tbblue_reg
    jp transport_write_byte 	; Send sprite control byte



;===========================================================================
; CMD_READ_PORT
; Reads a value from a port.
; Changes:
;  NA
;===========================================================================
cmd_read_port:
    ; LOGPOINT [CMD] cmd_write_port
    ; Read port (low byte)
    call transport_read_byte
    ld l,a
    ; Read port (high byte)
    call transport_read_byte
    ld b,a
    ; Read value from the port
    ld c,l
    in a,(c)

    ; Send response
    push af
    ld de,2
    call send_length_and_seqno
    ; Write port value
    pop af
    jp transport_write_byte


;===========================================================================
; CMD_WRITE_PORT
; Writes a value to a port.
; Changes:
;  NA
;===========================================================================
cmd_write_port:
    ; LOGPOINT [CMD] cmd_write_port
    ; Read port (low byte)
    call transport_read_byte
    ld l,a
    ; Read port (high byte)
    call transport_read_byte
    ld h,a
    ; Read value
    call transport_read_byte
    ; Write to the port
    ld bc,hl
    out (c),a
    ; Send response
    ld de,1
    jp send_length_and_seqno


;===========================================================================
; CMD_EXEC_ASM
; Executes a small assembler program.
; Changes:
;  NA
;===========================================================================
cmd_exec_asm:
    ; LOGPOINT [CMD] cmd_exec_asm
    ld de,(receive_buffer.length)	; assembler code size
    ld hl,PAYLOAD_EXEC_ASM-1	; 1 for the RET
    or a
    sbc hl,de
    jr nc,.buffer_size_ok

    ; Code size too big -> return error
    ld hl,0
    push hl, hl, hl, hl
    ld a,1	; error: 1 = buffer size too big
    jp .send_response

.buffer_size_ok:
    ; Load the context (ignored) and the assembler code
    ld hl,receive_buffer.payload
    call receive_bytes
    ; End the code with a RET
    ld (hl),0xC9

    ; Execute
    call payload_exec_asm.code

    ; Save all registers
    push hl, de, bc, af
    ; No error
    xor a

.send_response:
    ; a contains the error code.
    push af
    ; Send response
    ld de,10
    call send_length_and_seqno
    ; Send error code (=no error)
    pop af	; error code
    call transport_write_byte
    ; Send AF
    pop hl	; H=A, L=F
    call .write_reg
    ; Send BC
    pop hl	; H=B, L=C
    call .write_reg
    ; Send DE
    pop hl	; H=D, L=E
    call .write_reg
    ; Send HL
    pop hl	; H=H, L=L
    ; Flow through

.write_reg:
    ld a,l
    call transport_write_byte	; low byte
    ld a,h
    jp transport_write_byte	; high byte



;===========================================================================
; CMD_INTERRUPT_ON_OFF
; Turns the interrupt on or off.
; Changes:
;  NA
;===========================================================================
cmd_interrupt_on_off:
    ; LOGPOINT [CMD] cmd_exec_asm
    ; Read: off=0 or on
    call transport_read_byte
    ld hl,backup.interrupt_state
    or a
    jr z,.disable

    ; Enable interrupt
    set 2,(hl)

.send_response:
    ; Send response
    ld de,1
    jp send_length_and_seqno

.disable:
    ; Disable interrupt
    res 2,(hl)
    jr .send_response
