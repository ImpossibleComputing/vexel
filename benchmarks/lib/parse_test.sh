#!/usr/bin/env bash
# parse_test.sh — Unit tests for the benchmark output parsers.
#
# Why this exists: parser drift (an engine tweaks its stdout/JSON format on a
# version bump) is the single most likely SILENT failure mode of this harness —
# a benchmark that quietly parses 0 tok/s looks like a slow engine, not a broken
# parser. These tests pin each parser against CAPTURED FIXTURE output from a real
# run (see benchmarks/lib/fixtures/), so format drift fails loudly in CI instead
# of corrupting a published "where does Vexel stand" number.
#
# Run standalone:  bash benchmarks/lib/parse_test.sh
# Exit code 0 = all pass, 1 = any failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURES="$SCRIPT_DIR/fixtures"

# shellcheck source=./parse.sh
source "$SCRIPT_DIR/parse.sh"
# parse.sh enables `set -e`; disable it here so an assertion's internal non-zero
# (e.g. a failed [[ ]]) reports a FAIL instead of aborting the whole runner.
set +e

TESTS_RUN=0
TESTS_FAILED=0

# assert_close <name> <actual> <expected> <tolerance>
#   Float comparison with absolute tolerance (parsers do division/unit math, so
#   exact string equality is too brittle).
assert_close() {
    local name="$1" actual="$2" expected="$3" tol="$4"
    TESTS_RUN=$((TESTS_RUN + 1))
    local ok
    ok=$(awk -v a="$actual" -v e="$expected" -v t="$tol" \
        'BEGIN { d = a - e; if (d < 0) d = -d; print (d <= t) ? "1" : "0" }')
    if [[ "$ok" == "1" ]]; then
        echo "  ok   $name (got $actual, expected ~$expected)"
    else
        echo "  FAIL $name (got $actual, expected ~$expected ±$tol)"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

###############################################################################
echo "== MLX parser (fixture: real mlx_lm.generate --verbose output) =="
# Fixture:
#   Prompt: 33 tokens, 97.790 tokens-per-sec
#   Generation: 10 tokens, 577.359 tokens-per-sec
#   Peak memory: 0.310 GB
# Expected:
#   decode      = 577.359   (Generation rate, direct)
#   prefill     =  97.790   (Prompt rate, direct)
#   ttft_ms     = 337.46    (DERIVED: prompt_tokens / prefill_rate * 1000 = 33/97.790*1000)
#   peak_mem_mb = 317.44    (0.310 GiB * 1024)
mlx_out=$(parse_mlx_metrics "$FIXTURES/mlx_qwen05b.txt")
read -r mlx_decode mlx_prefill mlx_ttft mlx_mem <<<"$mlx_out"
assert_close "mlx decode tok/s"   "$mlx_decode"  "577.359" "0.01"
assert_close "mlx prefill tok/s"  "$mlx_prefill" "97.790"  "0.01"
assert_close "mlx ttft_ms"        "$mlx_ttft"    "337.46"  "0.5"
assert_close "mlx peak_mem_mb"    "$mlx_mem"     "317.44"  "0.5"

###############################################################################
echo "== ollama parser (fixture: real /api/generate + /api/ps JSON) =="
# Fixture /api/generate (durations in nanoseconds):
#   prompt_eval_count=4   prompt_eval_duration=232019875
#   eval_count=20         eval_duration=76609791
#   load_duration=14182956000
# Fixture /api/ps: size_vram=1804817920
# Expected:
#   decode      = 261.06    (eval_count / (eval_duration/1e9))
#   prefill     =  17.24    (prompt_eval_count / (prompt_eval_duration/1e9))
#   ttft_ms     = 14414.98  (MEASURED: (load_duration + prompt_eval_duration)/1e6; load dominant on cold capture)
#   peak_mem_mb = 1721.21   (size_vram / 1048576)
ol_out=$(parse_ollama_metrics "$FIXTURES/ollama_generate_qwen05b.json" "$FIXTURES/ollama_ps_qwen05b.json")
read -r ol_decode ol_prefill ol_ttft ol_mem <<<"$ol_out"
assert_close "ollama decode tok/s"  "$ol_decode"  "261.06"   "0.1"
assert_close "ollama prefill tok/s" "$ol_prefill" "17.24"    "0.1"
assert_close "ollama ttft_ms"       "$ol_ttft"    "14414.98" "1.0"
assert_close "ollama peak_mem_mb"   "$ol_mem"     "1721.21"  "0.5"

echo "== ollama parser: missing /api/ps degrades to 0 memory (never crashes) =="
ol_out_nomem=$(parse_ollama_metrics "$FIXTURES/ollama_generate_qwen05b.json")
read -r _ _ _ ol_mem_missing <<<"$ol_out_nomem"
assert_close "ollama peak_mem_mb when ps absent" "$ol_mem_missing" "0" "0"

###############################################################################
echo ""
if [[ "$TESTS_FAILED" -eq 0 ]]; then
    echo "PASS: $TESTS_RUN/$TESTS_RUN parser assertions passed"
    exit 0
else
    echo "FAIL: $TESTS_FAILED/$TESTS_RUN parser assertions failed"
    exit 1
fi
