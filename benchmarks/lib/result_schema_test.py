#!/usr/bin/env python3
"""result_schema_test.py — Unit tests for result_schema.py.

Pins (a) the warmup-discard + per-metric aggregation pipeline and (b) the shape
of the JSON result record. The aggregation reuses the stats core (already pinned
in stats_test.py), so here we verify the wiring: warmup runs are dropped, each of
the 4 contract metrics is summarized, and a full record validates and round-trips
through JSON.

Standalone runner, exit 0 = pass / 1 = fail (mirrors parse_test.sh).
Run:  python3 benchmarks/lib/result_schema_test.py
"""

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from result_schema import (  # noqa: E402
    METRICS,
    SCHEMA_VERSION,
    build_engine_result,
    build_result_record,
    group_and_build_entries,
    summarize_runs,
    validate_record,
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


# ---------------------------------------------------------------------------
# 12 runs: first 2 are warmup (huge cold-start values), remaining 10 have
# decode_tok_s = 1..10 so we can reuse the hand-computed stats from stats_test.
# ---------------------------------------------------------------------------
RAW = [{"decode_tok_s": 1000.0, "prefill_tok_s": 9000.0, "ttft_ms": 50.0, "peak_mem_mb": 500.0},
       {"decode_tok_s": 2000.0, "prefill_tok_s": 9000.0, "ttft_ms": 40.0, "peak_mem_mb": 500.0}]
RAW += [{"decode_tok_s": float(v), "prefill_tok_s": float(v * 2),
         "ttft_ms": 30.0, "peak_mem_mb": 500.0} for v in range(1, 11)]

print("== summarize_runs: warmup discarded, each metric summarized ==")
agg = summarize_runs(RAW, warmup=2)
check("warmup_discarded recorded", agg["warmup_discarded"] == 2)
check("measured_n == 10 (12 - 2 warmup)", agg["measured_n"] == 10)
check("all 4 contract metrics present", sorted(agg["metrics"].keys()) == sorted(METRICS))
close("decode median == 5.5 (1..10)", agg["metrics"]["decode_tok_s"]["median"], 5.5)
close("decode p5 == 1.45", agg["metrics"]["decode_tok_s"]["p5"], 1.45)
close("decode p95 == 9.55", agg["metrics"]["decode_tok_s"]["p95"], 9.55)
close("decode stddev == 3.02765", agg["metrics"]["decode_tok_s"]["stddev"], 3.0276503541)
check("decode warmup value 2000 excluded (max==10 not 2000)",
      agg["metrics"]["decode_tok_s"]["max"] == 10.0)
close("prefill median == 11.0 (2..20 step 2)", agg["metrics"]["prefill_tok_s"]["median"], 11.0)
check("raw samples retained for decode (variance is auditable)",
      agg["metrics"]["decode_tok_s"]["samples"] == [float(v) for v in range(1, 11)])

print("== summarize_runs: 0 measured runs after warmup is honest, not a crash ==")
empty_agg = summarize_runs(RAW[:2], warmup=5)
check("measured_n == 0", empty_agg["measured_n"] == 0)
check("decode median is None (no data)", empty_agg["metrics"]["decode_tok_s"]["median"] is None)

print("== build_engine_result: one entry per (engine, model, scenario) ==")
entry = build_engine_result(
    engine="vexel", model="qwen-0.5b", scenario="standard_decode",
    runs=RAW, warmup=2, gen_tokens=128,
    notes="raw prompt; greedy temp=0",
)
check("entry engine", entry["engine"] == "vexel")
check("entry model", entry["model"] == "qwen-0.5b")
check("entry scenario", entry["scenario"] == "standard_decode")
check("entry gen_tokens", entry["gen_tokens"] == 128)
check("entry carries notes", entry["notes"] == "raw prompt; greedy temp=0")
close("entry decode median", entry["metrics"]["decode_tok_s"]["median"], 5.5)

print("== build_result_record: top-level schema assembly + validation ==")
record = build_result_record(
    created_utc="2026-06-11T00:00:00Z",
    hardware={"chip": "Apple M4 Max", "cpu_cores": 16, "gpu_cores": 40,
              "unified_memory_gb": 128, "macos": "15.5", "metal": "Metal 3"},
    engine_versions={"vexel": "c30d2b6", "llama.cpp": "b8140",
                     "ollama": "0.13.5", "mlx_lm": "0.30.7"},
    methodology={"warmup": 2, "measured_runs": 10, "gen_tokens": 128,
                 "temperature": 0, "prompt_set": "synthetic-64"},
    entries=[entry],
    mlx_caveat="MLX uses 4-bit mlx-community weights, not the GGUF file.",
)
check("schema_version stamped", record["schema_version"] == SCHEMA_VERSION)
check("created_utc present", record["created_utc"] == "2026-06-11T00:00:00Z")
check("hardware captured", record["hardware"]["chip"] == "Apple M4 Max")
check("engine versions captured", record["engine_versions"]["mlx_lm"] == "0.30.7")
check("mlx caveat surfaced in record", "MLX" in record["mlx_caveat"])
check("entries present", len(record["entries"]) == 1)

errs = validate_record(record)
check("valid record has no validation errors", errs == [], f"errors={errs}")

print("== validate_record: catches a malformed record ==")
bad = json.loads(json.dumps(record))
del bad["hardware"]
bad["entries"][0]["metrics"]["decode_tok_s"].pop("p95")
bad_errs = validate_record(bad)
check("missing hardware flagged", any("hardware" in e for e in bad_errs), f"errs={bad_errs}")
check("missing p95 in metric flagged", any("p95" in e for e in bad_errs), f"errs={bad_errs}")

print("== group_and_build_entries: raw JSONL records -> one entry per cell ==")
# Mixed records as the bench loops emit them (note: 'mode' is the scenario key
# in the existing JSONL; grouping must accept it). Two engines, same model.
JSONL = []
for v in range(1, 11):
    JSONL.append({"engine": "vexel", "model": "qwen-0.5b", "mode": "standard",
                  "gen_tokens": 128, "decode_tok_s": float(v), "prefill_tok_s": float(v * 2)})
for v in range(1, 11):
    JSONL.append({"engine": "llama.cpp", "model": "qwen-0.5b", "mode": "standard",
                  "gen_tokens": 128, "decode_tok_s": 100.0, "prefill_tok_s": 200.0})
grouped = group_and_build_entries(JSONL, warmup=0)
check("two cells -> two entries", len(grouped) == 2)
check("grouping preserves insertion order (vexel first)", grouped[0]["engine"] == "vexel")
check("scenario taken from 'mode' key", grouped[0]["scenario"] == "standard")
close("vexel decode median (1..10)", grouped[0]["metrics"]["decode_tok_s"]["median"], 5.5)
close("llama.cpp decode median (constant 100)", grouped[1]["metrics"]["decode_tok_s"]["median"], 100.0)
check("llama.cpp decode stddev == 0 (no spread)",
      grouped[1]["metrics"]["decode_tok_s"]["stddev"] == 0.0)
check("missing metric (ttft) degrades to None, never crashes",
      grouped[0]["metrics"]["ttft_ms"]["median"] is None)

print("== record round-trips through JSON unchanged ==")
roundtrip = json.loads(json.dumps(record))
check("json round-trip stable", roundtrip == record)

print("== committed example_result.json conforms to the live schema ==")
EXAMPLE = Path(__file__).resolve().parent.parent / "results" / "example_result.json"
check("example_result.json exists", EXAMPLE.exists(), f"({EXAMPLE})")
if EXAMPLE.exists():
    example = json.loads(EXAMPLE.read_text())
    check("example schema_version matches code", example["schema_version"] == SCHEMA_VERSION,
          f"(file={example.get('schema_version')}, code={SCHEMA_VERSION})")
    ex_errs = validate_record(example)
    check("example validates against current schema", ex_errs == [], f"errors={ex_errs}")

print()
if TESTS_FAILED == 0:
    print(f"PASS: {TESTS_RUN}/{TESTS_RUN} result_schema assertions passed")
    sys.exit(0)
else:
    print(f"FAIL: {TESTS_FAILED}/{TESTS_RUN} result_schema assertions failed")
    sys.exit(1)
