#!/usr/bin/env bash
# Build + run the FULL cajeta-logging tour (sections 1–8).
#
# Library, tour, and src-di sources are compiled TOGETHER into one executable —
# the same rule as run-tests.sh: compile-time DI resolves the graph in the
# FINAL binary, so the @Profile-selected providers behind `Log.defaultFor`
# (section 8, `@Logged`) only wire correctly when the library sources are part
# of this compile. For the manifest-driven half (sections 1–7 against the
# published .cja), use `cajeta run` with the cajeta.json beside this script.
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
cp -r "$here/src-di/cajeta/." "$srcroot/"

"$CAJETA" --emit=exe --profile="$PROFILE" \
    -o "$out/logging-tour" \
    tour.LoggingTourDi.run "$srcroot" "$out/build" >/dev/null

"$out/logging-tour"
