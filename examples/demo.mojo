# examples/demo.mojo — small tour of logging-mojo.
# Run with `pixi run demo`. Set `LOG` to control verbosity:
#   pixi run demo                                  → default INFO
#   LOG=debug pixi run demo                        → DEBUG and above
#   LOG=info,h2=trace pixi run demo                → h2.* targets trace, rest info
#   NO_COLOR=1 pixi run demo                       → kill ANSI
#   FORCE_COLOR=1 pixi run demo > /tmp/log.txt     → keep ANSI even when redirected

import logging
from logging import Field, Color


def serve_request(mut log: logging.Logger[logging.Filtered[logging.FmtSubscriber]]) raises:
    var req_log = log.with_target("http_client.h2")
    var ansi = Color.enabled()  # gate caller-side colour on the same rules
    req_log.debug(
        "stream open",
        Field.int("stream_id", 5),
        Field.str("method", "GET"),
        Field.str("path", "/api/users"),
    )
    req_log.info(
        "request started",
        Field.str("method", "GET"),
        Field.str("path", "/api/users"),
    )
    req_log.trace(
        "frame recv",
        Field.int("stream_id", 5),
        Field.str("type", "DATA"),
        Field.int("flags", 0x1),
    )
    req_log.warn(
        "slow " + Color.paint_if(ansi, Color.YELLOW, "(>300ms)"),
        Field.float("rtt_ms", 312.4),
        Field.int("bytes", 18_944),
    )
    req_log.info(
        "request done", Field.int("status", 200), Field.int("bytes", 4096)
    )


def main() raises:
    var log = logging.init()
    var ansi = Color.enabled()

    log.info(
        "logging-mojo demo",
        Field.str("version", "0.1.0"),
        Field.str("hint", 'try LOG=debug or LOG="info,http_client=trace"'),
    )

    serve_request(log)

    # Caller-coloured message body. `paint_if` keeps the line plain when
    # NO_COLOR=1 or stderr isn't a TTY — same rule the subscriber uses.
    log.error(
        Color.paint_if(ansi, Color.BOLD, "connection lost")
            + " — "
            + Color.paint_if(ansi, Color.RED, "10.0.0.5:443"),
        Field.bool("will_retry", True),
        Field.int("attempt", 2),
    )
