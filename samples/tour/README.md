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

Run:

```sh
./run.sh                       # cajeta on PATH, --profile=dev
CAJETA=/path/to/cajeta ./run.sh
PROFILE=test ./run.sh          # a different DI profile for section 8
```

Library and tour sources compile together into one binary — the same rule as
`run-tests.sh`: compile-time DI resolves in the final compile, so the
`@Profile`-selected providers behind `Log.defaultFor` only wire correctly when
the library sources are part of it. The explicit sections (1–7) construct
their encoders and appenders directly and behave the same under any profile;
only section 8 changes with `PROFILE`.

The plain `===` banner lines between the records are deliberate: a real
console stream interleaves structured records with plain text, and the tour's
output doubles as a fixture for consumers that render JSONL (the Cajeta IDE
plugin's console JSON view among them).
