#!/usr/bin/env python3
"""metadata.py — Auto-capture engine versions + reference hardware.

"Pinned engine versions" and "one documented reference machine" are two of the
spec's trust requirements (3.4). Hand-editing VERSIONS.md is exactly the kind of
drift the harness must remove: this module captures versions and hardware
*automatically* into the result record so a published number is always tied to
the exact engine builds and machine that produced it.

Two layers, deliberately separated for testability:
  - Pure PARSERS (parse_*): command-output text -> value. Unit-tested against
    captured real output in metadata_test.py (banner/format drift on a tool
    upgrade fails loudly instead of recording silent nulls).
  - Impure CAPTURE (capture_*): shell out to the live machine and feed the
    parsers. Each tool is optional and degrades to a clearly-labelled
    "not available" string rather than crashing — a missing engine is reported,
    never silently omitted (spec 6).

Run as a script to print captured metadata as JSON (smoke check):
    python3 benchmarks/lib/metadata.py
"""

import json
import re
import shutil
import subprocess
from pathlib import Path
from typing import Optional

UNAVAILABLE = "not available"


# ---------------------------------------------------------------------------
# Pure parsers (unit-tested)
# ---------------------------------------------------------------------------
def parse_ollama_version(text: str) -> Optional[str]:
    """From `ollama --version`: 'ollama version is X' or 'client version is X'."""
    m = re.search(r"version is\s+(\S+)", text)
    return m.group(1) if m else None


def parse_llama_version(text: str) -> Optional[str]:
    """From `llama-cli --version`: 'version: N (hash)' or 'build: N (hash)'."""
    m = re.search(r"(?:version|build):\s*(\d+)\s*\(([0-9a-fA-F]+)\)", text)
    return f"{m.group(1)} ({m.group(2)})" if m else None


def parse_pip_show_version(text: str) -> Optional[str]:
    """From `pip show <pkg>`: the 'Version: X' line."""
    m = re.search(r"^Version:\s*(\S+)", text, re.MULTILINE)
    return m.group(1) if m else None


def parse_macos_version(text: str) -> Optional[str]:
    """From `sw_vers`: the 'ProductVersion:\tX' value."""
    m = re.search(r"ProductVersion:\s*(\S+)", text)
    return m.group(1) if m else None


def parse_gpu_cores(text: str) -> Optional[int]:
    """From `system_profiler SPDisplaysDataType`: 'Total Number of Cores: N'."""
    m = re.search(r"Total Number of Cores:\s*(\d+)", text)
    return int(m.group(1)) if m else None


def parse_metal_support(text: str) -> Optional[str]:
    """From `system_profiler SPDisplaysDataType`: 'Metal Support: Metal 3'."""
    m = re.search(r"Metal(?:\s+Family)?\s+Support:\s*(.+)", text)
    return m.group(1).strip() if m else None


# ---------------------------------------------------------------------------
# Impure capture (shell out; each piece degrades gracefully)
# ---------------------------------------------------------------------------
def _run(cmd: list[str]) -> str:
    """Run a command, returning combined stdout+stderr text; '' on any failure."""
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=20)
        return (proc.stdout or "") + (proc.stderr or "")
    except (OSError, subprocess.SubprocessError):
        return ""


def _repo_root() -> Path:
    # benchmarks/lib/metadata.py -> repo root is two parents up from benchmarks/.
    return Path(__file__).resolve().parent.parent.parent


def capture_vexel_commit() -> str:
    """Vexel version = the git commit it was built from (short hash, +'-dirty')."""
    root = _repo_root()
    sha = _run(["git", "-C", str(root), "rev-parse", "--short", "HEAD"]).strip()
    if not sha:
        return UNAVAILABLE
    dirty = _run(["git", "-C", str(root), "status", "--porcelain"]).strip()
    return f"{sha}-dirty" if dirty else sha


def capture_llama_version() -> str:
    for binary in ("llama-cli", "llama-completion", "llama-server"):
        if shutil.which(binary):
            parsed = parse_llama_version(_run([binary, "--version"]))
            if parsed:
                return parsed
    return UNAVAILABLE


def capture_ollama_version() -> str:
    if not shutil.which("ollama"):
        return UNAVAILABLE
    return parse_ollama_version(_run(["ollama", "--version"])) or UNAVAILABLE


def capture_mlx_lm_version() -> str:
    # Prefer importing the package (authoritative); fall back to pip metadata.
    out = _run(["python3", "-c", "import mlx_lm,sys; sys.stdout.write(mlx_lm.__version__)"]).strip()
    if out and "Traceback" not in out and "Error" not in out:
        return out
    parsed = parse_pip_show_version(_run(["python3", "-m", "pip", "show", "mlx-lm"]))
    return parsed or UNAVAILABLE


def capture_engine_versions() -> dict:
    """Auto-capture all four engine versions; missing ones become 'not available'."""
    return {
        "vexel": capture_vexel_commit(),
        "llama.cpp": capture_llama_version(),
        "ollama": capture_ollama_version(),
        "mlx_lm": capture_mlx_lm_version(),
    }


def _sysctl(key: str) -> str:
    return _run(["sysctl", "-n", key]).strip()


def capture_hardware() -> dict:
    """Auto-capture the reference machine: chip, cores, unified memory, OS/Metal."""
    chip = _sysctl("machdep.cpu.brand_string") or UNAVAILABLE

    cpu_cores = None
    ncpu = _sysctl("hw.ncpu")
    if ncpu.isdigit():
        cpu_cores = int(ncpu)

    unified_memory_gb = None
    memsize = _sysctl("hw.memsize")
    if memsize.isdigit():
        unified_memory_gb = round(int(memsize) / (1024 ** 3))

    macos = parse_macos_version(_run(["sw_vers"]))
    displays = _run(["system_profiler", "SPDisplaysDataType"])
    gpu_cores = parse_gpu_cores(displays)
    metal = parse_metal_support(displays)

    return {
        "chip": chip,
        "cpu_cores": cpu_cores,
        "gpu_cores": gpu_cores,
        "unified_memory_gb": unified_memory_gb,
        "macos": macos or UNAVAILABLE,
        "metal": metal or UNAVAILABLE,
    }


if __name__ == "__main__":
    print(json.dumps(
        {"engine_versions": capture_engine_versions(), "hardware": capture_hardware()},
        indent=2,
    ))
