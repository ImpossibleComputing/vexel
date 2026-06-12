#!/usr/bin/env bash
# models.sh — Model download and discovery for the Vexel benchmark suite.
# Sourced by full_comparison.sh; not intended to be run standalone.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCH_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$BENCH_DIR/.." && pwd)"
MODELS_DIR="$BENCH_DIR/models"

# HuggingFace download URLs — model weights
URL_LLAMA_8B="https://huggingface.co/bartowski/Meta-Llama-3.1-8B-Instruct-GGUF/resolve/main/Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf"
URL_QWEN_05B="https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf"
URL_TINYLLAMA="https://huggingface.co/TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF/resolve/main/tinyllama-1.1b-chat-v1.0.Q4_0.gguf"

# HuggingFace download URLs — tokenizer.json (Vexel needs a separate tokenizer file)
URL_TOKENIZER_LLAMA_8B="https://huggingface.co/unsloth/Meta-Llama-3.1-8B-Instruct/resolve/main/tokenizer.json"
URL_TOKENIZER_QWEN_05B="https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct/resolve/main/tokenizer.json"
URL_TOKENIZER_TINYLLAMA="https://huggingface.co/TinyLlama/TinyLlama-1.1B-Chat-v1.0/resolve/main/tokenizer.json"

# Corresponding filenames
FILE_LLAMA_8B="Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf"
FILE_QWEN_05B="qwen2.5-0.5b-instruct-q4_k_m.gguf"
FILE_TINYLLAMA="tinyllama-1.1b-chat-v1.0.Q4_0.gguf"

# Subdirectories for each model (Vexel looks for tokenizer.json beside the model file)
DIR_LLAMA_8B="llama-8b"
DIR_QWEN_05B="qwen-0.5b"
DIR_TINYLLAMA="tinyllama"

# Possible symlink source directory (llama.cpp models)
LLAMA_MODELS_DIR="$REPO_ROOT/../llama.cpp/models"

###############################################################################
# ensure_models_gitignored — Abort if the models directory is not gitignored.
###############################################################################
ensure_models_gitignored() {
    # Use a relative path for check-ignore since absolute paths may not match .gitignore patterns
    local rel_path
    rel_path=$(python3 -c "import os; print(os.path.relpath('$MODELS_DIR', '$REPO_ROOT'))")
    if ! git -C "$REPO_ROOT" check-ignore -q "$rel_path/" 2>/dev/null; then
        echo "ERROR: $MODELS_DIR is not gitignored." >&2
        echo "Add 'benchmarks/models/' to .gitignore before running benchmarks." >&2
        exit 1
    fi
    echo "[models] models directory is gitignored — OK"
}

###############################################################################
# download_if_missing <subdir> <filename> <url>
#   1. If the file already exists in MODELS_DIR/<subdir>/, do nothing.
#   2. Try to symlink from ../llama.cpp/models/.
#   3. Fall back to downloading via curl.
###############################################################################
download_if_missing() {
    local subdir="$1"
    local filename="$2"
    local url="$3"
    local target_dir="$MODELS_DIR/$subdir"
    local target="$target_dir/$filename"

    mkdir -p "$target_dir"

    if [[ -f "$target" ]]; then
        echo "[models] $subdir/$filename — already present"
        return 0
    fi

    # Try symlink from llama.cpp models directory
    if [[ -f "$LLAMA_MODELS_DIR/$filename" ]]; then
        ln -s "$LLAMA_MODELS_DIR/$filename" "$target"
        echo "[models] $subdir/$filename — symlinked from llama.cpp/models/"
        return 0
    fi

    # Download via curl
    echo "[models] $subdir/$filename — downloading from HuggingFace..."
    curl -L --progress-bar -o "$target" "$url"
    echo "[models] $subdir/$filename — download complete"
}

###############################################################################
# download_tokenizer <subdir> <url>
#   Download tokenizer.json into the model subdirectory if not already present.
###############################################################################
download_tokenizer() {
    local subdir="$1"
    local url="$2"
    local target_dir="$MODELS_DIR/$subdir"
    local target="$target_dir/tokenizer.json"

    mkdir -p "$target_dir"

    if [[ -f "$target" ]]; then
        echo "[models] $subdir/tokenizer.json — already present"
        return 0
    fi

    # Try symlink from llama.cpp models directory (some setups keep tokenizers there)
    local llama_tok="$LLAMA_MODELS_DIR/$subdir/tokenizer.json"
    if [[ -f "$llama_tok" ]]; then
        ln -s "$llama_tok" "$target"
        echo "[models] $subdir/tokenizer.json — symlinked from llama.cpp/models/"
        return 0
    fi

    echo "[models] $subdir/tokenizer.json — downloading from HuggingFace..."
    curl -L --progress-bar -o "$target" "$url"
    echo "[models] $subdir/tokenizer.json — download complete"
}

###############################################################################
# setup_models — Ensure all benchmark models are available.
#   Sets: MODEL_LLAMA_8B, MODEL_QWEN_05B, MODEL_TINYLLAMA
###############################################################################
setup_models() {
    echo "=== Setting up models ==="
    ensure_models_gitignored

    # Download model weights into per-model subdirectories
    download_if_missing "$DIR_LLAMA_8B"   "$FILE_LLAMA_8B"  "$URL_LLAMA_8B"
    download_if_missing "$DIR_QWEN_05B"   "$FILE_QWEN_05B"  "$URL_QWEN_05B"
    download_if_missing "$DIR_TINYLLAMA"  "$FILE_TINYLLAMA" "$URL_TINYLLAMA"

    # Download tokenizer.json files (Vexel looks for tokenizer.json beside the GGUF)
    download_tokenizer "$DIR_LLAMA_8B"  "$URL_TOKENIZER_LLAMA_8B"
    download_tokenizer "$DIR_QWEN_05B"  "$URL_TOKENIZER_QWEN_05B"
    download_tokenizer "$DIR_TINYLLAMA" "$URL_TOKENIZER_TINYLLAMA"

    export MODEL_LLAMA_8B="$MODELS_DIR/$DIR_LLAMA_8B/$FILE_LLAMA_8B"
    export MODEL_QWEN_05B="$MODELS_DIR/$DIR_QWEN_05B/$FILE_QWEN_05B"
    export MODEL_TINYLLAMA="$MODELS_DIR/$DIR_TINYLLAMA/$FILE_TINYLLAMA"

    echo "[models] MODEL_LLAMA_8B  = $MODEL_LLAMA_8B"
    echo "[models] MODEL_QWEN_05B  = $MODEL_QWEN_05B"
    echo "[models] MODEL_TINYLLAMA = $MODEL_TINYLLAMA"
    echo ""
}

###############################################################################
# THE STANDARD MODEL MATRIX (ov-5j6.3)
#
# Single source of truth for the multi-engine benchmark grid. One record per
# line, pipe-delimited, with EIGHT fields:
#
#   key | gguf_url | gguf_file | gguf_sha256 | tokenizer_url | ollama_tag | mlx_repo | tier
#
#   key           short model id; also the on-disk subdir under benchmarks/models/.
#   gguf_url      HuggingFace resolve URL for the Q4_K_M GGUF (Vexel/llama.cpp).
#   gguf_file     local filename for that GGUF.
#   gguf_sha256   pinned content hash (== the HF `x-linked-etag` header, the
#                 canonical LFS content sha256 — NOT the redirected Xet CDN ETag,
#                 which is a content-defined-chunking hash). Verified after
#                 download so a corrupted/swapped weight fails loudly.
#   tokenizer_url tokenizer.json source (Vexel loads it beside the GGUF). Chosen
#                 from a NON-GATED mirror where the canonical repo is gated
#                 (e.g. gemma-2 uses unsloth's mirror).
#   ollama_tag    the SAME base model at an equivalent Q4_K_M quant in ollama.
#   mlx_repo      MLX-equivalent source: same base model at an EQUIVALENT 4-bit
#                 quant (mlx-community), NOT the identical GGUF file — see the MLX
#                 caveat in engines.sh:find_mlx. This is what makes MLX rows
#                 "same-model/equivalent-quant", never "same-file".
#   tier          smoke = part of the fast --smoke set (no 8B downloads);
#                 std   = full matrix only.
#
# Matched-quant contract: Vexel, llama.cpp and ollama all consume the SAME Q4_K_M
# GGUF lineage; MLX consumes its 4-bit equivalent. Keep these rows in lockstep.
###############################################################################
model_matrix() {
    cat <<'EOF'
qwen-0.5b|https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf|qwen2.5-0.5b-instruct-q4_k_m.gguf|74a4da8c9fdbcd15bd1f6d01d621410d31c6fc00986f5eb687824e7b93d7a9db|https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct/resolve/main/tokenizer.json|qwen2.5:0.5b|mlx-community/Qwen2.5-0.5B-Instruct-4bit|smoke
qwen-7b|https://huggingface.co/bartowski/Qwen2.5-7B-Instruct-GGUF/resolve/main/Qwen2.5-7B-Instruct-Q4_K_M.gguf|Qwen2.5-7B-Instruct-Q4_K_M.gguf|65b8fcd92af6b4fefa935c625d1ac27ea29dcb6ee14589c55a8f115ceaaa1423|https://huggingface.co/Qwen/Qwen2.5-7B-Instruct/resolve/main/tokenizer.json|qwen2.5:7b|mlx-community/Qwen2.5-7B-Instruct-4bit|std
llama-8b|https://huggingface.co/bartowski/Meta-Llama-3.1-8B-Instruct-GGUF/resolve/main/Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf|Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf|7b064f5842bf9532c91456deda288a1b672397a54fa729aa665952863033557c|https://huggingface.co/unsloth/Meta-Llama-3.1-8B-Instruct/resolve/main/tokenizer.json|llama3.1:8b|mlx-community/Meta-Llama-3.1-8B-Instruct-4bit|std
gemma-2-2b|https://huggingface.co/bartowski/gemma-2-2b-it-GGUF/resolve/main/gemma-2-2b-it-Q4_K_M.gguf|gemma-2-2b-it-Q4_K_M.gguf|e0aee85060f168f0f2d8473d7ea41ce2f3230c1bc1374847505ea599288a7787|https://huggingface.co/unsloth/gemma-2-2b-it/resolve/main/tokenizer.json|gemma2:2b|mlx-community/gemma-2-2b-it-4bit|std
phi-3.5-mini|https://huggingface.co/bartowski/Phi-3.5-mini-instruct-GGUF/resolve/main/Phi-3.5-mini-instruct-Q4_K_M.gguf|Phi-3.5-mini-instruct-Q4_K_M.gguf|e4165e3a71af97f1b4820da61079826d8752a2088e313af0c7d346796c38eff5|https://huggingface.co/microsoft/Phi-3.5-mini-instruct/resolve/main/tokenizer.json|phi3.5:3.8b|mlx-community/Phi-3.5-mini-instruct-4bit|std
EOF
}

# Field index constants for model_matrix records (1-based, pipe-delimited).
readonly MM_KEY=1 MM_GGUF_URL=2 MM_GGUF_FILE=3 MM_SHA256=4 \
         MM_TOKENIZER_URL=5 MM_OLLAMA_TAG=6 MM_MLX_REPO=7 MM_TIER=8

###############################################################################
# model_field <key> <field-index>
#   Print field <field-index> (use the MM_* constants) of the matrix record for
#   <key>. Returns non-zero if the key is unknown.
###############################################################################
model_field() {
    local key="${1:?Usage: model_field <key> <field-index>}"
    local idx="${2:?}"
    model_matrix | awk -F'|' -v k="$key" -v i="$idx" \
        '$1 == k { print $i; found = 1 } END { exit !found }'
}

# Convenience accessors (each: <key> -> value).
model_gguf_url()      { model_field "$1" "$MM_GGUF_URL"; }
model_gguf_file()     { model_field "$1" "$MM_GGUF_FILE"; }
model_sha256()        { model_field "$1" "$MM_SHA256"; }
model_tokenizer_url() { model_field "$1" "$MM_TOKENIZER_URL"; }
model_ollama_tag()    { model_field "$1" "$MM_OLLAMA_TAG"; }
model_mlx_repo()      { model_field "$1" "$MM_MLX_REPO"; }
model_gguf_path()     { echo "$MODELS_DIR/$1/$(model_gguf_file "$1")"; }

# model_keys / smoke_keys — list all matrix keys, or just the --smoke tier.
model_keys()  { model_matrix | awk -F'|' '{ print $1 }'; }
smoke_keys()  { model_matrix | awk -F'|' '$8 == "smoke" { print $1 }'; }

###############################################################################
# sha256_of <file> — print the file's sha256 (macOS shasum or GNU sha256sum).
###############################################################################
sha256_of() {
    local f="${1:?Usage: sha256_of <file>}"
    if command -v shasum &>/dev/null; then
        shasum -a 256 "$f" | awk '{print $1}'
    elif command -v sha256sum &>/dev/null; then
        sha256sum "$f" | awk '{print $1}'
    else
        echo "ERROR: no sha256 tool (shasum/sha256sum) found" >&2
        return 1
    fi
}

###############################################################################
# verify_sha256 <file> <expected>
#   Verify <file> matches <expected> sha256. A mismatch is FATAL (trust
#   contract: a swapped/corrupt weight must never silently feed a published
#   number) unless BENCH_ALLOW_SHA_MISMATCH=1, in which case it only warns.
#   An empty <expected> ("" / "-") skips verification with a notice.
###############################################################################
verify_sha256() {
    local file="${1:?Usage: verify_sha256 <file> <expected>}"
    local expected="${2:-}"

    if [[ -z "$expected" || "$expected" == "-" ]]; then
        echo "[models] $(basename "$file") — sha256 unpinned, skipping verification"
        return 0
    fi

    local actual
    actual=$(sha256_of "$file") || return 1
    if [[ "$actual" == "$expected" ]]; then
        echo "[models] $(basename "$file") — sha256 OK"
        return 0
    fi

    echo "[models] $(basename "$file") — sha256 MISMATCH" >&2
    echo "    expected: $expected" >&2
    echo "    actual:   $actual" >&2
    if [[ "${BENCH_ALLOW_SHA_MISMATCH:-0}" == "1" ]]; then
        echo "    (BENCH_ALLOW_SHA_MISMATCH=1 — continuing despite mismatch)" >&2
        return 0
    fi
    echo "    Refusing to benchmark an unverified weight. Set BENCH_ALLOW_SHA_MISMATCH=1 to override." >&2
    return 1
}

###############################################################################
# setup_matrix_model <key>
#   Ensure one matrix model is present on disk (GGUF + tokenizer.json), verify
#   its pinned sha256, and print the absolute GGUF path on stdout. Downloads
#   on demand so --smoke fetches ONLY the smoke-tier model(s), never the 8B set.
#   All progress goes to stderr so stdout is exactly the GGUF path (capturable).
###############################################################################
setup_matrix_model() {
    local key="${1:?Usage: setup_matrix_model <key>}"

    local gguf_url gguf_file sha tok_url
    gguf_url=$(model_gguf_url "$key")      || { echo "ERROR: unknown model key: $key" >&2; return 1; }
    gguf_file=$(model_gguf_file "$key")
    sha=$(model_sha256 "$key")
    tok_url=$(model_tokenizer_url "$key")

    # download_if_missing / download_tokenizer log to stdout; redirect to stderr
    # so this function's stdout stays a clean, capturable path.
    download_if_missing "$key" "$gguf_file" "$gguf_url"  1>&2
    download_tokenizer  "$key" "$tok_url"                1>&2

    local gguf_path="$MODELS_DIR/$key/$gguf_file"
    verify_sha256 "$gguf_path" "$sha" 1>&2 || return 1

    echo "$gguf_path"
}
