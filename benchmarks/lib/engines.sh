#!/usr/bin/env bash
# engines.sh — Engine binary discovery for the Vexel benchmark suite.
# Sourced by full_comparison.sh; not intended to be run standalone.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCH_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$BENCH_DIR/.." && pwd)"

# Relative path to llama.cpp build binaries
LLAMA_BIN_DIR="$REPO_ROOT/../llama.cpp/build/bin"

###############################################################################
# find_vexel — Build the Vexel binary if missing, then set VEXEL_BIN.
###############################################################################
find_vexel() {
    local vexel_path="$REPO_ROOT/vexel"

    if [[ -x "$vexel_path" ]]; then
        echo "[engines] vexel binary found: $vexel_path"
    else
        echo "[engines] vexel binary not found — building via 'make build'..."
        make -C "$REPO_ROOT" build
        if [[ ! -x "$vexel_path" ]]; then
            echo "ERROR: 'make build' did not produce $vexel_path" >&2
            exit 1
        fi
        echo "[engines] vexel binary built: $vexel_path"
    fi

    export VEXEL_BIN="$vexel_path"
}

###############################################################################
# find_llama — Locate llama.cpp binaries.
#   Checks PATH first, then the known build directory.
#   Sets: LLAMA_CLI, LLAMA_SERVER, LLAMA_SPECULATIVE
#   Prints "[missing]" and continues if a binary is not found.
###############################################################################
find_llama() {
    local binaries=("llama-completion" "llama-cli" "llama-server" "llama-speculative")
    local varnames=("LLAMA_COMPLETION" "LLAMA_CLI" "LLAMA_SERVER" "LLAMA_SPECULATIVE")

    for i in "${!binaries[@]}"; do
        local bin="${binaries[$i]}"
        local var="${varnames[$i]}"
        local found=""

        # Check PATH first
        if command -v "$bin" &>/dev/null; then
            found="$(command -v "$bin")"
        # Check llama.cpp build directory
        elif [[ -x "$LLAMA_BIN_DIR/$bin" ]]; then
            found="$LLAMA_BIN_DIR/$bin"
        fi

        if [[ -n "$found" ]]; then
            export "$var"="$found"
            echo "[engines] $bin found: $found"
        else
            export "$var"="[missing]"
            echo "[engines] $bin — [missing]"
        fi
    done
}

###############################################################################
# find_ollama — Locate the ollama CLI and confirm its server is reachable.
#   The `ollama` CLI is a thin client; the model runs in (and all timing/memory
#   metrics come from) the local HTTP API. We therefore require BOTH the binary
#   AND a reachable server.
#   Sets: OLLAMA_BIN, OLLAMA_AVAILABLE (1 = usable, 0 = skip)
#   Honors OLLAMA_HOST (default http://localhost:11434).
#   Degrades gracefully — reports the skip reason; never silently omits ollama.
###############################################################################
find_ollama() {
    local host="${OLLAMA_HOST:-http://localhost:11434}"

    if ! command -v ollama &>/dev/null; then
        export OLLAMA_BIN="[missing]"
        export OLLAMA_AVAILABLE=0
        echo "[engines] ollama: not available (binary not found) — will be SKIPPED, not silently omitted"
        return 0
    fi

    export OLLAMA_BIN="$(command -v ollama)"
    if curl -s -o /dev/null --max-time 3 "$host/api/version" 2>/dev/null; then
        export OLLAMA_AVAILABLE=1
        echo "[engines] ollama found: $OLLAMA_BIN (server up at $host)"
    else
        export OLLAMA_AVAILABLE=0
        echo "[engines] ollama: binary found ($OLLAMA_BIN) but server unreachable at $host — will be SKIPPED (start it with 'ollama serve')"
    fi
}

###############################################################################
# find_mlx — Locate the mlx_lm.generate entry point.
#   Sets: MLX_GENERATE (executable path) or "[missing]".
#   Degrades gracefully — reports the skip reason; never silently omits MLX.
#
#   ⚠️ MLX FORMAT CAVEAT (must be surfaced in every report):
#   MLX consumes its OWN weight format (mlx-community 4-bit), NOT GGUF. An
#   "apples-to-apples" MLX comparison therefore uses the SAME base model at an
#   EQUIVALENT quantization (e.g. 4-bit) — NOT the identical file that Vexel /
#   llama.cpp / ollama load. Numbers must be read with this caveat or they are
#   silently misleading.
###############################################################################
find_mlx() {
    if command -v mlx_lm.generate &>/dev/null; then
        export MLX_GENERATE="$(command -v mlx_lm.generate)"
        echo "[engines] mlx_lm.generate found: $MLX_GENERATE"
    else
        export MLX_GENERATE="[missing]"
        echo "[engines] MLX: not available (mlx_lm not installed) — will be SKIPPED, not silently omitted"
    fi
}

###############################################################################
# setup_engines — Discover all engine binaries.
###############################################################################
setup_engines() {
    echo "=== Setting up engines ==="
    find_vexel
    find_llama
    find_ollama
    find_mlx

    echo ""
    echo "[engines] VEXEL_BIN          = $VEXEL_BIN"
    echo "[engines] LLAMA_COMPLETION   = ${LLAMA_COMPLETION:-[missing]}"
    echo "[engines] LLAMA_CLI          = $LLAMA_CLI"
    echo "[engines] LLAMA_SERVER       = $LLAMA_SERVER"
    echo "[engines] LLAMA_SPECULATIVE  = $LLAMA_SPECULATIVE"
    echo "[engines] OLLAMA_BIN         = ${OLLAMA_BIN:-[missing]} (available=${OLLAMA_AVAILABLE:-0})"
    echo "[engines] MLX_GENERATE       = ${MLX_GENERATE:-[missing]}"
    echo ""
}
