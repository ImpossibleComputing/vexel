#!/usr/bin/env bash
# bench_compare.sh — ONE command: run the full engine × model benchmark grid
# and write a machine-readable JSON result. (ov-5j6.3)
#
# This is the single entry point the epic promises: it wires the ov-5j6.1 engine
# adapters (Vexel / llama.cpp / ollama / MLX) and the ov-5j6.2 statistical harness
# (warmup discard, median/p5/p95/stddev, auto-captured versions + hardware) over
# the ov-5j6.3 standard model matrix, and emits one honest, variance-aware
# results JSON under benchmarks/results/.
#
# Usage:
#   benchmarks/bench_compare.sh [options]
#   make bench-compare            # full matrix
#   make bench-smoke              # fast pipeline validation (Qwen-0.5B only)
#
# Options:
#   --smoke              Fast end-to-end pipeline check: Qwen-0.5B only, short
#                        runs, no 8B downloads. (warmup=1, runs=3, gen-tokens=32)
#   --models "a b c"     Explicit space-separated matrix keys (overrides default).
#                        Valid keys: $(model_keys). Default: full matrix.
#   --warmup N           Warmup runs to discard per cell (default: 2; smoke: 1).
#   --runs N             Measured runs per cell (default: 10; smoke: 3).
#   --gen-tokens N       Tokens generated per run (default: 128; smoke: 32).
#   --output PATH        Result JSON path (default: results/<UTC-stamp>/compare.json).
#   -h, --help           Show this help.
#
# Trust knobs (env):
#   BENCH_ALLOW_SHA_MISMATCH=1   Continue despite a weight sha256 mismatch (off by
#                                default — an unverified weight aborts the run).

set -euo pipefail

BENCH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Remember whether the caller pinned a per-run timeout before bench_grid.sh
# applies its default, so --smoke can pick a tighter one without overriding the user.
_USER_RUN_TIMEOUT="${BENCH_RUN_TIMEOUT:-}"

source "$BENCH_ROOT/lib/models.sh"
source "$BENCH_ROOT/lib/engines.sh"
source "$BENCH_ROOT/lib/parse.sh"
source "$BENCH_ROOT/lib/bench_grid.sh"

###############################################################################
# Defaults (overridable by flags; --smoke flips the whole profile fast).
###############################################################################
SMOKE=0
WARMUP=""
RUNS=""
GEN_TOKENS=""
MODELS_OVERRIDE=""
OUTPUT=""

usage() { sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --smoke)        SMOKE=1; shift ;;
        --models)       MODELS_OVERRIDE="${2:?--models needs a value}"; shift 2 ;;
        --warmup)       WARMUP="${2:?--warmup needs a value}"; shift 2 ;;
        --runs)         RUNS="${2:?--runs needs a value}"; shift 2 ;;
        --gen-tokens)   GEN_TOKENS="${2:?--gen-tokens needs a value}"; shift 2 ;;
        --output|-o)    OUTPUT="${2:?--output needs a value}"; shift 2 ;;
        -h|--help)      usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

# Profile: smoke is the fast pipeline-validation path; otherwise the full grid.
if [[ "$SMOKE" == "1" ]]; then
    WARMUP="${WARMUP:-1}"
    RUNS="${RUNS:-3}"
    GEN_TOKENS="${GEN_TOKENS:-32}"
    GRID_MODELS="${MODELS_OVERRIDE:-$(smoke_keys | tr '\n' ' ')}"
    # Fail fast in smoke: a hung run should cost ~2 min, not the full 5-min cap.
    BENCH_RUN_TIMEOUT="${_USER_RUN_TIMEOUT:-120}"
    PROFILE="smoke"
else
    WARMUP="${WARMUP:-2}"
    RUNS="${RUNS:-10}"
    GEN_TOKENS="${GEN_TOKENS:-128}"
    GRID_MODELS="${MODELS_OVERRIDE:-$(model_keys | tr '\n' ' ')}"
    PROFILE="full"
fi

# Results destination (UTC-stamped dir; results/* is gitignored except SCHEMA/example).
STAMP="$(date -u +%Y-%m-%dT%H-%M-%SZ)"
RESULTS_DIR="$BENCH_ROOT/results/$STAMP"
mkdir -p "$RESULTS_DIR"
OUTPUT="${OUTPUT:-$RESULTS_DIR/compare.json}"

export WARMUP RUNS GEN_TOKENS GRID_MODELS RESULTS_DIR

echo "=============================================="
echo " Vexel multi-engine benchmark — bench-compare"
echo " Profile:    $PROFILE"
echo " Models:     $GRID_MODELS"
echo " Warmup:     $WARMUP discarded / cell"
echo " Measured:   $RUNS runs / cell"
echo " Gen tokens: $GEN_TOKENS"
echo " Results:    $RESULTS_DIR"
echo "=============================================="

###############################################################################
# Discover engines (each degrades gracefully — a missing engine is skipped with
# a logged reason, never silently omitted).
###############################################################################
setup_engines

###############################################################################
# Run the grid → per-run JSONL.
###############################################################################
run_grid

###############################################################################
# Aggregate → one validated, variance-aware result JSON.
#   --warmup 0: the grid loop already pre-discarded its warmup runs, so every
#   record in grid.jsonl is a measured run.
###############################################################################
echo ""
echo "=== Aggregating → $OUTPUT ==="
python3 "$BENCH_ROOT/lib/aggregate_results.py" "$RESULTS_DIR/grid.jsonl" \
    -o "$OUTPUT" --warmup 0

###############################################################################
# Render the publishable markdown report (ov-5j6.4) — the generated replacement
# for hand-edited RESULTS.md / perf_reports.
###############################################################################
REPORT_MD="${OUTPUT%.json}.md"
echo ""
echo "=== Report → $REPORT_MD ==="
python3 "$BENCH_ROOT/lib/report_compare.py" "$OUTPUT" -o "$REPORT_MD"

echo ""
echo "=============================================="
echo " bench-compare complete."
echo " Per-run JSONL: $RESULTS_DIR/grid.jsonl"
echo " Result JSON:   $OUTPUT"
echo " Report:        $REPORT_MD"
echo ""
echo " CI regression guard (vs stored baseline):"
echo "   python3 benchmarks/lib/regression_guard.py $OUTPUT"
echo " Promote this run as the new baseline:"
echo "   cp $OUTPUT benchmarks/results/baseline.json"
echo "=============================================="
