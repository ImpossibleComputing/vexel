#!/usr/bin/env python3
"""stats_test.py — Unit tests for the benchmark statistics core (stats.py).

Why this exists: the entire trust thesis of this harness is that variance is a
first-class, honestly-reported output — "best of N" is banned. That promise is
only as good as the math behind median / p5 / p95 / stddev. These tests pin that
math against KNOWN inputs with HAND-COMPUTED expected values, so a future tweak
to the percentile convention or the stddev estimator fails loudly here instead of
silently shifting every published number.

Convention mirrors benchmarks/lib/parse_test.sh: a standalone runner (no pytest
dependency — none is installed), exit 0 = all pass, exit 1 = any failure.

Run standalone:  python3 benchmarks/lib/stats_test.py
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from stats import discard_warmup, percentile, summarize  # noqa: E402

TESTS_RUN = 0
TESTS_FAILED = 0


def assert_close(name: str, actual, expected, tol: float = 1e-9) -> None:
    """Float comparison with absolute tolerance (the math does division)."""
    global TESTS_RUN, TESTS_FAILED
    TESTS_RUN += 1
    if actual is None or abs(actual - expected) > tol:
        print(f"  FAIL {name} (got {actual}, expected ~{expected} +/-{tol})")
        TESTS_FAILED += 1
    else:
        print(f"  ok   {name} (got {actual}, expected ~{expected})")


def assert_eq(name: str, actual, expected) -> None:
    global TESTS_RUN, TESTS_FAILED
    TESTS_RUN += 1
    if actual != expected:
        print(f"  FAIL {name} (got {actual!r}, expected {expected!r})")
        TESTS_FAILED += 1
    else:
        print(f"  ok   {name} (got {actual!r})")


# ---------------------------------------------------------------------------
# Dataset: 1..10 (n=10, the spec's minimum measured-run count). All expected
# values below are hand-computed in the module docstring of stats.py.
# ---------------------------------------------------------------------------
DATA = [10, 1, 9, 2, 8, 3, 7, 4, 6, 5]  # deliberately unsorted: summarize must sort

print("== percentile (linear interpolation, method of analyze.py) ==")
srt = sorted(DATA)
assert_close("p5  of 1..10", percentile(srt, 5), 1.45)
assert_close("p50 of 1..10 (== median)", percentile(srt, 50), 5.5)
assert_close("p95 of 1..10", percentile(srt, 95), 9.55)
assert_close("p0  == min", percentile(srt, 0), 1.0)
assert_close("p100 == max", percentile(srt, 100), 10.0)

print("== summarize on 1..10 ==")
s = summarize(DATA)
assert_eq("n", s["n"], 10)
assert_close("min", s["min"], 1.0)
assert_close("max", s["max"], 10.0)
assert_close("mean", s["mean"], 5.5)
assert_close("median", s["median"], 5.5)
assert_close("p5", s["p5"], 1.45)
assert_close("p95", s["p95"], 9.55)
# Sample stddev (Bessel, n-1): sum sq dev = 82.5, /9 = 9.1667, sqrt = 3.02765
assert_close("stddev (sample, n-1)", s["stddev"], 3.0276503541, 1e-6)

print("== summarize edge cases ==")
one = summarize([42.0])
assert_eq("n=1 -> n", one["n"], 1)
assert_close("n=1 -> median", one["median"], 42.0)
assert_close("n=1 -> p5", one["p5"], 42.0)
assert_close("n=1 -> p95", one["p95"], 42.0)
assert_close("n=1 -> stddev is 0 (undefined sample var degrades to 0)", one["stddev"], 0.0)

empty = summarize([])
assert_eq("n=0 -> n", empty["n"], 0)
assert_eq("n=0 -> median is None (no data, never faked)", empty["median"], None)
assert_eq("n=0 -> stddev is None", empty["stddev"], None)

print("== discard_warmup (warmup runs are dropped, never averaged in) ==")
assert_eq("discard 3 of 1..10", discard_warmup(DATA, 3), [2, 8, 3, 7, 4, 6, 5])
assert_eq("discard 0 keeps all", discard_warmup(DATA, 0), DATA)
assert_eq("discard >= len yields empty", discard_warmup([1, 2], 5), [])
assert_eq("discard negative treated as 0", discard_warmup([1, 2, 3], -1), [1, 2, 3])

print()
if TESTS_FAILED == 0:
    print(f"PASS: {TESTS_RUN}/{TESTS_RUN} stats assertions passed")
    sys.exit(0)
else:
    print(f"FAIL: {TESTS_FAILED}/{TESTS_RUN} stats assertions failed")
    sys.exit(1)
