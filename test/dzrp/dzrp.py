"""A minimal DZRP client, for talking to any DZRP remote.

Wire format, quoted from DeZog's design/DeZogProtocol.md rather than recalled:

    Command frame
      0 | 4 | Length of the payload data. (little endian)
      4 | 1 | Sequence number, 1-255. Increased with each command
      5 | 1 | Command ID
      6 | 1 | Payload: Data[0]

    Response frame
      0 | 4 | Length of the following data beginning with the sequence number.
      4 | 1 | Sequence number, same as command.
      5 | 1 | Payload: Data[0]

    Notification frame
      0 | 4 | Length of the following data beginning with the sequence number.
      4 | 1 | Sequence number = 0.
      5 | 1 | Payload: Data[0]

THE TWO DIRECTIONS USE DIFFERENT LENGTH CONVENTIONS, and the spec's two tables
say so in words easy to skim past:

  * a COMMAND's length is "the length of the payload data" — it counts NEITHER
    the sequence number NOR the command ID;
  * a RESPONSE's (and a notification's) length is "the length of the following
    data beginning with the sequence number" — it DOES count the sequence byte.

This was verified against CSpect's DeZog plugin, not inferred. Sending CMD_INIT
with a symmetric length (payload + 2) produced no reply at all: the plugin sat
waiting for the two bytes it thought were still owed. With the length set to
the payload alone it answered at once, and its reply's own length counted the
sequence byte. Assuming symmetry here costs a silent hang, not an error, which
is the most expensive kind of wrong.

THE START BYTE IS REAL, DOCUMENTED, AND SERIAL-ONLY. Upstream's own design
doc says it outright (doc/legacy/Design.md:30-31): "the DZRP protocol was
extended by one byte which is sent as first byte of a message (only in
direction from ZX Next to PC). This is the MESSAGE_START_BYTE (0xA5). DeZog
will wait on this byte before it recognizes messages coming from the Next."
The reason is in the paragraph above it: a game that grabs the joy port makes
the Next transmit endless zeroes, and the preamble is how DeZog resynchronises.

DeZog implements exactly that split — its ZxNextSerialRemote scans for and
strips byte 165, its CSpectRemote does not. So the byte is REQUIRED in UART
mode and must be ABSENT in WiFi mode: it is a property the transport
contributes, not an error to remove. This client therefore treats it as a
per-remote setting, defaulting to autodetect.
"""

import socket
import struct

# The 29 commands, from the project's dzrp skill. Not re-derived here.
CMD_INIT = 1
CMD_CLOSE = 2
CMD_GET_REGISTERS = 3
CMD_SET_REGISTER = 4
CMD_WRITE_BANK = 5
CMD_CONTINUE = 6
CMD_PAUSE = 7
CMD_READ_MEM = 8
CMD_WRITE_MEM = 9
CMD_SET_SLOT = 10
CMD_GET_TBBLUE_REG = 11
CMD_SET_BORDER = 12
CMD_SET_BREAKPOINTS = 13
CMD_RESTORE_MEM = 14
CMD_LOOPBACK = 15
CMD_GET_SPRITES_PALETTE = 16
CMD_GET_SPRITES_CLIP_WINDOW_AND_CONTROL = 17
CMD_GET_SPRITES = 18
CMD_GET_SPRITE_PATTERNS = 19
CMD_READ_PORT = 20
CMD_WRITE_PORT = 21
CMD_EXEC_ASM = 22
CMD_INTERRUPT_ON_OFF = 23
CMD_ADD_BREAKPOINT = 40
CMD_REMOVE_BREAKPOINT = 41
CMD_ADD_WATCHPOINT = 42
CMD_REMOVE_WATCHPOINT = 43
CMD_READ_STATE = 50
CMD_WRITE_STATE = 51

NTF_PAUSE = 1

START_BYTE = 0xA5

# Generous: the spec caps CMD_LOOPBACK data at 8192 bytes, and a frame carries
# a little overhead on top. Anything beyond this is treated as a desync rather
# than honoured, so a garbage length cannot make us block forever on a read.
MAX_FRAME = 9000


class DzrpError(Exception):
    pass


class Timeout(DzrpError):
    pass


class Desync(DzrpError):
    """The byte stream did not look like a DZRP frame."""


# --------------------------------------------------------------------------
# transports
# --------------------------------------------------------------------------


class TcpTransport:
    def __init__(self, host, port, timeout):
        self.name = "tcp:%s:%d" % (host, port)
        self.sock = socket.create_connection((host, port), timeout=timeout)
        self.sock.settimeout(timeout)

    def read(self, n):
        out = b""
        while len(out) < n:
            try:
                chunk = self.sock.recv(n - len(out))
            except socket.timeout:
                raise Timeout("timed out after %d of %d bytes" % (len(out), n))
            if not chunk:
                raise DzrpError("remote closed the connection")
            out += chunk
        return out

    def set_timeout(self, seconds):
        self.sock.settimeout(seconds)

    def write(self, data):
        self.sock.sendall(data)

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


class SerialTransport:
    def __init__(self, device, baud, timeout):
        try:
            import serial  # noqa: F401  (pyserial, optional)
        except ImportError:
            raise DzrpError(
                "the serial target needs pyserial (python3 -m pip install pyserial); "
                "it is deliberately not a hard dependency of this bench")
        import serial
        self.name = "serial:%s:%d" % (device, baud)
        self.port = serial.Serial(device, baud, timeout=timeout)

    def read(self, n):
        out = self.port.read(n)
        if len(out) < n:
            raise Timeout("timed out after %d of %d bytes" % (len(out), n))
        return out

    def set_timeout(self, seconds):
        self.port.timeout = seconds

    def write(self, data):
        self.port.write(data)
        self.port.flush()

    def close(self):
        self.port.close()


def open_remote(spec, timeout=5.0):
    """spec is 'tcp:<host>:<port>' or 'serial:<device>:<baud>'."""
    parts = spec.split(":")
    if parts[0] == "tcp" and len(parts) == 3:
        return TcpTransport(parts[1], int(parts[2]), timeout)
    if parts[0] == "serial" and len(parts) == 3:
        return SerialTransport(parts[1], int(parts[2]), timeout)
    raise DzrpError(
        "cannot parse remote %r — expected tcp:<host>:<port> or serial:<device>:<baud>"
        % spec)


# --------------------------------------------------------------------------
# client
# --------------------------------------------------------------------------


class Dzrp:
    """One DZRP conversation.

    start_byte: None  — frames begin with the length (the specification)
                0xA5  — frames begin with 0xA5, as our stub emits
                "auto" — decide on the first frame received, and record it
    """

    def __init__(self, transport, start_byte="auto"):
        self.t = transport
        self.start_byte = start_byte
        self.observed_start_byte = None
        self.seq = 0
        self.notifications = []

    def close(self):
        self.t.close()

    def _next_seq(self):
        # "Sequence number, 1-255" — 0 is reserved for notifications, so it is
        # skipped on wrap rather than allowed to collide with one.
        self.seq = self.seq % 255 + 1
        return self.seq

    def send_raw(self, data):
        self.t.write(data)

    def build_command(self, cmd_id, payload=b"", seq=None, length=None):
        """The bytes of a command frame. Exposed so tests can send malformed
        frames deliberately."""
        if seq is None:
            seq = self._next_seq()
        if length is None:
            # Payload ONLY — not the sequence byte, not the command ID. See the
            # module docstring: responses count differently, and getting this
            # wrong makes the remote wait silently rather than complain.
            length = len(payload)
        return struct.pack("<IBB", length, seq, cmd_id) + payload, seq

    def _read_frame(self):
        """One response or notification: returns (seq, payload)."""
        first = self.t.read(1)

        if self.start_byte == "auto":
            if first[0] == START_BYTE:
                # Only conclude "start byte" if what follows is a credible
                # length. A frame with NO preamble whose length is exactly 165
                # also begins 0xA5, so this must fall back rather than raise —
                # it used to raise, and would have reported a perfectly good
                # remote as desynced the first time a response happened to be
                # 165 bytes long.
                probe = self.t.read(4)
                length = struct.unpack("<I", probe)[0]
                if 1 <= length <= MAX_FRAME:
                    self.start_byte = START_BYTE
                    self.observed_start_byte = START_BYTE
                    return self._finish_frame(length)
                # Re-read those five bytes as <length:4><seq:1> with no
                # preamble: 0xA5 was the length's low byte after all. No extra
                # read is needed, we already hold them.
                length = struct.unpack("<I", first + probe[:3])[0]
                if not 1 <= length <= MAX_FRAME:
                    raise Desync(
                        "leading 0xA5 is neither a preamble nor a sane length (%d)" % length)
                self.start_byte = None
                self.observed_start_byte = None
                body = probe[3:] + self.t.read(length - 1)
                return body[0], body[1:]
            self.start_byte = None
            self.observed_start_byte = None
            length = struct.unpack("<I", first + self.t.read(3))[0]
            return self._finish_frame(length)

        if self.start_byte == START_BYTE:
            if first[0] != START_BYTE:
                raise Desync("expected start byte 0xA5, got 0x%02X" % first[0])
            length = struct.unpack("<I", self.t.read(4))[0]
            return self._finish_frame(length)

        length = struct.unpack("<I", first + self.t.read(3))[0]
        return self._finish_frame(length)

    def _finish_frame(self, length):
        if not 1 <= length <= MAX_FRAME:
            raise Desync("implausible frame length %d" % length)
        body = self.t.read(length)          # length counts from the seq number
        return body[0], body[1:]

    def command(self, cmd_id, payload=b""):
        """Send a command, return its response payload.

        Notifications arriving while we wait are collected, not confused with
        the response: a notification is seq 0, and a response carries the
        sequence number of the command that asked for it.
        """
        frame, seq = self.build_command(cmd_id, payload)
        self.t.write(frame)
        while True:
            got_seq, body = self._read_frame()
            if got_seq == 0:
                self.notifications.append(body)
                continue
            if got_seq != seq:
                raise DzrpError(
                    "sequence mismatch: sent %d, got %d" % (seq, got_seq))
            return body

    def wait_notification(self):
        """Block until a notification (seq 0) arrives, and return its body."""
        if self.notifications:
            return self.notifications.pop(0)
        while True:
            got_seq, body = self._read_frame()
            if got_seq == 0:
                return body
            raise DzrpError("expected a notification, got a response for seq %d" % got_seq)


def init_payload(version=(2, 1, 0), name="dezogif_ng-conformance"):
    """CMD_INIT: 3 bytes big-endian Major.Minor.Patch, then a NUL-terminated
    program name."""
    return bytes(version) + name.encode("ascii") + b"\x00"
