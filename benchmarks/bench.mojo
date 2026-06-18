# bench.mojo — coarse latency numbers per log call. Run with
#   pixi run bench
# Writes to a `JsonSubscriber` aimed at /dev/null so the kernel write path is
# real but the terminal isn't a factor; flip the fd to 2 to measure with a tty
# on the receiving end.

from std.time import perf_counter_ns
from std.io import FileDescriptor

from chrono import Instant, ClockId

from logging import (
    Field,
    Level,
    Logger,
    EnvFilter,
    Filtered,
    FmtSubscriber,
    JsonSubscriber,
    NopSubscriber,
    TestSubscriber,
)
from logging.event import Event
from logging.subscriber import Subscriber


comptime N: Int = 200_000


def bench_comptime_disabled() raises:
    # `trace` is dead code at the default LOG_COMPILE_MIN_LEVEL=DEBUG.
    var sub = NopSubscriber()
    var log = Logger[NopSubscriber](sub^, min_level=Level.TRACE, target="bench")
    var t0 = perf_counter_ns()
    for i in range(N):
        log.trace("nope", Field.int("i", i))
    var t1 = perf_counter_ns()
    print(
        "comptime-disabled trace:",
        Float64(t1 - t0) / Float64(N),
        "ns/call (",
        N,
        " calls,",
        t1 - t0,
        "ns total)",
    )


def bench_runtime_disabled() raises:
    # Calls below `min_level`. The comptime gate lets these through, but the
    # runtime compare drops them before any allocation.
    var sub = NopSubscriber()
    var log = Logger[NopSubscriber](sub^, min_level=Level.WARN, target="bench")
    var t0 = perf_counter_ns()
    for i in range(N):
        log.info("nope", Field.int("i", i))
    var t1 = perf_counter_ns()
    print(
        "runtime-disabled info:",
        Float64(t1 - t0) / Float64(N),
        "ns/call",
    )


struct AlwaysOnNop(Subscriber):
    var n: Int

    @always_inline
    def __init__(out self):
        self.n = 0

    @always_inline
    def on_event(mut self, mut event: Event):
        self.n += 1

    @always_inline
    def enabled(self, level: Level, target: StaticString) -> Bool:
        return True


def bench_enabled_alwayson_no_fields() raises:
    var sub = AlwaysOnNop()
    var log = Logger[AlwaysOnNop](sub^, min_level=Level.TRACE, target="bench")
    var t0 = perf_counter_ns()
    for _ in range(N):
        log.info("hi")
    var t1 = perf_counter_ns()
    print(
        "enabled no-fields  info:",
        Float64(t1 - t0) / Float64(N),
        "ns/call (",
        log.subscriber.n,
        "events)",
    )


def bench_enabled_alwayson_3_fields() raises:
    var sub = AlwaysOnNop()
    var log = Logger[AlwaysOnNop](sub^, min_level=Level.TRACE, target="bench")
    var t0 = perf_counter_ns()
    for i in range(N):
        log.info(
            "hi",
            Field.int("i", i),
            Field.str("kind", "tick"),
            Field.bool("ok", True),
        )
    var t1 = perf_counter_ns()
    print(
        "enabled 3-fields    info:",
        Float64(t1 - t0) / Float64(N),
        "ns/call",
    )


def bench_fmt_to_stdout() raises:
    # Real formatter into a JSON sink aimed at stdout — measures the actual
    # work of formatting and a `write` per event. Redirect with `> /dev/null`
    # to take the terminal out of the loop.
    var sub = JsonSubscriber(fd=1)
    var log = Logger[JsonSubscriber](
        sub^, min_level=Level.TRACE, target="bench"
    )
    var t0 = perf_counter_ns()
    var iterations = N // 10  # actual writes are expensive; sample fewer
    for i in range(iterations):
        log.info(
            "tick",
            Field.int("i", i),
            Field.str("k", "v"),
            Field.bool("ok", True),
        )
    var t1 = perf_counter_ns()
    print(
        "fmt(json,stdout)    info:",
        Float64(t1 - t0) / Float64(iterations),
        "ns/call (",
        iterations,
        "events; pipe stdout to /dev/null for a fair number)",
    )




def bench_fmt_format_only() raises:
    # FmtSubscriber._format directly — measures the per-event formatting cost
    # without the kernel write overhead. This is the hot path inside the sink.
    var sub = FmtSubscriber(ansi=False, fd=1)
    var inst = Instant[ClockId.REALTIME].now()
    var fl0 = List[Field]()
    fl0.append(Field.int("i", 0))
    fl0.append(Field.str("k", "v"))
    fl0.append(Field.bool("ok", True))
    var ev = Event(Level.INFO, "bench", String("tick"), fl0^, inst)
    var sink = String("")
    var t0 = perf_counter_ns()
    for _ in range(N):
        var fl = List[Field]()
        fl.append(Field.int("i", 0))
        fl.append(Field.str("k", "v"))
        fl.append(Field.bool("ok", True))
        ev = Event(Level.INFO, "bench", String("tick"), fl^, inst)
        sink = sub._format(ev)
    var t1 = perf_counter_ns()
    print(
        "fmt._format(3-fields):",
        Float64(t1 - t0) / Float64(N),
        "ns/call (last=",
        len(sink),
        "bytes)",
    )


def bench_json_format_only() raises:
    var sub = JsonSubscriber(fd=1)
    var inst = Instant[ClockId.REALTIME].now()
    var ev_init = List[Field]()
    ev_init.append(Field.int("i", 0))
    ev_init.append(Field.str("k", "v"))
    ev_init.append(Field.bool("ok", True))
    var ev = Event(Level.INFO, "bench", String("tick"), ev_init^, inst)
    var sink = String("")
    var t0 = perf_counter_ns()
    for _ in range(N):
        var fl = List[Field]()
        fl.append(Field.int("i", 0))
        fl.append(Field.str("k", "v"))
        fl.append(Field.bool("ok", True))
        ev = Event(Level.INFO, "bench", String("tick"), fl^, inst)
        sink = sub._format(ev)
    var t1 = perf_counter_ns()
    print(
        "json._format(3-fields):",
        Float64(t1 - t0) / Float64(N),
        "ns/call (last=",
        len(sink),
        "bytes)",
    )


def main() raises:
    print("logging-mojo bench (N =", N, ")")
    bench_comptime_disabled()
    bench_runtime_disabled()
    bench_enabled_alwayson_no_fields()
    bench_enabled_alwayson_3_fields()
    bench_fmt_to_stdout()
    bench_fmt_format_only()
    bench_json_format_only()
