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

## Issues and Branches

- Before starting a task, find its issue: search open issues with
  `gh issue list --state open --search "<keywords>"` and check the sub-issues of
  related parent issues. Tell the developer which issue you are working on. If
  none fits, ask whether to create one (use the `issue-description` skill), and
  start without an issue only when the developer says so.
- Work on a branch linked to the issue. Create it with
  `gh issue develop <N> --name <branch> --base <base> --checkout`, where `<base>`
  is `main` or, for stacked work, the branch the work builds on. When an issue
  exists, create the work branch only this way, not with `git switch -c`,
  `git checkout -b`, or `git branch`.
- If tooling already started you on its own branch, such as a managed worktree,
  create the linked branch with `gh issue develop` without `--checkout`, then
  run `git fetch origin <branch>` and `git switch <branch>` before your first
  commit.
- Confirm the link with `gh issue develop --list <N>`. A branch links to one
  issue; when a PR resolves further issues, add their `Closes #N` lines and tell
  the developer which ones need a manual Development link, because GitHub only
  links closing keywords for PRs into `main`.

## Pull Request Descriptions

Use the `pr-description` skill to write or revise a description; `.github/pull_request_template.md` holds the skeleton.

- Title the PR with a concise summary of the work in sentence case, such as "Add opt-in threaded host execution". Do not use Conventional Commits form for PR titles.
- Open with the problem or motivation in one or two sentences, then the change.
- Under `## Features`, list each implemented feature as a bullet with a short description of what callers observe: opt-in flags, newly rejected inputs, preserved invariants. Add implementation details only where reviewers need them to understand the behavior.
- Under `## API changes`, list each changed user-facing API with a short reason.
- Delete template sections that would be empty. When a PR closes several issues, a table mapping issues to changes may replace the feature list.
- For breaking changes, add a `## Breaking change` section that states what callers must change and links the design decision records that document it.
- End with one `Closes #N` line per resolved issue.
- Never include validation: test runs or counts, hardware, sanitizer or doctest results, CI or review-bot status, or what remains untested.
- Never include benchmark results unless the developer explicitly asks for them.
- Never include PR metadata: stack or base relationships, branch names, commit hashes or counts, review ranges or walkthroughs, or narratives about what other PRs supply. Use the hosting platform's metadata fields or stack tooling.
- Never include commit or process history, follow-up or roadmap work, or AI attribution.
- The Issue Writing rules on other projects and local filesystem paths apply to PR titles and bodies too.

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

## Issue Writing

- Keep issue titles, bodies, and comments focused on Larecs. Never mention other projects unless the developer explicitly requests it.
- Never include local filesystem paths in issues, including pasted logs or command output. Use repository links or symbol names to identify code.
- Manage prioritization and scheduling through issue metadata, such as milestone assignments and priority fields or labels. Keep priority levels, deferral status, and release scheduling out of issue titles, bodies, and comments.

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
