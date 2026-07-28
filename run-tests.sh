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
# cajeta-unit resolution, in order:
#   1. $UNIT_CJA        — explicit archive path, used verbatim
#   2. $UNIT_REPO       — sibling checkout (default ../cajeta-unit) when it
#                         exists: build it and use whatever version it emits.
#                         The local-dev flow — tests against unit HEAD.
#   3. $OLLA_HOME store — a properly installed dev.cajeta.unit at the version
#                         pinned in cajeta.json's dev-dependencies
#   4. Olla registry    — /v2/resolve + /v2/blob (the toolchain's own fetch
#                         protocol), sha256-verified, cached under build/.
#                         The CI flow: bare runners have no checkout.
# The version for 3/4 comes from cajeta.json's dev-dependencies — the single
# source of truth; nothing here hardcodes it. (This script used to hardcode
# dev.cajeta.unit-0.1.0.cja and only rebuild when that exact file was missing,
# which both linked stale archives and broke outright on any unit bump.)
#
# `cajeta build` does not resolve dev-dependencies today — only runtime
# `dependencies` — which is why step 4 exists at all. When dev-dep resolution
# lands in the toolchain, 3 will always hit and 4 becomes dead code.
#
# Override paths via env:
#   CAJETA     — compiler binary (default: cajeta on PATH)
#   UNIT_CJA   — explicit cajeta-unit .cja (skips all resolution)
#   UNIT_REPO  — path to a cajeta-unit checkout (default: ../cajeta-unit)
#   OLLA_HOME  — local package store (default: ~/.olla)
#   OLLA_URL   — registry base (default: https://olla.cajeta.dev)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
CAJETA="${CAJETA:-cajeta}"
UNIT_REPO="${UNIT_REPO:-$here/../cajeta-unit}"
OLLA_HOME="${OLLA_HOME:-$HOME/.olla}"
OLLA_URL="${OLLA_URL:-https://olla.cajeta.dev}"

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1;
    else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# --- resolve the cajeta-unit archive -----------------------------------------
unit_cja="${UNIT_CJA:-}"

if [[ -z "$unit_cja" && -d "$UNIT_REPO" ]]; then
    echo ">> building cajeta-unit from checkout ($UNIT_REPO)"
    ( cd "$UNIT_REPO" && "$CAJETA" build >/dev/null )
    unit_cja="$(ls -t "$UNIT_REPO"/build/archive/dev.cajeta.unit-*.cja 2>/dev/null | head -1)"
fi

if [[ -z "$unit_cja" ]]; then
    UNIT_VER="$(sed -n 's/.*"dev\.cajeta\.unit"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
        "$here/cajeta.json" | head -1)"
    if [[ -z "$UNIT_VER" ]]; then
        echo "run-tests.sh: no dev.cajeta.unit pin in cajeta.json dev-dependencies" >&2
        exit 1
    fi

    store_cja="$OLLA_HOME/dev.cajeta.unit/$UNIT_VER/dev.cajeta.unit-$UNIT_VER.cja"
    cache_cja="$here/build/.unit-cache/dev.cajeta.unit-$UNIT_VER.cja"
    if [[ -f "$store_cja" ]]; then
        unit_cja="$store_cja"
    elif [[ -f "$cache_cja" ]]; then
        unit_cja="$cache_cja"
    else
        echo ">> fetching dev.cajeta.unit $UNIT_VER from $OLLA_URL"
        meta="$(curl -fsS "$OLLA_URL/v2/resolve?name=dev.cajeta.unit&version=$UNIT_VER")"
        sha="$(printf '%s' "$meta" | sed -n 's/.*"sha256":"sha256:\([0-9a-f]*\)".*/\1/p')"
        if [[ -z "$sha" ]]; then
            echo "run-tests.sh: /v2/resolve gave no sha256 for dev.cajeta.unit $UNIT_VER" >&2
            exit 1
        fi
        mkdir -p "$(dirname "$cache_cja")"
        curl -fsS -o "$cache_cja" "$OLLA_URL/v2/blob/$sha"
        got="$(sha256_of "$cache_cja")"
        if [[ "$got" != "$sha" ]]; then
            rm -f "$cache_cja"
            echo "run-tests.sh: sha256 mismatch fetching dev.cajeta.unit $UNIT_VER" >&2
            echo "  expected $sha" >&2
            echo "  got      $got" >&2
            exit 1
        fi
        unit_cja="$cache_cja"
    fi
fi

if [[ ! -f "$unit_cja" ]]; then
    echo "run-tests.sh: could not resolve a dev.cajeta.unit archive" >&2
    exit 1
fi
echo ">> cajeta-unit: $unit_cja"

# --- build + run --------------------------------------------------------------
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

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
