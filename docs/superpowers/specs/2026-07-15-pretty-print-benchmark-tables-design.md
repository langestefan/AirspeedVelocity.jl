# Pretty-printed benchmark comparison tables

- **Date:** 2026-07-15
- **Branch:** `pretty-print`
- **Status:** Design approved, pending spec review

## Motivation

`benchpkgtable` / `benchpkg` currently emit a flat GitHub-flavored markdown table
with one column per revision and a `main / PR` ratio column. In the primary use
case — a benchmark comment posted on a pull request by the GitHub Action — this
table is hard to skim: every benchmark is shown at equal weight, the ratio
direction (`main / PR`, where `>1` means *faster*) is unintuitive, and a 50-row
suite produces a wall of numbers even when nothing meaningfully changed.

This feature makes the comparison output **scannable**: a one-line verdict, the
few benchmarks that actually moved surfaced at the top with direction markers,
and everything unchanged tucked into a collapsible section.

The primary optimization target is the **rendered GitHub comment**, so the value
comes from markdown/HTML semantics (emoji, bold, `<details>`), not from a
table-drawing library. PrettyTables.jl was considered and rejected for this
scope: its markdown backend emits essentially the same `| ... |` pipes we already
produce. (See *Out of scope* for where PrettyTables would legitimately fit.)

## Non-goals

- **Terminal / TTY pretty rendering** (box-drawing, ANSI color). Rich output is
  markdown-optimized; `<details>` tags render literally in a plain terminal, same
  as the raw markdown tables already printed today. A TTY-aware renderer is
  future work (see *Out of scope*).
- **Changing time/memory unit selection.** Auto-unit and `--force-time-unit`
  behavior are untouched. This feature only adds the Change column, markers,
  verdict, and collapse.
- **Multi-revision (>2) comparison semantics.** Rich comparison applies only when
  comparing exactly two revisions; otherwise we fall back to the plain table.

## Terminology

- **Baseline** — the first revision in `combined_results` (e.g. the default
  branch, `main`).
- **Candidate** — the second revision (e.g. the PR head SHA).
- **Change** — signed relative change of candidate vs baseline:
  `(candidate − baseline) / baseline`. Positive = candidate is *slower / uses
  more memory* = regression. Negative = *faster / less memory* = improvement.
- **Significant** — a change large enough to surface above the fold (see rule).

## Output specification

### 2-revision rich output (the default)

Per mode (`time`, `memory`), `create_table` emits, in order:

1. A **verdict line**: `**Time** — 🔴 N regressions · 🟢 M faster · ➖ K unchanged`
   - Mode label derived from `key`: `median → "Time"`, `memory → "Memory"`.
   - Correct singular/plural (`1 regression`, `2 regressions`).
   - When `N == 0 && M == 0`: `**Time** — ➖ K benchmarks, none beyond ±10%`.
2. A **significant table** (only if at least one benchmark is significant):
   always visible, sorted by `|Change|` descending (worst first). The benchmark
   name is prefixed with `🔴`/`🟢`; the Change cell is bold.
3. A **collapsed table** of everything else, wrapped in
   `<details><summary>➖ K unchanged benchmarks</summary> … </details>`. Original
   key order preserved. No emoji prefixes, Change not bolded.

`time_to_load` is always pinned to the **last row of whichever table it lands
in** (normally the collapsed one).

Cells show the median at the selected unit **without** `± IQR` (the spread is
used internally for significance only, keeping cells narrow). Headers are
`Benchmark | <baseline label> | <candidate label> | Change`.

**Example — a PR with no real change (all within ±10% and noise):**

```markdown
## Benchmark Results (Julia v1)

**Time** — ➖ 51 benchmarks, none beyond ±10%

<details><summary>➖ 51 unchanged benchmarks</summary>

|                         | main       | 656f8e4eaf77f6…  | Change |
|:------------------------|:----------:|:----------------:|:------:|
| ours/n=100/NOAA         | 0.0405 ms  | 0.0411 ms        | +1.5%  |
| ours/n=100/PSA          | 0.0173 ms  | 0.0178 ms        | +3.0%  |
| refraction/NoRefraction | 0.00021 ms | 0.00022 ms       | +4.7%  |
| …                                                                |
| time_to_load            | 0.182 s    | 0.182 s          | 0%     |
</details>
```

**Example — a PR that regresses one benchmark:**

```markdown
**Time** — 🔴 1 regression · 🟢 0 faster · ➖ 50 unchanged

|                          | main   | 656f8e4eaf77f6… | Change   |
|:-------------------------|:------:|:---------------:|:--------:|
| 🔴 solposx/n=100000/USNO | 459 ms | 643 ms          | **+40%** |

<details><summary>➖ 50 unchanged benchmarks</summary>
… the remaining 50 rows …
</details>
```

### Plain output (`--plain`)

Byte-for-byte identical to today's `create_table`: `main / PR ± err` ratio column,
`median ± IQR` cells, no verdict, no emoji, no collapse. This is the escape hatch
and the regression anchor for tests.

### Multi-revision (>2) output

Falls back to the plain multi-column table regardless of `--plain` (verdict/
markers/collapse/Change require a single baseline↔candidate pair).

## Change computation & significance rule

Given baseline stats `b` and candidate stats `c` for one benchmark, with
`v = "median"` for time or `v = "memory"` for memory:

```
change  = (c[v] - b[v]) / b[v]                      # requires b[v] != 0
dir     = change > 0 ? :regression : change < 0 ? :improvement : :none

# Noise gate (time only; memory has no IQR):
err_b   = (b["75"] - b["25"]) / 2                   # if both present
err_c   = (c["75"] - c["25"]) / 2
noise   = sqrt(err_b^2 + err_c^2)
outside = abs(c[v] - b[v]) > noise                  # true if errs unavailable

significant = (abs(change) >= threshold) && outside
```

- `threshold` default **0.10** (10%), configurable (see API/CLI).
- **Memory** benchmarks carry no `"25"`/`"75"`, so `outside` is `true` and
  significance is threshold-only on memory bytes. `allocs` is displayed but does
  not drive the Change metric.
- `b[v] == 0` → Change is not computable; display `—`, treat as not significant,
  count as unchanged. (Covers the 0-alloc memory rows and any zero-baseline.)
- A benchmark present in only one revision → blank Change cell, uncounted, placed
  in the collapsed table.

### Why 10% *and* noise (rationale from real data)

On a real 51-benchmark suite where the PR changed nothing, ratios clustered at
±1–3% with tight error bars (e.g. `0.985 ± 0.0089`, ~1.7σ from parity). A
noise-only rule would flag roughly half the suite as "changes" because the
benchmarks are precise but small in magnitude. The 10% floor suppresses that; the
noise gate additionally prevents a large-looking % on a benchmark with huge
variance from being reported. Both conditions are required.

## Formatting details

- **Change cell:** signed percent. One decimal when `|pct| < 10` (`+1.5%`),
  integer otherwise (`+40%`). Exactly-zero → `0%`. Sign uses ASCII `-` / `+`.
- **Emoji:** `🔴` regression, `🟢` improvement, `➖` unchanged (verdict/summary
  only). Row-level emoji appears only in the significant table, prefixing the name.
- **Memory cell tidy-up (rich mode):** render as `10 allocs · 4.53 kB` (single
  space, `·` separator), replacing today's `10  allocs: 4.53 kB`. Non-computable
  Change → `—`.
- **Header truncation:** unchanged — long revision labels/SHAs still truncated at
  14 chars + `…` as today.

## Architecture

All new logic lives in `src/TableUtils.jl` as small, independently testable
functions; the actual table rendering reuses the existing `markdown_table`.

```julia
# pure, unit-testable
compute_change(b, c) -> (; change::Union{Float64,Missing}, dir::Symbol, err::Union{Float64,Missing})
is_significant(change, err, diff; threshold) -> Bool
format_change(change, dir; bold::Bool) -> String        # "**+40%**", "+1.5%", "—"
verdict_line(n_reg, n_faster, n_unchanged; key, threshold) -> String
```

`create_table` is refactored to dispatch on mode:

```julia
function create_table(combined_results;
    key="median",
    add_ratio_col=true,
    time_unit=nothing,
    formatter=nothing,
    plain::Bool=false,               # NEW — plain reproduces old output exactly
    significance_threshold=0.10,     # NEW
    emoji::Bool=true,                # NEW
)
```

- `plain=true` **or** `length(combined_results) != 2` → existing code path,
  unchanged output.
- otherwise → rich path: build rows via `compute_change`, split into
  significant/unchanged, render each bucket with `markdown_table`, prepend
  verdict, wrap the unchanged bucket in `<details>`.

The existing `markdown_table`, `format_time`, `format_memory` are retained;
`format_memory` gains the tidier rich rendering (or a sibling used in rich mode).

## CLI & Action changes

- **`benchpkgtable`** (`src/BenchPkgTable.jl`) and **`benchpkg`**
  (`src/BenchPkg.jl`): add `--plain` flag (default off → rich) and
  `--threshold <arg>` (default `0.10`), threaded into `create_table`. Rich becomes
  the default output for both.
- **`action.yml`** ("Create comment body" step): remove the per-mode
  `<details><summary>${m^} benchmarks</summary>` wrapper — Julia now owns the
  verdict and inner collapse. Bash concatenates each mode's output under the
  `## Benchmark Results` header. No new action inputs.

## Backward compatibility

- `create_table`'s public signature only gains keyword args with defaults;
  positional/existing-keyword callers keep working. `--plain` yields byte-identical
  legacy output.
- Existing test expectations that assert the old default table are updated to the
  rich format (or switched to `plain=true` where they are really testing the
  legacy renderer). At least one test pins the `--plain` / `plain=true` output to
  guard the legacy path.

## Edge cases (all covered by tests)

| Case | Behavior |
|------|----------|
| Zero baseline (`b[v] == 0`) | Change `—`, not significant, unchanged bucket |
| Benchmark in only one revision | blank Change, uncounted, collapsed |
| Missing IQR (memory, or partial) | noise gate skipped → threshold-only |
| `>2` revisions | plain fallback |
| Everything unchanged | verdict + single collapsed table, no visible table |
| `time_to_load` | always last row of its bucket |
| `emoji=false` | markers/verdict use ASCII (`+`/`-`/`~`) instead of emoji |

## Testing plan

- **`compute_change` / `is_significant`** units: regression, improvement,
  within-noise, `|change| ≥ threshold` but inside noise (→ not significant),
  missing IQR, zero baseline.
- **`create_table` rich**: asserts verdict line text & counts, emoji prefix on
  significant rows, `<details>` present, `time_to_load` last, significant rows
  sorted worst-first, memory cell tidy format.
- **`create_table` plain round-trip**: `plain=true` reproduces the pre-change
  output string.
- **Fallback**: 3 revisions → plain table.
- Reuse `test/utils.jl`'s whitespace-insensitive `isapprox(::String,::String)`
  for table comparisons.

## Out of scope / future work

- **TTY-aware terminal renderer.** For local `benchpkg` runs, a renderer that
  detects a TTY and emits a box-drawn, colored table would be a genuine
  improvement — and this is exactly where **PrettyTables.jl** earns its place
  (terminal backend), rather than the markdown target. Deferred.
- **Per-repo threshold via action input.** The `--threshold` CLI flag exists;
  wiring a matching `action.yml` input can follow if requested.

## File-by-file change list

- `src/TableUtils.jl` — new helpers + `create_table` rich/plain dispatch; tidy
  memory formatting.
- `src/BenchPkgTable.jl` — `--plain`, `--threshold` options.
- `src/BenchPkg.jl` — `--plain`, `--threshold` options.
- `action.yml` — drop per-mode `<details>` wrapper in comment assembly.
- `test/runtests.jl` — update expectations, add rich/plain/fallback test items.
- `README.md` — document new default output, `--plain`, `--threshold`; update the
  CI "collapsible tables" description.
