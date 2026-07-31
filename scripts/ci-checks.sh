#!/usr/bin/env bash
# The full CI check chain: unit suite, the tour under every DI profile, then
# the tour coverage gate. release.yml's `test-command` points here so the
# list lives in one place.
set -euo pipefail
cd "$(dirname "$0")/.."

./run-tests.sh

PROFILE=dev  ./samples/tour/run.sh
PROFILE=prod ./samples/tour/run.sh
PROFILE=test ./samples/tour/run.sh

CAJETA="$(command -v cajeta)" ./scripts/check-library-tour-coverage.sh \
    src/main/cajeta samples/tour
