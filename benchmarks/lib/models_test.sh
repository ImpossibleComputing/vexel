#!/usr/bin/env bash
# models_test.sh — Validate the standard model matrix registry (ov-5j6.3).
#
# Deterministic, network-free structural checks on model_matrix(): the matrix is
# the single source of truth for the benchmark grid, so a malformed row (missing
# field, bad sha256, duplicate key, no smoke model) would silently corrupt every
# downstream run. These tests catch that drift without touching the network.
#
# Run:  bash benchmarks/lib/models_test.sh   (exit 0 = pass, 1 = fail)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/models.sh"
# models.sh sets `set -euo pipefail`; this test deliberately exercises failure
# paths (e.g. unknown-key lookups return non-zero), so disable -e here.
set +e

FAIL=0
check() {  # <description> <condition-already-evaluated:0/1>
    if [[ "$2" == "0" ]]; then
        echo "  ok: $1"
    else
        echo "  FAIL: $1"
        FAIL=1
    fi
}

echo "=== model matrix: structure ==="

# Every record has exactly 8 pipe-delimited fields.
bad_arity=$(model_matrix | awk -F'|' 'NF != 8 { print NR": "NF" fields" }')
check "every row has 8 fields" "$([[ -z "$bad_arity" ]] && echo 0 || echo 1)"
[[ -n "$bad_arity" ]] && echo "    offending rows: $bad_arity"

# Keys are unique and non-empty.
n_keys=$(model_keys | grep -c .)
n_uniq=$(model_keys | sort -u | grep -c .)
check "keys are unique ($n_keys total, $n_uniq unique)" \
    "$([[ "$n_keys" == "$n_uniq" && "$n_keys" -gt 0 ]] && echo 0 || echo 1)"

# At least one smoke-tier model exists (the --smoke path depends on it).
n_smoke=$(smoke_keys | grep -c .)
check "at least one smoke-tier model ($n_smoke found)" \
    "$([[ "$n_smoke" -ge 1 ]] && echo 0 || echo 1)"

# Qwen-0.5b is the designated smoke model.
check "qwen-0.5b is a smoke model" \
    "$(smoke_keys | grep -qx 'qwen-0.5b' && echo 0 || echo 1)"

echo "=== model matrix: per-field validity ==="

# Each field is non-empty, sha256 is 64 hex chars, URLs look like https, and the
# mlx_repo is an org/name slug.
field_errs=""
while IFS='|' read -r key gguf_url gguf_file sha tok_url ollama_tag mlx_repo tier; do
    [[ -n "$key" ]]        || field_errs+="empty key; "
    [[ "$gguf_url" == https://* ]] || field_errs+="$key: gguf_url not https; "
    [[ -n "$gguf_file" && "$gguf_file" == *.gguf ]] || field_errs+="$key: gguf_file not *.gguf; "
    [[ "$sha" =~ ^[0-9a-f]{64}$ ]] || field_errs+="$key: sha256 not 64-hex; "
    [[ "$tok_url" == https://*tokenizer.json ]] || field_errs+="$key: tokenizer_url bad; "
    [[ -n "$ollama_tag" && "$ollama_tag" == *:* ]] || field_errs+="$key: ollama_tag missing :tag; "
    [[ "$mlx_repo" == */* ]] || field_errs+="$key: mlx_repo not org/name; "
    [[ "$tier" == "smoke" || "$tier" == "std" ]] || field_errs+="$key: tier not smoke/std; "
done < <(model_matrix)
check "all fields well-formed" "$([[ -z "$field_errs" ]] && echo 0 || echo 1)"
[[ -n "$field_errs" ]] && echo "    $field_errs"

echo "=== model matrix: accessors ==="

# Spot-check accessors resolve a known key and reject an unknown one.
check "model_ollama_tag qwen-0.5b == qwen2.5:0.5b" \
    "$([[ "$(model_ollama_tag qwen-0.5b)" == "qwen2.5:0.5b" ]] && echo 0 || echo 1)"
check "model_mlx_repo llama-8b is mlx-community/*" \
    "$([[ "$(model_mlx_repo llama-8b)" == mlx-community/* ]] && echo 0 || echo 1)"
model_field "no-such-model" "$MM_GGUF_URL" >/dev/null 2>&1
check "unknown key returns non-zero" \
    "$([[ "$?" -ne 0 ]] && echo 0 || echo 1)"

# The four spec-required additions are all present.
for required in qwen-0.5b qwen-7b llama-8b gemma-2-2b phi-3.5-mini; do
    check "matrix contains '$required'" \
        "$(model_keys | grep -qx "$required" && echo 0 || echo 1)"
done

if [[ "$FAIL" -eq 0 ]]; then
    echo "MODEL MATRIX TESTS PASSED"
    exit 0
else
    echo "MODEL MATRIX TESTS FAILED"
    exit 1
fi
