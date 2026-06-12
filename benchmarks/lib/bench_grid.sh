#!/usr/bin/env bash
# bench_grid.sh — The engine × model comparison grid (ov-5j6.3).
# Sourced by bench_compare.sh; not intended to be run standalone.
#
# Walks the standard model matrix (models.sh) and, for every available engine
# (Vexel / llama.cpp / ollama / MLX), runs WARMUP discarded runs followed by RUNS
# measured runs, emitting ONE per-run JSONL record per measured run in the
# 4-metric contract:
#
#     decode_tok_s  prefill_tok_s  ttft_ms  peak_mem_mb
#
# Honesty rules (the whole point of this epic):
#   - An unavailable engine is SKIPPED with a logged reason, never silently
#     omitted (it simply contributes no run records → measured_n 0 downstream).
#   - A metric an adapter does not measure degrades to 0 and stays VISIBLE in the
#     record (Vexel/llama.cpp adapters report decode+prefill only today; ttft and
#     peak_mem record 0 with a per-row note rather than a fabricated number).
#   - No "best of N": every measured run is recorded; aggregation
#     (aggregate_results.py) reduces to median + p5/p95 + stddev.

set -euo pipefail

# Per-run wall-clock cap. Engine runs can hang indefinitely (observed: a Vexel
# qwen-0.5b run sat 10+ minutes at ~0% CPU — the ov-7ro flake class); without a
# cap, ONE hung run stalls the whole grid forever. A timed-out run records 0s
# (visible, honest) and the grid moves on. Override with BENCH_RUN_TIMEOUT (s).
BENCH_RUN_TIMEOUT="${BENCH_RUN_TIMEOUT:-300}"

# _timeout_cmd — set to "timeout"/"gtimeout" if available, else empty (no cap;
# warn once). GNU timeout is not stock on macOS, so degrade gracefully.
if command -v timeout &>/dev/null; then
    _TIMEOUT_BIN="timeout"
elif command -v gtimeout &>/dev/null; then
    _TIMEOUT_BIN="gtimeout"
else
    _TIMEOUT_BIN=""
    echo "[grid] WARNING: no timeout/gtimeout found — a hung engine run will stall the grid (brew install coreutils)" >&2
fi

# _run_capped <fn> <args...> — run <fn> under the per-run wall-clock cap.
# Functions can't be exec'd by timeout directly, so re-enter bash with the
# library sourced. Exported engine vars (VEXEL_BIN etc.) survive the re-entry.
_run_capped() {
    if [[ -n "$_TIMEOUT_BIN" ]]; then
        "$_TIMEOUT_BIN" --kill-after=10 "$BENCH_RUN_TIMEOUT" \
            bash -c 'source "$1/parse.sh"; shift; "$@"' _ "$_GRID_LIB_DIR" "$@"
    else
        "$@"
    fi
}
_GRID_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Notes attached to each engine's rows (carried into the result entry; the report
# generator surfaces them so a reader is never misled by a degraded-to-0 metric).
VEXEL_NOTE="ttft_ms/peak_mem_mb not measured by the Vexel adapter (reported as 0)."
LLAMA_NOTE="ttft_ms/peak_mem_mb not measured by the llama.cpp adapter (reported as 0)."
OLLAMA_NOTE="decode/prefill/ttft from server timings; peak_mem from /api/ps size_vram."
MLX_NOTE="MLX uses equivalent 4-bit mlx-community weights, NOT the GGUF; ttft is DERIVED from prefill rate."

###############################################################################
# _emit_run <outfile> <engine> <model> <run> <metrics4> <note>
#   metrics4 = "decode prefill ttft peak_mem" (space-separated; missing -> 0).
#   Writes one JSONL record. Pure formatting; no engine invocation here.
###############################################################################
_emit_run() {
    local outfile="$1" engine="$2" model="$3" run="$4" metrics="$5" note="$6"
    local decode prefill ttft mem
    read -r decode prefill ttft mem <<< "$metrics"
    decode="${decode:-0}"; prefill="${prefill:-0}"; ttft="${ttft:-0}"; mem="${mem:-0}"

    emit_jsonl "$outfile" "$(jq -nc \
        --arg engine "$engine" --arg model "$model" --arg note "$note" \
        --argjson run "$run" --argjson gen "$GEN_TOKENS" \
        --argjson decode "$decode" --argjson prefill "$prefill" \
        --argjson ttft "$ttft" --argjson mem "$mem" \
        '{engine:$engine, scenario:"decode", model:$model, run:$run,
          gen_tokens:$gen, decode_tok_s:$decode, prefill_tok_s:$prefill,
          ttft_ms:$ttft, peak_mem_mb:$mem, notes:$note}')"
    echo "    run $run: decode=${decode} prefill=${prefill} ttft=${ttft}ms mem=${mem}MB"
}

###############################################################################
# _bench_engine <outfile> <engine> <model_name> <note> <run_fn> <args...>
#   Generic warmup+measure loop. <run_fn> is a parser function from parse.sh
#   that prints space-separated metrics; <args...> are passed to it verbatim.
#   The loop pads the metric line to 4 fields so 2-metric adapters (Vexel,
#   llama.cpp) record ttft/peak_mem as a visible 0.
###############################################################################
_bench_engine() {
    local outfile="$1" engine="$2" model_name="$3" note="$4" run_fn="$5"
    shift 5
    local args=("$@")

    echo "  $engine warmup ($WARMUP runs)..."
    for ((w = 1; w <= WARMUP; w++)); do
        _run_capped "$run_fn" "${args[@]}" > /dev/null 2>&1 || true
    done

    echo "  $engine measured ($RUNS runs, ${BENCH_RUN_TIMEOUT}s cap each)..."
    for ((r = 1; r <= RUNS; r++)); do
        local raw run_note="$note"
        raw=$(_run_capped "$run_fn" "${args[@]}" || echo "")
        if [[ -z "$raw" ]]; then
            echo "    run $r: FAILED or timed out (>${BENCH_RUN_TIMEOUT}s) — recording 0s"
            run_note="$note RUN FAILED OR TIMED OUT (>${BENCH_RUN_TIMEOUT}s); 0s are not measurements."
        fi
        # Pad to exactly 4 metric fields (decode prefill ttft peak_mem).
        local decode prefill ttft mem _rest
        read -r decode prefill ttft mem _rest <<< "$raw"
        _emit_run "$outfile" "$engine" "$model_name" "$r" \
            "${decode:-0} ${prefill:-0} ${ttft:-0} ${mem:-0}" "$run_note"
    done
}

###############################################################################
# run_grid
#   Run the full engine × model grid over the active model set ($GRID_MODELS,
#   space-separated matrix keys). Results appended to $RESULTS_DIR/grid.jsonl.
###############################################################################
run_grid() {
    local outfile="$RESULTS_DIR/grid.jsonl"
    : > "$outfile"

    local prompt
    prompt=$(generate_prompt 64)

    local key
    for key in $GRID_MODELS; do
        echo ""
        echo "=============================================================="
        echo " Model: $key"
        echo "=============================================================="

        # Resolve per-model sources. The GGUF is downloaded + sha-verified here
        # (on demand) so --smoke never pulls an 8B file.
        local gguf ollama_tag mlx_repo
        gguf=$(setup_matrix_model "$key") || { echo "  [SKIP model] $key — setup failed"; continue; }
        ollama_tag=$(model_ollama_tag "$key")
        mlx_repo=$(model_mlx_repo "$key")

        # ── Vexel (subject under test) ──
        if [[ -n "${VEXEL_BIN:-}" && -x "${VEXEL_BIN:-/nonexistent}" ]]; then
            _bench_engine "$outfile" "vexel" "$key" "$VEXEL_NOTE" \
                run_vexel_generate "$gguf" "$prompt" "$GEN_TOKENS"
        else
            echo "  [SKIP] vexel — binary not available"
        fi

        # ── llama.cpp (ecosystem reference) ──
        if [[ ( -n "${LLAMA_COMPLETION:-}" && "$LLAMA_COMPLETION" != "[missing]" ) || \
              ( -n "${LLAMA_CLI:-}" && "$LLAMA_CLI" != "[missing]" ) ]]; then
            _bench_engine "$outfile" "llama.cpp" "$key" "$LLAMA_NOTE" \
                run_llama_generate "$gguf" "$prompt" "$GEN_TOKENS"
        else
            echo "  [SKIP] llama.cpp — not available"
        fi

        # ── ollama (adoption-share leader) ──
        if [[ "${OLLAMA_AVAILABLE:-0}" == "1" ]]; then
            _bench_engine "$outfile" "ollama" "$key" "$OLLAMA_NOTE" \
                run_ollama_generate "$ollama_tag" "$prompt" "$GEN_TOKENS"
        else
            echo "  [SKIP] ollama — server unavailable (skipped, not silently omitted)"
        fi

        # ── MLX (the engine to beat) ──
        if [[ -n "${MLX_GENERATE:-}" && "$MLX_GENERATE" != "[missing]" ]]; then
            _bench_engine "$outfile" "mlx" "$key" "$MLX_NOTE" \
                run_mlx_generate "$mlx_repo" "$prompt" "$GEN_TOKENS"
        else
            echo "  [SKIP] mlx — mlx_lm not installed (skipped, not silently omitted)"
        fi
    done

    echo ""
    echo "Grid per-run records: $outfile"
}
