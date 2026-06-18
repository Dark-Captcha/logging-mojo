# Event — the single value that flows from a `Logger.<level>(...)` call into a
# `Subscriber.on_event` handler. The Event borrows the message and field list
# from the caller's frame; subscribers that need to retain (file rotation,
# in-memory capture, async forwarding) must `.copy()` the pieces they keep.
#
# Designed as a "view" rather than an "owner" so the hot path avoids copies.
# The Logger constructs an Event on the stack, hands a mutable reference to the
# subscriber, the subscriber formats and writes, then the Event drops with the
# call frame.

from chrono import Instant, ClockId
from logging.field import Field
from logging.level import Level


# Wall-clock instant — REALTIME, the only clock with a meaningful textual
# rendering. A monotonic timestamp on a log line is meaningless to a human
# reader; if a subscriber wants the perf-counter clock, it can sample
# Instant[ClockId.MONOTONIC] itself.
comptime EventInstant = Instant[ClockId.REALTIME]


struct Event(Movable):
    var level: Level
    var target: StaticString
    var message: String
    var fields: List[Field]
    var timestamp: EventInstant

    @always_inline
    def __init__(
        out self,
        level: Level,
        target: StaticString,
        var message: String,
        var fields: List[Field],
        timestamp: EventInstant,
    ):
        self.level = level
        self.target = target
        self.message = message^
        self.fields = fields^
        self.timestamp = timestamp
