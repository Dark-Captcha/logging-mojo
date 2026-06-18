# Changelog

All notable changes to `logging-mojo` are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] — 2026-06-18

The first tagged release. Establishes the public surface and the pure-Mojo,
zero-FFI, monomorphized-sink shape the rest of the library will grow against.

### Added

- **Core**
  - `Level` — `TRACE`, `DEBUG`, `INFO`, `WARN`, `ERROR`, `OFF`; `Comparable`
    + `TrivialRegisterPassable`; comptime constants on the struct; case-
    insensitive `Level.parse` with explicit raise on garbage.
  - `Field` + `Value` — tagged sum (`TAG_STR`, `TAG_INT`, `TAG_FLOAT`,
    `TAG_BOOL`, `TAG_BYTES`) with typed constructors (`Field.str`,
    `Field.int`, `Field.float`, `Field.bool`, `Field.bytes`).
  - `Event` — `(level, target, message, fields, timestamp)` carried by
    value into every subscriber; timestamp is a `chrono.Instant`.
  - `Logger[S: Subscriber]` — generic on the sink type, monomorphized per
    instantiation, no vtable. `with_target` forks a scoped child.
  - `LOG_COMPILE_MIN_LEVEL` — module-level `comptime Level` floor; calls
    below it are dead code (DCE-verified in the test suite).
  - `init()` — one-call constructor returning `Logger[Filtered[FmtSubscriber]]`
    wired to `FmtSubscriber.default()` and `EnvFilter` parsed from `LOG=`.
- **Subscribers**
  - `Subscriber` trait — `on_event(mut, mut Event)` + `enabled(Level, StaticString)`.
  - `FmtSubscriber` — pretty stderr sink, ANSI-aware (honours `NO_COLOR`,
    `FORCE_COLOR`, `CLICOLOR_FORCE`, `isatty(2)`), level + target column
    coloured, fields rendered as `k=v` with shell-safe quoting.
  - `JsonSubscriber` — NDJSON, any fd, structured field encoding, ms-resolution
    timestamps.
  - `TestSubscriber` + `CapturedEvent` — in-memory capture for unit tests.
  - `NopSubscriber` — `enabled` returns `False`; intended for benches and
    quiet builds.
  - `Tee[A, B]` — fan-out to two subscribers, both monomorphized.
- **Filtering**
  - `EnvFilter` — `LOG=` grammar (default level + `target=level` overrides),
    longest-prefix wins on target match.
  - `Filtered[S]` — wraps any subscriber with an `EnvFilter`.
- **Colour**
  - `Color` — ANSI SGR helper for caller-painted message bodies and field
    values. Constants exposed as struct-level `comptime StaticString`:
    `RESET`, `BOLD`, `DIM`, `ITALIC`, `UNDERLINE`, `BLINK`, `REVERSE`,
    `HIDDEN`, `STRIKE`; 8 standard + 8 bright foreground; 8 standard + 8
    bright background.
  - `Color.paint(code, text)` — canonical wrap-with-reset.
  - `Color.paint_if(ansi, code, text)` — gated variant; returns bare text
    when `ansi` is `False`.
  - `Color.enabled()` — mirror of `FmtSubscriber.default()`'s decision so
    caller-painted content tracks the subscriber.
  - `Color.fg256(n)` / `bg256(n)` — xterm 256-color escapes.
  - `Color.fg_rgb(r, g, b)` / `bg_rgb(r, g, b)` — 24-bit truecolor.
  - Named helpers: `red`, `green`, `yellow`, `blue`, `magenta`, `cyan`,
    `black`, `white`, `bold`, `dim`, `italic`, `underline`, `reverse`,
    `strike` — all route through `paint`.
- **Examples**
  - `examples/demo.mojo` — small tour, picks up `LOG=`, `NO_COLOR`,
    `FORCE_COLOR`. Exercises the `Color` helper for caller-painted message
    bodies.
- **Benches**
  - `benchmarks/bench.mojo` — comptime-disabled, runtime-disabled,
    `AlwaysOnNop` enabled (no-fields + 3-fields), and `JsonSubscriber` +
    real `write(2)` paths. Plus `bench_color_paint` and `bench_color_paint_if`
    for the SGR helper.
- **Tests**
  - 22 tests in `tests/run_tests.mojo` covering level ordering and parse,
    field constructors and tag decoding, `EnvFilter` defaults / overrides /
    `off`-with-override, logger min-level drop, `Tee` fan-out, `Filtered`
    per-target drop, comptime gate erasure proof, `Nop` enabled-state,
    `FmtSubscriber` and `JsonSubscriber` line shape, and the full `Color`
    surface (constants, composition, `paint_if` gating, 256-color and
    truecolor escapes, `enabled()` honouring `NO_COLOR`).

### Verified

- All 22 tests pass on `mojo-compiler 1.0.0b3.dev2026061706`.
- `examples/demo.mojo` runs correctly under default, `LOG=debug`,
  `LOG=trace`, `NO_COLOR=1`, and `FORCE_COLOR=1`.
- `LOG_COMPILE_MIN_LEVEL = DEBUG` proven to erase `trace` call sites —
  see `test_comptime_gate_erases_trace`.

### Known limits

- No spans / scoped context — deferred to v0.2.
- No global dispatcher — pass-down only (Mojo 1.0.0b3 has no module-level
  mutable globals).
- Linux-first; macOS / BSD untested.
- Pinned to a Mojo nightly via `pixi.toml`; expect churn until Mojo 1.0
  ships.

[0.1.0]: https://github.com/luanon404/logging-mojo/releases/tag/v0.1.0
