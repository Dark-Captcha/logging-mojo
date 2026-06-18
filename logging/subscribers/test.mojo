# TestSubscriber — in-memory capture for unit tests. Stores every event's
# (level, target, message) triple so assertions can match on what the system
# *would have* logged without writing anything to a tty. Fields aren't retained
# here (the only test we have so far asserts on text only); add a fields snapshot
# when a test wants it.

from logging.event import Event
from logging.level import Level
from logging.subscriber import Subscriber


struct CapturedEvent(Copyable, Movable):
    var level: Level
    var target: String
    var message: String

    @always_inline
    def __init__(
        out self, level: Level, var target: String, var message: String
    ):
        self.level = level
        self.target = target^
        self.message = message^


struct TestSubscriber(Subscriber):
    var captured: List[CapturedEvent]

    @always_inline
    def __init__(out self):
        self.captured = List[CapturedEvent]()

    @always_inline
    def enabled(self, level: Level, target: StaticString) -> Bool:
        return True

    def on_event(mut self, mut event: Event):
        self.captured.append(
            CapturedEvent(
                event.level, String(event.target), event.message.copy()
            )
        )
