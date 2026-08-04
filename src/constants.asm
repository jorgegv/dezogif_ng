;===========================================================================
; constants.asm
;
; Definition of the main constants.
;===========================================================================



; Is temporarily used. E.g. to change the AltROM. The debugged program can use this bank.
TMP_BANK:       EQU 92
TMP_BANKB:       EQU 93

; The 8k memory bank to store the code to.
; Debugged programs cannot use this bank.
MAIN_BANK:      EQU 94  ; Last 8k bank on unexpanded ZXNext.

MAIN_SLOT:      EQU 7   ; 0xE000
SWAP_SLOT:      EQU 6   ; 0xC000, used only temporary

LOOPBACK_BANK:  EQU 91 ; Used for the loopback test. Could be any bank as the loopback test is not done with a running debugged program.

; The address that correspondends to the main bank.
MAIN_ADDR:      EQU MAIN_SLOT*0x2000

; The address that correspondends to the swap slot bank.
SWAP_ADDR:      EQU SWAP_SLOT*0x2000

; Use the build time
BUILD_TIME16: equ BUILD_TIME & 0xFFFF
; DISPLAY "BUILD_TIME: ", BTIME


;===========================================================================
; ROM identity block — issue #4.
;
; A fixed marker saying "this enNextMf.rom is ours, and which variant it is".
; It answers IDENTITY. The CRC in the .sum files answers INTEGRITY, and the
; two must not be confused again: a CRC identifies one BUILD, because
; BUILD_TIME is stamped into every ROM, so it changes on every rebuild and
; every release. Using it for identity meant that after any upgrade mfselect
; no longer recognised our own ROM — and its first-run guard, which exists to
; stop it saving OUR ROM as the user's `original.rom`, stopped firing.
;
; AT THE VERY END OF THE IMAGE, and that is the whole point of the address.
; tbblue.fw loads exactly 8192 bytes, so the last of them are the one anchor
; in this file that cannot drift as the code grows. Anything measured from the
; start would move the first time something above it changed size.
;
;   ROM file offset 0x1FE0 .. 0x1FFF   =   address 0xFEA0 .. 0xFEBF
;   (the image is mf_nmi.bin, 0x140 bytes, followed by main.bin from 0xE000,
;    so offset = 0x140 + address - 0xE000)
;
; NEVER MOVE THIS. Its only value is being in the same place in every release
; we have ever shipped and will ever ship. A build that cannot fit below it
; must shrink, which is what the ASSERT in main.asm enforces.
;===========================================================================
;   DeZoGiFnG_UART_00A3
;   DeZoGiFnG_WIFI_00A3
;   \________/ \__/ \__/
;    identity   |    build number, 4 uppercase hex digits, from version.yaml
;               transport variant
;
; THE PREFIX IS THE IDENTITY AND THE SUFFIX IS NOT. A reader must match
; "DeZoGiFnG_" to answer "is this ours", then the variant field to answer
; "which one". The build number is information to *show* the user, never
; something to match on — matching it would reintroduce exactly the
; per-build fragility this block exists to remove.
ROM_MAGIC_ADDR:     equ MAIN_ADDR + 0x1EA0  ; 0xFEA0 = ROM offset 0x1FE0
ROM_MAGIC_SIZE:     equ 32                  ; reserved; the string is 20 bytes

; Which transport this ROM was assembled against. There is only one build
; today; the assembly-time switch is M1's, and issue #5 is the consumer that
; needs to tell two of our ROMs apart — no CRC can, since both change on every
; build.
ROM_VARIANT_UART:   equ 0
ROM_VARIANT_WIFI:   equ 1
ROM_VARIANT:        equ ROM_VARIANT_UART



; UART baudrate
;BAUDRATE:   equ 2000000
;BAUDRATE:   equ 1958400
;BAUDRATE:   equ 1228800
BAUDRATE:   equ 921600
;BAUDRATE:   equ 614400
;BAUDRATE:   equ 460800
;BAUDRATE:   equ 230400


; Program states
PRGM_IDLE:		equ 1	; Waiting for a new program (at program start and after CMD_CLOSE)
PRGM_LOADING:	equ 2	; After CMD_INIT until the first CMD_CONTINUE
PRGM_STOPPED:	equ 3	; After breakpoint or NMI
PRGM_RUNNING:	equ 4	; After CMD_CONTINUE
