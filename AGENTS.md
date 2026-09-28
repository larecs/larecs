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
- Keep implementation tasks and release checklists separate from durable design
  records; link them as evidence. Do not mark a requirement implemented solely
  because it appears in a plan.

## Build/Test Commands

- Run all tests: `pixi run tests test`
- Run single test: `pixi run tests test/<filename>.mojo`
- Format code: `pixi run mojo format src test benchmark`
- Generate docs: `pixi run mojo doc -o docs/src/larecs.json src/larecs`
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
