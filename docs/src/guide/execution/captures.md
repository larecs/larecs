+++
type = "docs"
title = "Pass local values to kernels"
weight = 2
+++

Pass a step-local scale or result without storing it as a world resource. Start
with [movement and resources](../../../start/shared_configuration). Choose a
lexical closure for sequential host borrows, or explicit slots for a thin kernel
that can also run on a device. Threaded execution accepts neither capture path;
its inputs belong in read-only resources or components.

## Borrow locals on the host

Both independent programs on this page use these particle types.

{{< example file="particles/lexical_closure.mojo" region="model" >}}

The names match the core simulation. The explicit-capture variant uses the same
`Float32` representation for device-compatible arithmetic; see
[device eligibility](../device).

The lexical stage defines `move` inside `Move.update` and passes it as a value.

{{< example file="particles/lexical_closure.mojo" region="closure" >}}

`imm scale` borrows the local input and `mut visits` borrows the counter.
`context.run(move)` selects the value-taking overload, which supports only
sequential HOST. Every matching physical store receives a call, so `visits`
increments inside the row loop. Completion is synchronous; its final value is
visible at the assertion. Do not capture an alias that structurally changes the
world while rows are borrowed.

The driver checks two matching physical stores with different compositions.

{{< example file="particles/lexical_closure.mojo" region="check" >}}

`walker` and `climber` both move once, and the counter counts rows across both
calls. The extra `Int32` component puts `climber` in another logical archetype;
it does not change the movement filter. Run
`pixi run mojo run -I src examples/particles/lexical_closure.mojo` from the
repository root to check the stage.

## Declare explicit slots for a thin kernel

The alternative stage declares ordered {{< api Captures >}} slots, independent
of the world's resource types.

{{< example file="particles/captures.mojo" region="kernel" >}}

Slot 0 is a {{< api ReadCapture >}} input; slot 1 is a {{< api MutCapture >}}
result. `get[0]` is immutable. The output is shared by all invocations/threads,
not private per row. On host, one writer per store adds that store's length.
On device, only global thread zero adds the packed length, after its own row
loop. This works because the result does not read other threads' outputs.
It is not a barrier or a general parallel reduction.

Bind locals in exactly the declared order when the system runs.

{{< example file="particles/captures.mojo" region="system" >}}

{{< api read_capture >}} and {{< api mut_capture >}} borrow their locals until
`run` finishes. Host execution borrows the original values; device execution
uploads each binding on every call and copies mutable slots back before return.
Empty matches leave captures unchanged. The checked full program also tests an
empty world and 37 particles split across two physical stores.

From the repository root, execute this independent stage:

```sh
pixi run mojo run -I src examples/particles/captures.mojo
```

The program always checks host execution. Its explicit device PASS line means
actual execution and copy-back; a SKIP line means that device validation did
not run. [Device setup](../device) explains availability failures.

## Restrictions and recovery

| Failure or restriction | Response |
| --- | --- |
| Wrong slot count, type, or mutability | Match `Captures` in binding order. Slots may share a type; their index still distinguishes them. |
| Conflicting borrows of one local | Use separate values; the borrow checker rejects overlapping read/mutable bindings. |
| Heap owner or host pointer in a device capture | Captures transfer trivial bytes, not object graphs, and perform no `DevicePassable` conversion. Use a portable resource for owned storage. |
| A captured reference outlives execution | Keep references and pointers inside the invocation. Neither lexical nor explicit capture references may escape it. |
| Several writers update one output | Choose a proven single writer or [per-row output and a later reduction](../shared_writes). Mutable capture access supplies no synchronization. |

Device execution remains [experimental](../../../reference/compatibility).
Prefer explicit bindings when the same thin kernel must run on both targets;
use [portable resources](../portable_resources) when the input persists between
steps or owns data.

{{< example file="particles/lexical_closure.mojo" full=true >}}

The first program checks lexical host borrowing.

{{< example file="particles/captures.mojo" full=true >}}

The second checks explicit host bindings and optionally device bindings as a
separate simulation.
