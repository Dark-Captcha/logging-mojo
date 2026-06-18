# JsonSubscriber — NDJSON sink, one event per line, written with a single
# `FileDescriptor(fd).write`. Field order is stable: `ts`, `level`, `target`,
# `msg`, `fields`. The bytes are built into a single `List[UInt8]` (no String
# += chain) and converted to `String(from_utf8=...)` once at the end — same
# pattern as FmtSubscriber. Strings escape only the JSON-mandatory subset
# (quote, backslash, control bytes); bytes serialize as base16 with an `0x`
# prefix to stay grep-able (no base64 padding noise).
#
# Intended for machine consumers — ship logs to a file, pipe to `jq`, ingest
# into Vector/Fluent Bit. Composes with FmtSubscriber via Tee when a pretty
# tail + a structured file are both wanted.

from std.io import FileDescriptor

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


comptime _OPEN_BRACE: UInt8 = UInt8(ord("{"))
comptime _CLOSE_BRACE: UInt8 = UInt8(ord("}"))
comptime _QUOTE: UInt8 = UInt8(ord('"'))
comptime _COMMA: UInt8 = UInt8(ord(","))
comptime _COLON: UInt8 = UInt8(ord(":"))
comptime _BACKSLASH: UInt8 = UInt8(ord("\\"))
comptime _NEWLINE: UInt8 = UInt8(ord("\n"))


struct JsonSubscriber(Subscriber):
    var fd: Int

    @always_inline
    def __init__(out self, fd: Int = 2):
        self.fd = fd

    @always_inline
    def enabled(self, level: Level, target: StaticString) -> Bool:
        return True

    def on_event(mut self, mut event: Event):
        try:
            var line = self._format(event)
            var f = FileDescriptor(self.fd)
            f.write(line)
        except:
            pass

    def _format(self, event: Event) raises -> String:
        var buf = List[UInt8](capacity=160)

        # {"ts":"…","level":"…","target":"…","msg":"…","fields":{…}}
        write_static(buf, '{"ts":"')
        var dt = DateTime.from_utc_instant(event.timestamp)
        write_rfc3339_into(buf, dt, Offset.UTC, frac_max_digits=9)
        write_static(buf, '","level":"')
        write_static(buf, event.level.name())
        write_static(buf, '","target":"')
        _json_string_body(buf, event.target.as_bytes())
        write_static(buf, '","msg":"')
        _json_string_body(buf, event.message.as_bytes())
        write_static(buf, '","fields":{')
        for i in range(len(event.fields)):
            if i > 0:
                buf.append(_COMMA)
            ref f = event.fields[i]
            buf.append(_QUOTE)
            _json_string_body(buf, f.key.as_bytes())
            buf.append(_QUOTE)
            buf.append(_COLON)
            _append_json_value(buf, f)
        write_static(buf, "}}\n")
        return String(from_utf8=buf^)


# --- helpers ----------------------------------------------------------------


def _append_json_value(mut buf: List[UInt8], ref field: Field):
    var tag = field.value.tag
    if tag == TAG_STR:
        buf.append(_QUOTE)
        _json_string_body(buf, field.value.as_str().as_bytes())
        buf.append(_QUOTE)
    elif tag == TAG_INT:
        write_int_signed(buf, Int(field.value.as_int()))
    elif tag == TAG_FLOAT:
        var s = String(field.value.as_float())
        write_bytes(buf, s.as_bytes())
    elif tag == TAG_BOOL:
        write_bool(buf, field.value.as_bool())
    elif tag == TAG_BYTES:
        write_static(buf, '"0x')
        write_hex(buf, field.value.as_bytes())
        buf.append(_QUOTE)


def _json_string_body(mut buf: List[UInt8], bytes: Span[UInt8, _]):
    # JSON-mandated escapes plus `\u00XX` for bytes below 0x20 that lack a
    # named escape. Non-ASCII bytes pass through (JSON allows raw UTF-8).
    #
    # Fast-path: most log payloads have no characters to escape. We scan for
    # the next byte that needs work; everything before it is bulk-copied with
    # `extend`, which lowers to a memcpy. The slow per-byte branch fires only
    # when an escape is actually needed.
    var n = len(bytes)
    var i = 0
    while i < n:
        # Find the next byte that needs escaping.
        var j = i
        while j < n:
            var c = bytes[j]
            if c == _QUOTE or c == _BACKSLASH or c < UInt8(0x20):
                break
            j += 1
        if j > i:
            buf.extend(bytes[i:j])
        if j >= n:
            return
        var c = bytes[j]
        if c == _QUOTE or c == _BACKSLASH:
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
        elif c == UInt8(ord("\b")):
            buf.append(_BACKSLASH)
            buf.append(UInt8(ord("b")))
        elif c == UInt8(ord("\f")):
            buf.append(_BACKSLASH)
            buf.append(UInt8(ord("f")))
        else:
            write_static(buf, "\\u00")
            _hex_pair(buf, c)
        i = j + 1


@always_inline
def _hex_pair(mut buf: List[UInt8], b: UInt8):
    comptime _HEX_BYTES = "0123456789abcdef".as_bytes()
    buf.append(_HEX_BYTES[Int((b >> 4) & UInt8(0x0F))])
    buf.append(_HEX_BYTES[Int(b & UInt8(0x0F))])
