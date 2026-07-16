module TableUtils

using ..Utils:
    get_reasonable_time_unit,
    get_reasonable_allocs_unit,
    get_reasonable_memory_unit,
    get_time_unit_scale
using OrderedCollections: OrderedDict
using Printf: @sprintf

"""
    format_time(val::Dict; time_unit=nothing)

Format a time value with optional fixed unit. When `time_unit` is `nothing`,
the unit is automatically chosen based on the magnitude.
Valid time units: "ns", "μs", "ms", "s", "h" (and `:us` is accepted as an alias for `"μs"`).
"""
function format_time(val::Dict; time_unit::Union{Nothing,Symbol}=nothing)
    if time_unit === nothing
        unit, unit_name = get_reasonable_time_unit([val["median"]])
    else
        unit, unit_name = get_time_unit_scale(time_unit)
    end
    if haskey(val, "75")
        @sprintf(
            "%.3g ± %.2g %s",
            val["median"] * unit,
            (val["75"] - val["25"]) * unit,
            unit_name
        )
    else
        @sprintf("%.3g %s", val["median"] * unit, unit_name)
    end
end

function format_time(::Missing; time_unit::Union{Nothing,Symbol}=nothing)
    return ""
end

function format_memory(val::Dict)
    allocs, memory = get(val, "allocs", nothing), get(val, "memory", nothing)
    if !isnothing(allocs) && !isnothing(memory)
        allocs_unit, allocs_unit_name = get_reasonable_allocs_unit(val["allocs"])
        memory_unit, memory_unit_name = get_reasonable_memory_unit(val["memory"])
        @sprintf(
            "%.3g %s allocs: %.3g %s",
            allocs * allocs_unit,
            allocs_unit_name,
            memory * memory_unit,
            memory_unit_name
        )
    else
        ""
    end
end

function format_memory(::Missing)
    return ""
end

struct BenchChange
    change::Union{Float64,Missing}
    dir::Symbol
    significant::Bool
end

function _half_iqr(d::AbstractDict)::Union{Float64,Missing}
    if (haskey(d, "75") && haskey(d, "25"))
        (Float64(d["75"]) - Float64(d["25"])) / 2
    else
        missing
    end
end

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
    dir = if change > 0
        :regression
    elseif change < 0
        :improvement
    else
        :none
    end
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

# Colored status dots (section headers + summary line).
function _dot(kind::Symbol, emoji::Bool)
    if emoji
        return kind === :worse ? "🔴" : kind === :better ? "🟢" : "⚪"
    else
        return kind === :worse ? "!" : kind === :better ? "+" : "="
    end
end

# Per-row direction arrows tracking the metric: up = value increased (slower /
# more memory), down = value decreased (faster / less memory).
function _arrow(kind::Symbol, emoji::Bool)
    if emoji
        return kind === :worse ? "⬆️" : "⬇️"
    else
        return kind === :worse ? "^" : "v"
    end
end

# Section heading label per mode.
function _mode_label(key::String, emoji::Bool)
    if key == "memory"
        return emoji ? "💾 Memory" : "Memory"
    else
        return emoji ? "⏱️ Time" : "Time"
    end
end

# Split a benchmark name into (category, leaf) on the first "/".
function _category(name::String)::String
    i = findfirst('/', name)
    return i === nothing ? "·" : name[1:prevind(name, i)]
end
function _leaf(name::String)::String
    i = findfirst('/', name)
    return i === nothing ? name : name[nextind(name, i):end]
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

"""
    create_table(combined_results::OrderedDict; kws...)

Render a markdown comparison table. By default (exactly two revisions), emits the
rich format: a verdict headline, significant benchmarks with 🔴/🟢 markers, and a
collapsible `<details>` section for unchanged benchmarks. Pass `plain=true` for the
legacy per-revision table with a ratio column. With a number of revisions other than
two, always falls back to the legacy table.

Keyword arguments: `key` ("median" or "memory"), `add_ratio_col`, `time_unit`,
`formatter` (legacy path only); `plain`, `significance_threshold` (default 0.10),
`emoji`, `collapse` (rich path only). When `collapse=true`, every table is placed
inside one collapsible block so only the section header and one-line summary stay
visible (keeping comment size constant).
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
    collapse::Bool=false,
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
        collapse=collapse,
    )
end

function _ordered_keys(combined_results::OrderedDict)::Vector{String}
    all_keys = String[keys(first(values(combined_results)))...]
    for extra_key in union([keys(v) for v in values(combined_results)]...)
        in(extra_key, all_keys) || push!(all_keys, string(extra_key))
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

# Render one status bucket as a markdown table with benchmarks grouped by
# category. The category cell is blanked on repeats so each category reads as a
# visual block.
function _grouped_table(rows::Vector{NTuple{4,String}}, rev1::String, rev2::String)::String
    isempty(rows) && return ""
    header = String["Group", "Benchmark", rev1, rev2, "Change"]
    data = Matrix{String}(undef, length(rows), 5)
    prev = ""
    for (i, row) in enumerate(rows)
        name, c1, c2, chg = row
        cat = _category(name)
        data[i, 1] = cat == prev ? "" : cat
        data[i, 2] = _leaf(name)
        data[i, 3] = c1
        data[i, 4] = c2
        data[i, 5] = chg
        prev = cat
    end
    return markdown_table(; data=data, header=header)
end

function _rich_table(
    combined_results::OrderedDict;
    key::String,
    time_unit::Union{Nothing,Symbol},
    threshold::Float64,
    emoji::Bool,
    collapse::Bool=false,
)
    revs = collect(keys(combined_results))
    base_res = combined_results[revs[1]]
    cand_res = combined_results[revs[2]]

    cutoff = 14
    _abbrev(h) = length(h) <= cutoff ? h : first(h, cutoff) * "..."
    rev1 = _abbrev(string(revs[1]))
    rev2 = _abbrev(string(revs[2]))

    # (is_time_to_load, category, -|change|, row) — sorted so categories cluster,
    # time_to_load sinks to the bottom, and within a category the worst is first.
    Entry = Tuple{Bool,String,Float64,NTuple{4,String}}
    slower = Entry[]
    faster = Entry[]
    unchanged = NTuple{4,String}[]
    for k in _ordered_keys(combined_results)
        c1 = _cell(get(base_res, k, missing), key, time_unit, k)
        c2 = _cell(get(cand_res, k, missing), key, time_unit, k)
        if !(haskey(base_res, k) && haskey(cand_res, k))
            push!(unchanged, (k, c1, c2, "—"))
            continue
        end
        bc = compute_change(base_res[k], cand_res[k]; key=key, threshold=threshold)
        if bc.significant
            arrow = _arrow(bc.dir === :regression ? :worse : :better, emoji)
            row = (k, c1, c2, "$arrow $(format_change(bc; bold=true))")
            entry = (k == "time_to_load", _category(k), -abs(bc.change), row)
            bc.dir === :regression ? push!(slower, entry) : push!(faster, entry)
        else
            push!(unchanged, (k, c1, c2, format_change(bc; bold=false)))
        end
    end
    sort!(slower; by=t -> (t[1], t[2], t[3]))
    sort!(faster; by=t -> (t[1], t[2], t[3]))
    slow_rows = NTuple{4,String}[t[4] for t in slower]
    fast_rows = NTuple{4,String}[t[4] for t in faster]

    n_s = length(slow_rows)
    n_f = length(fast_rows)
    n_u = length(unchanged)
    worse = _dot(:worse, emoji)
    better = _dot(:better, emoji)
    equal = _dot(:equal, emoji)

    # (dot, title, rows) for each populated bucket, in display order.
    buckets = Tuple{String,String,Vector{NTuple{4,String}}}[]
    n_s > 0 && push!(buckets, (worse, "Slower", slow_rows))
    n_f > 0 && push!(buckets, (better, "Faster", fast_rows))
    n_u > 0 && push!(buckets, (equal, "Unchanged", unchanged))

    # Compact vertical summary of the three counts.
    summary = [
        "$worse Slower"    string(n_s)
        "$better Faster"   string(n_f)
        "$equal Unchanged" string(n_u)
    ]

    io = IOBuffer()
    println(io, "### $(_mode_label(key, emoji))")
    println(io)
    print(io, markdown_table(; data=summary, header=String["Result", "Count"]))
    println(io)
    if collapse
        # Summary-only: every table lives inside one collapsible block, so the
        # rendered comment is always the header + one-line summary + toggle.
        println(io, "<details><summary>Details</summary>")
        println(io)
        for (i, (dot, title, rows)) in enumerate(buckets)
            i == 1 || (println(io, "---"); println(io))
            println(io, "#### $dot $title")
            println(io)
            print(io, _grouped_table(rows, rev1, rev2))
            println(io)
        end
        println(io, "</details>")
    else
        # Default: Slower/Faster shown up front, Unchanged tucked into <details>.
        # Each populated bucket is preceded by a horizontal rule.
        for (dot, title, rows) in buckets
            println(io, "---")
            println(io)
            if title == "Unchanged"
                println(io, "<details><summary>$dot $(length(rows)) unchanged</summary>")
                println(io)
                print(io, _grouped_table(rows, rev1, rev2))
                println(io)
                println(io, "</details>")
            else
                println(io, "#### $dot $title")
                println(io)
                print(io, _grouped_table(rows, rev1, rev2))
                println(io)
            end
        end
    end
    return String(take!(io))
end

"""
    _plain_table(combined_results::OrderedDict; kws...)

Legacy renderer: a markdown table of the results loaded from the `load_results`
function. If there are two results for a given benchmark, will have an additional
column for the comparison, assuming the first revision is one to compare against.

The `formatter` keyword argument generates the column value. By default, the table
formats time as the median ± the interquantile range, and formats memory as the number
of allocations and allocated memory.

The `time_unit` keyword argument can be used to specify a fixed time unit for
all benchmark results. Valid values are: `:ns`, `Symbol("μs")`, `:ms`, `:s`, `:h` (and `:us` is accepted as an alias for `Symbol("μs")`).
If not specified (default), the unit is automatically chosen based on the magnitude
of the value. The `time_to_load` benchmark always uses auto-detection regardless
of this setting.
"""
function _plain_table(
    combined_results::OrderedDict;
    key="median",
    add_ratio_col=true,
    time_unit::Union{Nothing,Symbol}=nothing,
    formatter=nothing,
)
    num_revisions = length(combined_results)
    num_cols = 1 + num_revisions
    # Order keys based on first result:
    all_keys = [keys(first(values(combined_results)))...]

    # But, make sure we have all keys:
    for extra_key in union([keys(v) for v in values(combined_results)]...)
        if !in(extra_key, all_keys)
            push!(all_keys, extra_key)
        end
    end

    # Always put `time_to_load` at bottom:
    if in("time_to_load", all_keys)
        deleteat!(all_keys, findfirst(==("time_to_load"), all_keys))
        push!(all_keys, "time_to_load")
    end

    headers = String["", string.(keys(combined_results))...]

    # Cutoff headers if needed:
    cutoff = 14
    headers = String[
        if length(head) <= cutoff
            head
        else
            first(head, cutoff) * "..."
        end for head in headers
    ]

    data_columns = Vector{String}[]

    for result in values(combined_results)
        col = String[]
        for row in all_keys
            val = get(result, row, missing)
            if formatter !== nothing
                push!(col, formatter(val))
            else
                if key == "memory"
                    push!(col, format_memory(val))
                elseif key == "median"
                    effective_time_unit = row == "time_to_load" ? nothing : time_unit
                    push!(col, format_time(val; time_unit=effective_time_unit))
                else
                    error("Unknown ratio column: $key")
                end
            end
        end
        push!(data_columns, col)
    end

    if num_revisions == 2 && add_ratio_col
        col = String[]
        results = collect(values(combined_results))

        for benchmark_name in all_keys
            if !all(haskey(r, benchmark_name) for r in results)
                push!(col, "")
                continue
            end

            stats = [r[benchmark_name] for r in results]

            if !all(haskey(s, key) for s in stats)
                push!(col, "")
                continue
            end

            vals = [s[key] for s in stats]

            @assert length(vals) == 2
            ratio = vals[1] / vals[2]

            compute_ratio_err =
                all(haskey(s, "25") && haskey(s, "75") for s in stats) && key == "median"
            ratio_err = if compute_ratio_err
                errs = [max(0.0, s["75"] - s["25"]) for s in stats]
                abs(ratio) * sqrt((errs[1] / vals[1])^2 + (errs[2] / vals[2])^2)
            else
                NaN
            end
            string_ratio = join((
                isfinite(ratio) ? @sprintf("%.3g", ratio) : "",
                isfinite(ratio_err) ? @sprintf(" ± %.2g", ratio_err) : "",
            ))

            push!(col, string_ratio)
        end
        push!(data_columns, col)
        push!(headers, "$(headers[2]) / $(headers[3])")
        num_cols += 1
    end

    mdata = hcat(string.(all_keys), data_columns...)
    # With headers and data, let's make a markdown table
    return markdown_table(; data=mdata, header=headers)
end

function markdown_table(; data::AbstractMatrix, header::AbstractVector)
    @assert size(data, 2) == length(header)
    col_widths = [max(length(head), 4) for head in header]
    for row in eachrow(data)
        for (i, val) in enumerate(row)
            col_widths[i] = max(col_widths[i], length(string(val)))
        end
    end
    # GitHub-style markdown table:
    io = IOBuffer()
    print(io, "|")
    for (i, head) in enumerate(header)
        print(io, " $(head) " * " "^(col_widths[i] - length(head)) * "|")
    end
    println(io)

    # First column left-aligned:
    print(io, "|:---" * "-"^(col_widths[1] - 2) * "|")
    # Rest are centered:
    for (i, head) in enumerate(header)
        i == 1 && continue
        print(io, ":---" * "-"^(col_widths[i] - 3) * ":|")
    end

    println(io)
    for row in eachrow(data)
        print(io, "|")
        for (i, val) in enumerate(row)
            print(io, " $(val) " * " "^(col_widths[i] - length(string(val))) * "|")
        end
        println(io)
    end
    return String(take!(io))
end

end # AirspeedVelocity.TableUtils
