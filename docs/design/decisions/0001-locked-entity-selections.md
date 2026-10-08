---
id: "0001"
title: "Locked entity selections"
status: accepted
---

# Decision 0001: Locked entity selections

## Context

The changed-entity execution work in issue #170.

## Decision

Use locked, exact-range entity selections with in-place mutations and
reusable CPU/GPU execution. The requirements and consequences follow below.

## Purpose

Let systems create or structurally modify a batch of entities, then execute CPU
or GPU kernels on exactly that batch. Support further component addition,
removal, and replacement on the returned batch.

The result is a locked, range-based `EntitySelection`. It does not track entity
identities across unrelated structural changes. This replaces the earlier
identity-tracking proposal.

## Agreed public behavior

| Operation                                   | Input scope                                              | Resulting membership                                   |
| ------------------------------------------- | -------------------------------------------------------- | ------------------------------------------------------ |
| Batch creation on `SystemContext`           | Newly created entities                                   | Exactly the new rows                                   |
| Batch add/remove/replace on `SystemContext` | Entities matching the operation filter                   | Exactly the modified entities                          |
| Batch add/remove/replace on a selection     | Existing selection intersected with the operation filter | Exactly the modified entities, at their new locations  |
| Kernel execution on a selection             | Selection intersected with the kernel filter             | Selection remains reusable and unchanged in membership |

- Expose batch operations through `SystemContext`.
- A selection owns a structural-change lock until released or destroyed.
- Kernels may write component values, resources, and mutable captures according
  to their existing access declarations.
- Unrelated entity creation, deletion, and archetype changes remain blocked.
- A kernel skips nonmatching selected entities without reporting a filter error.
  If no entities match, it performs no kernel invocation or GPU launch.
- A filtered component operation keeps only entities actually modified in the
  resulting selection.
  Skipped entities remain unchanged in the world and leave the selection.
- Selection component operations update the same selection in place and return
  nothing. Kernel calls borrow it without changing membership.
- Selections are movable and noncopyable.
- An empty result is a valid locked selection. Its lifetime follows the same
  ownership rules as a nonempty result.

An intended workflow is: create a batch, initialize it with a GPU kernel, add
components to the batch, run another kernel, replace or remove components, then
release the selection. Each structural step updates that same selection.

## API shape and ownership

Use `EntitySelection` as the public type and `.run(...)` as its execution method.
Mirror `SystemContext.run`'s supported kernel forms, filter inference, resource
requirements, explicit capture bindings, and CPU/GPU switch. Retain the CPU
closure overload; do not add unsupported GPU lexical captures.

Use the existing storage API's naming and overload conventions when exposing
batch creation and component operations through `SystemContext` and selections.
The concrete signatures and the `with` lifetime behavior were established by
compiler-checked ownership prototypes before the full API was implemented.

The selection needs origin-bound access to its world, owned range metadata, and
one lock guard. It must not outlive the world or leave borrowed component pointers
usable after a structural operation. Do not erase world ownership origins merely
to make the public API compile.

Compiler validation on Mojo 1.0 established the following concrete surface:

- `SystemContext.add_entities(*components, count=...) -> EntitySelection`
- `SystemContext.add[*Ts, filter=...](components...) -> EntitySelection`
- `SystemContext.remove[*Ts, filter=...]() -> EntitySelection`
- `SystemContext.replace[remove=Components[*Ts](), filter=...](components...)`
- in-place `EntitySelection.add`, `remove`, and `replace` (`mut self`, no return
  value) with the same direct replacement form; reusable thin/CPU-closure `EntitySelection.run`; and
  consuming `selection^.release()`.

Mojo rejects two variadic type packs in one signature, so replacement uses a
compile-time `Components` value for removed types and infers the added types
from values. The selection itself is the origin-bound RAII guard: storing a
mutable world pointer and a separately origin-tracked pointer into that world's
lock manager is rejected as overlapping mutable origins. It therefore stores
the tracked world pointer plus its one owned lock bit, transfers both on move,
and unlocks through that same world borrow on release or destruction. Direct
construction is kept internal; context entry points establish the borrow.

Selections also support `with context.add_entities(...) as selected:` and
`with selection^ as selected:`. The manager retains the owning guard and
`__enter__(mut self)` returns a noncopyable selection whose world origin is
narrowed to the manager's origin. This scoped selection supports in-place
mutations and repeated kernel calls but cannot escape its manager. Its range
metadata is copied on entry; no additional lock is acquired. `__exit__(mut
self)` releases the owned guard exactly once on normal, early, and exceptional
exit. Releasing the scoped selection early does not release the manager's guard.

Compiler checks rejected escaping the scoped selection to a world-bound return
type. A consuming `__enter__` alone deferred destruction beyond normal block
exit on Mojo 1.0, so explicit manager-owned exit cleanup is required.

A selection operates on its own world; users do not supply another context to
`.run`. If any internal entry point accepts a separate world or manager, validate
that its ownership token belongs to that manager.

## Range representation

Represent membership as explicit triples:

`(archetype_index, first_row, row_count)`

Use counts, not ranges implicitly extending to the current archetype length.
With [opt-in partitions](0013-cluster-local-partition-blocks.md), the internal
`archetype_index` names a dense physical store, including a partition block;
logical archetypes remain component-defined. Membership and lock rules are
unchanged, and a cluster selection can contain several such ranges.

Ranges must be in bounds, nonoverlapping, and free of duplicate entity rows.
Merge adjacent ranges in the same archetype when useful. Store indices rather
than persistent archetype pointers: creating a destination archetype can
reallocate the archetype list.

Membership is recorded after each operation. Existing destination rows are
never included merely because changed entities move into their archetype.
Replacing values without changing the archetype records precisely the rows
whose values were replaced. An operation assigning an equal value still counts
as modification; no component equality comparison is required. A request with
no component changes produces an empty selection, consistent with existing
batch behavior.

No stable entity ordering or CPU/GPU-equivalent row numbering is introduced.
Entity identities remain stable; execution row indices retain the existing
backend-local meaning.

## Lock transfer and structural operations

The structural lock is a mutation guard, not thread synchronization or exclusive
component access.

A selection may structurally modify its own rows only when its guard is the sole
active structural lock. Another live query or selection could hold ranges made
invalid by the mutation. Reject such a mutation before changing storage, using
the existing locked-world error.

Provide a narrow internal mutation path authorized by the owning guard. Check
both manager identity and sole-lock ownership. Do not expose a general-purpose
lock bypass or temporarily clear the lock mask.

For a context mutation, validate ordinary unlocked-world requirements, acquire
the result guard before modifying storage, and transfer it to the result. For a
selection mutation, retain its existing guard and update its range metadata
in place. There must be no unlocked interval or second lock allocation
after a successful mutation.

Validation failures preserve the selection's membership and existing guard,
allowing subsequent calls on the same object. Context entry-point failures
release their locally owned guard through RAII. Validate predictable errors
before modifying rows. Preserve valid component lifetimes
and entity-location mappings if an operation raises. Full transactional rollback
is not part of this feature; document the actual guarantee for any remaining
fallible mutation steps before exposing them.

## Component mutation engine

Reuse the existing component type, duplicate-type, add/remove, and replacement
validation rules. Kernel filter mismatch is harmless; an invalid component
mutation request can still report an error. Apply row-dependent checks to the
operation's candidate selection, not unrelated rows in the world. Retain
existing filter-level constraints where required by the storage API.

The whole-archetype `HostStorage._batch_remove_and_add` path and exact selected
range path must preserve these steps as their internals are consolidated:

1. Snapshot candidate ranges and source archetypes before modifying storage.
2. Validate the request and establish lock authorization.
3. Resolve destination archetypes and reserve metadata/capacity where practical.
4. For in-place replacement, assign only candidate rows, destroying replaced
   values correctly.
5. Otherwise, move retained components and entity identities, initialize added
   values, and destroy removed values exactly once.
6. Compact source storage and update entity locations for both transferred
   entities and source entities moved by compaction.
7. Build exact destination ranges and update the selection under its existing guard.

Partial selections must not call the whole-archetype move path. A correctness-first
partial-row implementation can process source rows in descending index order to
avoid invalidating pending indices during swap-removal. Preserve a fast path for
whole-archetype transfers and optimize contiguous moves after correctness tests.
Do not reprocess appended destination rows during the same operation. Confirm
whether existing validation still guarantees distinct destinations; do not rely
on that property without checking it for the new range path.

## Shared kernel execution

Factor execution around a source of matching row ranges. Ordinary context
execution supplies whole matching archetypes; selected execution supplies the
intersection of selection ranges and kernel filters. Keep the ordinary path
lazy where possible to avoid an additional range allocation on every call.

CPU execution offsets each component pointer by the range start and passes the
range length to `KernelContext`. It invokes the kernel for each matching range,
sharing the invocation's resource and capture bindings.

GPU execution computes the total matching length, packs readable component
spans into device columns, allocates writable columns, and launches over the
packed rows. Copy writable component spans back to their original host ranges.
Preserve write-only handling and existing resource/capture upload and copy-back
rules. Retain the lock and transfer buffers until synchronization is complete,
including safe cleanup on exceptional paths.

An empty match does not allocate component buffers or launch a kernel. Preserve
existing binding, resource, and device validation behavior; empty membership
does not suppress unrelated API errors. Mutable captures and resources receive
no kernel-driven changes.

## Compatibility and exclusions

- Replace mutation-result iterator usage with selected kernel execution in
  examples and tests. Document this beta API migration.
- Preserve ordinary queries and single-entity operations. `_WorldEntityIterator`
  currently supports queries as well as mutation results: migrate its remaining
  query duties before deleting it. Do not silently remove query behavior.
- Keep low-level storage operations usable where needed, but avoid a second
  implementation of mutation semantics. Document any changed return types.
- Do not add selection entity deletion, long-lived identity tracking, selection
  unions, copying, asynchronous execution, or general concurrency guarantees.
- Heap-backed GPU resources and resource synchronization are separate work.
- `ResourceStorage.get` retains `UnsafeAnyOrigin` until Mojo can model the
  ownership relationship between `Resources` and stored resource values.

## Acceptance criteria

Only selected, matching entities are executed or modified, including when source
or destination archetypes also contain unselected entities. Chained mutations
preserve identity and valid locations. CPU and GPU produce the expected component
values, captures, and resources. Locks prevent unrelated structural mutations,
transfer safely through chains, and release on normal and exceptional exits.
Ordinary queries and full-world execution retain their behavior. Benchmarks
measure both selected execution and any regression in the ordinary path.

## Rationale

Exact ranges let a system process just the rows changed by a batch operation.
Owning the structural guard makes those row positions valid across repeated
kernel calls and in-place mutation. This was chosen over long-lived entity
identity tracking, which would have different semantics and costs.

## Consequences and evidence

Callers must release or finish with a selection before unrelated structural
changes. Query behavior and low-level storage operations remain supported while
their internals are consolidated. The accepted requirements are
[ECS-06 and ECS-07](../requirements.md). The
[roadmap](../../roadmap.md) tracks unfinished migration and performance work;
`test/entity_selection_test.mojo`, `test/gpu_entity_selection_test.mojo`, and
`benchmark/entity_selection_benchmark.mojo` provide implementation evidence.

CPU execution now shares `_bind_cpu_resources` and `_cpu_kernel_context` in
[`system.mojo`](../../../src/larecs/system.mojo) across ordinary/selected and
thin/value-taking entry points. Resources and explicit captures bind once per
invocation; the shared context builder offsets columns by the range start and
uses the exact range length. Ordinary CPU execution fixes the initial archetype
count, then scans those indices lazily and reacquires each archetype from storage
so it does not retain the archetype-list buffer across callbacks. Selected CPU
execution reads its existing ranges directly. Matching-range
metadata and aggregate row counting are confined to GPU execution.
[`cpu_execution_test.mojo`](../../../test/cpu_execution_test.mojo) covers both
range sources, both CPU kernel forms, shared heap-backed resources and explicit
captures, disjoint offsets, empty ranges, and exclusion/exclusive filters.
The [focused comparison](../../src/guide/benchmarks.md#shared-cpu-execution-comparison)
records paired baseline/current measurements and their limitations.
This implements the existing execution contract without changing the API;
batch mutation consolidation and query iterator migration remain on the roadmap.
