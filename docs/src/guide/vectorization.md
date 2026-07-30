+++
type = "docs"
title = "Vectorization"
weight = 70
+++

A major feature of Mojo is its native support for
vectorized operations, processing multiple values in
one go via `SIMD`. This can improve
the computational performance of our code significantly.
In Larecs🌲, this feature can be used by defining
a vectorized function that can process multiple entities at once
and applying it to entities via the {{< api World.apply apply >}}
method.

> [!Caution]
> Using vectorized functions is an an advanced feature,
> requiring some knowledge about Mojo and SIMD. Mistakes
> can lead to serious bugs that are difficult to track down.

## Preliminary imports

Below, we need some advanced Mojo and
Larecs🌲 features, which we can import as follows:

```mojo {doctest="guide_simd_apply" global=true}
from memory import UnsafePointer
from sys.info import simdwidthof, sizeof
from larecs import World, MutableEntityAccessor
```

## Considering the memory layout

Before we can implement a vectorized function that can process
multiple entities at once, we need to have a look at
the memory layout of the components
we want to consider. Suppose we want to process the
`Position` components of a chunk of entities. Each entity's
`Position` has two attributes `x` and `y`. In order to work with these
attributes in vectorized computations, we need all `x` values
and all `y` values to be in contiguous `SIMD` vectors, respectively.

However, the `x` and `y` attributes are not stored next to each other
in memory. Instead, an array of `Position` components would look like this:

```
Position[0].x | Position[0].y | Position[1].x | Position[1].y | ...
```

Hence, accessing the `x` attribute of multiple `Position` components
requires us to skip the `y` attributes.

```mojo {doctest="guide_simd_apply" global=true hide=true}

@fieldwise_init
struct Position(Copyable, Movable):
    var x: Float64
    var y: Float64

@fieldwise_init
struct Velocity(Copyable, Movable):
    var dx: Float64
    var dy: Float64
```

```mojo {doctest="guide_simd_apply" hide=true}
world = World[Position, Velocity]()
_ = world.add_entities(Position(0, 0), Velocity(1, 0), count=10)
```

Loading elements from memory while leaving out some values
is called _strided_ loading. Here, `stride` refers to the
"step width" between the memory address of two loaded elements.
In our case, the stride is `2`, because the distance between the
memory addresses from the first `x` attribute to the second
is _twice_ the size of a single `x` attribute.

> [!Note]
> The `stride` is given in multiples of the
> considered attribute's size. While this makes it easy
> to work with components whose attributes are all of the same type,
> it may be tricky or even impossible to process components
> with heterogeneous attribute types.

> [!Caution]
> Choosing the wrong `stride` may lead to undefined behavior,  
> causing crashes or errors that are extremely difficult to track down.

We may store the stride information in an `alias` variable.

```mojo {doctest="guide_simd_apply"}
alias stride = 2

# Alternatively, we could use the `sizeof` function
# to calculate the stride automatically.
alias stride_ = Int(sizeof[Position]() / sizeof[__type_of(Position(0, 0).x)]())
```

Note that the `Velocity` component also has two `Float64`
attributes and thus the same stride as the `Position`
component.

## Defining a vectorized operation

Now we can define our vectorized move operation.
It needs to accept an integer parameter `simd_width`,
which denotes how many entities will be processed at once.
Let us revisit the `move` function we defined in the
[queries and iteration](../queries_iteration#applying-functions-to-entities-in-queries)
chapter and add support for vectorized computation. The
updated signature of the function reads as follows:

```mojo {doctest="guide_simd_apply"}
fn move[simd_width: Int](entity: MutableEntityAccessor) capturing:
```

Again we start implementing `move` by obtaining pointers
to the `Position` and `Velocity` components.

```mojo {doctest="guide_simd_apply"}
    try:
        pos = Pointer(to=entity.get[Position]())
        vel = Pointer(to=entity.get[Velocity]())
    except:
        return
```

The `entity` argument is a normal mutable
{{< api EntityAccessor >}} instance, allowing
access to a single entity. However, the referenced entity
is the _first_ of a _batch_ of `simd_width` entities, each with
the same components. The `move` function will not be
called for any other entity in this batch.

The components of the batched entities are guaranteed
to be stored in contiguous memory, respectively.
However, loading a components' individual
attributes in a batch is an "unsafe" operation, as it requires
us to specify the stride manually.
Hence, we need `UnsafePointer`s to the components.

```mojo {doctest="guide_simd_apply"}
    pos_x_ptr = UnsafePointer(to=pos[].x)
    pos_y_ptr = UnsafePointer(to=pos[].y)
    vel_x_ptr = UnsafePointer(to=vel[].dx)
    vel_y_ptr = UnsafePointer(to=vel[].dy)
```

Now we can load `simd_width` values of `x` and `y`
into temporary `SIMD` vectors using the `strided_load` method
and do the same for the `dx` and `dy` attributes of `Velocity`.

```mojo {doctest="guide_simd_apply"}
    pos_x = pos_x_ptr.strided_load[width=simd_width](stride)
    pos_y = pos_y_ptr.strided_load[width=simd_width](stride)
    vel_x = vel_x_ptr.strided_load[width=simd_width](stride)
    vel_y = vel_y_ptr.strided_load[width=simd_width](stride)
```

Next, we implement the actual "move" logic as if the
vectors were simple scalars.

```mojo {doctest="guide_simd_apply"}
    pos_x += vel_x
    pos_y += vel_y
```

Finally, we store the updated positions at their original
memory locations using the `strided_store` method.

```mojo {doctest="guide_simd_apply"}
    pos_x_ptr.strided_store[width=simd_width](pos_x, stride)
    pos_y_ptr.strided_store[width=simd_width](pos_y, stride)
```

> [!Tip]
> It can be worthwhile to define project-specific load and store
> functions that take care of stride and width and
> thereby reduce the complexity of the code.

# Applying a vectorized operation to all entities

What remains to be done is to apply the move operation to all entities.
In the vectorized version, the {{< api World.apply apply >}} method
requires us to provide a value for the `simd_width` parameter, which
denotes the maximal number of entities that can be processed
at once efficiently. Typically, this corresponds to the `SIMD` width of our machine.
We can get this information using the `simdwidthof` function.

```mojo {doctest="guide_simd_apply"}
# How many `Float64` values can we process at once?
alias simd_width=simdwidthof[Float64]()

# Apply the move operation to all entities with a position and a velocity
world.storage.apply[move, simd_width=simd_width](world.storage.query[Position, Velocity]())
```

> [!Note]
> The overhead from
> the extra load and store operations can exceed the gain
> from SIMD operations in simple functions such as the `move`
> function considered here. Thorough benchmarking is required to
> determine whether the use of `SIMD` is beneficial in a specific
> case.
