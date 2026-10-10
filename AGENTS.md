# Agent Guidelines for Larecs

## Project Overview

Larecs is a high-performance Entity Component System (ECS) library written in Mojo. It provides efficient data structures and algorithms for game development and simulation applications.

## Key Components

- **Entities**: Unique identifiers for game objects
- **Components**: Data containers that can be attached to entities
- **Systems**: Logic that operates on entities with specific components
- **World**: Central container managing entities, components, and systems
- **Archetypes**: Efficient storage for entities with the same component composition
- **Queries**: Fast iteration over entities matching specific criteria

## Design Records

- Read [the design index](docs/design/README.md) and relevant
  [requirements](docs/design/requirements.md) and decisions before changing
  ECS behavior, ownership, storage, query, or execution semantics.
- Record consequential new choices as numbered files in `docs/design/decisions/`
  using the status, context, decision, rationale, consequences, and evidence
  convention in the index. Mark unaccepted ideas `Proposed`.
- When an accepted choice changes, add a superseding decision and update the
  index and requirements; retain the earlier record for history. Update code,
  tests, and user guides to match the accepted behavior.
- Track unfinished work in the single [roadmap](docs/roadmap.md), grouped by
  **Next release**, **Later**, or **Unscheduled**. Move items between priority
  buckets as needed; do not add per-version todo files. Put completed release
  history in the [changelog](changelog.md).
- Keep tasks separate from durable design records; link decisions and evidence.
  Do not mark a requirement implemented solely because it appears on the roadmap.

## Build/Test Commands

- Run all tests: `pixi run tests test`
- Run single test: `pixi run tests test/<filename>.mojo`
- Format code: `pixi run mojo format src test benchmark`
- Generate docs: `pixi run mojo doc -o docs/src/larecs.json src/larecs`
- Run small spatial comparisons: `pixi run spatial-benchmarks`
- Check spatial regressions against a revision: `pixi run spatial-performance-check --base <revision>`
- Build a focused benchmark binary: `pixi run mojo build -I src benchmark/<benchmark_filename>.mojo -o /tmp/larecs-benchmark`
- Run the complete benchmark suite: `pixi run mojo run -I src benchmark/run_benchmarks.mojo`
- Run focused part of the benchmark suite: `pixi run mojo run -I src benchmark/<benchmark_filename>.mojo`

## Code Style

- Use snake_case for functions/variables, PascalCase for types
- Always use `def` for functions
- Prefer `var` for mutable, immutable by default
- Use `mut` parameters for mutation, not return modified values
- Include comprehensive type hints with Mojo's progressive typing
- Use `comptime` for compile-time constants, `@always_inline` for critical paths
- Leverage SIMD types `SIMD[type, width]` for vectorization
- Apply traits: `Copyable`, `ImplicitlyCopyable`, `Movable`, `Writable`, `Deinitable`, `RegisterPassable`, `TriviallyRegisterPassable` appropriately
- Use manual memory management with `Allocation[T]` ONLY when needed
- Every function needs a docstrings including a description of all parameters, raises and returns.
  Use this example as a template:

    ````mojo
      def <function_name>[<parameters>](<arguments>) raises? -> <return type>:
          """<short description>

          <long description>(optional)

          Parameters:
              <parameter name>: <description for one parameter>

          Args:
              <argument name>: <description for one argument>

          Raises:
              <description when and what Exceptions can be raised>

          Returns:
              <description what gets returned>

          Constraints:
              <description of one comptime constraint (indicated by `comptime assert`)>

          Examples:
            <Include ONLY on end user facing API which isn't easily understable!>
          ```mojo
         <example mojo code here>
          ```
         """
    ````
    - Skip sections that are empty. So for example if a function returns nothing don't specify a `Returns: ...`.

- Reference Mojo docs via the `mojo-syntax` skill

## Error Handling & Safety

- Follow borrow checker principles for memory safety
- Prefer stack allocation and RAII patterns
- Use `debug_warn()` utility for debug messages
- Use `debug_assert()` for critical checks when they introduce no performance overhead

## Performance Focus

- This is a performance-critical ECS library
- Memory layout and cache efficiency are crucial
- Always consider vectorization opportunities
- Update benchmarks when making performance changes

## Building and Using Benchmarks

- Add or update representative benchmarks when changing storage, queries,
  classification, row movement, or execution costs. Read the
  [benchmark guide](docs/src/guide/benchmarks.md) for current cases and methods.
- Maintain a small CPU benchmark suite suitable for every PR. Keep the combined PR
  benchmark checks near one minute per runner, including compilation, warmup,
  and sampling. Measure cold compilation and execution separately on Linux and
  macOS before expanding the suite. Avoid importing the complete benchmark
  registry into a PR driver; keep larger worlds and GPU measurements available
  as focused manual benchmarks.
- Use deterministic inputs, bounded calibration or fixed iteration counts,
  and a compact scenario matrix. Cover relevant sizes, distributions, and
  mutation patterns; spatial cases should include uniform, dense, sparse, and
  moving entities with different maintenance cadences. The existing small
  spatial suite uses 512/2,048 rows and 32 cases.
- Compare implementations or layouts using identical entities and semantic
  work. Include an unchanged-layout control. Measure isolated operation costs
  and complete frame costs when useful; include input updates, classification,
  sorting, movement, location repair, and transfers when they belong to the
  workload being claimed. State exactly which setup and maintenance costs are
  excluded. Validate results, entity locations, and payload preservation outside
  the timed region; consume results to prevent dead-code elimination.
- Build timing binaries once using the focused build command above, then run
  the binary repeatedly. Use matching compiler versions and optimization settings
  for comparisons; measure normal optimized builds without debug info,
  sanitizers, or tracing overhead. Run measurements without concurrent builds
  or other benchmark jobs. Report compilation cost separately from operation
  timing.
- Compare the same current driver against the PR base and current library on
  the same runner. Warm both binaries, alternate baseline/current sample order,
  and use repeated paired measurements. Avoid machine-specific checked-in
  timing baselines. The spatial checker defaults to the GitHub PR base SHA;
  local runs default to committed `HEAD`, so use `--base` to assess a branch's
  changes. A base predating the spatial API uses the documented bootstrap
  implementation.
- Keep the small regression checks in the complete `pixi run tests test` path
  so existing Linux/macOS PR jobs execute them. Focused test-file runs omit
  them. The spatial guard requires over 30% slowdown and over 500 ns extra time
  in at least four of five pairs, with medians exceeding both thresholds, and
  confirms the affected cases in a fresh sample set. Investigate sustained
  failures; document evidence for changing thresholds rather than loosening
  them merely to pass CI. Smaller regressions need dedicated measurements.
- Keep the driver's scenario matrix and the checker's expected-case manifest
  synchronized. Build failures, invalid or incomplete timing reports, and
  correctness failures must fail the check. Update the guide when changing
  cases, timing boundaries, sampling, or baseline selection. Record hardware,
  compiler version, method, and limitations with performance claims; keep
  unmeasured application benefits and remaining work explicit in the roadmap.

## Known issues

### GPU tests must not be compiled with `-g` (Apple Metal compiler crash)

Compiling a GPU kernel that uses `KernelContext`'s `for entity in context`
iteration (`EntityAccessorIterator`, which lowers to `raise StopIteration()`-
driven control flow) with debug info (`-g`) reliably crashes Apple's Metal
shader compiler on-device:

```
At max/mojo/max/gpu/host/_device_context_extras.mojo:168:17: Failed to create
compute pipeline state (GPU machine code generation): Compilation failed due
to an interrupted connection: XPC_ERROR_CONNECTION_INTERRUPTED. This error
occurred after multiple retries.
```

This is not flaky driver noise -- it's deterministic and reproducible in
isolation. `log show`/crash reports (`~/Library/Logs/DiagnosticReports/
MTLCompilerService-*.ips`) show `MTLCompilerService` SIGABRT-ing every time,
inside Apple's proprietary AGX LLVM backend:

```
llvm::report_fatal_error
  -> llvm::AGX::AGXCompilePlan::execute
  -> AGCLLVMCtx::compile
  -> MTLCompilerObject::backendCompileModule
  -> MTLCompilerService::messageHandler
```

The trigger is specifically `-g`: the exact same kernel, built with the exact
same `mojo build` invocation minus `-g`, compiles and runs correctly. It is
independent of resource access, of whether the kernel reads or writes
components, and of component count/type -- confirmed by bisecting several
minimal repros. `system_sketch.mojo` (built via plain `mojo run`/`mojo
build`, no `-g`) uses this exact iteration pattern and works; every test in
`test/` that used it failed until this was understood, because
`test/run_tests.sh` used to build every test with `-g` unconditionally.

**Fix**: any test that launches a GPU kernel must opt out of debug info via
the `# SKIP_DEBUG` marker mogo-tester (>=2.3.0) supports -- see
`test/run_tests.sh`'s header comment. This is a workaround, not a real fix:
the underlying bug lives in Apple's Metal compiler, not in Mojo or larecs,
and there is nothing to change in this codebase to avoid it beyond not
compiling GPU kernels with `-g`.

### macOS 27 SDK breaks linking (`libSystem.tbd ... unknown architecture`)

The macOS 27 SDK's `.tbd` stubs list the new `arm64e.x1` architecture, which
the conda-forge `ld64` used by `mojo build` cannot parse:

```
ld: warning: ignoring file .../MacOSX.sdk/usr/lib/libSystem.tbd, malformed file
.../libSystem.tbd:4:20: error: unknown architecture
Undefined symbols for architecture arm64: "_write", "_strlen", ...
```

**Fix**: `scripts/activate_macos_sdk.sh` runs as a pixi activation script on
osx-arm64. If the default SDK is affected and `SDKROOT` is unset, it exports
`SDKROOT` pointing at the newest installed SDK without `arm64e.x1` (e.g.
`MacOSX26.sdk`). This needs an older SDK to be installed; it can be removed
once conda-forge ships an `ld64` that understands the new stubs.
