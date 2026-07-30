# samples/tour — the cajeta-logging tour

One executable that walks the library's public surface, section by section,
printing to stdout:

1. `Log.console` — compact JSONL, the tier-1 facade
2. Fielded records — `event` + `str`/`i64`/`f64`/`flag` + `emit`
3. `enabled()` guarding a fielded build
4. The same record through `JsonlEncoder`, `TextEncoder`, and `LogfmtEncoder`
5. Threshold gating (a WARN-gated logger drops info)
6. `CapturingAppender`, lent to the logger and read back — the test shape
7. `CompositeAppender` fan-out (one emit, two sinks)
8. `@Logged` + DI — the synthesized, profile-wired logger

## Two ways to run

**Manifest (sections 1–7)** — the tour as a real consumer of the published
library, resolved from Olla like any application dependency:

```sh
cajeta run
```

**run.sh (all 8 sections)** — library + tour + `src-di` sources compiled
together into one binary:

```sh
./run.sh                       # cajeta on PATH, --profile=dev
CAJETA=/path/to/cajeta ./run.sh
PROFILE=test ./run.sh          # a different DI profile for section 8
```

## Why section 8 is script-only

Compile-time DI resolves in the final compile — the same rule that shapes
`run-tests.sh`. The `@Profile`-selected providers behind `Log.defaultFor`
(what `@Logged`'s synthesized logger uses) wire correctly only when the
library SOURCES are part of the consumer's compile; a precompiled `.cja`
carries wiring frozen at its own build profile. A manifest can't express a
from-source dependency today, so the `@Logged` demo lives in `src-di/`, which
only `run.sh` merges in. Sections 1–7 construct their encoders and appenders
explicitly and behave identically on both paths.

The plain `===` banner lines between the records are deliberate: a real
console stream interleaves structured records with plain text, and the tour's
output doubles as a fixture for consumers that render JSONL (the Cajeta IDE
plugin's console JSON view among them).
