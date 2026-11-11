+++
type = "docs"
title = "Reuse unchanged device copies"
weight = 5
+++

Skip uploading particle data that has not changed since the last device call.
Use this after the kernel already passes the
[host and device comparison](../device#compare-the-device-with-the-host) and a
[measurement](../../performance/measure) shows that uploads matter. Reuse is
off by default, set per world, and
[experimental](../../../reference/compatibility). Written outputs still copy
back to the host after every call.

Start with [Execute on a device](../device).

## Enable reuse for a world

The stage uses the [portable particle model](../#the-portable-particle-model)
and the unchanged movement kernel and system.

{{< example file="particles/copy_reuse.mojo" region="model" >}}

{{< example file="particles/copy_reuse.mojo" region="kernel" >}}

{{< example file="particles/copy_reuse.mojo" region="system" >}}

The kernel and system do not know about the transfer policy. You enable it on
the world with {{< api World.reuse_device_copies >}}, as the sequence below
does before it moves `walker` six times:

{{< example file="particles/copy_reuse.mojo" region="sequence" >}}

Larecs keeps a *revision* for each resource and for each component column of a
physical store, and advances it whenever the host may have changed that data.
With reuse enabled, a device call uploads a resource or column only when the
revision of its *device copy*, the bytes already on the device, differs from
the current one. In the sequence:

- `read` calls leave the revisions unchanged, so the second step reuses every
  input.
- `get` through mutable storage advances the revision even if you only read the
  value, so the step after `get[Time]()` uploads `Time` again.
- A successful device call leaves the written `Position` current on both sides,
  so the next call can skip its upload too.

![First use uploads, an unchanged revision reuses bytes, and a tracked write or explicit invalidation makes the next call upload again; allocation capacity persists.](/images/device-copy-reuse.svg)

*Retained capacity does not prove that its contents are current.*

Larecs keeps device allocations between calls whether or not reuse is enabled;
a kept allocation says nothing about whether its bytes are current. With reuse
enabled, a read-only [portable resource](../portable_resources) whose source is
current skips `prepare_device` and reuses its view.

## Invalidate a write Larecs cannot see

Larecs advances a revision when you call `get`, not when you later write through
the reference it returned. The sequence keeps `time_ptr` across a run and then
writes through it, so Larecs cannot see that write.
`scheduler.world.resources.invalidate_device[Time]()` marks the device copy of
`Time` stale, and the next call uploads it again. For writes through raw
pointers to several resources or columns,
{{< api World.invalidate_device_copies >}} marks every device copy stale.
Reacquiring a reference with `get` after each run avoids the problem.

## Check both transfer policies

The driver runs the same sequence on the host, on the device with default
transfers, and on the device with reuse:

{{< example file="particles/copy_reuse.mojo" region="check" >}}

Every run ends at `(4.5, 7.0)`. From the repository root, run
`pixi run mojo run -I src examples/particles/copy_reuse.mojo`. A PASS line for
the device means both transfer policies ran on the accelerator and matched the
host; a SKIP line means only the host sequence ran.

## Variations

### Observe values without forcing an upload

Use `read` on storage and resources, or read-only queries, when you only look
at values. They keep device copies current.

### Turn reuse off

`world.reuse_device_copies(False)` discards the reuse records; the next device
call uploads every input again. Calls stay synchronous either way.

## Failures and limits

| Symptom | Cause and fix |
| --- | --- |
| The device reads old values | A write went through a reference kept from before a run, or a raw pointer. Reacquire references with `get` after each run, or invalidate the copy. Turn reuse off to confirm the diagnosis. |
| Inputs still upload on most calls | Something advances their revisions: a mutable `get`, a writable kernel declaration, a structural change, spatial maintenance, or a filter or selection that packs rows at a different offset. Use `read` for observation. |
| Written data still downloads | Larecs copies written outputs back after every call; reuse skips only uploads. |

The [copy-reuse reference](../../../reference/execution#device-copy-reuse) lists
every operation that advances a revision.

{{< example file="particles/copy_reuse.mojo" full=true >}}

## Next steps

- [Measure complete simulation steps](../../performance/measure) before you
  keep this option.
- [Device-copy validity](../../../inside/architecture/transfers#device-copy-validity)
  explains how Larecs records which device copies are current.
