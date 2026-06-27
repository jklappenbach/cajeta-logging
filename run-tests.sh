#!/usr/bin/env bash
# Build + run the cajeta-logging unit tests (Tier-1 Phase 1).
#
# The suite lives under src/test/cajeta and is driven by cajeta-unit's
# reflective @Test discovery (dev.cajeta.unit.Runner). It compiles ONLY the
# test sources into an executable, with the logging library and cajeta-unit
# both supplied as .cja classpath dependencies — the compiler links their
# bitcode into the test binary (requires a toolchain with classpath-bitcode
# linking, cajeta >= 0.7.1-dev with that fix).
#
# Until `cajeta test` can resolve a dev-dependency + the project's own lib
# onto the test classpath, this script is the supported entry point.
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

echo ">> building logging library .cja"
"$CAJETA" --emit=cja -o "$out/logging.cja" \
    dev.cajeta.logging.Log.run "$here/src/main/cajeta" "$out" >/dev/null

echo ">> building + running the test binary"
"$CAJETA" --emit=exe --profile=test \
    --classpath="$out/logging.cja,$unit_cja" \
    -o "$out/logtests" \
    dev.cajeta.logging.selftest.TestMain.run "$here/src/test/cajeta" "$out" >/dev/null

"$out/logtests"
