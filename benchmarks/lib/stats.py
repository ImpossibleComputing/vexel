#!/usr/bin/env python3
"""stats.py — Statistics core for the trustworthy benchmark harness.

This module is the heart of the harness's trust contract (see
docs/superpowers/specs/2026-06-11-vexel-benchmark-harness-design.md): it turns a
list of per-run measurements into a *distribution*, never a "best of N" cherry
pick. Variance is reported as a first-class output (p5/p95/stddev), so a reader
sees the spread instead of a hidden best case. The cold-start flake tracked in
ov-7ro is exactly the kind of outlier that "best of N" would launder away and
that median + p5/p95 surface honestly.

Pure functions only (numbers in, numbers out) so they are unit-tested against
known inputs in stats_test.py — mirroring the fixture-test philosophy the
ov-5j6.1 parsers established (parser/stat drift is the most likely silent
failure of a benchmark).

Conventions (pinned by stats_test.py against hand-computed values):
- percentile(): linear interpolation between closest ranks, k = (n-1)*p/100.
  This is the same convention already used by benchmarks/analyze.py and by
  numpy's default — one percentile definition across the whole codebase.
- median == percentile(50) (correct for both odd and even n).
- stddev: SAMPLE standard deviation (Bessel's correction, divide by n-1). We are
  estimating the underlying run-to-run variance from a finite SAMPLE of runs, so
  the n-1 estimator is the textbook choice. A single run has undefined sample
  variance and degrades to 0.0 (no spread observable from one point); zero runs
  yields None (no data — never faked).

Worked example for DATA = 1..10 (n=10), pinned in stats_test.py:
    mean        = 5.5
    median      = 5.5
    p5          = 1.45     (k = 9*0.05 = 0.45 -> 1*0.55 + 2*0.45)
    p95         = 9.55     (k = 9*0.95 = 8.55 -> 9*0.45 + 10*0.55)
    sum sq dev  = 82.5 -> sample var 82.5/9 = 9.1667 -> stddev 3.02765
"""

import math
from typing import Optional


def percentile(sorted_values: list[float], p: float) -> float:
    """The p-th percentile (0..100) of an ALREADY-SORTED, non-empty list.

    Linear interpolation between closest ranks: k = (n-1) * p/100. Matches
    benchmarks/analyze.py and numpy's default 'linear' method.
    """
    if not sorted_values:
        raise ValueError("percentile() requires a non-empty list")
    if len(sorted_values) == 1:
        return float(sorted_values[0])
    k = (len(sorted_values) - 1) * (p / 100.0)
    lo = math.floor(k)
    hi = math.ceil(k)
    if lo == hi:
        return float(sorted_values[int(k)])
    return sorted_values[lo] * (hi - k) + sorted_values[hi] * (k - lo)


def stddev_sample(values: list[float]) -> Optional[float]:
    """Sample standard deviation (Bessel, n-1).

    None for an empty list (no data). 0.0 for a single value (no spread
    observable — sample variance is undefined and we report it as zero).
    """
    n = len(values)
    if n == 0:
        return None
    if n == 1:
        return 0.0
    mean = sum(values) / n
    variance = sum((x - mean) ** 2 for x in values) / (n - 1)
    return math.sqrt(variance)


def summarize(samples: list[float]) -> dict:
    """Summarize a list of per-run measurements into a distribution record.

    Returns a dict with: n, min, max, mean, median, p5, p95, stddev. For an
    empty input every statistic is None and n is 0 — the harness reports "no
    data", it never fabricates a number.
    """
    n = len(samples)
    if n == 0:
        return {
            "n": 0,
            "min": None,
            "max": None,
            "mean": None,
            "median": None,
            "p5": None,
            "p95": None,
            "stddev": None,
        }
    srt = sorted(float(x) for x in samples)
    return {
        "n": n,
        "min": srt[0],
        "max": srt[-1],
        "mean": sum(srt) / n,
        "median": percentile(srt, 50),
        "p5": percentile(srt, 5),
        "p95": percentile(srt, 95),
        "stddev": stddev_sample(srt),
    }


def discard_warmup(samples: list, warmup: int) -> list:
    """Drop the first `warmup` runs (cold-start) before aggregation.

    Warmup discard is the trust contract's answer to ov-7ro cold-start variance:
    the first runs pay JIT/Metal-shader/page-fault costs unrepresentative of
    steady state, so they are removed, never averaged in. A negative warmup is
    treated as 0; a warmup >= len yields an empty list (caller must notice 0
    measured runs and report it honestly).
    """
    if warmup <= 0:
        return samples
    return samples[warmup:]
