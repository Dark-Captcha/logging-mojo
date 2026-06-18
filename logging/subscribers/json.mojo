# JsonSubscriber — NDJSON sink, one event per line, written with a single
# `FileDescriptor(fd).write`. Field order is stable: `ts`, `level`, `target`,
# `msg`, `fields`. Strings escape only the JSON-mandatory subset (quote,
# backslash, control bytes); bytes serialize as base16 with an `0x` prefix to
# stay grep-able (no base64 padding noise).
#
# Intended for machine consumers — ship logs to a file, pipe to `jq`, ingest
# into Vector/Fluent Bit. Composes with FmtSubscriber via Tee when a pretty
# tail + a structured file are both wanted.

from std.io import FileDescriptor

from chrono import Rfc3339, DateTime, Offset

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
        var out = String("{")
        var dt = DateTime.from_utc_instant(event.timestamp)
        out += '"ts":"'
        out += Rfc3339.format(dt, Offset.UTC)
        out += '","level":"'
        out += event.level.name()
        out += '","target":"'
        _json_string_body(out, event.target.as_bytes())
        out += '","msg":"'
        _json_string_body(out, event.message.as_bytes())
        out += '","fields":{'
        for i in range(len(event.fields)):
            if i > 0:
                out += ","
            ref f = event.fields[i]
            out += '"'
            _json_string_body(out, f.key.as_bytes())
            out += '":'
            _append_json_value(out, f)
        out += "}}\n"
        return out


def _append_json_value(mut out: String, ref field: Field):
    var tag = field.value.tag
    if tag == TAG_STR:
        out += '"'
        _json_string_body(out, field.value.as_str().as_bytes())
        out += '"'
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
        out += '"0x'
        _hex_body(out, field.value.as_bytes())
        out += '"'


def _json_string_body(mut out: String, bytes: Span[UInt8, _]):
    # The JSON-mandated escapes plus a backslash-u fallback for any byte
    # below 0x20 that isn't one of the named escapes. Non-ASCII bytes pass
    # through (we emit UTF-8 directly — JSON spec allows it).
    for i in range(len(bytes)):
        var c = bytes[i]
        if c == UInt8(ord('"')) or c == UInt8(ord("\\")):
            out += "\\"
            out += chr(Int(c))
        elif c == UInt8(ord("\n")):
            out += "\\n"
        elif c == UInt8(ord("\r")):
            out += "\\r"
        elif c == UInt8(ord("\t")):
            out += "\\t"
        elif c == UInt8(ord("\b")):
            out += "\\b"
        elif c == UInt8(ord("\f")):
            out += "\\f"
        elif c < UInt8(0x20):
            comptime HEX = "0123456789abcdef"
            var hb = HEX.as_bytes()
            out += "\\u00"
            out += chr(Int(hb[Int((c >> 4) & UInt8(0x0F))]))
            out += chr(Int(hb[Int(c & UInt8(0x0F))]))
        else:
            out += chr(Int(c))


def _hex_body(mut out: String, ref bytes: List[UInt8]):
    comptime HEX = "0123456789abcdef"
    var hb = HEX.as_bytes()
    for i in range(len(bytes)):
        var b = bytes[i]
        out += chr(Int(hb[Int((b >> 4) & UInt8(0x0F))]))
        out += chr(Int(hb[Int(b & UInt8(0x0F))]))
