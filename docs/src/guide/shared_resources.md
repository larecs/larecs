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

Resource types conform to `Copyable` and `Deinitable`; they need not appear in
the world's component pack. {{< api ResourceStorage.add >}} inserts values and
raises on duplicates. {{< api ResourceStorage.get >}} returns a reference and
raises on missing types. {{< api ResourceStorage.set >}} replaces existing values;
if any requested type is absent, it raises without updating them. Its
`add_if_not_found=True` option inserts absent types instead.
{{< api ResourceStorage.remove >}} removes values and raises on missing types.
Do not retain resource references across removal or replacement.

## Declare kernel permissions

{{< example file="particles/configuration.mojo" region="kernel" >}}

{{< api Resources >}} declares access independently of component filters.
`read[Time]()` grants immutable `get`; `read_write` grants mutable `get`.
Host `write` grants `set` only, not `get`. `Resources[Time]()` defaults to
read-write access. Every declared resource must exist before
{{< api SystemContext.run >}}; otherwise it raises.

Ordinary sequential host resources can own collections. A resource is shared
across the entire invocation, not copied once per particle. Updating it once
per kernel call therefore depends on how matching rows are split into calls;
use a system hook for one update per simulation step, as `ConfigureTime` does.

## Troubleshooting

If movement reports a missing `Time`, add it before scheduling. If an access
fails compilation, check the resource declaration independently of the component
filter. For adapters and device restrictions, use the
[advanced resource material](../resources#portable-owning-resources).
