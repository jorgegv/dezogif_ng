#!/usr/bin/env python3
"""Bench check W8: STOP A FREELY RUNNING DEBUGGEE FROM THE PC.

THIS IS MILESTONE M2'S ACCEPTANCE CRITERION AND NOTHING IN THIS PROJECT HAS EVER
DONE IT. dezogif's headline limitation is that you cannot pause a running
program from the PC — you walk over and press the M1 button. Every resume this
suite has ever tested (C10, C11) comes back through a temporary breakpoint the
client planted in advance; the debuggee is stopped because it ran into something
the debugger put there. Here it is stopped because somebody clicked Pause.

THE DEBUGGED PROGRAM INSTALLS THE COPPER LIST, NOT THE DEBUGGER, and that is the
design rather than a convenience of this fixture. The Copper's 1024-instruction
list is write-only (zxnext.vhd:3959-3976, :3980-3998; no read decode for NR 0x60
or 0x63 at :6286-6287), so a debugger that installed its own could never restore
what it destroyed. A program that carries `WAIT line,0` / `MOVE $02,$08` itself
keeps its own Copper program and can compile the two instructions out for
release; a program that does not simply gets no asynchronous break. So the
fixture below is what a real user's program start would look like, and the two
instructions are encoded from device/copper.vhd:91-104 rather than from a wiki.

THE SEQUENCE, and why each step is the one it is:

    CMD_INIT                 a session, and it resets the slots to the ZX128
                             layout the fixture's addresses assume.
    CMD_WRITE_MEM            the fixture: enable the MF NMI gate, install the
                             list, then spin. Read back before it is trusted —
                             a fixture that did not land would make everything
                             after it meaningless.
    CMD_SET_REGISTER PC/SP   aim the debuggee at it. SP is the fixture's own,
                             clear of anything else this run touches.
    CMD_CONTINUE, NO         the load-bearing difference from C10. With no
    TEMPORARY BREAKPOINT     breakpoint there is NOTHING that can stop this
                             program except an asynchronous break: it spins in
                             `jr $` for ever, and before M2 the only way back
                             was a finger on the M1 button.
    (settle)                 the debuggee is left running for a whole second of
                             wall clock, so that "it was still running" is not
                             a claim about a millisecond.
    CMD_PAUSE                the click.
    NTF_PAUSE                the verdict: it must arrive, carry MANUAL_BREAK,
                             and name a PC inside the fixture's spin.
    the Length=1 response    CMD_PAUSE's own answer, which the specification
                             requires and which issue #8 fixed. Read AFTER the
                             notification, because the stub sends the
                             notification first — see below.
    one further command      the stub must still be serving afterwards.

WHY MANUAL_BREAK AND NOT A NEW REASON. BREAK_REASON has three values —
NO_REASON, MANUAL_BREAK, BREAKPOINT_HIT (src/breakpoints.asm:18-20) — and DZRP
defines no fourth for "the client asked". Inventing one would be this remote
encoding its own vocabulary into the protocol, and DeZog's cspect remote already
understands MANUAL_BREAK, which is what a button press reports. A poll break and
a button press are the same event as far as a client is concerned: the program
stopped and nobody's breakpoint did it.

THE ORDER OF THE NOTIFICATION AND THE RESPONSE IS THE STUB'S, NOT A CHOICE HERE.
mf_nmi_button_pressed sends the NTF_PAUSE and then falls into cmd_loop, which is
where the pending CMD_PAUSE is read and answered. So the notification comes
first and the response second, and a client that insisted on the reverse order
would deadlock against a correct remote. This reads whichever arrives.

WHY cmd_pause ITSELF IS UNCHANGED, WHICH IS EASY TO GET WRONG. The break is
caused by the POLL, not by the handler: by the time cmd_loop reads command 7 the
machine is already stopped and send_ntf_pause has already set prgm_state to
PRGM_STOPPED. So cmd_loop still runs only while stopped, there is still nothing
for cmd_pause to pause, and issue #8's two prohibitions — do not touch
prgm_state, do not send a notification — both still hold for the reasons #8
gives them. Verified in the source before relying on it; conformance check C12
covers the same handler in the other state.

THE CONTROL IS IN THE BENCH, NOT HERE. Run with --no-pause the client does
everything except send CMD_PAUSE, and NOTHING must come back: without that, a
green W8 is not evidence that the pause caused the break rather than the
debuggee having stopped on its own, or never having run. It is the same argument
W3 makes for C10. See run-dzrp-stub.sh's PAUSE_RUNNING_CONTROL.

Environment: DZRP_HOST, DZRP_PORT, DZRP_TIMEOUT, W8_NO_PAUSE, W8_RUN_SECONDS.
Exit 0 means a verdict was rendered and is on stdout as a RESULT line; 1 means a
precondition stopped the run before that, in which case nothing was judged.
"""
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from dzrp import (CMD_CONTINUE, CMD_GET_TBBLUE_REG, CMD_INIT,  # noqa: E402
                  CMD_PAUSE, CMD_READ_MEM, CMD_SET_REGISTER, CMD_WRITE_MEM,
                  Dzrp, NTF_PAUSE, Timeout, init_payload, open_remote)

HOST = os.environ.get("DZRP_HOST", "127.0.0.1")
PORT = int(os.environ.get("DZRP_PORT", "11000"))
TIMEOUT = float(os.environ.get("DZRP_TIMEOUT", "25"))
NO_PAUSE = os.environ.get("W8_NO_PAUSE", "") not in ("", "0")
RUN_SECONDS = float(os.environ.get("W8_RUN_SECONDS", "1.0"))

# Inside 0x8000-0x9FFF, which CMD_INIT maps to bank 4 — the same window
# conformance.py's own fixture uses, and clear of the debugger's slots 6 and 7.
DBG_CODE = 0x8000
DBG_STACK = 0x9F00

REG_PC, REG_SP = 0, 1

BREAK_MANUAL = 1

TBBLUE_SELECT = 0x243B
TBBLUE_ACCESS = 0x253B
REG_RESET = 0x02
REG_PERIPHERAL_2 = 0x06
REG_COPPER_DATA = 0x60
REG_COPPER_ADDR_LSB = 0x61
REG_COPPER_CONTROL = 0x62

COPPER_LINE = 100
COPPER_RUN_LOOP = 0x40


def _w(v):
    return v.to_bytes(2, "little")


def _nextreg(reg, val):
    """Z80N `nextreg reg,val` — ED 91 rr vv."""
    return bytes([0xED, 0x91, reg, val])


# Hand-assembled, one instruction per line. It is the user-program half of the
# asynchronous break and nothing more: set the gate, write the list, run it,
# spin. The WAIT is 0x8000|line and the MOVE is (reg<<8)|value, per
# device/copper.vhd:91-104.
_wait = 0x8000 | COPPER_LINE
_move = (REG_RESET << 8) | 0x08
FIXTURE = (
    b"\xF3" +                                   # di
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


def main():
    d = Dzrp(open_remote("tcp:%s:%d" % (HOST, PORT), timeout=TIMEOUT),
             start_byte=None, base_timeout=TIMEOUT)

    d.command(CMD_INIT, init_payload(name="dezogif_ng-pause-running"))

    d.command(CMD_WRITE_MEM, b"\x00" + _w(DBG_CODE) + FIXTURE)
    back = d.command(CMD_READ_MEM, b"\x00" + _w(DBG_CODE) + _w(len(FIXTURE)))
    if back != FIXTURE:
        print("PRECONDITION the fixture did not land at 0x%04X (%d of %d bytes match)"
              % (DBG_CODE, sum(1 for a, b in zip(back, FIXTURE) if a == b), len(FIXTURE)))
        return 1

    d.command(CMD_SET_REGISTER, bytes([REG_PC]) + _w(DBG_CODE))
    d.command(CMD_SET_REGISTER, bytes([REG_SP]) + _w(DBG_STACK))

    # NO TEMPORARY BREAKPOINT. Both entries disabled, no alternate command, no
    # step-over range — so nothing the debugger planted can bring this back.
    payload = (bytes([0]) + _w(0) +
               bytes([0]) + _w(0) +
               bytes([0]) +
               _w(0) + _w(0))
    d.command(CMD_CONTINUE, payload)

    print("RUNNING free at 0x%04X, no breakpoint set; letting it run %.1fs"
          % (DBG_CODE, RUN_SECONDS))
    sys.stdout.flush()
    time.sleep(RUN_SECONDS)

    if NO_PAUSE:
        print("CONTROL no CMD_PAUSE sent; waiting for a notification that must not come")
        try:
            d.wait_notification()
        except Timeout:
            print("RESULT pause OK control: nothing came back with no CMD_PAUSE sent")
        else:
            print("RESULT pause BAD control: a notification arrived with no CMD_PAUSE sent")
        return 0

    # ONE CALL, AND IT IS ORDER-INDEPENDENT BY CONSTRUCTION. Dzrp.command reads
    # frames until it sees the response carrying this command's sequence number,
    # collecting any notification it meets on the way — so it does not matter
    # that the stub emits the NTF_PAUSE first and answers CMD_PAUSE afterwards
    # from cmd_loop. A client that insisted on one order would deadlock against
    # a correct remote in the other.
    problems = []
    try:
        body = d.command(CMD_PAUSE)
    except Timeout:
        print("RESULT pause BAD no response to CMD_PAUSE within %.0fs: the running "
              "debuggee was not stopped" % TIMEOUT)
        return 0
    if body:
        problems.append("CMD_PAUSE answered with a %d-byte payload, expected none" % len(body))

    try:
        ntf = d.wait_notification()
    except Timeout:
        ntf = None

    if ntf is None:
        print("RESULT pause BAD CMD_PAUSE was answered but no NTF_PAUSE arrived: "
              "the running debuggee was not stopped")
        return 0
    if len(ntf) < 6 or ntf[0] != NTF_PAUSE:
        print("RESULT pause BAD notification is %d bytes, id %d, not an NTF_PAUSE"
              % (len(ntf), ntf[0] if ntf else -1))
        return 0

    reason = ntf[1]
    addr = int.from_bytes(ntf[2:4], "little")

    # DIAGNOSTIC, not a verdict: which branch of save_nmi_return_address was
    # entitled to run, and what the hardware captured. NR 0xC0 bit 3 is the
    # stackless-NMI enable and NR 0xC2/0xC3 are the return address the NMI
    # acknowledge latches (zxnext.vhd:2052-2068). MEMORY.md 2026-08-05 records
    # that nothing anywhere had ever distinguished those two branches.
    try:
        c0 = d.command(CMD_GET_TBBLUE_REG, bytes([0xC0]))[0]
        c2 = d.command(CMD_GET_TBBLUE_REG, bytes([0xC2]))[0]
        c3 = d.command(CMD_GET_TBBLUE_REG, bytes([0xC3]))[0]
        print("STATE NR 0xC0=0x%02X (stackless %s), NR 0xC3C2=0x%02X%02X"
              % (c0, "on" if c0 & 0x08 else "OFF", c3, c2))
    except Exception as exc:
        print("STATE could not be read: %s" % exc)

    if reason != BREAK_MANUAL:
        problems.append("break reason %d, expected %d (MANUAL_BREAK)" % (reason, BREAK_MANUAL))
    if addr != SPIN:
        # A STANDING RED AS OF 2026-08-10, AND IT IS NOT "THE BREAK DID NOT
        # HAPPEN". Everything else here passes: CMD_PAUSE is answered, an
        # NTF_PAUSE arrives carrying MANUAL_BREAK, the stub serves on, and the
        # control shows nothing comes back without the pause. What is wrong is
        # the ADDRESS the notification reports.
        #
        # save_nmi_return_address takes the stackless branch (NR 0xC0 bit 3 is
        # set — printed above) and reads NR 0xC2/0xC3, which zxnext.vhd:2060-2063
        # says the NMI acknowledge latches for ANY NMI source. It reads 0x0000.
        # Measured, and left as a red rather than softened: a client told the
        # wrong PC is shown the wrong source line, and a CMD_CONTINUE from a
        # backup.pc of 0 is issue #39's recipe.
        #
        # Whether the fault is the stub's, upstream's or jnext's is UNRESOLVED —
        # note that nothing in this project has ever exercised this branch in an
        # emulator before (MEMORY.md 2026-08-05: C10 sets PC itself), and that
        # the same run shows NR 0xC3C2 holding a DEBUGGER address afterwards,
        # because the poll keeps firing while the debugger is stopped and every
        # acknowledge overwrites the pair.
        problems.append("PC 0x%04X, expected the spin at 0x%04X — the break happened, "
                        "the reported address did not" % (addr, SPIN))

    # Still serving? An exchange AFTER the break, which is what says the stub
    # came back into cmd_loop rather than merely having emitted a notification.
    try:
        d.command(CMD_READ_MEM, b"\x00" + _w(DBG_CODE) + _w(2))
    except (Timeout, OSError) as exc:
        problems.append("the stub stopped serving after the break (%s)" % type(exc).__name__)

    if problems:
        print("RESULT pause BAD %s" % "; ".join(problems))
    else:
        print("RESULT pause OK stopped at 0x%04X, reason %d (MANUAL_BREAK), still serving"
              % (addr, reason))
    return 0


if __name__ == "__main__":
    sys.exit(main())
