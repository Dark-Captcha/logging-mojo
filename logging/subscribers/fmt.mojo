# FmtSubscriber — human-readable ANSI-coloured default sink. One event in,
# one buffered byte vector, one `FileDescriptor(2).write` out. The bytes are
# built directly into a `List[UInt8]` (no String += chain) and then handed
# to `String(from_utf8=...)` so the on-the-wire path is one heap allocation
# and one syscall. A torn line is impossible on Linux up to PIPE_BUF (4 KiB);
# every realistic log line stays well under that.
#
# Layout, in order:
#
#   2026-06-18T03:02:11.746Z  INFO http_client.h2: <message> key=value k2=v2
#
# Colours go on the level token only (and the target when ANSI is on);
# colouring field values turns busy logs into Christmas trees. Strings
# carrying whitespace / `=` / control bytes are quoted (`"…"`) with backslash
# escapes; everything else is bare.

from std.io import FileDescriptor
from std.os import isatty, getenv

from chrono import DateTime, Offset

from logging.event import Event
from logging.field import (
    Field,
    TAG_STR,
    TAG_INT,
    TAG_FLOAT,
    TAG_BOOL,
    TAG_BYTES,
)
from logging.level import Level
from logging.subscriber import Subscriber
from logging._fmt_fast import (
    write_byte,
    write_bytes,
    write_static,
    write_int_signed,
    write_bool,
    write_hex,
    write_rfc3339_into,
)


comptime _RESET: StaticString = "\x1b[0m"
comptime _TARGET_FG: StaticString = "\x1b[36m"  # cyan for the target column
comptime _SPACE: UInt8 = UInt8(ord(" "))
comptime _COLON: UInt8 = UInt8(ord(":"))
comptime _EQ: UInt8 = UInt8(ord("="))
comptime _QUOTE: UInt8 = UInt8(ord('"'))
comptime _BACKSLASH: UInt8 = UInt8(ord("\\"))
comptime _NEWLINE: UInt8 = UInt8(ord("\n"))


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
        # Reserve enough to cover the typical event (timestamp + level + target
        # + short message + a few fields) without a resize. Larger events grow
        # the buffer at most a couple of times.
        var buf = List[UInt8](capacity=128)

        # Timestamp — millisecond precision (3 fractional digits max). The
        # subscriber does this directly so the whole event is one buffer,
        # without a chrono String allocation and a post-trim pass.
        var dt = DateTime.from_utc_instant(event.timestamp)
        write_rfc3339_into(buf, dt, Offset.UTC, frac_max_digits=3)
        buf.append(_SPACE)

        # Level — coloured + padded to keep the rest of the columns aligned.
        if self.ansi:
            write_static(buf, event.level.ansi_color())
            write_static(buf, event.level.name_padded())
            write_static(buf, _RESET)
        else:
            write_static(buf, event.level.name_padded())
        buf.append(_SPACE)

        # Target — dim cyan when ANSI is on.
        if self.ansi:
            write_static(buf, _TARGET_FG)
            write_bytes(buf, event.target.as_bytes())
            write_static(buf, _RESET)
        else:
            write_bytes(buf, event.target.as_bytes())
        buf.append(_COLON)
        buf.append(_SPACE)

        # Message — raw, even with whitespace; field values use quoting below.
        write_bytes(buf, event.message.as_bytes())

        # Fields — space-separated `k=v`, in call-site order.
        for i in range(len(event.fields)):
            buf.append(_SPACE)
            ref f = event.fields[i]
            write_bytes(buf, f.key.as_bytes())
            buf.append(_EQ)
            _append_value(buf, f)

        buf.append(_NEWLINE)
        return String(from_utf8=buf^)


# --- Field value rendering --------------------------------------------------


def _append_value(mut buf: List[UInt8], ref field: Field):
    var tag = field.value.tag
    if tag == TAG_STR:
        _append_string(buf, field.value.as_str().as_bytes())
    elif tag == TAG_INT:
        write_int_signed(buf, Int(field.value.as_int()))
    elif tag == TAG_FLOAT:
        # Mojo's `String(Float64)` is still the right primitive here — a
        # custom Grisu/Ryu would dwarf the value-adds of this rewrite.
        var s = String(field.value.as_float())
        write_bytes(buf, s.as_bytes())
    elif tag == TAG_BOOL:
        write_bool(buf, field.value.as_bool())
    elif tag == TAG_BYTES:
        write_static(buf, "0x")
        write_hex(buf, field.value.as_bytes())


def _append_string(mut buf: List[UInt8], bytes: Span[UInt8, _]):
    # Bare if "safe" — no whitespace, no quote, no equals, no control bytes —
    # else quote with backslash escapes for `"` and `\`. Same convention as
    # `slog` / `tracing-subscriber`; bare keeps `grep` happy and quoted is
    # unambiguous.
    var n = len(bytes)
    var needs_quote = False
    for i in range(n):
        var c = bytes[i]
        if (
            c <= UInt8(0x20)
            or c == _QUOTE
            or c == _EQ
            or c == _BACKSLASH
        ):
            needs_quote = True
            break
    if not needs_quote:
        write_bytes(buf, bytes)
        return
    buf.append(_QUOTE)
    for i in range(n):
        var c = bytes[i]
        if c == _BACKSLASH or c == _QUOTE:
            buf.append(_BACKSLASH)
            buf.append(c)
        elif c == _NEWLINE:
            buf.append(_BACKSLASH)
            buf.append(UInt8(ord("n")))
        elif c == UInt8(ord("\r")):
            buf.append(_BACKSLASH)
            buf.append(UInt8(ord("r")))
        elif c == UInt8(ord("\t")):
            buf.append(_BACKSLASH)
            buf.append(UInt8(ord("t")))
        else:
            buf.append(c)
    buf.append(_QUOTE)
