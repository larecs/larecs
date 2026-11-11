+++
type = "docs"
title = "Pass local values to kernels"
weight = 3
+++

Give the particle kernel a step-local scale and get a particle count back,
without storing either value as a world resource. Use a lexical closure when
the kernel runs sequentially on the host, and explicit capture slots when the
same kernel must also run on a device. Threaded execution accepts neither; pass
its inputs through read-only resources or components.

Start with [Execute on a device](../device), which introduces the backend
parameter. [Run threaded host kernels](../threaded) defines thin kernels.

## Borrow locals with a closure on the host

Both programs on this page use the
[portable particle model](../#the-portable-particle-model).

{{< example file="particles/lexical_closure.mojo" region="model" >}}

A *lexical closure* is a `def` nested inside another function that names the
local variables it uses in a capture list. Here, `move` is defined inside
`Move.update` and passed to `run` as a value:

{{< example file="particles/lexical_closure.mojo" region="closure" >}}

The capture list `{imm scale, mut visits}` borrows `scale` read-only and
`visits` mutably. `context.run(move)` selects the overload that takes a
callable value; it runs only sequentially on the host. Larecs calls `move` once
per matching physical store, and `visits` increases once per row. `run` returns
after the last call, so the assertion sees the final count.

The driver puts the two particles into different physical stores:

{{< example file="particles/lexical_closure.mojo" region="check" >}}

The extra `Int32` component gives `climber` a different composition and
therefore its own physical store; it does not change which entities `move`
matches. Both particles move once, and `visits` counts rows across both calls.
From the repository root, run:

```sh
pixi run mojo run -I src examples/particles/lexical_closure.mojo
```

## Declare explicit slots for a thin kernel

A thin kernel cannot borrow locals, but it can declare ordered *capture slots*
with {{< api Captures >}}. The system binds a local value to each slot when it
calls `run`, on the host or on a device.

{{< example file="particles/captures.mojo" region="kernel" >}}

Slot 0 is a {{< api ReadCapture >}} input; `get[0]()` returns its value. Slot 1
is a {{< api MutCapture >}} output. Every invocation, and on a device every
thread, sees the same output value, so only one writer may update it:

- On the host, each invocation covers one physical store and adds its own row
  count, `context.length`. Sequential invocations never overlap.
- On a device, one launch covers all rows. `comptime if is_gpu()` compiles the
  check only for the device, where only the thread with global index zero adds
  the packed row count.

This works because no thread reads another thread's result. A thread-zero
branch is not a barrier, and it does not make a general reduction safe.

Bind locals in the declared order when the system runs:

{{< example file="particles/captures.mojo" region="system" >}}

{{< api read_capture >}} and {{< api mut_capture >}} borrow `scale` and
`processed` until `run` returns. On the host, the kernel uses the original
values. On a device, Larecs uploads every binding on each call and copies the
mutable slot back before `run` returns, so `processed` holds 37 at the
assertion.

From the repository root, run:

```sh
pixi run mojo run -I src examples/particles/captures.mojo
```

A PASS line for the device means the slots were bound, executed, and copied
back on the accelerator; a SKIP line means only the host ran.

## Variations

### Keep a value between steps

A capture lives for one `run` call. A value that persists between steps, or
that owns memory, belongs in a [resource](../../shared_resources) or a
[portable resource](../portable_resources).

### Produce one result per particle

When many invocations or threads contribute to a result, write a per-particle
component and reduce it after `run`, as in
[Coordinate shared writes](../shared_writes).

## Failures and limits

| Failure | Cause and fix |
| --- | --- |
| Compile error on the slot count, type, or mutability | Bind one value per slot in declaration order, with the declared type. Two slots may share a type; their index distinguishes them. |
| Borrow-checker error on one local | One local cannot be bound read-only and mutably in the same call. Use separate values. |
| Compile error for a device capture that owns memory or holds a pointer | Device captures copy plain bytes. Use a [portable resource](../portable_resources) for owning data. |
| Wrong result from several writers | A mutable slot provides no synchronization. Use one writer, or [per-particle output](../shared_writes). |
| Compile error for a closure with `DEVICE` or `threaded=True` | Lexical closures run only sequentially on the host. Use explicit slots for a device. |

Keep references from capture slots and closure borrows inside the kernel; they
must not outlive the call. The
[capture reference](../../../reference/resources#explicit-captures) lists the
remaining binding rules.

## Complete program

{{< example file="particles/lexical_closure.mojo" full=true >}}

The program above checks the lexical closure on the host.

{{< example file="particles/captures.mojo" full=true >}}

The program above checks explicit slots on the host and, when available, on a
device.

## Next steps

- [Use portable resources](../portable_resources) passes owning collections to
  host and device kernels.
- [Coordinate shared writes](../shared_writes) covers results from many
  writers.
