#!/usr/bin/env python3
"""result_schema.py — The JSON result schema + aggregation for the harness.

This is the machine-readable contract for benchmarks/results/*.json. It defines
exactly one shape that the (later) report generator (ov-5j6.4) and the CI
regression guard consume, and it builds that shape from raw per-run measurements.

The schema is intentionally "distribution-first": every metric stores its full
summary (median/p5/p95/stddev/min/max/mean/n) AND the raw samples, so variance is
both shown and auditable — never reduced to a single "best of N" number (the
trust gap this epic exists to close). It also pins, per record:
  - schema_version       — so format drift is detectable, not silently misread.
  - engine_versions      — Vexel commit, llama.cpp build hash, ollama, mlx-lm
                           (auto-captured by metadata.py).
  - hardware             — chip / cores / unified memory / macOS+Metal
                           (auto-captured by metadata.py).
  - methodology          — warmup count, measured-run count, gen length, temp.
  - mlx_caveat           — the "MLX is 4-bit mlx-community weights, not the GGUF"
                           note, surfaced in the record so a reader can never
                           misread an MLX number as same-file apples-to-apples.

The pure aggregation/build/validate functions are unit-tested in
result_schema_test.py against known inputs (reusing the stats core).

See benchmarks/results/SCHEMA.md for the annotated human-readable schema and
benchmarks/results/example_result.json for a conforming example.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from stats import discard_warmup, summarize  # noqa: E402

# Bump when the on-disk JSON shape changes incompatibly. Consumers (report
# generator, CI guard) should refuse a record whose major version they don't know.
SCHEMA_VERSION = "1.0.0"

# The 4-metric contract established by the ov-5j6.1 ollama/MLX adapters.
# Order is the canonical reporting order.
METRICS = ["decode_tok_s", "prefill_tok_s", "ttft_ms", "peak_mem_mb"]

# Keys every per-metric distribution must carry (summarize() output + samples).
_DISTRIBUTION_KEYS = ["n", "min", "max", "mean", "median", "p5", "p95", "stddev", "samples"]


def summarize_runs(runs: list[dict], warmup: int = 0) -> dict:
    """Aggregate raw per-run metric dicts into per-metric distributions.

    `runs` is a list of dicts each carrying the 4 contract metric keys (extra
    keys ignored). The first `warmup` runs are DISCARDED (cold-start, ov-7ro)
    before aggregation — never averaged in. The remaining "measured" runs are
    summarized per metric via the stats core.

    Honesty note: values are aggregated exactly as recorded. We do NOT filter
    out zeros — per the 4-metric contract a missing value degrades to 0 and that
    must stay visible, not be silently dropped. An unavailable engine simply
    yields no run records (measured_n == 0), which surfaces as None statistics.

    Returns: {warmup_discarded, measured_n, metrics: {metric: {<distribution>}}}
    """
    measured = discard_warmup(runs, warmup)
    metrics = {}
    for metric in METRICS:
        samples = [float(r[metric]) for r in measured if r.get(metric) is not None]
        dist = summarize(samples)
        dist["samples"] = samples
        metrics[metric] = dist
    return {
        "warmup_discarded": max(warmup, 0),
        "measured_n": len(measured),
        "metrics": metrics,
    }


def build_engine_result(engine: str, model: str, scenario: str, runs: list[dict],
                        warmup: int = 0, gen_tokens: int = 0, notes: str = "") -> dict:
    """Build one result entry for a single (engine, model, scenario) cell."""
    agg = summarize_runs(runs, warmup=warmup)
    return {
        "engine": engine,
        "model": model,
        "scenario": scenario,
        "gen_tokens": gen_tokens,
        "notes": notes,
        "warmup_discarded": agg["warmup_discarded"],
        "measured_n": agg["measured_n"],
        "metrics": agg["metrics"],
    }


def group_and_build_entries(records: list[dict], warmup: int = 0) -> list[dict]:
    """Group raw per-run JSONL records into one entry per (engine, model, scenario).

    `records` are the flat per-run dicts the bench loops emit (engine, model,
    a scenario key — accepted as either 'scenario' or the existing 'mode' — plus
    the metric keys). Group insertion order is preserved so the report reads in
    the order runs were collected. Each group is folded into a schema entry,
    discarding `warmup` leading runs.
    """
    groups: dict = {}
    order: list = []
    for r in records:
        scenario = r.get("scenario") or r.get("mode") or "default"
        key = (r["engine"], r["model"], scenario)
        if key not in groups:
            groups[key] = []
            order.append(key)
        groups[key].append(r)

    entries = []
    for engine, model, scenario in order:
        runs = groups[(engine, model, scenario)]
        entries.append(build_engine_result(
            engine=engine, model=model, scenario=scenario, runs=runs,
            warmup=warmup, gen_tokens=runs[0].get("gen_tokens", 0),
            notes=runs[0].get("notes", ""),
        ))
    return entries


def build_result_record(created_utc: str, hardware: dict, engine_versions: dict,
                        methodology: dict, entries: list[dict],
                        mlx_caveat: str = "") -> dict:
    """Assemble the top-level result record from entries + auto-captured metadata."""
    return {
        "schema_version": SCHEMA_VERSION,
        "created_utc": created_utc,
        "hardware": hardware,
        "engine_versions": engine_versions,
        "methodology": methodology,
        "mlx_caveat": mlx_caveat,
        "entries": entries,
    }


def validate_record(record: dict) -> list[str]:
    """Lightweight schema validation (no jsonschema dependency).

    Returns a list of human-readable error strings; an empty list means valid.
    Checks required top-level keys, that each entry carries the contract metrics,
    and that each metric distribution has the full summary key set. This is the
    guardrail that makes a malformed result fail loudly rather than feed a
    silently-wrong published number downstream.
    """
    errors: list[str] = []
    required_top = ["schema_version", "created_utc", "hardware", "engine_versions",
                    "methodology", "entries"]
    for key in required_top:
        if key not in record:
            errors.append(f"missing top-level key: {key}")

    for i, entry in enumerate(record.get("entries", [])):
        for key in ["engine", "model", "scenario", "measured_n", "metrics"]:
            if key not in entry:
                errors.append(f"entries[{i}]: missing key: {key}")
        metrics = entry.get("metrics", {})
        for metric in METRICS:
            if metric not in metrics:
                errors.append(f"entries[{i}].metrics: missing metric: {metric}")
                continue
            for dk in _DISTRIBUTION_KEYS:
                if dk not in metrics[metric]:
                    errors.append(f"entries[{i}].metrics.{metric}: missing field: {dk}")
    return errors
