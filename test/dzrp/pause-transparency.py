#!/usr/bin/env python3
"""A LONG FREE RUN UNDER THE ASYNCHRONOUS-BREAK POLL, THEN A PAUSE.

W8 resumes a debuggee, lets it run for ONE SECOND, and pauses it. That proves
the break works; it says almost nothing about the poll being TRANSPARENT,
because fifty NMIs is not a sample. This runs the same shape for minutes — 3000
polls a minute — with a debuggee that checks, on every pass, whether it was
given its machine back.

WHAT IS BEING TESTED IS THE DEBUGGEE'S OWN VERDICT, not this client's. The
fixture (test/pause_transparency.asm) watches the two pieces of state the poll
path disturbs and must restore: MMU slot 7, and the NextREG select latch. It
records the FIRST fault with the iteration it landed on, and keeps running so
that the pause can still be tested in the run that found one. This client
loads it, resumes it with no breakpoint, waits, pauses, and reads the record
back.

THREE THINGS ARE JUDGED, AND THEY FAIL INDEPENDENTLY:

  the fixture's record    slot 7 and the latch, ~50 times a second for the
                          whole run. This is the subject.
  the debuggee's memory   a canary the fixture never touches, read back after
                          the break. The poll runs on the debuggee's machine
                          with the debugger's bank paged in; nothing should
                          have been written outside the debugger's own bank.
  the break itself        MANUAL_BREAK, a PC inside the fixture, and an SP the
                          stackless NMI has not pushed onto.

THE COUNTER IS REPORTED, NOT ASSERTED BEYOND "IT RAN". A rate depends on the
clock the debuggee happens to be at and on what else the machine is doing, so
a tight bound would be a check of the machine's mood. What is asserted is that
it is large enough to mean the program really ran; the rate is printed as a
measurement, next to how many times the poll is expected to have fired.

THE ADDRESSES BELOW ARE PINNED BY ASSERTS IN THE FIXTURE, not agreed by
convention: test/pause_transparency.asm fails to build if `results` moves off
0x9000 or its layout changes size, which is what stops this client reading a
byte nothing writes and reporting a green it did not earn.

Environment: DZRP_HOST, DZRP_PORT, DZRP_TIMEOUT, PT_RUN_SECONDS, PT_BIN.
Exit 0 means a verdict was rendered and is on stdout as a RESULT line; 1 means
a precondition stopped the run before that, in which case nothing was judged.
"""
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from dzrp import (CMD_CLOSE, CMD_CONTINUE, CMD_GET_REGISTERS,  # noqa: E402
                  CMD_GET_TBBLUE_REG, CMD_INIT, CMD_PAUSE, CMD_READ_MEM,
                  CMD_SET_REGISTER, CMD_WRITE_MEM, Dzrp, NTF_PAUSE, Timeout,
                  init_payload, open_remote)

HOST = os.environ.get("DZRP_HOST", "127.0.0.1")
PORT = int(os.environ.get("DZRP_PORT", "11000"))
TIMEOUT = float(os.environ.get("DZRP_TIMEOUT", "25"))
RUN_SECONDS = float(os.environ.get("PT_RUN_SECONDS", "60"))

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_BIN = os.path.join(HERE, "..", "..", "build", "pause-transparency.bin")
BIN = os.environ.get("PT_BIN", DEFAULT_BIN)

# Inside 0x8000-0x9FFF, which CMD_INIT maps to bank 4 — the window
# conformance.py's own fixture uses, and clear of the debugger's slots 6 and 7.
DBG_CODE = 0x8000
DBG_STACK = 0x9F00

# test/pause_transparency.asm's ORG and layout, both ASSERTed there.
RESULTS = 0x9000
RESULTS_LEN = 13

# Between the results and the stack, and never touched by the fixture.
CANARY = 0x9100
CANARY_LEN = 256

REG_PC, REG_SP = 0, 1
BREAK_MANUAL = 1

# test/pause_transparency.asm's FAULT_* codes.
FAULTS = {
    1: "the NextREG select latch was not restored",
    2: "the CPU clock speed changed under the debuggee",
    3: "MMU slot 7 was not restored",
    4: "BLIND: the watch register reads the probe bank, so the latch check "
       "could not have seen a fault either way",
}

# The Copper list fires once per frame. 50 Hz is the timing this project
# assumes throughout; it is used only to say how many polls a run covered.
FRAMES_PER_SECOND = 50


def _w(v):
    return v.to_bytes(2, "little")


def _u32(b):
    return int.from_bytes(b, "little")


def main():
    try:
        with open(BIN, "rb") as fh:
            fixture = fh.read()
    except OSError as exc:
        print("PRECONDITION cannot read the fixture %s (%s) — run `make "
              "pause-transparency` first" % (BIN, exc))
        return 1
    if not fixture:
        print("PRECONDITION the fixture %s is empty" % BIN)
        return 1

    d = Dzrp(open_remote("tcp:%s:%d" % (HOST, PORT), timeout=TIMEOUT),
             start_byte=None, base_timeout=TIMEOUT)

    d.command(CMD_INIT, init_payload(name="dezogif_ng-pause-transparency"))

    # The fixture, read back before it is trusted: one that did not land would
    # make everything after it meaningless.
    d.command(CMD_WRITE_MEM, b"\x00" + _w(DBG_CODE) + fixture)
    back = d.command(CMD_READ_MEM, b"\x00" + _w(DBG_CODE) + _w(len(fixture)))
    if back != fixture:
        same = sum(1 for a, b in zip(back, fixture) if a == b)
        print("PRECONDITION the fixture did not land at 0x%04X (%d of %d bytes match)"
              % (DBG_CODE, same, len(fixture)))
        return 1

    # The canary. Not zero-free by accident: a pattern that repeats every 256
    # bytes would make a shifted write look identical, so it is index-dependent.
    canary = bytes(((i * 7) + 0x5A) & 0xFF for i in range(CANARY_LEN))
    d.command(CMD_WRITE_MEM, b"\x00" + _w(CANARY) + canary)
    if d.command(CMD_READ_MEM, b"\x00" + _w(CANARY) + _w(CANARY_LEN)) != canary:
        print("PRECONDITION the canary did not land at 0x%04X" % CANARY)
        return 1

    d.command(CMD_SET_REGISTER, bytes([REG_PC]) + _w(DBG_CODE))
    d.command(CMD_SET_REGISTER, bytes([REG_SP]) + _w(DBG_STACK))

    # NO TEMPORARY BREAKPOINT: both entries disabled, no alternate command, no
    # step-over range. Nothing the debugger planted can bring this back, which
    # is what makes the pause the only candidate for having stopped it.
    d.command(CMD_CONTINUE, bytes([0]) + _w(0) + bytes([0]) + _w(0) +
                            bytes([0]) + _w(0) + _w(0))

    expected_polls = int(RUN_SECONDS * FRAMES_PER_SECOND)
    print("RUNNING free at 0x%04X with no breakpoint, for %.0fs — the poll should "
          "fire about %d times" % (DBG_CODE, RUN_SECONDS, expected_polls))
    sys.stdout.flush()

    # Progress, because a silent minute reads as a hang. Ten dots, whatever the
    # run length.
    step = RUN_SECONDS / 10.0
    started = time.time()
    for _ in range(10):
        time.sleep(step)
        sys.stdout.write(".")
        sys.stdout.flush()
    ran_for = time.time() - started
    print("")

    problems = []

    # One call, order-independent: Dzrp.command reads frames until it sees this
    # command's sequence number and collects any notification on the way, so it
    # does not matter that the stub emits the NTF_PAUSE first and answers
    # CMD_PAUSE afterwards from cmd_loop.
    try:
        body = d.command(CMD_PAUSE)
    except Timeout:
        print("RESULT transparency BAD no response to CMD_PAUSE within %.0fs: the "
              "running debuggee was not stopped" % TIMEOUT)
        return 0
    if body:
        problems.append("CMD_PAUSE answered with a %d-byte payload, expected none"
                        % len(body))

    try:
        ntf = d.wait_notification()
    except Timeout:
        ntf = None
    if ntf is None:
        print("RESULT transparency BAD CMD_PAUSE was answered but no NTF_PAUSE "
              "arrived: the running debuggee was not stopped")
        return 0
    if len(ntf) < 6 or ntf[0] != NTF_PAUSE:
        print("RESULT transparency BAD notification is %d bytes, id %d, not an NTF_PAUSE"
              % (len(ntf), ntf[0] if ntf else -1))
        return 0

    if ntf[1] != BREAK_MANUAL:
        problems.append("break reason %d, expected %d (MANUAL_BREAK)"
                        % (ntf[1], BREAK_MANUAL))

    # THE FIXTURE'S OWN VERDICT, which is the subject of this check.
    try:
        rec = d.command(CMD_READ_MEM, b"\x00" + _w(RESULTS) + _w(RESULTS_LEN))
    except (Timeout, OSError) as exc:
        print("RESULT transparency BAD could not read the fixture's record after the "
              "break (%s)" % type(exc).__name__)
        return 0
    if len(rec) != RESULTS_LEN:
        print("RESULT transparency BAD the record is %d bytes, expected %d"
              % (len(rec), RESULTS_LEN))
        return 0

    iterations = _u32(rec[0:4])
    fault = rec[4]
    fault_at = _u32(rec[5:9])
    observed, expected = rec[9], rec[10]
    watch_expect, slot7_expect = rec[11], rec[12]

    rate = iterations / ran_for if ran_for > 0 else 0
    print("STATE %d iterations in %.1fs (%.0f/s); NR 0x07 read 0x%02X, MMU7 read %d"
          % (iterations, ran_for, rate, watch_expect, slot7_expect))

    if fault:
        problems.append("the debuggee reports %s at iteration %d (read 0x%02X, "
                        "expected 0x%02X)"
                        % (FAULTS.get(fault, "fault code %d" % fault),
                           fault_at, observed, expected))

    # It must actually have run. A tiny count means it was stopped almost at
    # once — a real finding, and one the fault code cannot express.
    if iterations < 1000:
        problems.append("only %d iterations: the debuggee barely ran" % iterations)

    # THE BREAK ITSELF. The PC must be inside the fixture, and the bound comes
    # from the image just loaded rather than from a number written here.
    try:
        regs = d.command(CMD_GET_REGISTERS)
    except (Timeout, OSError) as exc:
        problems.append("CMD_GET_REGISTERS after the break failed (%s)"
                        % type(exc).__name__)
        regs = b""
    if len(regs) >= 4:
        pc = int.from_bytes(regs[0:2], "little")
        sp = int.from_bytes(regs[2:4], "little")
        print("STATE PC=0x%04X SP=0x%04X (fixture 0x%04X-0x%04X, stack 0x%04X)"
              % (pc, sp, DBG_CODE, DBG_CODE + len(fixture) - 1, DBG_STACK))
        if not (DBG_CODE <= pc < DBG_CODE + len(fixture)):
            problems.append("stopped at PC 0x%04X, outside the fixture" % pc)
        if sp != DBG_STACK:
            problems.append("SP 0x%04X, not the fixture's 0x%04X" % (sp, DBG_STACK))
    elif regs:
        problems.append("CMD_GET_REGISTERS returned %d bytes" % len(regs))

    # The debuggee's memory. The poll pages the debugger's own bank in to reach
    # its image; a write that escaped it would land here.
    try:
        after = d.command(CMD_READ_MEM, b"\x00" + _w(CANARY) + _w(CANARY_LEN))
    except (Timeout, OSError) as exc:
        problems.append("the canary could not be read back (%s)" % type(exc).__name__)
        after = canary
    if after != canary:
        first = next((i for i, (a, b) in enumerate(zip(after, canary)) if a != b), 0)
        changed = sum(1 for a, b in zip(after, canary) if a != b)
        problems.append("%d of %d canary bytes changed, first at 0x%04X"
                        % (changed, CANARY_LEN, CANARY + first))

    # Diagnostic, never a verdict: NR 0xC2/0xC3 hold the LAST poll's address by
    # the time anything can ask, because the poll keeps firing at the stopped
    # debugger. NR 0xC0 bit 3 says which branch of save_nmi_return_address was
    # entitled to run.
    try:
        c0 = d.command(CMD_GET_TBBLUE_REG, bytes([0xC0]))[0]
        print("STATE NR 0xC0=0x%02X (stackless %s)"
              % (c0, "on" if c0 & 0x08 else "OFF"))
    except Exception as exc:
        print("STATE NR 0xC0 could not be read: %s" % exc)

    # Still serving, AFTER everything above — an exchange the stub has to
    # answer from cmd_loop rather than merely a notification it emitted.
    try:
        d.command(CMD_READ_MEM, b"\x00" + _w(DBG_CODE) + _w(2))
    except (Timeout, OSError) as exc:
        problems.append("the stub stopped serving after the break (%s)"
                        % type(exc).__name__)

    # Leave the machine saying the session ended, rather than dropping the
    # socket and leaving it reading "Session lost - client gone".
    try:
        d.command(CMD_CLOSE)
    except (Timeout, OSError):
        pass

    # The join can exceed the ~20-word verdict budget, deliberately and for
    # C10's and C11's reason: these are INDEPENDENT faults — the debuggee's own
    # detector, its memory, the PC, the SP — and a poll that is not transparent
    # is exactly the thing that fails on several axes at once.
    if problems:
        print("RESULT transparency BAD %s" % "; ".join(problems))
    else:
        print("RESULT transparency OK %d iterations over %.0fs, about %d polls, "
              "nothing disturbed" % (iterations, ran_for, expected_polls))
    return 0


if __name__ == "__main__":
    sys.exit(main())
