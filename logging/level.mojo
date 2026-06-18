# Level — the severity tag attached to every event. Six values, totally ordered;
# the ordering is the only comparison logger filters need (`emit if event.level
# >= min_level`). `OFF` is the sentinel above ERROR — filtering `>= OFF` drops
# every event including ERROR, the standard "silence" idiom.
#
# Stored as a single UInt8 so Level is `TrivialRegisterPassable` and lives in a
# register. The six tags are exposed as `comptime` constants on the struct so the
# Rust-flavoured `Level.INFO` form folds at compile time — no module-level globals,
# no runtime construction.


struct Level(Comparable, TrivialRegisterPassable):
    var _v: UInt8

    @always_inline
    def __init__(out self, v: UInt8):
        self._v = v

    @always_inline
    def __eq__(self, other: Self) -> Bool:
        return self._v == other._v

    @always_inline
    def __ne__(self, other: Self) -> Bool:
        return self._v != other._v

    @always_inline
    def __lt__(self, other: Self) -> Bool:
        return self._v < other._v

    @always_inline
    def __le__(self, other: Self) -> Bool:
        return self._v <= other._v

    @always_inline
    def __gt__(self, other: Self) -> Bool:
        return self._v > other._v

    @always_inline
    def __ge__(self, other: Self) -> Bool:
        return self._v >= other._v

    @always_inline
    def value(self) -> UInt8:
        return self._v

    @always_inline
    def name(self) -> StaticString:
        if self._v == 0:
            return "TRACE"
        if self._v == 1:
            return "DEBUG"
        if self._v == 2:
            return "INFO"
        if self._v == 3:
            return "WARN"
        if self._v == 4:
            return "ERROR"
        return "OFF"

    @always_inline
    def name_padded(self) -> StaticString:
        # Five-character right-padded form for column-aligned output. ERROR/TRACE/
        # DEBUG/OFF are already five; INFO and WARN gain a trailing space so the
        # message column starts at the same place regardless of level.
        if self._v == 0:
            return "TRACE"
        if self._v == 1:
            return "DEBUG"
        if self._v == 2:
            return "INFO "
        if self._v == 3:
            return "WARN "
        if self._v == 4:
            return "ERROR"
        return "OFF  "

    @always_inline
    def ansi_color(self) -> StaticString:
        # SGR colour codes for the level label when the formatter has decided
        # ANSI is allowed. Background-neutral colours — readable on light and
        # dark terminals.
        if self._v == 0:
            return "\x1b[90m"  # bright black (grey)
        if self._v == 1:
            return "\x1b[36m"  # cyan
        if self._v == 2:
            return "\x1b[32m"  # green
        if self._v == 3:
            return "\x1b[33m"  # yellow
        if self._v == 4:
            return "\x1b[31m"  # red
        return "\x1b[90m"

    @staticmethod
    def parse(text: String) raises -> Level:
        """Case-insensitive parse of "trace"/"debug"/"info"/"warn"/"warning"/
        "error"/"err"/"off". Raises on an unrecognized token. Used by EnvFilter
        for the `LOG=` env-var grammar — invalid spelling should fail loudly
        rather than silently default."""
        var lc = text.lower()
        if lc == "trace":
            return Level.TRACE
        if lc == "debug":
            return Level.DEBUG
        if lc == "info":
            return Level.INFO
        if lc == "warn" or lc == "warning":
            return Level.WARN
        if lc == "error" or lc == "err":
            return Level.ERROR
        if lc == "off":
            return Level.OFF
        raise Error("logging.Level.parse: unrecognized level '" + text + "'")

    comptime TRACE: Level = Level(UInt8(0))
    comptime DEBUG: Level = Level(UInt8(1))
    comptime INFO: Level = Level(UInt8(2))
    comptime WARN: Level = Level(UInt8(3))
    comptime ERROR: Level = Level(UInt8(4))
    comptime OFF: Level = Level(UInt8(5))
