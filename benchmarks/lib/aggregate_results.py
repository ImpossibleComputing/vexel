#!/usr/bin/env python3
"""aggregate_results.py — Fold collected per-run JSONL into one result record.

This is the OUTPUT stage of the statistical harness: it consumes the per-run
metric records the engine adapters/bench loops emit (ov-5j6.1), discards warmup,
aggregates each metric into a median/p5/p95/stddev distribution, attaches
auto-captured engine versions + reference hardware, validates the result against
the schema, and writes one machine-readable JSON record under benchmarks/results/.

It deliberately does NOT run any models — collecting the JSONL (the model matrix
+ one-command runner) is ov-5j6.3. This stage is the "replace best-of-3 with
honest distributions" half of the trust contract.

Usage:
    python3 lib/aggregate_results.py <input.jsonl|dir> -o results/run.json \
        [--warmup N] [--mlx-caveat "..."]

Input may be a single .jsonl file or a directory of .jsonl files (all concatenated
in sorted filename order). Exits non-zero if the assembled record fails schema
validation (a malformed result must fail loudly, never feed a wrong number
downstream).
"""

import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from metadata import capture_engine_versions, capture_hardware  # noqa: E402
from result_schema import (  # noqa: E402
    build_result_record,
    group_and_build_entries,
    validate_record,
)

DEFAULT_MLX_CAVEAT = (
    "MLX numbers use the same base model at an EQUIVALENT 4-bit quant "
    "(mlx-community weights), NOT the identical GGUF file the other engines load. "
    "Read MLX rows as same-model/equivalent-quant, not same-file."
)


def load_records(path: Path) -> list[dict]:
    """Load per-run records from a .jsonl file or a directory of them."""
    files = sorted(path.glob("*.jsonl")) if path.is_dir() else [path]
    records: list[dict] = []
    for f in files:
        for line in f.read_text().splitlines():
            line = line.strip()
            if line:
                records.append(json.loads(line))
    return records


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("input", help="JSONL file or directory of per-run records")
    ap.add_argument("-o", "--output", required=True, help="output result JSON path")
    ap.add_argument("--warmup", type=int, default=0,
                    help="leading runs per cell to discard as warmup (default 0; "
                         "the bench loops already pre-discard their warmup runs)")
    ap.add_argument("--mlx-caveat", default=DEFAULT_MLX_CAVEAT,
                    help="caveat string surfaced in the record for MLX rows")
    args = ap.parse_args(argv)

    in_path = Path(args.input)
    if not in_path.exists():
        print(f"error: input not found: {in_path}", file=sys.stderr)
        return 2

    records = load_records(in_path)
    if not records:
        print(f"error: no records found in {in_path}", file=sys.stderr)
        return 2

    entries = group_and_build_entries(records, warmup=args.warmup)
    measured_runs = max((e["measured_n"] for e in entries), default=0)
    record = build_result_record(
        created_utc=datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        hardware=capture_hardware(),
        engine_versions=capture_engine_versions(),
        methodology={
            "warmup": args.warmup,
            "measured_runs": measured_runs,
            "aggregation": "median + p5/p95 + stddev over measured runs (no best-of-N)",
        },
        entries=entries,
        mlx_caveat=args.mlx_caveat,
    )

    errors = validate_record(record)
    if errors:
        print("error: assembled record failed schema validation:", file=sys.stderr)
        for e in errors:
            print(f"  - {e}", file=sys.stderr)
        return 1

    out_path = Path(args.output)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(record, indent=2) + "\n")
    print(f"wrote {out_path} ({len(entries)} cells, "
          f"{measured_runs} measured runs/cell, warmup={args.warmup})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
