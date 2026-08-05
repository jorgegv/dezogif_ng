;===========================================================================
; data.asm
;
; All volatile data is defined here.
;
; Note: The area does not need to be copied. i.e. is initialized on the fly.
;===========================================================================



; UPSTREAM's version, and the fork has never moved it. It is no longer on the
; screen — that says `dezogif_ng <variant> build <nnnn>`, from the same two
; symbols the identity block uses (IDENTITY_LINE in constants.asm, issue #12).
; What is left of it is the program name CMD_INIT reports to the client
; (PROGRAM_NAME, commands.asm), where it is still "dezogif v2.2.1" and where
; changing it changes what DeZog displays. That is a separate decision.
 MACRO PRG_VERSION
    defb "v2.2.1"
 ENDM


;===========================================================================
; Magic number addresses to recognize the debugger
;===========================================================================
magic_number_a:     equ 0x0000     ; Address 0x0000 (0xE000)
magic_number_b:     equ 0x0001
magic_number_c:     equ 0x0066      ; Address 0x0066 (0xE066)
magic_number_d:     equ 0x0067


;===========================================================================
; Const data
;===========================================================================

; 16 bit build time
build_time_abs: defw BUILD_TIME16
build_time_rel = build_time_abs-MAIN_ADDR;


;===========================================================================
; UI
;
; THE TWO MODES DRAW DIFFERENT SCREENS, and that is the decision MEMORY.md
; records on 2026-08-04, not a shortcut taken here. A cable baud rate and a
; joy-port selector are meaningful in UART mode and meaningless in WiFi mode;
; the address a client has to dial is the other way round. There is no shared
; layout with blanks in it, because a screen with blanks where its content
; should be is what a user reads as a broken debugger.
;
; What both keep is mode-independent, and two of them are load-bearing rather
; than decorative: `Core:` is CHECKED by show_ui against 03.01.10 (stackless
; NMI needs it, over WiFi exactly as over a cable), and the red error area at
; the bottom is where a bring-up failure has to be able to say so.
;
; The common lines are spelled out in both branches rather than factored into a
; shared prologue. They are about thirty bytes of text, and the UART build's
; bytes are a standing gate — a shared table would put that at risk to save
; nothing.
;
; The variant blocks below hold ONLY what is static. WiFi mode's connect
; address cannot be: it comes from the ESP at run time, so it is composed in
; transport_esp.asm and drawn into the gap this text leaves at rows 6 and 7.
;===========================================================================

 IF ROM_VARIANT == ROM_VARIANT_WIFI

INTRO_TEXT:
    defb AT, 0, 0
    ; "WiFi" where UART mode says "UART". The two builds have to be
    ; distinguishable at a glance on a real machine: with the same title and
    ; the same body they were not, and finding out which ROM was installed cost
    ; a hardware session.
.identity:
    IDENTITY_LINE
    ; The screen is 32 columns and this line starts at column 0. Held by an
    ; ASSERT rather than by the arithmetic in the macro's comment: a bound
    ; written down is a bound nothing checks, and this project has paid for
    ; that three times (ERRORS.md). Watched to fail, at 25.
    ASSERT $ - .identity <= 32
    defb AT, 0, 1*8
    defb "DZRP v"
    defb DZRP_VERSION.MAJOR+'0', '.', DZRP_VERSION.MINOR+'0', '.', DZRP_VERSION.PATCH+'0'
    defb AT, 0, 2*8
    defb "Core: "
    defb AT, 0, 3*8
    ; The ESP link's rate, which is what this build actually runs the
    ; peripheral at. The line it replaces rendered BAUDRATE — the joy-port
    ; cable's 921600 — in a ROM whose prescaler table is built from
    ; ESP_BAUDRATE, so it stated a rate the hardware was not using, in the
    ; first place anyone looks when the ESP misbehaves.
    defb "ESP Baudrate: "
    STRINGIFY ESP_BAUDRATE
    defb AT, 0, 4*8
    defb "Video timing:"

    ; Rows 6 and 7 are left to esp_show_status.

    ; The key list is three lines shorter than UART mode's — there is no
    ; joystick port to choose — so it starts lower, which keeps the gap between
    ; it and the status block rather than leaving a hole in the middle. R and B
    ; stay on rows 12 and 13 so BORDER_ON_TEXT / BORDER_OFF_TEXT, which are
    ; shared and carry their own coordinates, need no variant of their own.
    defb AT, 0, 11*8
    defb "Keys:"
    defb AT, 0, 12*8
    defb "R = Reset"
    defb AT, 0, 13*8
    defb "B = Border"
    defb 0

 ELSE

INTRO_TEXT:
    defb AT, 0, 0
.identity:
    IDENTITY_LINE
    ; 32 columns, as in the WiFi branch above and for the same reason.
    ASSERT $ - .identity <= 32
    defb AT, 0, 1*8
    defb "DZRP v"
    defb DZRP_VERSION.MAJOR+'0', '.', DZRP_VERSION.MINOR+'0', '.', DZRP_VERSION.PATCH+'0'
    defb AT, 0, 2*8
    defb "Core: "
    defb AT, 0, 3*8
    defb "ESP UART Baudrate: "
    STRINGIFY BAUDRATE
    defb AT, 0, 4*8
    defb "Video timing:"

    defb AT, 0, 8*8
    defb "Keys:"
    defb AT, 0, 9*8
    defb "1 = Joy 1"
    defb AT, 0, 10*8
    defb "2 = Joy 2"
    defb AT, 0, 11*8
    defb "3 = No joystick port"
    defb AT, 0, 12*8
    defb "R = Reset"
    defb AT, 0, 13*8
    defb "B = Border"
    defb 0

JOY1_SELECTED_TEXT:
    defb AT, 0, 6*8, "Using Joy 1 (left)", 0
JOY2_SELECTED_TEXT:
    defb AT, 0, 6*8, "Using Joy 2 (right)", 0
NOJOY_SELECTED_TEXT:
    defb AT, 0, 6*8, "No joystick port used.", 0

SELECTED_TEXT_TABLE:
    defw NOJOY_SELECTED_TEXT
    defw JOY1_SELECTED_TEXT
    defw JOY2_SELECTED_TEXT

 ENDIF


BORDER_OFF_TEXT:
    defb AT, 11*8, 13*8, "off", 0
BORDER_ON_TEXT:
    defb AT, 11*8, 13*8, "on", 0


; Error texts
TEXT_LAST_ERROR:
    defb AT, 0, 15*8, "Last Error:", AT, 0, 16*8, 0

TEXT_ERROR_RX_TIMEOUT: defb "RX Timeout", 0
TEXT_ERROR_RX_OVERFLOW: defb "RX Buffer overflow", 0
TEXT_ERROR_TX_TIMEOUT: defb "TX Timeout", 0
TEXT_ERROR_WRONG_FUNC_NUMBER: defb "Wrong function number", 0
TEXT_ERROR_WRITE_MAIN_BANK: defb "CMD_WRITE_BANK: Can't write to  bank "
    STRINGIFY MAIN_BANK
    defb ". Bank is used by DeZog.", 0
TEXT_ERROR_CORE_VERSION_NOT_SUPPORTED: ; Core not supported
    defb "Core Version not supported,     should be >= 03.01.10", 0
TEXT_CMD_NOT_SUPPORTED: ; Core not supported
    defb "Command not supported", 0

 IF ROM_VARIANT == ROM_VARIANT_WIFI
; Short on purpose. The status block above already says what to do about it in
; full sentences; this is the machine-readable half of the same fact, in the
; place a user of this program is trained to look for a fault.
TEXT_ERROR_NO_WIFI_ADDRESS:
    defb "No WiFi address", 0
 ENDIF

ERROR_TEXT_TABLE:
    defw TEXT_ERROR_RX_TIMEOUT
    defw TEXT_ERROR_RX_OVERFLOW
    defw TEXT_ERROR_TX_TIMEOUT
    defw TEXT_ERROR_WRONG_FUNC_NUMBER
    defw TEXT_ERROR_WRITE_MAIN_BANK
    defw TEXT_ERROR_CORE_VERSION_NOT_SUPPORTED
    defw TEXT_CMD_NOT_SUPPORTED
 IF ROM_VARIANT == ROM_VARIANT_WIFI
    defw TEXT_ERROR_NO_WIFI_ADDRESS
 ENDIF
