# cajeta-logging — Specification

_A structured logging library for Cajeta. Default output is **JSONL** (one JSON object
per line); **plain text** and **logfmt** are first-class alternatives. Adds a first-class
**system log** (one wide event per request) and a **metrics bridge** that fuses metric
publication into that event._

Status: design spec (v0.2). The project builds to a `.cja`; this document defines the API to
implement. Plan: `plan/logging-plan.md`.

> **Foundation update (v0.2):** this spec previously assumed Cajeta has *no*
> fiber/thread-local storage and made ambient request context a non-goal. That
> constraint is being lifted: `cajeta.concurrent.FiberLocal<T>` is now specified and
> scheduled (`docs/stdlib/FiberLocal.md` + `plans/FiberLocal-plan.md` in the compiler
> repo). `FiberLocal` is the sound, fiber-keyed, single-use, scope-restored replacement for
> a `ThreadLocal`/MDC. The logging framework is the headline consumer: the **system log**
> entry lives in a `FiberLocal<SystemLogEntry>`, so it follows a request across structured
> fan-out and worker handoff without being threaded through every signature. Sections that
> said "pass the handle, there is no ambient context" are updated below; the **explicit
> handle remains supported** (and is the fallback when `FiberLocal` is not yet built), but
> ambient context via `FiberLocal` is now the primary ergonomic path.

---

## 1. Goals & non-goals

**Goals**
- A small, fast, **structured-first** logging facade — fields are first-class, not
  string-interpolated.
- **JSONL by default** — machine-parseable, one event per line, append-friendly.
- A **system log**: exactly one log entry per request, a key-value document (a "wide
  event" / "canonical log line").
- A **metrics bridge** so metrics published by code also land in the request's system-log
  entry — and vice versa — without double instrumentation.
- Wire cleanly through Cajeta's `@Component` DI; testable with cajeta-unit.

**Goals (cont.)**
- **Multiple output formats**, switchable per appender: **JSONL** (default, machine), **plain
  text** (human console, the common case), and **logfmt** (`k=v` pairs). One `Encoder`
  interface, three shipped implementations.
- **Ambient request context via `FiberLocal`** — an MDC-equivalent that follows the request
  across fan-out and handoff, without the `ThreadLocal` pool-leak footgun (the binding is
  fiber-keyed and single-use). Explicit-handle context stays supported as the fallback.

**Non-goals (v1)**
- A full tracing/span system (OpenTelemetry traces) — we interoperate (trace/span id
  *fields*), we don't reimplement the SDK.
- Log *querying*/storage — we emit; downstream (Loki/ELK/BigQuery) ingests.
- A bespoke ambient-context mechanism — we **reuse** `cajeta.concurrent.FiberLocal` (§7)
  rather than inventing a logging-specific MDC. Until `FiberLocal` ships, the explicit
  handle (a `LogContext` you pass) is the interim path and never stops working.

## 2. Prior art & positioning

We are explicitly modeling on logging frameworks (not JUnit). The landscape and what we
take from each:

| Framework | Model | What we adopt | What we reject |
|---|---|---|---|
| **SLF4J + Logback** (Java) | facade + pluggable backend; per-class loggers | the **facade/backend split**, `Logger.of(Class)`, level hierarchy | string-template `{}` as the *primary* API |
| **Log4j2** (Java) | appenders + layouts, async ring buffer | **appender/encoder separation**, async appender | XML config as the norm |
| **java.util.logging** | built-in, handler/formatter | nothing much (cautionary: weak structured support) | global singletons |
| **Serilog** (.NET) | **structured-first**, message templates capture properties | structured events as the default unit | — |
| **Zerolog / zap** (Go) | **JSON-first, zero-alloc**, fluent field builders | **JSONL default**, fluent `.str().int().log()`, level-gated zero-work | — |
| **Go `slog`** | `Handler` interface, `Attr` key-values, `With` context | the **Handler abstraction**, `with(fields)` child loggers | — |
| **Rust `tracing`** | spans + events, subscriber layers | the **subscriber/layer** idea for fan-out, structured fields | span-centric mental model for v1 |
| **Stripe canonical log lines / Honeycomb wide events** | **one wide event per request** | the **system log** (§9) — this is the headline feature | sampling-by-default |

**Position:** a Zerolog/slog-style **JSON-first structured logger** with a Serilog-grade
event model, an SLF4J-style facade/backend split, and a canonical-log-line **system log**
on top. JSONL is the default encoding everywhere.

## 3. Architecture

```
                      org.cajeta.logging
  ┌────────────────────────────────────────────────────────────┐
  │ Facade            Logger  (per-class; level methods + fields) │
  │ Event             LogRecord { ts, level, logger, msg, fields }│
  │ Backend           LoggerFactory → Logger; holds config        │
  │ Sink              Appender (console, file, rolling, async)     │
  │ Format            Encoder (JsonlEncoder [default], TextEncoder)│
  │ Filter            Level threshold per-logger + global          │
  │ Context           LogContext (explicit field bag, see §7)      │
  │ System log        SystemLog + SystemLogEntry (§9)              │
  │ Metrics           MetricsSink / MetricsProvider bridge (§10)   │
  └────────────────────────────────────────────────────────────┘
```

Everything is a `@Component` so it wires through DI and is overridable in tests via
`@TestComponent` / `@Profile("test")`.

## 4. Logger facade & levels

Levels: `TRACE < DEBUG < INFO < WARN < ERROR` (plus `OFF` for thresholds).

```cajeta
Logger log = Logger.of(OrderService.class);   // or LoggerFactory.get("order")

// structured-first: message + typed fields, fluent and level-gated
log.info("order placed")
   .str("order_id", id)
   .int64("amount_cents", cents)
   .str("currency", "USD")
   .emit();                       // nothing is built if INFO is below threshold

// child logger with bound fields (slog `With`)
Logger reqLog = log.with("request_id", rid);
```

- **Level gating is zero-work**: `log.info(...)` returns a no-op builder when INFO is
  below the logger's threshold — no allocation, no field evaluation.
- `Logger.of(Class<T>)` uses reflection (`Class<T>` is shipped) to derive the logger name.
- Lazy values: `.lazy("k", () -> expensive())` evaluated only if the record is emitted.

## 5. The structured record & JSONL

A `LogRecord` is `{ timestamp, level, logger, message, fields{} }`. The default
`JsonlEncoder` serializes it to **one compact JSON line** via the shipped
`cajeta.codec.json.JsonWriter` (verified to emit whitespace-free single-line objects):

```json
{"ts":"2026-06-14T17:09:00.123Z","level":"INFO","logger":"order","msg":"order placed","order_id":"o_42","amount_cents":1999,"currency":"USD"}
```

Reserved keys: `ts`, `level`, `logger`, `msg`. User fields must not collide (collision
policy: user field is suffixed `_1` and a `__warn` field notes it). Timestamps come from
`cajeta.time.Clock` (`millisTime`/`Instant`, shipped); format ISO-8601 UTC by default,
epoch-millis optional.

### 5.1 Output formats — one `Encoder`, three shipped backends

The `LogRecord` is format-agnostic; the **`Encoder`** turns it into bytes. The same record
encodes to any of the three. An appender owns one encoder; you pick per appender (e.g.
JSONL to a file, text to the console).

```cajeta
public interface Encoder {
    int8[] encode(LogRecord r);    // one line, newline-terminated
}
```

**1. `JsonlEncoder` (default)** — one compact JSON object per line (shown above).
Machine-first; the right default for services shipping to Loki/ELK/BigQuery.

**2. `TextEncoder` (human console)** — the common, readable line format. A configurable
layout pattern over the same fields:

```
2026-06-14T17:09:00.123Z INFO  order  order placed  order_id=o_42 amount_cents=1999 currency=USD
```

- Default layout: `<ts> <LEVEL> <logger> <msg>  <k=v …>`. Trailing structured fields are
  appended as `k=v` so nothing is lost relative to JSONL.
- Level is fixed-width/padded for column alignment; **ANSI color** by level when the sink is
  a TTY (auto-detected; `--no-color`/env override), plain otherwise.
- Layout is a pattern string (Logback/log4j-style tokens: `%d %level %logger %msg %fields`)
  so projects can shape it without code.

**3. `LogfmtEncoder`** — flat `key=value` pairs (Heroku/Go `logfmt`), the middle ground:
greppable like text, parseable like JSON.

```
ts=2026-06-14T17:09:00.123Z level=info logger=order msg="order placed" order_id=o_42 amount_cents=1999 currency=USD
```

All three escape correctly (JSON string rules / quoted values with spaces in text & logfmt).
A project selects the encoder per `@Profile` (§8): text+color on `dev`, JSONL on `prod`.

## 6. Appenders (sinks)

`Appender` is the sink interface (`void append(LogRecord)` + `flush()`/`close()`):

- **ConsoleAppender** → `System.stdout`/`System.stderr` (shipped IO).
- **FileAppender** / **RollingFileAppender** → `cajeta.io.file` (size/time rolling).
- **AsyncAppender** → hands records to a worker fiber via a `Channel<LogRecord>`
  (cajeta async is shipped); the worker owns the downstream appender. Back-pressure
  policy: block / drop-oldest / drop-newest (configurable).

An `Appender` owns an `Encoder`; default `JsonlEncoder`. Multiple appenders fan out (a
slog-style multi-handler).

## 7. Context — ambient via `FiberLocal`, explicit as fallback

Context is a bag of fields (request id, principal, trace id) that should appear on every
record emitted while handling a request. Two ways to carry it, both supported:

**Ambient (primary, once `FiberLocal` ships).** A `static FiberLocal<LogContext>` holds the
current request's context. `Logger` reads it on `emit()` and merges its fields into every
record — no `with(...)` plumbing through the call tree. Because it is *fiber*-keyed and
single-use (see `FiberLocal.md`), there is no `ThreadLocal`-style cross-request leak.

```cajeta
LogContext.where(LogContext.of("request_id", rid, "principal", who), () -> {
    handle(req);     // every log.*().emit() inside auto-includes request_id + principal
});
```

- **Fan-out:** child fibers spawned in a `scope` inherit the context (FiberLocal Layer 2) —
  parallel sub-tasks log with the same request id for free.
- **Handoff:** crossing to a worker fiber carries a `FiberContext` snapshot (Layer 3); the
  worker reinstalls it so its log lines stay correctly attributed.

**Explicit (always supported, and the interim path before `FiberLocal` lands).** A
`LogContext` you attach to a child logger (`log.with("request_id", rid)`) or pass on your
request object. This composes with §9: the per-request `SystemLog` entry *is* the request
context, whether bound ambiently or threaded by hand.

## 8. Configuration & DI

- **Programmatic** builder: `LoggingConfig.builder().level(INFO).appender(...).build()`.
- **Component-wired**: `LoggerFactory` is a `@Component` (singleton). Appenders and the
  active `Encoder` are components; a project overrides them per `@Profile`
  (e.g. `@Profile("prod")` JSONL→file, `@Profile("dev")` text→console). Tests override via
  `@TestComponent` (an in-memory capturing appender — see §13).
- Per-logger thresholds via a name-prefix table (`order.* = DEBUG`).

## 9. System log — one wide event per request

The **system log** emits **exactly one structured entry per request** — a canonical log
line / wide event. Instead of scattering many log lines, the request handler accumulates
key-values into one `SystemLogEntry` and flushes it once at the end.

The entry is stored in a `FiberLocal<SystemLogEntry>`, so any code on the request's path
contributes to it via `SystemLog.current()` without being handed the entry — and it follows
the request across fan-out (inherited) and handoff (carried). The explicit-handle form
(`begin()` returning a `#SystemLogEntry` you thread yourself) remains available and is the
interim path until `FiberLocal` is built.

```cajeta
@Component class SystemLog {
    // ambient form: bind a request-scoped entry for the extent of `body`,
    // flushing once on exit (normal OR throw). Backed by FiberLocal<SystemLogEntry>.
    public <R> R forRequest(String route, () -> R body);

    // the entry bound to the current fiber — usable anywhere on the request path
    public static SystemLogEntry current();

    // explicit-handle form (interim / when you want to thread it by hand)
    public #SystemLogEntry begin(String route);
}

// ambient: handler body wrapped once; deep code just calls SystemLog.current()
systemLog.forRequest("POST /orders", () -> {
    SystemLog.current().put("user_id", userId);     // from any layer, no handle passed
    placeOrder(req);                                 // it, too, enriches current()
    SystemLog.current().put("db_queries", 4).put("cache_hit", true);
});   // ONE jsonl line emitted here, even if the body threw

// explicit (interim): thread the handle as before
#SystemLogEntry sys = systemLog.begin("POST /orders");
sys.put("user_id", userId).put("order_id", orderId);
sys.flush();   // emits ONE line; also runs on scope-drop if not flushed
```

- `SystemLogEntry` is a typed key-value document; `flush()` serializes it as **one JSONL
  line** (the same `JsonWriter` path), tagged `"kind":"system"`.
- It is an **owned handle threaded through the request** (created at entry, flushed at
  exit). Drop-on-scope guarantees it is never silently lost (auto-flush with a
  `"flushed":"drop"` marker if the handler forgot).
- Standard fields auto-populated: `route`, `ts`, `latency_ms`, `status`, `error` (if the
  request threw — integrates with the exception model).
- Rationale and prior art: Stripe "canonical log lines", Honeycomb "wide events",
  observability-2.0 "one wide event per request" — far cheaper to query than reconstructing
  a request from many narrow lines.

## 10. Metrics bridge — the headline feature

**Requirement:** metrics published to a metrics provider (statsd/Prometheus/OTel) should
*also* land in the request's system-log entry, so the wide event carries the request's
metrics without separate instrumentation. Two directions were considered; we ship **both**
behind one small interface, with Direction A as the primary path.

### Interfaces

```cajeta
// A provider is an installed sink for metrics (statsd, prometheus, otel, ...).
public interface MetricsProvider {
    void counter(String name, int64 delta, Tags tags);
    void gauge(String name, float64 value, Tags tags);
    void timing(String name, int64 millis, Tags tags);
}

// The bridge that fuses metrics into the system log.
public interface MetricsSink extends MetricsProvider { }
```

### Direction A (primary) — *system log is the metrics façade; it fans out to providers*

The `SystemLogEntry` exposes the metric API. Each call (a) records the value as a KV in
the wide event, and (b) forwards to every installed `MetricsProvider`:

```cajeta
sys.counter("orders.placed", 1, tags("currency","USD"));
//  ├─ writes  "orders.placed": 1   into the system-log entry
//  └─ forwards to each installed MetricsProvider (statsd/prom/otel)
```

- **Why primary:** with no fiber-local storage, the `SystemLog` handle is already the one
  object threaded through the request. Making it the metrics entry point means a single
  call both enriches the wide event *and* drives the provider — no lookup of a "current"
  context needed. Providers are registered once (DI: all `@Component`s implementing
  `MetricsProvider` are collected) and the entry fans out to them.

### Direction B (also supported) — *metrics provider hooks the system log*

For code that only knows the `MetricsProvider` API (e.g. a library that takes a provider
parameter), we register a **`SystemLogMetricsSink`** as one of the installed providers.
When that sink receives a metric it records it into the **current** request's system-log
entry. With `FiberLocal`, "current" is the ambient entry — `Metrics.current()` resolves to a
provider bound to the running request, so third-party code needs no hand-off:

```cajeta
chargeService.charge(amount, Metrics.current());  // ambient: binds to this request's entry
```

The explicit binding still works when you'd rather not rely on ambient state (or before
`FiberLocal` lands): obtain the sink from the entry and pass it where a `MetricsProvider`
is expected.

```cajeta
Metrics m = sys.metrics();         // a MetricsProvider bound to THIS request's entry
chargeService.charge(amount, m);   // library publishes via the provider…
//                                 // …and it also lands in the system-log entry
```

### Recommendation

Use **Direction A** as the default in-house path (richest, simplest), and offer
**Direction B**'s `Metrics.current()` / `sys.metrics()` adapter for interop with
provider-typed APIs. Both are the same data flowing through one `MetricsSink`; the only
difference is who holds the reference. Aggregation (counters summed, timings as
last/aggregate) within a single request is the entry's responsibility; on `flush()` the
aggregated metrics are part of the one JSONL line.

## 11. Async / fiber behavior

- Emitting is safe from fibers: the logger/appender are shared and appenders serialize via
  their own lock or the async channel.
- The ambient `LogContext` / `SystemLogEntry` ride a `FiberLocal` (§7): fan-out under a
  `scope` inherits them (FiberLocal Layer 2); a worker handoff carries a `FiberContext`
  snapshot (Layer 3). No per-call handle threading.
- One `SystemLogEntry` may receive `put`s from multiple fibers of the same request
  (parallel fan-out writing to the inherited entry), so the entry is **internally
  synchronized** (a `Mutex`) — specified as the entry's contract. (Inheritance shares the
  *binding*, not a private copy; the shared entry must therefore be thread-safe.)

## 12. Performance

- Level check before any allocation; no-op builders below threshold.
- Reuse `JsonWriter` buffers per appender; avoid per-record heap churn where possible.
- Async appender keeps request-path latency off the I/O path.

## 13. Testability (with cajeta-unit)

- A `CapturingAppender` (`@TestComponent`) records `LogRecord`s in memory for assertions.
- `@Profile("test")` swaps console/file appenders for the capturing one with zero
  production-code change (DI override, shipped).
- Assert on structured fields, not formatted strings.

## 14. Suggested enhancements (after the basics)

The basics (§§3–8: facade, levels, the three encoders, console/file appenders, DI) come
first. These are the high-value additions a *first-class* logger eventually wants — listed
so the design leaves room for them, **not** scheduled for the first cut:

1. **Error/exception logging with stack traces.** `log.error("…", throwable)` captures the
   exception's type, message, and stack trace as structured fields — ties directly into the
   exception/stack-trace work (`plans/ExceptionReview-plan.md`). The single most-requested
   feature after the basics.
2. **Sensitive-field redaction.** Mark fields (or key patterns) as secret so values are
   masked (`****`/hashed) before encoding — PII/PCI hygiene. A redaction pass on the
   `LogRecord` before the encoder. Important for "first-class."
3. **Trace/correlation correlation.** Auto-include `trace_id`/`span_id` from the ambient
   `FiberLocal` context on every record — OTel-interop without an OTel dependency.
4. **Source location.** Optional `file:line`/method on a record (gated, off the hot path),
   leaning on the same debug-info plumbing the exception work uses.
5. **Sampling / rate-limiting.** Per-logger or per-key "log at most N/sec" and system-log
   sampling under load — design the hook now (a `Filter` stage), ship later.
6. **MDC-style scopes** beyond a single context object: nested `LogContext.where(...)` that
   merge (request → user → operation), riding FiberLocal's nested-binding shadowing.
7. **Dynamic level reconfiguration.** Flip a logger's threshold at runtime (admin endpoint
   / signal) without a restart — common in long-running services.
8. **Structured field types.** First-class `bool`/`float64`/`Instant`/`Duration`/array
   field setters (beyond `str`/`int64`) so JSON types are preserved end to end.

## 15. Open questions / dependencies

- **Tags/label type** (`Tags`) — interned small-map; define the value domain.
- **Field value union** — reuse `JsonValue`, or a lighter logging-specific value? (perf).
- **Sampling** for the system log under load — out of v1, design the hook (§14.5).
- **Cross-fiber entry merge** semantics — define precisely once async patterns settle;
  with FiberLocal inheritance the common case is a *shared synchronized* entry (§11),
  with `#`-transferred sub-entry merge reserved for the detached-handoff case.
- **Depends on shipped:** `cajeta.codec.json` (JSONL), `cajeta.time.Clock` (ts),
  `@Component` DI, `cajeta.io.file` (sinks), async `Channel` (async appender).
- **Depends on scheduled:** `cajeta.concurrent.FiberLocal` (`plans/FiberLocal-plan.md`) for
  ambient context (§7) and the ambient `SystemLog.current()` / `Metrics.current()` paths.
  The framework's **basics build and run without it** (explicit-handle context); ambient
  context is additive and lands when FiberLocal does. No new compiler features required.
