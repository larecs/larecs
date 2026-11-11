+++
type = "docs"
title = "Execute on a device"
weight = 2
+++

Run the particle movement kernel on an accelerator, such as a GPU, and check
that it produces the same positions as the host. Use this when a kernel does
enough arithmetic per particle to outweigh copying data to the device and back.
Device execution is [experimental](../../../reference/compatibility); it needs
the repository's pinned Mojo and MAX environment and a supported accelerator.

Start with [Update entities with systems and kernels](../../systems_kernels)
and [Share time and configuration](../../../start/shared_configuration).

## Select the device in the system

The stage uses the [portable particle model](../#the-portable-particle-model),
whose components Larecs can copy to the device byte by byte.

{{< example file="particles/device.mojo" region="model" >}}

The kernel is the movement kernel from the first simulation, unchanged.

{{< example file="particles/device.mojo" region="kernel" >}}

`move` is a *thin kernel*: a named `def` function that `run` receives as a
compile-time parameter. Device execution accepts only thin kernels. The system
chooses the target with the `backend` parameter of {{< api SystemContext.run >}}:

{{< example file="particles/device.mojo" region="system" >}}

`Move[ExecutionBackend.DEVICE]()` runs `move` on the device, and
`Move[ExecutionBackend.HOST]()` runs it sequentially on the host, which is also
the default when you omit `backend`. The {{< api ExecutionBackend >}} value is a
compile-time parameter, so each system specialization runs on one target.

## Let the filter decide what moves

Larecs copies only the data the kernel declares. For each call, it packs the
matching rows of every physical store into contiguous device columns, runs the
kernel once over all of them, and copies written columns back to their original
rows.

![Readable Position and Velocity ranges pack from two host stores into device columns; only written Position scatters back after synchronization.](/images/device-transfer.svg)

*Access declarations determine transfer directions.*

| Declaration | Upload before the kernel | Copy back after the kernel |
| --- | --- | --- |
| `include[Position]()` | Yes | Yes |
| `read[Velocity]()`, `Resources().read[Time]()` | Yes | No |
| `write[T]()` | No; the kernel must `set` every row it visits | Yes |

`run` returns after the kernel finishes and Larecs has copied every written
component, read-write resource, and mutable capture back to the host. The next
system sees the new values on the host. Rows that the filter does not match
stay untouched.

## Compare the device with the host

The driver runs two steps on 37 moving particles and one unmatched marker,
once per target, each in a fresh world.

{{< example file="particles/device.mojo" region="parity" >}}

Every mover ends at `(0.5, 1.0)`, the marker stays at `(-3, -3)`, and the
device sums match the host sums. `has_accelerator()` decides whether the
program attempts the device at all; without support, it checks that a device
call raises instead of falling back.

From the repository root, run:

```sh
pixi run mojo run -I src examples/particles/device.mojo
```

A PASS line for the device means the kernel ran on the accelerator and matched
the host; a SKIP line means this machine has no supported accelerator and only
the host ran.

## How device threads visit rows

On the host, a kernel invocation covers one physical store or one
[threaded chunk](../threaded#how-larecs-splits-the-rows). On a device, one
launch covers all packed rows, and each device thread runs the kernel body.
The `for` loop over the context uses *grid-stride iteration*: each thread
starts at its global thread index and advances by the total number of launched
threads, so every row is visited exactly once, even when there are more rows
than threads.

![Sequential host calls each matching store, threaded host calls disjoint chunks, and device threads stride through packed matching rows.](/images/execution-mapping.svg)

*One row loop, three invocation mappings.*

Code outside the `for` loop runs once per device thread. A row's `idx` is its
offset in the packed rows, and [row indices are not entity
IDs](../../../reference/compatibility#row-indices-are-not-entity-ids).

## Variations

### Choose the target at run time

The backend is a compile-time parameter. To choose at run time, branch and call
each specialization explicitly, for example add `Move[ExecutionBackend.DEVICE]()`
when `has_accelerator()` is true and `Move[ExecutionBackend.HOST]()` otherwise.
Larecs itself has [no device fallback](../../../reference/compatibility#no-device-fallback).

### Run on a selection

{{< api EntitySelection.run >}} accepts the same `backend` parameter and packs
only the selection's rows.

### Pass local values or owning data

Use [explicit capture slots](../captures#declare-explicit-slots-for-a-thin-kernel)
for a step-local value and [portable resources](../portable_resources) for an
owning collection.

### Skip unchanged uploads

By default, every device call uploads all readable columns and resources.
[Reuse unchanged device copies](../copy_reuse) skips uploads of data that has
not changed since the last call.

## Failures and limits

| Failure | Cause and fix |
| --- | --- |
| `run` raises that DEVICE requires accelerator support or a working device context | No usable accelerator. Fix the accelerator or toolchain, or select `ExecutionBackend.HOST`; there is [no device fallback](../../../reference/compatibility#no-device-fallback). |
| Compile error: every accessed component type must be device-safe | Make the component `TrivialRegisterPassable`, as in the portable model. Only accessed components are checked. |
| Compile error: device resources require pointer-free trivial plain values | The resource owns memory or holds a pointer. Use a [portable resource](../portable_resources) for owning data. |
| Compile error: device write-only resources are unsupported | Declare an ordinary device resource with `read` or `read_write`. |
| Compile error for a lexical closure or `threaded=True` | Device execution needs a thin kernel and cannot be combined with threaded host execution. |
| `run` raises about a missing resource, even with no matching rows | Add every declared resource during setup. |

A failed device call does not roll back host writes that already happened. The
[device execution reference](../../../reference/execution#device-execution)
covers empty matches, transfer and synchronization failures, and when a world
rejects further device work. Transfers and preparation can dominate a small
kernel; [measure complete simulation steps](../../performance/measure) before
choosing a backend.

{{< example file="particles/device.mojo" full=true >}}

## Next steps

- [Pass local values to kernels](../captures) binds a scale and a counter for
  host and device runs.
- [Use portable resources](../portable_resources) reads owning collections on
  the device.
- [Bindings, transfers, and revisions](../../../inside/architecture/transfers)
  explains packing and copy-back.
