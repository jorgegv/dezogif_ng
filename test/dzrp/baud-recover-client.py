#!/usr/bin/env python3
"""Make the stub recover, then ask whether it is still serving — issue #25, R4.

WHY THIS EXISTS AND slot-recovery-client.py DOES NOT DO IT. That client fills
every inbound slot on the module before injecting its fault, because its subject
is the AT+CIPCLOSE sweep and a full module is the state it has to be in. Here the
subject is `esp_recover`'s tail — `jp transport_init` — which re-runs the WHOLE
bring-up chain, baud negotiation included. Filling slots would add a variable
this check does not want and would leave the recovery competing with four held
peers for the answer.

THE FAULT IS A TRUNCATED COMMAND, the same trick and the same reason: the stub
blocks in transport_read_byte waiting for bytes that never come, its RX budget
expires, and `rxtx_error` counts it — the only counter ESP_FAULT_LIMIT watches.
jnext answers everything it is asked, so five consecutive faults cannot be
produced here at all; the ROM is built FAULT_LIMIT=1, the seam run-no-hang.sh's
N4 established.

THE CONNECTION IS LEFT OPEN ON PURPOSE. A socket that closes hands its slot back
and gives the module a `<id>,CLOSED` to emit, which is a second stimulus this
check did not ask for.

WHAT IT PRINTS, and the bench greps rather than parses:

    INJECTED         the truncated command went out
    SERVED <n>       a fresh client was answered, on attempt n
    NOTSERVED        nothing answered inside the budget
"""

import argparse
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import dzrp        # noqa: E402


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--host", required=True)
    ap.add_argument("--port", type=int, default=11000)
    ap.add_argument("--timeout", type=float, default=10.0)
    ap.add_argument("--reclaim-timeout", type=float, default=60.0,
                    help="how long to keep asking for a fresh connection")
    args = ap.parse_args()

    # A healthy exchange first, so that a run in which the stub was never
    # serving cannot be read as a run in which the recovery failed. Without it
    # NOTSERVED has two causes and this check cannot tell them apart — probe A's
    # A1 lesson, applied to a gate instead of an instrument.
    try:
        first = dzrp.Dzrp(dzrp.TcpTransport(args.host, args.port, args.timeout),
                          start_byte=None, base_timeout=args.timeout)
        first.command(dzrp.CMD_INIT, dzrp.init_payload())
    except (OSError, dzrp.DzrpError) as e:
        print("PRECONDITION the stub was not serving before the fault: %s: %s"
              % (type(e).__name__, e), flush=True)
        return 3
    print("the stub answered CMD_INIT before the fault was injected", flush=True)

    # An honest header, a length promising four bytes that never arrive.
    frame, _seq = first.build_command(dzrp.CMD_INIT, dzrp.init_payload())
    first.send_raw(frame[:-4])
    print("INJECTED", flush=True)

    # The listener is DOWN for part of a recovery — esp_recover retires it with
    # AT+CIPSERVER=0 before putting it back — so a refused attempt here is
    # expected rather than the answer. Ask until the budget runs out.
    deadline = time.time() + args.reclaim_timeout
    attempts = 0
    while time.time() < deadline:
        attempts += 1
        fresh = None
        try:
            fresh = dzrp.Dzrp(dzrp.TcpTransport(args.host, args.port, 5.0),
                              start_byte=None, base_timeout=5.0)
            fresh.command(dzrp.CMD_INIT, dzrp.init_payload())
            print("SERVED %d" % attempts, flush=True)
            dzrp.send_close_quietly(fresh)
            first.close()
            return 0
        except (OSError, dzrp.DzrpError):
            if fresh is not None:
                try:
                    fresh.close()
                except OSError:
                    pass
            time.sleep(1.0)

    print("NOTSERVED after %d attempts in %.0fs" % (attempts, args.reclaim_timeout),
          flush=True)
    first.close()
    return 1


if __name__ == "__main__":
    sys.exit(main())
