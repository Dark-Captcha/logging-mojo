# EnvFilter — the `LOG=` env-var driven filter, the same shape tracing-subscriber
# uses for `RUST_LOG`. The directive grammar is:
#
#   LOG=<spec>(,<spec>)*
#   <spec> ::= <level>                        # global default
#            | <target_prefix>=<level>        # override for matching targets
#
# Target match is *prefix on dot boundary*: directive "h2" matches targets
# "h2", "h2.frame", "h2.flow" — but not "h2x" or "http_h2". Longest-matching
# directive wins; ties broken by file order. If no directive matches, the
# default level (the last bare `<level>` in the spec, or `INFO`) applies.
#
# Cost model: parsing once at startup; `enabled(level, target)` is at most one
# bytewise scan over the directive list. The list is small in practice (a few
# entries) and lives in the Logger's frame, so this is a tight inner loop with
# no allocation.

from std.os import getenv

from logging.level import Level


struct _Directive(Copyable, Movable):
    var target: String  # empty → "applies to every target" (the default)
    var level: Level

    @always_inline
    def __init__(out self, var target: String, level: Level):
        self.target = target^
        self.level = level


struct EnvFilter(Copyable, Movable):
    var default: Level
    var directives: List[_Directive]

    @always_inline
    def __init__(out self, default: Level):
        self.default = default
        self.directives = List[_Directive]()

    @always_inline
    def __init__(out self, default: Level, var directives: List[_Directive]):
        self.default = default
        self.directives = directives^

    @staticmethod
    def parse(text: String) raises -> EnvFilter:
        """Parse a LOG-style directive list. Empty input → default INFO with no
        overrides. Whitespace around levels and targets is stripped; unknown
        level tokens raise (the env var is user input but a typo at startup
        should fail loudly, not silently drop events)."""
        var default = Level.INFO
        var dirs = List[_Directive]()
        var bytes = text.as_bytes()
        var n = len(bytes)
        if n == 0:
            return EnvFilter(default, dirs^)

        comptime COMMA = UInt8(ord(","))
        comptime EQ = UInt8(ord("="))

        var i = 0
        while i < n:
            # One comma-delimited segment.
            var start = i
            while i < n and bytes[i] != COMMA:
                i += 1
            var seg_end = i
            if i < n:
                i += 1  # skip ','

            # Trim leading/trailing whitespace bytes inside [start, seg_end).
            while start < seg_end and _is_ws(bytes[start]):
                start += 1
            while seg_end > start and _is_ws(bytes[seg_end - 1]):
                seg_end -= 1
            if seg_end == start:
                continue

            # Find '=' within the segment.
            var eq = -1
            for j in range(start, seg_end):
                if bytes[j] == EQ:
                    eq = j
                    break

            if eq == -1:
                default = Level.parse(_slice_to_string(bytes, start, seg_end))
            else:
                var tgt_start = start
                var tgt_end = eq
                while tgt_start < tgt_end and _is_ws(bytes[tgt_end - 1]):
                    tgt_end -= 1
                var lvl_start = eq + 1
                var lvl_end = seg_end
                while lvl_start < lvl_end and _is_ws(bytes[lvl_start]):
                    lvl_start += 1
                var lvl = Level.parse(
                    _slice_to_string(bytes, lvl_start, lvl_end)
                )
                if tgt_end == tgt_start:
                    default = lvl
                else:
                    dirs.append(
                        _Directive(
                            _slice_to_string(bytes, tgt_start, tgt_end),
                            lvl,
                        )
                    )

        return EnvFilter(default, dirs^)

    @staticmethod
    def from_env() raises -> EnvFilter:
        """Read `LOG` from the process env (empty if unset) and parse it."""
        return EnvFilter.parse(getenv("LOG"))

    @always_inline
    def min_level_for(self, target: StaticString) -> Level:
        """Pick the directive level for `target` using longest-prefix match on
        dot boundaries. Falls back to `default` when nothing matches."""
        var best_len = -1
        var best_level = self.default
        for i in range(len(self.directives)):
            ref d = self.directives[i]
            if _target_matches(d.target, target):
                var dl = d.target.byte_length()
                if dl > best_len:
                    best_len = dl
                    best_level = d.level
        return best_level

    @always_inline
    def enabled(self, level: Level, target: StaticString) -> Bool:
        return level >= self.min_level_for(target)


@always_inline
def _is_ws(b: UInt8) -> Bool:
    return b == UInt8(ord(" ")) or b == UInt8(ord("\t"))


@always_inline
def _slice_to_string(bytes: Span[UInt8, _], start: Int, end: Int) -> String:
    var out = String()
    for i in range(start, end):
        out += chr(Int(bytes[i]))
    return out


@always_inline
def _target_matches(prefix: String, target: StaticString) -> Bool:
    """`prefix == target`, or `target` starts with `prefix + "."`. Avoids
    matching "h2" against "h2x"."""
    var t_bytes = target.as_bytes()
    var p_bytes = prefix.as_bytes()
    var pl = len(p_bytes)
    var tl = len(t_bytes)
    if pl > tl:
        return False
    for i in range(pl):
        if t_bytes[i] != p_bytes[i]:
            return False
    if pl == tl:
        return True
    return t_bytes[pl] == UInt8(ord("."))
