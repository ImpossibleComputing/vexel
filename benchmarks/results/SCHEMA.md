# Benchmark Result Schema (`benchmarks/results/*.json`)

> Schema version: **1.0.0** — defined and validated by `benchmarks/lib/result_schema.py`.
> Canonical example: [`example_result.json`](./example_result.json) (kept conforming by `result_schema_test.py`).

This is the machine-readable record produced by the statistical benchmark harness
(ov-5j6.2). It exists to close the trust gaps in the spec
(`docs/superpowers/specs/2026-06-11-vexel-benchmark-harness-design.md`):

- **Variance is first-class, "best of N" is banned.** Every metric stores its full
  distribution (median / p5 / p95 / stddev / min / max / mean / n) **and the raw
  samples**, so a reader sees the spread and can re-derive every number.
- **Versions + hardware are auto-captured**, not hand-edited, so a published number
  is always tied to the exact engine builds and machine that produced it.
- **The MLX format caveat travels with the data**, so an MLX row is never misread as
  same-file apples-to-apples.

## Top-level record

| Field             | Type     | Notes |
|-------------------|----------|-------|
| `schema_version`  | string   | SemVer. Consumers should refuse a major version they don't know. |
| `created_utc`     | string   | ISO-8601 UTC, e.g. `2026-06-11T00:00:00Z`. |
| `hardware`        | object   | Reference machine (auto-captured by `metadata.py`). |
| `engine_versions` | object   | One pinned version per engine (auto-captured). |
| `methodology`     | object   | Warmup count, measured-run count, gen length, temp, etc. |
| `mlx_caveat`      | string   | The "MLX is equivalent-quant, not same-file" note. |
| `entries`         | array    | One entry per `(engine, model, scenario)` cell. |

### `hardware`
`chip`, `cpu_cores` (int), `gpu_cores` (int), `unified_memory_gb` (int),
`macos` (e.g. `15.5`), `metal` (e.g. `Metal 3`). Any field that can't be read
degrades to `"not available"` / `null` rather than failing the run.

### `engine_versions`
`vexel` (git short commit, `-dirty` if the tree is modified), `llama.cpp`
(`<build> (<hash>)`), `ollama` (semver), `mlx_lm` (semver). A missing engine is
recorded as `"not available"` — **never silently omitted**.

### `methodology`
Free-form but conventionally includes `warmup`, `measured_runs`, `gen_tokens`,
`temperature`, `prompt_set`, and an `aggregation` description. Records the trust
contract that produced the numbers.

## `entries[]` — one per `(engine, model, scenario)`

| Field              | Type   | Notes |
|--------------------|--------|-------|
| `engine`           | string | `vexel` / `llama.cpp` / `ollama` / `mlx`. |
| `model`            | string | e.g. `qwen2.5-7b-q4_k_m`. |
| `scenario`         | string | e.g. `standard_decode`. |
| `gen_tokens`       | int    | Generation length used. |
| `notes`            | string | Per-cell caveats (e.g. MLX weight format, TTFT derivation). |
| `warmup_discarded` | int    | Leading runs dropped before aggregation (ov-7ro cold-start). |
| `measured_n`       | int    | Number of measured runs aggregated. `0` ⇒ engine unavailable. |
| `metrics`          | object | The 4-metric contract, each a distribution (below). |

### `metrics` — the 4-metric contract (from the ov-5j6.1 adapters)
Keys: **`decode_tok_s`**, **`prefill_tok_s`**, **`ttft_ms`**, **`peak_mem_mb`**.

Each maps to a **distribution object**:

| Field     | Type            | Notes |
|-----------|-----------------|-------|
| `n`       | int             | Sample count (== `measured_n` when the engine reported the metric). |
| `min`/`max` | float \| null | Extremes. |
| `mean`    | float \| null   | Arithmetic mean. |
| `median`  | float \| null   | `percentile(50)`, robust to cold-start outliers. |
| `p5`/`p95`| float \| null   | 5th / 95th percentile (linear interpolation, `k=(n-1)·p/100`). |
| `stddev`  | float \| null   | **Sample** stddev (Bessel, `n-1`). `0.0` for n=1, `null` for n=0. |
| `samples` | float[]         | The raw measured values (variance is auditable, not just summarized). |

`null` everywhere means *no data* (engine unavailable / metric not reported) — the
harness reports the absence honestly, it never fabricates a value.

## Producing a record

```bash
# 1. Collect per-run JSONL (the bench loops / engine adapters emit the 4 metrics).
# 2. Aggregate -> validated result record:
python3 benchmarks/lib/aggregate_results.py <runs.jsonl|dir> -o benchmarks/results/run.json --warmup 3
```

`aggregate_results.py` groups records by cell, discards warmup, summarizes each
metric, attaches auto-captured versions + hardware, and **exits non-zero if the
record fails `validate_record`** — a malformed result fails loudly instead of
feeding a wrong published number.

## Consumers

- `benchmarks/lib/report_compare.py` — renders the publishable markdown report
  ("Vexel's position" table, variance inline, MLX caveat, hardware+versions
  footer) from one of these records. Run automatically by `bench_compare.sh`.
- `benchmarks/lib/regression_guard.py` — CI guard: fails (exit 1) if Vexel's
  median `decode_tok_s` regressed more than a threshold (default 5%) vs a
  stored baseline record (`benchmarks/results/baseline.json` by convention).

Both refuse a record whose schema major version they don't know.

## Tests
`python3 benchmarks/lib/stats_test.py`, `result_schema_test.py`, `metadata_test.py`,
`report_compare_test.py`, `regression_guard_test.py`
(or all gates via `benchmarks/lib/run_tests.sh`). The statistics are pinned against
hand-computed known inputs; the example above is checked to conform on every run.
