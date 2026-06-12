#!/usr/bin/env python3
"""report_compare_test.py — Unit tests for report_compare.py.

Pins the publishable-markdown rendering against the committed
benchmarks/results/example_result.json fixture (the canonical schema-1.0.0
record, kept conforming by result_schema_test.py). The report is the public
face of the trust contract, so the tests assert the honesty guarantees
directly: variance (p5–p95) is shown, the MLX weight-format caveat is inline,
hardware + engine versions are footered, and "Vexel is behind" is stated
plainly when the data says so.

Standalone runner, exit 0 = pass / 1 = fail (mirrors result_schema_test.py).
Run:  python3 benchmarks/lib/report_compare_test.py
"""

import copy
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from report_compare import render_report, SchemaVersionError  # noqa: E402

TESTS_RUN = 0
TESTS_FAILED = 0


def check(name: str, cond: bool, detail: str = "") -> None:
    global TESTS_RUN, TESTS_FAILED
    TESTS_RUN += 1
    if cond:
        print(f"  ok   {name}")
    else:
        print(f"  FAIL {name} {detail}")
        TESTS_FAILED += 1


FIXTURE = Path(__file__).resolve().parent.parent / "results" / "example_result.json"
RECORD = json.loads(FIXTURE.read_text())

# ---------------------------------------------------------------------------
# Render the committed fixture. In it (qwen2.5-7b-q4_k_m / standard_decode):
# decode medians are mlx 112.0 > vexel 101.5 > llama.cpp 96.0 > ollama 94.5,
# so Vexel is #2 of 4, (112.0 - 101.5) / 112.0 = 9.375% behind mlx.
# ---------------------------------------------------------------------------
report = render_report(RECORD, source="example_result.json")

print("== report identifies itself as generated (replaces hand-edited RESULTS.md) ==")
check("title present", "# Vexel Multi-Engine Benchmark Report" in report)
check("do-not-hand-edit banner", "Do not hand-edit" in report)
check("names its source file", "example_result.json" in report)

print("== date comes from the record (deterministic), not from now() ==")
check("created_utc date used", "2026-06-11" in report)

print("== Vexel's position table: all four engines, decode-sorted ==")
check("position section present", "Vexel's position" in report)
for engine in ["mlx", "vexel", "llama.cpp", "ollama"]:
    check(f"engine row present: {engine}", f"| {engine}" in report)
mlx_row = report.index("| mlx")
vexel_row = report.index("| vexel")
llama_row = report.index("| llama.cpp")
ollama_row = report.index("| ollama")
check("rows sorted by decode median desc (mlx, vexel, llama.cpp, ollama)",
      mlx_row < vexel_row < llama_row < ollama_row)

print("== variance is first-class: median with p5–p95 range shown ==")
check("vexel decode median shown", "101.5" in report)
check("vexel decode p5–p95 range shown", "98.8–104.2" in report)
check("mlx decode median shown", "112.0" in report)
check("mlx decode p5–p95 range shown", "108.0–116.0" in report)

print("== position stated plainly when Vexel is behind ==")
check("rank stated", "#2 of 4" in report)
check("gap leader named", "behind mlx" in report)
check("gap quantified (9.375% -> 9.4%)", "9.4%" in report)

print("== MLX weight-format caveat is inline, not buried ==")
check("mlx row carries a caveat marker", "mlx †" in report or "mlx†" in report)
check("caveat text from record surfaced", "NOT the identical GGUF" in report)

print("== hardware + versions footer ==")
check("chip in footer", "Apple M4 Max" in report)
check("macOS in footer", "15.5" in report)
check("vexel version in footer", "c30d2b6" in report)
check("llama.cpp version in footer", "8140 (a045fa8)" in report)
check("ollama version in footer", "0.13.5" in report)
check("mlx_lm version in footer", "0.30.7" in report)

print("== methodology surfaced (runs / warmup / aggregation contract) ==")
check("measured runs stated", "**measured_runs:** 10" in report)
check("aggregation note stated", "no best-of-N" in report)

print("== Vexel leading is reported as leading (not hardcoded 'behind') ==")
lead = copy.deepcopy(RECORD)
for entry in lead["entries"]:
    if entry["engine"] == "vexel":
        for field in ["min", "max", "mean", "median", "p5", "p95"]:
            entry["metrics"]["decode_tok_s"][field] = (
                entry["metrics"]["decode_tok_s"][field] + 100.0)
        entry["metrics"]["decode_tok_s"]["samples"] = [
            s + 100.0 for s in entry["metrics"]["decode_tok_s"]["samples"]]
lead_report = render_report(lead, source="lead.json")
check("rank #1 stated", "#1 of 4" in lead_report)
check("ahead-of language used", "ahead of" in lead_report)
check("no 'behind' claim when leading", "behind" not in lead_report.split("Vexel's position")[1].split("†")[0])

print("== engine with no data renders honestly as '—', never a fake 0 ==")
gap = copy.deepcopy(RECORD)
for entry in gap["entries"]:
    if entry["engine"] == "ollama":
        entry["measured_n"] = 0
        for metric in entry["metrics"].values():
            for field in ["min", "max", "mean", "median", "p5", "p95", "stddev"]:
                metric[field] = None
            metric["n"] = 0
            metric["samples"] = []
gap_report = render_report(gap, source="gap.json")
check("no-data engine still listed", "| ollama" in gap_report)
check("no-data cells render as em-dash", "—" in gap_report)
check("rank excludes engines without data", "#2 of 3" in gap_report)

print("== Vexel missing entirely is reported, not silently dropped ==")
novex = copy.deepcopy(RECORD)
novex["entries"] = [e for e in novex["entries"] if e["engine"] != "vexel"]
novex_report = render_report(novex, source="novex.json")
check("absence stated plainly", "Vexel was not measured" in novex_report)

print("== unknown schema major version is refused ==")
alien = copy.deepcopy(RECORD)
alien["schema_version"] = "2.0.0"
try:
    render_report(alien, source="alien.json")
    check("raises SchemaVersionError", False, "(no exception raised)")
except SchemaVersionError:
    check("raises SchemaVersionError", True)

print()
if TESTS_FAILED == 0:
    print(f"PASS: {TESTS_RUN}/{TESTS_RUN} report_compare assertions passed")
    sys.exit(0)
else:
    print(f"FAIL: {TESTS_FAILED}/{TESTS_RUN} report_compare assertions failed")
    sys.exit(1)
