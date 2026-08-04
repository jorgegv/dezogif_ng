#!/usr/bin/env python3
"""CRC-16/CCITT-FALSE of a file, as four uppercase hex digits.

The host half of mfselect's checksum. mfselect computes the same value on the
Next (tools/mfselect/mfselect.c, crc16()), and the two must agree byte for
byte — the headless bench checks that they do rather than trusting it.

Parameters: poly 0x1021, init 0xFFFF, no input/output reflection, no final
xor. Chosen because it is the CRC-16 everyone means by "CRC-16/CCITT", so a
third party can reproduce a .sum file without reading this script.
"""

import sys


def crc16(data):
    crc = 0xFFFF
    for b in data:
        crc ^= b << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc


def main():
    if len(sys.argv) != 2:
        print("usage: romsum.py FILE", file=sys.stderr)
        return 2
    with open(sys.argv[1], "rb") as f:
        data = f.read()
    print("%04X" % crc16(data))
    return 0


if __name__ == "__main__":
    sys.exit(main())
