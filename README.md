# logging-mojo

> **Version:** 0.1.0 | **Updated:** 2026-06-18
> **Package:** `logging`

A `tracing`-flavoured structured logger for Mojo — pure Mojo, no FFI, zero
cost when a level is comptime-disabled, useful by default. The
counterpart to `chrono-mojo` for observability.

---

## Status

| Component                  | State                                                                                                                          |
| -------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| Core spine                 | `Level`, `Field`, `Event`, `Logger[S: Subscriber]`, `Subscriber` trait                                                         |
| Subscribers                | `FmtSubscriber` (ANSI pretty), `JsonSubscriber` (NDJSON), `TestSubscriber` (capture), `NopSubscriber`, `Tee[A, B]`              |
| Filtering                  | `EnvFilter` (`LOG=` grammar, per-target overrides), `Filtered[S]` wrapper                                                      |
| Levels                     | `TRACE`, `DEBUG`, `INFO`, `WARN`, `ERROR`, `OFF` — totally ordered, parsed by `Level.parse`                                    |
| Comptime gate              | `LOG_COMPILE_MIN_LEVEL` — calls below it are dead code (DCE-verified)                                                          |
| Caller colour              | `Color` — ANSI SGR palette + style helpers (`paint`, `paint_if`, 16 FG, 16 bright, 16 BG, 16 bright BG, 256-color, truecolor)  |
| Test suite                 | 22 green, `mblack` clean                                                                                                       |
| Toolchain                  | `mojo-compiler 1.0.0b3.dev2026061706`, `mblack 26.5.0.dev2026061706`                                                           |

---

## Why this exists

Mojo's stdlib ships `std.logger` — a single-line, single-level printer with
no spans, no per-target filtering, no structured fields, no composable
sinks. The Mojo stack (`chrono-mojo`, `crypto-mojo`, `tls-mojo`,
`socket-mojo`, the upcoming `http-client-mojo`) needs the same logger Rust
gets from `tracing`: target-scoped, level-gated, field-structured,
sink-agnostic. `logging-mojo` is that logger — small, pure-Mojo,
zero-FFI, monomorphized.

---

## Design pillars

| Pillar                | What it means                                                                                                                                                                                                                                                                                                                |
| --------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Pass-down, not global | Mojo 1.0.0b3 forbids module-level mutable globals. Logger is a value generic on `S: Subscriber`, passed explicitly (slog / Rust `log` shape). No hidden dispatcher, no TLS, no init order trap.                                                                                                                                  |
| Zero cost when gated  | `comptime if Level.X >= LOG_COMPILE_MIN_LEVEL` wraps every level method. Calls below the build-time floor are dead code — verified by `test_comptime_gate_erases_trace` and the bench (`comptime-disabled trace: ~0 ns/call`).                                                                                                   |
| Monomorphized sinks   | `Logger[FmtSubscriber]`, `Logger[Tee[A, B]]`, `Logger[Filtered[S]]` — each combination is a distinct type, direct call, no vtable. Composition is via type parameters, not runtime dispatch.                                                                                                                                     |
| Pure Mojo, no FFI     | `from std.io import FileDescriptor` for stderr writes, `from std.os import getenv, isatty` for env / TTY detection. No `external_call`, no libc shim. Build = compile.                                                                                                                                                            |
| Honest about colour   | `FmtSubscriber` paints level + target tokens itself, following `NO_COLOR` / `FORCE_COLOR` / `isatty(2)`. `Color` exposes the same decision (`Color.enabled()`) so caller-painted message bodies stay in sync.                                                                                                                     |

---

## Quick start

```bash
pixi install
pixi run test       # 22 tests
pixi run bench      # latency numbers
pixi run demo       # prints to stderr, set LOG= or NO_COLOR= to vary
```

A logger in five lines:

```mojo
import logging
from logging import Field

def main() raises:
    var log = logging.init()                                # FmtSubscriber + EnvFilter from LOG=
    log.info("server starting", Field.str("addr", "0.0.0.0:8080"))
    log.warn("slow", Field.float("rtt_ms", 4.3), Field.int("bytes", 18_944))

    var sub = log.with_target("http_client.h2")            # scoped child, same sink
    sub.debug("frame", Field.int("stream", 5), Field.str("type", "DATA"))
```

Filter at runtime via the environment:

```bash
LOG=debug                  pixi run demo   # DEBUG and above globally
LOG="info,h2=trace"        pixi run demo   # trace under any h2.* target, info elsewhere
LOG="off,http_client=info" pixi run demo   # silence everything except http_client.*
```

Caller-painted colour, gated on the same rules as the subscriber:

```mojo
import logging
from logging import Field, Color

def main() raises:
    var log = logging.init()
    var ansi = Color.enabled()      # NO_COLOR / FORCE_COLOR / isatty(2)

    log.warn(
        "slow " + Color.paint_if(ansi, Color.YELLOW, "(>300ms)"),
        Field.float("rtt_ms", 312.4),
    )
    log.error(
        Color.paint_if(ansi, Color.BOLD, "connection lost")
            + " — "
            + Color.paint_if(ansi, Color.RED, "10.0.0.5:443"),
        Field.bool("will_retry", True),
    )
```

---

## Public surface

| Family            | Exports                                                                                                                              |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| Core              | `init`, `Logger`, `Level`, `Field`, `Value`, `Event`, `LOG_COMPILE_MIN_LEVEL`                                                        |
| Subscribers       | `Subscriber` (trait), `FmtSubscriber`, `JsonSubscriber`, `TestSubscriber`, `CapturedEvent`, `NopSubscriber`, `Tee`                   |
| Filtering         | `EnvFilter`, `Filtered`                                                                                                              |
| Colour            | `Color` — constants (FG, bright FG, BG, bright BG, styles), `paint`, `paint_if`, `enabled`, `fg256`, `bg256`, `fg_rgb`, `bg_rgb`, named helpers (`red`, `green`, `bold`, etc.) |
| Field value tags  | `TAG_STR`, `TAG_INT`, `TAG_FLOAT`, `TAG_BOOL`, `TAG_BYTES`                                                                           |

---

## Performance

Numbers from `pixi run bench` on x86-64, `N = 200_000` iterations:

| Path                                                       | ns/call |
| ---------------------------------------------------------- | ------- |
| comptime-disabled trace (`LOG_COMPILE_MIN_LEVEL=DEBUG`)    | ~0      |
| runtime-disabled info (`min_level=WARN`)                   | ~0      |
| enabled INFO, no fields (`AlwaysOnNop` sink)               | ~44     |
| enabled INFO, 3 fields                                     | ~145    |
| `JsonSubscriber` + real `write(2)` (3 fields)              | ~1 400  |
| `Color.paint(code, text)`                                  | ~13     |
| `Color.paint_if(False, code, text)` (gated-off path)       | ~0      |

The enabled-path cost sits in the same neighbourhood as Rust `tracing`'s
field-attaching layer; the comptime-gated path produces no machine code
at all, so a release binary with `LOG_COMPILE_MIN_LEVEL = WARN` carries
zero overhead from trace/debug/info call sites. Caller-painted colour
adds ~13 ns per painted token when ANSI is on and ~0 when it's off, so
gating with `Color.paint_if(Color.enabled(), …)` is free under
`NO_COLOR` or a non-TTY stderr.

---

## Environment

| Variable        | Effect                                                                 |
| --------------- | ---------------------------------------------------------------------- |
| `LOG`           | `EnvFilter` grammar — `info`, `info,h2=trace`, `off,http_client=info`. |
| `NO_COLOR`      | Any non-empty value disables ANSI (overrides `FORCE_COLOR`).           |
| `FORCE_COLOR`   | Any non-empty value enables ANSI even when stderr isn't a TTY.         |
| `CLICOLOR_FORCE`| Synonym for `FORCE_COLOR`.                                             |

---

## Verification discipline

| Layer       | Check                                                                                                            |
| ----------- | ---------------------------------------------------------------------------------------------------------------- |
| Unit        | `tests/run_tests.mojo` — 22 tests, every test is a `def run() raises` that aborts on first mismatch.             |
| Comptime    | `test_comptime_gate_erases_trace` proves `trace` under `LOG_COMPILE_MIN_LEVEL=DEBUG` is dead code (no capture).  |
| Surface     | Color constants and helpers are asserted against literal ANSI SGR escape strings — drift fails the suite.       |
| Format      | `FmtSubscriber._format` and `JsonSubscriber._format` are exercised on synthetic events with mixed field tags.   |
| Probe       | `.probe/SYNTAX.md` carries the verified Mojo 1.0.0b3 idioms — port to a new nightly and re-verify, don't recall. |

Errors raise — `Level.parse` and `EnvFilter.parse` reject garbage rather
than silently defaulting. Drop-on-write failure inside `FmtSubscriber` is
the one swallowed path (logging a failure of the log sink would loop);
that decision is commented at the call site and is the standard convention.

---

## Documentation

For now the README + `.probe/SYNTAX.md` cover the surface. `ARCHITECTURE.md`
arrives when the layout has hardened past one more milestone. `ROADMAP.md`
arrives once spans / scoped context land.

---

## Deliberate boundaries

| Area                          | Decision                                                                                                                                                                                                                                                                                                                |
| ----------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Global dispatcher             | Not in v0. Mojo's no-mutable-global rule pushes pass-down by default, and a TLS dispatcher behind libc `pthread_setspecific` would add an FFI dependency we don't need for the foreseeable scope. A future opt-in helper can layer on top — the core stays explicit.                                                       |
| Spans / scoped context        | Deferred to v0.2. RAII semantics plus a per-logger context stack are the design — kept out of v0.1 so the surface stays tiny.                                                                                                                                                                                              |
| Async sinks / background flush | Out of scope. Every write is synchronous, kernel-level `write(2)`; on Linux up to `PIPE_BUF` (4 KiB) the line is atomic. Users who need batching wrap a `Subscriber` themselves.                                                                                                                                            |
| SBO formatter                 | Future optimization. The current formatter allocates one `String` per line; replacing it with an inline-array buffer would knock another ~50% off the formatter path — not a v0 goal.                                                                                                                                       |
| Platform                      | Linux-first. The subscriber writes to fd 2 with `FileDescriptor(2).write(s)` from stdlib; macOS / BSD work by inheritance but only Linux is verified.                                                                                                                                                                       |

---

## Licence

Apache License 2.0 — see [LICENSE](LICENSE).
