# cajeta-logging — Implementation Plan

_Execution plan for the spec in `docs/logging-spec.md` (v0.2). Library project (`.cja`),
scaffolded from the `library` archetype._

## Strategy: basics first, ambient second

The framework splits cleanly into two tiers by dependency:

- **Tier 1 — the basics (no `FiberLocal` needed).** Facade, levels, the three encoders
  (JSONL / text / logfmt), console + file appenders, DI wiring, explicit-handle context and
  system log. Builds and ships **today** against shipped stdlib only.
- **Tier 2 — ambient context (needs `cajeta.concurrent.FiberLocal`).** `LogContext.where`,
  `SystemLog.current()`, `Metrics.current()` — the no-handle ergonomics. Lands when
  `FiberLocal` does (`plans/FiberLocal-plan.md`), and is **purely additive**: every Tier-1
  API keeps working.

Do Tier 1 end to end first. Wire Tier 2 in once FiberLocal is built — no Tier-1 rework.

## Phasing

### Phase 0 — skeleton (done)
- [x] `cajeta init library` scaffold; builds to `org.cajeta.logging-*.cja`.
- [x] Spec (`docs/logging-spec.md`, now v0.2 with formats + FiberLocal integration).

### Phase 1 — core structured logger  *(Tier 1, the basics)*
- [x] `Level` enum + `Levels` severity/threshold helpers; below-threshold convenience
      calls build nothing (zero-alloc no-op builder is a later perf pass).
- [x] `LogRecord { ts, level, logger, msg, fields }` (fluent `str`/`i64`/`flag`/`f64`).
- [x] `Logger` facade: level methods + fluent `event`/`emit`; `of(Class)` / `.with(...)`
      child loggers deferred to Phase 3 (DI).
- [x] `Clock`-sourced timestamps (epoch millis today; ISO-8601 rendering deferred).
- [x] Unit tests via cajeta-unit + `CapturingAppender` — `src/test/cajeta`, driven by
      `org.cajeta.unit.Runner` reflective `@Test` discovery. Run with `./run-tests.sh`.
      The test exe compiles only the test sources and links the logging lib **and**
      cajeta-unit in as `.cja` classpath deps — enabled by the cajeta-two
      classpath-bitcode-linking fix (a plain `.cja` previously contributed declarations
      only, not linked code). A native `cajeta test` task awaits build-tool wiring
      (per-action source-root + dev-dependency-on-test-classpath resolution).

### Phase 2 — output formats  *(Tier 1)*
- [x] `LogEncoder` interface (`int8[] encode(LogRecord)`). Named `LogEncoder`, not
      `Encoder`, to avoid shadowing the stdlib `cajeta.wire.Encoder` (a compiler
      name-resolution bug binds an unqualified `Encoder` to the wrong one — see below).
- [x] `JsonlEncoder` (default) over `cajeta.codec.json.JsonWriter` → one compact line;
      reserved keys first.
- [x] `TextEncoder` — default layout `<ts> <LEVEL> <logger> <msg>  <k=v…>`, level padding,
      `k=v` field tail. TTY ANSI color + configurable pattern are Phase-3 sink concerns.
- [x] `LogfmtEncoder` — `k=v` pairs, lower-cased level, value quoting/escaping (`LogFmt`).
- [x] Encoder tests (`EncoderTest`, 5 cases): layout, level padding, field quoting (spaces),
      logfmt reserved-key/lowercase shape, quote-escaping. Run with `./run-tests.sh` (11/0).

_Dogfood note: building Phase 2 surfaced two pre-existing cajeta-two compiler bugs (both
fixed/worked-around): (1) an enum-constant constructor arg resolving to `int32` broke
overload resolution when the ctor also had an interface param (compiler fix landed);
(2) an unqualified `Encoder` bound to the stdlib `cajeta.wire.Encoder` instead of the
local one, giving some implementers a wrong interface vtable → SIGSEGV — sidestepped by
the `LogEncoder` rename; compiler name-resolution fix tracked separately._

### Phase 3 — appenders & config  *(Tier 1)*
- [~] `Appender` interface ✅; `ConsoleAppender` ✅ (TTY color deferred); `FileAppender` ✅
      (`cajeta.io.file`, `OpenMode.APPEND`/`WRITE`, flush-per-line); `CompositeAppender` ✅
      (fan-out to N sinks, copies the owned line per child). `AppenderTest` 3 cases.
      `RollingFileAppender` (size/time rolling) **BLOCKED** — `cajeta.io.file.File` has no
      `rename`/`delete`/`exists` static op yet (needed to roll current→`.N`).
- [ ] `AsyncAppender` over a worker fiber + `Channel<LogRecord>`; back-pressure policy
      (block / drop-oldest / drop-newest).
- [ ] `LoggerFactory` as `@Component` (singleton); appenders/encoder as components;
      `@Profile` prod(JSONL→file)/dev(text+color→console); `@TestComponent` capturing appender.
- [ ] **Milestone: the basics are usable** — a service can log structured JSONL to a file
      and colored text to the console, all DI-wired and test-overridable.

### Phase 4 — system log, explicit-handle form  *(Tier 1)*
- [ ] `SystemLogEntry`: typed KV document, `put/putDuration/...`, internal `Mutex` for
      cross-fiber `put`.
- [ ] `SystemLog` `@Component`: `begin(route) -> #SystemLogEntry`; auto fields
      (route/ts/latency/status/error); `flush()` → one `"kind":"system"` line; drop-on-scope
      auto-flush with `"flushed":"drop"`.
- [ ] Exception-model integration: a request that throws records `error` + throwable summary.

### Phase 5 — metrics bridge, explicit form  *(Tier 1)*
- [ ] `MetricsProvider` + `MetricsSink` interfaces; `Tags` type.
- [ ] Direction A: metric methods on `SystemLogEntry` → (a) record KV + (b) fan out to all
      installed `MetricsProvider` components; in-request aggregation.
- [ ] Direction B: `sys.metrics()` → a `MetricsProvider` bound to the entry.
- [ ] Reference adapters: no-op/console provider now; statsd/Prom/OTel as follow-on libs.

### Phase 6 — ambient context  *(Tier 2 — needs FiberLocal)*
- [ ] `LogContext` + `LogContext.where(ctx, body)` over `FiberLocal<LogContext>`; `Logger`
      merges the ambient context into every record on `emit()`.
- [ ] `SystemLog.forRequest(route, body)` + `SystemLog.current()` over
      `FiberLocal<SystemLogEntry>`; one flush on body exit (normal or throw).
- [ ] `Metrics.current()` ambient provider (Direction B with no hand-off).
- [ ] Fan-out + handoff tests: structured `scope` children inherit the entry; a worker-pool
      handoff carries it via `FiberContext`. (Mirrors FiberLocal plan Phase 6 checkpoint.)

### Phase 7 — hardening & enhancements
- [ ] Perf pass (buffer reuse, alloc audit, level-gate microbench).
- [ ] Selected §14 enhancements as demand warrants: exception fields (#1), redaction (#2),
      trace-id correlation (#3) — each its own sub-task.
- [ ] Docs: README usage, cookbook (request handler with ambient system log + metrics).
- [ ] Publish `.cja`; version 0.1.0 (Tier 1) → 0.2.0 (Tier 2).

## Key risks / dependencies
- **Tier 2 gates on `FiberLocal`** (`plans/FiberLocal-plan.md`). Tier 1 has no such gate —
  start now. Keep the ambient APIs *additive* so no Tier-1 code is reworked.
- **`JsonValue` vs lightweight field value** — decide early (perf vs reuse); affects all
  three encoders.
- **Cross-fiber `SystemLogEntry` semantics** — with FiberLocal inheritance the entry is
  *shared + synchronized* (spec §11); pin before Phase 6.
- All Tier-1 dependencies are SHIPPED stdlib (json, time, io, async, DI) — no compiler change.

## Acceptance
1. `log.info(...).str(...).emit()` produces a correct line in **each** of JSONL / text /
   logfmt; below-threshold is alloc-free.
2. One `SystemLogEntry` per request → exactly one `"kind":"system"` line, never lost
   (explicit-handle form, Tier 1).
3. A metric call enriches the system-log entry **and** reaches an installed provider
   (Direction A); `sys.metrics()` does the same for provider-typed callers (Direction B).
4. Prod/dev/test wiring swaps entirely via `@Profile`/`@TestComponent`, no app-code change.
5. **Tier 2:** with FiberLocal present, deep code logs request-scoped fields and contributes
   to the system log via `current()` with **no handle threaded**, across fan-out and handoff.
