# Filtered[S] — wraps any Subscriber with an EnvFilter so per-target level
# gating works against every sink. Use when you want the same filter to drive
# multiple sinks (`Filtered[Tee[Fmt, Json]]`) or when a particular sink should
# have a stricter view (`Tee[Fmt, Filtered[Json]]`).
#
# Lives in `logging.filter` rather than `logging.subscribers` because its
# behaviour is "filter, then delegate" — the wrapped sink is incidental.

from logging.event import Event
from logging.filter.env import EnvFilter
from logging.level import Level
from logging.subscriber import Subscriber


struct Filtered[S: Subscriber](Subscriber):
    var inner: Self.S
    var filter: EnvFilter

    @always_inline
    def __init__(out self, var inner: Self.S, var filter: EnvFilter):
        self.inner = inner^
        self.filter = filter^

    @always_inline
    def on_event(mut self, mut event: Event):
        # Defence in depth — the Logger should already have early-outed via
        # `enabled`, but a Tee that fans out *after* a permissive Logger may
        # still send us events that should be dropped here.
        if self.filter.enabled(event.level, event.target):
            self.inner.on_event(event)

    @always_inline
    def enabled(self, level: Level, target: StaticString) -> Bool:
        return self.filter.enabled(level, target) and self.inner.enabled(
            level, target
        )
