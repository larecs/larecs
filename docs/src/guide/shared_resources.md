+++
type = "docs"
title = "Share values with resources"
weight = 6
next = "/guide/execution"
+++

Store a value that exists once per world, such as the step length, as a
resource, and let kernels and systems read or change it.
[Share time and configuration](../../start/shared_configuration) runs this
code.

{{< example file="particles/configuration.mojo" region="time" >}}

{{< example file="particles/configuration.mojo" region="configuration" >}}

{{< example file="particles/configuration.mojo" region="world" >}}

`Time` and `Configuration` are resources. `world.resources.add` stores one
value of each, and `ConfigureTime` changes `Time` through
`context.world[].resources` before every movement step.

## Define a resource

A resource is a struct that conforms to
{{< api resource.ResourceType >}}, which requires `Copyable` and
`Deinitable`. Use `ResourceType` to name this constraint in your type declaration. A world holds at most one
value per resource type, and resource types do not appear in the world's
component list.

## Add, read, replace, and remove resources

{{< api ResourceStorage >}} manages the world's resources:

| Method | Effect | Raises when |
| --- | --- | --- |
| {{< api ResourceStorage.add >}} | Inserts values | A type is already present |
| {{< api ResourceStorage.get >}} | Returns a reference to the value | The type is missing |
| {{< api ResourceStorage.set >}} | Replaces existing values | Any type is missing; then no value changes. With `add_if_not_found=True`, it inserts missing types instead. |
| {{< api ResourceStorage.remove >}} | Removes values | A type is missing |

Do not keep a resource reference across removal or replacement.

## Declare kernel access

{{< example file="particles/configuration.mojo" region="kernel" >}}

A kernel declares its resources with {{< api Resources >}}, separately from its
component filter:

| Declaration | Access through the kernel |
| --- | --- |
| `read[T]()` | Read with `get` |
| `read_write[T]()` | Read and write with `get` |
| `write[T]()` | Write with `set` only, on the host; device kernels reject it |
| `Resources[T]()` | Read and write, like `read_write` |

Every declared resource must exist in the world when you call
{{< api SystemContext.run >}}; otherwise `run` raises.

On the sequential host, a resource can own collections such as a `List`. Every
kernel call in one `run` sees the same resource value. Because one `run` can
call the kernel several times, change per-step values in a system's `update`,
as `ConfigureTime` does, rather than in the kernel.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| `run` raises because `Time` is missing | Add `Time` with `world.resources.add` before you start the scheduler. |
| Compile error on resource access | Check the kernel's `Resources` declaration; the component filter does not grant resource access. |

## Next steps

[Use portable resources](../execution/portable_resources) covers threaded and
device restrictions and adapters for resources that own data.

[Bindings, transfers, and revisions](../../inside/architecture/transfers) explains
source leases, invocation-owned views, and publication.
