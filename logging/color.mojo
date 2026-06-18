# Color — ANSI SGR (Select Graphic Rendition) helper for user-formatted log
# content. The default `FmtSubscriber` paints the level and target tokens
# itself; this struct exists so a caller can colour the *message* or *field
# values* without hand-rolling escape sequences. Constants are `comptime
# StaticString` so the common case (`Color.red("oops")`) is a single allocation
# and the escape codes fold at the call site.
#
# Honest about its limits: emitting colour codes here does NOT consult NO_COLOR
# / FORCE_COLOR / isatty — the caller decides. Use `Color.enabled()` (the same
# resolution `FmtSubscriber.default()` uses) to gate, or `Color.paint_if(...)`
# to wrap that gate in a single call.

from std.os import isatty, getenv


struct Color:
    """ANSI SGR palette + style helpers for caller-coloured log content.

    All constants are `StaticString` and fold at compile time. Helpers return
    `String` (heap), one allocation per call. The struct holds no state — every
    member is `comptime` or `@staticmethod`."""

    # --- Reset / styles ----------------------------------------------------
    comptime RESET: StaticString = "\x1b[0m"
    comptime BOLD: StaticString = "\x1b[1m"
    comptime DIM: StaticString = "\x1b[2m"
    comptime ITALIC: StaticString = "\x1b[3m"
    comptime UNDERLINE: StaticString = "\x1b[4m"
    comptime BLINK: StaticString = "\x1b[5m"
    comptime REVERSE: StaticString = "\x1b[7m"
    comptime HIDDEN: StaticString = "\x1b[8m"
    comptime STRIKE: StaticString = "\x1b[9m"

    # --- Foreground (8 standard) ------------------------------------------
    comptime BLACK: StaticString = "\x1b[30m"
    comptime RED: StaticString = "\x1b[31m"
    comptime GREEN: StaticString = "\x1b[32m"
    comptime YELLOW: StaticString = "\x1b[33m"
    comptime BLUE: StaticString = "\x1b[34m"
    comptime MAGENTA: StaticString = "\x1b[35m"
    comptime CYAN: StaticString = "\x1b[36m"
    comptime WHITE: StaticString = "\x1b[37m"

    # --- Foreground (8 bright) --------------------------------------------
    comptime BRIGHT_BLACK: StaticString = "\x1b[90m"
    comptime BRIGHT_RED: StaticString = "\x1b[91m"
    comptime BRIGHT_GREEN: StaticString = "\x1b[92m"
    comptime BRIGHT_YELLOW: StaticString = "\x1b[93m"
    comptime BRIGHT_BLUE: StaticString = "\x1b[94m"
    comptime BRIGHT_MAGENTA: StaticString = "\x1b[95m"
    comptime BRIGHT_CYAN: StaticString = "\x1b[96m"
    comptime BRIGHT_WHITE: StaticString = "\x1b[97m"

    # --- Background (8 standard) ------------------------------------------
    comptime BG_BLACK: StaticString = "\x1b[40m"
    comptime BG_RED: StaticString = "\x1b[41m"
    comptime BG_GREEN: StaticString = "\x1b[42m"
    comptime BG_YELLOW: StaticString = "\x1b[43m"
    comptime BG_BLUE: StaticString = "\x1b[44m"
    comptime BG_MAGENTA: StaticString = "\x1b[45m"
    comptime BG_CYAN: StaticString = "\x1b[46m"
    comptime BG_WHITE: StaticString = "\x1b[47m"

    # --- Background (8 bright) --------------------------------------------
    comptime BG_BRIGHT_BLACK: StaticString = "\x1b[100m"
    comptime BG_BRIGHT_RED: StaticString = "\x1b[101m"
    comptime BG_BRIGHT_GREEN: StaticString = "\x1b[102m"
    comptime BG_BRIGHT_YELLOW: StaticString = "\x1b[103m"
    comptime BG_BRIGHT_BLUE: StaticString = "\x1b[104m"
    comptime BG_BRIGHT_MAGENTA: StaticString = "\x1b[105m"
    comptime BG_BRIGHT_CYAN: StaticString = "\x1b[106m"
    comptime BG_BRIGHT_WHITE: StaticString = "\x1b[107m"

    # ------------------------------------------------------------------ core

    @staticmethod
    @always_inline
    def paint(code: String, text: String) -> String:
        """Wrap `text` in `code` and a trailing `RESET`. The canonical helper —
        every named convenience below routes through this so the reset is in
        exactly one place."""
        return code + text + String(Color.RESET)

    @staticmethod
    def paint_if(ansi: Bool, code: String, text: String) -> String:
        """`paint(code, text)` if `ansi` is True, else `text` unchanged. Lets
        the caller honour the same NO_COLOR / FORCE_COLOR / isatty decision
        the subscriber made without two code paths."""
        if ansi:
            return Color.paint(code, text)
        return text

    @staticmethod
    def enabled() -> Bool:
        """Mirror of `FmtSubscriber.default()`'s colour resolution: ANSI is on
        iff stderr is a TTY, `NO_COLOR` is unset, and `FORCE_COLOR` /
        `CLICOLOR_FORCE` did not override the decision. Read once at startup
        and pass the result to `paint_if` for a per-call gate, or query each
        time — both are cheap (env reads are O(env) but not a syscall on glibc)."""
        var force = (
            getenv("FORCE_COLOR").byte_length() > 0
            or getenv("CLICOLOR_FORCE").byte_length() > 0
        )
        var no_color = getenv("NO_COLOR").byte_length() > 0
        if no_color:
            return False
        if force:
            return True
        return isatty(2)

    # ---------------------------------------------------------- 256-color

    @staticmethod
    def fg256(n: UInt8) -> String:
        """xterm 256-color foreground escape: `\\x1b[38;5;{n}m`."""
        return "\x1b[38;5;" + String(Int(n)) + "m"

    @staticmethod
    def bg256(n: UInt8) -> String:
        """xterm 256-color background escape: `\\x1b[48;5;{n}m`."""
        return "\x1b[48;5;" + String(Int(n)) + "m"

    # -------------------------------------------------------------- truecolor

    @staticmethod
    def fg_rgb(r: UInt8, g: UInt8, b: UInt8) -> String:
        """24-bit truecolor foreground: `\\x1b[38;2;{r};{g};{b}m`."""
        return (
            "\x1b[38;2;"
            + String(Int(r))
            + ";"
            + String(Int(g))
            + ";"
            + String(Int(b))
            + "m"
        )

    @staticmethod
    def bg_rgb(r: UInt8, g: UInt8, b: UInt8) -> String:
        """24-bit truecolor background: `\\x1b[48;2;{r};{g};{b}m`."""
        return (
            "\x1b[48;2;"
            + String(Int(r))
            + ";"
            + String(Int(g))
            + ";"
            + String(Int(b))
            + "m"
        )

    # --------------------------------------------------------- foreground fns

    @staticmethod
    @always_inline
    def black(text: String) -> String:
        return Color.paint(Color.BLACK, text)

    @staticmethod
    @always_inline
    def red(text: String) -> String:
        return Color.paint(Color.RED, text)

    @staticmethod
    @always_inline
    def green(text: String) -> String:
        return Color.paint(Color.GREEN, text)

    @staticmethod
    @always_inline
    def yellow(text: String) -> String:
        return Color.paint(Color.YELLOW, text)

    @staticmethod
    @always_inline
    def blue(text: String) -> String:
        return Color.paint(Color.BLUE, text)

    @staticmethod
    @always_inline
    def magenta(text: String) -> String:
        return Color.paint(Color.MAGENTA, text)

    @staticmethod
    @always_inline
    def cyan(text: String) -> String:
        return Color.paint(Color.CYAN, text)

    @staticmethod
    @always_inline
    def white(text: String) -> String:
        return Color.paint(Color.WHITE, text)

    # ----------------------------------------------------------------- styles

    @staticmethod
    @always_inline
    def bold(text: String) -> String:
        return Color.paint(Color.BOLD, text)

    @staticmethod
    @always_inline
    def dim(text: String) -> String:
        return Color.paint(Color.DIM, text)

    @staticmethod
    @always_inline
    def italic(text: String) -> String:
        return Color.paint(Color.ITALIC, text)

    @staticmethod
    @always_inline
    def underline(text: String) -> String:
        return Color.paint(Color.UNDERLINE, text)

    @staticmethod
    @always_inline
    def reverse(text: String) -> String:
        return Color.paint(Color.REVERSE, text)

    @staticmethod
    @always_inline
    def strike(text: String) -> String:
        return Color.paint(Color.STRIKE, text)
