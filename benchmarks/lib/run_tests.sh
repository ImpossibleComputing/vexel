#!/usr/bin/env bash
# run_tests.sh — Run all benchmark-harness unit tests (the harness's own gate).
#
# These are deterministic, network-free, model-free unit tests (parsers + stats +
# schema) — the fast CI gate that catches the harness's most likely silent
# failures (parser/stat/format drift) without downloading models or running an
# engine. Engine-availability checks live separately in benchmarks/validate.sh.
#
# Run:  bash benchmarks/lib/run_tests.sh
# Exit: 0 = all suites pass, 1 = any suite fails.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Activate the benchmark venv if present (so mlx/etc. imports in smoke paths work);
# the unit tests themselves use only the Python stdlib.
VENV_DIR="$SCRIPT_DIR/../.venv"
if [[ -f "$VENV_DIR/bin/activate" ]]; then
    # shellcheck disable=SC1091
    source "$VENV_DIR/bin/activate"
fi

FAIL=0

run_suite() {
    local name="$1"
    shift
    echo "=== $name ==="
    if "$@"; then
        echo "--- $name: PASS"
    else
        echo "--- $name: FAIL"
        FAIL=1
    fi
    echo ""
}

run_suite "parsers (bash, fixtures)"   bash      "$SCRIPT_DIR/parse_test.sh"
run_suite "statistics (python)"        python3   "$SCRIPT_DIR/stats_test.py"
run_suite "result schema (python)"     python3   "$SCRIPT_DIR/result_schema_test.py"
run_suite "metadata parsers (python)"  python3   "$SCRIPT_DIR/metadata_test.py"

if [[ "$FAIL" -eq 0 ]]; then
    echo "ALL HARNESS UNIT TESTS PASSED"
    exit 0
else
    echo "HARNESS UNIT TESTS FAILED"
    exit 1
fi
