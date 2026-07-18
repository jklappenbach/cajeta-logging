#!/usr/bin/env bash
# Build + run the cajeta-logging unit tests.
#
# The suite lives under src/test/cajeta and is driven by cajeta-unit's
# reflective @Test discovery (dev.cajeta.unit.Runner).
#
# The library and test sources are compiled TOGETHER under --profile=test into
# one executable (cajeta-unit supplied as a .cja classpath dep). This matters
# for the DI-wired logger: compile-time DI resolves the graph in the FINAL
# binary, so the profile-selected providers (@Profile) and the @TestComponent
# CapturingAppender masking only apply when the components' sources are part of
# this compile. A precompiled library .cja carries DI wiring frozen at its own
# build profile and does not re-resolve under --profile=test.
#
# Override paths via env:
#   CAJETA    — compiler binary (default: cajeta on PATH)
#   UNIT_REPO — path to the cajeta-unit checkout (default: ../cajeta-unit)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
CAJETA="${CAJETA:-cajeta}"
UNIT_REPO="${UNIT_REPO:-$here/../cajeta-unit}"

out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

unit_cja="$UNIT_REPO/build/archive/dev.cajeta.unit-0.1.0.cja"
if [[ ! -f "$unit_cja" ]]; then
    echo ">> building cajeta-unit .cja ($UNIT_REPO)"
    ( cd "$UNIT_REPO" && "$CAJETA" build >/dev/null )
fi

# Merge library + test sources into one root so the DI graph resolves in the
# final --profile=test binary (see header).
srcroot="$out/src"
mkdir -p "$srcroot"
cp -r "$here/src/main/cajeta/." "$srcroot/"
cp -r "$here/src/test/cajeta/." "$srcroot/"

echo ">> building + running the test binary (lib+test sources, --profile=test)"
"$CAJETA" --emit=exe --profile=test \
    --classpath="$unit_cja" \
    -o "$out/logtests" \
    dev.cajeta.logging.selftest.TestMain.run "$srcroot" "$out/build" >/dev/null

"$out/logtests"
