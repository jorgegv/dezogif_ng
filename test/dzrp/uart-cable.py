#!/usr/bin/env python3
"""The serial cable's half of asynchronous break — issue #43.

THIS IS NOT A CLIENT, AND THAT IS THE WHOLE DIFFICULTY. Every other DZRP check
here holds a socket and reacts to what the remote says. A joystick-port cable in
jnext is a ONE-WAY byte stream from a file (`--joy-uart-rx`, jnext#251): the
guest's replies leave through joystick pin 7 and reach nothing on the host. So
the commands are PRE-RECORDED, and the remote's answers are read afterwards out
of jnext's own UART TX log, which records every byte the guest transmits
(`uart.cpp:743`, at `debug`).

    build    write the recorded command stream to a file
    verdict  decode a jnext log's TX bytes back into DZRP frames and judge them

Keeping both in one module is deliberate: the builder chooses the sequence
numbers and the decoder maps them back to commands, and two files disagreeing
about that would be a bench reporting the wrong command's answer.

WHAT THE RUN DOES. A debuggee carrying the 44 bytes of Copper list — the same
fixture as bench W8, and the same thing a real user's program carries — is
written over the cable, resumed with NO temporary breakpoint, and stopped again
by bytes arriving on that cable. Before this, `TRANSPORT_DEACTIVATE` cleared
NR 0x0B on every resume, which re-pointed the joystick pin away from the UART
and made the poll's link check permanently blind; it now keeps io mode when
`uart_joyport_selection` is 2. That macro is reached by no other run anywhere,
in jnext or on hardware.

THE BREAK ALONE CANNOT SHOW WHICH ARM OF THAT MACRO RAN, AND THAT WAS MEASURED
RATHER THAN ASSUMED. The RX FIFO is 512 bytes and NOTHING drains it on the
resume path (`restore_registers` does `transport_flush` then the macro, and no
drain — `backup.asm:58-62`), so bytes that arrived while the debugger was still
stopped are still there afterwards. The whole recorded stream is ~250 bytes and
takes ~2.7 ms on the wire at 921600, against the several milliseconds `cmd_init`
spends in `show_ui`, so in practice ALL of it is buffered before `CMD_CONTINUE`
is even read. Measured: a run with the cable in joystick socket 1 and the
port-1 selection — which clears NR 0x0B on resume, i.e. the pre-fix behaviour —
breaks in and answers every command exactly as socket 2 does, byte for byte.

SO THE DEBUGGEE IS THE WITNESS INSTEAD, AND IT MEASURES THE CHANGED LINE
DIRECTLY. NR 0x0B reads back (`zxnext.vhd:5914`,
`nr_0b_joy_iomode_en & '0' & nr_0b_joy_iomode & "000" & nr_0b_joy_iomode_0`), so
the fixture's first act after the resume is to read it and store it. That byte
is what `TRANSPORT_DEACTIVATE` left, sampled by the debugged program itself at
the only moment that matters — while it is running — and it is immune to the
FIFO, to the pacing and to when the poll happens to fire. It comes back over the
cable afterwards as an ordinary `CMD_READ_MEM`.

    joy port 2   NR 0x0B = 0xB1   io mode on, socket 2, UART1 — the cable lives
    joy port 1   NR 0x0B = 0x00   io mode off — the cable's RX is severed

The read-back is exact for those two values: the VHDL zeroes bits 6 and 3:1 and
both are already zero in what the stub writes. jnext returns the byte as
written (`nextreg.cpp:442`), so the comparison is masked to the bits the VHDL
guarantees rather than trusting either model's spare bits.

Environment: none. Everything is arguments, so a run is re-runnable by hand.
"""
import argparse
import os
import re
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from dzrp import (CMD_CONTINUE, CMD_GET_REGISTERS, CMD_INIT,  # noqa: E402
                  CMD_PAUSE, CMD_READ_MEM, CMD_SET_REGISTER, CMD_WRITE_MEM,
                  NTF_PAUSE, START_BYTE, init_payload)

# Inside 0x8000-0x9FFF, which CMD_INIT maps to bank 4 — W8's window, and clear
# of the debugger's own slots 6 and 7.
DBG_CODE = 0x8000
DBG_STACK = 0x9F00
WITNESS = 0x9000            # 3840 bytes below the stack, which nothing pushes to
WITNESS_SEED = 0x5A         # so "the fixture never ran" is a distinct outcome

REG_PC, REG_SP = 0, 1
BREAK_MANUAL = 1

TBBLUE_SELECT = 0x243B
TBBLUE_ACCESS = 0x253B
REG_RESET = 0x02
REG_PERIPHERAL_2 = 0x06
REG_JOYSTICK_IO_MODE = 0x0B
REG_COPPER_DATA = 0x60
REG_COPPER_ADDR_LSB = 0x61
REG_COPPER_CONTROL = 0x62

COPPER_LINE = 100
COPPER_RUN_LOOP = 0x40

# The bits NR 0x0B's read decode guarantees: 7 (enable), 5:4 (mode) and 0
# (which UART). Bits 6 and 3:1 read back as zero on hardware and as whatever
# was written under jnext, so they are masked out rather than argued about.
NR0B_MASK = 0b10110001
NR0B_JOY2 = 0b10110001      # transport_activate's joy-port-2 value
NR0B_OFF = 0b00000000       # what TRANSPORT_DEACTIVATE writes on any other port


def _w(v):
    return v.to_bytes(2, "little")


def _nextreg(reg, val):
    """Z80N `nextreg reg,val` — ED 91 rr vv."""
    return bytes([0xED, 0x91, reg, val])


def _read_nextreg_to(reg, addr):
    """`a = NR reg; (addr) = a`, through the ordinary 0x243B/0x253B pair."""
    return (b"\x01" + _w(TBBLUE_SELECT) +        # ld bc,0x243B
            b"\x3E" + bytes([reg]) +             # ld a,reg
            b"\xED\x79" +                        # out (c),a
            b"\x01" + _w(TBBLUE_ACCESS) +        # ld bc,0x253B
            b"\xED\x78" +                        # in a,(c)
            b"\x32" + _w(addr))                  # ld (addr),a


# Hand-assembled, one instruction per line, and it is what a real user's program
# start looks like plus the one witness read. The WAIT is 0x8000|line and the
# MOVE is (reg<<8)|value, per device/copper.vhd:91-104.
#
# THE WITNESS READ COMES FIRST, before the Copper list, so that the byte it
# stores is NR 0x0B at the earliest instruction the debuggee executes after
# `restore_registers` returned to it. Nothing between there and here can have
# changed it — the poll does not touch NR 0x0B and `transport_activate` runs
# only when the debugger takes control — but reading it first is what makes
# that a fact about the resume rather than about the rest of the fixture.
_wait = 0x8000 | COPPER_LINE
_move = (REG_RESET << 8) | 0x08
FIXTURE = (
    b"\xF3" +                                   # di
    _read_nextreg_to(REG_JOYSTICK_IO_MODE, WITNESS) +
    # NR 0x06 |= bit 3 — every MF NMI source is ANDed with it (zxnext.vhd:2090)
    b"\x01" + _w(TBBLUE_SELECT) +               # ld bc,0x243B
    b"\x3E" + bytes([REG_PERIPHERAL_2]) +       # ld a,0x06
    b"\xED\x79" +                               # out (c),a
    b"\x01" + _w(TBBLUE_ACCESS) +               # ld bc,0x253B
    b"\xED\x78" +                               # in a,(c)
    b"\xF6\x08" +                               # or 0x08
    b"\xED\x79" +                               # out (c),a
    # stop the Copper, put the write pointer at index 0
    _nextreg(REG_COPPER_CONTROL, 0x00) +
    _nextreg(REG_COPPER_ADDR_LSB, 0x00) +
    # the list, MSB first
    _nextreg(REG_COPPER_DATA, (_wait >> 8) & 0xFF) +
    _nextreg(REG_COPPER_DATA, _wait & 0xFF) +
    _nextreg(REG_COPPER_DATA, (_move >> 8) & 0xFF) +
    _nextreg(REG_COPPER_DATA, _move & 0xFF) +
    # run it from index 0, looping
    _nextreg(REG_COPPER_CONTROL, COPPER_RUN_LOOP) +
    b"\x18\xFE"                                 # jr $   <- the spin
)
SPIN = DBG_CODE + len(FIXTURE) - 2

# seq -> what that command was, so the decoder can name an answer rather than
# print a number. Built once, here, by the same code that lays the stream out.
SEQ_INIT = 1
SEQ_SEED = 2
SEQ_FIXTURE = 3
SEQ_READBACK = 4
SEQ_PC = 5
SEQ_SP = 6
SEQ_CONTINUE = 7
SEQ_PAUSE = 8
SEQ_REGS = 9
SEQ_WITNESS = 10
SEQ_ALIVE = 11

LAST_SETUP_SEQ = SEQ_CONTINUE


def _cmd(seq, cmd_id, payload=b""):
    # Length counts the PAYLOAD only for a command — see dzrp.py. A response
    # counts from the sequence byte, which is why the decoder below adds one.
    return struct.pack("<IBB", len(payload), seq, cmd_id) + payload


def build_stream(control=False):
    """The recorded command stream.

    THE CONTROL TRUNCATES AFTER `CMD_CONTINUE` AND IS NOT OPTIONAL, for W3's
    reason exactly: without it, a notification arriving after the resume is not
    evidence that the CABLE caused it rather than the debuggee stopping by
    itself, never having run, or the stub breaking in on something of its own.
    """
    out = _cmd(SEQ_INIT, CMD_INIT, init_payload(name="dezogif_ng-uart-cable"))
    # Seed the witness with a byte the fixture cannot produce, so "the fixture
    # never ran" is a third outcome and not silently one of the two verdicts.
    out += _cmd(SEQ_SEED, CMD_WRITE_MEM, b"\x00" + _w(WITNESS) + bytes([WITNESS_SEED]))
    out += _cmd(SEQ_FIXTURE, CMD_WRITE_MEM, b"\x00" + _w(DBG_CODE) + FIXTURE)
    out += _cmd(SEQ_READBACK, CMD_READ_MEM, b"\x00" + _w(DBG_CODE) + _w(len(FIXTURE)))
    out += _cmd(SEQ_PC, CMD_SET_REGISTER, bytes([REG_PC]) + _w(DBG_CODE))
    out += _cmd(SEQ_SP, CMD_SET_REGISTER, bytes([REG_SP]) + _w(DBG_STACK))
    # NO TEMPORARY BREAKPOINT. Both entries disabled, no alternate command, no
    # step-over range — so nothing the debugger planted can bring this back.
    out += _cmd(SEQ_CONTINUE, CMD_CONTINUE,
                bytes([0]) + _w(0) + bytes([0]) + _w(0) + bytes([0]) + _w(0) + _w(0))
    if control:
        return out
    out += _cmd(SEQ_PAUSE, CMD_PAUSE)
    out += _cmd(SEQ_REGS, CMD_GET_REGISTERS)
    out += _cmd(SEQ_WITNESS, CMD_READ_MEM, b"\x00" + _w(WITNESS) + _w(1))
    out += _cmd(SEQ_ALIVE, CMD_READ_MEM, b"\x00" + _w(DBG_CODE) + _w(2))
    return out


# --- reading the stub's answers back out of jnext's log ---------------------

_TX = re.compile(r"TX write (0x[0-9a-fA-F]+)")


def tx_bytes(path):
    """Every byte the guest transmitted, in order, from a jnext uart=debug log."""
    out = bytearray()
    with open(path, "r", errors="replace") as fh:
        for line in fh:
            m = _TX.search(line)
            if m:
                out.append(int(m.group(1), 16) & 0xFF)
    return bytes(out)


def frames(data):
    """[(seq, payload)] — the DZRP frames in a UART-mode TX stream.

    Every response and notification is preceded by MESSAGE_START_BYTE (0xA5).
    That is upstream's documented extension for the serial link, not a defect
    (doc/legacy/Design.md:30-31), and it is what makes this stream
    self-framing: resynchronising on it is how a partial frame at the end — a
    run that was cut off mid-reply — is skipped rather than mis-parsed as the
    next one's length.
    """
    out = []
    i = 0
    while i < len(data):
        if data[i] != START_BYTE:
            i += 1
            continue
        if i + 5 > len(data):
            break
        length = struct.unpack("<I", data[i + 1:i + 5])[0]
        body = data[i + 5:i + 5 + length]
        if length < 1 or len(body) < length:
            break                      # truncated tail: the run ended mid-reply
        out.append((body[0], body[1:]))
        i += 5 + length
    return out


def _answers(fr):
    return {seq: payload for seq, payload in fr if seq != 0}


def _notifications(fr):
    return [payload for seq, payload in fr if seq == 0]


def verdict_subject(fr, expect_nr0b, label):
    """The full run: did the cable stop a running debuggee, and what did the
    debuggee see NR 0x0B holding while it ran?

    TWO VERDICTS, RENDERED INDEPENDENTLY, and that separation was earned by a
    red-first rather than designed in. With the fixture's Copper list never
    started the break correctly reports BAD — and the first version then threw
    that away, because the witness (which the stub can only send once it HAS
    broken in) reported a precondition and the single return code carried it.
    A check that renders a verdict must report it; the two subjects fail for
    different reasons and are answered on different lines.

    The exit code is about the SETUP only: non-zero means neither subject was
    reachable, so both are preconditions rather than verdicts.
    """
    ans = _answers(fr)
    ntfs = _notifications(fr)
    problems = []

    # --- preconditions: nothing below means anything without these ----------
    if SEQ_READBACK not in ans:
        print("PRECONDITION %s the stub never answered the fixture read-back" % label)
        return 1
    back = ans[SEQ_READBACK]
    if back != FIXTURE:
        same = sum(1 for a, b in zip(back, FIXTURE) if a == b)
        print("PRECONDITION %s the fixture did not land: %d of %d bytes match"
              % (label, same, len(FIXTURE)))
        return 1
    if SEQ_CONTINUE not in ans:
        print("PRECONDITION %s CMD_CONTINUE was never answered, so nothing was resumed"
              % label)
        return 1

    # --- the break ----------------------------------------------------------
    if not ntfs:
        print("RESULT %s break BAD no notification: the running debuggee was never stopped"
              % label)
    else:
        n = ntfs[0]
        if len(n) < 6 or n[0] != NTF_PAUSE:
            problems.append("notification is %d bytes, id %d, not an NTF_PAUSE"
                            % (len(n), n[0] if n else -1))
        else:
            if n[1] != BREAK_MANUAL:
                problems.append("break reason %d, expected %d (MANUAL_BREAK)"
                                % (n[1], BREAK_MANUAL))
            # A manual break has no breakpoint, so mf.asm:169 passes zero. A
            # remote putting something else here would be telling the client a
            # breakpoint stopped a program that none was planted in.
            bp = int.from_bytes(n[2:4], "little")
            if bp != 0:
                problems.append("the notification named breakpoint 0x%04X where a manual "
                                "break has none" % bp)
        if SEQ_PAUSE not in ans:
            problems.append("CMD_PAUSE went unanswered")
        elif ans[SEQ_PAUSE]:
            problems.append("CMD_PAUSE answered with a %d-byte payload, expected none"
                            % len(ans[SEQ_PAUSE]))

        regs = ans.get(SEQ_REGS, b"")
        if len(regs) >= 4:
            pc = int.from_bytes(regs[0:2], "little")
            sp = int.from_bytes(regs[2:4], "little")
            print("STATE %s PC=0x%04X SP=0x%04X (spin 0x%04X, stack 0x%04X)"
                  % (label, pc, sp, SPIN, DBG_STACK))
            if pc != SPIN:
                problems.append("stopped at PC 0x%04X, not the spin at 0x%04X" % (pc, SPIN))
            if sp != DBG_STACK:
                problems.append("SP 0x%04X, not the fixture's 0x%04X" % (sp, DBG_STACK))
        else:
            problems.append("CMD_GET_REGISTERS returned %d bytes" % len(regs))

        if SEQ_ALIVE not in ans:
            problems.append("the stub stopped serving after the break")

        # The join can exceed the ~20-word budget, deliberately and for C10's
        # and C11's reason: these are INDEPENDENT faults, and a badly broken
        # asynchronous break is exactly what fails on several axes at once.
        if problems:
            print("RESULT %s break BAD %s" % (label, "; ".join(problems)))
        else:
            print("RESULT %s break OK stopped the spin at 0x%04X over the cable, still serving"
                  % (label, SPIN))

    # --- the witness --------------------------------------------------------
    verdict_witness(fr, expect_nr0b, label)
    return 0


def verdict_witness(fr, expect_nr0b, label):
    """What the DEBUGGEE read out of NR 0x0B while it was running — which is
    what TRANSPORT_DEACTIVATE left, sampled by the program itself.

    THE WITNESS IS NOT INDEPENDENT OF THE BREAK, and that is a real dependency
    rather than a wrinkle: the byte can only come back over the cable once the
    stub has broken in and is reading commands again. So a run in which nothing
    stopped the debuggee has no witness to report, and this says PRECONDITION —
    the state was never sampled — rather than rendering a verdict on a byte
    nobody sent.
    """
    ans = _answers(fr)
    if SEQ_WITNESS not in ans or len(ans[SEQ_WITNESS]) < 1:
        print("RESULT %s witness PRECONDITION the byte never came back: nothing broke in"
              % label)
        return 1
    raw = ans[SEQ_WITNESS][0]
    if raw == WITNESS_SEED:
        print("RESULT %s witness BAD the seed 0x%02X is untouched: the fixture never ran"
              % (label, WITNESS_SEED))
        return 0
    got = raw & NR0B_MASK
    if got != expect_nr0b:
        print("RESULT %s witness BAD the debuggee ran with NR 0x0B = 0x%02X, expected 0x%02X"
              % (label, got, expect_nr0b))
    else:
        print("RESULT %s witness OK the debuggee ran with NR 0x0B = 0x%02X (raw 0x%02X)"
              % (label, got, raw))
    return 0


def verdict_control(fr):
    """The control: the same run with the stream truncated after CMD_CONTINUE.

    NOTHING may come back. A notification here would mean the break W1 reports
    was not caused by the bytes that follow the resume in the full stream.
    """
    ans = _answers(fr)
    if SEQ_CONTINUE not in ans:
        print("PRECONDITION control CMD_CONTINUE was never answered, so nothing was resumed")
        return 1
    if SEQ_READBACK not in ans or ans[SEQ_READBACK] != FIXTURE:
        print("PRECONDITION control the fixture did not land, so the debuggee ran nothing")
        return 1
    late = [seq for seq in ans if seq > LAST_SETUP_SEQ]
    ntfs = _notifications(fr)
    if ntfs:
        print("RESULT control BAD a notification arrived with nothing sent after CMD_CONTINUE")
    elif late:
        print("RESULT control BAD the stub answered %d command(s) nobody sent" % len(late))
    else:
        print("RESULT control OK nothing came back after the resume")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="mode", required=True)

    b = sub.add_parser("build", help="write the recorded command stream")
    b.add_argument("path")
    b.add_argument("--control", action="store_true",
                   help="truncate after CMD_CONTINUE (nothing may come back)")

    v = sub.add_parser("verdict", help="judge a jnext uart=debug log")
    v.add_argument("log")
    v.add_argument("--label", default="joy2")
    v.add_argument("--control", action="store_true")
    v.add_argument("--expect-nr0b", default="0xB1",
                   help="the NR 0x0B the debuggee must have seen (default 0xB1, joy port 2)")

    a = ap.parse_args()

    if a.mode == "build":
        data = build_stream(control=a.control)
        with open(a.path, "wb") as fh:
            fh.write(data)
        print("stream %d bytes, fixture %d at 0x%04X, spin 0x%04X, witness 0x%04X"
              % (len(data), len(FIXTURE), DBG_CODE, SPIN, WITNESS))
        return 0

    fr = frames(tx_bytes(a.log))
    print("TXFRAMES %s %s" % (a.label,
                              " ".join("ntf" if s == 0 else str(s) for s, _ in fr) or "none"))
    if a.control:
        return verdict_control(fr)
    return verdict_subject(fr, int(a.expect_nr0b, 0) & NR0B_MASK, a.label)


if __name__ == "__main__":
    sys.exit(main())
