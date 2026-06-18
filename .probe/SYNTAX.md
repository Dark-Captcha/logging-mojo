# Mojo 1.0.0b3 cheat sheet for `logging-mojo`

Findings from `/tmp/logmojo_probe/`. Every line below is *probed*, not remembered.

## Language shape

| Form | Status | Use |
|---|---|---|
| `fn` keyword | REMOVED | use `def` |
| `alias` keyword | deprecated | use `comptime` |
| `@parameter if` | deprecated | use `comptime if` |
| `@register_passable("trivial")` | REMOVED | conform to `TrivialRegisterPassable` trait |
| `Stringable` trait | gone (no longer declarable) | expose `name() -> StaticString` or `write_to[W: Writer](self, mut w: W)` |
| `EqualityComparable` | not in scope | `Comparable` already implies it |
| `owned` keyword in params | replaced | use `var` in parameter list (`def f(var x: T)`) |
| Module-level mutable `var` | ERROR: "global variables are not supported" | no globals — pass state down |
| Module-level `comptime` const | OK | use for compile-time constants |
| Variadic struct args `*xs: T` | OK | `for x in xs:` + `len(xs)` work |
| Generic struct field referencing param | `Self.S`, not bare `S` | `var sub: Self.S` |
| Trait method body | `...` (ellipsis) | declaration only |
| Trait base list | needs `ImplicitlyDeletable` for owned types | `trait T(Copyable, Movable, ImplicitlyDeletable)` |
| `comptime if` inside `@always_inline` | DCE works | filtered branch produces no output, verified |
| `Optional[UnsafePointer[T, O]]` | the way to model nullable ptr | `UnsafePointer` is non-null by design |
| `UnsafePointer` mutable origin | `MutAnyOrigin` (NOT `MutableAnyOrigin`) | `UnsafePointer[UInt8, MutAnyOrigin]` |
| String byte slice | `s[byte=a:b]` | direct `s[a:b]` is rejected |

## Stdlib I/O (no FFI needed)

| Need | Import / call |
|---|---|
| Write to fd 2 (stderr) | `from std.io import FileDescriptor; FileDescriptor(2).write(s)` |
| Env var | `from std.os import getenv; getenv("LOG")` → `String` (empty if unset) |
| isatty | `from std.os import isatty; isatty(2) -> Bool` |

These obsolete the libc FFI shim I started writing. Don't reintroduce `external_call["write", ...]` — it conflicts with stdlib's own declaration.

## Chrono integration

```mojo
from chrono import Instant, Now, Rfc3339, Offset
var dt = Now.utc_datetime()                       # raises
var ts = Rfc3339.format(dt, Offset.UTC)           # raises; e.g. "2026-06-18T03:02:11.746588216Z"
```

`Instant.now()` raises; `Instant.milliseconds_since_epoch()` is cheap (no alloc).
`Offset.UTC` is a `comptime` const on the struct.

## Negative findings (don't try)

- `@register_passable("trivial")` decorator — gone.
- `Stringable` trait — gone.
- `EqualityComparable` trait — gone.
- `alias FOO = …` at module scope — warns, will be removed.
- `@parameter if` — warns, use `comptime if`.
- `from logger import …` (bare module) — there is no top-level `logger`.
- `external_call["write", …]` — conflicts with stdlib's own decl, fails at LLVM lowering.
- `String(some_struct)` for a struct that doesn't implement the TString protocol — fails with a long candidate list.
- `s[:n]` byte-slicing — rejected; use `s[byte=:n]`.

## Trait + generic struct (Subscriber pattern)

```mojo
trait Sink(Copyable, Movable, ImplicitlyDeletable):
    def emit(mut self, msg: String):
        ...

struct StdoutSink(Sink):
    def __init__(out self): pass
    def emit(mut self, msg: String):
        print("[stdout]", msg)

struct Wrap[S: Sink](Copyable, Movable):
    var sink: Self.S                              # NOTE: Self.S, not S
    def __init__(out self, var s: Self.S):        # NOTE: var, not owned
        self.sink = s^
```

Monomorphization: `Wrap[StdoutSink]` is a distinct type — direct call, no vtable.

## Comptime level gate (verified DCE)

```mojo
@always_inline
def gated[max: LevelTag, lvl: LevelTag](msg: String):
    comptime if lvl.v >= max.v:
        print("[gated]", msg)

gated[INFO, TRACE]("trace?")   # → no output, body erased
gated[INFO, WARN]("warn kept") # → prints
```

This is the zero-cost-when-disabled guarantee for `logging-mojo`.
