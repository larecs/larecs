---
id: "0020"
title: "Declared plain values"
status: accepted
status_notes: |
  Supersedes decisions 0018 and 0019 only for plain-value eligibility.
  Their remaining contracts and validation qualifications are retained;
  threaded host execution remains experimental pending macOS arm64 validation.
---

# Decision 0020: Declared plain values

## Context

The recursive plain-value validator cannot inspect the opaque array storage of
`StaticTuple` and `InlineArray`. Decisions [0018](0018-portable-resource-adapters.md)
and [0019](0019-threaded-host-execution.md) therefore reject these fields even
when they contain only scalars. Tree-D's `EffectiveLeafLayersAbove` component,
which stores a fixed tuple of float32 directions, needs threaded host execution.

## Decision

Add the public opt-in `PlainValue` marker trait. A conforming type declares that
its entire representation contains only plain numeric values, with no pointer,
reference, or handle at any depth. The declaring author guarantees this property;
Larecs cannot verify it by reflection.

The shared `_plain_device_value` validator first requires `Copyable` conformance
and trivial copy, move, and destruction. It then accepts `PlainValue` types
without inspecting their fields. Other types retain recursive validation:
scalar/SIMD values and supported aggregates pass, while undeclared opaque
representations fail. A declared field may be nested in a reflected aggregate.

Apply this rule to accessed threaded components and ordinary threaded read
resources, including sequential fallback, and to ordinary device resources.
This does not change the separate device-component eligibility check or permit
owning containers and pointer-bearing values. Resource views continue to use
their separate descriptor and adapter contracts.

This decision supersedes the opaque-value rejection in decisions 0018 and 0019.
Retain all their other requirements, including resource access modes, adapter
ownership and concurrent-read obligations, synchronous completion, threaded
configuration, dispatch, lifecycle restrictions, and validation qualifications.

## Rationale

A marker lets authors describe fixed scalar arrays without teaching reflection
about each opaque storage implementation. Checking triviality before trusting
the declaration preserves rejection of custom copy, move, or destruction.
Leaving undeclared types on the conservative path avoids broadening eligibility
for arbitrary opaque representations.

## Consequences

Users can opt pointer-free array wrappers into threaded execution and ordinary
resource transfer without changing their storage layout. Incorrect declarations
can admit unsafe representations: authors must audit every nested field.
The marker establishes representation eligibility, not kernel thread safety or
permission for mutable shared resources. Threaded support remains experimental
under decision 0019's platform-validation requirements.

## Evidence

- [Validator and marker](../../../src/larecs/resource_representation.mojo) and
  [public export](../../../src/larecs/__init__.mojo).
- [Threaded execution tests](../../../test/threaded_execution_test.mojo):
  `test_declared_plain_array_component` processes a nested declared `StaticTuple`
  component in parallel chunks.
- [Threaded contracts](../../../test/check_threaded_contracts.py):
  `undeclared_array_component` rejects an undeclared opaque tuple component.
- [Systems guide](../../src/guide/systems_scheduler.md) documents the author
  guarantee; [requirements](../requirements.md) ECS-08 and ECS-18 record the
  updated eligibility contract.
