# PERF

Hot-path numbers for logging-mojo. Measured on x86-64 Linux with `pixi run bench`, N=200_000, median of three runs.

## Current

| Path                                  | ns/call | Notes                                                                       |
| ------------------------------------- | ------- | --------------------------------------------------------------------------- |
| comptime-disabled `trace`             | ~0      | DCE'd by `comptime if LOG_COMPILE_MIN_LEVEL`                                |
| runtime-disabled `info`               | ~0      | Below `min_level` — dropped before allocation                               |
| enabled `info`, no fields             | ~35     | Logger → AlwaysOnNop on_event, no formatting                                |
| enabled `info`, 3 fields              | ~112    | Same path + Field list construction                                         |
| `FmtSubscriber._format(3 fields)`     | ~204    | Single byte-buffer build, RFC 3339 ms precision, then `String(from_utf8=)`  |
| `JsonSubscriber._format(3 fields)`    | ~260    | Same pattern with 9-digit RFC 3339, JSON escape scan                        |
| `FmtSubscriber.fmt + write(2)` (JSON sink → stdout) | ~860–1250 | Real syscall path; varies with kernel scheduling          |

## What made it fast

The previous formatters built each event via a chain of `String += String += …`. Every `+=` resized a new heap allocation; a 3-field line cost ~20 of them.

The current path is **one buffer, one allocation, one syscall**:

1. **`List[UInt8]` with reserved capacity** — every fragment of the event is appended to a single buffer. Mojo's `List.extend(span)` lowers to memcpy for the bulk runs.
2. **One `String(from_utf8=buf^)`** at the end — single heap allocation, ownership transfer.
3. **RFC 3339 timestamp written directly into the buffer** — `logging/_fmt_fast.write_rfc3339_into` uses the same two-digit lookup (`_D100`) and one-pass `year_month_day` decode the chrono library uses; the subscriber no longer round-trips through a `String` then a separate `_trim_fractional_ms` pass.
4. **Fast itoa for int fields** — `write_int_signed` uses the two-digit table; `String(Int(...))` is gone from the hot path.
5. **Bulk-extend for non-escape JSON runs** — `_json_string_body` scans for the next byte that needs escaping and copies everything before it with `List.extend` (memcpy). The slow per-byte branch only fires at escape boundaries; a typical payload (`target`, `msg`, key names, ASCII values) has no escapes at all.

Net change vs. the original:

| Path                          | Before  | After  | Speedup  |
| ----------------------------- | ------- | ------ | -------- |
| `FmtSubscriber._format`       | 951 ns  | 204 ns | **4.7×** |
| `JsonSubscriber._format`      | 809 ns  | 260 ns | **3.1×** |
| enabled 3-fields (user path)  | 145 ns  | 112 ns | 1.3×     |

The remaining ~200 ns in fmt is roughly the timestamp (~50 ns), 3 field encodes (~80 ns), level + target + message (~25 ns), and the final `String(from_utf8=)` allocation (~30 ns).

## Reproducing

```bash
pixi run bench
```

The bench file (`benchmarks/bench.mojo`) is the source of truth. The "fmt(json,stdout)" line includes a real `write(2)` syscall per event; pipe stdout to `/dev/null` (`pixi run bench > /dev/null`) to take the terminal out of the loop.

## Where time still goes

- **`Instant.now()` (~35 ns)** — `clock_gettime(REALTIME)` floor. Can't be lowered without giving up wall-clock accuracy.
- **`String(Float64)`** — Mojo stdlib's general-purpose float-to-string. A custom Grisu/Ryu would help float-heavy logs; not chased here.
- **Per-event `List[UInt8]` allocation** — A subscriber-owned reusable buffer (cleared each event, written via `FileDescriptor.write_bytes` without materializing a String) is the next obvious win when a single sink shoulders heavy traffic.
