# Subscriber — the sink trait. Implementors decide *what to do* with an event:
# write to stderr, emit NDJSON to a file, push onto an in-memory list for tests,
# fan-out to N children. The Logger holds its subscriber by *value*, parameterized
# on the concrete `S: Subscriber` — every call site is monomorphized, so the
# `on_event` dispatch is a direct call (no vtable, no allocation).
#
# `enabled` is the early-out hook: filters that would drop an event answer
# `False` here so the Logger never builds the Event in the first place. This is
# how an `EnvFilter`-wrapped subscriber turns `trace!()` calls in a quiet target
# into a single comparison.

from logging.event import Event
from logging.level import Level


trait Subscriber(Copyable, ImplicitlyDeletable, Movable):
    def on_event(mut self, mut event: Event):
        """Consume an event. The Event is borrowed mutably so a subscriber can
        move its `fields`/`message` into its own buffer if it needs to retain.
        Errors inside on_event should NOT propagate; a logging failure must
        never crash the application path that issued the log call."""
        ...

    def enabled(self, level: Level, target: StaticString) -> Bool:
        """Pre-filter hook. Return `False` to drop the event before the Logger
        constructs it — saves the Instant.now() syscall, the field-list
        allocation, and the String construction of the message. Always-on
        subscribers should return `True`."""
        ...


struct NopSubscriber(Subscriber):
    """Discards every event. Useful as the default for tests that don't want
    log noise on stderr, or as the right-side of a `Tee` to disable one branch
    without removing it."""

    @always_inline
    def __init__(out self):
        pass

    @always_inline
    def on_event(mut self, mut event: Event):
        pass

    @always_inline
    def enabled(self, level: Level, target: StaticString) -> Bool:
        return False


struct Tee[A: Subscriber, B: Subscriber](Subscriber):
    """Fan-out combinator. An Event is delivered to `a` first, then `b`; both
    are run unconditionally even if one returns from `enabled` as False, because
    the per-child decision belongs to that child's own gate. Composes left-to-
    right: `Tee[Tee[Fmt, Json], Test]` is three sinks."""

    var a: Self.A
    var b: Self.B

    @always_inline
    def __init__(out self, var a: Self.A, var b: Self.B):
        self.a = a^
        self.b = b^

    @always_inline
    def on_event(mut self, mut event: Event):
        self.a.on_event(event)
        self.b.on_event(event)

    @always_inline
    def enabled(self, level: Level, target: StaticString) -> Bool:
        # Either child wants it -> we want it. The child that doesn't will
        # decide for itself inside its own on_event (which is a cheap no-op
        # for NopSubscriber and a level compare for the others).
        return self.a.enabled(level, target) or self.b.enabled(level, target)
