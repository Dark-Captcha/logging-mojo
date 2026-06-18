# Fast byte-buffer formatting helpers for the subscribers. The previous code
# built each event by chaining `String += String += String …` — every `+=`
# resizes a new heap allocation. This module replaces that with helpers that
# append directly into a single `List[UInt8]`, so a complete event line is
# one growing buffer and one `String(from_utf8=...)` at the end.
#
# The two-digit decimal table (`_D100`) is the standard itoa trick: each value
# in `0..100` has two ASCII bytes side by side, so two-digit chunks are one
# indexed read into a 200-byte table instead of a divide/mod + add('0') pair.
# Reference: Andrei Alexandrescu, "Three Optimization Tips for C++" (CppCon
# 2014); same approach used in fmt, Rust std, Go runtime.
#
# Private to the library — outside callers do not import from here.

from chrono import DateTime, Offset, Instant, ClockId


# --- Lookup tables ----------------------------------------------------------

comptime _D100: StaticString = (
    "00010203040506070809"
    "10111213141516171819"
    "20212223242526272829"
    "30313233343536373839"
    "40414243444546474849"
    "50515253545556575859"
    "60616263646566676869"
    "70717273747576777879"
    "80818283848586878889"
    "90919293949596979899"
)

comptime _HEX: StaticString = "0123456789abcdef"

comptime _DASH: UInt8 = UInt8(ord("-"))
comptime _COLON: UInt8 = UInt8(ord(":"))
comptime _DOT: UInt8 = UInt8(ord("."))
comptime _T: UInt8 = UInt8(ord("T"))
comptime _Z: UInt8 = UInt8(ord("Z"))
comptime _ZERO: UInt8 = UInt8(ord("0"))
comptime _PLUS: UInt8 = UInt8(ord("+"))
comptime _MINUS: UInt8 = UInt8(ord("-"))


# --- Buffer primitives ------------------------------------------------------

@always_inline
def write_byte(mut buf: List[UInt8], c: UInt8):
    buf.append(c)


@always_inline
def write_bytes(mut buf: List[UInt8], bytes: Span[UInt8, _]):
    """Bulk-append every byte of `bytes` to `buf` via `List.extend` — Mojo
    lowers this to a memcpy after the resize."""
    buf.extend(bytes)


@always_inline
def write_static(mut buf: List[UInt8], s: StaticString):
    write_bytes(buf, s.as_bytes())


# --- itoa helpers -----------------------------------------------------------

@always_inline
def write2(mut buf: List[UInt8], n: Int):
    """Append two zero-padded ASCII digits. `n` must be `0..99`."""
    var t = _D100.as_bytes()
    var idx = n + n
    buf.append(t[idx])
    buf.append(t[idx + 1])


@always_inline
def write4(mut buf: List[UInt8], n: Int):
    """Append four zero-padded ASCII digits. `n` must be `0..9999`."""
    var hi = n // 100
    var lo = n - hi * 100
    write2(buf, hi)
    write2(buf, lo)


def write_int_signed(mut buf: List[UInt8], value: Int):
    """Append a signed integer in decimal — no padding, minimal width. Fast
    path uses pairs of digits from `_D100` so the inner loop runs `digits/2`
    times rather than `digits`."""
    var v = value
    if v < 0:
        buf.append(_MINUS)
        v = -v
    if v < 10:
        buf.append(_ZERO + UInt8(v))
        return
    # Render into a scratch in reverse, then flip on copy out.
    var tmp = InlineArray[UInt8, 20](uninitialized=True)  # max Int64 has 19 digits + sign
    var pos = 0
    var t = _D100.as_bytes()
    while v >= 100:
        var q = v // 100
        var r = v - q * 100
        var idx = r + r
        tmp[pos] = t[idx + 1]
        tmp[pos + 1] = t[idx]
        pos += 2
        v = q
    if v < 10:
        tmp[pos] = _ZERO + UInt8(v)
        pos += 1
    else:
        var idx = v + v
        tmp[pos] = t[idx + 1]
        tmp[pos + 1] = t[idx]
        pos += 2
    # Reverse-copy
    for i in range(pos - 1, -1, -1):
        buf.append(tmp[i])


@always_inline
def write_bool(mut buf: List[UInt8], b: Bool):
    if b:
        write_static(buf, "true")
    else:
        write_static(buf, "false")


def write_hex(mut buf: List[UInt8], bytes: Span[UInt8, _]):
    """Append the lowercase hex encoding of `bytes` (two output bytes per
    input byte). No `0x` prefix — callers decide framing."""
    var t = _HEX.as_bytes()
    for i in range(len(bytes)):
        var b = bytes[i]
        buf.append(t[Int((b >> 4) & UInt8(0x0F))])
        buf.append(t[Int(b & UInt8(0x0F))])


# --- RFC 3339 timestamp -----------------------------------------------------

def write_rfc3339_into(
    mut buf: List[UInt8],
    dt: DateTime,
    offset: Offset,
    frac_max_digits: Int = 9,
) raises:
    """Append an RFC 3339 timestamp for `dt` at `offset`. `frac_max_digits`
    truncates (not rounds) the fractional second to at most that many digits;
    trailing zeros within that window are still trimmed, so `123_400_000ns`
    with `frac_max_digits=3` writes `.123` and `100_000_000ns` writes `.1`.
    `frac_max_digits=0` suppresses the fractional part entirely."""
    var ymd = dt.date().year_month_day()
    var year = ymd.year
    if year < 0 or year > 9999:
        raise Error(
            "logging._fmt_fast: year out of RFC 3339 range (0..9999), got "
            + String(year)
        )
    write4(buf, year)
    buf.append(_DASH)
    write2(buf, ymd.month)
    buf.append(_DASH)
    write2(buf, ymd.day)
    buf.append(_T)
    write2(buf, dt.hour())
    buf.append(_COLON)
    write2(buf, dt.minute())
    buf.append(_COLON)
    write2(buf, dt.second())

    var nanos = dt.nanosecond()
    if nanos != 0 and frac_max_digits > 0:
        # Truncate to `frac_max_digits`, then trim trailing zeros.
        var max_digits = frac_max_digits if frac_max_digits <= 9 else 9
        var significand = nanos
        if max_digits < 9:
            var divisor = 1
            for _ in range(9 - max_digits):
                divisor *= 10
            significand //= divisor
        if significand != 0:
            var digits = max_digits
            while (significand % 10) == 0:
                significand //= 10
                digits -= 1
            buf.append(_DOT)
            # Write significand left-padded to `digits` columns.
            var start = len(buf)
            for _ in range(digits):
                buf.append(_ZERO)
            var v = significand
            for i in range(digits - 1, -1, -1):
                buf[start + i] = _ZERO + UInt8(v % 10)
                v //= 10

    if offset.is_utc():
        buf.append(_Z)
    else:
        var sec = offset.total_seconds()
        if sec >= 0:
            buf.append(_PLUS)
        else:
            buf.append(_MINUS)
            sec = -sec
        write2(buf, sec // 3600)
        buf.append(_COLON)
        write2(buf, (sec % 3600) // 60)
