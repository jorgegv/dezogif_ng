#!/usr/bin/env python3
"""Emit a binary file as a C array, in the form `xxd -i -n <name>` produces.

This exists for portability rather than for taste. `xxd -i` is ancient, but
`xxd -n` — which names the array instead of deriving the name from the input
FILE's name — is a recent addition, and macOS ships whatever xxd came with its
bundled vim. Without `-n` the build had to copy the binary to a file called
`mfwin_bin` first so that xxd would name the array after it, which is a
workaround this replaces rather than makes portable.

python3 is already a build dependency (tools/romsum.py), so this adds nothing
to what a contributor needs installed.

Output is byte-identical to `xxd -i -n <name> <file>`: twelve bytes per line,
two-space indent, lowercase hex, and no trailing comma on the last data line.
That is deliberate — a generator that produced merely EQUIVALENT C would make
every future diff of the generated header noise, and the point of the change is
that nothing downstream of it moves.

    usage: bin2c.py <array-name> <binary-file>
"""

import sys

BYTES_PER_LINE = 12


def main(argv):
    if len(argv) != 3:
        sys.stderr.write("usage: %s <array-name> <binary-file>\n" % argv[0])
        return 2

    name, path = argv[1], argv[2]

    with open(path, "rb") as f:
        data = f.read()

    # An empty input would emit a well-formed but empty array, which compiles
    # and then fails on the machine. The build has no other check on this file,
    # so this is the one that has to be loud.
    if not data:
        sys.stderr.write("ERROR: %s is empty, so there is no array to emit\n" % path)
        return 1

    out = ["unsigned char %s[] = {" % name]
    for start in range(0, len(data), BYTES_PER_LINE):
        chunk = data[start:start + BYTES_PER_LINE]
        line = "  " + ", ".join("0x%02x" % b for b in chunk)
        if start + BYTES_PER_LINE < len(data):
            line += ","
        out.append(line)
    out.append("};")
    out.append("unsigned int %s_len = %d;" % (name, len(data)))

    sys.stdout.write("\n".join(out) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
