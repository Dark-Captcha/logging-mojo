# init() — the one-line "give me sensible logging" entry. Reads the `LOG` env
# var into an `EnvFilter`, builds a `FmtSubscriber` with auto-detected colours
# (TTY + NO_COLOR / FORCE_COLOR), wraps the two in `Filtered`, and returns the
# `Logger`.
#
# The default level is INFO when `LOG` is unset — anything noisier requires the
# user to opt in. The Logger's own `min_level` is set to TRACE here so it never
# gets in the EnvFilter's way; the filter is the single source of truth.

from logging.filter.env import EnvFilter
from logging.filter.filtered import Filtered
from logging.level import Level
from logging.logger import Logger
from logging.subscribers.fmt import FmtSubscriber


def init(target: StaticString = "root") raises -> Logger[Filtered[FmtSubscriber]]:
    """Build the default logger: env-filter + pretty stderr. The `target`
    parameter sets the Logger's default target for events emitted directly off
    it; downstream consumers should call `with_target` to fork a Logger with
    a more specific name for each subsystem."""
    var filter = EnvFilter.from_env()
    var sub = FmtSubscriber.default()
    var filtered = Filtered[FmtSubscriber](sub^, filter^)
    return Logger[Filtered[FmtSubscriber]](
        filtered^, min_level=Level.TRACE, target=target
    )
