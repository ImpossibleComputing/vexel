# Vexel Trustworthy Multi-Engine Benchmark Harness — Design Spec

> Date: 2026-06-11
> Status: Approved (brainstorm) → ready for implementation
> Owner: mayor (coordination) → oss_vexel polecats (implementation)
> Epic: Vexel "awesome for others" — Phase 1, item #1 (ground truth)

## 1. Purpose & motivation

Vexel's adoption thesis is **"the fastest local LLM on Apple Silicon, effortless to drop in."**
Half of that — *fast* — is currently **unproven**. We do not have a trustworthy answer to
"where does Vexel actually stand?" This spec defines the benchmark that establishes that ground truth.

This is **step zero**: we cannot honestly market performance, and cannot know whether perf-frontier
work is needed (or where), until we measure rigorously against the real competition.

### Why the existing benchmark setup is not yet ground truth

The repo already has substantial benchmark infrastructure (`benchmarks/lib/*.sh`, the `vexel bench`
subcommand, `perf_reports/`, `benchmarks/RESULTS.md`, `benchmarks/COMPETITORS.md`). It has three
trust-breaking gaps:

1. **Only llama.cpp is measured.** `benchmarks/lib/engines.sh` discovers llama.cpp binaries only.
   Yet `COMPETITORS.md` ranks **MLX (~230 tok/s) ~50% faster than llama.cpp (~150)** on M2 Ultra.
   The current headline ("+26% vs llama.cpp", `RESULTS.md`) may be beating the wrong reference while
   MLX laps the field. **We are blind to the actual leader.**
2. **Numbers are not statistically trustworthy.** `RESULTS.md` reports "best of 3 runs," and admits
   the LLaMA-8B figure moved from **+57% → +26%** on re-measure. "Best of N" hides variance. The
   cold-start flake tracked in `ov-7ro` proves run-to-run variance is real on this stack.
3. **Not reproducible/publishable.** Ad-hoc shell scripts + hand-edited dated markdown; competitor
   numbers (`COMPETITORS.md`, M2 Ultra research) live on a different machine than the measured ones
   (`RESULTS.md`, M4 Max). No single command, no in-loop version pinning.

## 2. Goal

**One command produces honest, variance-aware numbers and a publishable report that places Vexel
against llama.cpp, ollama, AND MLX on a documented reference machine.**

Non-goals (explicitly out of scope for this epic):
- Optimizing Vexel's performance (that is Phase 3, gated on this baseline).
- CUDA / non-Apple-Silicon engines.
- A hosted/CI dashboard service (local CI regression guard is in-scope; a web service is not).
- Training/fine-tuning benchmarks.

## 3. Design

### 3.1 Engines under test
| Engine | Status | Notes |
|--------|--------|-------|
| Vexel | exists | subject under test |
| llama.cpp | wired (`engines.sh`) | ecosystem reference |
| **ollama** | **ADD** | adoption-share leader; wraps llama.cpp but UX-different; users compare to it |
| **MLX** | **ADD (must-have)** | the engine to beat per our own landscape doc |

MLX adapter caveat: MLX consumes its own weight format, not GGUF. "Apples-to-apples" therefore means
**same base model + equivalent quantization (e.g., 4-bit), not the identical file.** This must be
documented inline in every report so comparisons aren't silently misread.

### 3.2 Metrics (per engine × model × scenario)
- **Decode throughput** (tokens/sec, steady-state generation)
- **Prefill throughput** (tokens/sec, prompt ingestion)
- **Time-to-first-token (TTFT)** (ms)
- **Peak memory** (resident + unified GPU where measurable)

Each metric reported as **median + p5/p95 + stddev over N≥10 measured runs**, with warmup runs
discarded. **No "best of N".** Variance is a first-class output, not noise to hide.

### 3.3 Model matrix (matched quant)
Small, standard, representative set. Same GGUF across Vexel/llama.cpp/ollama; MLX uses converted
equivalent.
- **LLaMA-3.1-8B-Instruct Q4_K_M** — the 8B-class standard (already in `models.sh`)
- **Qwen2.5** (0.5B already present; add a mid-size, e.g. 7B Q4_K_M)
- **Gemma-2-2B Q4_K_M** — now correctness-verified in Vexel; dogfoods the work just completed
- **Phi-3.5-mini Q4_K_M**

Each model entry pins: download URL, file name, sha256, and the MLX-equivalent source.

### 3.4 Methodology (the trust contract)
- Fixed prompt set (short + medium) and fixed generation length, identical across engines.
- Greedy / temp=0 for determinism of output (correctness cross-check retained from existing
  `accuracy_test.sh`).
- **Warmup runs discarded** (directly addresses the `ov-7ro` cold-start sensitivity).
- **N≥10 measured runs**; report median + p5/p95 + stddev.
- **Pinned engine versions** captured into the result record automatically (Vexel commit, llama.cpp
  build hash, ollama version, MLX/mlx-lm version) — extend `VERSIONS.md` into machine-captured metadata.
- **One documented reference machine** per published report (chip, core counts, unified memory,
  macOS/Metal version) captured automatically.

### 3.5 Output
- **Machine-readable JSON** under `benchmarks/results/` (one record per run-set; schema includes
  engine versions, hardware, per-metric distributions).
- **Generated markdown report** (replaces hand-edited `RESULTS.md` / `perf_reports/*`), including a
  **"Vexel's position" table that contains MLX and ollama**, with variance shown and the MLX-format
  caveat inline.
- **Local CI regression guard**: a mode that fails if Vexel's own median decode tok/s regresses
  more than a configurable threshold (default 5%) vs a stored baseline (reuses the same harness;
  protects against silent perf regressions).

### 3.6 Honesty guardrails (the entire point)
- Report **variance, not best-case**.
- Report plainly **when Vexel is behind** (esp. vs MLX) — a "we're 2nd, here's the gap" result is a
  success of this epic, because it directs Phase-3 work.
- Pin and record versions; document hardware; surface the MLX-format caveat in every report.
- Cross-check output correctness (existing `accuracy_test.sh`) so a "fast" number is never a fast
  *wrong* number.

## 4. Work breakdown (epic → children)

Sequential, each landing via merge queue (`--merge=mr`), each verified on main before the next.

1. **Child 1 — ollama + MLX engine adapters** (`benchmarks/lib/engines.sh` + runners).
   Discovery, invocation, and output parsing for ollama and MLX (mlx-lm). Gives the **first real
   "where we stand" signal** vs the actual leader. *Highest-information first step.*
2. **Child 2 — statistical harness.** Warmup + N-run loop, median/p5/p95/stddev, JSON result schema
   with auto-captured engine versions + hardware. Replaces "best of 3".
3. **Child 3 — standard model matrix + one-command runner.** Pin the matrix (URL/sha256/MLX-equiv),
   a single `make bench-compare` (or `vexel bench compare`) entry point that runs the full grid.
4. **Child 4 — report generator + "position" table + CI regression guard.** Generate the publishable
   markdown (with MLX/ollama + variance + caveats) from JSON; add the regression-guard mode.

## 5. Testing
- Unit-test the parsers (each engine's stdout → metrics struct) against captured fixture outputs —
  parser drift is the most likely silent failure (we saw signature/parse drift bugs this session).
- Unit-test the statistics (median/percentile/stddev) on known inputs.
- A `--dry-run`/`--smoke` mode using the smallest model (Qwen-0.5B) to validate the full pipeline
  fast in CI without requiring 8B downloads or long runs.
- The harness's own output feeds the CI regression guard (dogfood).

## 6. Risks & mitigations
- **MLX not installed / format conversion friction** → adapter degrades gracefully (skip + clearly
  report "MLX: not available"), document the conversion step; never silently omit an engine.
- **Parser brittleness across engine version bumps** → fixture-based parser tests + pinned versions.
- **Result reveals Vexel is behind MLX** → that's an accepted, valuable outcome; it scopes Phase 3.
- **Variance still high after warmup** → report it honestly (p5/p95); investigate via `ov-7ro`.
- **Scope creep into a dashboard/service** → explicitly out of scope; local JSON + markdown + CI guard only.

## 7. Definition of done (epic)
- `ollama` and `MLX` measured alongside Vexel + llama.cpp.
- One command runs the full matrix; results are JSON + generated markdown.
- Every number is median-over-N with variance shown; versions + hardware auto-captured.
- A published report states Vexel's honest position vs all three competitors.
- CI regression guard wired for Vexel's own decode throughput.
