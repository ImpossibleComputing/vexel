#!/usr/bin/env python3
"""regression_guard_test.py — Unit tests for regression_guard.py.

Pins the CI regression-guard threshold logic against the committed
benchmarks/results/example_result.json fixture used as the stored baseline.
The guard's contract: fail when Vexel's median decode tok/s regresses more
than a configurable threshold (default 5%) vs the baseline, fail when a
baselined Vexel cell silently disappears, and never fail for noise inside
the threshold or for improvements.

Standalone runner, exit 0 = pass / 1 = fail (mirrors result_schema_test.py).
Run:  python3 benchmarks/lib/regression_guard_test.py
"""

import copy
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from regression_guard import (  # noqa: E402
    DEFAULT_THRESHOLD_PCT,
    SchemaVersionError,
    compare_to_baseline,
)

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


def close(name: str, actual, expected, tol=1e-6) -> None:
    check(name, actual is not None and abs(actual - expected) <= tol,
          f"(got {actual}, expected ~{expected})")


FIXTURE = Path(__file__).resolve().parent.parent / "results" / "example_result.json"
BASELINE = json.loads(FIXTURE.read_text())
# Baseline vexel decode median for qwen2.5-7b-q4_k_m / standard_decode: 101.5


def with_vexel_decode_scaled(record: dict, factor: float) -> dict:
    """Copy of `record` with every vexel decode_tok_s statistic scaled."""
    scaled = copy.deepcopy(record)
    for entry in scaled["entries"]:
        if entry["engine"] != "vexel":
            continue
        dist = entry["metrics"]["decode_tok_s"]
        for field in ["min", "max", "mean", "median", "p5", "p95", "stddev"]:
            if dist[field] is not None:
                dist[field] *= factor
        dist["samples"] = [s * factor for s in dist["samples"]]
    return scaled


print("== default threshold is the spec'd 5% ==")
check("DEFAULT_THRESHOLD_PCT == 5.0", DEFAULT_THRESHOLD_PCT == 5.0)

print("== identical current vs baseline passes ==")
result = compare_to_baseline(BASELINE, copy.deepcopy(BASELINE))
check("passes", result["ok"] is True)
check("one vexel cell compared", len(result["cells"]) == 1)
cell = result["cells"][0]
check("cell identifies model", cell["model"] == "qwen2.5-7b-q4_k_m")
check("cell identifies scenario", cell["scenario"] == "standard_decode")
close("baseline median recorded", cell["baseline_median"], 101.5)
close("current median recorded", cell["current_median"], 101.5)
close("delta is 0%", cell["delta_pct"], 0.0)
check("not flagged", cell["regressed"] is False)

print("== a 10% drop fails at the default 5% threshold ==")
result = compare_to_baseline(BASELINE, with_vexel_decode_scaled(BASELINE, 0.90))
check("fails", result["ok"] is False)
cell = result["cells"][0]
check("cell flagged", cell["regressed"] is True)
close("delta_pct == -10", cell["delta_pct"], -10.0)

print("== a 3% drop is inside the default 5% threshold: noise, not regression ==")
result = compare_to_baseline(BASELINE, with_vexel_decode_scaled(BASELINE, 0.97))
check("passes", result["ok"] is True)
close("delta_pct == -3", result["cells"][0]["delta_pct"], -3.0)

print("== threshold is configurable: the same 3% drop fails at 2% ==")
result = compare_to_baseline(BASELINE, with_vexel_decode_scaled(BASELINE, 0.97),
                             threshold_pct=2.0)
check("fails at 2%", result["ok"] is False)

print("== exactly at threshold passes (fails only when regression EXCEEDS it) ==")
result = compare_to_baseline(BASELINE, with_vexel_decode_scaled(BASELINE, 0.95))
check("a drop of exactly 5.0% passes", result["ok"] is True)

print("== an improvement passes, with positive delta ==")
result = compare_to_baseline(BASELINE, with_vexel_decode_scaled(BASELINE, 1.10))
check("passes", result["ok"] is True)
close("delta_pct == +10", result["cells"][0]["delta_pct"], 10.0)

print("== baselined vexel cell missing from current fails (no silent skip) ==")
gone = copy.deepcopy(BASELINE)
gone["entries"] = [e for e in gone["entries"] if e["engine"] != "vexel"]
result = compare_to_baseline(BASELINE, gone)
check("fails", result["ok"] is False)
check("missing cell reported", any(c.get("missing") for c in result["cells"]))

print("== vexel cell with no data (measured_n 0 / null median) fails ==")
hollow = copy.deepcopy(BASELINE)
for entry in hollow["entries"]:
    if entry["engine"] == "vexel":
        entry["measured_n"] = 0
        for metric in entry["metrics"].values():
            for field in ["min", "max", "mean", "median", "p5", "p95", "stddev"]:
                metric[field] = None
            metric["n"] = 0
            metric["samples"] = []
result = compare_to_baseline(BASELINE, hollow)
check("fails", result["ok"] is False)

print("== a NEW vexel cell (not in baseline) is reported but never fails the run ==")
grown = copy.deepcopy(BASELINE)
extra = copy.deepcopy(
    [e for e in BASELINE["entries"] if e["engine"] == "vexel"][0])
extra["model"] = "llama-3.1-8b-q4_k_m"
grown["entries"].append(extra)
result = compare_to_baseline(BASELINE, grown)
check("passes", result["ok"] is True)
check("new cell visible in results", any(c.get("new") for c in result["cells"]))

print("== non-vexel engines never gate the run (guard watches Vexel only) ==")
slow_mlx = copy.deepcopy(BASELINE)
for entry in slow_mlx["entries"]:
    if entry["engine"] == "mlx":
        dist = entry["metrics"]["decode_tok_s"]
        for field in ["min", "max", "mean", "median", "p5", "p95"]:
            dist[field] *= 0.5
        dist["samples"] = [s * 0.5 for s in dist["samples"]]
result = compare_to_baseline(BASELINE, slow_mlx)
check("mlx halving does not fail the guard", result["ok"] is True)

print("== unknown schema major version is refused ==")
alien = copy.deepcopy(BASELINE)
alien["schema_version"] = "2.0.0"
try:
    compare_to_baseline(BASELINE, alien)
    check("raises SchemaVersionError", False, "(no exception raised)")
except SchemaVersionError:
    check("raises SchemaVersionError", True)

print()
if TESTS_FAILED == 0:
    print(f"PASS: {TESTS_RUN}/{TESTS_RUN} regression_guard assertions passed")
    sys.exit(0)
else:
    print(f"FAIL: {TESTS_FAILED}/{TESTS_RUN} regression_guard assertions failed")
    sys.exit(1)
