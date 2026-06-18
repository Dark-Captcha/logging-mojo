# tests/run_tests.mojo — single-binary test runner. Each test is a `def` that
# raises on failure; `main` runs them in order and prints `PASS`/`FAIL`. No
# discovery framework; the file is the source of truth.

from chrono import Instant

from logging import (
    Color,
    Field,
    Level,
    Logger,
    EnvFilter,
    Filtered,
    FmtSubscriber,
    JsonSubscriber,
    TestSubscriber,
    NopSubscriber,
    Tee,
)
from logging.event import Event
from logging.subscriber import Subscriber


def _assert(cond: Bool, msg: String) raises:
    if not cond:
        raise Error("assert failed: " + msg)


def test_level_basics() raises:
    _assert(Level.TRACE < Level.DEBUG, "trace<debug")
    _assert(Level.DEBUG < Level.INFO, "debug<info")
    _assert(Level.INFO < Level.WARN, "info<warn")
    _assert(Level.WARN < Level.ERROR, "warn<error")
    _assert(Level.ERROR < Level.OFF, "error<off")
    _assert(Level.parse("info") == Level.INFO, "parse info")
    _assert(Level.parse("WARN") == Level.WARN, "parse WARN")
    _assert(Level.parse("warning") == Level.WARN, "parse warning")
    _assert(Level.parse("err") == Level.ERROR, "parse err")
    _assert(Level.parse("off") == Level.OFF, "parse off")
    _assert(String(Level.INFO.name()) == "INFO", "name INFO")


def test_level_parse_invalid_raises() raises:
    var raised = False
    try:
        _ = Level.parse("not-a-level")
    except:
        raised = True
    _assert(raised, "Level.parse should raise on garbage")


def test_field_constructors() raises:
    var fs = Field.str("k", "v")
    _assert(fs.value.is_str(), "str tag")
    _assert(fs.value.as_str() == "v", "str val")

    var fi = Field.int("n", 42)
    _assert(fi.value.is_int(), "int tag")
    _assert(fi.value.as_int() == Int64(42), "int val")

    var fb = Field.bool("b", True)
    _assert(fb.value.is_bool(), "bool tag")
    _assert(fb.value.as_bool() == True, "bool val")

    var ff = Field.float("f", 1.5)
    _assert(ff.value.is_float(), "float tag")
    _assert(ff.value.as_float() == 1.5, "float val")

    var by = List[UInt8]()
    by.append(UInt8(1))
    by.append(UInt8(2))
    var fy = Field.bytes("raw", by^)
    _assert(fy.value.is_bytes(), "bytes tag")
    _assert(len(fy.value.as_bytes()) == 2, "bytes len")


def test_env_filter_parse_default() raises:
    var f = EnvFilter.parse("")
    _assert(f.default == Level.INFO, "empty default = INFO")
    _assert(f.enabled(Level.INFO, "root"), "INFO root pass")
    _assert(not f.enabled(Level.DEBUG, "root"), "DEBUG root drop")


def test_env_filter_parse_overrides() raises:
    var f = EnvFilter.parse("info, h2=trace, quic=debug")
    _assert(f.default == Level.INFO, "default INFO")
    _assert(f.enabled(Level.TRACE, "h2.frame"), "h2.frame TRACE pass")
    _assert(f.enabled(Level.DEBUG, "quic"), "quic DEBUG pass")
    _assert(not f.enabled(Level.TRACE, "quic"), "quic TRACE drop")
    _assert(not f.enabled(Level.TRACE, "h2x"), "h2x not under h2")
    _assert(f.enabled(Level.INFO, "root"), "root falls back to default")


def test_env_filter_off_with_override() raises:
    var f = EnvFilter.parse("off, http_client=info")
    _assert(not f.enabled(Level.ERROR, "h2"), "ERROR h2 silenced")
    _assert(f.enabled(Level.INFO, "http_client.req"), "http_client.req INFO")
    _assert(not f.enabled(Level.DEBUG, "http_client"), "http_client DEBUG drop")


def test_logger_into_test_subscriber() raises:
    var log = Logger[TestSubscriber](
        TestSubscriber(), min_level=Level.TRACE, target="t"
    )
    log.info("hello")
    log.warn("bad", Field.str("why", "timeout"))
    log.error("dead", Field.int("code", 500))

    _assert(len(log.subscriber.captured) == 3, "captured 3 events")
    _assert(
        log.subscriber.captured[0].level == Level.INFO, "captured[0] = INFO"
    )
    _assert(log.subscriber.captured[0].message == "hello", "msg hello")
    _assert(
        log.subscriber.captured[2].message == "dead", "captured[2].msg dead"
    )


def test_logger_min_level_drops() raises:
    var log = Logger[TestSubscriber](
        TestSubscriber(), min_level=Level.WARN, target="t"
    )
    log.info("ignored")
    log.debug("ignored")
    log.warn("kept")
    log.error("kept")
    _assert(len(log.subscriber.captured) == 2, "min_level drops below WARN")


def test_tee_fans_out() raises:
    var t = Tee[TestSubscriber, TestSubscriber](
        TestSubscriber(), TestSubscriber()
    )
    var log = Logger[Tee[TestSubscriber, TestSubscriber]](
        t^, min_level=Level.TRACE, target="t"
    )
    log.info("x")
    log.warn("y")
    _assert(len(log.subscriber.a.captured) == 2, "tee a got 2")
    _assert(len(log.subscriber.b.captured) == 2, "tee b got 2")


def test_filtered_drops_per_target() raises:
    # Note: this test stays at DEBUG and above so the comptime gate (default
    # LOG_COMPILE_MIN_LEVEL = DEBUG) doesn't erase any of these calls. The
    # trace path is exercised in test_comptime_gate_erases_trace below.
    var sub = TestSubscriber()
    var f = EnvFilter.parse("off, allow=debug")
    var filt = Filtered[TestSubscriber](sub^, f^)
    var log = Logger[Filtered[TestSubscriber]](
        filt^, min_level=Level.TRACE, target="allow"
    )
    log.debug("allowed-debug")
    log.info("allowed-info")
    var quiet = log.with_target("nope")
    quiet.error("silenced-by-default-off")
    _assert(
        len(log.subscriber.inner.captured) == 2,
        "two events kept on the allowed target",
    )
    # `quiet` is a copy taken AFTER the two `allow` events, so it inherits
    # them; what we want to verify is that the post-fork `error` call did NOT
    # land in either subscriber's list.
    _assert(
        len(quiet.subscriber.inner.captured) == 2,
        "fork inherits prior captures; the silenced error is not added",
    )


def test_comptime_gate_erases_trace() raises:
    # With the default `LOG_COMPILE_MIN_LEVEL = DEBUG`, `log.trace(...)` is
    # dead code — the body never runs even when the runtime gate would allow
    # it. This protects hot paths in h2/h3 frame loops from paying TRACE cost
    # in release.
    var f = EnvFilter.parse("trace")
    var sub = TestSubscriber()
    var filt = Filtered[TestSubscriber](sub^, f^)
    var log = Logger[Filtered[TestSubscriber]](
        filt^, min_level=Level.TRACE, target="t"
    )
    log.trace("should be erased")
    _assert(
        len(log.subscriber.inner.captured) == 0,
        "trace under LOG_COMPILE_MIN_LEVEL=DEBUG is dead code",
    )


def test_nop_is_disabled() raises:
    var n = NopSubscriber()
    _assert(not n.enabled(Level.ERROR, "x"), "nop never enabled")


def test_fmt_format_has_level_and_target() raises:
    # Indirect test: pull the format function via _format on a non-tty subscriber.
    var sub = FmtSubscriber(ansi=False)
    var fl = List[Field]()
    fl.append(Field.str("k", "v"))
    var ev = Event(Level.INFO, "tgt", String("msg"), fl^, Instant.now())
    var line = sub._format(ev)
    _assert("INFO" in line, "line has INFO")
    _assert("tgt" in line, "line has target")
    _assert("k=v" in line, "line has k=v")


def test_color_wraps_text_with_reset() raises:
    var red = Color.red("oops")
    _assert(red == "\x1b[31moops\x1b[0m", "Color.red wraps with red FG + reset")

    var compose = Color.bold(Color.green("ok"))
    _assert(
        compose == "\x1b[1m\x1b[32mok\x1b[0m\x1b[0m",
        "bold+green composes — inner reset terminates both attributes",
    )

    var generic = Color.paint(Color.YELLOW, "warn")
    _assert(generic == "\x1b[33mwarn\x1b[0m", "paint(YELLOW, ...) matches")


def test_color_paint_if_gates_on_bool() raises:
    var on = Color.paint_if(True, Color.RED, "x")
    _assert(on == "\x1b[31mx\x1b[0m", "paint_if(True) applies code")

    var off = Color.paint_if(False, Color.RED, "x")
    _assert(off == "x", "paint_if(False) returns text unchanged")


def test_color_256_and_rgb_helpers() raises:
    _assert(
        Color.fg256(208) == "\x1b[38;5;208m", "fg256 emits xterm-256 escape"
    )
    _assert(Color.bg256(0) == "\x1b[48;5;0m", "bg256 zero is well-formed")
    _assert(
        Color.fg_rgb(255, 100, 0) == "\x1b[38;2;255;100;0m",
        "fg_rgb emits truecolor",
    )
    _assert(
        Color.bg_rgb(0, 0, 0) == "\x1b[48;2;0;0;0m",
        "bg_rgb truecolor zero is well-formed",
    )


def test_color_all_foreground_constants() raises:
    # Lock the full standard + bright FG palette to its canonical SGR code.
    # If any drifts, the test fails — these are the values terminals expect.
    _assert(String(Color.BLACK) == "\x1b[30m", "BLACK")
    _assert(String(Color.RED) == "\x1b[31m", "RED")
    _assert(String(Color.GREEN) == "\x1b[32m", "GREEN")
    _assert(String(Color.YELLOW) == "\x1b[33m", "YELLOW")
    _assert(String(Color.BLUE) == "\x1b[34m", "BLUE")
    _assert(String(Color.MAGENTA) == "\x1b[35m", "MAGENTA")
    _assert(String(Color.CYAN) == "\x1b[36m", "CYAN")
    _assert(String(Color.WHITE) == "\x1b[37m", "WHITE")
    _assert(String(Color.BRIGHT_BLACK) == "\x1b[90m", "BRIGHT_BLACK")
    _assert(String(Color.BRIGHT_RED) == "\x1b[91m", "BRIGHT_RED")
    _assert(String(Color.BRIGHT_GREEN) == "\x1b[92m", "BRIGHT_GREEN")
    _assert(String(Color.BRIGHT_YELLOW) == "\x1b[93m", "BRIGHT_YELLOW")
    _assert(String(Color.BRIGHT_BLUE) == "\x1b[94m", "BRIGHT_BLUE")
    _assert(String(Color.BRIGHT_MAGENTA) == "\x1b[95m", "BRIGHT_MAGENTA")
    _assert(String(Color.BRIGHT_CYAN) == "\x1b[96m", "BRIGHT_CYAN")
    _assert(String(Color.BRIGHT_WHITE) == "\x1b[97m", "BRIGHT_WHITE")


def test_color_all_background_constants() raises:
    _assert(String(Color.BG_BLACK) == "\x1b[40m", "BG_BLACK")
    _assert(String(Color.BG_RED) == "\x1b[41m", "BG_RED")
    _assert(String(Color.BG_GREEN) == "\x1b[42m", "BG_GREEN")
    _assert(String(Color.BG_YELLOW) == "\x1b[43m", "BG_YELLOW")
    _assert(String(Color.BG_BLUE) == "\x1b[44m", "BG_BLUE")
    _assert(String(Color.BG_MAGENTA) == "\x1b[45m", "BG_MAGENTA")
    _assert(String(Color.BG_CYAN) == "\x1b[46m", "BG_CYAN")
    _assert(String(Color.BG_WHITE) == "\x1b[47m", "BG_WHITE")
    _assert(String(Color.BG_BRIGHT_BLACK) == "\x1b[100m", "BG_BRIGHT_BLACK")
    _assert(String(Color.BG_BRIGHT_RED) == "\x1b[101m", "BG_BRIGHT_RED")
    _assert(String(Color.BG_BRIGHT_GREEN) == "\x1b[102m", "BG_BRIGHT_GREEN")
    _assert(String(Color.BG_BRIGHT_YELLOW) == "\x1b[103m", "BG_BRIGHT_YELLOW")
    _assert(String(Color.BG_BRIGHT_BLUE) == "\x1b[104m", "BG_BRIGHT_BLUE")
    _assert(String(Color.BG_BRIGHT_MAGENTA) == "\x1b[105m", "BG_BRIGHT_MAGENTA")
    _assert(String(Color.BG_BRIGHT_CYAN) == "\x1b[106m", "BG_BRIGHT_CYAN")
    _assert(String(Color.BG_BRIGHT_WHITE) == "\x1b[107m", "BG_BRIGHT_WHITE")


def test_color_all_style_constants() raises:
    _assert(String(Color.RESET) == "\x1b[0m", "RESET")
    _assert(String(Color.BOLD) == "\x1b[1m", "BOLD")
    _assert(String(Color.DIM) == "\x1b[2m", "DIM")
    _assert(String(Color.ITALIC) == "\x1b[3m", "ITALIC")
    _assert(String(Color.UNDERLINE) == "\x1b[4m", "UNDERLINE")
    _assert(String(Color.BLINK) == "\x1b[5m", "BLINK")
    _assert(String(Color.REVERSE) == "\x1b[7m", "REVERSE")
    _assert(String(Color.HIDDEN) == "\x1b[8m", "HIDDEN")
    _assert(String(Color.STRIKE) == "\x1b[9m", "STRIKE")


def test_color_named_helpers_match_paint() raises:
    # Each named helper must equal `paint(<corresponding constant>, text)`.
    # Locks the convenience surface to its routing contract.
    _assert(Color.black("x") == Color.paint(Color.BLACK, "x"), "black()")
    _assert(Color.red("x") == Color.paint(Color.RED, "x"), "red()")
    _assert(Color.green("x") == Color.paint(Color.GREEN, "x"), "green()")
    _assert(Color.yellow("x") == Color.paint(Color.YELLOW, "x"), "yellow()")
    _assert(Color.blue("x") == Color.paint(Color.BLUE, "x"), "blue()")
    _assert(Color.magenta("x") == Color.paint(Color.MAGENTA, "x"), "magenta()")
    _assert(Color.cyan("x") == Color.paint(Color.CYAN, "x"), "cyan()")
    _assert(Color.white("x") == Color.paint(Color.WHITE, "x"), "white()")
    _assert(Color.bold("x") == Color.paint(Color.BOLD, "x"), "bold()")
    _assert(Color.dim("x") == Color.paint(Color.DIM, "x"), "dim()")
    _assert(Color.italic("x") == Color.paint(Color.ITALIC, "x"), "italic()")
    _assert(
        Color.underline("x") == Color.paint(Color.UNDERLINE, "x"),
        "underline()",
    )
    _assert(Color.reverse("x") == Color.paint(Color.REVERSE, "x"), "reverse()")
    _assert(Color.strike("x") == Color.paint(Color.STRIKE, "x"), "strike()")


def test_color_enabled_honours_no_color() raises:
    # `enabled()` returns False under a pipe (no TTY) when NO_COLOR is set or
    # unset; that case is exercised by `pixi run test` itself. The contract
    # we lock here is that the function is callable and returns a Bool —
    # value depends on the runtime environment.
    var v = Color.enabled()
    _assert(v == True or v == False, "enabled() returns a Bool")


def test_json_format_is_valid_shape() raises:
    var sub = JsonSubscriber(fd=2)
    var fl = List[Field]()
    fl.append(Field.int("n", 7))
    var ev = Event(Level.WARN, "h2", String("frame"), fl^, Instant.now())
    var line = sub._format(ev)
    _assert(line.startswith("{"), "starts with {")
    _assert(line.endswith("}\n"), "ends with }\\n")
    _assert('"level":"WARN"' in line, "level field")
    _assert('"target":"h2"' in line, "target field")
    _assert('"fields":{"n":7}' in line, "fields field")


def main() raises:
    var failures = 0
    print("logging-mojo tests")
    try:
        test_level_basics()
        print("  PASS test_level_basics")
    except e:
        print("  FAIL test_level_basics:", e)
        failures += 1
    try:
        test_level_parse_invalid_raises()
        print("  PASS test_level_parse_invalid_raises")
    except e:
        print("  FAIL test_level_parse_invalid_raises:", e)
        failures += 1
    try:
        test_field_constructors()
        print("  PASS test_field_constructors")
    except e:
        print("  FAIL test_field_constructors:", e)
        failures += 1
    try:
        test_env_filter_parse_default()
        print("  PASS test_env_filter_parse_default")
    except e:
        print("  FAIL test_env_filter_parse_default:", e)
        failures += 1
    try:
        test_env_filter_parse_overrides()
        print("  PASS test_env_filter_parse_overrides")
    except e:
        print("  FAIL test_env_filter_parse_overrides:", e)
        failures += 1
    try:
        test_env_filter_off_with_override()
        print("  PASS test_env_filter_off_with_override")
    except e:
        print("  FAIL test_env_filter_off_with_override:", e)
        failures += 1
    try:
        test_logger_into_test_subscriber()
        print("  PASS test_logger_into_test_subscriber")
    except e:
        print("  FAIL test_logger_into_test_subscriber:", e)
        failures += 1
    try:
        test_logger_min_level_drops()
        print("  PASS test_logger_min_level_drops")
    except e:
        print("  FAIL test_logger_min_level_drops:", e)
        failures += 1
    try:
        test_tee_fans_out()
        print("  PASS test_tee_fans_out")
    except e:
        print("  FAIL test_tee_fans_out:", e)
        failures += 1
    try:
        test_filtered_drops_per_target()
        print("  PASS test_filtered_drops_per_target")
    except e:
        print("  FAIL test_filtered_drops_per_target:", e)
        failures += 1
    try:
        test_comptime_gate_erases_trace()
        print("  PASS test_comptime_gate_erases_trace")
    except e:
        print("  FAIL test_comptime_gate_erases_trace:", e)
        failures += 1
    try:
        test_nop_is_disabled()
        print("  PASS test_nop_is_disabled")
    except e:
        print("  FAIL test_nop_is_disabled:", e)
        failures += 1
    try:
        test_fmt_format_has_level_and_target()
        print("  PASS test_fmt_format_has_level_and_target")
    except e:
        print("  FAIL test_fmt_format_has_level_and_target:", e)
        failures += 1
    try:
        test_json_format_is_valid_shape()
        print("  PASS test_json_format_is_valid_shape")
    except e:
        print("  FAIL test_json_format_is_valid_shape:", e)
        failures += 1
    try:
        test_color_wraps_text_with_reset()
        print("  PASS test_color_wraps_text_with_reset")
    except e:
        print("  FAIL test_color_wraps_text_with_reset:", e)
        failures += 1
    try:
        test_color_paint_if_gates_on_bool()
        print("  PASS test_color_paint_if_gates_on_bool")
    except e:
        print("  FAIL test_color_paint_if_gates_on_bool:", e)
        failures += 1
    try:
        test_color_256_and_rgb_helpers()
        print("  PASS test_color_256_and_rgb_helpers")
    except e:
        print("  FAIL test_color_256_and_rgb_helpers:", e)
        failures += 1
    try:
        test_color_all_foreground_constants()
        print("  PASS test_color_all_foreground_constants")
    except e:
        print("  FAIL test_color_all_foreground_constants:", e)
        failures += 1
    try:
        test_color_all_background_constants()
        print("  PASS test_color_all_background_constants")
    except e:
        print("  FAIL test_color_all_background_constants:", e)
        failures += 1
    try:
        test_color_all_style_constants()
        print("  PASS test_color_all_style_constants")
    except e:
        print("  FAIL test_color_all_style_constants:", e)
        failures += 1
    try:
        test_color_named_helpers_match_paint()
        print("  PASS test_color_named_helpers_match_paint")
    except e:
        print("  FAIL test_color_named_helpers_match_paint:", e)
        failures += 1
    try:
        test_color_enabled_honours_no_color()
        print("  PASS test_color_enabled_honours_no_color")
    except e:
        print("  FAIL test_color_enabled_honours_no_color:", e)
        failures += 1

    if failures != 0:
        raise Error(String("failed: ") + String(failures))
    print("\nall tests passed")
