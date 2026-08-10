#!/usr/bin/env python3
"""Bench checks W6 and W7: an M1 press while the debugger is STOPPED must not
destroy the state the entry path saves on behalf of a RUNNING debuggee.

TWO CHECKS, ONE PRESS, AND THEY ARE THE SAME DEFECT TWO BYTES APART. mf_rom.asm's
NMI entry path answers "what was the machine like before this NMI?" on EVERY
button press, before the dispatch has decided anything, and writes the answers
where the DEBUGGEE's saved state lives. That is right when the press interrupts a
running debuggee and wrong when the debugger itself is executing.

  W6 (issue #26)  slot_backup.slot7 — the bank in MAIN_SLOT. While the debugger
                  executes that is MAIN_BANK, so the press overwrote the bank
                  dbg_enter saved and the next CMD_CONTINUE would have paged the
                  DEBUGGER's own bank into the debuggee's slot 7.
  W7 (issue #37)  backup.speed and backup.io_next_reg — the clock speed and the
                  NextREG address latch, saved two and eleven instructions later
                  by the same path. While the debugger executes the clock is
                  28 MHz, so the press overwrote the debuggee's speed with the
                  debugger's and the next CMD_CONTINUE handed it back at 28 MHz.

W6 IS OBSERVABLE OVER DZRP AND W7 IS NOT, which is why they read their subjects
by different routes and why #37 shipped with no check at all. CMD_GET_REGISTERS
reports slot 7 from slot_backup.slot7 — the last byte of the 37-byte payload,
the only one of the eight read from memory rather than from an MMU register. It
reports neither the turbo mode nor the NextREG latch, and nothing else in the
protocol does either. So W7 reads the bytes out of the debugger's own bank
DIRECTLY, by borrowing an MMU slot, exactly as conformance.py's C22/C23 do:
MAIN_BANK at slot PROBE_SLOT puts 0xFCxx at 0xBCxx, below 0xE000, so CMD_READ_MEM
takes memory_loop's phase 2 and reaches the byte with no swap window involved.

THE ADDRESSES COME FROM THE BUILD, NOT FROM THIS FILE. backup.speed moves with
every change to the debugger's data, so a constant here would go stale silently
and read some neighbouring byte that never changes — a green check that cannot
fail. The bench greps them out of the assembler's own label table (--lstlab) and
passes them in; a miss fails the run rather than this check.

THE SEQUENCE, and the reason for each step:

    CMD_INIT                 cmd_init RESETS slot_backup.slot7 to 1, so it has
                             to come first — sending it later would erase the
                             evidence, the same way it erases last_error for
                             the screen reader (MEMORY.md 2026-08-06).
    CMD_SET_SLOT 7 = BANK    slot 7 is handled specially by cmd_set_slot: it
                             changes no MMU register, it writes ONLY the saved
                             value. So this is a direct, legitimate way to put
                             a known bank where a stopped debuggee's would be.
    CMD_GET_REGISTERS        PRECONDITION. If the set did not take, everything
                             after it is meaningless and this reports a harness
                             fault rather than a stub fault.
    the slot-5 borrow        W7's "before" reading, and its own PRECONDITION:
                             see BOTH BYTES MUST BE ABLE TO CHANGE below.
    (the M1 press lands)     Announced by the bench through the sentinel file:
                             see below.
    CMD_GET_REGISTERS        W6's verdict. Pre-fix this reads 94 (MAIN_BANK);
                             fixed, it still reads BANK.
    the slot-5 borrow again  W7's verdict. Both bytes must be what they were.

BANK IS 30 AND MUST BE NEITHER 1 NOR 94. 1 is what cmd_init leaves, so a stub
that ignored CMD_SET_SLOT entirely would look unchanged across the press; 94 is
MAIN_BANK, the value the defect writes, so it must not be the one we asked for.

BOTH BYTES MUST BE ABLE TO CHANGE, AND ONLY ONE OF THEM IS GUARANTEED TO.
W6's equivalent of this is the paragraph above; W7's is a runtime precondition,
because the values are the stub's rather than ours to choose.

  * backup.speed is the discriminating half. main's prologue sets it to
    RTM_3MHZ (0) and nothing else writes it until a debuggee is resumed, while
    init_main_bank leaves the machine at RTM_28MHZ (3) and the debugger idles
    there — so a defective stub writes 3 over 0. If it ALREADY reads 3 before
    the press there is nothing the defect could change and this refuses to
    render a verdict at all, rather than passing.
  * backup.io_next_reg turned out to discriminate as reliably, for a reason
    nobody expected and which is worth knowing separately: the entry path's own
    cause check does `out (c),REG_RESET` to select NR 0x02 BEFORE the
    instruction that claims to "backup contents of IO_NEXTREG_REG" reads the
    latch back — so what it saves is always REG_RESET (2), never whatever the
    debuggee had. Measured, 0x00 -> 0x02. That is a second, pre-existing defect
    in the same three instructions, out of scope for #37 and harmless in
    practice (any code that writes a NextREG selects it first), and it is not
    what this asserts. This asserts the byte is unchanged, which is the property
    #37 is about, and it is the speed byte that carries the guarantee.

AND THE TUPLE COMPARISON IS WHAT MAKES THAT ROBUST TO A `drain_main`, which is
the one residual way the speed byte alone could report a false green: drain_main
falls into main, whose prologue rewrites backup.speed to RTM_3MHZ — so a drain
landing between the press and the second read would put the "before" value back
on a defective ROM. main does NOT touch backup.io_next_reg, so the REG_RESET
witness still fires and the pair still differs. Both bytes are compared for that
reason as well as because both must be intact.

THE PRESS HAS TO LAND BETWEEN THE TWO READS, AND THE TWO EDGES OF THAT WINDOW
ARE HELD BY DIFFERENT MEANS. Getting this wrong is how the check fails green,
so it is worth being exact about which is which:

  * the RIGHT edge is guaranteed. The bench watches jnext's own log for the
    second "Delayed NMI button ... pressed" line and only then touches the
    sentinel this client is waiting on, so the second read cannot precede the
    press. Sleeping instead would be a guess — jnext counts emulated frames
    while this client counts wall clock, and the frame rate collapses under
    DZRP traffic.
  * the LEFT edge is a MARGIN plus an assertion, not a guarantee. Nothing
    stops a press scheduled too early from landing before CMD_SET_SLOT takes
    effect — and that direction is the dangerous one, because CMD_SET_SLOT
    would then overwrite whatever a corrupting press had just written, leaving
    no second press to observe and reporting before=30 after=30 on a broken
    ROM. An earlier version of this file called both edges "by construction"
    and was wrong: measured across two runs of the identical script on an idle
    machine, the margin was 149 ms in one and 2 ms in the other. The bench now
    widens the schedule AND asserts from the log that every setup command had
    arrived before the press, so losing the margin fails RED.

The bench asserts the press count from the log after the run too, for the same
reason W4 asserts its collision: a precondition nobody checked is a check that
can pass having tested nothing.

Idling here also costs nothing and is realistic: transport_wait_rx's bound
(issue #16) expires after five seconds and the stub drops back to main_loop
with prgm_state untouched, which is exactly where a user's finger finds it.

THE EXIT CODE SAYS WHETHER A VERDICT WAS REACHED, NOT WHETHER IT PASSED. Two
checks share one run, so one number cannot carry both; the bench reads the
RESULT lines below. Exit 0 means both verdicts were rendered and are on stdout,
and 1 means a precondition stopped the run before that — in which case NEITHER
check has been tested and the bench must say so for both.

Environment: DZRP_HOST, DZRP_PORT, SENTINEL, BACKUP_SPEED_ADDR and
BACKUP_IO_NEXT_REG_ADDR (all required), plus DZRP_TIMEOUT and SENTINEL_TIMEOUT.
"""
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from dzrp import (CMD_GET_REGISTERS, CMD_INIT, CMD_READ_MEM,  # noqa: E402
                  CMD_SET_SLOT, Dzrp, init_payload, open_remote)

HOST = os.environ.get("DZRP_HOST", "127.0.0.1")
PORT = int(os.environ.get("DZRP_PORT", "11000"))
TIMEOUT = float(os.environ.get("DZRP_TIMEOUT", "25"))
SENTINEL = os.environ.get("SENTINEL", "")
SENTINEL_TIMEOUT = float(os.environ.get("SENTINEL_TIMEOUT", "300"))

BANK = 30
MAIN_BANK = 94

# REG_TURBO_MODE DOES NOT READ BACK WHAT WAS WRITTEN, AND AN EARLIER VERSION OF
# THIS FILE ASSUMED IT DID. `port_253b_dat <= "00" & cpu_speed & "00" &
# nr_07_cpu_speed` (zxnext.vhd:5903) puts the ACTUAL speed in bits 5:4 and the
# PROGRAMMED one in bits 1:0, while a write takes only bits 1:0 (:5789). So
# 28 MHz reads back as 0x33 and not 0x03 — measured against the pre-fix ROM,
# which is also what caught the assumption.
#
# Only bits 1:0 decide what a restore does, so that is what the precondition
# below masks: a stored byte already SELECTING 28 MHz is one the defect could
# not change, and this refuses to render a verdict on it.
RTM_MASK = 0x03
RTM_28MHZ = 0x03

# MMU slot 5 is 0xA000-0xBFFF. C22/C23 borrow the same one, and for the same
# two reasons: slot 4 is where that suite's fixture lives, and an address below
# 0xE000 reaches memory_loop's direct path rather than the swap window. Nothing
# else in THIS run touches either slot — it is a single client with no
# conformance suite behind it.
PROBE_SLOT = 5

# CMD_GET_REGISTERS's PAYLOAD is 37 bytes: 14 register words (28), a slot count
# (1), then the eight slot values (8). commands.asm says `ld de,38` because a
# response's length field counts from the SEQUENCE byte — the two directions
# use different length conventions, which dzrp.py's header sets out and which
# has now cost this project twice. Slot 7 is the last byte, and the only one of
# the eight read from memory rather than from an MMU register.
REGS_PAYLOAD = 37
SLOT_BASE = 29
SLOT7 = -1


def env_addr(name):
    """An address in MAIN_SLOT, from the bench's grep of the label table.

    Refused rather than defaulted: a missing or nonsensical value would make
    this read some other byte, and a byte nothing writes is a check that cannot
    fail.
    """
    raw = os.environ.get(name, "")
    try:
        addr = int(raw, 0)
    except ValueError:
        raise SystemExit("PRECONDITION %s is not an address: %r" % (name, raw))
    if not 0xE000 <= addr <= 0xFFFF:
        raise SystemExit("PRECONDITION %s = 0x%04X is not in MAIN_SLOT" % (name, addr))
    return addr


SAVED = (("speed", env_addr("BACKUP_SPEED_ADDR")),
         ("io_next_reg", env_addr("BACKUP_IO_NEXT_REG_ADDR")))


def slot7_of(body):
    if len(body) != REGS_PAYLOAD:
        raise SystemExit("PRECONDITION CMD_GET_REGISTERS answered %d payload bytes, expected %d"
                         % (len(body), REGS_PAYLOAD))
    return body[SLOT7]


def peek_saved(d):
    """Read the debuggee's saved bytes out of MAIN_BANK, over the wire.

    The slot is put back from what CMD_GET_REGISTERS reported for it, which for
    slots 0-6 is read LIVE from the MMU rather than from the stub's bookkeeping.
    """
    body = d.command(CMD_GET_REGISTERS)
    if len(body) != REGS_PAYLOAD:
        raise SystemExit("PRECONDITION CMD_GET_REGISTERS answered %d payload bytes, expected %d"
                         % (len(body), REGS_PAYLOAD))
    was = body[SLOT_BASE + PROBE_SLOT]
    d.command(CMD_SET_SLOT, bytes([PROBE_SLOT, MAIN_BANK]))
    try:
        # THE BORROW IS ASSERTED, NOT ASSUMED, and without this the check has a
        # silent false green: a CMD_SET_SLOT that did nothing would leave the
        # DEBUGGEE's bank there, both readings would come from it, they would
        # agree, and W7 would pass against a stub with the defect intact. Slots
        # 0-6 are reported live from the MMU, so this observes the register
        # rather than the stub's bookkeeping.
        body = d.command(CMD_GET_REGISTERS)
        if body[SLOT_BASE + PROBE_SLOT] != MAIN_BANK:
            raise SystemExit("PRECONDITION MMU slot %d reads %d after being set to MAIN_BANK "
                             "(%d): the borrow did not take"
                             % (PROBE_SLOT, body[SLOT_BASE + PROBE_SLOT], MAIN_BANK))
        out = []
        for _, addr in SAVED:
            probe = PROBE_SLOT * 0x2000 + (addr & 0x1FFF)
            body = d.command(CMD_READ_MEM,
                             bytes([0]) + probe.to_bytes(2, "little") + (1).to_bytes(2, "little"))
            if len(body) != 1:
                raise SystemExit("PRECONDITION CMD_READ_MEM answered %d bytes, expected 1"
                                 % len(body))
            out.append(body[0])
        return tuple(out)
    finally:
        d.command(CMD_SET_SLOT, bytes([PROBE_SLOT, was]))


def saved_str(before, after):
    return " ".join("%s=0x%02x/0x%02x" % (name, b, a)
                    for (name, _), b, a in zip(SAVED, before, after))


def await_sentinel():
    """Block until the bench says the M1 press has been delivered."""
    if not SENTINEL:
        raise SystemExit("PRECONDITION no SENTINEL set: the press cannot be located in time")
    deadline = time.time() + SENTINEL_TIMEOUT
    while time.time() < deadline:
        if os.path.exists(SENTINEL) and os.path.getsize(SENTINEL) > 0:
            return True
        time.sleep(0.2)
    return False


def main():
    d = Dzrp(open_remote("tcp:%s:%d" % (HOST, PORT), timeout=TIMEOUT),
             start_byte=None, base_timeout=TIMEOUT)

    d.command(CMD_INIT, init_payload(name="dezogif_ng-nmi-while-stopped"))
    d.command(CMD_SET_SLOT, bytes([7, BANK]))

    slot7_before = slot7_of(d.command(CMD_GET_REGISTERS))
    if slot7_before != BANK:
        print("PRECONDITION CMD_SET_SLOT did not take: slot 7 reads %d, wanted %d"
              % (slot7_before, BANK))
        return 1

    saved_before = peek_saved(d)
    if saved_before[0] & RTM_MASK == RTM_28MHZ:
        print("PRECONDITION backup.speed 0x%02x already selects 28 MHz, which is what a "
              "press would write: nothing to observe" % saved_before[0])
        return 1

    print("ARMED slot 7 = %d, %s, waiting for the M1 press"
          % (slot7_before, saved_str(saved_before, saved_before)))
    sys.stdout.flush()

    if not await_sentinel():
        print("PRECONDITION the bench never signalled the M1 press; nothing was judged")
        return 1

    slot7_after = slot7_of(d.command(CMD_GET_REGISTERS))
    saved_after = peek_saved(d)

    # OK/BAD IS THE VERDICT AND THE BENCH ONLY RELAYS IT. It is decided here,
    # beside the values, rather than re-derived from the printed numbers by a
    # shell pattern — two renderings of one fact are how they drift apart.
    print("RESULT slot7 %s before=%d after=%d"
          % ("OK" if slot7_after == slot7_before else "BAD", slot7_before, slot7_after))
    print("RESULT saved %s %s"
          % ("OK" if saved_after == saved_before else "BAD",
             saved_str(saved_before, saved_after)))

    if slot7_after == MAIN_BANK:
        print("the press overwrote the debuggee's bank with MAIN_BANK: continue would "
              "page the debugger's own bank into slot 7")
    if saved_after[0] & RTM_MASK == RTM_28MHZ:
        print("the press overwrote the debuggee's saved clock speed with the debugger's "
              "28 MHz: continue would hand it back at the wrong speed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
