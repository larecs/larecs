+++
type = "docs"
title = "Test and hardware coverage"
weight = 2
+++

These checks establish different facts. A rejected program checks a compiler
contract; a host test checks host execution; successful device compilation
does not establish actual accelerator execution.

## Compile-contract commands

Run these commands from the repository root in the test environment. Positive
controls must compile, negative controls must fail for the expected diagnostic,
and intentional exclusions must remain accepted.

| Contract | Command |
| --- | --- |
| Type-only struct invariants and exclusions | `pixi run -e test python test/check_struct_constraints.py` |
| Iterator mutability, filters, and borrows | `pixi run -e test python test/check_iteration_contracts.py` |
| Explicit backend selection and unsupported combinations | `pixi run -e test python test/check_execution_backend_contracts.py` |
| Threaded eligibility, captures, resource access, and fallback | `pixi run -e test python test/check_threaded_contracts.py` |
| Ordinary/adapted resource representations and capabilities | `pixi run -e test python test/check_resource_contracts.py` |
| Synchronization view/guard confinement and backend restrictions | `pixi run -e test python test/check_synchronization_contracts.py` |
| Read-only spatial registration filters | `pixi run spatial-filter-checks` |
| Duplicate resource/type-list fixtures | `pixi run test-resource-compile-failures` |

The full `pixi run tests test` wrapper runs the first seven families and the
thread-capacity Python tests. Focused `world_entity_iterator`,
`execution_backend`, `threaded_execution`, `resource_adapter`, and
`synchronization` test files trigger their corresponding family. The last
table row is separate. The {{< repo "test/check_struct_constraints.py" "struct checker" >}}
uses type-only bindings so constructor checks cannot conceal a missing
declaration invariant; see the
{{< repo "docs/design/research/struct-constraints.md" "constraint audit" >}}.

## Runtime evidence

| Result | What it establishes |
| --- | --- |
| Compile pass for device code | The installed compiler accepts that specialization; no hardware behavior is proved. |
| Host correctness pass | Assertions ran on the host, including actual worker overlap where a test checks it. |
| Device `SKIP`, or an early guard returning before a launch | Host/setup or compile coverage only; no device execution. |
| A device launch completes and output assertions pass | Execution on the named device for that workload and toolchain. |

`has_accelerator()` describes compilation support. Runtime context creation can
still fail. The particle programs probe both and print explicit device PASS or
SKIP evidence. Some older GPU tests return early on unsupported targets while
the file still reports PASS; inspect the guard and logs, rather than counting
file passes as device coverage. `ExecutionBackend.DEVICE` itself never falls back.

Record compiler/build, OS, processor/device, revision, executed path, assertions,
and skips separately. The Linux/macOS CI matrix does not imply NVIDIA, AMD, or
Apple device coverage merely from runner names. A source or driver change can
invalidate earlier evidence; current status is in the
[compatibility reference](../../../reference/compatibility), and durable backend
investigations remain in the [evidence map](../design).

## Markers and diagnostics

`test/run_tests.sh` enables ASAN, `-g`, `-DASSERT=all`, and Tracy linkage.
`# SKIP_ASAN` opts a file out of sanitization; `# SKIP_DEBUG` omits debug info.
Every test that launches a GPU kernel needs `# SKIP_DEBUG` because of the
{{< repo "docs/development.md#metal-debug-info" "Metal compiler failure" >}}.
Neither marker means that the test may skip its assertions. The doctest runner
uses assertions and Tracy linkage, but does not enable the test wrapper's
ASAN/debug defaults.

CI bounds test compilation concurrency with `--parallel 2` and retains
`output/memory/` diagnostics. An interrupted runner or missing artifact is not
a correctness pass. See {{< repo ".github/workflows/main.yml" "the CI workflow" >}}
and {{< repo "scripts/monitor_ci_memory.py" "the memory monitor" >}} for the
recorded process boundary; keep performance measurements isolated from builds.
