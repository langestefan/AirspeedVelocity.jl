# Showcase benchmark: evaluate symbolic-expression trees of two complexities
# across a range of input sizes, for two SymbolicRegression versions. Used by
# .github/workflows/showcase.yml to demonstrate the pretty-printed comment.
using BenchmarkTools
using SymbolicRegression

@assert PACKAGE_VERSION in (v"0.15.3", v"0.16.2")

const SUITE = BenchmarkGroup()

options = Options(; binary_operators=[+, -, *], unary_operators=[cos])
x, y = Node(; feature=1), Node(; feature=2)

small_tree = x + cos(3.2f0 * y)
big_tree = ((x * y) + cos(x - 3.1f0 * y)) * (x + cos(y))

SUITE["eval_small"] = BenchmarkGroup()
SUITE["eval_big"] = BenchmarkGroup()

for n in (10, 100, 1000, 10000)
    SUITE["eval_small"]["n=$n"] = @benchmarkable(
        eval_tree_array($small_tree, X, $options),
        setup = (X = randn(Float32, 2, $n)),
        evals = 1,
        samples = 300,
    )
    SUITE["eval_big"]["n=$n"] = @benchmarkable(
        eval_tree_array($big_tree, X, $options),
        setup = (X = randn(Float32, 2, $n)),
        evals = 1,
        samples = 300,
    )
end
