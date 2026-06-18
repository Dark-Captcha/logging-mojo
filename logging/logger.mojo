# Logger — the user-facing front door. Parameterized on the concrete subscriber
# `S`, so `info(...)` is a direct (monomorphized) call into `S.on_event`; no
# vtable, no boxed allocation. Every level method is `@always_inline` and gated
# on the binary-wide `LOG_COMPILE_MIN_LEVEL` so out-of-band severities are dead
# code at release.
#
# Hot path for `log.info("frame recv", Field.int("stream", 5))`:
#   1. comptime gate (folded — DCE if the binary disabled INFO)
#   2. runtime compare against `min_level` (one byte cmp)
#   3. subscriber.enabled(level, target) (one byte cmp for FmtSubscriber)
#   4. Instant.now() syscall
#   5. List[Field] alloc + variadic copy
#   6. subscriber.on_event(event) — formatter writes
# Steps 4-6 only happen for events that survive the two gates above.

from chrono import Instant

from logging.event import Event, EventInstant
from logging.field import Field
from logging.level import Level
from logging.subscriber import Subscriber


# Binary-wide compile-time minimum. Override in a project root by re-declaring
# `LOG_COMPILE_MIN_LEVEL` before importing `logging.logger`, OR by importing
# this module and reading the constant — Mojo doesn't yet have `--define`, so
# the override path is "fork this constant for your binary if you need it".
# Default DEBUG: dev builds keep everything; flip to INFO/WARN/ERROR/OFF in a
# release shim to fully erase the lower bands.
comptime LOG_COMPILE_MIN_LEVEL: Level = Level.DEBUG


struct Logger[S: Subscriber](Copyable, Movable):
    var subscriber: Self.S
    var min_level: Level
    var target: StaticString

    @always_inline
    def __init__(
        out self,
        var subscriber: Self.S,
        min_level: Level = Level.INFO,
        target: StaticString = "root",
    ):
        self.subscriber = subscriber^
        self.min_level = min_level
        self.target = target

    @always_inline
    def with_target(self, target: StaticString) -> Self:
        """Return a copy of this Logger with a different default target. The
        subscriber is copied (subscribers are cheap-to-copy by design — a TTY
        flag + an fd handle); callers who want a shared underlying sink should
        keep one Logger and pass it down."""
        return Self(self.subscriber.copy(), self.min_level, target)

    @always_inline
    def with_level(self, min_level: Level) -> Self:
        return Self(self.subscriber.copy(), min_level, self.target)

    @always_inline
    def trace(mut self, var msg: String, *fields: Field) raises:
        comptime if Level.TRACE >= LOG_COMPILE_MIN_LEVEL:
            if Level.TRACE >= self.min_level and self.subscriber.enabled(
                Level.TRACE, self.target
            ):
                var fl = List[Field]()
                for i in range(len(fields)):
                    fl.append(fields[i].copy())
                self._dispatch(Level.TRACE, msg^, fl^)

    @always_inline
    def debug(mut self, var msg: String, *fields: Field) raises:
        comptime if Level.DEBUG >= LOG_COMPILE_MIN_LEVEL:
            if Level.DEBUG >= self.min_level and self.subscriber.enabled(
                Level.DEBUG, self.target
            ):
                var fl = List[Field]()
                for i in range(len(fields)):
                    fl.append(fields[i].copy())
                self._dispatch(Level.DEBUG, msg^, fl^)

    @always_inline
    def info(mut self, var msg: String, *fields: Field) raises:
        comptime if Level.INFO >= LOG_COMPILE_MIN_LEVEL:
            if Level.INFO >= self.min_level and self.subscriber.enabled(
                Level.INFO, self.target
            ):
                var fl = List[Field]()
                for i in range(len(fields)):
                    fl.append(fields[i].copy())
                self._dispatch(Level.INFO, msg^, fl^)

    @always_inline
    def warn(mut self, var msg: String, *fields: Field) raises:
        comptime if Level.WARN >= LOG_COMPILE_MIN_LEVEL:
            if Level.WARN >= self.min_level and self.subscriber.enabled(
                Level.WARN, self.target
            ):
                var fl = List[Field]()
                for i in range(len(fields)):
                    fl.append(fields[i].copy())
                self._dispatch(Level.WARN, msg^, fl^)

    @always_inline
    def error(mut self, var msg: String, *fields: Field) raises:
        comptime if Level.ERROR >= LOG_COMPILE_MIN_LEVEL:
            if Level.ERROR >= self.min_level and self.subscriber.enabled(
                Level.ERROR, self.target
            ):
                var fl = List[Field]()
                for i in range(len(fields)):
                    fl.append(fields[i].copy())
                self._dispatch(Level.ERROR, msg^, fl^)

    @always_inline
    def _dispatch(
        mut self,
        level: Level,
        var msg: String,
        var fields: List[Field],
    ) raises:
        var ev = Event(level, self.target, msg^, fields^, Instant.now())
        self.subscriber.on_event(ev)
