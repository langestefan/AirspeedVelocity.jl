# Pretty-print Benchmark Tables Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `benchpkgtable` / `benchpkg` emit a scannable GitHub-comment table — a signed `Change` column, significance-gated emoji markers, a verdict headline, and a collapsible section for unchanged benchmarks — while preserving the legacy output behind `--plain`.

**Architecture:** All formatting logic lives in `src/TableUtils.jl` as small pure functions composed by a refactored `create_table`, which dispatches to a new rich renderer (exactly 2 revisions) or the untouched legacy renderer (`--plain`, or ≠2 revisions). The actual markdown grid is still produced by the existing `markdown_table`. CLI wrappers gain `--plain`/`--threshold`; `action.yml` drops its per-mode `<details>` wrapper since Julia now owns the collapse.

**Tech Stack:** Julia ≥1.10, BenchmarkTools JSON stats, Comonicon (CLI), DispatchDoctor (type-stability enforcement), TestItemRunner/`@testitem` (tests).

## Global Constraints

- Julia compat floor: **1.10** (`Project.toml`). No new package dependencies (PrettyTables is explicitly out of scope).
- **Type stability is enforced in tests** — `test/runtests.jl` sets DispatchDoctor `instability_check => "error"`. New functions must be type-stable; if DispatchDoctor flags one, annotate that specific function with `@unstable` (imported at the top of `TableUtils.jl` — add `using DispatchDoctor: @unstable` if not present) rather than loosening types elsewhere.
- **Blue style** formatting (`.JuliaFormatter.toml`). Run `julia -e 'using JuliaFormatter; format("src"); format("test")'` before each commit if available.
- **`--plain` / `plain=true` must reproduce legacy `create_table` output byte-for-byte.** This is the regression anchor.
- String assertions in tests use the whitespace-insensitive `Base.isapprox(::String,::String)` from `test/utils.jl` (`include("utils.jl")`), so `≈` ignores spacing/alignment but not other characters.
- Data shape: `combined_results::OrderedDict{String,OrderedDict}` keyed by revision label → benchmark-name → stats `Dict` with `"median"`, optionally `"25"`/`"75"` (only when >1 sample), and for memory `"memory"` (bytes) / `"allocs"` (which may be `nothing`). `"time_to_load"` is a benchmark key that must always sort last.
- Change semantics: baseline = first revision, candidate = second. `Change = (candidate − baseline)/baseline`; positive = regression (slower/more memory), negative = improvement.

---

## File Structure

- `src/TableUtils.jl` — **modified**. Add pure helpers (`BenchChange`, `compute_change`, `format_change`, `verdict_line`, `_mark`, `format_time_median`, `format_memory_pretty`, `_ordered_keys`, `_cell`, `_rich_table`); refactor `create_table` into a dispatcher + renamed legacy body `_plain_table`.
- `src/BenchPkgTable.jl` — **modified**. Add `--plain`/`--threshold` options; thread into `create_table`.
- `src/BenchPkg.jl` — **modified**. Add `--plain`/`--threshold` options; thread into the final `create_table` print.
- `action.yml` — **modified**. Remove the per-mode `<details><summary>…</summary>` wrapper in "Create comment body".
- `test/runtests.jl` — **modified**. Switch the existing 2-revision exact-string assertions to `plain=true`; add new `@testitem`s for `compute_change`, formatting helpers, and rich `create_table`.
- `README.md` — **modified**. Document the new default output, `--plain`, `--threshold`; update the CI "collapsible tables" wording.

---

## Task 1: Change computation (`compute_change`)

**Files:**
- Modify: `src/TableUtils.jl` (add near the top, after the `using`/unit blocks)
- Test: `test/runtests.jl` (new `@testitem`)

**Interfaces:**
- Consumes: nothing (pure).
- Produces:
  - `struct BenchChange; change::Union{Float64,Missing}; dir::Symbol; significant::Bool; end`
  - `compute_change(base::AbstractDict, cand::AbstractDict; key::String, threshold::Float64)::BenchChange` — `dir ∈ (:regression, :improvement, :none, :na)`. Noise gate applies only when `key == "median"` and both revisions carry `"25"`/`"75"`; otherwise significance is threshold-only. Returns `dir=:na, significant=false` when either value is missing/`nothing` or the baseline is `0`.

- [ ] **Step 1: Write the failing test**

Add to `test/runtests.jl`:

```julia
@testitem "compute_change significance" begin
    using AirspeedVelocity
    const TU = AirspeedVelocity.TableUtils

    # Clear regression: +40%, well outside noise
    bc = TU.compute_change(
        Dict("median" => 100.0, "25" => 95.0, "75" => 105.0),
        Dict("median" => 140.0, "25" => 135.0, "75" => 145.0);
        key="median", threshold=0.1,
    )
    @test bc.dir == :regression
    @test bc.significant
    @test isapprox(bc.change, 0.4; atol=1e-9)

    # Clear improvement: -30%
    bc = TU.compute_change(
        Dict("median" => 100.0, "25" => 95.0, "75" => 105.0),
        Dict("median" => 70.0, "25" => 65.0, "75" => 75.0);
        key="median", threshold=0.1,
    )
    @test bc.dir == :improvement
    @test bc.significant

    # Big % but swamped by noise -> not significant
    bc = TU.compute_change(
        Dict("median" => 100.0, "25" => 0.0, "75" => 200.0),
        Dict("median" => 140.0, "25" => 40.0, "75" => 240.0);
        key="median", threshold=0.1,
    )
    @test bc.dir == :regression
    @test !bc.significant

    # Missing IQR -> noise gate skipped, threshold-only
    bc = TU.compute_change(
        Dict("median" => 100.0), Dict("median" => 140.0);
        key="median", threshold=0.1,
    )
    @test bc.significant

    # Below threshold -> not significant
    bc = TU.compute_change(
        Dict("median" => 100.0), Dict("median" => 103.0);
        key="median", threshold=0.1,
    )
    @test !bc.significant

    # Zero baseline -> :na
    bc = TU.compute_change(
        Dict("median" => 0.0), Dict("median" => 5.0);
        key="median", threshold=0.1,
    )
    @test bc.dir == :na
    @test ismissing(bc.change)
    @test !bc.significant

    # Memory: threshold-only (no noise gate), +20% is significant
    bc = TU.compute_change(
        Dict("memory" => 1000.0, "allocs" => 5),
        Dict("memory" => 1200.0, "allocs" => 5);
        key="memory", threshold=0.1,
    )
    @test bc.dir == :regression
    @test bc.significant

    # Memory: +5% not significant
    bc = TU.compute_change(
        Dict("memory" => 1000.0), Dict("memory" => 1050.0);
        key="memory", threshold=0.1,
    )
    @test !bc.significant
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `julia --project=. -e 'using TestItemRunner; @run_package_tests filter=ti->occursin("compute_change", ti.name)'`
Expected: FAIL — `UndefVarError: compute_change` (or `type AirspeedVelocity.TableUtils has no field compute_change`).

- [ ] **Step 3: Write minimal implementation**

In `src/TableUtils.jl`, after the unit-scale helpers (around line 69, before `_get_script` has no place here — insert after `get_reasonable_allocs_unit` definition), add:

```julia
struct BenchChange
    change::Union{Float64,Missing}
    dir::Symbol
    significant::Bool
end

_half_iqr(d::AbstractDict) =
    (haskey(d, "75") && haskey(d, "25")) ? (Float64(d["75"]) - Float64(d["25"])) / 2 : missing

function compute_change(
    base::AbstractDict, cand::AbstractDict; key::String, threshold::Float64
)
    b = get(base, key, missing)
    c = get(cand, key, missing)
    if ismissing(b) || ismissing(c) || b === nothing || c === nothing || b == 0
        return BenchChange(missing, :na, false)
    end
    bf = Float64(b)
    cf = Float64(c)
    change = (cf - bf) / bf
    dir = change > 0 ? :regression : change < 0 ? :improvement : :none
    outside = if key == "median"
        eb = _half_iqr(base)
        ec = _half_iqr(cand)
        (ismissing(eb) || ismissing(ec)) ? true : abs(cf - bf) > sqrt(eb^2 + ec^2)
    else
        true
    end
    significant = abs(change) >= threshold && outside && dir != :none
    return BenchChange(change, dir, significant)
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `julia --project=. -e 'using TestItemRunner; @run_package_tests filter=ti->occursin("compute_change", ti.name)'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/TableUtils.jl test/runtests.jl
git commit -m "feat: add compute_change with significance gate"
```

---

## Task 2: Formatting helpers

**Files:**
- Modify: `src/TableUtils.jl`
- Test: `test/runtests.jl` (new `@testitem`)

**Interfaces:**
- Consumes: `BenchChange` (Task 1); `get_reasonable_time_unit`, `get_time_unit_scale`, `get_reasonable_allocs_unit`, `get_reasonable_memory_unit` (already imported).
- Produces:
  - `_mark(dir::Symbol, emoji::Bool)::String`
  - `format_change(bc::BenchChange; bold::Bool)::String` — `"**+40%**"`, `"-5.0%"`, `"0%"`, `"—"`.
  - `verdict_line(n_reg::Int, n_faster::Int, n_unchanged::Int; key::String, threshold::Float64, emoji::Bool)::String`
  - `format_time_median(val; time_unit::Union{Nothing,Symbol}=nothing)::String` — median only, no `± IQR`.
  - `format_memory_pretty(val)::String` — `"10 allocs · 4.53 kB"`; `""` when unavailable.

- [ ] **Step 1: Write the failing test**

Add to `test/runtests.jl`:

```julia
@testitem "formatting helpers" begin
    using AirspeedVelocity
    const TU = AirspeedVelocity.TableUtils

    reg = TU.BenchChange(0.4, :regression, true)
    imp = TU.BenchChange(-0.3, :improvement, true)
    small = TU.BenchChange(0.015, :regression, false)
    zero = TU.BenchChange(0.0, :none, false)
    na = TU.BenchChange(missing, :na, false)

    @test TU.format_change(reg; bold=true) == "**+40%**"
    @test TU.format_change(imp; bold=true) == "**-30%**"
    @test TU.format_change(small; bold=false) == "+1.5%"
    @test TU.format_change(zero; bold=false) == "0%"
    @test TU.format_change(na; bold=false) == "—"

    @test TU._mark(:regression, true) == "🔴"
    @test TU._mark(:improvement, true) == "🟢"
    @test TU._mark(:none, true) == "➖"

    v = TU.verdict_line(1, 1, 1; key="median", threshold=0.1, emoji=true)
    @test occursin("**Time**", v)
    @test occursin("🔴 1 regression", v)
    @test occursin("🟢 1 faster", v)
    @test occursin("➖ 1 unchanged", v)

    v2 = TU.verdict_line(0, 0, 2; key="median", threshold=0.1, emoji=true)
    @test occursin("➖ 2 benchmarks, none beyond ±10%", v2)

    vm = TU.verdict_line(2, 0, 0; key="memory", threshold=0.1, emoji=true)
    @test occursin("**Memory**", vm)
    @test occursin("🔴 2 regressions", vm)

    @test TU.format_time_median(Dict("median" => 1.2e9)) == "1.2 s"
    @test TU.format_time_median(missing) == ""
    @test TU.format_memory_pretty(Dict("allocs" => 10, "memory" => 4.53 * 1024)) ==
        "10 allocs · 4.53 kB"
    @test TU.format_memory_pretty(missing) == ""
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `julia --project=. -e 'using TestItemRunner; @run_package_tests filter=ti->occursin("formatting helpers", ti.name)'`
Expected: FAIL — `format_change` undefined.

- [ ] **Step 3: Write minimal implementation**

In `src/TableUtils.jl`, after the Task 1 additions, add:

```julia
function _mark(dir::Symbol, emoji::Bool)
    if emoji
        return dir === :regression ? "🔴" : dir === :improvement ? "🟢" : "➖"
    else
        return dir === :regression ? "^" : dir === :improvement ? "v" : "-"
    end
end

function format_change(bc::BenchChange; bold::Bool)
    ismissing(bc.change) && return "—"
    pct = bc.change * 100
    s = abs(pct) < 10 ? @sprintf("%+.1f%%", pct) : @sprintf("%+.0f%%", pct)
    if s == "+0.0%" || s == "-0.0%"
        s = "0%"
    end
    return bold ? "**" * s * "**" : s
end

function verdict_line(
    n_reg::Int, n_faster::Int, n_unchanged::Int; key::String, threshold::Float64, emoji::Bool
)
    label = key == "memory" ? "Memory" : "Time"
    non_m = _mark(:none, emoji)
    if n_reg == 0 && n_faster == 0
        pct = round(Int, threshold * 100)
        noun = n_unchanged == 1 ? "benchmark" : "benchmarks"
        return "**$label** — $non_m $n_unchanged $noun, none beyond ±$pct%"
    end
    reg_m = _mark(:regression, emoji)
    imp_m = _mark(:improvement, emoji)
    reg = "$reg_m $n_reg regression" * (n_reg == 1 ? "" : "s")
    fast = "$imp_m $n_faster faster"
    unch = "$non_m $n_unchanged unchanged"
    return "**$label** — $reg · $fast · $unch"
end

function format_time_median(val::Dict; time_unit::Union{Nothing,Symbol}=nothing)
    if time_unit === nothing
        unit, unit_name = get_reasonable_time_unit([val["median"]])
    else
        unit, unit_name = get_time_unit_scale(time_unit)
    end
    return @sprintf("%.3g %s", val["median"] * unit, unit_name)
end
format_time_median(::Missing; time_unit::Union{Nothing,Symbol}=nothing) = ""

function format_memory_pretty(val::Dict)
    allocs = get(val, "allocs", nothing)
    memory = get(val, "memory", nothing)
    (isnothing(allocs) || isnothing(memory)) && return ""
    au, an = get_reasonable_allocs_unit(allocs)
    mu, mn = get_reasonable_memory_unit(memory)
    allocs_str = @sprintf("%.3g%s", allocs * au, an)
    return @sprintf("%s allocs · %.3g %s", allocs_str, memory * mu, mn)
end
format_memory_pretty(::Missing) = ""
```

- [ ] **Step 4: Run test to verify it passes**

Run: `julia --project=. -e 'using TestItemRunner; @run_package_tests filter=ti->occursin("formatting helpers", ti.name)'`
Expected: PASS.

Note: if the `"10 allocs · 4.53 kB"` assertion fails on the allocs token (e.g. `"10.0 allocs"`), confirm `@sprintf("%.3g%s", 10.0, "")` yields `"10"`; adjust only if the platform prints differently — the `%.3g` of `10.0` is `"10"`.

- [ ] **Step 5: Commit**

```bash
git add src/TableUtils.jl test/runtests.jl
git commit -m "feat: add change/verdict/cell formatting helpers"
```

---

## Task 3: Rich `create_table` renderer + `--plain` dispatch

**Files:**
- Modify: `src/TableUtils.jl:78-182` (`create_table`) and add `_ordered_keys`, `_cell`, `_rich_table`
- Modify: `test/runtests.jl:216-234` (switch 2-rev exact assertions to `plain=true`) and add a rich `@testitem`

**Interfaces:**
- Consumes: `compute_change` (Task 1); `format_change`, `verdict_line`, `_mark`, `format_time_median`, `format_memory_pretty` (Task 2); existing `markdown_table`.
- Produces: `create_table(combined_results; key="median", add_ratio_col=true, time_unit=nothing, formatter=nothing, plain::Bool=false, significance_threshold::Float64=0.10, emoji::Bool=true)::String`. Dispatches to legacy `_plain_table` when `plain` or `length(combined_results) != 2`; otherwise the 2-revision rich renderer.

- [ ] **Step 1: Update existing legacy tests to pin `plain=true`, then write the failing rich test**

In `test/runtests.jl`, in the `@testitem "Test table generation"` block, change the two 2-revision assertions to request plain output. Replace line 223:

```julia
    @test truth ≈ create_table(combined_results; plain=true)
```

and replace lines 232-234:

```julia
    @test truth ≈ create_table(
        combined_results;
        formatter=AirspeedVelocity.TableUtils.format_memory,
        key="memory",
        plain=true,
    )
```

(The single-revision `benchpkgtable` assertion later in the same block needs no change — 1 revision auto-falls back to plain.)

Then add a new rich test:

```julia
@testitem "rich table generation" begin
    using AirspeedVelocity
    using OrderedCollections: OrderedDict
    include("utils.jl")

    combined_results = OrderedDict(
        "v1" => OrderedDict(
            "bench1" => Dict("median" => 1.2e9, "75" => 1.3e9, "25" => 1.1e9),
            "bench2" => Dict("median" => 2.0e5, "75" => 3.0e5, "25" => 1.0e5),
        ),
        "v2" => OrderedDict(
            "bench1" => Dict("median" => 1.2e10, "75" => 1.3e10, "25" => 1.1e10),
            "bench2" => Dict("median" => 2.0e4, "75" => 3.0e4, "25" => 1.0e4),
            "bench3" => Dict("median" => 2.0e4, "75" => 3.0e4, "25" => 1.0e4),
        ),
    )

    t = create_table(combined_results)  # rich is now the default for 2 revisions
    @test occursin("**Time** — 🔴 1 regression · 🟢 1 faster · ➖ 1 unchanged", t)
    @test occursin("🔴 bench1", t)
    @test occursin("**+900%**", t)
    @test occursin("🟢 bench2", t)
    @test occursin("**-90%**", t)
    @test occursin("<details><summary>➖ 1 unchanged benchmark</summary>", t)
    @test occursin("bench3", t)
    @test occursin("</details>", t)
    # significant rows are above the collapsed section
    @test findfirst("🔴 bench1", t)[1] < findfirst("<details>", t)[1]

    # All-quiet case collapses everything into one <details>
    quiet = OrderedDict(
        "v1" => OrderedDict(
            "a" => Dict("median" => 100.0, "75" => 110.0, "25" => 90.0),
            "b" => Dict("median" => 100.0, "75" => 110.0, "25" => 90.0),
        ),
        "v2" => OrderedDict(
            "a" => Dict("median" => 103.0, "75" => 113.0, "25" => 93.0),
            "b" => Dict("median" => 101.0, "75" => 111.0, "25" => 91.0),
        ),
    )
    q = create_table(quiet)
    @test occursin("➖ 2 benchmarks, none beyond ±10%", q)
    @test occursin("<details>", q)

    # >2 revisions falls back to plain (has the ratio-style header, no verdict)
    three = OrderedDict(
        "v1" => OrderedDict("a" => Dict("median" => 100.0)),
        "v2" => OrderedDict("a" => Dict("median" => 100.0)),
        "v3" => OrderedDict("a" => Dict("median" => 100.0)),
    )
    f = create_table(three)
    @test !occursin("**Time**", f)
end
```

- [ ] **Step 2: Run tests to verify the rich test fails**

Run: `julia --project=. -e 'using TestItemRunner; @run_package_tests filter=ti->occursin("rich table generation", ti.name)'`
Expected: FAIL — no verdict line emitted (current `create_table` produces the legacy table for 2 revisions).

- [ ] **Step 3: Refactor `create_table` and add the rich renderer**

In `src/TableUtils.jl`, rename the existing `function create_table(...)` body to `_plain_table` by changing its signature line (currently line 78) from:

```julia
function create_table(
    combined_results::OrderedDict;
    key="median",
    add_ratio_col=true,
    time_unit::Union{Nothing,Symbol}=nothing,
    formatter=nothing,
)
```

to:

```julia
function _plain_table(
    combined_results::OrderedDict;
    key="median",
    add_ratio_col=true,
    time_unit::Union{Nothing,Symbol}=nothing,
    formatter=nothing,
)
```

Leave the rest of that function body unchanged. Then add the new dispatcher and helpers immediately above `_plain_table`:

```julia
"""
    create_table(combined_results::OrderedDict; kws...)

Render a markdown comparison table. By default (exactly two revisions), emits the
rich format: a verdict headline, significant benchmarks with 🔴/🟢 markers, and a
collapsible `<details>` section for unchanged benchmarks. Pass `plain=true` for the
legacy per-revision table with a ratio column. With a number of revisions other than
two, always falls back to the legacy table.

Keyword arguments: `key` ("median" or "memory"), `add_ratio_col`, `time_unit`,
`formatter` (legacy path only); `plain`, `significance_threshold` (default 0.10),
`emoji` (rich path only).
"""
function create_table(
    combined_results::OrderedDict;
    key="median",
    add_ratio_col=true,
    time_unit::Union{Nothing,Symbol}=nothing,
    formatter=nothing,
    plain::Bool=false,
    significance_threshold::Float64=0.10,
    emoji::Bool=true,
)
    if plain || length(combined_results) != 2
        return _plain_table(
            combined_results;
            key=key,
            add_ratio_col=add_ratio_col,
            time_unit=time_unit,
            formatter=formatter,
        )
    end
    return _rich_table(
        combined_results;
        key=key,
        time_unit=time_unit,
        threshold=significance_threshold,
        emoji=emoji,
    )
end

function _ordered_keys(combined_results::OrderedDict)
    all_keys = [keys(first(values(combined_results)))...]
    for extra_key in union([keys(v) for v in values(combined_results)]...)
        in(extra_key, all_keys) || push!(all_keys, extra_key)
    end
    if in("time_to_load", all_keys)
        deleteat!(all_keys, findfirst(==("time_to_load"), all_keys))
        push!(all_keys, "time_to_load")
    end
    return all_keys
end

function _cell(val, key::String, time_unit::Union{Nothing,Symbol}, rowname::String)
    ismissing(val) && return ""
    if key == "memory"
        return format_memory_pretty(val)
    else
        tu = rowname == "time_to_load" ? nothing : time_unit
        return format_time_median(val; time_unit=tu)
    end
end

function _rich_table(
    combined_results::OrderedDict;
    key::String,
    time_unit::Union{Nothing,Symbol},
    threshold::Float64,
    emoji::Bool,
)
    revs = collect(keys(combined_results))
    base_res = combined_results[revs[1]]
    cand_res = combined_results[revs[2]]
    all_keys = _ordered_keys(combined_results)

    cutoff = 14
    trunc(h) = length(h) <= cutoff ? h : first(h, cutoff) * "..."
    header = String["Benchmark", trunc(string(revs[1])), trunc(string(revs[2])), "Change"]

    sig = Tuple{Bool,Float64,Vector{String}}[]  # (is_time_to_load, |change|, row)
    unc = Vector{String}[]
    n_reg = 0
    n_faster = 0
    for k in all_keys
        c1 = _cell(get(base_res, k, missing), key, time_unit, k)
        c2 = _cell(get(cand_res, k, missing), key, time_unit, k)
        if !(haskey(base_res, k) && haskey(cand_res, k))
            push!(unc, String[k, c1, c2, ""])
            continue
        end
        bc = compute_change(base_res[k], cand_res[k]; key=key, threshold=threshold)
        if bc.significant
            row = String["$(_mark(bc.dir, emoji)) $k", c1, c2, format_change(bc; bold=true)]
            push!(sig, (k == "time_to_load", abs(bc.change), row))
            bc.dir === :regression ? (n_reg += 1) : (n_faster += 1)
        else
            push!(unc, String[k, c1, c2, format_change(bc; bold=false)])
        end
    end

    # worst-first, but time_to_load pinned to the end of the significant table
    sort!(sig; by=t -> (t[1], -t[2]))
    sig_rows = [t[3] for t in sig]
    n_unchanged = length(unc)

    io = IOBuffer()
    println(
        io,
        verdict_line(n_reg, n_faster, n_unchanged; key=key, threshold=threshold, emoji=emoji),
    )
    println(io)
    if !isempty(sig_rows)
        print(io, markdown_table(; data=permutedims(hcat(sig_rows...)), header=header))
        println(io)
    end
    if n_unchanged > 0
        noun = n_unchanged == 1 ? "unchanged benchmark" : "unchanged benchmarks"
        println(io, "<details><summary>$(_mark(:none, emoji)) $n_unchanged $noun</summary>")
        println(io)
        print(io, markdown_table(; data=permutedims(hcat(unc...)), header=header))
        println(io)
        println(io, "</details>")
    end
    return String(take!(io))
end
```

- [ ] **Step 4: Run the rich test and the legacy test together**

Run: `julia --project=. -e 'using TestItemRunner; @run_package_tests filter=ti->occursin("table generation", ti.name)'`
Expected: PASS for both `Test table generation` (now `plain=true`) and `rich table generation`.

If DispatchDoctor raises an instability error for `_rich_table` or `_cell`, annotate that function with `@unstable` (add `using DispatchDoctor: @unstable` to the top of `TableUtils.jl` if absent) and re-run.

- [ ] **Step 5: Commit**

```bash
git add src/TableUtils.jl test/runtests.jl
git commit -m "feat: rich create_table with verdict, markers, and collapse"
```

---

## Task 4: CLI flags (`--plain`, `--threshold`)

**Files:**
- Modify: `src/BenchPkgTable.jl:42-89`
- Modify: `src/BenchPkg.jl:52-116`
- Test: `test/runtests.jl` (new `@testitem` driving `benchpkgtable` via `redirect_stdout`)

**Interfaces:**
- Consumes: `create_table` rich/plain dispatch (Task 3).
- Produces: `benchpkgtable(...; plain::Bool=false, threshold::Float64=0.1, ...)` and `benchpkg(...; plain::Bool=false, threshold::Float64=0.1, ...)` passing `plain=plain, significance_threshold=threshold` into `create_table`.

- [ ] **Step 1: Write the failing test**

Add to `test/runtests.jl`:

```julia
@testitem "benchpkgtable plain vs rich flag" begin
    using AirspeedVelocity
    include("utils.jl")

    tmpdir = mktempdir()
    for (rev, base) in (("v1", 1000), ("v2", 2000))
        open(joinpath(tmpdir, "results_TestPackage@$rev.json"), "w") do io
            # one benchmark "b" whose times differ 2x between v1 and v2
            write(
                io,
                """{"tags":[],"data":{"b":{"times":[$base,$base,$base,$base,$base]}}}""",
            )
        end
    end

    grab(f) = begin
        orig = stdout
        (rd, wr) = redirect_stdout()
        f()
        redirect_stdout(orig)
        close(wr)
        read(rd, String)
    end

    rich = grab(() -> benchpkgtable("TestPackage"; rev="v1,v2", input_dir=tmpdir))
    @test occursin("**Time**", rich)          # verdict headline present
    @test occursin("🔴", rich)                 # v1->v2 is a 2x slowdown

    plain = grab(() -> benchpkgtable("TestPackage"; rev="v1,v2", input_dir=tmpdir, plain=true))
    @test !occursin("**Time**", plain)        # legacy table, no verdict
    @test occursin("| v1 ", plain) || occursin("v1 ", plain)
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `julia --project=. -e 'using TestItemRunner; @run_package_tests filter=ti->occursin("plain vs rich flag", ti.name)'`
Expected: FAIL — `benchpkgtable` has no keyword `plain`.

- [ ] **Step 3: Add the options to `benchpkgtable`**

In `src/BenchPkgTable.jl`, extend the signature (lines 42-51) to add two options:

```julia
Comonicon.@main function benchpkgtable(
    package_name::String="";
    rev::String="dirty,{DEFAULT}",
    input_dir::String=".",
    ratio::Bool=false,
    mode::String="time",
    force_time_unit::String="",
    url::String="",
    path::String="",
    plain::Bool=false,
    threshold::Float64=0.1,
)
```

and thread them into the `create_table` call inside the `for m in modes` loop (lines 78-85):

```julia
        println(
            create_table(
                combined_results;
                add_ratio_col=ratio,
                key=translate_mode(m),
                time_unit=effective_time_unit,
                plain=plain,
                significance_threshold=threshold,
            ),
        )
```

Also add to the docstring (after the `--force-time-unit` option, and under `# Flags`):

```
- `--threshold <arg>`: Relative change (e.g. 0.1 = 10%) required, in addition to
  exceeding measurement noise, to flag a benchmark as a regression/improvement
  in the default (rich) output (default: 0.1).
```

and under `# Flags`:

```
- `--plain`: Emit the legacy per-revision table with a ratio column instead of the
  rich comparison output (default: false).
```

- [ ] **Step 4: Add the options to `benchpkg`**

In `src/BenchPkg.jl`, extend the signature (lines 52-66) to add:

```julia
    dont_print::Bool=false,
    plain::Bool=false,
    threshold::Float64=0.1,
)
```

and update the final print (lines 108-113) to:

```julia
    if !dont_print
        combined_results = load_results(package_name, revs; input_dir=output_dir)
        println(
            create_table(
                combined_results;
                add_ratio_col=length(revs) == 2,
                key="median",
                plain=plain,
                significance_threshold=threshold,
            ),
        )
    end
```

Add matching docstring entries under `# Options`:

```
- `--threshold <arg>`: Relative change (e.g. 0.1 = 10%) required, in addition to
  exceeding measurement noise, to flag a benchmark in the rich output (default: 0.1).
```

and under `# Flags`:

```
- `--plain`: Emit the legacy table instead of the rich comparison output (default: false).
```

- [ ] **Step 5: Run test to verify it passes**

Run: `julia --project=. -e 'using TestItemRunner; @run_package_tests filter=ti->occursin("plain vs rich flag", ti.name)'`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/BenchPkgTable.jl src/BenchPkg.jl test/runtests.jl
git commit -m "feat: add --plain and --threshold to benchpkg CLIs"
```

---

## Task 5: Action comment assembly + documentation

**Files:**
- Modify: `action.yml:144-167` ("Create comment body" step)
- Modify: `README.md` (CLI reference + CI section wording)

**Interfaces:**
- Consumes: rich `benchpkgtable` output (Task 4). No Julia interface produced.

- [ ] **Step 1: Simplify the comment body assembly**

In `action.yml`, replace the "Create comment body" `run` block (lines 148-173) so it no longer wraps each mode in `<details>` (Julia now emits the verdict + inner collapse):

```yaml
      run: |
        echo "## Benchmark Results (Julia v${{ inputs.julia-version }})" > body.md
        echo "" >> body.md

        # One section per requested mode; benchpkgtable emits the verdict headline
        # and its own collapsible section for unchanged benchmarks.
        IFS=',' read -ra MODES <<< "${{ inputs.mode }}"
        for m in "${MODES[@]}"; do
          {
            benchpkgtable "${{ steps.pkg.outputs.package_name }}" \
              --input-dir=results/ \
              --mode=$m \
              --ratio \
              ${{ steps.flags.outputs.table_args }}
            echo ""
          } >> body.md
        done

        if [[ "${{ inputs.enable-plots }}" == 'true' ]]; then
          {
            echo 'A plot of the benchmark results has been uploaded as an artifact at ${{ steps.artifact-upload-step.outputs.artifact-url }}.'
          } >> body.md
        fi
```

- [ ] **Step 2: Update the README**

In `README.md`:

- Update the CI paragraph that says "separate, collapsible tables for runtime and memory" (~line 110) to describe the new behavior, e.g.:

  > Both workflows run AirspeedVelocity and display results with a verdict headline per mode (time/memory) — significant regressions and improvements are shown up front with 🔴/🟢 markers, and unchanged benchmarks are tucked into a collapsible section.

- In the `benchpkg` and `benchpkgtable` CLI reference blocks, add the `[--plain]` flag and `[--threshold <arg>]` option lines to the usage synopsis and the Options/Flags lists, matching the docstrings added in Task 4.

- [ ] **Step 3: Verify the full test suite still passes**

Run: `julia --color=yes --project=. -e 'using Pkg; Pkg.test()'`
Expected: PASS (all `@testitem`s, including the updated legacy `plain=true` assertions).

Note: this runs the slow integration tests that download SymbolicRegression.jl; allow several minutes and network access. To check only the table logic quickly, filter: `@run_package_tests filter=ti->occursin("table", ti.name) || occursin("compute_change", ti.name) || occursin("formatting", ti.name)`.

- [ ] **Step 4: Commit**

```bash
git add action.yml README.md
git commit -m "feat: emit rich benchmark comment; document --plain/--threshold"
```

---

## Self-Review

**Spec coverage:**
- Signed `Change` column, no `± IQR` in cells → Task 2 (`format_change`, `format_time_median`), Task 3 (`_cell`). ✓
- Significance = ≥threshold AND outside noise; memory threshold-only; zero baseline; missing IQR → Task 1. ✓
- Verdict headline + emoji + collapse; worst-first sort; `time_to_load` pinned → Task 2 (`verdict_line`), Task 3 (`_rich_table`). ✓
- New default + `--plain` + `--threshold`; `create_table` back-compatible via new kwargs → Task 3 (dispatch), Task 4 (CLI). ✓
- `>2` revisions plain fallback → Task 3 dispatch + test. ✓
- Memory cell tidy (`10 allocs · 4.53 kB`), blank → `—`/`""` → Task 2 (`format_memory_pretty`), Task 3. ✓
- `action.yml` drops per-mode `<details>` → Task 5. ✓
- Legacy output byte-identical under `--plain` → Task 3 (renamed `_plain_table`, existing tests pinned to `plain=true`). ✓
- README + CLI docs → Task 4 docstrings, Task 5. ✓
- Units unchanged (out of scope) → legacy path & `format_time_median` reuse existing unit helpers. ✓

**Placeholder scan:** No TBD/TODO; every code step shows full code and exact run commands. ✓

**Type consistency:** `BenchChange` fields and `compute_change`/`format_change`/`verdict_line`/`_mark`/`_cell`/`_rich_table` signatures are identical across Tasks 1–3; CLI kwargs `plain`/`threshold` map to `plain`/`significance_threshold` consistently in Task 4. ✓
