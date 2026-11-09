#!/usr/bin/env bash
# run_doctests.sh — Compile and run the Mojo doctest files extracted by Modo.
#
# Modo (see modo.yaml's `tests` setting) writes one file per doctest block
# under docs/test, named "<page>_<label>_test.mojo" -- a *suffix* naming
# convention. mogo-tester's directory scan only picks up files matching a
# "test_*.mojo" *prefix* convention (see test/run_tests.sh), so pointing it
# at the docs/test directory directly silently finds nothing. Passing the
# files explicitly bypasses that scan and works regardless of naming
# convention, so this script gathers them itself.
#
# Usage:
#   pixi run doctest
#
set -e

: "${CONDA_PREFIX:?must be set (run via 'pixi run doctest')}"

doctest_dir="docs/test"

# Documentation example programs. Guide pages show excerpts of these files
# (see the `example` shortcode in docs/site/layouts/shortcodes), so each one
# must compile and run like an extracted doctest.
example_dir="examples/particles"

if [ ! -d "$doctest_dir" ]; then
    echo "error: no $doctest_dir directory -- run 'modo build' or 'modo test' first." >&2
    exit 1
fi

mapfile -t all_doctest_files < <(find "$doctest_dir" -name '*.mojo' | sort)

if [ "${#all_doctest_files[@]}" -eq 0 ]; then
    echo "error: no doctest files found under $doctest_dir." >&2
    exit 1
fi

doctest_files=("${all_doctest_files[@]}")

mapfile -t example_files < <(find "$example_dir" -name '*.mojo' | sort)
doctest_files+=("${example_files[@]}")

echo "Running ${#doctest_files[@]} doctest(s):"
for path in "${doctest_files[@]}"; do
    echo "  RUN   $path"
done
echo

mojo_build_args=(-DASSERT=all -Xlinker -L"${CONDA_PREFIX}/lib" -Xlinker -lmojotracy -DTRACY_ENABLED)

mogo-tester --precompile src/larecs --mojo-build-args="${mojo_build_args[*]}" "${doctest_files[@]}"
