#!/usr/bin/env python3
"""regression_guard.py — CI guard: fail when Vexel's decode throughput regresses.

The local CI regression-guard mode from the design spec
(docs/superpowers/specs/2026-06-11-vexel-benchmark-harness-design.md §3.5):
compare a fresh result record (schema 1.0.0, as produced by bench_compare.sh)
against a stored baseline record and FAIL if Vexel's median decode tok/s
regressed by more than a configurable threshold (default 5%) in any
(model, scenario) cell. This protects against silent perf regressions without
requiring any hosted dashboard.

Guard contract (unit-tested in regression_guard_test.py):
  - Gates on **Vexel's own** median decode_tok_s only. Other engines' numbers
    are context, not gates — MLX getting faster is not a Vexel CI failure.
  - Median, not best-of-N: the same trust contract as the rest of the harness.
  - A baselined Vexel cell that is missing (or has no data) in the current
    record FAILS the guard — losing the measurement must be loud, or a broken
    bench run would "pass" by producing nothing.
  - A new cell with no baseline is reported but never fails the run.
  - A drop of exactly the threshold passes; the guard fails only when the
    regression EXCEEDS it.
  - Refuses records whose schema major version it doesn't know.

Usage:
    python3 lib/regression_guard.py <current.json> [--baseline PATH] [--threshold PCT]

Default baseline: benchmarks/results/baseline.json (promote a trusted run with:
cp results/<stamp>/compare.json results/baseline.json). Exit codes: 0 = pass,
1 = regression (or baselined cell lost), 2 = usage/validation error.
"""

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from result_schema import SCHEMA_VERSION, validate_record  # noqa: E402

DEFAULT_THRESHOLD_PCT = 5.0
DEFAULT_BASELINE = Path(__file__).resolve().parent.parent / "results" / "baseline.json"

# The guard watches the subject under test on the headline metric only.
GUARDED_ENGINE = "vexel"
GUARDED_METRIC = "decode_tok_s"


class SchemaVersionError(ValueError):
    """Raised when a record's schema major version is unknown to this code."""


def _check_schema_version(record: dict, label: str) -> None:
    found = str(record.get("schema_version", "<missing>"))
    if found.split(".")[0] != SCHEMA_VERSION.split(".")[0]:
        raise SchemaVersionError(
            f"{label}: unsupported schema_version {found!r} (this guard "
            f"understands major version {SCHEMA_VERSION.split('.')[0]}.x — "
            f"refusing to compare records it might misread)")


def _guarded_medians(record: dict) -> dict:
    """{(model, scenario): median decode tok/s or None} for the guarded engine."""
    cells = {}
    for entry in record.get("entries", []):
        if entry.get("engine") != GUARDED_ENGINE:
            continue
        median = entry.get("metrics", {}).get(GUARDED_METRIC, {}).get("median")
        cells[(entry["model"], entry["scenario"])] = median
    return cells


def compare_to_baseline(baseline: dict, current: dict,
                        threshold_pct: float = DEFAULT_THRESHOLD_PCT) -> dict:
    """Compare current vs baseline Vexel decode medians, cell by cell.

    Returns {"ok": bool, "threshold_pct": float, "cells": [...]} where each
    cell carries model/scenario, both medians, delta_pct (negative = slower),
    and flags: regressed, missing (baselined cell lost), new (no baseline).
    """
    _check_schema_version(baseline, "baseline")
    _check_schema_version(current, "current")

    base_cells = _guarded_medians(baseline)
    curr_cells = _guarded_medians(current)

    ok = True
    cells = []
    for key, base_median in base_cells.items():
        model, scenario = key
        curr_median = curr_cells.get(key)
        cell = {"model": model, "scenario": scenario,
                "baseline_median": base_median, "current_median": curr_median}

        if base_median is None:
            # Baseline recorded the cell but holds no data — nothing to gate
            # against; surface it rather than inventing a comparison.
            cell.update(delta_pct=None, regressed=False, no_baseline_data=True)
        elif curr_median is None:
            cell.update(delta_pct=None, regressed=True, missing=True)
            ok = False
        else:
            delta_pct = (curr_median - base_median) / base_median * 100.0
            # Gate on the floor value itself, not the rounded percentage:
            # "exceeds the threshold" means falling BELOW baseline*(1-t/100).
            floor = base_median * (1.0 - threshold_pct / 100.0)
            regressed = curr_median < floor
            cell.update(delta_pct=delta_pct, regressed=regressed)
            ok = ok and not regressed
        cells.append(cell)

    for key, curr_median in curr_cells.items():
        if key not in base_cells:
            cells.append({"model": key[0], "scenario": key[1],
                          "baseline_median": None, "current_median": curr_median,
                          "delta_pct": None, "regressed": False, "new": True})

    return {"ok": ok, "threshold_pct": threshold_pct, "cells": cells}


def _fmt(value, suffix="") -> str:
    return "—" if value is None else f"{value:.1f}{suffix}"


def _print_verdict(result: dict) -> None:
    print(f"Regression guard: {GUARDED_ENGINE} median {GUARDED_METRIC}, "
          f"threshold {result['threshold_pct']:.1f}%")
    for cell in result["cells"]:
        if cell.get("missing"):
            status = "FAIL (baselined cell missing from current run)"
        elif cell.get("new"):
            status = "new (no baseline — not gated)"
        elif cell.get("no_baseline_data"):
            status = "skipped (baseline has no data)"
        elif cell["regressed"]:
            status = "FAIL (regression exceeds threshold)"
        else:
            status = "ok"
        print(f"  {cell['model']} / {cell['scenario']}: "
              f"{_fmt(cell['baseline_median'])} -> {_fmt(cell['current_median'])} tok/s "
              f"({_fmt(cell['delta_pct'], '%')}) ... {status}")
    if not result["cells"]:
        print(f"  (no {GUARDED_ENGINE} cells found in baseline or current)")
    print("VERDICT: " + ("PASS" if result["ok"] else "FAIL — Vexel decode regressed"))


def _load_record(path: Path, label: str) -> dict:
    if not path.exists():
        print(f"error: {label} not found: {path}", file=sys.stderr)
        if label == "baseline":
            print("hint: promote a trusted run with "
                  "`cp benchmarks/results/<stamp>/compare.json "
                  "benchmarks/results/baseline.json`", file=sys.stderr)
        raise FileNotFoundError(path)
    record = json.loads(path.read_text())
    errors = validate_record(record)
    if errors:
        print(f"error: {label} {path} fails schema validation:", file=sys.stderr)
        for err in errors:
            print(f"  - {err}", file=sys.stderr)
        raise ValueError(f"invalid {label}")
    return record


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("current", help="fresh result JSON to check")
    ap.add_argument("--baseline", default=str(DEFAULT_BASELINE),
                    help=f"stored baseline result JSON (default: {DEFAULT_BASELINE})")
    ap.add_argument("--threshold", type=float, default=DEFAULT_THRESHOLD_PCT,
                    help="max tolerated median decode regression in percent "
                         f"(default: {DEFAULT_THRESHOLD_PCT})")
    args = ap.parse_args(argv)

    try:
        baseline = _load_record(Path(args.baseline), "baseline")
        current = _load_record(Path(args.current), "current")
        result = compare_to_baseline(baseline, current, threshold_pct=args.threshold)
    except (FileNotFoundError, ValueError) as exc:
        # SchemaVersionError is a ValueError: both are usage/validation errors.
        if isinstance(exc, SchemaVersionError):
            print(f"error: {exc}", file=sys.stderr)
        return 2

    _print_verdict(result)
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
