# FmtSubscriber — the human-readable, ANSI-coloured default sink. One event in,
# one buffered `String`, one `FileDescriptor(2).write` out. No allocator pool, no
# background thread, no flush dance — every emit is a complete record at write
# time, so a torn line is impossible on Linux up to PIPE_BUF (4 KiB), which is
# longer than every realistic log line.
#
# Layout, in order:
#
#   2026-06-18T03:02:11.746Z  INFO http_client.h2: <message> key=value k2=v2
#
# Colours go on the level token only — colouring fields turns busy logs into
# Christmas trees. Strings carrying whitespace / `=` / control bytes are
# quoted (`"…"`) with backslash escapes; everything else is bare.

from std.io import FileDescriptor
from std.os import isatty, getenv

from chrono import Rfc3339, DateTime, Offset
from chrono.instant import Instant
from chrono._core.clock_id import ClockId

from logging.event import Event
from logging.field import Field, TAG_STR, TAG_INT, TAG_FLOAT, TAG_BOOL, TAG_BYTES
from logging.level import Level
from logging.subscriber import Subscriber


comptime _RESET = "\x1b[0m"
comptime _DIM = "\x1b[2m"
comptime _TARGET_FG = "\x1b[36m"  # cyan for the target column


struct FmtSubscriber(Subscriber):
    """Pretty stderr sink. `ansi` is the resolved colour decision; build with
    `default()` to honour the standard NO_COLOR / FORCE_COLOR / isatty rules,
    or pass an explicit `True`/`False` for tests."""

    var ansi: Bool
    var fd: Int  # the file descriptor to write to (default 2 = stderr)

    @always_inline
    def __init__(out self, ansi: Bool, fd: Int = 2):
        self.ansi = ansi
        self.fd = fd

    @staticmethod
    def default() raises -> FmtSubscriber:
        """Construct with auto-detected colour: ANSI on iff stderr is a TTY,
        `NO_COLOR` is unset, and `FORCE_COLOR`/`CLICOLOR_FORCE` did not override
        the decision."""
        var force = (
            getenv("FORCE_COLOR").byte_length() > 0
            or getenv("CLICOLOR_FORCE").byte_length() > 0
        )
        var no_color = getenv("NO_COLOR").byte_length() > 0
        var ansi: Bool
        if no_color:
            ansi = False
        elif force:
            ansi = True
        else:
            ansi = isatty(2)
        return FmtSubscriber(ansi=ansi, fd=2)

    @always_inline
    def enabled(self, level: Level, target: StaticString) -> Bool:
        return True

    def on_event(mut self, mut event: Event):
        try:
            var line = self._format(event)
            var fd = FileDescriptor(self.fd)
            fd.write(line)
        except:
            # A failure to write a log line must not propagate; we silently
            # drop. A future revision can expose a dropped counter.
            pass

    def _format(self, event: Event) raises -> String:
        var out = String("")
        # Timestamp — project the realtime instant to a UTC DateTime and
        # render with chrono's RFC 3339, then trim the fractional second to
        # millisecond precision (the universal log convention; nanoseconds are
        # noise on a human-read line, and the perf-counter clock is the right
        # tool when a caller needs them).
        var dt = DateTime.from_utc_instant(event.timestamp)
        var ts = Rfc3339.format(dt, Offset.UTC)
        out += _trim_fractional_ms(ts)
        out += " "

        # Level — coloured + padded to keep the rest of the columns aligned.
        if self.ansi:
            out += event.level.ansi_color()
            out += event.level.name_padded()
            out += _RESET
        else:
            out += event.level.name_padded()
        out += " "

        # Target — dim cyan when ANSI is on.
        if self.ansi:
            out += _TARGET_FG
            out += event.target
            out += _RESET
        else:
            out += event.target
        out += ": "

        # Message — raw, even if it contains whitespace; the message column is
        # free-form by convention. Field values use the quoting rules below.
        out += event.message

        # Fields — space-separated `k=v`, in call-site order.
        for i in range(len(event.fields)):
            out += " "
            ref f = event.fields[i]
            out += f.key
            out += "="
            _append_value(out, f)

        out += "\n"
        return out


def _trim_fractional_ms(ts: String) -> String:
    # Cut everything between the ms third digit and the trailing zone designator.
    # chrono emits ".nnnnnnnnnZ" (or "+HH:MM"); we look for the dot and the
    # zone start, then splice. If no dot is present (e.g. integer-second
    # instant), the string is returned unchanged.
    var b = ts.as_bytes()
    var n = len(b)
    var dot = -1
    for i in range(n):
        if b[i] == UInt8(ord(".")):
            dot = i
            break
    if dot == -1:
        return ts
    var zone = -1
    for i in range(dot + 1, n):
        var c = b[i]
        if c == UInt8(ord("Z")) or c == UInt8(ord("+")) or c == UInt8(ord("-")):
            zone = i
            break
    if zone == -1:
        return ts
    var keep = dot + 4  # dot + 3 fractional digits
    if keep > zone:
        keep = zone
    var out = String("")
    for i in range(0, keep):
        out += chr(Int(b[i]))
    for i in range(zone, n):
        out += chr(Int(b[i]))
    return out


def _append_value(mut out: String, ref field: Field):
    var tag = field.value.tag
    if tag == TAG_STR:
        _append_string(out, field.value.as_str())
    elif tag == TAG_INT:
        out += String(field.value.as_int())
    elif tag == TAG_FLOAT:
        out += String(field.value.as_float())
    elif tag == TAG_BOOL:
        if field.value.as_bool():
            out += "true"
        else:
            out += "false"
    elif tag == TAG_BYTES:
        _append_bytes_hex(out, field.value.as_bytes())


def _append_string(mut out: String, s: String):
    # Bare if the value is "safe" — no whitespace, no quote, no equals, no
    # control bytes — else quote with backslash escapes for `"` and `\`. This
    # is the same convention `slog` and `tracing-subscriber` use; it keeps
    # `grep` happy on the bare case and stays unambiguous on the quoted one.
    var b = s.as_bytes()
    var needs_quote = False
    for i in range(len(b)):
        var c = b[i]
        if (
            c <= UInt8(0x20)
            or c == UInt8(ord('"'))
            or c == UInt8(ord("="))
            or c == UInt8(ord("\\"))
        ):
            needs_quote = True
            break
    if not needs_quote:
        out += s
        return
    out += '"'
    for i in range(len(b)):
        var c = b[i]
        if c == UInt8(ord("\\")) or c == UInt8(ord('"')):
            out += "\\"
            out += chr(Int(c))
        elif c == UInt8(ord("\n")):
            out += "\\n"
        elif c == UInt8(ord("\r")):
            out += "\\r"
        elif c == UInt8(ord("\t")):
            out += "\\t"
        else:
            out += chr(Int(c))
    out += '"'


def _append_bytes_hex(mut out: String, ref bytes: List[UInt8]):
    # Lowercase hex, no separator, prefixed with `0x` so it's unambiguous and
    # one short token even for kilobyte payloads.
    comptime HEX = "0123456789abcdef"
    out += "0x"
    var hb = HEX.as_bytes()
    for i in range(len(bytes)):
        var b = bytes[i]
        out += chr(Int(hb[Int((b >> 4) & UInt8(0x0F))]))
        out += chr(Int(hb[Int(b & UInt8(0x0F))]))
