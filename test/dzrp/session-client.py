#!/usr/bin/env python3
"""Drive the stub to each of the session states, for bench N1-N5.

    session-client.py silent        open TCP, say nothing at all
    session-client.py init          CMD_INIT, and stop there
    session-client.py close         CMD_INIT, CMD_CLOSE, then one more command
    session-client.py vanish        CMD_INIT, then drop the socket — no CMD_CLOSE
    session-client.py vanish-idle   the same, but only after the stub has gone
                                    back to its idle loop
    session-client.py vanish-slot   the same again, with MMU slot 2 retargeted
                                    first, and the bank checked afterwards
    session-client.py close-slot    MMU slot 2 retargeted, then CMD_CLOSE, whose
                                    show_ui must not draw through that window

Bench test/run-client-status.sh reads the verdict off the Next's own screen
(issue #14), so all this has to do is put the stub in a known state and then be
quiet, leaving the screen alone. It prints

    EXCHANGE_DONE <epoch>

the moment the state is set and holds its connection open afterwards, until it
is killed or HOLD seconds pass. The bench uses that timestamp to check that the
screenshot was taken AFTER the state was set — otherwise a capture that merely
came too early would be reported as the screen saying the wrong thing, which is
a check failing for a reason outside its own subject.

WHY `silent` IS A CHECK AND NOT A BASELINE. The line reports a DZRP SESSION, and
a TCP connection is not one: a client can be connected and never speak. A stub
that lit the line on a socket rather than on CMD_INIT would be claiming more
than it can see, which is exactly what issue #14's acceptance criterion forbids.
This phase opens a connection, sends nothing, and requires the screen to go on
saying so — while the connection is still open, which is why it holds.

WHY `close` SENDS A THIRD COMMAND, and it is an ordering proof rather than
belt-and-braces. cmd_init calls show_ui BEFORE writing its response, so holding
its answer proves the repaint already happened. cmd_close is the other way
round: it answers FIRST and reaches show_ui through `jp main` afterwards, so its
response proves nothing about the screen. The stub serves commands again only
once it is back in main_loop — which is past show_ui — so a reply to a further
command is what makes the repaint an observed fact instead of an assumption.
CMD_LOOPBACK is the one used because it changes no state and repaints nothing:
it ends `jp main_loop.continue`.

WHY THE FIRST THREE PHASES NEVER CLOSE THE SOCKET, and the last three exist to.
Closing it makes the module emit `<id>,CLOSED`, and until issue #23 the stub did
not look at that line at all — so N1-N3 hold their connections open precisely to
keep an event they could not see out of the runs that are not about it. The
phases below are the other half: they drop the socket WITHOUT sending CMD_CLOSE,
which is what a crashed client, a suspended laptop or a dropped link produce, and
the screen must stop claiming the session that ended.

`vanish` AND `vanish-idle` DIFFER ONLY IN WHERE THE STUB IS STANDING WHEN IT
HAPPENS, and that is the whole reason there are two. `vanish` drops the socket at
once, so the stub is inside cmd_loop's transport_wait_rx and the scan that meets
the `<id>,CLOSED` then finds no header, times out and reaches drain_main — whose
show_ui is what redraws the row. `vanish-idle` waits first, long enough for that
wait's own bound to expire into main_loop, so the line arrives at the idle poll
instead, where nothing times out and nothing reports: there the ONLY thing that
can redraw the row is esp_refresh_client_line. The bench tells the two apart by
the stub's error area — see run-client-status.sh.

`vanish-slot` IS NOT ABOUT THE SCREEN AT ALL. It is the memory-safety check for
that same redraw, and its verdict comes back over the socket rather than off a
picture. `CMD_SET_SLOT 2,<bank>` retargets the debugger's OWN MMU slot 2, so
address 0x4000 stops being the display file and becomes somebody else's memory;
a redraw that went ahead anyway would XOR the session line into that bank, where
nothing would ever undo it — no per-bank backup exists, only slot_backup.slot0
and .slot7. So this phase parks a known 32-byte pattern where the row's first
scanline lands, vanishes exactly as `vanish-idle` does, and reads it back.

THE THREE OUTCOMES ARE ALL DISTINGUISHABLE, which is what makes it worth
running:

    intact          nothing wrote through that window — the guard held
    changed         the stub XORed the line into the bank — the defect itself
    all zeros       show_ui's MEMCLEAR ran, so this run reached drain_main and
                    never tested its subject: a PRECONDITION failure, not a pass

The third is why the pattern is not all zeros, and why the second connection
sends no CMD_INIT: cmd_init writes bank 10 back into slot 2, which would hide
the very thing being read. (This said "contains no zero byte" until 2026-08-10
and that is false — see PROBE below, eight of its 2048 bytes are 0x00. And the
third outcome cannot in fact arise; see the module docstring's `close-slot`
section. Neither changes what this check does.)

AND IT COVERS THE WHOLE 2 KB THE ROW CAN REACH, because a narrower probe was
measured to be blind — see PROBE below. That mistake is the reason this check
was watched to go red before it was believed.

`close-slot` IS THE SAME QUESTION ASKED OF show_ui ITSELF — issue #28, and the
larger of the two hazards by two orders of magnitude. esp_refresh_client_line
draws one row, measured at 96 bytes; show_ui opens with
`MEMCLEAR SCREEN, SCREEN_SIZE`, so it zeroes 6144 bytes and then fills 1248 more
with attributes before it prints a character. Through a retargeted slot 2 that
is 0x4000-0x5CDF — 7392 bytes — of somebody else's bank, gone. (The issue says
8 KB; that is the size of the SLOT, not of the write.)

ITS TRIGGER IS CMD_CLOSE AND NOT THE "B" KEY, which is the trigger issue #28
names. Same routine either way — `check_key_border` reaches main_redraw and so
does `jp main` from cmd_close, and show_ui is below both — but the trigger a
client can send itself needs no margin at all, where an injected keypress is
scheduled in emulated FRAMES against a client counting wall clock. That mismatch
is the one W6 was caught by, and N5's own IDLE_WAIT is documented as a margin
rather than a proof. Here there is nothing to get wrong: the commands are
ordered by the socket.

AND IT SAYS SOMETHING THE "B" KEY CANNOT. Issue #28 records that the defect
"needs a client that uses CMD_SET_SLOT on slot 2 AND someone pressing B at the
machine". CMD_CLOSE is what DeZog's CSpectRemote.disconnect() sends on every
Shift+F5, so no one need be at the machine at all — and drain_main reaches the
same show_ui on any RX timeout, which is the wording N6's third outcome already
uses ("tested nothing") for a state it describes but CANNOT REACH: WIPED needs
`after == bytes(2048)` exactly, and any run that gets to show_ui also draws
glyphs into character rows 8-15, which is precisely 0x4800-0x4FFF. So N6 would
report CORRUPT and blame the refresh for show_ui's damage.

THE PRECONDITION IS THE ONE `close` ALREADY ARGUES FOR, reused rather than
invented: cmd_close answers BEFORE it reaches show_ui, so its own response
proves nothing. A reply to a FURTHER command does, because the stub only serves
again from main_loop, which is below main_redraw's show_ui.

THE READ-BACK DELIBERATELY DOES NOT RE-ISSUE CMD_SET_SLOT, and that is what
makes this cover the second half of the fix as well. A show_ui that forced the
window and then forgot to put it back would leave 0x4000 addressing the screen;
the probe read would come back as screen data and the check would be right to
fail. Slot 2 is read out of CMD_GET_REGISTERS first so the two faults are told
apart instead of being reported as one.
"""
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from dzrp import (CMD_CLOSE, CMD_GET_REGISTERS, CMD_INIT, CMD_LOOPBACK,  # noqa: E402
                  CMD_READ_MEM, CMD_SET_SLOT, CMD_WRITE_MEM,
                  Dzrp, init_payload, open_remote)

HOST = os.environ.get("DZRP_HOST", "127.0.0.1")
PORT = int(os.environ.get("DZRP_PORT", "11000"))
TIMEOUT = float(os.environ.get("DZRP_TIMEOUT", "25"))

# A backstop, not a schedule: the bench kills this process once it has the
# screenshot it was waiting for.
HOLD = float(os.environ.get("HOLD", "120"))

# How long `vanish-idle` stays quiet before dropping its socket. It has to
# outlast the stub's own TRANSPORT_WAIT_RX_SECONDS (5, constants.asm), which is
# five EMULATED seconds — and headless jnext advances emulated time roughly 5.5x
# faster than the wall clock, so one wall second is already more than the bound.
# Four is a margin, not a measurement, and it is cheap: the screenshot is
# scheduled thousands of frames later.
IDLE_WAIT = float(os.environ.get("IDLE_WAIT", "4"))

# How long `vanish-slot` leaves the stub alone after dropping its socket, so the
# idle poll has met the `<id>,CLOSED` and done whatever it is going to do before
# anything looks. Same currency as IDLE_WAIT and the same argument: emulated time
# runs faster than the wall clock here, so this is generous.
SETTLE_AFTER = float(os.environ.get("SETTLE_AFTER", "3"))

# The bank `vanish-slot` parks under 0x4000, and the probe it writes there.
#
# NOT one of the stub's own (TMP_BANK 92, TMP_BANKB 93, MAIN_BANK 94,
# LOOPBACK_BANK 91, ROM_BANK 0xFF) and not one cmd_init maps (10, 11, 4, 5, 0, 1).
#
# NOT ALL ZEROS, because all-zeros is a distinct verdict: it means show_ui's
# MEMCLEAR reached this bank and the run took the path this check is not about.
# THIS COMMENT SAID "NO ZERO BYTE" AND THAT IS FALSE — corrected 2026-08-10,
# issue #28. It was true when the probe was 32 bytes and was lost silently when
# it was widened to 2048: (i*7+1)&0xFF is zero at i = 73, 329, 585, 841, 1097,
# 1353, 1609 and 1865, so EIGHT of the 2048 bytes are 0x00. That is the whole of
# why both reds this pattern has produced report 2040 changed and not 2048. The
# conclusion survives — the outcome test is `after == bytes(2048)`, and PROBE is
# not all zeros — but the reason given for it was wrong.
#
# IT COVERS 0x4800-0x4FFF, WHICH IS EVERY BYTE A REDRAW OF ROW 8 CAN REACH, and
# the first version covered 32 of them and was BLIND. Character row 8 starts at
# 0x4800 and text.asm's print_char walks down with PIXELDN, so the row's eight
# scanlines are at 0x4800, 0x4900 ... 0x4F00 — 32 bytes of each. The probe was
# 32 bytes at 0x4800, i.e. scanline 0 alone, and MEASURED against the 48.rom font
# the stub prints with: XORing "Session opened - CMD_INIT" off and
# "Session lost - client gone" on differs in 12-17 columns on scanlines 1-6, in 3
# on scanline 7 — and in NONE on scanline 0, because the top row of essentially
# every ZX glyph is blank. So the check went green against a ROM that really was
# corrupting the bank. Taking the whole 2 KB needs no argument about which
# scanline is safe to sample, and survives any future rewording of those strings.
SLOT2_BANK = int(os.environ.get("SLOT2_BANK", "60"))
PROBE_ADDR = 0x4800
PROBE = bytes((i * 7 + 1) & 0xFF for i in range(2048))


def done():
    print("EXCHANGE_DONE %.3f" % time.time())
    sys.stdout.flush()
    time.sleep(HOLD)
    return 0


# The bank `vanish-slot1` parks at 0x2000-0x3FFF, chosen on SLOT2_BANK's rules —
# not one of the stub's own and not one cmd_init maps.
SLOT1_BANK = int(os.environ.get("SLOT1_BANK", "62"))

# CMD_GET_REGISTERS's payload is 37 bytes: 14 register words (28), a slot count
# (1), then the eight slot values. So slot n is byte 29+n. Slots 0-6 are read
# LIVE from the MMU (commands.asm's `.slot_loop` over REG_MMU) — which is exactly
# why this check works: there is no shadow copy to hide a clobbered register.
SLOTS_AT = 29


def slot_of(body, slot):
    if len(body) != 37:
        raise SystemExit("PRECONDITION CMD_GET_REGISTERS answered %d payload bytes, "
                         "expected 37" % len(body))
    return body[SLOTS_AT + slot]


def slot1_of(body):
    return slot_of(body, 1)


PHASES = ("silent", "init", "close", "vanish", "vanish-idle", "vanish-slot",
          "vanish-slot1", "close-slot")


def _w(v):
    return v.to_bytes(2, "little")


def read_probe(conv):
    """The 32 bytes at PROBE_ADDR, through whatever slot 2 currently holds."""
    return conv.command(CMD_READ_MEM, b"\x00" + _w(PROBE_ADDR) + _w(len(PROBE)))


def vanish_slot1(t, d):
    """N7: retarget slot 1, vanish, and require the MMU register to be given back.

    THE INVARIANT ISSUE #31 INTRODUCED. The glyphs are no longer copied into
    MAIN_BANK; text.font_map pages ROM into slot 1 to read them and font_unmap
    puts back what was there. Slot 1 has no backup anywhere — slot_backup holds
    slots 0 and 7 only — so a paint that forgot to restore it would both report
    the wrong bank to DeZog and hand the wrong bank to the debuggee on its next
    CMD_CONTINUE. That is issue #26 one slot along, and it would be SILENT.

    It is judged over the socket rather than off the screen because
    cmd_get_registers reads slots 0-6 straight out of the MMU, so the clobber is
    directly readable. The painter under test is the AUTONOMOUS one —
    esp_refresh_client_line, from main_loop's poll — which is the harder of the
    two: show_ui is reached from cmd_init, which resets slot 1 itself and would
    mask the answer.

    A failure reads 255 (ROM_BANK), which is what font_map leaves behind.
    """
    d.command(CMD_SET_SLOT, bytes([1, SLOT1_BANK]))

    before = slot1_of(d.command(CMD_GET_REGISTERS))
    if before != SLOT1_BANK:
        print("PRECONDITION CMD_SET_SLOT did not take: slot 1 reads %d, wanted %d"
              % (before, SLOT1_BANK), file=sys.stderr)
        return 1
    print("armed: slot 1 = %d" % before)
    sys.stdout.flush()

    print("staying quiet for %.1fs, so the stub's cmd_loop wait expires" % IDLE_WAIT)
    sys.stdout.flush()
    time.sleep(IDLE_WAIT)
    t.close()
    print("socket dropped with no CMD_CLOSE")
    sys.stdout.flush()
    time.sleep(SETTLE_AFTER)

    # A NEW CONNECTION AND NO CMD_INIT, for vanish_slot's reason: cmd_init writes
    # ROM_BANK into slot 1 itself, which is the very value a failure produces.
    t2 = open_remote(f"tcp:{HOST}:{PORT}", timeout=TIMEOUT)
    d2 = Dzrp(t2, start_byte=None, base_timeout=TIMEOUT)
    after = slot1_of(d2.command(CMD_GET_REGISTERS))

    if after == SLOT1_BANK:
        print("SLOT1 OK slot 1 still reads %d after the redraw" % after)
    else:
        print("SLOT1 CLOBBERED slot 1 reads %d, was %d" % (after, SLOT1_BANK))
    return done()


def vanish_slot(t, d):
    """N6: retarget slot 2, vanish, and require the bank to be untouched."""
    # Retarget slot 2 and park the probe in the retargeted bank. cmd_set_slot
    # writes the MMU register directly for every slot but 7, so from here on
    # 0x4000 is bank SLOT2_BANK for the debugger itself as well as for us.
    d.command(CMD_SET_SLOT, bytes([2, SLOT2_BANK]))
    d.command(CMD_WRITE_MEM, b"\x00" + _w(PROBE_ADDR) + PROBE)

    # The precondition, asserted rather than assumed: without this a bank that
    # was never writable would give a "corrupt" verdict that means nothing.
    before = read_probe(d)
    if before != PROBE:
        print("PRECONDITION the probe did not survive its own write to bank %d: %s"
              % (SLOT2_BANK, before.hex()), file=sys.stderr)
        return 1
    print("bank %d holds the probe at 0x%04X" % (SLOT2_BANK, PROBE_ADDR))
    sys.stdout.flush()

    # Vanish from main_loop, exactly as vanish-idle does — the path on which the
    # idle poll, and nothing else, meets the <id>,CLOSED.
    print("staying quiet for %.1fs, so the stub's cmd_loop wait expires" % IDLE_WAIT)
    sys.stdout.flush()
    time.sleep(IDLE_WAIT)
    t.close()
    print("socket dropped with no CMD_CLOSE")
    sys.stdout.flush()
    time.sleep(SETTLE_AFTER)

    # A NEW CONNECTION AND NO CMD_INIT. cmd_init would write bank 10 back into
    # slot 2 and read the display file instead of the bank under test.
    t2 = open_remote(f"tcp:{HOST}:{PORT}", timeout=TIMEOUT)
    d2 = Dzrp(t2, start_byte=None, base_timeout=TIMEOUT)
    d2.command(CMD_SET_SLOT, bytes([2, SLOT2_BANK]))
    after = read_probe(d2)

    if after == PROBE:
        print("SLOT_PROBE OK bank %d unchanged across %d bytes from 0x%04X"
              % (SLOT2_BANK, len(PROBE), PROBE_ADDR))
    elif after == bytes(len(PROBE)):
        print("SLOT_PROBE WIPED bank %d zeroed: show_ui's MEMCLEAR ran, so this "
              "run reached drain_main and tested nothing" % SLOT2_BANK)
    else:
        # A DIGEST AND NOT A DUMP. 2 KB of hex is 4096 characters in the bench
        # log, which buries every other line of the run; what identifies the
        # fault is how much moved and where it starts.
        changed = sum(1 for a, b in zip(PROBE, after) if a != b)
        first = next(i for i, (a, b) in enumerate(zip(PROBE, after)) if a != b)
        print("SLOT_PROBE CORRUPT bank %d: %d of %d bytes changed, first at 0x%04X"
              % (SLOT2_BANK, changed, len(PROBE), PROBE_ADDR + first))
    return done()


def close_slot(t, d):
    """N8: show_ui must not clear and redraw through a retargeted slot 2.

    Issue #28. Everything interesting is in the module docstring; what follows
    is only the order of events.
    """
    d.command(CMD_SET_SLOT, bytes([2, SLOT2_BANK]))
    d.command(CMD_WRITE_MEM, b"\x00" + _w(PROBE_ADDR) + PROBE)

    # Asserted rather than assumed, as vanish-slot does: a bank that never took
    # the write would give a "corrupt" verdict that means nothing.
    before = read_probe(d)
    if before != PROBE:
        print("PRECONDITION the probe did not survive its own write to bank %d: %s"
              % (SLOT2_BANK, before.hex()), file=sys.stderr)
        return 1
    print("bank %d holds the probe at 0x%04X" % (SLOT2_BANK, PROBE_ADDR))
    sys.stdout.flush()

    body = d.command(CMD_CLOSE)
    print("CMD_CLOSE answered: %s" % body.hex())
    sys.stdout.flush()

    # THE PRECONDITION. cmd_close writes its response and only then reaches
    # show_ui through `jp main`, so the response above proves nothing at all.
    # The stub serves again only from main_loop, which is below main_redraw's
    # show_ui, so an answer here is what makes the repaint an observed fact.
    # CMD_LOOPBACK because it changes no state and repaints nothing.
    echo = b"\x1c\x1c\x1c\x1c"
    body = d.command(CMD_LOOPBACK, echo)
    if body != echo:
        print("SHOW_UI UNRUN no reply after CMD_CLOSE (got %s)" % body.hex())
        return done()
    print("CMD_LOOPBACK after CMD_CLOSE answered, so show_ui has run")
    sys.stdout.flush()

    # Slot 2 FIRST, because if the window was left forced the probe read below
    # would be reading the display file and its verdict would name the wrong
    # fault. NO CMD_SET_SLOT here: putting the bank back would hide exactly that.
    slot2 = slot_of(d.command(CMD_GET_REGISTERS), 2)
    if slot2 != SLOT2_BANK:
        print("SHOW_UI LEAKED slot 2 reads %d after the redraw, was %d"
              % (slot2, SLOT2_BANK))
        return done()

    after = read_probe(d)
    if after == PROBE:
        print("SHOW_UI OK bank %d unchanged across %d bytes from 0x%04X"
              % (SLOT2_BANK, len(PROBE), PROBE_ADDR))
    else:
        # A digest and not a dump, for vanish_slot's reason: 2 KB of hex buries
        # every other line of the run.
        #
        # THE "zeroed" ARM IS UNREACHABLE TODAY and is kept anyway. Character
        # rows 8-15 land in exactly this probe's 0x4800-0x4FFF, so any run that
        # reaches show_ui draws glyphs here and the region can never come back
        # all-zero — both reds this check has produced say "overwritten". What
        # it would catch is a partial fix that cleared through the window and
        # then failed to draw, which is cheap to keep and not worth asserting.
        changed = sum(1 for a, b in zip(PROBE, after) if a != b)
        first = next(i for i, (a, b) in enumerate(zip(PROBE, after)) if a != b)
        how = "zeroed" if after == bytes(len(PROBE)) else "overwritten"
        print("SHOW_UI CORRUPT bank %d %s: %d of %d bytes changed, first at 0x%04X"
              % (SLOT2_BANK, how, changed, len(PROBE), PROBE_ADDR + first))
    return done()


def main(argv):
    if len(argv) != 2 or argv[1] not in PHASES:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    phase = argv[1]

    t = open_remote(f"tcp:{HOST}:{PORT}", timeout=TIMEOUT)
    # The preamble is a serial-only extension and must be absent here; `None`
    # asserts that rather than autodetecting around it.
    d = Dzrp(t, start_byte=None, base_timeout=TIMEOUT)

    if phase == "silent":
        print("connected, and saying nothing")
        return done()

    body = d.command(CMD_INIT, init_payload())
    print("CMD_INIT answered: %s" % body.hex())

    if phase == "init":
        # Deliberately no close, and the socket stays up: this is a live
        # session, which is the only state ATTACHED is entitled to describe.
        return done()

    if phase == "vanish-slot":
        return vanish_slot(t, d)

    if phase == "vanish-slot1":
        return vanish_slot1(t, d)

    if phase == "close-slot":
        return close_slot(t, d)

    if phase in ("vanish", "vanish-idle"):
        if phase == "vanish-idle":
            print("staying quiet for %.1fs, so the stub's cmd_loop wait expires"
                  % IDLE_WAIT)
            sys.stdout.flush()
            time.sleep(IDLE_WAIT)
        # NO CMD_CLOSE. The socket simply goes, which is all a crashed client,
        # a suspended laptop or a dropped link leave behind — and the only thing
        # the stub gets is the module's own `<id>,CLOSED` line.
        t.close()
        print("socket dropped with no CMD_CLOSE")
        # Nothing is held afterwards: there is no connection left to hold, and
        # the screen's verdict has to be reachable with the client gone, which
        # is the whole point of the check.
        return done()

    body = d.command(CMD_CLOSE)
    print("CMD_CLOSE answered: %s" % body.hex())

    echo = b"\x14\x14\x14\x14"
    body = d.command(CMD_LOOPBACK, echo)
    if body != echo:
        print("FAIL the stub did not serve a command after CMD_CLOSE "
              "(got %s), so the repaint cannot be shown to have happened"
              % body.hex(), file=sys.stderr)
        return 1
    print("CMD_LOOPBACK after CMD_CLOSE answered, so show_ui has run")
    return done()


if __name__ == "__main__":
    sys.exit(main(sys.argv))
