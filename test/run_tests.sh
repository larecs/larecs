#!/usr/bin/env bash
# run_tests.sh — Build and run Mojo test files with AddressSanitizer enabled.
#
# Usage:
#   ./test/run_tests.sh <test_directory>   # Run all test_*.mojo files in a directory
#   ./test/run_tests.sh <test_file.mojo>   # Run a single test file
#   ./test/run_tests.sh --no-precompile <test_file.mojo>
#   ./test/run_tests.sh --parallel auto <test_directory>
#
# `--parallel auto` compiles two files at a time on hosts with at least 12 GiB
# of memory and one at a time otherwise, because a single sanitizer build of a
# large host test can use about 4 GiB.
#
# Each test file is compiled with debug info, all assertions, and AddressSanitizer.
# `pixi run tests` selects Mogo Tester 3 through MOGO_TESTER_BIN, and it compiles
# with the active Larecs Mojo. Host tests request line tables through their
# `# MOJO_BUILD_ARGS: -g1` header, which keeps sanitizer reports' file and line
# numbers at a fraction of the compile time of full debug info.
# Without MOGO_TESTER_BIN, such as in package tests, `mogo-tester` comes from PATH.
# Test binaries run in a PTY to preserve ASAN's colored output while capturing
# it to check for ASAN error messages.
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

# Prints how many test files to compile at once for this host's memory.
memory_parallelism() {
    local memory_bytes=0
    if [ -r /proc/meminfo ]; then
        memory_bytes=$(( $(awk '/^MemTotal:/ { print $2 }' /proc/meminfo) * 1024 ))
    else
        memory_bytes=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
    fi
    if (( memory_bytes >= 12 * 1024 * 1024 * 1024 )); then
        echo 2
    else
        echo 1
    fi
}

args=("$@")
for (( i = 0; i < ${#args[@]}; i++ )); do
    arg="${args[i]}"
    case "$arg" in
        --no-precompile)
            precompile_args=()
            ;;
        --parallel)
            if [ "${args[i + 1]:-}" = auto ]; then
                parallelism="$(memory_parallelism)"
                echo "Compiling ${parallelism} test file(s) at a time for this host's memory."
                test_args+=(--parallel "$parallelism")
                i=$(( i + 1 ))
            else
                test_args+=("$arg")
            fi
            ;;
        *)
            test_args+=("$arg")
            ;;
    esac
done

# A complete suite run also verifies public compile-time classifier diagnostics.
# Individual test-file runs retain the existing focused behavior.
run_backend_contracts=false
run_spatial_performance=false
run_synchronization_contracts=false
run_resource_contracts=false
run_threaded_contracts=false
larecs_test_directory="$(cd "$(dirname "$0")" && pwd)"
for test_path in "${test_args[@]}"; do
    if [ "${test_path##*/}" = "world_entity_iterator_test.mojo" ]; then
        python "$larecs_test_directory/check_iteration_contracts.py"
    fi
    if [ "${test_path##*/}" = "execution_backend_test.mojo" ]; then
        run_backend_contracts=true
    fi
    if [ "${test_path##*/}" = "threaded_execution_test.mojo" ]; then
        run_threaded_contracts=true
    fi
    if [ "${test_path##*/}" = "resource_adapter_test.mojo" ]; then
        run_resource_contracts=true
    fi
    if [ "${test_path##*/}" = "synchronization_test.mojo" ]; then
        run_synchronization_contracts=true
    fi
    if [ -d "$test_path" ] && \
        [ "$(cd "$test_path" && pwd)" = "$larecs_test_directory" ]; then
        run_backend_contracts=true
        # The comparison needs the source tree and Git history.
        if (( ${#precompile_args[@]} > 0 )); then
            run_spatial_performance=true
        fi
        run_resource_contracts=true
        run_threaded_contracts=true
        run_synchronization_contracts=true
        python "$larecs_test_directory/check_iteration_contracts.py"
        python "$larecs_test_directory/check_struct_constraints.py"
        bash "$larecs_test_directory/check_spatial_filters.sh"
        break
    fi
done

if "$run_backend_contracts"; then
    python "$larecs_test_directory/check_execution_backend_contracts.py"
fi

if "$run_synchronization_contracts"; then
    python "$larecs_test_directory/check_synchronization_contracts.py"
fi

if "$run_threaded_contracts"; then
    python -m unittest discover -s "$larecs_test_directory" -p threaded_cpu_capacity_test.py
    python "$larecs_test_directory/check_threaded_contracts.py"
fi

if "$run_resource_contracts"; then
    python "$larecs_test_directory/check_resource_contracts.py"
fi

"${MOGO_TESTER_BIN:-mogo-tester}" "${precompile_args[@]}" --asan --mojo-build-args="${mojo_build_args[*]}" "${test_args[@]}"

# This bounded CPU benchmark runs on both existing PR test runners. Focused
# file runs omit it; the full benchmark suite remains an optional manual task.
if "$run_spatial_performance"; then
    python -m unittest discover -s "$larecs_test_directory" -p spatial_performance_test.py
    python "$larecs_test_directory/../scripts/check_spatial_performance.py"
fi
