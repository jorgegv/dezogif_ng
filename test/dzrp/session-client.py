#!/usr/bin/env python3
"""Drive the stub to each of the session states, for bench N1-N5.

    session-client.py silent        open TCP, say nothing at all
    session-client.py init          CMD_INIT, and stop there
    session-client.py close         CMD_INIT, CMD_CLOSE, then one more command
    session-client.py vanish        CMD_INIT, then drop the socket — no CMD_CLOSE
    session-client.py vanish-idle   the same, but only after the stub has gone
                                    back to its idle loop

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

WHY THE FIRST THREE PHASES NEVER CLOSE THE SOCKET, and the last two exist to.
Closing it makes the module emit `<id>,CLOSED`, and until issue #23 the stub did
not look at that line at all — so N1-N3 hold their connections open precisely to
keep an event they could not see out of the runs that are not about it. The two
phases below are the other half: they drop the socket WITHOUT sending CMD_CLOSE,
which is what a crashed client, a suspended laptop or a dropped link produce, and
the screen must stop claiming the session that ended.

THE TWO OF THEM DIFFER ONLY IN WHERE THE STUB IS STANDING WHEN IT HAPPENS, and
that is the whole reason there are two. `vanish` drops the socket at once, so the
stub is inside cmd_loop's transport_wait_rx and the scan that meets the
`<id>,CLOSED` then finds no header, times out and reaches drain_main — whose
show_ui is what redraws the row. `vanish-idle` waits first, long enough for that
wait's own bound to expire into main_loop, so the line arrives at the idle poll
instead, where nothing times out and nothing reports: there the ONLY thing that
can redraw the row is esp_refresh_client_line. The bench tells the two apart by
the stub's error area — see run-client-status.sh.
"""
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from dzrp import (CMD_CLOSE, CMD_INIT, CMD_LOOPBACK,  # noqa: E402
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


def done():
    print("EXCHANGE_DONE %.3f" % time.time())
    sys.stdout.flush()
    time.sleep(HOLD)
    return 0


PHASES = ("silent", "init", "close", "vanish", "vanish-idle")


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
