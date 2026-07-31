# samples/tour — the cajeta-logging tour

Self-checking demos over the library's whole public surface (17/17 types,
enforced by the coverage gate). Demos PRINT real log lines — a mixed stdout
stream of JSONL/text/logfmt is exactly what log consumers see — and ASSERT
through `CapturingAppender`, the library's own test shape. The exit code is
the number of failed checks.

| Demo | What it teaches |
|------|-----------------|
| `FacadeDemo` | `Log.console`, all five level methods, fielded records (`event` + `str`/`i64`/`flag`/`f64` + `emit(#r)`), `enabled()` build-guards |
| `LevelsDemo` | The six-value vocabulary TRACE→OFF, `Levels.severity`/`name`, OFF as the disable sentinel |
| `EncodersDemo` | One realistic record as JSONL, text, and logfmt |
| `AppendersDemo` | `FileAppender` lifecycle (WRITE vs APPEND, per-line flush, `close()`), console+file `CompositeAppender` fan-out, sink-ownership rules |
| `ExtensionDemo` | Custom `LogEncoder` + custom `Appender` over `LogField.kind` — a TSV encoder and a crash-dump ring buffer |
| DI half (`run.sh` only) | `@Logged` synthesized loggers + `LoggerFactory.loggerFor` per-module thresholds, profile-wired sinks |

## Two ways to run

**Manifest (all explicit demos)** — the tour as a real consumer of the
published library, resolved from Olla like any application dependency:

```sh
cajeta run
```

**run.sh (everything, including the DI half)** — library + tour + `src-di`
sources compiled together into one binary:

```sh
./run.sh                       # cajeta on PATH, --profile=dev
CAJETA=/path/to/cajeta ./run.sh
PROFILE=prod ./run.sh          # service lines -> app.jsonl (verified + shown)
PROFILE=test ./run.sh          # service lines -> masking CapturingAppender
```

`run.sh` announces the active profile and where the DI section's lines go,
and under `prod` verifies the JSONL landed — output never silently vanishes.

## Why the DI half is script-only

Compile-time DI resolves in the final compile — the same rule that shapes
`run-tests.sh`. The `@Profile`-selected providers behind `Log.defaultFor`
(what `@Logged`'s synthesized logger uses) wire correctly only when the
library SOURCES are part of the consumer's compile; a precompiled `.cja`
carries wiring frozen at its own build profile. A manifest can't express a
from-source dependency today, so the `@Logged`/`LoggerFactory` demo lives in
`src-di/`, which only `run.sh` merges in. The explicit demos construct their
encoders and appenders directly and behave identically on both paths.

Known rendering nit: `f64` fields are not shortest-round-trip today
(`0.987` prints as `0.986999` — cajeta INDEX: `float64-tostring-roundtrip`);
the tour demos the field but gates no check on its digits.

CI runs suite + tour (all three profiles) + the coverage gate via
`scripts/ci-checks.sh`.
