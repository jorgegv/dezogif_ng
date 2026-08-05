#!/usr/bin/env python3
"""One DZRP exchange, judged only on whether it completed.

The client half of test/run-tx-patience.sh. It sends CMD_INIT and then one
CMD_LOOPBACK large enough to need several AT+CIPSEND chunks, and reports
whether both came back. That is deliberately the whole of it: the bench's
subject is a TIMEOUT, so the only question worth asking here is "did the stub
answer at all", and every other DZRP property is already covered by
conformance.py.

WHY THE LOOPBACK HAS TO BE BIG. The stub buffers its response and pushes it out
in ESP_TX_CHUNK (240) byte chunks, each one an AT+CIPSEND with two waits the
module owes an answer to. A short reply is one chunk and one pair of waits; a
1024-byte reply is five, and the wait after a full chunk is the long one,
because the module only says SEND OK once it has taken all 240 bytes — 240 byte
times at 115200 is ~21 ms, against ~2 ms for a 25-byte reply. So the small
exchange sits near the boundary and the big one is well past it, which is why
CMD_INIT sometimes survives an injected budget that the loopback never does.

EXIT CODE IS THE VERDICT: 0 only if both exchanges completed and the loopback
came back byte-identical.
"""

import argparse
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import dzrp                                          # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=11000)
    ap.add_argument("--timeout", type=float, default=20.0)
    ap.add_argument("--size", type=int, default=1024,
                    help="CMD_LOOPBACK payload; must exceed ESP_TX_CHUNK (240) "
                         "so the reply needs several AT+CIPSEND round trips")
    args = ap.parse_args()

    try:
        t = dzrp.TcpTransport(args.host, args.port, args.timeout)
    except Exception as e:                          # noqa: BLE001
        print("could not connect to %s:%d — %s" % (args.host, args.port, e))
        return 2

    # No 0xA5 preamble: this is the WiFi build, where the byte is absent by
    # design (transport_esp.asm, point 1).
    d = dzrp.Dzrp(t, start_byte=None)

    t0 = time.time()
    try:
        d.command(dzrp.CMD_INIT, dzrp.init_payload())
    except Exception as e:                          # noqa: BLE001
        print("CMD_INIT got no usable reply after %.1fs — %s: %s"
              % (time.time() - t0, type(e).__name__, e))
        t.close()
        return 1
    print("CMD_INIT answered in %.2fs" % (time.time() - t0))

    payload = bytes(range(256)) * (args.size // 256) + bytes(range(args.size % 256))
    t0 = time.time()
    try:
        got = d.command(dzrp.CMD_LOOPBACK, payload)
    except Exception as e:                          # noqa: BLE001
        print("CMD_LOOPBACK (%d bytes) got no usable reply after %.1fs — %s: %s"
              % (args.size, time.time() - t0, type(e).__name__, e))
        t.close()
        return 1

    elapsed = time.time() - t0
    t.close()
    if got != payload:
        print("CMD_LOOPBACK came back wrong: sent %d bytes, got %d"
              % (len(payload), len(got)))
        return 1
    print("CMD_LOOPBACK %d bytes round-tripped exactly in %.2fs" % (args.size, elapsed))
    return 0


if __name__ == "__main__":
    sys.exit(main())
