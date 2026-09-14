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

mogo-tester "${precompile_args[@]}" --asan --mojo-build-args="${mojo_build_args[*]}" "${test_args[@]}"
