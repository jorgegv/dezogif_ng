#!/usr/bin/env python3
"""Drive the stub to each of the three session states, for bench N1/N2/N3.

    session-client.py silent    open TCP, say nothing at all
    session-client.py init      CMD_INIT, and stop there
    session-client.py close     CMD_INIT, CMD_CLOSE, then one more command

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

The socket is never closed by this fixture. Closing it would make the module
emit `<id>,CLOSED`, and what the stub does with that is precisely what this
feature does NOT claim to track — see esp_client_state in transport_esp.asm.
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


def done():
    print("EXCHANGE_DONE %.3f" % time.time())
    sys.stdout.flush()
    time.sleep(HOLD)
    return 0


def main(argv):
    if len(argv) != 2 or argv[1] not in ("silent", "init", "close"):
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
