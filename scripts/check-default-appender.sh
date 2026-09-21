#!/usr/bin/env bash
# The default `Appender` is the console, in every profile. Asserts a consumer
# built with NO profile writes to stdout and creates no file sink behind its
# back, and that `--profile=dev` still selects the console too.
#
# This cannot be a unit test: the suite runs under `--profile=test`, where the
# masking CapturingAppender replaces the appender, so the suite is structurally
# blind to what any other profile selects.
#
# Override the compiler with CAJETA=/path/to/cajeta (defaults to `cajeta` on PATH).
set -euo pipefail

SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
REPO_ROOT="$( cd -- "${SCRIPT_DIR}/.." &> /dev/null && pwd )"
CAJETA="${CAJETA:-cajeta}"

# Always rebuild. An archive from an earlier source state carries the earlier
# DI wiring and turns this check green for the wrong reason.
( cd "$REPO_ROOT" && "$CAJETA" build )
CJA="$( ls "$REPO_ROOT"/build/archive/dev.cajeta.logging-*.cja | head -1 )"

WORK="$REPO_ROOT/tmp/default-appender"
rm -rf "$WORK"; mkdir -p "$WORK/src/probe" "$WORK/w"
cat > "$WORK/src/probe/Main.cajeta" <<'PROBE'
package probe;

import dev.cajeta.logging.Log;
import dev.cajeta.logging.Logger;
import dev.cajeta.logging.Level;

public class Main {
    public static int32 run() {
        Logger log #= Log.at("probe", Level.INFO);
        log.info("DEFAULT-SINK-LINE");
        return 0;
    }
}
PROBE

arm() {
    local name="$1"; shift
    local dir="$WORK/$name"
    mkdir -p "$dir"
    ( cd "$dir" && "$CAJETA" --emit=exe "$@" --classpath="$CJA" \
        -o out probe.Main.run "$WORK/src" w ) > "$dir/build.log" 2>&1 \
        || { echo "FAIL: $name probe did not compile:" >&2; tail -20 "$dir/build.log" >&2; exit 1; }
    ( cd "$dir" && ./out ) > "$dir/stdout.log" 2>&1
}

# Default: no profile at all. This is what every consumer ships.
arm default
if ! grep -q "DEFAULT-SINK-LINE" "$WORK/default/stdout.log"; then
    echo "FAIL: with no profile the line did not reach stdout." >&2
    echo "      stdout was:" >&2; cat "$WORK/default/stdout.log" >&2
    if [[ -f "$WORK/default/app.jsonl" ]]; then
        echo "      but app.jsonl exists, so a file sink is bound by default:" >&2
        cat "$WORK/default/app.jsonl" >&2
    fi
    exit 1
fi
if [[ -f "$WORK/default/app.jsonl" ]]; then
    echo "FAIL: a file sink was bound by default and wrote app.jsonl." >&2
    exit 1
fi

# dev selects the console too, with the human-readable encoder.
arm dev --profile=dev
if ! grep -q "DEFAULT-SINK-LINE" "$WORK/dev/stdout.log"; then
    echo "FAIL: --profile=dev did not reach stdout." >&2
    cat "$WORK/dev/stdout.log" >&2
    exit 1
fi

echo "check-default-appender: stdout with no profile and under dev, no file sink bound"
