using Test
using Preferences: set_preferences!

set_preferences!(
    "AirspeedVelocity",
    "instability_check" => "error",
    "instability_check_codegen_level" => "min";
    force=true,
)

using AirspeedVelocity

using TestItems: @testitem
using TestItemRunner

@run_package_tests

@testitem "Test run benchmarking" begin
    using AirspeedVelocity

    script_dir = mktempdir()
    output_dir = mktempdir()
    script = joinpath(script_dir, "bench.jl")
    open(script, "w") do io
        write(
            io,
            """
        using BenchmarkTools
        using SymbolicRegression

        @assert PACKAGE_VERSION in (v"0.15.3", v"0.16.2")

        const SUITE = BenchmarkGroup()
        SUITE["eval_tree_array"] = begin
            b = BenchmarkGroup()
            options = Options(; binary_operators=[+, -, *], unary_operators=[cos])
            x, y = Node(; feature=1), Node(; feature=2)
            tree = x + cos(3.2f0 * y)

            X = randn(Float32, 2, 10)
            f() = eval_tree_array(tree, X, options)
            b["eval_10"] = @benchmarkable f() evals=1 samples=100

            X2 = randn(Float32, 2, 20)
            f2() = eval_tree_array(tree, X2, options)
            f2() # warmup
            b["eval_20"] = @benchmarkable f2() evals=1 samples=100

            b
        end
        """,
        )
    end

    results = benchmark(
        "SymbolicRegression", ["v0.15.3", "v0.16.2"]; script=script, output_dir=output_dir
    )
    @test length(results) == 2
    @test "SymbolicRegression@v0.15.3" in keys(results)
    @test "SymbolicRegression@v0.16.2" in keys(results)
    @test length(
        results["SymbolicRegression@v0.15.3"]["data"]["eval_tree_array"]["data"]["eval_10"]["times"],
    ) == 100
    @test length(
        results["SymbolicRegression@v0.16.2"]["data"]["eval_tree_array"]["data"]["eval_10"]["times"],
    ) == 100

    # Create plots:
    combined_results = load_results(
        "SymbolicRegression", ["v0.15.3", "v0.16.2"]; input_dir=output_dir
    )
    plots = combined_plots(combined_results; npart=1)
    @test length(plots) == 3
    plots = combined_plots(combined_results; npart=2)
    @test length(plots) == 2
end

@testitem "Ensure Transducers.jl has its Project.toml copied" begin
    using AirspeedVelocity

    tmpdir = mktempdir()
    script = joinpath(tmpdir, "bench.jl")
    open(script, "w") do io
        write(io, """
            using BenchmarkTools
            using Transducers

            const SUITE = BenchmarkGroup()
            function f()
                return 1:3 |> Map(x -> 2x) |> collect
            end
            SUITE["simple"] = @benchmarkable f()
        """ |> s -> replace(s, r"^\s+" => ""))
    end

    # Test with CLI version:
    output_dir = mktempdir()
    benchpkg(
        "Transducers";
        rev="v0.4.50,v0.4.70",
        script=script,
        tune=true,
        output_dir=output_dir,
    )
    @test isfile(joinpath(output_dir, "results_Transducers@v0.4.50.json"))
    @test isfile(joinpath(output_dir, "results_Transducers@v0.4.70.json"))
end

@testitem "Test getting script" begin
    using AirspeedVelocity

    include("utils.jl")

    tmpdir = mktempdir()
    script_path, project_toml = AirspeedVelocity.Utils._get_script(;
        package_name="Convex", benchmark_on="v0.13.1"
    )

    script_downloaded = open(script_path, "r") do io
        read(io, String)
    end

    # Compare against truth:
    truth = """
    using Pkg
    tempdir = mktempdir()
    Pkg.activate(tempdir)
    Pkg.develop(PackageSpec(path=joinpath(@__DIR__, "..")))
    Pkg.add(["BenchmarkTools", "PkgBenchmark", "MathOptInterface"])
    Pkg.resolve()

    using Convex: Convex, ProblemDepot
    using BenchmarkTools
    using MathOptInterface
    const MOI = MathOptInterface
    const MOIU = MOI.Utilities

    const SUITE = BenchmarkGroup()

    problems =  [
                    "constant_fix!_with_complex_numbers",
                    "affine_dot_multiply_atom",
                    "affine_hcat_atom",
                    "affine_trace_atom",
                    "exp_entropy_atom",
                    "exp_log_perspective_atom",
                    "socp_norm_2_atom",
                    "socp_quad_form_atom",
                    "socp_sum_squares_atom",
                    "lp_norm_inf_atom",
                    "lp_maximum_atom",
                    "sdp_and_exp_log_det_atom",
                    "sdp_norm2_atom",
                    "sdp_lambda_min_atom",
                    "sdp_sum_largest_eigs",
                    "mip_integer_variables",
                ]

    SUITE["formulation"] = ProblemDepot.benchmark_suite(problems) do problem
        model = MOIU.MockOptimizer(MOIU.Model{Float64}())
        Convex.load_MOI_model!(model, problem)
    end
    """
    @test script_downloaded ≈ truth
end

@testitem "Test table generation" begin
    using AirspeedVelocity
    using OrderedCollections: OrderedDict

    include("utils.jl")

    combined_results = OrderedDict(
        "v1" => OrderedDict(
            "bench1" => Dict(
                "median" => 1.2e9,
                "75" => 1.3e9,
                "25" => 1.1e9,
                "memory" => 1e1,
                "allocs" => 1,
            ),
            "bench2" => Dict(
                "median" => 0.2e6,
                "75" => 0.3e6,
                "25" => 0.1e6,
                "memory" => 1024 / 10,
                "allocs" => 1e6,
            ),
            #= We leave out bench3 as a test =#
        ),
        "v2" => OrderedDict(
            "bench1" => Dict(
                "median" => 1.2e10,
                "75" => 1.3e10,
                "25" => 1.1e10,
                "memory" => 1024,
                "allocs" => 2,
            ),
            "bench2" => Dict(
                "median" => 0.2e5,
                "75" => 0.3e5,
                "25" => 0.1e5,
                "memory" => 1024 * 10,
                "allocs" => 3,
            ),
            "bench3" => Dict(
                "median" => 0.2e5,
                "75" => 0.3e5,
                "25" => 0.1e5,
                "memory" => 1024^2 / 10,
                "allocs" => 4,
            ),
        ),
    )

    truth = """
    |        | v1           | v2         | v1 / v2     |
    |:-------|:------------:|:----------:|:-----------:|
    | bench1 | 1.2 ± 0.2 s  | 12 ± 2 s   | 0.1 ± 0.024 |
    | bench2 | 0.2 ± 0.2 ms | 20 ± 20 μs | 10 ± 14     |
    | bench3 |              | 20 ± 20 μs |             |
    """
    @test truth ≈ create_table(combined_results; plain=true)

    truth = """
    |        | v1                 | v2                | v1 / v2 |
    |:-------|:------------------:|:-----------------:|:-------:|
    | bench1 | 1  allocs: 10 B    | 2  allocs: 1 kB   | 0.00977 |
    | bench2 | 1 M allocs: 0.1 kB | 3  allocs: 10 kB  | 0.01    |
    | bench3 |                    | 4  allocs: 0.1 MB |         |
    """
    @test truth ≈ create_table(
        combined_results;
        formatter=AirspeedVelocity.TableUtils.format_memory,
        key="memory",
        plain=true,
    )

    tmpdir = mktempdir()
    results_fname = joinpath(tmpdir, "results_TestPackage@v1.json")

    open(results_fname, "w") do io
        write(
            io,
            """{"tags":[],"data":{"findall":{"tags":[],"data":{"base": {"times":[1, 2, 3]},"xf-array":{"times":[5, 5, 5, 5, 5]},"xf-iter":{"times":[9, 9, 10, 11, 11]}}}}}""",
        )
    end

    original_stdout = stdout

    (rd, wr) = redirect_stdout()
    benchpkgtable("TestPackage"; rev="v1", input_dir=tmpdir)
    redirect_stdout(original_stdout)

    close(wr)
    s = read(rd, String)

    truth = """
    |                  | v1        |
    |:-----------------|:---------:|
    | findall/base     | 2 ± 1 ns  |
    | findall/xf-array | 5 ± 0 ns  |
    | findall/xf-iter  | 10 ± 2 ns |"""

    @test truth ≈ s
end

@testitem "Test table generation with fixed time units" begin
    using AirspeedVelocity
    using OrderedCollections: OrderedDict

    # test data with a range of time scales
    combined_results = OrderedDict(
        "v1" => OrderedDict(
            "fast_bench" => Dict(
                "median" => 100.0,  # 100 ns
                "75" => 120.0,
                "25" => 80.0,
            ),
            "medium_bench" => Dict(
                "median" => 1.5e6,  # 1.5 ms
                "75" => 1.6e6,
                "25" => 1.4e6,
            ),
            "slow_bench" => Dict(
                "median" => 2.0e9,  # 2 s
                "75" => 2.2e9,
                "25" => 1.8e9,
            ),
            "time_to_load" => Dict(
                "median" => 5.0e9,  # 5 s - should always use auto unit
                "75" => 5.5e9,
                "25" => 4.5e9,
            ),
        ),
    )

    # automatic units (default behavior)
    table_auto = create_table(combined_results; add_ratio_col=false)
    @test occursin("0.1 ± 0.04 μs", table_auto)  # fast_bench in μs (auto-selected)
    @test occursin("1.5 ± 0.2 ms", table_auto)   # medium_bench in ms
    @test occursin("2 ± 0.4 s", table_auto)      # slow_bench in s
    @test occursin("5 ± 1 s", table_auto)        # time_to_load in s (auto)

    # (time_unit, expected_fast, expected_medium, expected_slow)
    test_cases = [
        (:ms, "0.0001 ± 4e-05 ms", "1.5 ± 0.2 ms", "2e+03 ± 4e+02 ms"),
        (:us, "0.1 ± 0.04 μs", "1.5e+03 ± 2e+02 μs", "2e+06 ± 4e+05 μs"),
        (:ns, "100 ± 40 ns", "1.5e+06 ± 2e+05 ns", "2e+09 ± 4e+08 ns"),
        (:s, "1e-07 ± 4e-08 s", "0.0015 ± 0.0002 s", "2 ± 0.4 s"),
    ]

    @testset "time_unit=$(t_unit)" for (
        t_unit, expected_fast, expected_medium, expected_slow
    ) in test_cases
        table = create_table(combined_results; add_ratio_col=false, time_unit=t_unit)
        @test occursin(expected_fast, table)    # fast_bench
        @test occursin(expected_medium, table)  # medium_bench
        @test occursin(expected_slow, table)    # slow_bench
        # time_to_load should always remain "5 ± 1 s" regardless of time_unit
        @test occursin("5 ± 1 s", table)        # time_to_load always uses auto unit
    end

    # test that invalid time unit throws an error
    @test_throws ErrorException AirspeedVelocity.Utils.get_time_unit_scale("invalid_unit")
    @test AirspeedVelocity.Utils.get_time_unit_scale("μs") ==
        AirspeedVelocity.Utils.get_time_unit_scale("us")
end

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

    @test TU._dot(:worse, true) == "🔴"
    @test TU._dot(:better, true) == "🟢"
    @test TU._dot(:equal, true) == "⚪"
    @test TU._arrow(:worse, true) == "⬆️"
    @test TU._arrow(:better, true) == "⬇️"

    @test TU._mode_label("median", true) == "⏱️ Time"
    @test TU._mode_label("memory", true) == "💾 Memory"
    @test TU._mode_label("median", false) == "Time"

    @test TU._category("sort/n=1000") == "sort"
    @test TU._leaf("sort/n=1000") == "n=1000"
    @test TU._category("time_to_load") == "·"   # no "/" -> no category
    @test TU._leaf("time_to_load") == "time_to_load"

    @test TU.format_time_median(Dict("median" => 1.2e9)) == "1.2 s"
    @test TU.format_time_median(missing) == ""
    @test TU.format_memory_pretty(Dict("allocs" => 10, "memory" => 4.53 * 1024)) ==
        "10 allocs · 4.53 kB"
    @test TU.format_memory_pretty(missing) == ""
end

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
    @test occursin("### ⏱️ Time", t)
    # vertical summary table of the three counts
    @test occursin(r"🔴 Slower *\| *1", t)
    @test occursin(r"🟢 Faster *\| *1", t)
    @test occursin(r"⚪ Unchanged *\| *1", t)
    @test occursin("#### 🔴 Slower", t)
    @test occursin("#### 🟢 Faster", t)
    @test occursin("⬆️ **+900%**", t)   # bench1 regression: value up = slower
    @test occursin("⬇️ **-90%**", t)    # bench2 improvement: value down = faster
    @test occursin("| Group | Benchmark |", t)   # grouped columns
    @test occursin("<details><summary>⚪ 1 unchanged</summary>", t)
    @test occursin("bench3", t)
    @test occursin("</details>", t)
    # the Slower table appears above the collapsed unchanged section
    @test findfirst("#### 🔴 Slower", t)[1] < findfirst("<details>", t)[1]

    # collapse=true: only the header + one-line summary stay visible; every table
    # (including Slower) lives inside a single <details> block.
    tc = create_table(combined_results; collapse=true)
    @test occursin(r"🔴 Slower *\| *1", tc)
    @test occursin("<details><summary>Details</summary>", tc)
    @test occursin("#### ⚪ Unchanged", tc)   # unchanged shown as a bucket, not nested summary
    @test findfirst("<details>", tc)[1] < findfirst("#### 🔴 Slower", tc)[1]
    # summary table precedes the collapsible block
    @test findfirst("| Result", tc)[1] < findfirst("<details>", tc)[1]

    # All-quiet case: no Slower/Faster tables, everything collapsed
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
    @test occursin(r"🔴 Slower *\| *0", q)
    @test occursin(r"⚪ Unchanged *\| *2", q)
    @test !occursin("#### 🔴 Slower", q)
    @test occursin("<details>", q)

    # >2 revisions falls back to plain (no section header)
    three = OrderedDict(
        "v1" => OrderedDict("a" => Dict("median" => 100.0)),
        "v2" => OrderedDict("a" => Dict("median" => 100.0)),
        "v3" => OrderedDict("a" => Dict("median" => 100.0)),
    )
    f = create_table(three)
    @test !occursin("###", f)
    @test !occursin("Slower", f)
end

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
    @test occursin("### ⏱️ Time", rich)       # rich section header present
    @test occursin(r"🔴 Slower *\| *1", rich)  # v1->v2 is a 2x slowdown

    # mode="time,memory": exercises translate_mode on the comma-split SubStrings
    # (the "memory" mode must render, not throw on a SubString key).
    both = grab(
        () -> benchpkgtable("TestPackage"; rev="v1,v2", input_dir=tmpdir, mode="time,memory")
    )
    @test occursin("### ⏱️ Time", both)
    @test occursin("### 💾 Memory", both)
    @test occursin("---", both)               # sections separated by a rule

    plain = grab(
        () -> benchpkgtable("TestPackage"; rev="v1,v2", input_dir=tmpdir, plain=true)
    )
    @test !occursin("###", plain)             # legacy table, no section header
    @test occursin("v1 ", plain)
end

@testitem "Dirty repo with filter" begin
    using AirspeedVelocity
    using Pkg
    using JSON3

    # Create a package with a dirty repo:
    tmpdir = mktempdir()
    cd(tmpdir)
    Pkg.generate("TestPackage")
    path = joinpath(tmpdir, "TestPackage")
    run(`git -C "$path" init`)
    # write benchmarks.jl in the package:
    script = joinpath(path, "bench.jl")
    open(joinpath(script), "w") do io
        write(
            io,
            """
            using BenchmarkTools
            using TestPackage
            const SUITE = BenchmarkGroup()
            SUITE["cos"] = @benchmarkable cos(x) setup=(x=rand())
            SUITE["sin"] = @benchmarkable sin(x) setup=(x=rand())
            """,
        )
    end
    # place to store the results:
    results_dir = mktempdir(; cleanup=false)
    # test the dirty repo:
    benchpkg(
        "TestPackage";
        rev="dirty",
        script=script,
        path=path,
        output_dir=results_dir,
        filter="cos",
    )
    @test isfile(joinpath(results_dir, "results_TestPackage@dirty.json"))
    # check that only the cos benchmark was run:
    results = JSON3.read(joinpath(results_dir, "results_TestPackage@dirty.json"))
    @test length(keys(results["data"])) == 1
    @test "cos" in keys(results["data"])
end

@testitem "Fill in defaults" begin
    import AirspeedVelocity.Utils: get_package_name_defaults as pkg_defaults

    # Create a temporary directory with a Project.toml
    tmpdir = mktempdir()
    toml_path = joinpath(tmpdir, "Project.toml")
    toml_content = """
    name = "TestPackage"
    """
    write(toml_path, toml_content)

    # Should fill in from file:
    @test pkg_defaults("", "", tmpdir) == ("TestPackage", "", tmpdir)

    # URL and package name
    @test pkg_defaults("TestPackage", "https://github.com/user/repo", "") ==
        ("TestPackage", "https://github.com/user/repo", "")

    # No arguments
    cd(tmpdir) do
        @test pkg_defaults("", "", "") == ("TestPackage", "", ".")
    end

    # Package name, no arguments = leave untouched
    @test pkg_defaults("TestPackage", "", "") == ("TestPackage", "", "")

    # Error cases
    @test_throws ErrorException pkg_defaults("", "https://github.com/user/repo", "")
    @test_throws ErrorException pkg_defaults("", "https://github.com/user/repo", ".")
end

@testitem "Test parse_rev" begin
    using AirspeedVelocity.Utils: parse_rev

    # Setup a temporary directory and initialize a git repository
    tmpdir = mktempdir()
    cd(tmpdir)
    run(`git clone --depth 1 https://github.com/MilesCranmer/AirspeedVelocity.jl .`)

    # Test the parse_rev function
    default_branch = parse_rev("{DEFAULT}", tmpdir)
    @test default_branch == "master"

    other_rev = parse_rev("my-rev", tmpdir)
    @test other_rev == "my-rev"
end

@testset "parse_package_spec" begin
    using Pkg
    using AirspeedVelocity.Utils: parse_package_spec
    @test parse_package_spec("Example") == Pkg.PackageSpec(; name="Example")
    @test parse_package_spec("https://github.com/User/Package.jl") ==
        Pkg.PackageSpec(; url="https://github.com/User/Package.jl")
    @test parse_package_spec(
        "https://github.com/User/Package.jl#deadbeef12341234deadbeef12341234deadbeef"
    ) == Pkg.PackageSpec(;
        url="https://github.com/User/Package.jl",
        rev="deadbeef12341234deadbeef12341234deadbeef",
    )
    @test parse_package_spec("https://github.com/User/Package.jl#v1.0.0") ==
        Pkg.PackageSpec(; url="https://github.com/User/Package.jl", rev="v1.0.0")
    @test parse_package_spec("https://github.com/User/Package.jl@v1.0.0") ==
        Pkg.PackageSpec(; url="https://github.com/User/Package.jl", version="v1.0.0")
    @test parse_package_spec(joinpath(Base.homedir())) ==
        Pkg.PackageSpec(; path=joinpath(Base.homedir()))
    @test parse_package_spec("Package@v1.0.0") ==
        Pkg.PackageSpec(; name="Package", version="v1.0.0")
end

@testitem "default_branch()" begin
    @test AirspeedVelocity.Utils.default_branch() == "master"
    run(pipeline(ignorestatus(`git branch master`); stderr=devnull)) # On CI, this branch might not actually exist.
    run(`git branch trunk`)
    @test AirspeedVelocity.Utils.default_branch() == "master" # This requires internet access
    run(`git branch -d trunk`)
    @test AirspeedVelocity.Utils.default_branch() == "master"
    @test AirspeedVelocity.Utils.parse_rev("{DEFAULT}", "unused") == "master"
    @test AirspeedVelocity.Utils.parse_rev("lh/guess-default-branch", "unused") ==
        "lh/guess-default-branch"
end

@testitem "dev sources" begin
    using AirspeedVelocity
    using Pkg
    using TOML

    tmpdir = mktempdir()
    cd(tmpdir)
    Pkg.generate("TestPackage")
    cd("TestPackage")
    Pkg.activate(".")

    Pkg.generate("Source1")
    Pkg.develop(path = "Source1")
    Pkg.add(url = "https://github.com/JuliaLang/Example.jl", rev = "master")

    proj_file = joinpath(tmpdir, "TestPackage/Project.toml")
    proj = TOML.parsefile(proj_file)
    proj["sources"] = get(proj, "sources", Dict{String, Any}())
    proj["sources"]["Source1"] = Dict("path" => "Source1")
    proj["sources"]["Example"] = Dict("url" => "https://github.com/JuliaLang/Example.jl", "rev" => "master")
    open(proj_file, "w") do io
        TOML.print(io, proj)
    end

    path = joinpath(tmpdir, "TestPackage")
    # Force the initial branch name so the `rev="master"` below resolves
    # regardless of the machine's `init.defaultBranch` (modern git uses `main`).
    run(`git init -b master`)
    run(`git add .`)
    run(`git config user.name "user"`)
    run(`git config user.email "user@example.com"`)
    run(`git commit -m "initial"`)
    script = joinpath(path, "bench.jl")

    open(joinpath(script), "w") do io
        write(
            io,
            """
            using BenchmarkTools
            using TestPackage
            const SUITE = BenchmarkGroup()
            SUITE["cos"] = @benchmarkable cos(x) setup=(x=rand())
            SUITE["sin"] = @benchmarkable sin(x) setup=(x=rand())
            """,
        )
    end

    results_dir = mktempdir(; cleanup=false)
    benchpkg(
        "TestPackage";
        rev="master",
        script=script,
        path=path,
        output_dir=results_dir,
    )

    @test isfile(joinpath(results_dir, "results_TestPackage@master.json"))
end
