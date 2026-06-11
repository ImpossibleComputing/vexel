#!/usr/bin/env bash
# parse.sh — Output parsing helpers for the Vexel benchmark suite.
# Sourced by benchmark scripts; not intended to be run standalone.
#
# Provides functions to run Vexel and llama.cpp, parse their output,
# and emit structured JSONL results.

set -euo pipefail

###############################################################################
# generate_prompt <target_tokens>
#   Generate a synthetic prompt of approximately <target_tokens> tokens.
#   Uses repeated common English words (~1 token per word for most tokenizers).
#   Prints the prompt to stdout.
###############################################################################
generate_prompt() {
    local target_tokens="${1:?Usage: generate_prompt <target_tokens>}"
    local words=("The" "quick" "brown" "fox" "jumps" "over" "the" "lazy" "dog"
                 "and" "then" "runs" "back" "across" "the" "wide" "green" "field"
                 "while" "the" "sun" "shines" "brightly" "in" "the" "clear" "blue" "sky"
                 "above" "the" "tall" "mountain" "range")
    local num_words=${#words[@]}
    local prompt=""
    for ((i = 0; i < target_tokens; i++)); do
        if [[ $i -gt 0 ]]; then
            prompt+=" "
        fi
        prompt+="${words[$((i % num_words))]}"
    done
    echo "$prompt"
}

###############################################################################
# run_vexel_generate <model> <prompt> <max_tokens> [extra_flags...]
#   Run Vexel generate with --verbose and parse throughput numbers.
#   Prints to stdout: decode_tok_s prefill_tok_s
###############################################################################
run_vexel_generate() {
    local model="${1:?Usage: run_vexel_generate <model> <prompt> <max_tokens> [flags...]}"
    local prompt="${2:?}"
    local max_tokens="${3:?}"
    shift 3
    local extra_flags=("$@")

    # Use temp file to avoid bash xrealloc issues with large/binary model output
    local tmpfile
    tmpfile=$(mktemp)

    "$VEXEL_BIN" --model "$model" --verbose generate \
        --prompt "$prompt" --max-tokens "$max_tokens" \
        ${extra_flags[@]+"${extra_flags[@]}"} > "$tmpfile" 2>&1 || true

    local decode_tok_s prefill_tok_s
    # Parse: [N tokens | prefill: X.X tok/s | decode: Y.Y tok/s]
    decode_tok_s=$(grep -oE 'decode: [0-9]+\.?[0-9]* tok/s' "$tmpfile" | grep -oE '[0-9]+\.?[0-9]*' | head -1 || true)
    prefill_tok_s=$(grep -oE 'prefill: [0-9]+\.?[0-9]* tok/s' "$tmpfile" | grep -oE '[0-9]+\.?[0-9]*' | head -1 || true)

    rm -f "$tmpfile"
    echo "${decode_tok_s:-0} ${prefill_tok_s:-0}"
}

###############################################################################
# run_vexel_medusa <model> <prompt> <max_tokens> [extra_flags...]
#   Run Vexel with --medusa and parse throughput + speculative stats.
#   Prints to stdout: decode_tok_s prefill_tok_s acceptance_pct speedup
###############################################################################
run_vexel_medusa() {
    local model="${1:?Usage: run_vexel_medusa <model> <prompt> <max_tokens> [flags...]}"
    local prompt="${2:?}"
    local max_tokens="${3:?}"
    shift 3
    local extra_flags=("$@")

    # Use temp file to avoid bash xrealloc issues with large/binary model output
    local tmpfile
    tmpfile=$(mktemp)

    "$VEXEL_BIN" --model "$model" --verbose --medusa generate \
        --prompt "$prompt" --max-tokens "$max_tokens" \
        ${extra_flags[@]+"${extra_flags[@]}"} > "$tmpfile" 2>&1 || true

    local decode_tok_s prefill_tok_s acceptance_pct speedup
    decode_tok_s=$(grep -oE 'decode: [0-9]+\.?[0-9]* tok/s' "$tmpfile" | grep -oE '[0-9]+\.?[0-9]*' | head -1 || true)
    prefill_tok_s=$(grep -oE 'prefill: [0-9]+\.?[0-9]* tok/s' "$tmpfile" | grep -oE '[0-9]+\.?[0-9]*' | head -1 || true)
    # Parse: [speculative: acceptance=Z.Z% speedup=W.Wx generated=G accepted=A]
    acceptance_pct=$(grep -oE 'acceptance=[0-9]+\.?[0-9]*%' "$tmpfile" | grep -oE '[0-9]+\.?[0-9]*' | head -1 || true)
    speedup=$(grep -oE 'speedup=[0-9]+\.?[0-9]*x' "$tmpfile" | grep -oE '[0-9]+\.?[0-9]*' | head -1 || true)

    rm -f "$tmpfile"
    echo "${decode_tok_s:-0} ${prefill_tok_s:-0} ${acceptance_pct:-0} ${speedup:-0}"
}

###############################################################################
# run_vexel_draft <model> <draft_model> <prompt> <max_tokens> [extra_flags...]
#   Run Vexel with --draft-model and parse throughput + speculative stats.
#   Prints to stdout: decode_tok_s prefill_tok_s acceptance_pct speedup
###############################################################################
run_vexel_draft() {
    local model="${1:?Usage: run_vexel_draft <model> <draft_model> <prompt> <max_tokens> [flags...]}"
    local draft_model="${2:?}"
    local prompt="${3:?}"
    local max_tokens="${4:?}"
    shift 4
    local extra_flags=("$@")

    # Use temp file to avoid bash xrealloc issues with large/binary model output
    local tmpfile
    tmpfile=$(mktemp)

    "$VEXEL_BIN" --model "$model" --draft-model "$draft_model" --verbose generate \
        --prompt "$prompt" --max-tokens "$max_tokens" \
        ${extra_flags[@]+"${extra_flags[@]}"} > "$tmpfile" 2>&1 || true

    local decode_tok_s prefill_tok_s acceptance_pct speedup
    decode_tok_s=$(grep -oE 'decode: [0-9]+\.?[0-9]* tok/s' "$tmpfile" | grep -oE '[0-9]+\.?[0-9]*' | head -1 || true)
    prefill_tok_s=$(grep -oE 'prefill: [0-9]+\.?[0-9]* tok/s' "$tmpfile" | grep -oE '[0-9]+\.?[0-9]*' | head -1 || true)
    acceptance_pct=$(grep -oE 'acceptance=[0-9]+\.?[0-9]*%' "$tmpfile" | grep -oE '[0-9]+\.?[0-9]*' | head -1 || true)
    speedup=$(grep -oE 'speedup=[0-9]+\.?[0-9]*x' "$tmpfile" | grep -oE '[0-9]+\.?[0-9]*' | head -1 || true)

    rm -f "$tmpfile"
    echo "${decode_tok_s:-0} ${prefill_tok_s:-0} ${acceptance_pct:-0} ${speedup:-0}"
}

###############################################################################
# run_llama_generate <model> <prompt> <max_tokens> [extra_flags...]
#   Run llama-completion (non-interactive) and parse throughput.
#   Uses llama-completion with -no-cnv for text generation mode.
#   Falls back to llama-cli if llama-completion is not available.
#   Prints to stdout: decode_tok_s prefill_tok_s
#   Returns "0 0" if no llama binary is available.
###############################################################################
run_llama_generate() {
    local model="${1:?Usage: run_llama_generate <model> <prompt> <max_tokens> [flags...]}"
    local prompt="${2:?}"
    local max_tokens="${3:?}"
    shift 3
    local extra_flags=("$@")

    # Prefer llama-completion (non-interactive), fall back to llama-cli
    local llama_bin=""
    local llama_flags=()
    if [[ -n "${LLAMA_COMPLETION:-}" && "$LLAMA_COMPLETION" != "[missing]" ]]; then
        llama_bin="$LLAMA_COMPLETION"
        llama_flags=(-no-cnv --no-display-prompt)
    elif [[ -n "${LLAMA_CLI:-}" && "$LLAMA_CLI" != "[missing]" ]]; then
        llama_bin="$LLAMA_CLI"
        llama_flags=(-no-cnv --no-display-prompt)
    else
        echo "0 0"
        return 0
    fi

    local tmpfile
    tmpfile=$(mktemp)

    "$llama_bin" -m "$model" -p "$prompt" -n "$max_tokens" \
        "${llama_flags[@]}" --temp 0 \
        ${extra_flags[@]+"${extra_flags[@]}"} > "$tmpfile" 2>&1 || true

    local decode_tok_s prefill_tok_s
    # Parse eval time from various llama.cpp output formats:
    #   common_perf_print:        eval time =    2499.70 ms /   127 runs   (   19.68 ms per token,    50.81 tokens per second)
    #   llama_perf_context_print: eval time = ...
    #   llama_print_timings:      eval time = ...
    # Exclude lines containing "prompt eval" to get decode-only eval time.
    decode_tok_s=$(grep -E 'eval time' "$tmpfile" | grep -v 'prompt eval' | \
        grep -oE '[0-9]+\.?[0-9]* tokens per second' | grep -oE '[0-9]+\.?[0-9]*' | head -1 || true)
    # Parse prompt eval time (prefill):
    #   common_perf_print: prompt eval time = ...
    prefill_tok_s=$(grep -E 'prompt eval time' "$tmpfile" | \
        grep -oE '[0-9]+\.?[0-9]* tokens per second' | grep -oE '[0-9]+\.?[0-9]*' | head -1 || true)

    rm -f "$tmpfile"
    echo "${decode_tok_s:-0} ${prefill_tok_s:-0}"
}

###############################################################################
# run_llama_speculative <model> <draft_model> <prompt> <max_tokens> [extra_flags...]
#   Run llama-speculative with -md draft model and parse throughput + acceptance.
#   Prints to stdout: decode_tok_s prefill_tok_s acceptance_pct
#   Returns "0 0 0" if LLAMA_SPECULATIVE is empty or missing.
###############################################################################
run_llama_speculative() {
    local model="${1:?Usage: run_llama_speculative <model> <draft_model> <prompt> <max_tokens> [flags...]}"
    local draft_model="${2:?}"
    local prompt="${3:?}"
    local max_tokens="${4:?}"
    shift 4
    local extra_flags=("$@")

    if [[ -z "${LLAMA_SPECULATIVE:-}" || "$LLAMA_SPECULATIVE" == "[missing]" ]]; then
        echo "0 0 0"
        return 0
    fi

    # Use temp file to avoid bash xrealloc issues with binary/unicode model output
    local tmpfile
    tmpfile=$(mktemp)

    "$LLAMA_SPECULATIVE" -m "$model" -md "$draft_model" \
        -p "$prompt" -n "$max_tokens" \
        --no-display-prompt ${extra_flags[@]+"${extra_flags[@]}"} > "$tmpfile" 2>&1 || true

    local decode_tok_s prefill_tok_s acceptance_pct
    decode_tok_s=$(grep -E 'eval time' "$tmpfile" | grep -v 'prompt eval' | \
        grep -oE '[0-9]+\.?[0-9]* tokens per second' | grep -oE '[0-9]+\.?[0-9]*' | head -1 || true)
    prefill_tok_s=$(grep -E 'prompt eval time' "$tmpfile" | \
        grep -oE '[0-9]+\.?[0-9]* tokens per second' | grep -oE '[0-9]+\.?[0-9]*' | head -1 || true)
    # Parse: speculative: accept rate: 0.456
    acceptance_pct=$(grep -oE 'accept rate: [0-9]+\.?[0-9]*' "$tmpfile" | grep -oE '[0-9]+\.?[0-9]*' | head -1 || true)
    # Convert from 0-1 fraction to percentage if present
    if [[ -n "$acceptance_pct" ]]; then
        acceptance_pct=$(awk "BEGIN {printf \"%.1f\", $acceptance_pct * 100}")
    fi

    rm -f "$tmpfile"
    echo "${decode_tok_s:-0} ${prefill_tok_s:-0} ${acceptance_pct:-0}"
}

###############################################################################
# THE 4-METRIC CONTRACT (ollama + MLX adapters)
#
# run_ollama_generate / run_mlx_generate print FOUR space-separated values:
#     decode_tok_s  prefill_tok_s  ttft_ms  peak_mem_mb
#
# Not every engine reports every metric natively, so the harness must be honest
# about which numbers are MEASURED vs DERIVED:
#   - MLX     : decode/prefill/peak_mem are measured; TTFT is DERIVED
#               (prompt_tokens / prefill_rate) because mlx_lm emits no TTFT.
#   - ollama  : decode/prefill/TTFT are measured (server timings); peak_mem is
#               read from a separate /api/ps call (the generate response has none).
# A missing value degrades to 0 (engine skipped/unavailable) — NEVER silently
# dropped. The parse_* helpers below are pure (file in, metrics out) so they can
# be unit-tested against captured fixtures (see parse_test.sh).
###############################################################################

###############################################################################
# parse_mlx_metrics <stdout_file>
#   Parse `mlx_lm.generate --verbose True` stdout into the 4-metric contract.
#   Expected fixture lines:
#     Prompt: 33 tokens, 97.790 tokens-per-sec
#     Generation: 10 tokens, 577.359 tokens-per-sec
#     Peak memory: 0.310 GB
#   Prints: decode_tok_s prefill_tok_s ttft_ms peak_mem_mb
###############################################################################
parse_mlx_metrics() {
    local f="${1:?Usage: parse_mlx_metrics <stdout_file>}"
    awk '
        /^Generation:/  { decode = $4 }           # "Generation: N tokens, RATE tokens-per-sec"
        /^Prompt:/      { prefill = $4; ptoks = $2 } # "Prompt: N tokens, RATE tokens-per-sec"
        /^Peak memory:/ { gb = $3 }                # "Peak memory: X.XXX GB" (GiB)
        END {
            # MLX does not emit TTFT; derive it from prefill throughput.
            ttft = (prefill + 0 > 0) ? (ptoks / prefill) * 1000 : 0
            mem  = (gb + 0) * 1024                  # MLX prints GiB -> MiB
            printf "%.3f %.3f %.2f %.2f\n", decode + 0, prefill + 0, ttft, mem
        }
    ' "$f"
}

###############################################################################
# parse_ollama_metrics <generate_json> [ps_json]
#   Parse an ollama /api/generate response (durations in NANOSECONDS) into the
#   4-metric contract. Optional /api/ps JSON supplies peak memory (size_vram);
#   if omitted/absent, peak_mem_mb degrades to 0 rather than failing.
#   Prints: decode_tok_s prefill_tok_s ttft_ms peak_mem_mb
###############################################################################
parse_ollama_metrics() {
    local gen="${1:?Usage: parse_ollama_metrics <generate_json> [ps_json]}"
    local ps="${2:-}"

    local ec ed pc pd ld vram
    ec=$(jq -r '.eval_count // 0' "$gen" 2>/dev/null || echo 0)
    ed=$(jq -r '.eval_duration // 0' "$gen" 2>/dev/null || echo 0)
    pc=$(jq -r '.prompt_eval_count // 0' "$gen" 2>/dev/null || echo 0)
    pd=$(jq -r '.prompt_eval_duration // 0' "$gen" 2>/dev/null || echo 0)
    ld=$(jq -r '.load_duration // 0' "$gen" 2>/dev/null || echo 0)
    vram=0
    if [[ -n "$ps" && -f "$ps" ]]; then
        vram=$(jq -r '.models[0].size_vram // 0' "$ps" 2>/dev/null || echo 0)
    fi

    awk -v ec="$ec" -v ed="$ed" -v pc="$pc" -v pd="$pd" -v ld="$ld" -v vram="$vram" 'BEGIN {
        decode  = (ed > 0) ? ec / (ed / 1e9) : 0    # tokens / seconds
        prefill = (pd > 0) ? pc / (pd / 1e9) : 0
        ttft    = (ld + pd) / 1e6                    # ns -> ms (load + prompt eval)
        mem     = vram / 1048576                     # bytes -> MiB
        printf "%.3f %.3f %.2f %.2f\n", decode, prefill, ttft, mem
    }'
}

###############################################################################
# run_mlx_generate <model> <prompt> <max_tokens> [extra_flags...]
#   Run mlx_lm.generate (greedy, raw prompt) and parse the 4 metrics.
#   <model> is an MLX-format model (HF repo id or local dir), e.g.
#   mlx-community/Qwen2.5-0.5B-Instruct-4bit — NOT the GGUF used by the others
#   (see the MLX caveat in engines.sh:find_mlx). Returns "0 0 0 0" if MLX is
#   unavailable so the engine is skipped, never silently omitted.
###############################################################################
run_mlx_generate() {
    local model="${1:?Usage: run_mlx_generate <model> <prompt> <max_tokens> [flags...]}"
    local prompt="${2:?}"
    local max_tokens="${3:?}"
    shift 3
    local extra_flags=("$@")

    if [[ -z "${MLX_GENERATE:-}" || "$MLX_GENERATE" == "[missing]" ]]; then
        echo "0 0 0 0"
        return 0
    fi

    local tmpfile
    tmpfile=$(mktemp)

    # --ignore-chat-template: tokenize the raw prompt (matches llama.cpp/Vexel
    #   raw -p) so prefill token counts are comparable across engines.
    # --temp 0: greedy/deterministic. --seed 0: reproducibility.
    "$MLX_GENERATE" --model "$model" --prompt "$prompt" \
        --max-tokens "$max_tokens" --temp 0 --seed 0 \
        --ignore-chat-template --verbose True \
        ${extra_flags[@]+"${extra_flags[@]}"} > "$tmpfile" 2>&1 || true

    parse_mlx_metrics "$tmpfile"
    rm -f "$tmpfile"
}

###############################################################################
# run_ollama_generate <model_tag> <prompt> <max_tokens>
#   Run a one-shot generation via the ollama HTTP API (greedy, raw prompt) and
#   parse the 4 metrics. <model_tag> is an ollama tag (e.g. "qwen2.5:0.5b") that
#   should reference the SAME base model at an equivalent quant (Q4_K_M) as the
#   GGUF used by Vexel/llama.cpp. Returns "0 0 0 0" if the ollama server is
#   unavailable so the engine is skipped, never silently omitted.
###############################################################################
run_ollama_generate() {
    local model="${1:?Usage: run_ollama_generate <model_tag> <prompt> <max_tokens>}"
    local prompt="${2:?}"
    local max_tokens="${3:?}"
    local host="${OLLAMA_HOST:-http://localhost:11434}"

    if [[ "${OLLAMA_AVAILABLE:-0}" != "1" ]]; then
        echo "0 0 0 0"
        return 0
    fi

    local genfile psfile
    genfile=$(mktemp)
    psfile=$(mktemp)

    # raw:true bypasses the model's chat template (matches raw -p on the others).
    # temperature 0 = greedy; seed for reproducibility; num_predict caps gen length.
    local payload
    payload=$(jq -n --arg m "$model" --arg p "$prompt" --argjson n "$max_tokens" \
        '{model:$m,prompt:$p,stream:false,raw:true,options:{temperature:0,seed:0,num_predict:$n}}')
    curl -s "$host/api/generate" -d "$payload" > "$genfile" 2>/dev/null || true

    # /api/generate exposes no memory; query the resident model's VRAM footprint.
    curl -s "$host/api/ps" > "$psfile" 2>/dev/null || true

    parse_ollama_metrics "$genfile" "$psfile"
    rm -f "$genfile" "$psfile"
}

###############################################################################
# emit_jsonl <file> <json_line>
#   Append a single JSON line to the given file. Creates the file if needed.
###############################################################################
emit_jsonl() {
    local file="${1:?Usage: emit_jsonl <file> <json_line>}"
    local json_line="${2:?}"
    echo "$json_line" >> "$file"
}
