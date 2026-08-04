/*
 * mfselect — switch the Next's Multiface ROM between the stock one and
 * dezogif_ng's, from the machine itself.
 *
 * Deployed as /mfselect/mfselect.nex and run under NextZXOS, which is assumed
 * present at all times: every file access here is the esxdos API, and there is
 * no fallback if it is absent. Loading this NEX without NextZXOS underneath
 * hangs on the first RST $08 — see doc/MFSELECT.md.
 *
 * Files it expects beside itself in /mfselect/:
 *
 *   dezogif.rom  dezogif.sum   our Multiface ROM and its checksum, both put
 *                              there when mfselect is installed
 *   original.rom original.sum  the stock ROM, captured on first run
 *
 * The checksum is CRC-16/CCITT (tools/romsum.py computes the same value on the
 * host, and the bench checks that the two agree). It does three jobs: identify
 * which ROM is installed, detect a truncated or corrupt copy, and guard the
 * first-run capture described below.
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

#define MF_ROM      "/machines/next/enNextMf.rom"
#define ORIG_ROM    "/mfselect/original.rom"
#define ORIG_SUM    "/mfselect/original.sum"
#define DEZ_ROM     "/mfselect/dezogif.rom"
#define DEZ_SUM     "/mfselect/dezogif.sum"

/* tbblue.fw loads exactly this many bytes, so anything else at the official
 * path is wrong and is refused rather than copied around. */
#define ROM_SIZE    8192U
#define CHUNK       512U

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

/* Screen layout. */
#define ROW_TITLE   0
#define ROW_STATUS  2
#define ROW_MENU    5
#define MENU_ITEMS  3
#define ROW_MSG     10
#define ROW_MSG_END 21
#define ROW_FOOT    23

/* One shared I/O buffer. 512 bytes rather than the whole 8K so every buffer
 * stays well inside the 0x4000-0xBFE0 window the esxdos API requires. */
static uint8_t buf[CHUNK];

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

    msg("Copying...");
    if (copy_rom(rom, MF_ROM) != 0)
        return;

    msg("Verifying...");
    if (rom_crc(MF_ROM, &got) != 0)
        return;
    if (got != want) {
        msg_attr("VERIFY FAILED", ATTR_ERR);
        msg_hex("  got  ", got);
        msg_hex("  want ", want);
        msg_attr("the installed ROM is BAD", ATTR_ERR);
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

/* First run: capture the stock ROM, with the guard described at the top.
 * Returns after leaving its report on screen. */
static void bootstrap(void)
{
    struct esx_stat es;
    uint16_t installed, ours;
    uint8_t  k;

    if (esx_f_stat(ORIG_ROM, &es) == 0)
        return;                       /* already captured */

    msg_reset();
    msg("No original ROM backup yet.");
    msg("Checking installed ROM...");

    if (rom_crc(MF_ROM, &installed) != 0) {
        msg_attr("no backup made", ATTR_ERR);
        wait_key();
        return;
    }

    /* Our own checksum comes from the .sum shipped beside our ROM, not a
     * constant compiled in here — so rebuilding the stub does not silently
     * invalidate the guard. No .sum means the guard cannot run at all, and
     * capturing blind is precisely the mistake it exists to prevent. */
    if (read_sum(DEZ_SUM, &ours) != 0) {
        msg_attr("dezogif.sum is missing, so", ATTR_ERR);
        msg("the installed ROM cannot be");
        msg("checked against ours.");
        msg("Refusing to make a backup.");
        wait_key();
        return;
    }

    if (installed == ours) {
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

    do {
        k = in_inkey();
    } while (k != 'y' && k != 'Y' && k != 'n' && k != 'N');

    if (k == 'n' || k == 'N') {
        msg("No backup made.");
        wait_key();
        return;
    }

    msg("Saving...");
    if (copy_rom(MF_ROM, ORIG_ROM) != 0) {
        msg_attr("backup failed", ATTR_ERR);
        wait_key();
        return;
    }
    if (rom_crc(ORIG_ROM, &ours) != 0 || ours != installed) {
        msg_attr("backup verify FAILED;", ATTR_ERR);
        msg("treat it as unusable");
        wait_key();
        return;
    }
    if (write_sum(ORIG_SUM, installed) != 0) {
        msg_attr("could not write the sum", ATTR_ERR);
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

    /* These names are printed at column 12, so they must fit in 20 columns. */
    if (rom_crc(MF_ROM, &cur) != 0)
        return "unreadable";
    if (read_sum(DEZ_SUM, &other) == 0 && other == cur)
        return "dezogif_ng ROM";
    if (read_sum(ORIG_SUM, &other) == 0 && other == cur)
        return "official MF ROM";
    return "unrecognised";
}

/* ------------------------------------------------------------------ */
/* menu                                                               */
/* ------------------------------------------------------------------ */

static const char *const menu_text[MENU_ITEMS] = {
    "Official Multiface NMI ROM",
    "dezogif_ng DZRP NMI ROM",
    "Exit without changes",
};

static void draw_chrome(void)
{
    print_at(0, ROW_TITLE, " mfselect            dezogif_ng ");
    attr_run(0, ROW_TITLE, 32, ATTR_BAR);
    print_at(0, ROW_FOOT,  " Up/Down to move   ENTER to run ");
    attr_run(0, ROW_FOOT, 32, ATTR_BAR);
}

static void draw_status(void)
{
    clear_row(ROW_STATUS);
    print_at(1, ROW_STATUS, "Reading installed ROM...");
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
        print_at(1, ROW_STATUS, "Installed: ");
        print_at(12, ROW_STATUS, name);

        sel = menu_select(sel);

        if (sel == 2)
            break;
        if (sel == 0)
            install(ORIG_ROM, ORIG_SUM, "Installing official MF ROM");
        else
            install(DEZ_ROM, DEZ_SUM, "Installing dezogif_ng ROM");

        wait_key();
    }

    cls();
}
