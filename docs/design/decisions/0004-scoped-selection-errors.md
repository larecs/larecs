---
id: "0004"
title: "Scoped selection errors"
status: accepted
---

# Decision 0004: Scoped selection errors

## Context

[Decision 0001](0001-locked-entity-selections.md) requires a selection to run a
kernel after adding, removing, or replacing components. Mojo 1.0 could not
compile that sequence inside a `with` block when the kernel had no resource
bindings. A selection mutation raises `LarecsError`, while `run` can raise a
general `Error`. The compiler tried to carry `Error` through the selection
scope's `LarecsError` path and reported that the type was absent from the
variant.

## Decision

Include `Error` as an arm of `LarecsError`. Keep the existing ECS-specific arms
and typed mutation signatures. Scoped selection execution may carry a general
kernel or resource failure through that arm.

## Rationale

Both error categories can cross the same scope. Representing both in the
variant preserves the specific mutation errors and lets the accepted
mutation-to-run sequence compile without changing its ownership or execution
semantics.

## Consequences

`LarecsError` can now contain a general `Error`, so code that exhaustively
inspects its arms must handle that additional case. A failed kernel still
propagates its error and the context manager releases the structural lock.

## Evidence

The implementation is in `src/larecs/error.mojo`. The scoped success and
failure cases in `test/entity_selection_test.mojo` and the runnable
[entity guide](../../src/guide/adding_and_removing_entities.md) exercise the
mutation-to-run path. This supports [ECS-07 and ECS-11](../requirements.md).
