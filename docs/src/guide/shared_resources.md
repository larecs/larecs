+++
type = "docs"
title = "Resources"
weight = 5
+++

Share one value per type across your simulation using {{< api ResourceStorage >}}.
The complete [configuration program](../../start/shared_configuration) sets
`Time.delta` before movement.

{{< example file="particles/configuration.mojo" region="time" >}}
{{< example file="particles/configuration.mojo" region="configuration" >}}
{{< example file="particles/configuration.mojo" region="world" >}}

## Add, read, replace, and remove

A resource conforms to [`ResourceType`](../../larecs#aliases), which requires `Copyable` and
`Deinitable`. The example's `Copyable, Movable` structs satisfy both. Resource
types need not appear among the world's declared component types.

{{< api ResourceStorage.add >}} inserts values and raises on duplicates. {{< api ResourceStorage.get >}} returns a reference and
raises on missing types. {{< api ResourceStorage.set >}} replaces existing values;
if any requested type is absent, it raises without updating them. Its
`add_if_not_found=True` option inserts absent types instead.
{{< api ResourceStorage.remove >}} removes values and raises on missing types.
Do not retain resource references across removal or replacement.

## Declare kernel permissions

{{< example file="particles/configuration.mojo" region="kernel" >}}

{{< api Resources >}} declares access independently of component filters.
`read[Time]()` grants immutable `get`; `read_write` grants mutable `get`.
On the host, `write` grants `set` only, not `get`; device kernels do not support
write-only resources. `Resources[Time]()` defaults to read-write access. Every
declared resource must exist before {{< api SystemContext.run >}}; otherwise it
raises.

On the sequential host, resources can own collections. Each kernel call sees
the same resource value. Because one `run` can call the kernel several times,
update per-step values in a system's `update`, as `ConfigureTime` does.

## Troubleshooting

If movement reports a missing `Time`, add it before scheduling. If an access
fails compilation, check the resource declaration independently of the component
filter. For adapters and device restrictions, use the
[Resource operations and adapters](../resources#portable-owning-resources).
