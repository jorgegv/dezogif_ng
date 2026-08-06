/*
 * mfselect — switch the Next's Multiface ROM between the stock one and
 * dezogif_ng's, from the machine itself.
 *
 * Deployed as /mfselect/mfselect.nex and run under NextZXOS, which is assumed
 * present at all times: every file access here is the esxdos API, and there is
 * no fallback if it is absent. Loading this NEX without NextZXOS underneath
 * hangs on the first RST $08 — see doc/MFSELECT.md.
 *
 * THE /mfselect/ DIRECTORY IS HARDCODED AND MUST STAY THAT WAY. Installed
 * anywhere else this program does not work at all. That is not laziness: a NEX
 * cannot discover where it lives. `esx_f_getcwd()` returns the LAUNCHER's
 * directory, measured under real NextZXOS (issue #6) — launch it with
 * `.nexload /probedir/x.nex` from a shell sitting at the root and it answers
 * `C:/`, not `/probedir/`. A getcwd-based version would therefore be broken
 * for the invocation doc/MFSELECT.md recommends while appearing to work from
 * the Browser, which is worse than a fixed path. esxdos also has no
 * handle-to-path call. The real fix, if it is ever worth it, is a dot command,
 * which receives a command tail.
 *
 * Files it expects beside itself in /mfselect/:
 *
 *   dezowifi.rom dezowifi.sum  our WiFi-mode ROM and its checksum
 *   dezouart.rom dezouart.sum  our UART-mode ROM and its checksum
 *   original.rom original.sum  the stock ROM, captured on first run
 *
 * The first two pairs are put there when mfselect is installed; `make mfselect`
 * builds both so a user cannot ship one and forget the other. Names are 8.3-safe
 * because the card is FAT and MEMORY.md already rejected 8.3-unsafe names here.
 *
 * BOTH OF OUR VARIANTS ARE OFFERED (issue #5), not just the WiFi one. The UART
 * build is not a legacy leftover: a debuggee that owns the ESP itself cannot be
 * debugged over WiFi, and the serial ROM is the documented answer to that. A
 * variant that can be built but not installed from the machine pushes the user
 * back to swapping files in a PC, which is the whole thing this program exists
 * to avoid.
 *
 * IDENTITY AND INTEGRITY ARE DIFFERENT QUESTIONS, answered by different things:
 *
 *   identity   "is this ours, and which variant?"  -> the magic string in the
 *              ROM itself, at a fixed offset (issue #4)
 *   integrity  "did these bytes land intact?"      -> CRC-16/CCITT, in the
 *              .sum sidecars (tools/romsum.py computes the same value on the
 *              host, and the bench checks the two agree)
 *
 * This program used to answer both with the checksum, and that was a silent
 * data-loss bug rather than an inelegance — see the ROM identity block below.
 * The CRC still detects a truncated or corrupt copy, which is its real job.
 *
 * WHY THE FIRST-RUN CAPTURE IS GUARDED. The obvious rule — "no backup yet, so
 * save whatever is installed as the original" — destroys the stock ROM for
 * exactly the people most likely to run this first: anyone who already
 * installed dezogif_ng by hand has *our* ROM at the official path. Capturing
 * that as "original" would label the debug stub as the stock Multiface ROM and
 * leave no copy of the real one anywhere on the card. So the capture refuses
 * when the installed ROM is ours, and asks before capturing anything else,
 * because "not ours" is not proof of "stock" — it could be upstream dezogif's
 * ROM, or any other third-party Multiface ROM.
 *
 * WHY THERE IS NO printf HERE. z88dk's console for the zxn target is a plain
 * character sink: control codes 12 (cls), 22 (AT), 16/17 (INK/PAPER) all print
 * as '?', and there is no native console redirect for this target. A menu in
 * the NextZXOS style needs positioning and inverse video, so the few screen
 * primitives below write the display file directly, using the ROM font the
 * CHARS system variable points at. Dropping stdio also takes ~7K off the NEX.
 */

#include <arch/zxn.h>
#include <arch/zxn/esxdos.h>
#include <input.h>
#include <stdint.h>
#include <string.h>

#define MF_ROM      "/machines/next/enNextMf.rom"
#define ORIG_ROM    "/mfselect/original.rom"
#define ORIG_SUM    "/mfselect/original.sum"
#define WIFI_ROM    "/mfselect/dezowifi.rom"
#define WIFI_SUM    "/mfselect/dezowifi.sum"
#define UART_ROM    "/mfselect/dezouart.rom"
#define UART_SUM    "/mfselect/dezouart.sum"

/* Every ROM this program writes is written to a temporary first, verified,
 * and only then renamed into place. Opening the real path with CREAT_TRUNC
 * destroys the existing file before the first byte arrives, so a power cut
 * mid-write would leave a short file at a path something else depends on —
 * for ORIG_ROM a backup that exists but is not a ROM, for MF_ROM a Multiface
 * ROM the firmware will still try to load. The temporaries live in the same
 * directory as their destination so the rename cannot cross a volume. */
#define ORIG_TMP    "/mfselect/original.tmp"
#define MF_TMP      "/machines/next/mfselect.tmp"

/* tbblue.fw loads exactly this many bytes, so anything else at the official
 * path is wrong and is refused rather than copied around. */
#define ROM_SIZE    8192U
#define CHUNK       512U

/* ---- ROM identity (issue #4) --------------------------------------------
 *
 * Every ROM we build carries a magic string at a fixed offset:
 *
 *     DeZoGiFnG_UART_0001
 *     DeZoGiFnG_WIFI_0001
 *
 * IDENTITY IS THE MAGIC; INTEGRITY IS THE CRC. Those are different questions
 * and this program used to answer the first with the second, which was a
 * silent data-loss bug: BUILD_TIME is stamped into every ROM, so the CRC
 * changes on every build. After any upgrade the installed ROM no longer
 * matched the .sum beside it, the first-run guard below stopped
 * recognising our own ROM, and the capture it exists to refuse went ahead —
 * saving the debug stub as the user's `original.rom` and leaving no copy of
 * the stock one. The CRC's remaining job, verifying that a copy landed
 * intact, is untouched.
 *
 * MATCH THE PREFIX AND THE VARIANT, NEVER THE BUILD NUMBER. The trailing four
 * hex digits are there to show the user which build they have; treating them
 * as part of identity would put the per-build fragility straight back.
 *
 * THE BLOCK STORES FOUR BARE DIGITS AND WE SHOW THEM AS NN.NN (issue #20) —
 * high byte, dot, low byte, the same way the debugger's own banner does. The
 * dot is a rendering and lives in rom_identity() below, not in the ROM: this
 * field's format is a contract, and giving the same value two stored spellings
 * is how they start to drift.
 *
 * The offset is a permanent contract with src/constants.asm — it is the end of
 * a ROM whose size the firmware fixes at 8192, chosen precisely because it
 * cannot drift as the code grows.
 *
 * ONE ROM OF OURS IS NOT RECOGNISED: any build predating this block. It has no
 * magic, so it reads as ID_NOT_OURS and mfselect will offer to capture it as
 * the user's "original". Bounded rather than dangerous — the capture path
 * shows the checksum and asks Y/N, so it takes an explicit answer to lose the
 * stock ROM, and nothing has been released, so no such ROM exists outside this
 * repository. If one is ever found in the field the answer is to reinstall a
 * current build, not to add a checksum fallback here: that would put back the
 * per-build fragility this block removes. */
#define MAGIC_OFF       0x1FE0UL
#define MAGIC_PREFIX    "DeZoGiFnG_"
#define MAGIC_PREFIX_N  10U
#define MAGIC_READ      20U     /* prefix + 4 variant + '_' + 4 build + NUL */
#define BUILD_N         4U      /* hex digits of the build number, as stored */
#define BUILD_SHOWN_N   (BUILD_N + 1U)  /* NN.NN — the same digits, displayed */

/* Result of rom_identity(). Negative values are failures to read. */
#define ID_UNREADABLE   (-1)
#define ID_NOT_OURS     0
#define ID_UART         1
#define ID_WIFI         2
#define ID_OURS_OTHER   3       /* ours, but a variant this build predates */

#define BAD_HANDLE  0xFF

/* Attributes. Body is bright white on black; bars and the selected row are
 * inverse, which is what both the 128 menu and the NextZXOS browser use to
 * show a selection. */
#define ATTR_BODY   0x47
#define ATTR_BAR    0x78
#define ATTR_WARN   0x46          /* bright yellow on black */
#define ATTR_ERR    0x42          /* bright red on black */

#define SCREEN      ((uint8_t *)0x4000)
#define ATTRS       ((uint8_t *)0x5800)
#define CHARS_SYSVAR (*(uint8_t **)0x5C36)

/* Screen layout. The menu grew a fourth row with issue #5, so ROW_MENU +
 * MENU_ITEMS now reaches row 8 and leaves exactly one blank row before the
 * message area. The typedef below is a compile-time assert on that: adding a
 * fifth entry without moving ROW_MSG would silently paint the menu over the
 * first line of every message this program prints. */
#define ROW_TITLE   0
#define ROW_STATUS  2
#define ROW_PROMPT  4
#define ROW_MENU    5
#define MENU_ITEMS  4
#define ROW_MSG     10
#define ROW_MSG_END 21
#define ROW_FOOT    23

typedef char menu_fits_above_messages[(ROW_MENU + MENU_ITEMS <= ROW_MSG) ? 1 : -1];

/* Menu entries, by index. Named rather than open-coded because the dispatch in
 * main() and the order of menu_text[] have to agree, and a bare `sel == 2` is
 * exactly the kind of thing that survives a reorder unchanged. */
#define MENU_OFFICIAL 0
#define MENU_WIFI     1
#define MENU_UART     2
#define MENU_EXIT     3

/* One shared I/O buffer. 512 bytes rather than the whole 8K so every buffer
 * stays well inside the 0x4000-0xBFE0 window the esxdos API requires. */
static uint8_t buf[CHUNK];

/* Build number of whatever is installed, filled by installed_name() and shown
 * beside it, already in its NN.NN display form. Empty when the installed ROM
 * is not ours and so carries none. */
static char build_str[BUILD_SHOWN_N + 1];

static uint8_t msg_row;

/* ------------------------------------------------------------------ */
/* screen                                                             */
/* ------------------------------------------------------------------ */

static void put_char(uint8_t x, uint8_t y, uint8_t c)
{
    uint8_t *dst = SCREEN + ((y & 0x18) << 8) + ((y & 7) << 5) + x;
    uint8_t *src = CHARS_SYSVAR + ((uint16_t)c << 3);
    uint8_t  i;

    for (i = 0; i < 8; i++) {
        *dst = *src++;
        dst += 256;
    }
}

static void print_at(uint8_t x, uint8_t y, const char *s)
{
    while (*s && x < 32)
        put_char(x++, y, (uint8_t)*s++);
}

static void attr_run(uint8_t x, uint8_t y, uint8_t n, uint8_t a)
{
    uint8_t *p = ATTRS + ((uint16_t)y << 5) + x;

    while (n--)
        *p++ = a;
}

/* Blank a row's characters, leaving its attributes alone. */
static void clear_row(uint8_t y)
{
    uint8_t x;

    for (x = 0; x < 32; x++)
        put_char(x, y, ' ');
}

static void cls(void)
{
    uint8_t y;

    for (y = 0; y < 24; y++) {
        clear_row(y);
        attr_run(0, y, 32, ATTR_BODY);
    }
}

/* Four hex digits into a caller-supplied buffer of at least 5 bytes. */
static void hex4(uint16_t v, char *out)
{
    static const char digits[] = "0123456789ABCDEF";
    uint8_t i;

    for (i = 0; i < 4; i++) {
        out[3 - i] = digits[v & 0x0F];
        v >>= 4;
    }
    out[4] = 0;
}

/* Decimal, up to five digits, into a buffer of at least 6 bytes. */
static void dec5(uint16_t v, char *out)
{
    char tmp[6];
    uint8_t n = 0;

    do {
        tmp[n++] = '0' + (v % 10);
        v /= 10;
    } while (v);
    while (n)
        *out++ = tmp[--n];
    *out = 0;
}

/* The message area, written top-down. Anything past the bottom is dropped
 * rather than allowed to scroll over the menu. */
static void msg_reset(void)
{
    uint8_t y;

    for (y = ROW_MSG; y <= ROW_MSG_END; y++) {
        clear_row(y);
        attr_run(0, y, 32, ATTR_BODY);
    }
    msg_row = ROW_MSG;
}

static void msg(const char *s)
{
    if (msg_row <= ROW_MSG_END)
        print_at(1, msg_row++, s);
}

static void msg_attr(const char *s, uint8_t a)
{
    if (msg_row <= ROW_MSG_END)
        attr_run(0, msg_row, 32, a);
    msg(s);
}

/* "<label> XXXX" — the only formatted output this program needs. */
static void msg_hex(const char *label, uint16_t v)
{
    char line[32];
    char h[5];
    uint8_t i = 0;

    while (label[i] && i < 26) {
        line[i] = label[i];
        i++;
    }
    hex4(v, h);
    line[i++] = h[0];
    line[i++] = h[1];
    line[i++] = h[2];
    line[i++] = h[3];
    line[i] = 0;
    msg(line);
}

static void msg_dec(const char *label, uint16_t v)
{
    char line[32];
    char d[6];
    uint8_t i = 0, j = 0;

    while (label[i] && i < 24) {
        line[i] = label[i];
        i++;
    }
    dec5(v, d);
    while (d[j] && i < 31)
        line[i++] = d[j++];
    line[i] = 0;
    msg(line);
}

static void wait_key(void)
{
    msg("");
    msg("Press any key.");
    in_wait_nokey();
    in_wait_key();
}

/* ------------------------------------------------------------------ */
/* checksum                                                           */
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

/* CRC of a ROM file, which must be exactly ROM_SIZE bytes.
 * Returns 0 and stores the CRC, or -1 having reported why.
 *
 * A bitwise CRC over 8K takes a few seconds at 3.5 MHz, so callers say what
 * they are about to do first — a screen that sits still for four seconds with
 * no explanation reads as a hang. The CPU speed is deliberately left alone:
 * this runs seldom, and changing the clock under NextZXOS's SD I/O would buy
 * speed with a risk not worth taking here. */
static int8_t rom_crc(const char *path, uint16_t *out)
{
    uint8_t  h;
    uint16_t crc = 0xFFFF;
    uint16_t total = 0;
    uint16_t n;

    h = esx_f_open(path, ESX_MODE_R | ESX_MODE_OPEN_EXIST);
    if (h == BAD_HANDLE) {
        msg_attr("cannot open:", ATTR_ERR);
        msg(path);
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
        msg_attr("wrong size, bytes: ", ATTR_ERR);
        msg_dec("  read ", total);
        return -1;
    }

    *out = crc;
    return 0;
}

/* Identify a ROM from its magic block (issue #4).
 *
 * Returns ID_UART / ID_WIFI for one of ours, ID_NOT_OURS for anything else
 * (the stock Multiface ROM included), or ID_UNREADABLE if the file could not
 * be read at all — a distinction the callers need, because "not ours" is a
 * fact about the ROM and "unreadable" is a fact about the card.
 *
 * If build_out is non-NULL it receives the build number in its NN.NN display
 * form plus a NUL — BUILD_SHOWN_N + 1 bytes. It is only ever displayed, which
 * is why the dot is applied here rather than kept as a second field.
 *
 * Cheap on purpose: one seek and a 20-byte read, no 8K pass. That is what lets
 * the menu identify the live ROM on every redraw where a CRC could not. */
static int8_t rom_identity(const char *path, char *build_out)
{
    uint8_t h;
    uint16_t n;
    uint8_t  i;

    if (build_out)
        build_out[0] = 0;

    h = esx_f_open(path, ESX_MODE_R | ESX_MODE_OPEN_EXIST);
    if (h == BAD_HANDLE)
        return ID_UNREADABLE;

    /* A file shorter than the ROM cannot carry the block at all; seeking past
     * the end and reading short is caught by the length check below. */
    esx_f_seek(h, MAGIC_OFF, ESX_SEEK_SET);
    n = esx_f_read(h, buf, MAGIC_READ);
    esx_f_close(h);

    if (n < MAGIC_READ)
        return ID_UNREADABLE;

    for (i = 0; i < MAGIC_PREFIX_N; i++) {
        if (buf[i] != (uint8_t)MAGIC_PREFIX[i])
            return ID_NOT_OURS;
    }

    /* NN.NN: the first two digits, the dot, the last two. The block itself is
     * untouched — see the header above. */
    if (build_out) {
        for (i = 0; i < BUILD_N; i++)
            build_out[i < 2U ? i : i + 1U] = (char)buf[MAGIC_PREFIX_N + 5U + i];
        build_out[2]             = '.';
        build_out[BUILD_SHOWN_N] = 0;
    }

    /* The variant field sits straight after the prefix. An unrecognised one is
     * still OURS — a newer build with a transport this mfselect predates — and
     * that matters more than naming it, because the guard protecting the
     * user's backup keys off "ours" alone. It gets its own value rather than
     * being folded into UART: guessing a variant would be a false statement
     * about the ROM on the card, and the whole point of this block is to stop
     * making those. */
    if (buf[MAGIC_PREFIX_N] == 'W')
        return ID_WIFI;
    if (buf[MAGIC_PREFIX_N] == 'U')
        return ID_UART;
    return ID_OURS_OTHER;
}


/* Read a .sum sidecar: four hex digits. Returns 0 on success, -1 on a missing,
 * short or malformed file. Silent — every caller reports in its own terms. */
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

static int8_t write_sum(const char *path, uint16_t v)
{
    uint8_t h;
    char    h4[5];

    hex4(v, h4);
    buf[0] = h4[0];
    buf[1] = h4[1];
    buf[2] = h4[2];
    buf[3] = h4[3];
    buf[4] = '\n';

    h = esx_f_open(path, ESX_MODE_W | ESX_MODE_OPEN_CREAT_TRUNC);
    if (h == BAD_HANDLE)
        return -1;
    if (esx_f_write(h, buf, 5) != 5) {
        esx_f_close(h);
        return -1;
    }
    esx_f_close(h);
    return 0;
}

/* ------------------------------------------------------------------ */
/* copying                                                            */
/* ------------------------------------------------------------------ */

static int8_t copy_rom(const char *src, const char *dst)
{
    uint8_t  hs, hd;
    uint16_t n, total = 0;

    hs = esx_f_open(src, ESX_MODE_R | ESX_MODE_OPEN_EXIST);
    if (hs == BAD_HANDLE) {
        msg_attr("cannot read:", ATTR_ERR);
        msg(src);
        return -1;
    }
    hd = esx_f_open(dst, ESX_MODE_W | ESX_MODE_OPEN_CREAT_TRUNC);
    if (hd == BAD_HANDLE) {
        msg_attr("cannot write:", ATTR_ERR);
        msg(dst);
        esx_f_close(hs);
        return -1;
    }

    while (total < ROM_SIZE) {
        n = esx_f_read(hs, buf, CHUNK);
        if (n == 0)
            break;
        if (esx_f_write(hd, buf, n) != n) {
            msg_attr("short write at byte ", ATTR_ERR);
            msg_dec("  ", total);
            esx_f_close(hd);
            esx_f_close(hs);
            return -1;
        }
        total += n;
    }

    esx_f_close(hd);
    esx_f_close(hs);

    if (total != ROM_SIZE) {
        msg_attr("copy short, bytes:", ATTR_ERR);
        msg_dec("  ", total);
        return -1;
    }
    return 0;
}

/* ------------------------------------------------------------------ */
/* operations                                                         */
/* ------------------------------------------------------------------ */

/* Copy one of our stored ROMs over the official path, verifying the source
 * before the copy and the result after it. A short write on a tired card is
 * the failure this must not hide, which is why the copy is read back. */
static void install(const char *rom, const char *sum, const char *label)
{
    uint16_t want, got;

    msg_reset();
    msg(label);
    msg("");

    if (read_sum(sum, &want) != 0) {
        msg_attr("no checksum file:", ATTR_ERR);
        msg(sum);
        msg("refusing to install");
        return;
    }

    msg("Checking source...");
    if (rom_crc(rom, &got) != 0)
        return;
    if (got != want) {
        msg_attr("source ROM is corrupt", ATTR_ERR);
        msg_hex("  got  ", got);
        msg_hex("  want ", want);
        return;
    }

    /* Write and verify beside the live ROM, which is not touched until the
     * replacement is known good. */
    msg("Copying...");
    esx_f_unlink(MF_TMP);
    if (copy_rom(rom, MF_TMP) != 0) {
        esx_f_unlink(MF_TMP);
        return;
    }

    msg("Verifying...");
    if (rom_crc(MF_TMP, &got) != 0) {
        esx_f_unlink(MF_TMP);
        return;
    }
    if (got != want) {
        msg_attr("VERIFY FAILED", ATTR_ERR);
        msg_hex("  got  ", got);
        msg_hex("  want ", want);
        msg("the ROM in use was NOT");
        msg("touched; nothing changed.");
        esx_f_unlink(MF_TMP);
        return;
    }

    /* The only moment the live ROM changes: two directory operations, no data
     * movement. Should the rename fail the verified copy is still on the card
     * under MF_TMP, so say where it is rather than leaving the user guessing. */
    esx_f_unlink(MF_ROM);
    if (esx_f_rename(MF_TMP, MF_ROM) != 0) {
        msg_attr("could not put the new ROM in", ATTR_ERR);
        msg("place. A verified copy is at");
        msg(MF_TMP);
        msg("- rename it by hand.");
        return;
    }

    msg_hex("Installed and verified: ", got);
    msg("");
    msg_attr("POWER-CYCLE the Next now:", ATTR_WARN);
    msg("switch it off, then on. The");
    msg("Multiface ROM is read at");
    msg("power-on, so the change takes");
    msg("effect only then.");
}

/* Is the stored backup actually usable? Existence is NOT enough, and assuming
 * it was a silent data-loss path: opening a file with CREAT_TRUNC creates the
 * directory entry before the first byte is written, so a capture interrupted
 * by a power cut leaves a SHORT original.rom. Treating that as "already backed
 * up" makes every later run skip the capture, without a word — and the user
 * then installs the stub believing the stock ROM is safe when no copy of it
 * exists anywhere.
 *
 * Size and a readable checksum only, deliberately not a full CRC re-read: an
 * interrupted capture always yields a short file, which the size test catches
 * instantly, and the backup's bytes are CRC-checked at both moments that
 * matter — when it is written, and again by install() before it is ever copied
 * over the live ROM. Re-reading 8K at every start would add seconds to the
 * common path to re-prove something already proven. */
static int8_t backup_valid(void)
{
    struct esx_stat es;
    uint16_t stored;

    if (esx_f_stat(ORIG_ROM, &es) != 0)
        return 0;
    if (es.size != ROM_SIZE)
        return 0;
    return (read_sum(ORIG_SUM, &stored) == 0);
}

/* First run: capture the stock ROM, with the guard described at the top.
 * Returns after leaving its report on screen. */
static void bootstrap(void)
{
    uint16_t installed, copied;
    int8_t   id;
    uint8_t  k;

    if (backup_valid())
        return;                       /* already captured */

    msg_reset();
    msg("No original ROM backup yet.");
    msg("Checking installed ROM...");

    if (rom_crc(MF_ROM, &installed) != 0) {
        msg_attr("no backup made", ATTR_ERR);
        wait_key();
        return;
    }

    /* THE GUARD, and it now asks the ROM itself rather than a sidecar file.
     *
     * It used to compare the installed ROM's CRC against dezogif.sum. That
     * made the guard depend on the .sum being present AND on it coming from
     * the very same build — and BUILD_TIME changes the CRC on every build, so
     * after any upgrade the comparison failed, the guard fell silent, and this
     * function captured our own ROM as the user's `original.rom`. The magic
     * block is stable across builds by construction, so identity no longer
     * degrades with age, and the "no .sum, refusing to act" path that used to
     * be needed here is gone with it. */
    id = rom_identity(MF_ROM, 0);

    /* rom_crc above has already read this file, so this should not happen —
     * but "should not" is not "cannot", and the safe answer to not knowing
     * what is installed is to leave the card alone rather than capture it. */
    if (id == ID_UNREADABLE) {
        msg_attr("cannot read the installed", ATTR_ERR);
        msg("ROM's identity. Refusing to");
        msg("make a backup.");
        wait_key();
        return;
    }

    if (id != ID_NOT_OURS) {
        msg_attr("That is the dezogif_ng ROM,", ATTR_WARN);
        msg("not the original. Saving it");
        msg("would lose the stock ROM, so");
        msg("no backup was made. Restore");
        msg("the stock ROM by hand first.");
        wait_key();
        return;
    }

    msg_hex("Installed ROM is ", installed);
    msg("which is not ours.");
    msg("");
    msg("Save it as the original? Y/N");

    in_wait_nokey();
    do {
        k = in_inkey();
    } while (k != 'y' && k != 'Y' && k != 'n' && k != 'N');

    if (k == 'n' || k == 'N') {
        msg("No backup made.");
        wait_key();
        return;
    }

    msg("Saving...");
    esx_f_unlink(ORIG_TMP);
    if (copy_rom(MF_ROM, ORIG_TMP) != 0) {
        msg_attr("backup failed", ATTR_ERR);
        esx_f_unlink(ORIG_TMP);
        wait_key();
        return;
    }
    /* INTEGRITY, not identity — this is the CRC's remaining job and it is
     * untouched by the magic block: did the bytes we just wrote match the
     * bytes we read? A short write on a tired card is what this catches. */
    if (rom_crc(ORIG_TMP, &copied) != 0 || copied != installed) {
        msg_attr("backup verify FAILED;", ATTR_ERR);
        msg("nothing was saved.");
        esx_f_unlink(ORIG_TMP);
        wait_key();
        return;
    }

    /* Checksum first, then the rename. A power cut between the two leaves no
     * original.rom at all, so the next run simply captures again — whereas the
     * reverse order could leave a ROM with no checksum beside it, which
     * backup_valid() would reject and no run could ever repair. */
    if (write_sum(ORIG_SUM, installed) != 0) {
        msg_attr("could not write the sum;", ATTR_ERR);
        msg("nothing was saved.");
        esx_f_unlink(ORIG_TMP);
        wait_key();
        return;
    }
    esx_f_unlink(ORIG_ROM);
    if (esx_f_rename(ORIG_TMP, ORIG_ROM) != 0) {
        msg_attr("could not store the backup;", ATTR_ERR);
        msg("a verified copy is at");
        msg(ORIG_TMP);
        wait_key();
        return;
    }

    msg_hex("Saved original ROM: ", installed);
    wait_key();
}

/* Name of whichever ROM is currently at the official path. */
static const char *installed_name(void)
{
    uint16_t cur, other;
    int8_t   id;

    /* These names are printed at column 11, so a name and the build number
     * beside it must fit in the 21 columns left. The longest of ours is 15,
     * plus a space and the five of "00.0E" — exactly 21. */

    /* Ours is answered by the magic block, which costs one 20-byte read and,
     * unlike a CRC, still says yes after the stub has been rebuilt. */
    id = rom_identity(MF_ROM, build_str);
    if (id == ID_UNREADABLE)
        return "unreadable";
    if (id == ID_UART)
        return "dezogif_ng UART";
    if (id == ID_WIFI)
        return "dezogif_ng WiFi";
    if (id == ID_OURS_OTHER)
        return "dezogif_ng ROM";

    /* Not ours. The stock ROM has no magic of its own, so the only handle on
     * it is the checksum of the copy we captured — which is sound here,
     * because that file and its .sum were written together by this program
     * and neither is ever rebuilt. */
    if (rom_crc(MF_ROM, &cur) != 0)
        return "unreadable";
    if (read_sum(ORIG_SUM, &other) == 0 && other == cur)
        return "official MF ROM";
    return "unrecognised";
}

/* ------------------------------------------------------------------ */
/* menu                                                               */
/* ------------------------------------------------------------------ */

/* Printed at column 2, so 30 columns is the limit. The two of ours name their
 * transport rather than their build: which physical link the debugger speaks
 * over is the only thing a user chooses between here. */
static const char *const menu_text[MENU_ITEMS] = {
    "Official Multiface NMI ROM",
    "dezogif_ng WiFi (ESP-01)",
    "dezogif_ng UART (joy port)",
    "Exit without changes",
};

/* Exit must stay the last entry, and this is not tidiness. main()'s dispatch
 * ends in an `else` that installs the UART ROM, so an entry added *after*
 * MENU_EXIT would be selectable, unnamed, and would quietly install something
 * the user did not choose. An extra string is already a compile error (the
 * array's bound is MENU_ITEMS); this catches the other direction. */
typedef char exit_is_the_last_menu_entry[(MENU_EXIT == MENU_ITEMS - 1) ? 1 : -1];

static void draw_chrome(void)
{
    print_at(0, ROW_TITLE, " mfselect            dezogif_ng ");
    attr_run(0, ROW_TITLE, 32, ATTR_BAR);
    print_at(0, ROW_FOOT,  " Up/Down to move   ENTER to run ");
    attr_run(0, ROW_FOOT, 32, ATTR_BAR);

    /* Static, and nothing clears this row: cls() runs once at start, and the
     * only later erasures are the status row, the menu rows and the message
     * area. Drawing it here keeps it out of the menu redraw loop. */
    print_at(1, ROW_PROMPT, "Select ROM to install:");
}

static void draw_status(void)
{
    clear_row(ROW_STATUS);
    /* Column 0, as the line that replaces it — see main(). A one-column jog
     * between the two would read as a glitch on the same row. */
    print_at(0, ROW_STATUS, "Reading installed ROM...");
}

static void draw_menu(uint8_t sel)
{
    uint8_t i;

    for (i = 0; i < MENU_ITEMS; i++) {
        clear_row(ROW_MENU + i);
        print_at(2, ROW_MENU + i, menu_text[i]);
        attr_run(0, ROW_MENU + i, 32, (i == sel) ? ATTR_BAR : ATTR_BODY);
    }
}

/* Up/Down/ENTER, as the NextZXOS browser does it. */
static uint8_t menu_select(uint8_t sel)
{
    uint8_t k;

    for (;;) {
        draw_menu(sel);
        in_wait_nokey();
        do {
            k = in_inkey();
        } while (k != 10 && k != 11 && k != 13);

        if (k == 13)
            return sel;
        if (k == 11)                                  /* up */
            sel = sel ? (uint8_t)(sel - 1) : (uint8_t)(MENU_ITEMS - 1);
        else                                          /* down */
            sel = (uint8_t)((sel + 1) % MENU_ITEMS);
    }
}

/* ------------------------------------------------------------------ */

void main(void)
{
    uint8_t sel = 0;

    zx_border(0);
    cls();
    draw_chrome();

    msg_reset();
    bootstrap();

    for (;;) {
        const char *name;

        draw_status();
        draw_menu(sel);
        msg_reset();

        /* Read the name BEFORE overwriting the status row: the CRC behind it
         * takes seconds, and clearing the progress line first would leave the
         * screen looking hung for the whole of it. */
        name = installed_name();
        clear_row(ROW_STATUS);
        print_at(0, ROW_STATUS, "Installed: ");
        print_at(11, ROW_STATUS, name);

        /* The build number, when there is one, so a user can say which build
         * is on the card without computing a checksum — which is the reason
         * it is in the ROM at all.
         *
         * THIS ROW STARTS AT COLUMN 0, and it used to start at 1. The dotted
         * build number is one character wider than the bare digits it replaced
         * (issue #20), and "Installed: dezogif_ng UART 00.0E" is 32 characters
         * — the whole row. print_at() clips at column 32, so the column left
         * over from before would have silently eaten the last digit rather
         * than complaining. Column 0 is also where the title and footer bars
         * begin, so the widest rows on the screen now all start together. */
        if (build_str[0]) {
            print_at(11 + (uint8_t)strlen(name) + 1, ROW_STATUS, build_str);
        }

        sel = menu_select(sel);

        if (sel == MENU_EXIT)
            break;
        if (sel == MENU_OFFICIAL)
            install(ORIG_ROM, ORIG_SUM, "Installing official MF ROM");
        else if (sel == MENU_WIFI)
            install(WIFI_ROM, WIFI_SUM, "Installing dezogif_ng WiFi");
        else
            install(UART_ROM, UART_SUM, "Installing dezogif_ng UART");

        wait_key();
    }

    cls();
}
