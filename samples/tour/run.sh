#!/usr/bin/env bash
# Build + run the FULL cajeta-logging tour (all demos + the DI half).
#
# Library, tour, and src-di sources are compiled TOGETHER into one executable —
# the same rule as run-tests.sh: compile-time DI resolves the graph in the
# FINAL binary, so the @Profile-selected providers behind `Log.defaultFor`
# (`@Logged`, `LoggerFactory`) only wire correctly when the library sources are
# part of this compile. For the manifest-driven half (the explicit demos
# against the published .cja), use `cajeta run` with the cajeta.json beside
# this script.
#
#   PROFILE — DI profile for the service scenario (default: dev)
#   CAJETA  — compiler binary (default: cajeta on PATH)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
CAJETA="${CAJETA:-cajeta}"
PROFILE="${PROFILE:-dev}"

out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

srcroot="$out/src"
mkdir -p "$srcroot"
cp -r "$root/src/main/cajeta/." "$srcroot/"
cp -r "$here/src/main/cajeta/." "$srcroot/"
cp -r "$here/src-di/cajeta/." "$srcroot/"

"$CAJETA" --emit=exe --profile="$PROFILE" \
    -o "$out/logging-tour" \
    tour.LoggingTourDi.run "$srcroot" "$out/build" >/dev/null

# Say up front where the DI section's lines will go, so nothing "vanishes".
case "$PROFILE" in
  dev)  echo ">> DI profile: dev  — service-scenario lines print below as TEXT (console appender)";;
  prod) echo ">> DI profile: prod — service-scenario lines land in ./app.jsonl (file appender), not on the console";;
  test) echo ">> DI profile: test — service-scenario lines are CAPTURED by the masking CapturingAppender; they are not printed anywhere (the sink tests assert through)";;
  *)    echo ">> DI profile: $PROFILE";;
esac

# prod writes into the CURRENT directory; run from a scratch dir so the
# tour never litters the invoker's cwd, then verify the destination.
rundir="$out/run"
mkdir -p "$rundir"
status=0
( cd "$rundir" && "$out/logging-tour" ) || status=$?

if [[ "$PROFILE" == "prod" ]]; then
    if grep -q '"msg":"payment settled"' "$rundir/app.jsonl" 2>/dev/null; then
        echo ">> verified: app.jsonl carries the JSONL service lines, e.g."
        tail -1 "$rundir/app.jsonl"
    else
        echo ">> FAIL: prod profile did not write the expected app.jsonl" >&2
        exit 1
    fi
fi

exit "$status"
