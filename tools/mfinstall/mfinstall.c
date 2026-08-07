/*
 * mfinstall — put a dezogif_ng ROM into Multiface ROM space at RUN TIME,
 * through config mode, without ever writing the SD card (issue #21).
 *
 * Deployed as /dot/mfinstall and run from the NextZXOS command line or from
 * AUTOEXEC.BAS. NextZXOS is assumed present at all times: every file access is
 * the esxdos API.
 *
 *     .mfinstall --load wifi     the WiFi build becomes the live Multiface ROM
 *     .mfinstall --load uart     the UART build does
 *     .mfinstall --unload        the captured original does
 *     .mfinstall --auto          whichever /mfselect/mfinstall.yml names
 *     .mfinstall --help
 *
 * IT LIVES IN /dot/ AND ITS ROMs LIVE IN /mfselect/, and that split is not a
 * preference. Dot commands are looked up in /dot/ — checked on the reference SD
 * image, which carries DISPLAYEDGE and ESPUPDATE there, so a nine-character
 * name is fine — while the ROMs stay where mfselect already puts them and
 * doc/MFSELECT.md already documents. Issue #21 says "with access to the same ROM
 * files", and that is what is preserved; only the binary moves.
 *
 * HOW THIS DIFFERS FROM mfselect, WHICH IS THE THING TO UNDERSTAND FIRST:
 *
 *   mfselect   writes the SD card. The change is PERMANENT and takes effect at
 *              the next POWER-ON, because tbblue.fw reads enNextMf.rom then.
 *   mfinstall  writes SRAM. The change is LIVE IMMEDIATELY and lasts until the
 *              next POWER-OFF, because tbblue.fw reloads that SRAM from the card
 *              every power-on. THE SD CARD IS NEVER WRITTEN — not even by
 *              --unload, which is why "unload" means "put the original back for
 *              the rest of this session" and nothing more. See doc/MFINSTALL.md.
 *
 * THE MECHANISM IS MEASURED, NOT INHERITED FROM DOCUMENTATION. Two probes under
 * a booted NextZXOS in jnext established it, and the second one carried a
 * one-constant control (issue #21's measurement comments):
 *
 *   - A dot command runs at 0x2000 with DivMMC RAM mapped there by CONMEM, so
 *     the DivMMC ROM is necessarily at 0x0000 too, where it is read-only. Config
 *     mode leaves DivMMC eligible in the second arbiter, so DivMMC wins and
 *     every config-mode write to bank 5 is SILENTLY DISCARDED. Measured: the
 *     probe read back enNxtmmc.rom's bytes.
 *   - With the critical section relocated above 0x4000 and DivMMC turned OFF,
 *     the write LANDS and the command SURVIVES. The control — the same routine
 *     with DivMMC left on — reproduces the blocked result from the same code
 *     location, so DivMMC-off is the load-bearing step and relocation is merely
 *     what makes it survivable.
 *
 * All of that lives in mfwin.asm, which is assembled at a fixed address and
 * copied to 0x5000 before every call. This file never enters config mode itself.
 *
 * IT USES THE SCREEN AS ITS BUFFER, and says so out loud because it is visible:
 * 0x4000-0x57FF (the display file's pixels) holds the 4 KB image buffer, the
 * relocated routine, its variables and its stack. Everything at 0x2000 — this
 * code and its statics included — vanishes while DivMMC is off, so nothing there
 * can be used. Nothing prints between filling the buffer and the routine
 * returning, because printing scrolls the screen and would destroy both. The
 * pixels are blanked afterwards; the attributes at 0x5800 are never touched.
 *
 * IDENTITY AND INTEGRITY ARE DIFFERENT QUESTIONS, exactly as in mfselect:
 *
 *   identity   "is this ours, and which variant?"  -> the magic string at ROM
 *              offset 0x1FE0 (issue #4), matched on PREFIX AND VARIANT and never
 *              on the build number
 *   integrity  "did these bytes land intact?"      -> CRC-16/CCITT against the
 *              .sum sidecar, before anything is written
 *
 * plus one this program needs and mfselect does not: whether the bytes actually
 * REACHED the ROM, which is checked by reading them back INSIDE the window. A
 * discarded write is this mechanism's entire failure mode.
 *
 * EXIT STATUS IS DELIBERATE, and both measurement probes got it wrong: they used
 * `void main(void)`, left HL holding whatever, and NextZXOS printed a spurious
 * "Path too long, 0:1" after otherwise perfect output. The z88dk dot crt reads
 * main's return value (zxn_crt_286.asm.m4:332-346): 0 exits cleanly, 1..255 is a
 * BASIC error code, and anything larger is a pointer to a custom message whose
 * last character carries +0x80. This program returns 0 or a custom message.
 *
 * THE 32-COLUMN RULE IS HELD AT COMPILE TIME. Every fixed string below is
 * declared with FITS(), which is mfselect's `typedef char x[(cond) ? 1 : -1]`
 * idiom — MEMORY.md issue #20 records a row that was already exactly full and
 * whose overflow would have been clipped in silence.
 */

#include <arch/zxn.h>
#include <arch/zxn/esxdos.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

/* ------------------------------------------------------------------ */
/* the card                                                           */
/* ------------------------------------------------------------------ */

/* The names and the directory are mfselect's, not this program's, and must not
 * drift from tools/mfselect/mfselect.c — the two programs install the same files
 * from the same place by different means. */
#define WIFI_ROM    "/mfselect/dezowifi.rom"
#define WIFI_SUM    "/mfselect/dezowifi.sum"
#define UART_ROM    "/mfselect/dezouart.rom"
#define UART_SUM    "/mfselect/dezouart.sum"
#define ORIG_ROM    "/mfselect/original.rom"
#define ORIG_SUM    "/mfselect/original.sum"
#define CONF_FILE   "/mfselect/mfinstall.yml"

/* tbblue.fw loads exactly this many bytes into the Multiface ROM's SRAM, so
 * anything else is refused rather than copied around. */
#define ROM_SIZE    8192U
#define CHUNK       512U

/* ---- ROM identity (issue #4) --------------------------------------------
 *
 *     DeZoGiFnG_UART_0010        DeZoGiFnG_WIFI_0010
 *
 * MATCH THE PREFIX AND THE VARIANT, NEVER THE BUILD NUMBER. The trailing four
 * hex digits show a user which build they have; treating them as identity is
 * the per-build fragility issue #4 removed, and it cost a user's backup once.
 *
 * The offset is a permanent contract with src/constants.asm: the END of an image
 * whose size the firmware fixes at 8192, chosen because it cannot drift as the
 * code grows. */
/* The OFFSET is deliberately NOT repeated here: mfwin.asm holds it, because
 * mfwin.asm is what reads it, and one contract in two files is the drift this
 * project has paid for more than once. */
#define MAGIC_PREFIX    "DeZoGiFnG_"
#define MAGIC_PREFIX_N  10U
#define MAGIC_READ      20U     /* prefix + 4 variant + '_' + 4 build + NUL */
#define BUILD_N         4U
#define BUILD_SHOWN_N   (BUILD_N + 1U)  /* NN.NN — one stored form, displayed */

/* No ID_UNREADABLE: unlike mfselect's, this identity check is handed a block of
 * bytes rather than a path, so "could not read it" is the caller's problem and
 * never this function's answer. */
#define ID_NOT_OURS     0
#define ID_UART         1
#define ID_WIFI         2
#define ID_OURS_OTHER   3       /* ours, but a variant this build predates */

#define BAD_HANDLE  0xFF

/* ------------------------------------------------------------------ */
/* the window                                                         */
/* ------------------------------------------------------------------ */

#include "mfwin_bin.h"          /* mfwin_bin[], MFWIN_BIN_LEN — from mfwin.asm */

/* These MUST agree with mfwin.asm's own EQUs. They are spelled out rather than
 * generated because there are six of them and a generator would be more moving
 * parts than the thing it generates — but a disagreement is silent, so the
 * assembler asserts the layout on its side and win_call() checks the copy landed
 * on this one. */
#define BUF         ((uint8_t *)0x4000)
#define BUF_LEN     4096U
#define CODE_ORG    0x5000
#define VARS        ((uint8_t *)0x5400)

#define W_OP        0x00        /* 1 */
#define W_DST       0x01        /* 2 */
#define W_LEN       0x03        /* 2 */
#define W_RES       0x05        /* 1 */
#define W_STAGE     0x06        /* 1 */
#define W_ID        0x20        /* MAGIC_READ */

#define OP_READ_ID  0
#define OP_SYNC     1

#define RES_OK      0       /* differed; written and verified */
#define RES_VERIFY  1       /* written, and the read-back disagrees */
#define RES_SAME    2       /* already identical; nothing written */

/* The display file's pixel area, which this program borrows wholesale. */
#define PIXELS      ((uint8_t *)0x4000)
#define PIXELS_LEN  6144U

/* ------------------------------------------------------------------ */
/* messages — every one of them 32 columns or fewer                   */
/* ------------------------------------------------------------------ */

/* mfselect's compile-time assert idiom, applied to a string literal: 32 visible
 * characters plus the NUL. A message too wide is a BUILD failure, not something
 * to notice in a screenshot — print_at-style clipping is exactly what issue #20
 * caught happening in silence. */
#define FITS(tag, s) typedef char col_fits_##tag[(sizeof(s) <= 33) ? 1 : -1]

#define M_TITLE   ".mfinstall - dezogif_ng"
#define M_U1      "Usage: .mfinstall <option>"
#define M_U2      " --load wifi  install WiFi ROM"
#define M_U3      " --load uart  install UART ROM"
#define M_U4      " --unload     restore original"
#define M_U5      " --auto       use mfinstall.yml"
#define M_U6      " --help       this text"
#define M_U7      "ROMs in /mfselect/. Live until"
#define M_U8      "power-off; the SD card is never"
#define M_U9      "written. Takes effect on the"
#define M_U10     "next NMI button press."

#define M_LOADW   "Installing the WiFi ROM..."
#define M_LOADU   "Installing the UART ROM..."
#define M_UNLOAD  "Restoring the original ROM..."
#define M_CHECK   "Checking the source ROM..."
#define M_WRITING "Writing the Multiface ROM..."
#define M_LIVE    "Live now. Press NMI to enter."
#define M_SAME    "Already loaded; nothing written."
#define M_AUTONO  "mfinstall.yml says: none."

#define E_ARGS    "Bad arguments; try --help"
#define E_NOSUM   "No .sum beside that ROM"
#define E_OPEN    "Cannot open the ROM file"
#define E_SIZE    "ROM file is not 8192 bytes"
#define E_CRC     "Source ROM fails its checksum"
#define E_READ    "Short read from the ROM file"
#define E_RELOC   "0x5000 is not writable RAM"
#define E_BLOCKED "Write blocked: ROM unchanged"
#define E_NOCONF  "No /mfselect/mfinstall.yml"
#define E_CONFBAD "mfinstall.yml: bad install:"

FITS(title,   M_TITLE);
FITS(u1,  M_U1);  FITS(u2,  M_U2);  FITS(u3,  M_U3);  FITS(u4,  M_U4);
FITS(u5,  M_U5);  FITS(u6,  M_U6);  FITS(u7,  M_U7);  FITS(u8,  M_U8);
FITS(u9,  M_U9);  FITS(u10, M_U10);
FITS(loadw,   M_LOADW);   FITS(loadu,  M_LOADU);   FITS(unload, M_UNLOAD);
FITS(check,   M_CHECK);   FITS(writing, M_WRITING); FITS(live,  M_LIVE);
FITS(same,    M_SAME);    FITS(autono,  M_AUTONO);
FITS(eargs,   E_ARGS);    FITS(enosum, E_NOSUM);   FITS(eopen,  E_OPEN);
FITS(esize,   E_SIZE);    FITS(ecrc,   E_CRC);     FITS(eread,  E_READ);
FITS(ereloc,  E_RELOC);   FITS(eblocked, E_BLOCKED);
FITS(enoconf, E_NOCONF);  FITS(econfbad, E_CONFBAD);

/* The lead of the line that REPORTS which ROM is live. It is reporting and
 * nothing else: since the compare became the idempotence test (see load_rom),
 * no decision is taken on the identity block at all, which is what issue #4
 * says that block is not for.
 *
 * "Live ROM: " is 10, the longest name ("dezogif_ng WiFi") is 15, plus a space
 * and the five of "00.10" — 31, inside the 32 columns there are. app() bounds
 * it at 32 regardless, so this arithmetic is a check on the design and not the
 * thing keeping the line short. (An earlier comment here did the sum for a
 * 14-character lead against a 9-character string and got 35; the arithmetic was
 * stale, not the bound.) */
#define M_LIVEIS "Live ROM: "
FITS(liveis, M_LIVEIS);

/* ------------------------------------------------------------------ */
/* state                                                              */
/* ------------------------------------------------------------------ */

/* One shared I/O buffer, in the dot command's own 8 KB at 0x2000. Used only for
 * the checksum pass and the config file — never while DivMMC is off, when it
 * does not exist. */
static uint8_t buf[CHUNK];

/* The live ROM's identity block, copied out of the window's variables the
 * moment it returns, before anything is printed. */
static uint8_t live_id[MAGIC_READ];

/* A custom esxdos error message, assembled here because the crt hands NextZXOS
 * a POINTER and the string must still exist after main returns. */
static char errbuf[34];

static char line[33];

/* ------------------------------------------------------------------ */
/* output                                                             */
/* ------------------------------------------------------------------ */

/* Everything printed goes through here, so there is exactly one place that
 * could ever exceed 32 columns and it cannot: the FITS() asserts cover the
 * literals, and the composed lines are built with a bounded appender. */
static void say(const char *s)
{
    puts((char *)s);   /* z88dk's puts takes char *, not const char * */
}

/* Append at most what is left of `line`, always NUL-terminated. Returns the new
 * length, so a caller can chain without tracking it. */
static uint8_t app(uint8_t n, const char *s)
{
    while (*s && n < 32)
        line[n++] = *s++;
    line[n] = 0;
    return n;
}

/* ------------------------------------------------------------------ */
/* checksum — CRC-16/CCITT, the same one tools/romsum.py and mfselect  */
/* compute, because the .sum files are worthless if they disagree      */
/* ------------------------------------------------------------------ */

static uint16_t crc16(uint16_t crc, uint8_t *p, uint16_t n)
{
    uint8_t i;

    while (n--) {
        crc ^= ((uint16_t)(*p++)) << 8;
        for (i = 0; i < 8; i++)
            crc = (crc & 0x8000) ? (uint16_t)((crc << 1) ^ 0x1021)
                                 : (uint16_t)(crc << 1);
    }
    return crc;
}

/* Read a .sum sidecar: four hex digits. 0 on success, -1 on a missing, short or
 * malformed file. Silent; callers report in their own terms. */
static int8_t read_sum(const char *path, uint16_t *out)
{
    uint8_t  h, i, c, d;
    uint16_t n, v = 0;

    h = esx_f_open(path, ESX_MODE_R | ESX_MODE_OPEN_EXIST);
    if (h == BAD_HANDLE)
        return -1;
    n = esx_f_read(h, buf, 8);
    esx_f_close(h);
    if (n < 4)
        return -1;

    for (i = 0; i < 4; i++) {
        c = buf[i];
        if (c >= '0' && c <= '9')      d = c - '0';
        else if (c >= 'A' && c <= 'F') d = c - 'A' + 10;
        else if (c >= 'a' && c <= 'f') d = c - 'a' + 10;
        else return -1;
        v = (uint16_t)(v << 4) | d;
    }

    *out = v;
    return 0;
}

/* CRC of a ROM file, which must be exactly ROM_SIZE bytes. 0 and stores the
 * CRC, or -1 with the reason in *why.
 *
 * A bitwise CRC over 8K takes a few seconds at 3.5 MHz, which is why the caller
 * says what it is about to do first. The CPU speed is deliberately left alone,
 * as mfselect leaves it: this runs seldom, and changing the clock under
 * NextZXOS's SD I/O buys speed with a risk not worth taking. */
static int8_t rom_crc(const char *path, uint16_t *out, const char **why)
{
    uint8_t  h;
    uint16_t crc = 0xFFFF;
    uint16_t total = 0;
    uint16_t n;

    h = esx_f_open(path, ESX_MODE_R | ESX_MODE_OPEN_EXIST);
    if (h == BAD_HANDLE) {
        *why = E_OPEN;
        return -1;
    }

    while (total < ROM_SIZE) {
        n = esx_f_read(h, buf, CHUNK);
        if (n == 0)
            break;
        crc = crc16(crc, buf, n);
        total += n;
    }
    esx_f_close(h);

    if (total != ROM_SIZE) {
        *why = E_SIZE;
        return -1;
    }

    *out = crc;
    return 0;
}

/* ------------------------------------------------------------------ */
/* identity                                                           */
/* ------------------------------------------------------------------ */

/* Identify a ROM from a 20-byte identity block, wherever it came from — a file
 * on the card or the live ROM read back through the window. Split out from any
 * file reading precisely so both sources are judged by the same code. */
static int8_t id_of(const uint8_t *blk)
{
    uint8_t i;

    for (i = 0; i < MAGIC_PREFIX_N; i++) {
        if (blk[i] != (uint8_t)MAGIC_PREFIX[i])
            return ID_NOT_OURS;
    }
    if (blk[MAGIC_PREFIX_N] == 'W')
        return ID_WIFI;
    if (blk[MAGIC_PREFIX_N] == 'U')
        return ID_UART;
    /* Ours, but a variant this build predates. It gets its own value rather than
     * being folded into UART: guessing a variant would be a false statement
     * about the ROM, which is the whole thing this block exists to stop. */
    return ID_OURS_OTHER;
}

static const char *id_name(int8_t id)
{
    if (id == ID_UART)       return "dezogif_ng UART";
    if (id == ID_WIFI)       return "dezogif_ng WiFi";
    if (id == ID_OURS_OTHER) return "dezogif_ng ROM";
    return "not ours";
}

/* The build number in its NN.NN display form (issue #20) — high byte, dot, low
 * byte. ONE STORED FORM WITH ONE DISPLAY TRANSFORM: the block keeps four bare
 * digits, because its format is a contract mfselect parses, and the dot is
 * applied here exactly as mfselect applies it. */
static void build_str(const uint8_t *blk, char *out)
{
    uint8_t i;

    for (i = 0; i < BUILD_N; i++)
        out[i < 2U ? i : i + 1U] = (char)blk[MAGIC_PREFIX_N + 5U + i];
    out[2]             = '.';
    out[BUILD_SHOWN_N] = 0;
}

/* "Live ROM: dezogif_ng WiFi 00.10" — bounded at 32 by app(), so the arithmetic
 * in the comment above M_LIVEIS does not have to be trusted at run time. */
static void say_id(const char *lead, int8_t id, const uint8_t *blk)
{
    char b[BUILD_SHOWN_N + 1];
    uint8_t n;

    n = app(0, lead);
    n = app(n, id_name(id));
    if (id != ID_NOT_OURS) {
        build_str(blk, b);
        n = app(n, " ");
        n = app(n, b);
    }
    (void)n;
    say(line);
}

/* ------------------------------------------------------------------ */
/* the config-mode window                                             */
/* ------------------------------------------------------------------ */

/* Run one window operation.
 *
 * THE ROUTINE IS RE-COPIED EVERY TIME, and that is not defensive clutter: it
 * lives at 0x5000, in the display file, and ANY printf between two calls scrolls
 * the screen and destroys it. Re-copying costs a few hundred bytes of memcpy and
 * removes a whole class of "works until someone adds a progress message".
 *
 * The copy is also CHECKED, which doubles as proof that 0x5000 really is
 * writable RAM — the assumption the entire relocation rests on. Returns 0 if the
 * window ran and its own verify was happy.
 */
static int8_t win_call(uint8_t op, uint16_t dst, uint16_t len)
{
    memcpy((void *)CODE_ORG, mfwin_bin, MFWIN_BIN_LEN);
    if (memcmp((void *)CODE_ORG, mfwin_bin, MFWIN_BIN_LEN) != 0)
        return -1;

    VARS[W_OP]      = op;
    VARS[W_DST]     = (uint8_t)(dst & 0xFF);
    VARS[W_DST + 1] = (uint8_t)(dst >> 8);
    VARS[W_LEN]     = (uint8_t)(len & 0xFF);
    VARS[W_LEN + 1] = (uint8_t)(len >> 8);

    /* Everything from here to the return is mfwin.asm. It does its own di/ei
     * and its own SP switch; this call's return address is pushed on the
     * CALLER's stack, which the routine saves and restores. */
    ((void (*)(void))CODE_ORG)();

    /* The window's own RES_*, passed through rather than flattened: the caller
     * has to tell "wrote it" from "it was already there", and that distinction
     * IS the idempotence. -1 above is the one thing the window never reports,
     * because it never ran. */
    return (int8_t)VARS[W_RES];
}

/* Blank the pixels we borrowed. NOT a restore — there is nowhere to keep 6144
 * bytes while DivMMC is off, so the screen's previous contents are gone and
 * saying "restore" would be a claim this cannot make. The attributes at 0x5800
 * are untouched (the window's stack tops out at 0x5800 and grows down), so the
 * screen ends up blank in its own colours and the console carries on printing
 * from wherever it was. */
static void blank_pixels(void)
{
    memset(PIXELS, 0, PIXELS_LEN);
}

/* ------------------------------------------------------------------ */
/* the install                                                        */
/* ------------------------------------------------------------------ */

/* Make Multiface ROM SRAM equal a ROM file, in two 4 KB passes, and say whether
 * anything actually had to change.
 *
 * IDEMPOTENCE LIVES HERE, and that is the point of doing it this way. Each pass
 * is COMPARED against what is live before it is written, inside the same window
 * — the bytes are already in the buffer, so it costs one extra scan of 4 KB and
 * no extra window entry. If every pass matches, nothing is written at all.
 *
 * IT REPLACED AN IDENTITY MATCH, and the difference is not academic. The old
 * test asked the identity block whether a WiFi ROM was live, which is a
 * different question from whether THESE bytes are: a locally rebuilt stub is a
 * new ROM wearing the same `DeZoGiFnG_WIFI_0010`, and would not have been
 * installed until someone remembered to bump. The person running this
 * repeatedly is the person rebuilding the stub. The identity block is still
 * read, for what issue #4 says it is for — telling the user which ROM is live.
 *
 * TWO PASSES BECAUSE 8192 BYTES DO NOT FIT. The buffer, the routine, its
 * variables and its stack must ALL live above 0x4000, and the display file's
 * pixel area is 6144 bytes; 8 KB of image alongside them does not fit anywhere
 * that survives DivMMC going off. Two passes of 4 KB do, with the buffer ending
 * exactly where the routine begins — asserted on both sides.
 *
 * NOTHING IS PRINTED INSIDE A PASS. The buffer is the screen.
 *
 * Returns 0, or a message; *changed is set when any pass was written. The ROM is
 * left partially written on a failure in the second pass, and that is deliberate
 * rather than overlooked: there is nothing to roll back TO — the previous
 * contents were overwritten by the first pass and are not stored anywhere. The
 * failure is reported plainly and the ROM is dead until another install or a
 * power cycle, which is a state a power cycle always fixes. mfselect's
 * temporary-file-and-rename dance has no analogue here because SRAM has no
 * rename.
 */
static const char *load_rom(const char *path, uint8_t *changed)
{
    uint8_t  h;
    uint16_t pass, off, got;

    *changed = 0;

    h = esx_f_open(path, ESX_MODE_R | ESX_MODE_OPEN_EXIST);
    if (h == BAD_HANDLE)
        return E_OPEN;

    for (pass = 0; pass < 2; pass++) {
        /* 512 at a time, as mfselect does, so every buffer stays well inside
         * the 0x4000-0xBFE0 window the esxdos API wants. */
        for (off = 0; off < BUF_LEN; off += CHUNK) {
            got = esx_f_read(h, BUF + off, CHUNK);
            if (got != CHUNK) {
                esx_f_close(h);
                return E_READ;
            }
        }

        switch (win_call(OP_SYNC, (uint16_t)(pass * BUF_LEN), BUF_LEN)) {
        case RES_SAME:
            break;                      /* already these bytes; nothing done */
        case RES_OK:
            *changed = 1;
            break;
        case -1:
            esx_f_close(h);
            return E_RELOC;
        default:
            /* RES_VERIFY: the window read back something other than what it
             * wrote. On the evidence of issue #21's first probe the
             * overwhelmingly likely cause is that the write was DISCARDED —
             * DivMMC, or an MMU RAM page in slot 0, winning the arbitration.
             * Bench check I7 builds exactly that state on purpose. */
            esx_f_close(h);
            return E_BLOCKED;
        }
    }

    esx_f_close(h);
    return 0;
}

/* ------------------------------------------------------------------ */
/* the config file                                                    */
/* ------------------------------------------------------------------ */

/* /mfselect/mfinstall.yml, one key:
 *
 *     install: wifi        # or uart, or none
 *
 * Deliberately not a YAML parser. It finds a line whose first word is
 * "install:", and reads the next word. '#' starts a comment. That is the whole
 * of the format issue #21 specifies, and a parser for more would be a parser
 * for things this program does not accept.
 *
 * Returns ID_WIFI / ID_UART / ID_NOT_OURS (meaning "none"), or -1 with a reason.
 */
static int8_t read_config(const char **why)
{
    uint8_t  h;
    uint16_t n, i;
    uint8_t  c;

    h = esx_f_open(CONF_FILE, ESX_MODE_R | ESX_MODE_OPEN_EXIST);
    if (h == BAD_HANDLE) {
        *why = E_NOCONF;
        return -1;
    }
    n = esx_f_read(h, buf, CHUNK - 1);
    esx_f_close(h);
    buf[n] = 0;

    i = 0;
    while (i < n) {
        /* start of a line: skip leading blanks */
        while (i < n && (buf[i] == ' ' || buf[i] == '\t'))
            i++;

        if (i < n && buf[i] != '#' &&
            (n - i) >= 8U && memcmp(&buf[i], "install:", 8) == 0) {
            i += 8;
            while (i < n && (buf[i] == ' ' || buf[i] == '\t'))
                i++;
            c = buf[i];
            if (c == 'w' || c == 'W')
                return ID_WIFI;
            if (c == 'u' || c == 'U')
                return ID_UART;
            if (c == 'n' || c == 'N')
                return ID_NOT_OURS;
            *why = E_CONFBAD;
            return -1;
        }

        /* to the end of this line */
        while (i < n && buf[i] != '\n' && buf[i] != '\r')
            i++;
        while (i < n && (buf[i] == '\n' || buf[i] == '\r'))
            i++;
    }

    *why = E_CONFBAD;
    return -1;
}

/* ------------------------------------------------------------------ */

static void usage(void)
{
    say(M_U1);
    say(M_U2);
    say(M_U3);
    say(M_U4);
    say(M_U5);
    say(M_U6);
    say(M_U7);
    say(M_U8);
    say(M_U9);
    say(M_U10);
}

/* A custom esxdos error message: NextZXOS prints the string, and the LAST
 * CHARACTER carries +0x80 as the end marker. Built into a static because the crt
 * hands BASIC a pointer, and main's locals are gone by then. */
static int fail(const char *msg)
{
    uint8_t n = 0;

    while (msg[n] && n < sizeof(errbuf) - 2) {
        errbuf[n] = msg[n];
        n++;
    }
    if (n == 0)
        errbuf[n++] = '?';
    errbuf[n - 1] = (char)(errbuf[n - 1] | 0x80);
    errbuf[n] = 0;
    return (int)errbuf;
}

/* Options, resolved before anything is touched.
 *
 * argv[0] is EMPTY for esxdos dot commands — the crt says so outright — so
 * options start at argv[1]. */
#define ACT_HELP    0
#define ACT_LOAD    1
#define ACT_UNLOAD  2

int main(int argc, char **argv)
{
    uint8_t  act = ACT_HELP;
    int8_t   want = ID_NOT_OURS;    /* which variant --load/--auto asked for */
    int8_t   liveid;
    uint8_t  changed = 0;
    uint16_t want_crc, got_crc;
    const char *rom = 0, *sum = 0, *why = 0;
    const char *doing = 0;
    uint8_t  i;

    say(M_TITLE);

    /* --- what were we asked to do ------------------------------------- */
    for (i = 1; i < (uint8_t)argc; i++) {
        const char *a = argv[i];

        if (strcmp(a, "--help") == 0 || strcmp(a, "-h") == 0) {
            usage();
            return 0;
        } else if (strcmp(a, "--unload") == 0) {
            act = ACT_UNLOAD;
        } else if (strcmp(a, "--auto") == 0) {
            want = read_config(&why);
            if (want < 0)
                return fail(why);
            if (want == ID_NOT_OURS) {
                /* The config file says do nothing, which is a SUCCESS and not a
                 * reason to print usage at every boot — `--auto` lives in
                 * AUTOEXEC.BAS and runs on days nobody is debugging. */
                say(M_AUTONO);
                return 0;
            }
            act = ACT_LOAD;
        } else if (strcmp(a, "--load") == 0 && (i + 1) < (uint8_t)argc) {
            i++;
            if (strcmp(argv[i], "wifi") == 0)
                want = ID_WIFI;
            else if (strcmp(argv[i], "uart") == 0)
                want = ID_UART;
            else
                return fail(E_ARGS);
            act = ACT_LOAD;
        } else {
            return fail(E_ARGS);
        }
    }

    if (act == ACT_HELP) {
        usage();
        return 0;
    }

    if (act == ACT_UNLOAD) {
        rom = ORIG_ROM;
        sum = ORIG_SUM;
        doing = M_UNLOAD;
    } else if (want == ID_WIFI) {
        rom = WIFI_ROM;
        sum = WIFI_SUM;
        doing = M_LOADW;
    } else {
        rom = UART_ROM;
        sum = UART_SUM;
        doing = M_LOADU;
    }

    say(doing);

    /* THERE IS NO "IS IT ALREADY THERE?" TEST HERE, and `--unload` gets no case
     * of its own. Every path asks load_rom the same question — do these bytes
     * differ — so "nothing to do" is an OUTCOME rather than a rule, and
     * `--unload` on a machine where nothing of ours is live simply finds the
     * original already in place and writes nothing. The cost is that `--unload`
     * needs /mfselect/original.rom to exist even then, and says so rather than
     * silently succeeding; mfselect is what captures it. */

    /* --- verify the source before writing anything --------------------
     *
     * mfselect's install() does exactly this and for the same reason: a ROM that
     * is already corrupt on the card must not be copied anywhere. Here it
     * matters more, because the destination cannot be rolled back. */
    say(M_CHECK);
    if (read_sum(sum, &want_crc) != 0)
        return fail(E_NOSUM);
    if (rom_crc(rom, &got_crc, &why) != 0)
        return fail(why);
    if (got_crc != want_crc)
        return fail(E_CRC);

    /* --- and make the ROM match it ------------------------------------- */
    say(M_WRITING);
    why = load_rom(rom, &changed);
    if (why) {
        blank_pixels();
        return fail(why);
    }

    /* --- which ROM is live? --------------------------------------------
     *
     * REPORTING ONLY, and read AFTERWARDS rather than before, which is both
     * more useful and the only order that works.
     *
     * More useful because "Live ROM:" then says what is live NOW — the thing
     * just installed — instead of what used to be. It can afford to: nothing is
     * decided on it any more (that is load_rom's byte compare), so there is no
     * reason for it to happen first.
     *
     * And the only order that works because load_rom BLANKS THE SCREEN — it
     * borrows the display file for its buffer — so anything printed before it
     * is wiped. A first version read and printed this beforehand, and the line
     * was erased by the very operation it introduced. Caught by the bench,
     * which reads the screen back as text, and not by reading the diff.
     *
     * The block can only be read HERE, through a read-only pass of the same
     * window: outside it, 0x1FE0 is somebody else's memory entirely.
     */
    if (win_call(OP_READ_ID, 0, 0) < 0) {
        /* The copy dirtied the screen before it failed, so clear up even here.
         * A machine whose 0x5000 is not RAM has larger problems, but leaving
         * half a routine painted across the display is not one to add. */
        blank_pixels();
        return fail(E_RELOC);
    }
    memcpy(live_id, VARS + W_ID, MAGIC_READ);
    blank_pixels();

    liveid = id_of(live_id);
    say_id(M_LIVEIS, liveid, live_id);

    /* NO SOFT RESET IS ISSUED, deliberately. taylorza's worked example ends
     * with `NEXTREG 2,1` and the replacement stuck — what they did, not a
     * stated requirement; issue #21's
     * open question 3 asks whether that is really required, and bench check I2
     * — an M1 button NMI immediately after an install, with no reset — is what
     * answers it. Adding a reset "just in case" would destroy the user's BASIC
     * session to work around something that may not be true, and would make the
     * check unable to answer the question at all. */
    say(changed ? M_LIVE : M_SAME);
    return 0;
}
