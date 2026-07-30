#!/usr/bin/env bash
# Build + run the cajeta-logging tour (samples/tour).
#
# Library and tour sources are compiled TOGETHER into one executable — the
# same rule as run-tests.sh: compile-time DI resolves the graph in the FINAL
# binary, so the @Profile-selected providers behind `Log.defaultFor` (and the
# `@Logged` section) only wire correctly when the library sources are part of
# this compile.
#
#   PROFILE — DI profile (default: dev → text encoder + console appender for
#             the @Logged/DI section; the explicit JSONL sections emit JSONL
#             regardless of profile)
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

"$CAJETA" --emit=exe --profile="$PROFILE" \
    -o "$out/logging-tour" \
    tour.LoggingTour.run "$srcroot" "$out/build" >/dev/null

"$out/logging-tour"
