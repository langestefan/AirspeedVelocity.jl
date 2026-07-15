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
    _abbrev(h) = length(h) <= cutoff ? h : first(h, cutoff) * "..."
    header = String[
        "Benchmark", _abbrev(string(revs[1])), _abbrev(string(revs[2])), "Change"
    ]

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
