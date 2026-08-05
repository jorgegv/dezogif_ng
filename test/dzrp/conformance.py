#!/usr/bin/env python3
"""End-to-end DZRP conformance checks against a remote given as a parameter.

    python3 test/dzrp/conformance.py --remote tcp:127.0.0.1:11000
    python3 test/dzrp/conformance.py --remote serial:/dev/ttyUSB0:921600

Run by `make test-dzrp REMOTE=...`. Issue #2.

WHY THIS EXISTS. Nothing else in this repository sends a DZRP command and
checks the reply: `make test` judges screenshots, `make test-mfselect` judges
files on an SD image, and the Z80 unit tests need VS Code. The deliverable of
this project is a protocol implementation, and the protocol had no test.

WHAT IT DELIBERATELY DOES NOT TEST. DeZog owns instruction-length calculation,
the DECISION of where the temporary breakpoints used to step off one belong,
and breakpoint-condition evaluation. Asserting any of those against the remote
would encode the wrong contract, and push whoever tried to make it pass into
building the very thing that fights DeZog at runtime. This suite behaves the
way DeZog behaves.

It does NOT mean the remote keeps no state: the stub necessarily stores the
opcode an RST 0 replaced, because it is the party that patches memory and so
the only one that can un-patch it. Substitution bookkeeping is the remote's;
the decisions are DeZog's.

A PARTIAL REMOTE IS LEGITIMATE. DZRP has 29 commands and remotes implement
different subsets — CSpect's DeZog plugin, for one, does not implement
CMD_LOOPBACK and closes the connection on it. So an unimplemented command is
reported as UNSUPPORTED, not failed, unless it is named in --require. Each
check therefore runs on its own connection: one refused command must not take
the rest of the suite down with it.
"""

import argparse
import os
import struct
import time
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import dzrp  # noqa: E402

PASS, FAIL, UNSUP = "PASS", "FAIL", "UNSUP"

# --------------------------------------------------------------------------
# Progress and colour
#
# A check can take 25 seconds (C12 waits out a timeout; C5 sweeps to 4096
# bytes), so a suite that prints nothing until it ends looks hung. Each check
# announces itself BEFORE it runs and its verdict lands when it finishes.
#
# THE ANNOUNCEMENT GOES TO STDERR, DELIBERATELY. stdout carries the result
# lines, and those are parsed — `hardware-check.py`'s classify() matches lines
# beginning "FAIL " and takes the check code from field 2. Interleaving
# progress chatter into that stream would be inviting the same class of
# breakage the length-convention bug came from. stderr shows up next to it on a
# terminal and stays out of the way of anything reading the results.
#
# COLOUR IS OFF WHEN STDOUT IS NOT A TTY, for the same reason: escape codes in
# front of "FAIL" would stop it starting with "FAIL". `hardware-check.py` runs
# this through a pipe and sets FORCE_COLOR when its own output is a terminal,
# and strips the codes before parsing — so the user still gets colour through
# the hardware bench without the parser ever seeing it.
# --------------------------------------------------------------------------

def _use_colour():
    if os.environ.get("NO_COLOR"):
        return False
    if os.environ.get("FORCE_COLOR"):
        return True
    return sys.stdout.isatty()


COLOUR = _use_colour()

# Whether to draw the in-progress line at all.
#
# ONLY ON A TERMINAL, and the reason is not cosmetic: the verdict overwrites the
# progress line with a carriage return and an erase-to-end-of-line, which needs
# a console to mean anything. Down a pipe those control characters would land in
# a log or in front of a line something else is parsing, and `hardware-check.py`
# matches result lines beginning "FAIL ".
#
# So a pipe gets one clean result line per check and nothing else. Nothing is
# lost there: `hardware-check.py` streams the child's output line by line, so a
# verdict still appears the moment it lands, which is the same information at
# the same time — just without a spinner in front of it.
PROGRESS = sys.stdout.isatty()
_CODES = {PASS: "\033[1;32m", FAIL: "\033[1;31m", UNSUP: "\033[1;33m"}


def paint(status):
    """The status token, coloured when that is safe."""
    if not COLOUR:
        return "%-5s" % status
    return "%s%-5s\033[0m" % (_CODES.get(status, ""), status)

# Command names, for --require and for reporting.
NAMES = {
    "INIT": dzrp.CMD_INIT,
    "CLOSE": dzrp.CMD_CLOSE,
    "LOOPBACK": dzrp.CMD_LOOPBACK,
    "GET_REGISTERS": dzrp.CMD_GET_REGISTERS,
    "SET_REGISTER": dzrp.CMD_SET_REGISTER,
    "READ_MEM": dzrp.CMD_READ_MEM,
    "WRITE_MEM": dzrp.CMD_WRITE_MEM,
    "CONTINUE": dzrp.CMD_CONTINUE,
    "PAUSE": dzrp.CMD_PAUSE,
    "GET_SPRITES": dzrp.CMD_GET_SPRITES,
    "GET_SPRITE_PATTERNS": dzrp.CMD_GET_SPRITE_PATTERNS,
}

# Set from --remote. The execution-control checks need a SECOND connection to
# ask "is the remote still alive?" after an exchange that produced no answer,
# so that a silent remote and a dead one are reported as the different things
# they are (ERRORS.md: a check that can fail for a reason outside its own
# subject has to say so).
REMOTE_SPEC = None

# Set from --no-continue. See CONTROL, below.
NO_CONTINUE = False


class Unsupported(Exception):
    """The remote does not implement this command."""


class Precondition(Exception):
    """Something this check needs went wrong BEFORE its subject was reached.

    Reported as a failure — nothing was established, so it cannot be a pass —
    but worded so it is not read as evidence about the thing under test.
    """


# CMD_INIT is how every DZRP conversation starts. A remote that cannot answer
# it is broken, not partial, so it is never eligible to be excused as
# UNSUPPORTED however it fails.
ALWAYS_REQUIRED = {"INIT"}


def talk(d, cmd_id, payload=b""):
    """Send a command, mapping only a DELIBERATE refusal onto Unsupported.

    A remote that does not know a command closes the connection — that is what
    CSpect's plugin does, and it is not a protocol violation.

    A TIMEOUT IS NOT THAT. It means the remote is waiting for bytes we did not
    send, which is what a wrong length field looks like from this side, and
    treating it as "unimplemented" is how this suite once reported a completely
    broken handshake as 8 UNSUPPORTED checks and exit 0. Timeouts propagate as
    failures.
    """
    try:
        return d.command(cmd_id, payload)
    except dzrp.DzrpError as e:
        if "closed" in str(e):
            raise Unsupported(str(e))
        raise


# --------------------------------------------------------------------------
# checks — each returns (status, detail) and gets a fresh connection
# --------------------------------------------------------------------------


def chk_init(d):
    """Version negotiation: the first command DeZog itself sends."""
    body = talk(d, dzrp.CMD_INIT, dzrp.init_payload())
    if len(body) < 6:
        return FAIL, "response is %d bytes, too short to decode" % len(body)
    err = body[0]
    ver = "%d.%d.%d" % (body[1], body[2], body[3])
    machine = body[4]
    name = body[5:].split(b"\x00")[0].decode("ascii", "replace")
    if err != 0:
        return FAIL, "error code %d (version %s, %r)" % (err, ver, name)
    return PASS, "DZRP %s, machine %d, %r" % (ver, machine, name)


# A check whose PASS is silence must wait LONGER than a normal command, not
# less. Every other check here treats a timeout as failure, which is the safe
# direction: too short only ever produces a loud false FAIL. This one inverts
# that, so too short produces a SILENT false PASS — a green line asserting
# something never established. Hence a multiple of the caller's own --timeout
# rather than a hardcoded number no caller can raise for a slow link.
SILENCE_FACTOR = 2.0


def chk_length_convention(d):
    """Prove the command length convention by violating it.

    An earlier version just sent a well-formed CMD_INIT and declared victory,
    which asserted nothing chk_init did not already assert — a reviewer called
    it a strictly weaker duplicate, correctly.

    So it now sends CMD_INIT with the WRONG length: payload + 2, the symmetric
    reading. A remote that counts the payload only is left waiting for two
    bytes that never arrive, and must not produce a valid response.

    Silence and refusal are reported as DIFFERENT observations, because they
    are: one means the remote is still waiting mid-frame, the other that it
    rejected the frame outright. Collapsing both into one message would
    overclaim what was seen.
    """
    payload = dzrp.init_payload()
    frame, seq = d.build_command(dzrp.CMD_INIT, payload, length=len(payload) + 2)
    wait = d.base_timeout * SILENCE_FACTOR
    d.send_raw(frame)
    d.t.set_timeout(wait)
    try:
        got_seq, _ = d._read_frame()
    except dzrp.Timeout:
        return PASS, "silent for %.0fs after an over-long length" % wait
    except dzrp.DzrpError as e:
        return PASS, "refused an over-long length outright (%s)" % e
    if got_seq == seq:
        return FAIL, "answered a length that counted seq and cmd too"
    # Something arrived that was neither our response nor silence. Say what it
    # was rather than quietly counting it as proof.
    return FAIL, "expected silence, got a frame with seq %d" % got_seq


def chk_preamble(d, expect):
    """Does the remote prefix frames with 0xA5?

    Not a bug hunt — a capability probe. Upstream extended DZRP by this byte
    for the serial link (doc/legacy/Design.md:30-31): DeZog "will wait on this
    byte before it recognizes messages coming from the Next", because a game
    that grabs the joy port makes the Next emit endless zeroes. DeZog's
    ZxNextSerialRemote strips byte 165; its CSpectRemote does not.

    So the correct answer differs by transport: present in UART mode, absent
    for a socket remote. That is why this reports rather than assumes, and why
    --expect-preamble exists for callers who know which they are talking to.
    """
    talk(d, dzrp.CMD_INIT, dzrp.init_payload())
    seen = d.observed_start_byte
    desc = "0xA5" if seen == dzrp.START_BYTE else "none"
    if expect == "report":
        return PASS, "%s (recorded, not asserted)" % desc
    want = dzrp.START_BYTE if expect == "a5" else None
    if seen == want:
        return PASS, "%s, as expected" % desc
    return FAIL, "expected %s, observed %s" % (expect, desc)


def chk_init_consumes_payload(d):
    """The other half of issue #7, which C2 cannot reach.

    C2 over-declares the length and requires SILENCE, so it proves the remote
    reads at least as far as the length promised. It says nothing about the
    opposite direction: whether the remote stops reading at the end of the
    declared payload and leaves the stream where the next command begins.

    This sends a CMD_INIT whose length is HONEST — it counts every byte sent —
    but whose payload carries four bytes after the name's NUL. A remote that
    frames on the NUL instead of on the length consumes fewer bytes than it was
    given, the four survivors become the head of the next command's header, and
    the session is desynchronised from there on. So the assertion is not on this
    command's answer alone: a SECOND, entirely ordinary CMD_INIT follows on the
    same connection and has to come back carrying its own sequence number.

    It is also the "a well-formed CMD_INIT still works" check issue #7 asks for,
    in the only form that is not a weaker duplicate of C1: C1 already proves a
    minimal frame is answered, and would go on passing for a fix that consumed
    too little.

    Nothing on the wire here is malformed. DZRP frames on the length, and a
    client that declares what it sends is entitled to be understood.
    """
    payload = dzrp.init_payload() + b"\xEE" * 4
    body = talk(d, dzrp.CMD_INIT, payload)
    if len(body) < 6:
        return FAIL, "response is %d bytes, too short to decode" % len(body)
    if body[0] != 0:
        return FAIL, "error code %d on a correct length" % body[0]
    # The real assertion. A remote still standing four bytes back reads this
    # command's header out of the leftovers and answers the wrong thing, or
    # nothing at all — either way not a response carrying this sequence number.
    again = talk(d, dzrp.CMD_INIT, dzrp.init_payload())
    if len(again) < 6 or again[0] != 0:
        return FAIL, ("the command after the padded one came back as %d bytes"
                      % len(again))
    return PASS, "4 bytes past the NUL consumed, next command in sync"


def chk_loopback(d):
    """Framing and byte order, without touching machine state. The project's
    dzrp skill puts this first for our own server: if it does not round-trip,
    nothing above it is worth debugging."""
    talk(d, dzrp.CMD_INIT, dzrp.init_payload())
    data = bytes(range(1, 33))
    got = talk(d, dzrp.CMD_LOOPBACK, data)
    if got != data:
        return FAIL, "sent %d bytes, got %d back and they differ" % (len(data), len(got))
    return PASS, "32 bytes round-tripped unchanged"


# Sizes for the loopback boundary sweep, and every one of them is there for a
# reason:
#
#   0, 1        empty and minimal
#   255, 256    a byte counter's boundary
#   1024        comfortably past any small internal buffer
#   2047..2049  THE TRANSPORT CHUNK BOUNDARY. jnext splits inbound TCP into
#               `+IPD` frames of at most MAX_IPD_CHUNK = 2048 bytes
#               (esp01/include/esp01/esp_at.h:448), so anything larger arrives
#               as SEVERAL headers and the remote has to reassemble across them.
#               Real traffic crosses this routinely — DeZog pushes 8-16 KB per
#               CMD_WRITE_BANK when it loads a .nex — and the first version of
#               this list stopped at 1024, so every payload in the WiFi
#               transport's evidence had arrived in a single frame and its
#               reassembly path was untested.
#   4096        more than two frames, so a remote that handles exactly one split
#               is not mistaken for one that handles any number.
LOOPBACK_SIZES = (0, 1, 255, 256, 1024, 2047, 2048, 2049, 4096)


def chk_loopback_sizes(d):
    """Boundaries, including empty, the transport's frame split, and past it."""
    talk(d, dzrp.CMD_INIT, dzrp.init_payload())
    for n in LOOPBACK_SIZES:
        payload = bytes((i * 7 + n) & 0xFF for i in range(n))
        got = talk(d, dzrp.CMD_LOOPBACK, payload)
        if got != payload:
            return FAIL, "%d bytes came back as %d and differ" % (n, len(got))
    return PASS, "%d sizes from %d to %d bytes, all exact" % (
        len(LOOPBACK_SIZES), LOOPBACK_SIZES[0], LOOPBACK_SIZES[-1])


def chk_sequence(d):
    """A response must carry the sequence number of the command that asked for
    it; the client raises on a mismatch, so five clean exchanges is the
    assertion."""
    for _ in range(5):
        talk(d, dzrp.CMD_INIT, dzrp.init_payload())
    return PASS, "5 consecutive commands, every sequence number echoed"


def chk_registers(d):
    """DeZog indexes into the register block, so a short answer is a hard
    failure rather than a partial one."""
    talk(d, dzrp.CMD_INIT, dzrp.init_payload())
    body = talk(d, dzrp.CMD_GET_REGISTERS)
    if len(body) < 28:
        return FAIL, "register block is only %d bytes" % len(body)
    return PASS, "%d-byte register block" % len(body)


def chk_memory(d):
    """Write then read back, in RAM clear of the ROM and of the debugger's own
    slots 6 and 7."""
    talk(d, dzrp.CMD_INIT, dzrp.init_payload())
    addr, n = 0x8000, 64
    data = bytes((i * 13 + 1) & 0xFF for i in range(n))
    talk(d, dzrp.CMD_WRITE_MEM, b"\x00" + addr.to_bytes(2, "little") + data)
    body = talk(d, dzrp.CMD_READ_MEM,
                b"\x00" + addr.to_bytes(2, "little") + n.to_bytes(2, "little"))
    if body != data:
        return FAIL, "wrote %d bytes at 0x%04X, read %d and they differ" % (n, addr, len(body))
    return PASS, "%d bytes at 0x%04X survived the round trip" % (n, addr)


# ==========================================================================
# Execution control: CMD_CONTINUE, NTF_PAUSE, CMD_PAUSE
#
# THIS IS THE HALF OF ISSUE #2 THAT WAS MISSING, AND IT IS THE ONE THAT
# MATTERS MOST. Everything above judges the debugger while it is STOPPED —
# framing, registers, a memory round trip — none of which needs the debuggee
# to ever run again. Until these checks existed, no evidence anywhere in this
# project showed the stub RESUMING a debuggee: not on hardware, not in the
# emulator. So the exit path and backup.asm's restoration were unexecuted
# code, and so was the AltROM patch, since nothing had ever run an RST 0.
#
# WHAT THEY DO NOT COVER, because the line is fine and easy to lose: the
# stackless-NMI RETURN ADDRESS. C9 sets PC itself with CMD_SET_REGISTER, so
# backup.pc never comes from save_nmi_return_address, which is the routine
# that reads NR 0xC2/0xC3. That runs only on an M1 press taken while
# prgm_state is PRGM_RUNNING — a SECOND NMI, landing after a CMD_CONTINUE —
# and jnext's --delayed-nmi counts emulated frames while this client counts
# wall clock, so scheduling one is a race and not a check. Plan §3.4 calls
# that the half that matters; what C9 establishes is the half it depends on,
# that restore_registers really hands the machine back.
#
# The existing bench check W2 does send a CMD_CONTINUE, and it must NOT be
# read as covering any of this: it resumes zeroed registers on purpose, so the
# machine crashes into a stray RST 0. That is a way of provoking an
# unprompted notification, not a demonstration that the return path works.
#
# HOW THE EVIDENCE IS ARRANGED. A fixture is written into the debuggee's
# memory, the debuggee's PC/SP/BC/IX are pointed at it with CMD_SET_REGISTER,
# and CMD_CONTINUE is sent with a TEMPORARY BREAKPOINT — which is exactly
# what DeZog does on every step, and therefore the mechanism this suite is
# allowed to use. The fixture then leaves three independent traces:
#
#   * a progress marker in memory, which can only be there if the debuggee
#     executed;
#   * the values of BC and IX AS THE DEBUGGEE SAW THEM, stored to memory by
#     its very first two instructions — evidence that restore_registers put
#     them back rather than that the debugger remembers what it was told;
#   * a byte written only by the instruction AFTER the breakpoint, which must
#     stay zero, so "stopped at the breakpoint" is distinguished from "ran
#     past it".
#
# plus the NTF_PAUSE itself and the register block read back afterwards.
#
# WHAT IS DELIBERATELY NOT ASSERTED. DeZog owns instruction lengths, the choice
# of where a temporary breakpoint goes, and condition evaluation. This suite
# therefore names the address itself, in CMD_CONTINUE's payload, exactly as the
# client does. It does NOT expect the remote to be stateless: un-patching an
# RST 0 requires the remote to have kept the byte it replaced.
# ==========================================================================

# All of these sit inside 0x8000-0x9FFF, which CMD_INIT maps to bank 4 (see
# cmd_init's "reset slots to ZX128 default"), clear of the ROM at 0x0000 and
# of the debugger's own slots 6 and 7. One bank, so nothing here depends on
# the SWAP window being right — C8 already covers memory access.
DBG_CODE = 0x8000       # the fixture
DBG_MARK = 0x9800       # its six marker bytes
DBG_STACK = 0x9F00      # the debuggee's SP while it runs
MARK_LEN = 6

# Values CMD_SET_REGISTER puts in before the resume; the fixture stores them
# to memory, so seeing them proves the RESUMED PROGRAM held them.
PRESET_BC = 0xC0DE
PRESET_IX = 0xFACE

# Values the fixture loads while running; seeing them in the register block
# proves the debugger captured the program's state on the way back in.
RUN_HL, RUN_DE, RUN_BC, RUN_A = 0x1234, 0x5678, 0x9ABC, 0x5A

# Written only by the instruction after the breakpoint. Must stay zero.
PAST_TRAP = 0xC3

# CMD_SET_REGISTER numbers, from the DZRP specification's table.
REG_PC, REG_SP, REG_BC, REG_IX = 0, 1, 3, 6


def _w(v):
    return v.to_bytes(2, "little")


# Hand-assembled, one instruction per line, and the trap's address is DERIVED
# from the length of the first half rather than written down twice.
_BEFORE_TRAP = (
    b"\xED\x43" + _w(DBG_MARK + 0) +        # ld (MARK+0),bc  what BC arrived as
    b"\xDD\x22" + _w(DBG_MARK + 2) +        # ld (MARK+2),ix  what IX arrived as
    b"\x21" + _w(RUN_HL) +                  # ld hl,0x1234
    b"\x11" + _w(RUN_DE) +                  # ld de,0x5678
    b"\x01" + _w(RUN_BC) +                  # ld bc,0x9ABC
    b"\x3E" + bytes([RUN_A]) +              # ld a,0x5A
    b"\x32" + _w(DBG_MARK + 4)              # ld (MARK+4),a   "I executed"
)
_AFTER_TRAP = (
    b"\x00" +                               # nop             <-- THE TRAP
    b"\x3E" + bytes([PAST_TRAP]) +          # ld a,0xC3
    b"\x32" + _w(DBG_MARK + 5) +            # ld (MARK+5),a   "I ran PAST it"
    b"\x18\xFE"                             # jr $            park, do not crash
)
DEBUGGEE = _BEFORE_TRAP + _AFTER_TRAP
DBG_TRAP = DBG_CODE + len(_BEFORE_TRAP)

# The order CMD_GET_REGISTERS returns, from the specification.
REGISTER_ORDER = ("PC", "SP", "AF", "BC", "DE", "HL",
                  "IX", "IY", "AF2", "BC2", "DE2", "HL2")


def decode_registers(body):
    """The 12 words, then R, I, IM, reserved. Slots follow and are ignored."""
    if len(body) < 28:
        raise Precondition("the register block is %d bytes, too short to index"
                           % len(body))
    regs = dict(zip(REGISTER_ORDER, struct.unpack("<12H", body[:24])))
    regs["R"], regs["I"], regs["IM"] = body[24], body[25], body[26]
    return regs


def _write_mem(d, addr, data):
    talk(d, dzrp.CMD_WRITE_MEM, b"\x00" + _w(addr) + data)


def _read_mem(d, addr, n):
    return talk(d, dzrp.CMD_READ_MEM, b"\x00" + _w(addr) + _w(n))


def _set_reg(d, num, value):
    talk(d, dzrp.CMD_SET_REGISTER, bytes([num]) + _w(value))


def load_debuggee(d):
    """Put the fixture in memory and aim the debuggee's registers at it.

    The marker area is cleared FIRST and read back, because a stale byte left
    by an earlier check would let "the debuggee ran" pass without it running.
    Anything failing here raises Precondition: it is a memory or register
    fault, and reporting it as a resume fault would be a false attribution.
    """
    talk(d, dzrp.CMD_INIT, dzrp.init_payload())

    _write_mem(d, DBG_MARK, bytes(MARK_LEN))
    _write_mem(d, DBG_CODE, DEBUGGEE)

    back = _read_mem(d, DBG_CODE, len(DEBUGGEE))
    if back != DEBUGGEE:
        raise Precondition("the fixture did not land at 0x%04X (%d/%d bytes)"
                           % (DBG_CODE, len(back), len(DEBUGGEE)))
    mark = _read_mem(d, DBG_MARK, MARK_LEN)
    if mark != bytes(MARK_LEN):
        raise Precondition("the marker area at 0x%04X did not clear (%s)"
                           % (DBG_MARK, mark.hex()))

    _set_reg(d, REG_PC, DBG_CODE)
    _set_reg(d, REG_SP, DBG_STACK)
    _set_reg(d, REG_BC, PRESET_BC)
    _set_reg(d, REG_IX, PRESET_IX)


def resume_to_trap(d):
    """CMD_CONTINUE with a temporary breakpoint at the trap; wait for NTF_PAUSE.

    Returns the notification body, or None if none arrived.

    Under --no-continue the CMD_CONTINUE is skipped and the wait is NOT: a
    notification arriving with nothing having asked for one would be a far
    more interesting finding than the one this control is looking for.
    """
    payload = (bytes([1]) + _w(DBG_TRAP) +      # breakpoint 1, enabled
               bytes([0]) + _w(0) +             # breakpoint 2, off
               bytes([0]) +                     # no alternate command
               _w(0) + _w(0))                   # no step-over range
    if not NO_CONTINUE:
        talk(d, dzrp.CMD_CONTINUE, payload)
    try:
        return d.wait_notification()
    except dzrp.Timeout:
        return None


def _remote_still_answers():
    """Can a NEW connection get an answer out of the remote right now?

    Used only to describe a silence accurately. CMD_GET_REGISTERS rather than
    CMD_INIT, so the probe does not reset the remote's session state on its
    way past.
    """
    if REMOTE_SPEC is None:
        return None
    try:
        t = dzrp.open_remote(REMOTE_SPEC, timeout=5.0)
    except (OSError, dzrp.DzrpError):
        return False
    probe = dzrp.Dzrp(t, base_timeout=5.0)
    try:
        return len(probe.command(dzrp.CMD_GET_REGISTERS)) >= 28
    except (OSError, dzrp.DzrpError):
        return False
    finally:
        probe.close()


def _liveness():
    """Three words saying which kind of silence this was.

    "No reply" has three quite different meanings and a verdict line that
    collapses them is a check failing for a reason outside its own subject
    (ERRORS.md):

      remote still serving      it swallowed the command and carried on, so a
                                client blocks for ever — issue #8's shape
      remote stopped answering  this run cannot separate "no reply" from "the
                                command killed it"
      liveness not probed       --remote was not set, so we do not know

    THREE WORDS EACH, DELIBERATELY. Every caller appends this to its own detail,
    so whatever it returns is paid for inside that caller's twenty-word budget;
    a longer phrase here spends words in four checks at once. The meanings are
    written out in doc/DZRP-TESTING.md, which is where a reader has room for
    them.
    """
    alive = _remote_still_answers()
    if alive is True:
        return "remote still serving"
    if alive is False:
        return "remote stopped answering"
    return "liveness not probed"


def chk_continue_resumes(d):
    """THE ONE THAT MATTERS: does CMD_CONTINUE actually restart the debuggee?"""
    load_debuggee(d)
    ntf = resume_to_trap(d)
    if ntf is None:
        return FAIL, ("no NTF_PAUSE within %.0fs: not resumed, or never reached "
                      "0x%04X" % (d.base_timeout, DBG_TRAP))
    if len(ntf) < 6:
        return FAIL, "notification is %d bytes, too short for NTF_PAUSE" % len(ntf)
    if ntf[0] != dzrp.NTF_PAUSE:
        return FAIL, "notification id is %d, expected %d" % (ntf[0], dzrp.NTF_PAUSE)

    reason, addr, bank = ntf[1], int.from_bytes(ntf[2:4], "little"), ntf[4]
    mark = _read_mem(d, DBG_MARK, MARK_LEN)

    problems = []
    if addr != DBG_TRAP:
        problems.append("broke at 0x%04X, not 0x%04X" % (addr, DBG_TRAP))
    if mark[4] != RUN_A:
        problems.append("marker 0x%04X is 0x%02X: the debuggee never executed"
                        % (DBG_MARK + 4, mark[4]))
    if mark[5] != 0:
        problems.append("0x%04X is 0x%02X: it ran past the breakpoint"
                        % (DBG_MARK + 5, mark[5]))
    # The break reason is REPORTED, not asserted. The specification allows
    # 0/1/2/3/4/255 and DeZog does not require a particular one here; our stub
    # answers 0 (no reason) for a temporary breakpoint, which is what a step
    # is. Asserting a value would encode one remote's choice as the protocol.
    if reason not in (0, 1, 2, 3, 4, 255):
        problems.append("break reason %d is not in the specification" % reason)
    if problems:
        return FAIL, "; ".join(problems)
    return PASS, ("stopped on the breakpoint at 0x%04X (reason %d, bank %d)"
                  % (addr, reason, bank))


def chk_continue_state(d):
    """Was the debuggee's state RESTORED across the resume, or corrupted?

    Two directions, and both are needed. Inward: BC and IX are read out of
    memory where the resumed program itself put them, so this is what the
    DEBUGGEE held, not what the debugger remembers being told. Outward: the
    register block afterwards must show what the program computed while it
    ran, and an SP that came back to where it started — plan §4.1 warns the
    debuggee's SP can point anywhere, and every RST 0 moves it.
    """
    load_debuggee(d)
    ntf = resume_to_trap(d)
    if ntf is None:
        return FAIL, "no NTF_PAUSE, so no state can be read; see the C10 line"

    mark = _read_mem(d, DBG_MARK, MARK_LEN)
    regs = decode_registers(talk(d, dzrp.CMD_GET_REGISTERS))

    problems = []
    for name, got, want in (
            ("BC", int.from_bytes(mark[0:2], "little"), PRESET_BC),
            ("IX", int.from_bytes(mark[2:4], "little"), PRESET_IX)):
        if got != want:
            problems.append("the debuggee saw %s = 0x%04X, not 0x%04X"
                            % (name, got, want))
    for name, want in (("PC", DBG_TRAP), ("SP", DBG_STACK), ("HL", RUN_HL),
                       ("DE", RUN_DE), ("BC", RUN_BC), ("IX", PRESET_IX)):
        if regs[name] != want:
            problems.append("%s came back 0x%04X, expected 0x%04X"
                            % (name, regs[name], want))
    if regs["AF"] >> 8 != RUN_A:
        problems.append("A came back 0x%02X, expected 0x%02X"
                        % (regs["AF"] >> 8, RUN_A))
    if problems:
        return FAIL, "; ".join(problems)
    return PASS, "BC/IX reached the debuggee, and PC/SP/AF/BC/DE/HL/IX came back as left"


def chk_pause_while_stopped(d):
    """CMD_PAUSE, sent while the remote is already stopped.

    SCOPE, STATED UP FRONT. This is NOT a test of PC-initiated break. Breaking
    into a FREELY RUNNING program is milestone M2 and is not built: mf_rom.asm's
    nmi66h serves button NMIs only (bench check T4 asserts that decline
    deliberately), so with the debuggee running there is nothing polling for a
    byte from the PC and no CMD_PAUSE can be received at all. That is a design
    state, not a bug, and no check here can pass until M2 changes it.

    What CAN be asked today is the narrow protocol question: the specification
    gives CMD_PAUSE a Length=1 response — the sequence number and nothing else
    — with no exemption for a remote that is already stopped. So the check is
    simply "is it answered". A remote that refuses the command by closing the
    connection is a legitimate partial remote and reports UNSUPPORTED; SILENCE
    is neither, because DeZog waits for the response and would block.
    """
    talk(d, dzrp.CMD_INIT, dzrp.init_payload())
    try:
        body = talk(d, dzrp.CMD_PAUSE)
    except dzrp.Timeout:
        return FAIL, "no response within %.0fs; %s" % (d.base_timeout, _liveness())
    if body:
        return FAIL, "answered, but with a %d-byte payload" % len(body)
    return PASS, "answered with the sequence number and an empty payload"


SPRITE_COUNT = 4


def _chk_sprite_family(d, cmd, per_item, name):
    """CMD_GET_SPRITES / CMD_GET_SPRITE_PATTERNS: answered, at the exact length.

    WHY THE LENGTH IS NOT NEGOTIABLE, and why "answer something short" is not an
    option for a remote that cannot supply the data. DeZog asserts the size in
    the client — `assert(count*5 == r.length)` for sprites and
    `assert(r.length == 256*count)` for patterns, in the installed 3.7.4 — and
    then slices the reply into fixed-size records. A short reply is a desync,
    not a refusal, and DZRP has no error response to send instead.

    A ZX Next genuinely cannot read either back: ports 0x57 and 0x5B have no
    read decode in the FPGA at all (zxnext.vhd:651-652, and neither appears in
    the read mux at :2803-2806). So the only honest answer at the required
    length is zeros, whose visible bit is clear — an empty sprite view. An
    EMULATOR-side remote answers these for real, because its sprite state is
    host memory; that is a capability difference between targets, and this check
    accepts either as long as the length is right.

    SCOPE. This asserts the two things a client actually suffers — a hang, and a
    desync. It does NOT see the third thing issue #9 reports, that the old
    handler jumped to drain_main and re-initialised the debugger underneath the
    client: `prgm_state` is not observable over the socket. What is observable
    is that the session goes on working, which is asserted by the second command
    below.
    """
    talk(d, dzrp.CMD_INIT, dzrp.init_payload())
    try:
        body = talk(d, cmd, bytes([0, SPRITE_COUNT]))
    except dzrp.Timeout:
        return FAIL, "no response within %.0fs; %s" % (d.base_timeout, _liveness())

    want = SPRITE_COUNT * per_item
    if len(body) != want:
        return FAIL, ("answered with %d bytes, not the %d the client asserts"
                      % (len(body), want))

    # The session must survive it. The handler this replaces reached drain_main,
    # which re-initialises the debugger, so "answered" alone is not the whole
    # question.
    try:
        regs = talk(d, dzrp.CMD_GET_REGISTERS)
    except (dzrp.DzrpError, OSError) as e:
        return FAIL, "right length, but the next command failed (%s)" % e
    if len(regs) < 28:
        return FAIL, ("right length, but the next command came back as %d bytes"
                      % len(regs))

    return PASS, ("%d %s, %d bytes%s, next command in sync"
                  % (SPRITE_COUNT, name, len(body),
                     " of zeros" if not any(body) else " with data"))


def chk_get_sprites(d):
    return _chk_sprite_family(d, dzrp.CMD_GET_SPRITES, 5, "sprite attributes")


def chk_get_sprite_patterns(d):
    return _chk_sprite_family(d, dzrp.CMD_GET_SPRITE_PATTERNS, 256,
                              "sprite patterns")


def chk_close(d):
    """CMD_CLOSE is answered, and the remote goes on serving afterwards.

    NOTHING ELSE IN THIS SUITE SENDS COMMAND 2. Every check above takes a fresh
    connection and simply drops it, which is a TCP event and not a DZRP one: the
    remote is never told the session ended, so the one command DeZog uses to say
    so had no coverage at all.

    TWO ASSERTIONS, AND THE SECOND IS THE INTERESTING ONE.

    The response first. The specification gives CMD_CLOSE a Length=1 response —
    the sequence number and nothing else, exactly as CMD_PAUSE has — and DeZog's
    DzrpRemote awaits it: `sendDzrpCmdClose()` is
    `await this.sendDzrpCmd(2, undefined, this.initCloseRespTimeoutTime)` in the
    installed 3.7.4. Silence there blocks the client, which is issue #8's shape.

    Then that the remote is still there. This is the only command our stub
    answers and then LEAVES through `jp main` (src/commands.asm), which runs
    main's destructive prologue — `prgm_state` to `PRGM_IDLE`, `backup.speed`,
    `backup.interrupt_state`, `slot_backup.slot0` — and then `transport_activate`
    and `show_ui` before reaching `main_loop` again. So the response is written
    BEFORE all of that and proves none of it; only a further command, answered,
    shows the stub came out of the other side.

    CMD_INIT is the follow-up, for two reasons. It is what DeZog's own driver
    does — the first entry of its stress `cmdList` is `sendDzrpCmdClose()`
    immediately followed by `sendDzrpCmdInit()`, on the same remote — and no
    remote is entitled to refuse it, so a failure there cannot be a capability
    difference wearing this check's name.

    IT IS SENT WITHOUT talk(), DELIBERATELY. talk() maps a closed connection onto
    Unsupported, and this check's cmd_name is CLOSE — so a remote that answered
    CMD_CLOSE perfectly and then hung up would be reported as not implementing
    the command it had just implemented. The closed case gets its own verdict
    below instead.

    WHAT IT DELIBERATELY DOES NOT CLAIM. Not that any of that state was reset:
    `prgm_state` and the backup fields are not observable over a socket, and all
    this sees is that the remote answers again. Not the repaint either — that
    CMD_CLOSE redraws the screen is bench run-client-status.sh's N3, read off the
    Next's own display. And not the socket's fate: DZRP is silent on whether the
    transport survives CMD_CLOSE, so a remote that hangs up is reported as its
    own observation rather than folded into "no answer".

    IT RUNS LAST because it resets the debugger. Anything after it would be
    talking to a re-initialised stub.
    """
    talk(d, dzrp.CMD_INIT, dzrp.init_payload())
    try:
        body = talk(d, dzrp.CMD_CLOSE)
    except dzrp.Timeout:
        return FAIL, "no response within %.0fs; %s" % (d.base_timeout, _liveness())
    if body:
        return FAIL, "answered, but with a %d-byte payload" % len(body)

    try:
        again = d.command(dzrp.CMD_INIT, dzrp.init_payload())
    except dzrp.Timeout:
        # THE SECOND ASSERTION'S FAILURE, and the one control (B) produces. Kept
        # inside the line budget: which connection went quiet, and what that
        # implies, is in this docstring and in doc/DZRP-TESTING.md rather than
        # here. "remote still serving" here is the interesting case — a NEW
        # connection is served while this one is not, and DeZog reuses this one.
        return FAIL, "answered, but the next command was not; %s" % _liveness()
    except dzrp.DzrpError as e:
        if "closed" in str(e):
            return FAIL, "answered, then hung up: this connection is not served"
        raise
    if len(again) < 6 or again[0] != 0:
        return FAIL, "answered, but the next CMD_INIT was %d bytes" % len(again)
    return PASS, "Length=1 response, and a CMD_INIT after it answered in sync"


# A CHECK'S PRINTED LINE IS ONE SHORT SENTENCE — id, label and detail together
# no longer than about twenty words. The reasoning behind each check lives in its
# docstring and in doc/DZRP-TESTING.md, which is where a reader can afford to
# read it; a verdict a reviewer has to scroll is a verdict nobody reads.
#
# THE ID IS PART OF THE INTERFACE AND NEVER CHANGES. test/run-dzrp-stub.sh's W3
# asserts its negative control with `grep '^FAIL  C10 '`, hardware-check.py's
# classify() takes the code from field 2 of every FAIL line, and every document
# and issue refers to these by number. Shorten the prose after the id, never the
# id itself.
CHECKS = [
    ("C1 CMD_INIT negotiates a version", chk_init, "INIT"),
    ("C2 a command's length counts payload only", chk_length_convention, "INIT"),
    ("C3 frame preamble", None, "INIT"),            # needs the expect argument
    ("C4 CMD_LOOPBACK round-trips", chk_loopback, "LOOPBACK"),
    ("C5 CMD_LOOPBACK is exact at size boundaries", chk_loopback_sizes, "LOOPBACK"),
    ("C6 sequence numbers echo back", chk_sequence, "INIT"),
    ("C7 CMD_GET_REGISTERS returns a register block", chk_registers, "GET_REGISTERS"),
    ("C8 memory write/read round-trip", chk_memory, "WRITE_MEM"),
    # C9 was written to be LAST, because it is the one check that deliberately
    # leaves bytes in flight and a remote that mishandles them would be broken
    # for whatever ran next. It now proves it left the stream in sync itself,
    # with a second CMD_INIT on the same connection, so the checks below can
    # follow it — and each of those opens its own connection regardless. If C9
    # ever goes red again, read the reds under it as suspect until it is green.
    ("C9 CMD_INIT consumes the declared payload", chk_init_consumes_payload, "INIT"),
    ("C10 CMD_CONTINUE resumes the debuggee and it runs", chk_continue_resumes,
     "CONTINUE"),
    ("C11 the debuggee's state survives the resume", chk_continue_state,
     "CONTINUE"),
    ("C12 CMD_PAUSE while stopped is answered", chk_pause_while_stopped, "PAUSE"),
    ("C13 CMD_GET_SPRITES is answered at the asserted length",
     chk_get_sprites, "GET_SPRITES"),
    ("C14 CMD_GET_SPRITE_PATTERNS is answered at the asserted length",
     chk_get_sprite_patterns, "GET_SPRITE_PATTERNS"),
    # C15 IS LAST, AND MUST STAY LAST. It is the only check that deliberately
    # resets the remote: CMD_CLOSE leaves our stub through `jp main`, which
    # re-initialises prgm_state and the debuggee's saved state. Anything below it
    # would be running against a re-initialised stub, which is a different
    # subject from the one it thinks it is testing.
    ("C15 CMD_CLOSE is answered and the remote serves on", chk_close, "CLOSE"),
]


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--remote", required=True,
                    help="tcp:<host>:<port> or serial:<device>:<baud>")
    ap.add_argument("--start-byte", default="auto", choices=["auto", "a5", "none"],
                    help="frame preamble the remote uses (default: autodetect)")
    ap.add_argument("--expect-preamble", default="report",
                    choices=["report", "a5", "none"],
                    help="assert the preamble rather than only reporting it")
    ap.add_argument("--require", default="",
                    help="comma-separated commands whose absence is a FAILURE "
                         "rather than UNSUPPORTED, e.g. INIT,LOOPBACK")
    ap.add_argument("--only", default="",
                    help="comma-separated check ids to run, e.g. C10,C11")
    ap.add_argument("--no-continue", action="store_true",
                    help="NEGATIVE CONTROL: perform the execution-control "
                         "checks' whole setup but never send CMD_CONTINUE. "
                         "They MUST then fail; if they pass, they are not "
                         "measuring the resume.")
    ap.add_argument("--timeout", type=float, default=5.0)
    args = ap.parse_args()

    global REMOTE_SPEC, NO_CONTINUE
    REMOTE_SPEC = args.remote
    NO_CONTINUE = args.no_continue

    required = {s.strip().upper() for s in args.require.split(",") if s.strip()}
    unknown = required - set(NAMES)
    if unknown:
        print("ERROR: --require names unknown commands: %s" % ", ".join(sorted(unknown)),
              file=sys.stderr)
        return 2

    ids = [label.split()[0] for label, _, _ in CHECKS]
    only = {s.strip().upper() for s in args.only.split(",") if s.strip()}
    unknown = only - set(ids)
    if unknown:
        print("ERROR: --only names unknown checks: %s (have: %s)"
              % (", ".join(sorted(unknown)), ", ".join(ids)), file=sys.stderr)
        return 2

    sb = {"auto": "auto", "a5": dzrp.START_BYTE, "none": None}[args.start_byte]

    print("== DZRP conformance against %s" % args.remote)
    if required:
        print("   required commands: %s" % ", ".join(sorted(required)))
    if only:
        print("   only: %s" % ", ".join(sorted(only)))
    if NO_CONTINUE:
        # Loud, because an output that looks like a normal run but is missing
        # the one command under test is exactly the artefact ERRORS.md warns
        # about being reported as a finding.
        print("   *** NEGATIVE CONTROL: --no-continue. No CMD_CONTINUE is sent.")
        print("   *** C10 and C11 MUST fail. This is NOT a conformance result.")
    print("")

    counts = {PASS: 0, FAIL: 0, UNSUP: 0}
    ran = 0

    for label, fn, cmd_name in CHECKS:
        if only and label.split()[0] not in only:
            continue
        ran += 1
        # Announce before running. On a terminal this is written WITHOUT a
        # newline and the verdict overwrites it, so the console ends up with
        # exactly one line per check rather than two.
        if PROGRESS:
            print("      %s ..." % label, end="\r", flush=True)
        # Each check gets a fresh connection, so one refused command cannot
        # take the rest down. A remote that serves one client at a time needs
        # a moment to start listening again between them — CSpect's plugin
        # logs "Disconnected / Waiting for a connection" — so retry briefly
        # rather than calling that transient gap an unreachable remote.
        transport = None
        for attempt in range(20):
            try:
                transport = dzrp.open_remote(args.remote, timeout=args.timeout)
                break
            except (OSError, dzrp.DzrpError):
                time.sleep(0.25)
        if transport is None:
            print("ERROR: cannot reach %s after 5s of retries" % args.remote,
                  file=sys.stderr)
            return 2
        d = dzrp.Dzrp(transport, start_byte=sb, base_timeout=args.timeout)
        try:
            if fn is None:                       # the preamble check needs a flag
                status, detail = chk_preamble(d, args.expect_preamble)
            else:
                status, detail = fn(d)
        except Unsupported as e:
            if cmd_name in required or cmd_name in ALWAYS_REQUIRED:
                status = FAIL
                detail = "CMD_%s is REQUIRED but the remote does not implement it (%s)" % (
                    cmd_name, e)
            else:
                status = UNSUP
                detail = "remote does not implement CMD_%s" % cmd_name
        except Precondition as e:
            # A failure, because nothing was established — but named as what it
            # is, so it is not read as evidence about this check's subject.
            status = FAIL
            # ONE WORD, and it is a label rather than a sentence: everything
            # after it is the fault itself, and the fault has to fit the line
            # budget beside it. What PRECONDITION *means* — the setup broke, so
            # nothing here is evidence about this check's subject — is in
            # doc/DZRP-TESTING.md. The long form spent six words saying it on
            # every occurrence and pushed three C10/C11 branches past the
            # budget, which is what measuring the FAIL paths turned up.
            detail = "PRECONDITION: %s" % e
        except dzrp.DzrpError as e:
            status, detail = FAIL, str(e)
        finally:
            d.close()

        counts[status] += 1
        # flush, because this is usually a pipe and Python would otherwise hold
        # every line until the suite ended — which is the whole problem this
        # streaming exists to fix.
        # Erase whatever the progress line left on this row before writing the
        # verdict over it — the labels differ in length, so without this the
        # tail of a longer previous line survives past the shorter new one.
        if PROGRESS:
            print("\033[K", end="")
        print("%s %s%s" % (paint(status), label, " — %s" % detail if detail else ""),
              flush=True)

    print("")
    summary = "%d passed, %d failed, %d unsupported, of %d checks" % (
        counts[PASS], counts[FAIL], counts[UNSUP], ran)
    print("DZRP conformance: " + summary)
    # Everything-unsupported is not a pass. A remote that answered nothing at
    # all would otherwise exit 0, which is precisely the "green result that
    # cannot distinguish success from noise" ERRORS.md already warns about.
    if counts[PASS] == 0:
        print("  (nothing passed — treating that as a failure, not a partial remote)")
        return 1
    return 1 if counts[FAIL] else 0


if __name__ == "__main__":
    sys.exit(main())
