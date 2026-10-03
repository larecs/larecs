#!/usr/bin/env bash
# run_tests.sh — Build and run Mojo test files with AddressSanitizer enabled.
#
# Usage:
#   ./test/run_tests.sh <test_directory>   # Run all test_*.mojo files in a directory
#   ./test/run_tests.sh <test_file.mojo>   # Run a single test file
#   ./test/run_tests.sh --no-precompile <test_file.mojo>
#
# Each test file is compiled with debug info, all assertions, and AddressSanitizer,
# then executed via `script` so it runs in a PTY. This preserves ASAN's colored
# output while also capturing it to check for ASAN error messages.
#
# Binaries are placed in .build/ and removed after each test run.
# The script exits with code 1 if any test fails to build, exits non-zero,
# or produces output containing both "ERROR:" and "AddressSanitizer".
#
# To disable AddressSanitizer for a specific test file, add the following
# comment anywhere in that file:
#
#   # SKIP_ASAN
#
# To omit `-g` (debug info) for a specific test file, add:
#
#   # SKIP_DEBUG
#
# All tests that launch a GPU kernel should use `# SKIP_DEBUG`: compiling
# certain kernels with `-g` crashes Apple's Metal compiler on-device. See
# "Known issues" in AGENTS.md.
#
set -e

precompile_args=(--precompile src/larecs)
test_args=()
: "$CONDA_PREFIX:=${PREFIX:-}"
: "${CONDA_PREFIX:?must be set (or PREFIX must be set)}"
mojo_build_args=(-g -DASSERT=all -Xlinker -L"${CONDA_PREFIX}/lib" -Xlinker -lmojotracy -DTRACY_ENABLED)

for arg in "$@"; do
    case "$arg" in
        --no-precompile)
            precompile_args=()
            ;;
        *)
            test_args+=("$arg")
            ;;
    esac
done

# A complete suite run also verifies public compile-time classifier diagnostics.
# Individual test-file runs retain the existing focused behavior.
run_spatial_performance=false
larecs_test_directory="$(cd "$(dirname "$0")" && pwd)"
for test_path in "${test_args[@]}"; do
    if [ -d "$test_path" ] && \
        [ "$(cd "$test_path" && pwd)" = "$larecs_test_directory" ]; then
        run_spatial_performance=true
        bash "$larecs_test_directory/check_spatial_filters.sh"
        break
    fi
done

mogo-tester "${precompile_args[@]}" --asan --mojo-build-args="${mojo_build_args[*]}" "${test_args[@]}"

# This bounded CPU benchmark runs on both existing PR test runners. Focused
# file runs omit it; the full benchmark suite remains an optional manual task.
if "$run_spatial_performance"; then
    python -m unittest discover -s "$larecs_test_directory" -p spatial_performance_test.py
    python "$larecs_test_directory/../scripts/check_spatial_performance.py"
fi
