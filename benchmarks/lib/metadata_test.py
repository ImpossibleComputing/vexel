#!/usr/bin/env python3
"""metadata_test.py — Unit tests for metadata.py version/hardware PARSERS.

The capture functions in metadata.py shell out to the live machine (git, sysctl,
sw_vers, system_profiler, ollama, llama-cli, pip) and so can't be unit-tested
deterministically. But the PARSERS that turn each command's text into a value are
pure — and version/banner drift on a tool upgrade is a real silent-failure risk
(a "reproducible" report that quietly records null versions). So we pin every
parser against CAPTURED real-tool output here, exactly as parse_test.sh does for
the metric parsers.

Standalone runner, exit 0 = pass / 1 = fail.
Run:  python3 benchmarks/lib/metadata_test.py
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from metadata import (  # noqa: E402
    parse_gpu_cores,
    parse_llama_version,
    parse_macos_version,
    parse_metal_support,
    parse_ollama_version,
    parse_pip_show_version,
)

TESTS_RUN = 0
TESTS_FAILED = 0


def eq(name, actual, expected):
    global TESTS_RUN, TESTS_FAILED
    TESTS_RUN += 1
    if actual == expected:
        print(f"  ok   {name} (got {actual!r})")
    else:
        print(f"  FAIL {name} (got {actual!r}, expected {expected!r})")
        TESTS_FAILED += 1


print("== ollama --version (server-up and server-down banners both parse) ==")
eq("ollama normal banner", parse_ollama_version("ollama version is 0.13.5"), "0.13.5")
eq("ollama server-down banner",
   parse_ollama_version(
       "Warning: could not connect to a running Ollama instance\n"
       "Warning: client version is 0.13.5"),
   "0.13.5")
eq("ollama unparseable -> None", parse_ollama_version("totally unrelated"), None)

print("== llama-cli --version (newer 'version:' and older 'build:' both parse) ==")
eq("llama newer banner",
   parse_llama_version("version: 8140 (a045fa8)\nbuilt with Apple clang 16.0"),
   "8140 (a045fa8)")
eq("llama older banner",
   parse_llama_version("build: 4589 (deadbee) with cc (GCC)"),
   "4589 (deadbee)")
eq("llama unparseable -> None", parse_llama_version("no version here"), None)

print("== pip show mlx-lm ==")
eq("mlx-lm version",
   parse_pip_show_version(
       "Name: mlx-lm\nVersion: 0.30.7\nSummary: ...\nLocation: /x/y"),
   "0.30.7")
eq("pip show no version -> None", parse_pip_show_version("Name: mlx-lm"), None)

print("== sw_vers (macOS version) ==")
eq("macOS version",
   parse_macos_version(
       "ProductName:\tmacOS\nProductVersion:\t15.5\nBuildVersion:\t24F74"),
   "15.5")

print("== system_profiler SPDisplaysDataType (GPU cores + Metal) ==")
SPDISPLAYS = (
    "Graphics/Displays:\n\n"
    "    Apple M4 Max:\n\n"
    "      Chipset Model: Apple M4 Max\n"
    "      Type: GPU\n"
    "      Bus: Built-In\n"
    "      Total Number of Cores: 40\n"
    "      Vendor: Apple (0x106b)\n"
    "      Metal Support: Metal 3\n"
)
eq("gpu cores", parse_gpu_cores(SPDISPLAYS), 40)
eq("metal support", parse_metal_support(SPDISPLAYS), "Metal 3")
eq("gpu cores absent -> None", parse_gpu_cores("no gpu info"), None)

print()
if TESTS_FAILED == 0:
    print(f"PASS: {TESTS_RUN}/{TESTS_RUN} metadata parser assertions passed")
    sys.exit(0)
else:
    print(f"FAIL: {TESTS_FAILED}/{TESTS_RUN} metadata parser assertions failed")
    sys.exit(1)
