#!/usr/bin/env python3
"""Bench check W6: an M1 press while the debugger is STOPPED must not destroy
the debuggee's saved slot-7 bank.

THE DEFECT THIS EXISTS FOR (issue #26, the second of its family). mf_rom.asm's
NMI entry path reads the bank in MAIN_SLOT and stores it, on EVERY button
press, before the dispatch has decided anything. That is right when the press
interrupts a RUNNING debuggee — slot 7 holds the debuggee's bank and saving it
is the whole point. It is wrong when the debugger itself is executing, because
then slot 7 holds MAIN_BANK: the store overwrote the debuggee's bank, which
dbg_enter had saved when the breakpoint was taken, with the debugger's own.
The next CMD_CONTINUE would page the DEBUGGER's bank into the debuggee's
slot 7 — restore_registers reads that byte (backup.asm) and exit_code_di
installs it (breakpoints.asm).

WHY IT IS OBSERVABLE OVER A SOCKET AT ALL, which is what makes this a bench
check rather than a hardware story: CMD_GET_REGISTERS reports slot 7 from
slot_backup.slot7, not from the MMU — it is the last byte of the 38-byte
response (commands.asm, "Get and send slot 7"). So the corruption can be read
back through the same protocol that caused it, with no screenshot and no
emulator introspection.

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
    (the M1 press lands)     Announced by the bench through the sentinel file:
                             see below.
    CMD_GET_REGISTERS        THE CHECK. Pre-fix this reads 94 (MAIN_BANK);
                             fixed, it still reads BANK.

BANK IS 30 AND MUST BE NEITHER 1 NOR 94. 1 is what cmd_init leaves, so a stub
that ignored CMD_SET_SLOT entirely would look unchanged across the press; 94 is
MAIN_BANK, the value the defect writes, so it must not be the one we asked for.

THE SENTINEL IS WHAT STOPS THIS PASSING VACUOUSLY, and it is not a convenience.
The press has to land BETWEEN the two reads. jnext schedules it in emulated
frames while this client counts wall clock, and the frame rate collapses under
DZRP traffic — so sleeping "long enough" would be a guess that fails in the
green direction: a press arriving after the second read leaves a broken stub
looking clean. Instead the bench watches jnext's own log for the second
"Delayed NMI button ... pressed" line and only then touches the sentinel, so
the press is inside the window by construction. The bench asserts the count
from the log again after the run, for the same reason W4 does.

Idling here also costs nothing and is realistic: transport_wait_rx's bound
(issue #16) expires after five seconds and the stub drops back to main_loop
with prgm_state untouched, which is exactly where a user's finger finds it.

Environment: DZRP_HOST, DZRP_PORT, SENTINEL (required), plus SENTINEL_TIMEOUT.
Prints one RESULT line the bench parses, and exits 0 only if the bank survived.
"""
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from dzrp import (CMD_GET_REGISTERS, CMD_INIT, CMD_SET_SLOT,  # noqa: E402
                  Dzrp, init_payload, open_remote)

HOST = os.environ.get("DZRP_HOST", "127.0.0.1")
PORT = int(os.environ.get("DZRP_PORT", "11000"))
TIMEOUT = float(os.environ.get("DZRP_TIMEOUT", "25"))
SENTINEL = os.environ.get("SENTINEL", "")
SENTINEL_TIMEOUT = float(os.environ.get("SENTINEL_TIMEOUT", "300"))

BANK = 30
MAIN_BANK = 94

# CMD_GET_REGISTERS's PAYLOAD is 37 bytes: 14 register words (28), a slot count
# (1), then the eight slot values (8). commands.asm says `ld de,38` because a
# response's length field counts from the SEQUENCE byte — the two directions
# use different length conventions, which dzrp.py's header sets out and which
# has now cost this project twice. Slot 7 is the last byte, and the only one of
# the eight read from memory rather than from an MMU register.
REGS_PAYLOAD = 37
SLOT7 = -1


def slot7_of(body):
    if len(body) != REGS_PAYLOAD:
        raise SystemExit("PRECONDITION CMD_GET_REGISTERS answered %d payload bytes, expected %d"
                         % (len(body), REGS_PAYLOAD))
    return body[SLOT7]


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

    before = slot7_of(d.command(CMD_GET_REGISTERS))
    if before != BANK:
        print("PRECONDITION CMD_SET_SLOT did not take: slot 7 reads %d, wanted %d"
              % (before, BANK))
        return 1
    print("ARMED slot 7 = %d, waiting for the M1 press" % before)
    sys.stdout.flush()

    if not await_sentinel():
        print("PRECONDITION the bench never signalled the M1 press; nothing was judged")
        return 1

    after = slot7_of(d.command(CMD_GET_REGISTERS))
    print("RESULT before=%d after=%d" % (before, after))

    if after == before:
        return 0
    if after == MAIN_BANK:
        print("the press overwrote the debuggee's bank with MAIN_BANK: continue would "
              "page the debugger's own bank into slot 7")
    return 1


if __name__ == "__main__":
    sys.exit(main())
