# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

AirspeedVelocity.jl benchmarks Julia packages **across their git history** (inspired by [asv](https://asv.readthedocs.io/)). It ships three CLI executables — `benchpkg`, `benchpkgtable`, `benchpkgplot` — plus a Julia API. The core idea: freeze a benchmark script at one revision, then run it against many commits/tags/branches and compare.

## Commands

```bash
# Run the full test suite (matches CI)
julia --color=yes --threads=auto --project=. -e 'using Pkg; Pkg.test()'

# Build the three CLI executables into ~/.julia/bin
julia --project=. -e 'using Pkg; Pkg.build()'   # runs deps/build.jl

# Format code (blue style; see .JuliaFormatter.toml)
julia -e 'using JuliaFormatter; format(".")'

# Build docs
julia --project=docs docs/make.jl
```

Run a **single test item** — tests use TestItemRunner, so filter by name from `test/runtests.jl` rather than by file:

```bash
julia --project=. -e 'using TestItemRunner; @run_package_tests filter=ti->occursin("Test run benchmarking", ti.name)'
```

Note: many tests are **integration tests** that download and benchmark `SymbolicRegression.jl` at pinned versions (e.g. `v0.15.3`, `v0.16.2`). They spawn real Julia subprocesses and are slow; a full run takes minutes and needs network access.

## Architecture

The top module `src/AirspeedVelocity.jl` includes submodules in dependency order. Everything except the CLI wrappers is wrapped in `@stable` (DispatchDoctor) to enforce type stability; the Comonicon CLI files are `@unstable`.

- **`Utils.jl`** — the engine. `benchmark(package, revs; ...)` is the heart of the package. For **each revision** it creates a temporary Pkg environment, `Pkg.add`s the package at that revision, and launches a **fresh `julia` subprocess** that runs the (frozen) benchmark script under BenchmarkTools.jl. Results are written as one JSON file per revision. Load-time is measured separately by starting one Julia process per sample (`nsamples_load_time`). `load_results` reads those JSONs back. Also owns unit selection (`TIME_UNITS`, `MEMORY_UNITS`, `ALLOCATION_UNITS`) and script resolution (`_get_script` downloads `benchmark/benchmarks.jl` from a given revision).
- **`TableUtils.jl`** — `create_table` renders `load_results` output as a markdown table (time and/or memory modes, optional ratio column when comparing exactly two revisions).
- **`PlotUtils.jl`** — `combined_plots` flattens the benchmark suite into per-benchmark line plots (PlotlyLight + PlotlyKaleido/Kaleido for image export).
- **`BenchPkg.jl` / `BenchPkgTable.jl` / `BenchPkgPlot.jl`** — thin Comonicon `@main` CLI wrappers, one per executable. They parse comma-delimited string args (`--rev`, `--filter`, `--add`, etc.) and delegate to the Utils/TableUtils/PlotUtils functions. `deps/build.jl` calls each module's `comonicon_install()`.

### Benchmark script contract

A benchmark script (default `benchmark/benchmarks.jl`) must define `const SUITE = BenchmarkGroup()`. Inside it, the constant `PACKAGE_VERSION` is available so a single frozen script can branch on the package version being tested. The `{DEFAULT}` revision token resolves to the package's default branch; `dirty` benchmarks the current working state at `--path`.

## Conventions

- **DispatchDoctor type stability is enforced in tests**: `test/runtests.jl` sets the `instability_check => "error"` preference, so a type instability introduced in `@stable` code will **fail tests**, not just warn. Keep new code in `Utils.jl`/`TableUtils.jl`/`PlotUtils.jl` type-stable.
- Formatting is **blue style** via JuliaFormatter (`docs/` is ignored).
- Releases are automated via **release-please** (see `release-please-config.json`); the GitHub Action is versioned separately at the `action-v1` tag (`action.yml`).
