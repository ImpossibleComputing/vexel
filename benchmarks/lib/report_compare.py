#!/usr/bin/env python3
"""report_compare.py — Generate the publishable markdown report from a result JSON.

This is the OUTPUT face of the trustworthy benchmark harness (ov-5j6.4): it
consumes one schema-1.0.0 result record (benchmarks/results/*.json, produced by
aggregate_results.py / bench_compare.sh) and renders the publishable markdown
that REPLACES the hand-edited RESULTS.md / perf_reports flow.

The rendering encodes the honesty guardrails from the design spec
(docs/superpowers/specs/2026-06-11-vexel-benchmark-harness-design.md):
  - "Vexel's position" table contains ALL engines (MLX + ollama + llama.cpp +
    Vexel), sorted by measured decode median — wherever Vexel lands.
  - Variance is shown inline: every metric cell is `median (p5–p95)`, never a
    single cherry-picked number.
  - Vexel's rank is stated plainly, including "behind" and by how much, when
    the data says Vexel is behind. A missing/unmeasured Vexel is said out loud.
  - The MLX weight-format caveat travels inline († footnote on the mlx row),
    so an MLX number can't be misread as same-file apples-to-apples.
  - Hardware + pinned engine versions are footered from the record itself.
  - The report date is the record's created_utc — the report is a pure
    function of the JSON, deterministic and reproducible.

Usage:
    python3 lib/report_compare.py <result.json> [-o report.md]

Without -o the markdown goes to stdout. Refuses a record whose schema major
version it doesn't know (format drift must fail loudly, not render garbage).
Unit-tested in report_compare_test.py against benchmarks/results/example_result.json.
"""

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from result_schema import SCHEMA_VERSION, validate_record  # noqa: E402

# Metric -> column header, in canonical reporting order. Decode first: it is
# the ranking metric ("the fastest local LLM" claim lives or dies on decode).
_METRIC_COLUMNS = [
    ("decode_tok_s", "Decode tok/s"),
    ("prefill_tok_s", "Prefill tok/s"),
    ("ttft_ms", "TTFT ms"),
    ("peak_mem_mb", "Peak mem MB"),
]

NO_DATA = "—"  # em-dash: "no data", never a fabricated 0


class SchemaVersionError(ValueError):
    """Raised when a record's schema major version is unknown to this code."""


def _check_schema_version(record: dict) -> None:
    found = str(record.get("schema_version", "<missing>"))
    if found.split(".")[0] != SCHEMA_VERSION.split(".")[0]:
        raise SchemaVersionError(
            f"unsupported schema_version {found!r} (this generator understands "
            f"major version {SCHEMA_VERSION.split('.')[0]}.x — refusing to "
            f"render a format it might misread)")


def _fmt(value) -> str:
    return NO_DATA if value is None else f"{value:.1f}"


def _dist_cell(dist: dict) -> str:
    """One table cell: `median (p5–p95)` — variance is part of the number."""
    if not dist or dist.get("median") is None:
        return NO_DATA
    return f"{_fmt(dist['median'])} ({_fmt(dist['p5'])}–{_fmt(dist['p95'])})"


def _engine_label(entry: dict) -> str:
    """Engine cell; mlx carries the † weight-format caveat marker inline."""
    engine = entry["engine"]
    return f"{engine} †" if engine == "mlx" else engine


def _decode_median(entry: dict):
    return entry.get("metrics", {}).get("decode_tok_s", {}).get("median")


def _position_sentence(ranked: list[dict]) -> str:
    """Plain-language statement of where Vexel stands on decode throughput.

    `ranked` is the with-data entries sorted by decode median desc. This is the
    spec's "report plainly when Vexel is behind" guardrail: the sentence names
    the leader and quantifies the gap instead of hiding it in a table.
    """
    vexel_rank = next((i for i, e in enumerate(ranked) if e["engine"] == "vexel"), None)
    if vexel_rank is None:
        return ("**Vexel was not measured in this record** — no position is "
                "claimed without data.")

    n = len(ranked)
    vexel_median = _decode_median(ranked[vexel_rank])
    if n == 1:
        return (f"**Vexel decoded at {_fmt(vexel_median)} tok/s (median); no "
                f"other engine produced data to compare against.**")

    if vexel_rank == 0:
        runner_up = ranked[1]
        gap_pct = ((vexel_median - _decode_median(runner_up))
                   / _decode_median(runner_up) * 100.0)
        return (f"**Position: Vexel is #1 of {n} on decode throughput — "
                f"{_fmt(gap_pct)}% ahead of {runner_up['engine']} "
                f"({_fmt(vexel_median)} vs {_fmt(_decode_median(runner_up))} "
                f"tok/s median).**")

    leader = ranked[0]
    gap_pct = (_decode_median(leader) - vexel_median) / _decode_median(leader) * 100.0
    return (f"**Position: Vexel is #{vexel_rank + 1} of {n} on decode "
            f"throughput — {_fmt(gap_pct)}% behind {leader['engine']} "
            f"({_fmt(vexel_median)} vs {_fmt(_decode_median(leader))} "
            f"tok/s median).**")


def _section_for_cell(model: str, scenario: str, entries: list[dict],
                      mlx_caveat: str) -> list[str]:
    """One "Vexel's position" section for a (model, scenario) cell group."""
    with_data = [e for e in entries if _decode_median(e) is not None]
    no_data = [e for e in entries if _decode_median(e) is None]
    ranked = sorted(with_data, key=_decode_median, reverse=True)

    lines = [
        f"## Vexel's position — {model} ({scenario})",
        "",
        _position_sentence(ranked),
        "",
        "| Engine | "
        + " | ".join(f"{header} median (p5–p95)" for _, header in _METRIC_COLUMNS)
        + " | Runs |",
        "|--------|" + "|".join(["---:"] * len(_METRIC_COLUMNS)) + "|-----:|",
    ]
    for entry in ranked + no_data:  # unmeasured engines listed, never dropped
        cells = [_dist_cell(entry["metrics"].get(metric)) for metric, _ in _METRIC_COLUMNS]
        lines.append(f"| {_engine_label(entry)} | " + " | ".join(cells)
                     + f" | {entry.get('measured_n', 0)} |")
    lines.append("")

    if mlx_caveat and any(e["engine"] == "mlx" for e in entries):
        lines.append(f"> † {mlx_caveat}")
        lines.append("")
    return lines


def render_report(record: dict, source: str = "") -> str:
    """Render one schema-1.0.0 result record to publishable markdown."""
    _check_schema_version(record)

    lines = [
        "# Vexel Multi-Engine Benchmark Report",
        "",
        f"> Generated by `benchmarks/lib/report_compare.py` from "
        f"`{source or 'a result record'}`. **Do not hand-edit** — regenerate "
        "from the JSON instead.",
        "",
        f"**Date:** {record.get('created_utc', NO_DATA)} (record creation, UTC)  ",
        f"**Schema:** {record.get('schema_version')}",
        "",
    ]

    # One position section per (model, scenario), in record order.
    groups: dict = {}
    order: list = []
    for entry in record.get("entries", []):
        key = (entry["model"], entry["scenario"])
        if key not in groups:
            groups[key] = []
            order.append(key)
        groups[key].append(entry)

    if not order:
        lines += ["*No benchmark entries in this record.*", ""]
    for model, scenario in order:
        lines += _section_for_cell(model, scenario, groups[(model, scenario)],
                                   record.get("mlx_caveat", ""))

    # Methodology: the trust contract that produced the numbers.
    methodology = record.get("methodology", {})
    if methodology:
        lines += ["## Methodology", ""]
        lines += [f"- **{key}:** {value}" for key, value in methodology.items()]
        lines.append("")

    # Footer: reference machine + pinned engine versions, from the record.
    hardware = record.get("hardware", {})
    versions = record.get("engine_versions", {})
    lines += ["## Hardware & engine versions", ""]
    if hardware:
        lines.append("**Hardware:** " + " · ".join(
            f"{key} {value}" for key, value in hardware.items()))
        lines.append("")
    if versions:
        lines += ["| Engine | Version |", "|--------|---------|"]
        lines += [f"| {engine} | {version} |" for engine, version in versions.items()]
        lines.append("")

    return "\n".join(lines)


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("input", help="result JSON (schema 1.0.0) to render")
    ap.add_argument("-o", "--output", help="markdown output path (default: stdout)")
    args = ap.parse_args(argv)

    in_path = Path(args.input)
    if not in_path.exists():
        print(f"error: input not found: {in_path}", file=sys.stderr)
        return 2

    try:
        record = json.loads(in_path.read_text())
    except json.JSONDecodeError as exc:
        print(f"error: {in_path} is not valid JSON: {exc}", file=sys.stderr)
        return 2
    errors = validate_record(record)
    if errors:
        print(f"error: {in_path} fails schema validation:", file=sys.stderr)
        for err in errors:
            print(f"  - {err}", file=sys.stderr)
        return 2

    try:
        report = render_report(record, source=in_path.name)
    except SchemaVersionError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    if args.output:
        Path(args.output).write_text(report)
        print(f"report written: {args.output}")
    else:
        print(report)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
