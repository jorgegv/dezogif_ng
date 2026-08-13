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
    NTF_PAUSE                it must arrive and carry MANUAL_BREAK.
    CMD_GET_REGISTERS        THE VERDICT: PC must be the fixture's spin and SP
                             its own stack. See below — the PC is NOT in the
                             notification, and reading it from there is what
                             made this check a standing red for a day.
    the Length=1 response    CMD_PAUSE's own answer, which the specification
                             requires and which issue #8 fixed. Read AFTER the
                             notification, because the stub sends the
                             notification first — see below.
    one further command      the stub must still be serving afterwards.

WHERE THE PC IS, AND WHERE IT IS NOT. `NTF_PAUSE`'s payload is
`[id][reason][bp_addr_lo][bp_addr_hi][bank+1][reason string]`
(src/message.asm:342-362), and `bp_addr` is the address of the BREAKPOINT that
caused the stop. `mf_nmi_button_pressed` passes `ld hl,0` (src/mf.asm:169),
because a manual break — button or poll — has no breakpoint. So those two bytes
are 0x0000 by design, on every remote, for every asynchronous break, and the
2026-08-05 hardware capture of a real M1 press recorded exactly that:
`payload=01 01 00 00 00 00`, with the PC arriving separately as `CMD_GET_REGISTERS`
→ 0x801C (MEMORY.md). The PC comes from `backup.pc`, which
`save_nmi_return_address` writes.

So this check reads the PC where the PC is. It ALSO asserts that `bp_addr` is
zero, which is not decoration: a stub that reported a break as though a
breakpoint had caused it would be lying to the client about why it stopped, and
nothing else here would see it.

AND THE PC IS THE ONE THING THAT EXERCISES THE STACKLESS-NMI LATCH. `backup.pc`
on this path can only come from `save_nmi_return_address`, whose stackless
branch reads NR 0xC2/0xC3 — the pair `zxnext.vhd:2054-2070` latches at every NMI
acknowledge. MEMORY.md 2026-08-05 records that nothing anywhere had ever
distinguished that branch from the stack one: C10 sets `PC` itself, and the
hardware manual break of that evening could have come back correct either way.
Here NR 0xC0 is read back and printed, so a green verdict says WHICH branch ran.

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

from dzrp import (CMD_CONTINUE, CMD_GET_REGISTERS,  # noqa: E402
                  CMD_GET_TBBLUE_REG, CMD_INIT,
                  CMD_PAUSE, CMD_READ_MEM, CMD_SET_REGISTER, CMD_WRITE_MEM,
                  Dzrp, NTF_PAUSE, Timeout, init_payload, open_remote)

HOST = os.environ.get("DZRP_HOST", "127.0.0.1")
PORT = int(os.environ.get("DZRP_PORT", "11000"))
TIMEOUT = float(os.environ.get("DZRP_TIMEOUT", "25"))
NO_PAUSE = os.environ.get("W8_NO_PAUSE", "") not in ("", "0")
RUN_SECONDS = float(os.environ.get("W8_RUN_SECONDS", "1.0"))

# W9: the fixture also points the UART select at the OTHER channel before it
# spins, which is what a debuggee using the Raspberry Pi header's UART does.
# Issue #42 — see UART_SELECT below and transport_esp.asm's poll. W8 and W9 are
# the same run differing in this one flag, so a red here is attributable to the
# select and to nothing else.
STEAL_SELECT = os.environ.get("W9_STEAL_SELECT", "") not in ("", "0")

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

# The UART select. Bit 6 picks which of the two UARTs 0x133B/0x143B/0x163B refer
# to; bit 4 clear means this write moves the select and leaves both prescalers
# alone (ports.txt:370-372). 0x40 selects the Pi UART, i.e. the channel the WiFi
# build does NOT own — so this is a debuggee taking a resource the debugger is
# not using, which is the whole point of issue #42.
UART_SELECT = 0x153B
UART_SELECT_OTHER = 0x40


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
    # W9 only: take the UART select for our own channel, exactly as a program
    # using the Pi header's UART would. LAST, so that everything above is
    # byte-identical between the two runs and the spin address is the only
    # thing that moves.
    ((b"\x01" + _w(UART_SELECT) +               # ld bc,0x153B
      b"\x3E" + bytes([UART_SELECT_OTHER]) +    # ld a,0x40
      b"\xED\x79")                              # out (c),a
     if STEAL_SELECT else b"") +
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
    bp_addr = int.from_bytes(ntf[2:4], "little")

    # DIAGNOSTIC, not a verdict: which branch of save_nmi_return_address was
    # ENTITLED to run. NR 0xC0 bit 3 is the stackless-NMI enable, so with it set
    # the PC checked below can only have come from NR 0xC2/0xC3.
    #
    # NR 0xC2/0xC3 ARE PRINTED AND MUST NOT BE JUDGED, and that trap is worth
    # naming because it cost this check a day. By the time anything can ask, the
    # poll has fired many times against the STOPPED debugger and every
    # acknowledge overwrites the pair (zxnext.vhd:2054-2070 latches it on any
    # NMI, from any source). So what is read here is a DEBUGGER address, always,
    # on a perfectly healthy stub. The only readable trace of what the latch held
    # at the break is backup.pc, which is what CMD_GET_REGISTERS returns.
    try:
        c0 = d.command(CMD_GET_TBBLUE_REG, bytes([0xC0]))[0]
        c2 = d.command(CMD_GET_TBBLUE_REG, bytes([0xC2]))[0]
        c3 = d.command(CMD_GET_TBBLUE_REG, bytes([0xC3]))[0]
        print("STATE NR 0xC0=0x%02X (stackless %s); NR 0xC3C2=0x%02X%02X is the "
              "LAST poll's, not the break's" % (c0, "on" if c0 & 0x08 else "OFF", c3, c2))
        stackless = bool(c0 & 0x08)
    except Exception as exc:
        print("STATE could not be read: %s" % exc)
        stackless = None

    if reason != BREAK_MANUAL:
        problems.append("break reason %d, expected %d (MANUAL_BREAK)" % (reason, BREAK_MANUAL))

    # A manual break has no breakpoint, so mf_nmi_button_pressed passes zero
    # (src/mf.asm:169). A remote that put something else there would be telling
    # the client a breakpoint stopped the program when none did.
    if bp_addr != 0:
        problems.append("the notification named breakpoint 0x%04X where a manual break has none"
                        % bp_addr)

    # THE VERDICT. backup.pc on this path is save_nmi_return_address's and
    # nothing else's — the only other writer needs an RST 0 from a breakpoint,
    # and none was planted. SP is checked with it because the stackless NMI must
    # not have pushed anything onto the debuggee's stack; a non-stackless entry
    # that was mis-accounted would show up here as SP two bytes low.
    try:
        regs = d.command(CMD_GET_REGISTERS)
    except (Timeout, OSError) as exc:
        problems.append("CMD_GET_REGISTERS after the break failed (%s)" % type(exc).__name__)
        regs = b""
    if len(regs) >= 4:
        pc = int.from_bytes(regs[0:2], "little")
        sp = int.from_bytes(regs[2:4], "little")
        print("STATE PC=0x%04X SP=0x%04X (spin 0x%04X, stack 0x%04X)"
              % (pc, sp, SPIN, DBG_STACK))
        if pc != SPIN:
            problems.append("stopped at PC 0x%04X, not the spin at 0x%04X" % (pc, SPIN))
        if sp != DBG_STACK:
            problems.append("SP 0x%04X, not the fixture's 0x%04X" % (sp, DBG_STACK))
    elif regs:
        problems.append("CMD_GET_REGISTERS returned %d bytes" % len(regs))

    # Still serving? An exchange AFTER the break, which is what says the stub
    # came back into cmd_loop rather than merely having emitted a notification.
    try:
        d.command(CMD_READ_MEM, b"\x00" + _w(DBG_CODE) + _w(2))
    except (Timeout, OSError) as exc:
        problems.append("the stub stopped serving after the break (%s)" % type(exc).__name__)

    # The join can exceed the ~20-word verdict budget, deliberately and for
    # C10's and C11's reason: these are INDEPENDENT faults — a wrong PC, a
    # corrupted SP, a break reason that is not MANUAL_BREAK, a breakpoint
    # address a manual break cannot have — and a badly broken asynchronous
    # break is exactly the thing that fails on several axes at once. Each
    # single-cause detail above is inside the budget.
    if problems:
        print("RESULT pause BAD %s" % "; ".join(problems))
    else:
        print("RESULT pause OK stopped the spin at 0x%04X, %s NMI, still serving"
              % (SPIN, "stackless" if stackless else "stacked"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
