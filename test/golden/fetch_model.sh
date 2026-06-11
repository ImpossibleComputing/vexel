#!/usr/bin/env bash
#
# Download the TinyLlama-1.1B-Chat-v1.0 weights used as the golden-test fixture.
#
# The golden vectors in test/golden/data were captured from this exact model, so the
# Go golden tests (test/golden/golden_test.go) need the real weights to validate
# against. The weights are multi-GB and intentionally git-ignored (root .gitignore:
# models/, *.safetensors), so they are fetched on demand rather than committed.
#
# Files are placed in <repo>/models with the tiny_* names expected by both the Go
# loader (tiny_model.safetensors) and the Python regenerator's setup_local_model()
# in generate_golden.py (tiny_config.json, tiny_tokenizer.json).
#
# Usage:
#   test/golden/fetch_model.sh            # download into <repo>/models
#   MODEL_DIR=/custom/path test/golden/fetch_model.sh
#
set -euo pipefail

REPO_ID="TinyLlama/TinyLlama-1.1B-Chat-v1.0"
BASE_URL="https://huggingface.co/${REPO_ID}/resolve/main"

# Resolve <repo>/models relative to this script (test/golden/ -> ../../models).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODEL_DIR="${MODEL_DIR:-${SCRIPT_DIR}/../../models}"
mkdir -p "${MODEL_DIR}"

# Source filename on the Hub -> destination filename in MODEL_DIR.
declare -a FILES=(
	"model.safetensors:tiny_model.safetensors"
	"config.json:tiny_config.json"
	"tokenizer.json:tiny_tokenizer.json"
)

download() {
	local url="$1" dest="$2"
	if [[ -f "${dest}" ]]; then
		echo "✓ already present: ${dest}"
		return 0
	fi
	echo "↓ ${url}"
	if command -v curl >/dev/null 2>&1; then
		# Download to a temp file first so an interrupted transfer never leaves a
		# truncated fixture that would silently corrupt the golden comparison.
		curl -fL --retry 3 -o "${dest}.tmp" "${url}"
		mv "${dest}.tmp" "${dest}"
	elif command -v wget >/dev/null 2>&1; then
		wget -O "${dest}.tmp" "${url}"
		mv "${dest}.tmp" "${dest}"
	else
		echo "error: neither curl nor wget is available" >&2
		exit 1
	fi
}

# Prefer the Hugging Face CLI when available (handles auth, resume, and caching).
if command -v hf >/dev/null 2>&1; then
	echo "Using hf CLI to download ${REPO_ID} into ${MODEL_DIR}"
	for entry in "${FILES[@]}"; do
		src="${entry%%:*}"
		dest="${entry##*:}"
		hf download "${REPO_ID}" "${src}" --local-dir "${MODEL_DIR}"
		# hf preserves the original filename; rename to the tiny_* convention.
		if [[ -f "${MODEL_DIR}/${src}" && "${src}" != "${dest}" ]]; then
			mv "${MODEL_DIR}/${src}" "${MODEL_DIR}/${dest}"
		fi
	done
else
	echo "hf CLI not found; downloading directly from ${BASE_URL}"
	for entry in "${FILES[@]}"; do
		src="${entry%%:*}"
		dest="${entry##*:}"
		download "${BASE_URL}/${src}" "${MODEL_DIR}/${dest}"
	done
fi

echo
echo "Model fixture ready in ${MODEL_DIR}:"
ls -lh "${MODEL_DIR}"/tiny_*.safetensors "${MODEL_DIR}"/tiny_*.json 2>/dev/null || true
echo
echo "Run the golden tests with:  go test ./test/golden/"
