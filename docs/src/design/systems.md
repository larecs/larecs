# System Concept Design

This document captures the design of Larecs' System abstraction — both the
declarative CPU-side system trait and the GPU acceleration layer that builds on it.
The two are developed together because the GPU layer's requirements (pre-allocated
transfers, registration-time dependency analysis) are what motivate the declarative
system trait in the first place.

## Usage

```mojo
from larecs.bitmask import BitMask
from larecs.component import ComponentType, ComponentManager
from larecs.archetype import _ComponentStorage
from larecs.unsafe_box import UnsafeBox

from std.sys.intrinsics import _type_is_eq


@fieldwise_init
struct Position(Copyable):
    var x: Float32
    var y: Float32


@fieldwise_init
struct Velocity(Copyable):
    var dx: Float32
    var dy: Float32


@fieldwise_init
struct Name(Copyable):
    var name: String


@fieldwise_init
struct QueryBuilder[*WorldTs: ComponentType, include_mask: BitMask, exclude_mask: BitMask](Movable):
    comptime component_manager = ComponentManager[*Self.WorldTs]

    comptime include[*Ts: ComponentType] = QueryBuilder[
            *Self.WorldTs,
            include_mask=include_mask | BitMask(Self.component_manager.get_id_arr[*Ts]()),
            exclude_mask=exclude_mask
        ]

    comptime exclude[*Ts: ComponentType] = QueryBuilder[
            *Self.WorldTs,
            include_mask=include_mask,
            exclude_mask=exclude_mask | BitMask(Self.component_manager.get_id_arr[*Ts]()),
        ]

    @staticmethod
    def __call__(is_mut: Bool = False) -> Query:
        return Query(
            include=Self.include_mask, exclude=Self.exclude_mask, is_mut=is_mut
        )


@fieldwise_init
struct _World[*WorldTs: ComponentType]:
    comptime component_manager = ComponentManager[*Self.WorldTs]
    comptime QueryBuilder = QueryBuilder[*Self.WorldTs]

    comptime filter = Self.QueryBuilder(_include=BitMask(), _exclude=BitMask())

filter.include[Foo].exclude[Bar].query()
world.query[Foo]().without[Bar]()

@fieldwise_init
struct Query(Copyable):
    var is_mut: Bool
    var include: BitMask
    var exclude: BitMask


struct EntityAccessor(Copyable):
    var id: Int

    def __init__(out self, id: Int):
        self.id = id

    def get[T: ComponentType](self) -> T:
        comptime if _type_is_eq[T, Position]():
            return rebind_var[T](Position(x=1.0, y=-1.0))
        elif _type_is_eq[T, Velocity]():
            return rebind_var[T](Velocity(dx=1.0, dy=-1.0))
        else:
            return rebind_var[T](Name(name=String(self.id)))


struct Iter2(Iterator, Movable):
    comptime Element = EntityAccessor

    var elems: List[EntityAccessor]
    var idx: Int

    def __init__(out self):
        self.elems = [
            EntityAccessor(id=1),
            EntityAccessor(id=2),
            EntityAccessor(id=3),
            EntityAccessor(id=4),
            EntityAccessor(id=5),
        ]
        self.idx = 0

    def __iter__(deinit self) -> Self:
        return self^

    def __next__(
        mut self,
    ) raises StopIteration -> ref[origin_of(self.elems)] Self.Element:
        if self.idx >= len(self.elems):
            raise StopIteration()
        ref result = self.elems[self.idx]
        self.idx += 1
        return result


struct Context[*WorldTs: ComponentType]:
    def query[q: Query](self) -> Iter2:
        return Iter2()


trait SystemType:
    ...

struct Systems[*system: System]:
    comptime add(system: System): Systems[*system]

struct Scheduler[
    systems: Systems,
]:

    comptime add_system[system: System]: Scheduler[Self.systems.add(system)]

struct System[
    T: SystemType,
    //,
    imm_components: Components = Components[](),
    mut_components: Components = Components[](),
]:

    comptime info: SystemInfo = SystemInfo[
        reflect[T],
        Self.imm_components,
        Self.mut_components,
    ]()

    var _system: T

    def __init__(out self, system: T):
        self._system = system


trait System(Copyable, ImplicitlyDeletable):
    comptime ImmComponents: TypeList[ComponentType]
    comptime MutComponents: TypeList[ComponentType]
    comptime Resources: TypeList[ResourceType]
    comptime Phase: LarecsPhase
    comptime prefers_gpu = True

    def update[*WorldTs: ComponentType](self, context: Context[*WorldTs]):
        ...

struct KernelContext:

    thread_idx: Int
    block_idx: Int
    kernel_info: KernelInfo
    components: [*WorldTs: ComponentType]

    def query[*WorldTs: ComponentType](self, context: Context[*WorldTs]):
        return KernelIter(self.components[self.thread_idx])

    def resource[R: ResourceType](self, context: Context[*WorldTs]):
        var shared = alloc[R](1)
        comptime if self.thread_idx == 0:
            return context.resource[*WorldTs]()
        else:
            return shared[]

def run[KernelFunc: def (kernel_ctx: KernelContext) -> None](self, kernel_func: KernelFunc, kernel_ctx: KernelContext):
    var kernel_ctx = KernelContext(
        thread_idx,
        block_idx,
        self.kernel_info
    )

    self.ctx.enqueue_function[kernel_func](grid_dim=10, block_dim=64)


struct MySystem:
    # comptime ImmComponents = [Foo]
    # comptime MutComponents = [Foo]
    # comptime Resources = [Bar]
    # comptime Phase = LightPhase

    def update(context):
        # var shared = alloc[Bar](1)
        # if thread_idx == 0:
        #     shared.store(context.resource[Bar]())
        # ref bar = shared[]
        #

        def kernel1(kernel_ctx):
            ref bar = kernel_ctx.resource[Bar]()
            for ref foo in kernel_ctx.query[Foo]():
                foo.x += 1

        def kernel2(accessors, context):
            ref bar = context.resource[Bar]()
            for ref entity in accessors:
                entity.y += 1

        context.run[kernel1]()
        context.run[kernel2, context.query[Foo]()](context.resource[Bar]())

comptime World = _World[Position, Velocity, Name]


@fieldwise_init
struct Move(System):
    comptime pos_vel_query = World.filter.include[Position, Velocity]().query(
        is_mut=True
    )
    comptime name_query = World.filter.include[Name]().exclude[
        Position, Velocity
    ]().query()

    comptime Queries = [
        Self.pos_vel_query,
        Self.name_query,
    ]

    def update[*WorldTs: ComponentType](self, context: Context[*WorldTs]):
        for entity in context.query[Self.pos_vel_query]():
            ref pos = entity.get[Position]()
            ref vel = entity.get[Velocity]()

            pos.x += vel.dx
            pos.y += vel.dy

        for entity in context.query[Self.name_query]():
            ref pos = entity.get[Position]()  # MUST fail!
            ref name = entity.get[Name]()

            print(t"Entity named {name.name}")


@fieldwise_init
struct Collision(System):
    comptime Queries = [
        World.filter.include[Position]().query(),
    ]

    def update[*WorldTs: ComponentType](self, context: Context[*WorldTs]):
        pass


@fieldwise_init
struct Scheduler:
    var systems: List[Tuple[UnsafeBox, List[Query]]]

    def __init__(out self):
        self.systems = List[Tuple[UnsafeBox, List[Query]]]()

    def add_system[SystemType: System](mut self, var system: SystemType):
        var builder = StringBuilder("")
        write_system[SystemType](builder)
        print(builder.s)

        if self.get_conflicts(system):
            print("Conflicts with existing systems")
            return

        self.systems.append(
            (UnsafeBox(system^), materialize[SystemType.Queries]())
        )

    def get_conflicts[
        SystemType: System
    ](self, system: SystemType, out conflicts: List[Int]):
        conflicts = List[Int]()
        for sys_idx in range(len(self.systems)):
            ref queries = self.systems[sys_idx][1]
            if conflicts_with(system, queries):
                conflicts.append(sys_idx)


def conflicts_with[
    SystemType: System
](system: SystemType, queries: List[Query]) -> Bool:
    comptime for query1 in SystemType.Queries:
        for query2 in queries:
            if query1.include.matches(query2.include):
                return True
    return False


def main():
    scheduler = Scheduler()
    scheduler.add_system(Move())
    scheduler.add_system(Collision())
```

> The sketch in `system_sketch.mojo` is the working prototype for the syntax in this
> section. It compiles and demonstrates the full comptime introspection path
> (`add_system` walking `SystemType.Queries`, conflict detection between systems, and
> a debug printer that resolves component IDs to type names) end-to-end. The
> `EntityAccessor.get[T]` body is stubbed with `_type_is_eq` for prototyping; the
> `# MUST fail!` comment marks the intended compile-time safety check — calling
> `.get[T]()` for a component that the query excludes should not compile (see
> [Open Questions](#open-questions)).

## Overview

The System concept in Larecs is designed around Mojo's unique strengths: zero-cost
abstractions, compile-time metaprogramming, strong static typing, ownership/borrowing,
and MLIR backend. This document captures the requirements and design decisions for
implementing systems, including the GPU-accelerated system variant.

## Design Goals

- One abstraction for both CPU and GPU systems.
- Efficient GPU ↔ CPU data transfer.
- Minimal boilerplate: no repeating of required queries, resources, etc.
- Extensible: Should be able to add new systems (with the right shape, i.e. correct world component types) at runtime to the scheduler.
- No (or minimal) manual memory management for GPU usage.
- As much compile-time checks as possible.

## Current Architecture

Larecs is an archetype-based ECS where entities with identical component sets are
stored in contiguous SoA (Structure of Arrays) buffers. Key types in the current
production codebase:

- **World**: Central container. Holds `List[Archetype]`, entity pool, and component
  manager.
- **Archetype**: Stores component data as typed `UnsafePointer` buffers via
  `_ComponentStorage`.
- **Query**: Matches archetypes by component bitmask, then iterates entities.
- **Scheduler/System**: `System` trait with `initialize`/`update`/`finalize`
  lifecycle. `Scheduler` runs systems sequentially.

Component data lives in CPU memory as flat arrays per component type per archetype.
Each archetype's `_ComponentStorage` holds a tuple of
`Optional[UnsafePointer[T]]` indexed by component ID.

The current production `System` trait (`src/larecs/scheduler.mojo`) discovers its
component access at call time through `world.query[*T]()` inside `update`. That works
on the CPU but hides the access set from the framework — the scheduler cannot know
which components a system will read or write until the system actually runs. The
declarative trait prototyped in `system_sketch.mojo` (see [Usage](#usage)) is intended
to replace it; see [Open Questions](#open-questions) for the coexistence plan.

## Core Design Decisions

### Systems as Compile-Time Types

Every system is its own type, not a runtime object:

```mojo
struct Move(System):
    comptime pos_vel_query = World.filter.include[Position, Velocity]().query(
        is_mut=True
    )
    comptime Queries = [Self.pos_vel_query]

    def update[*WorldTs: ComponentType](self, context: Context[*WorldTs]):
        ...
```

The scheduler never sees "a function" — it sees `Move` as a type. This enables
compile-time metadata queries via `Move.Queries` (and, once added,
`Move.Resources`, `Move.After`, `Move.Before`): the scheduler walks these at
`add_system[Move]` time, resolves component IDs through `ComponentManager`, and
builds the schedule before the first frame.

### System Metadata is Compile-Time

The prototyped shape (see `system_sketch.mojo`) puts the metadata on the trait as a
list of declarative `Query` values, each carrying an `include` bitmask, an `exclude`
bitmask, and an `is_mut` flag — all built from the world's `ComponentManager`:

```mojo
@fieldwise_init
struct QueryBuilder[*WorldTs: ComponentType](Movable):
    comptime component_manager = ComponentManager[*Self.WorldTs]

    var _include: BitMask
    var _exclude: BitMask

    def include[*Ts: ComponentType](deinit self) -> Self:
        self._include |= BitMask(Self.component_manager.get_id_arr[*Ts]())
        return self^

    def exclude[*Ts: ComponentType](deinit self) -> Self:
        self._exclude |= BitMask(Self.component_manager.get_id_arr[*Ts]())
        return self^

    def query(deinit self, is_mut: Bool = False) -> Query:
        return Query(
            include=self._include, exclude=self._exclude, is_mut=is_mut
        )


@fieldwise_init
struct _World[*WorldTs: ComponentType]:
    comptime component_manager = ComponentManager[*Self.WorldTs]
    comptime QueryBuilder = QueryBuilder[*Self.WorldTs]
    comptime filter = Self.QueryBuilder(_include=BitMask(), _exclude=BitMask())


@fieldwise_init
struct Query(Copyable):
    var is_mut: Bool
    var include: BitMask
    var exclude: BitMask


trait System(Copyable, ImplicitlyDeletable):
    comptime Queries: List[Query]

    def update[*WorldTs: ComponentType](self, context: Context[*WorldTs]):
        ...
```

`QueryBuilder` is a fluent, `Movable` builder: `.include[*Ts]()` and `.exclude[*Ts]()`
mutate `self` in place via `|=` and return `self^`, so calls chain as
`World.filter.include[Position, Velocity]().exclude[Mass]().query(is_mut=True)`. The
`_World[*WorldTs]` type exposes a `comptime filter` field pre-seeded with an empty
`QueryBuilder`, giving systems a single canonical entry point.

The scheduler extracts the following from each system type, all at comptime:

- **Queried components** — by walking `Queries[i].include.get_indices()` and
  resolving each component ID through `ComponentManager.get_type_name(id)`. The
  `write_system` debug printer in the sketch does exactly this.
- **Excluded components** — by walking `Queries[i].exclude.get_indices()` the same
  way. A query matches an archetype only if the archetype's mask is a superset of
  `include` _and_ disjoint from `exclude`.
- **Read/write access** — `Queries[i].is_mut: Bool`. The sketch went with a single
  per-query mutability flag rather than per-component access modes (see
  [Open Questions](#open-questions) for whether per-component granularity is needed
  later).
- **Resources** — not yet modeled; will likely live alongside `Queries` as a
  separate comptime field.
- **Phase / dependencies** — handled via explicit `After` / `Before` (see
  [System Ordering and Dependencies](#system-ordering-and-dependencies)).

The runtime scheduler only consumes this comptime metadata — exactly as envisioned in
the original design, but with `Queries: List[Query]` as the concrete carrier instead
of parallel `Reads` / `Writes` tuples. The sketch's `Scheduler.add_system[S]` already
demonstrates this: it calls `write_system[S]` to introspect `S.Queries` at comptime,
then `conflicts_with` to detect overlap with already-registered systems.

### Complete Data Declaration

Systems MUST declare every component and resource they need to run. In the
prototyped shape, this declaration lives in `comptime Queries` — each `Query` is
built via `World.filter.include[*Ts]()` / `.exclude[*Ts]()` / `.query(is_mut=...)`,
which folds the world's `ComponentManager`-assigned component IDs into `include` and
`exclude` bitmasks:

```mojo
struct Move(System):
    comptime pos_vel_query = World.filter.include[Position, Velocity]().query(
        is_mut=True
    )
    comptime name_query = World.filter.include[Name]().exclude[
        Position, Velocity
    ]().query()

    comptime Queries = [
        Self.pos_vel_query,
        Self.name_query,
    ]

    def update[*WorldTs: ComponentType](self, context: Context[*WorldTs]):
        ...
```

From `Queries` the compiler extracts, per query:

- **Components included**: the set bits in `include`, resolved to component types
  via `ComponentManager`.
- **Components excluded**: the set bits in `exclude`. An archetype matches only if
  it has every included component and none of the excluded ones.
- **Mutability**: `is_mut` — whether the system may write to the included
  components, or only read them.
- **Per-query entity set**: every archetype whose component mask is a superset of
  `include` and disjoint from `exclude` matches.

What is **not yet** derivable from the sketch (and needs adding):

- **Per-component read vs. write** — currently `is_mut` is per-query, so a query
  either mutates all of its included components or none. See
  [Open Questions](#open-questions).
- **Resources** — no `Resource` parameter type yet.

Once access modes are settled, the declaration is the complete statement of what the
system touches — no registration, no macros, no reflection beyond what
`ComponentManager` already provides.

### Scheduling from Declarations

During scheduling, the compiler gathers all system declarations to:

1. **Determine execution order** — Systems writing to a component must run before
   systems reading it.
2. **Identify parallelism** — Systems with no overlapping access can run concurrently.
3. **Select entities** — Only entities matching a system's query are passed to it.

```
MoveSystem
  query 0: include=[Position, Velocity], is_mut=true

AnimationSystem
  query 0: include=[Position, Transform], is_mut=true

AudioSystem
  query 0: include=[AudioListener], is_mut=false
```

Schedule:

- MoveSystem runs first (writes Position via its mutable query)
- AnimationSystem runs after MoveSystem (also writes Position — they conflict)
- AudioSystem runs in parallel with both (no overlapping included components)

The sketch's `conflicts_with` already detects case 2 (overlap) by checking
`query1.include.matches(query2.include)`; it does not yet factor in `is_mut` or
`exclude`, so it currently treats any `include` overlap as a conflict regardless of
whether both queries actually mutate (see [Open Questions](#open-questions)).

### System Ordering and Dependencies

While the compiler can infer order from data access, explicit ordering is sometimes
needed. The sketch currently exposes per-query mutability via `is_mut` (a single
boolean per query) rather than per-component access modes; implicit ordering based
on read/write conflict detection therefore works at query granularity today and at
component granularity only once per-component access modes land (see
[Open Questions](#open-questions)). Explicit `After` / `Before` ordering is
independent of that and can land first.

**Implicit ordering (from `is_mut` and `include` overlap, today):**

```mojo
# Two systems whose mutable queries both include Position — the scheduler
# detects a conflict via conflicts_with and orders / serializes them.
struct Physics(System):
    comptime Queries = [
        World.filter.include[Position, Velocity]().query(is_mut=True),
    ]
    def update[*WorldTs: ComponentType](self, context: Context[*WorldTs]): ...

struct Render(System):
    comptime Queries = [
        World.filter.include[Position, Transform]().query(is_mut=False),
    ]
    def update[*WorldTs: ComponentType](self, context: Context[*WorldTs]): ...
```

**Explicit ordering (when needed):**

```mojo
struct Move(System):
    comptime After = (Input,)
    comptime Before = ()
    comptime Queries = [
        World.filter.include[Position, Velocity]().query(is_mut=True),
    ]
    def update[*WorldTs: ComponentType](self, context: Context[*WorldTs]): ...

struct Animation(System):
    comptime After = ()
    comptime Before = (Render,)
    comptime Queries = [
        World.filter.include[Position, Transform]().query(is_mut=True),
    ]
    def update[*WorldTs: ComponentType](self, context: Context[*WorldTs]): ...
```

**Full dependency declarations (aspirational, once per-component access modes land):**

```mojo
struct Move(System):
    comptime Reads = (Velocity, Time)
    comptime Writes = (Position,)
    comptime Resources = (Time,)
    comptime After = (Input,)
    comptime Before = (Animation, Collision)
    comptime Queries = [
        World.filter.include[Position, Velocity]().query(is_mut=True),
    ]
    def update[*WorldTs: ComponentType](self, context: Context[*WorldTs]): ...
```

Ordering is resolved at compile time. The scheduler validates that explicit orders
don't conflict with data access patterns inferred from `Queries`.

### Stateful Systems

Systems can own persistent state:

```mojo
struct PhysicsSystem:
    var broadphase: BroadphaseCache
    var contacts: List[Contact]
```

Every frame reuses caches without globals or singleton resources.

### Query Supplied by Scheduler

Systems do not build queries or select entities — the scheduler supplies both. In
the prototyped shape, `update` receives a single `Context[*WorldTs]` and fetches
each declared query by value via `context.query[q]()`:

```mojo
struct Context[*WorldTs: ComponentType]:
    def query[q: Query](self) -> Iter2:
        return Iter2()


struct Move(System):
    comptime pos_vel_query = World.filter.include[Position, Velocity]().query(
        is_mut=True
    )
    comptime name_query = World.filter.include[Name]().exclude[
        Position, Velocity
    ]().query()

    comptime Queries = [Self.pos_vel_query, Self.name_query]

    def update[*WorldTs: ComponentType](self, context: Context[*WorldTs]):
        for entity in context.query[Self.pos_vel_query]():
            ref pos = entity.get[Position]()
            ref vel = entity.get[Velocity]()
            pos.x += vel.dx
            pos.y += vel.dy

        for entity in context.query[Self.name_query]():
            ref name = entity.get[Name]()
            print(t"Entity named {name.name}")
```

The scheduler:

1. Reads the system's declared `Queries` at comptime (the `include`, `exclude`, and
   `is_mut` fields).
2. For each query, finds all archetypes whose component mask is a superset of
   `include` and disjoint from `exclude`.
3. Builds a `Context[*WorldTs]` and passes it to `update`; the system pulls an
   iterator per declared query via `context.query[Self.<query>]()`.

The `q: Query` parameter on `Context.query` is a comptime value, so each call site
is monomorphized against the specific declared query — the iterator type, the
`EntityAccessor` shape, and the access checks can all be specialized at compile
time. This is what should make the `# MUST fail!` safety check enforceable: a query
that excludes `Position` should produce an `EntityAccessor` whose `.get[Position]()`
does not typecheck (see [Open Questions](#open-questions)).

This enables:

- Query reuse across systems with identical `include`/`exclude` sets.
- Automatic entity filtering based on component composition, including exclusion.
- Comptime verification that the world's `ComponentManager` knows every component
  referenced in `Queries` (otherwise `get_id_arr[*Ts]` fails at the
  `QueryBuilder.include[*Ts]` / `.exclude[*Ts]` call site).
- A path to compile-time enforcement that `.get[T]()` is only callable for
  components the query actually includes (or, once per-component access modes land,
  that mutation is only allowed on `is_mut` queries).

### Archetype-Based Entity Selection

The scheduler uses declared component access to determine which archetypes to
iterate. A query matches an archetype iff the archetype's component mask is a
superset of `include` and disjoint from `exclude`:

```
Archetype 1: [Position, Velocity]        → matches include=[Position, Velocity], exclude=[]
Archetype 2: [Position, Velocity, Mass]  → matches include=[Position, Velocity], exclude=[]
                                           (Mass is neither included nor excluded)
Archetype 3: [Position, Velocity, Mass]  → does NOT match include=[Position], exclude=[Mass]
Archetype 4: [Position, Transform]       → does NOT match include=[Position, Velocity]
Archetype 5: [Velocity, AudioListener]   → does NOT match include=[Position, Velocity]
```

Only entities in matching archetypes are passed to the system, ensuring minimal
overhead.

### Generic Systems

Systems can be generic types:

```mojo
struct GravitySystem[T: Numeric]:
    ...

struct CopySystem[
    From: Component,
    To: Component
]:
    ...
```

Compile-time specialization is free with type-based systems.

### Composable Plugins

Systems compose into plugins:

```mojo
PhysicsPlugin[
    CollisionSystem,
    GravitySystem,
    BroadphaseSystem
]
```

No registration strings, no IDs, no virtual dispatch.

### No Inheritance

Use traits instead of class inheritance:

```mojo
trait System(Copyable, ImplicitlyDeletable):
    comptime Queries: List[Query]

    def update[*WorldTs: ComponentType](self, context: Context[*WorldTs]):
        ...
```

This allows `Scheduler[S: System]` to specialize on the concrete system type, so
`S.Queries` is known at compile time and the per-system dispatch is monomorphized.

### Runtime Registration for Tooling

Separate compile-time types from runtime metadata:

```mojo
struct RegisteredSystem:
    var type_id: TypeId
    var statistics: SystemStats
    var execution_time: Duration
    var enabled: Bool
    var frequency: Int
    var dependencies: List[TypeId]
```

This provides tooling without sacrificing optimization.

### Compile-Time Schedule Construction

The compiler can construct complete dependency graphs:

```mojo
Schedule[
    StartupSystems,
    UpdateSystems,
    RenderSystems,
]
```

Plugins, game modes, or simulation pipelines assemble at compile time while
permitting lightweight runtime representation for:

- Enabling/disabling systems
- Profiling statistics
- Hot-reloading in development

---

## GPU Acceleration

The declarative system trait is not an end in itself — it is the prerequisite for
GPU acceleration. The current production `System` trait discovers its component
access at call time through `world.query[*T]()` inside `update`. That works on the
CPU but hides the access set from the framework: the scheduler cannot know which
components a system will read or write until the system actually runs. For GPU
dispatch this is fatal — device buffers must be allocated and uploaded _before_ the
kernel launches, and a dependency graph between systems must be built at registration
time.

### Why the Declarative Pattern Matters for GPU

With the declarative `System.Queries` in place (see
[System Metadata is Compile-Time](#system-metadata-is-compile-time)):

1. **Introspection at registration** — `add_system[S]` can walk `S.Queries` at
   comptime, resolve each `include`/`exclude` bitmask to component IDs and type
   names, and pre-register the component access set. No `update` call required.
2. **Pre-allocated transfers** — the `GpuScheduler` knows every component column a
   GPU system will touch before the first frame, so it can pre-size device buffers
   and plan upload/download per archetype.
3. **Dependency graph** — with declared access sets, the scheduler can detect
   read/write conflicts between systems and emit a DAG (see `graph.mojo`), enabling
   parallel CPU/GPU scheduling and overlap with transfers. The sketch's
   `conflicts_with` is the seed of this — currently `include.matches` only, but
   extensible to `is_mut`-aware conflict rules.
4. **Uniform API** — CPU and GPU systems share the same `System` trait surface
   (`comptime Queries`, `update[*WorldTs](self, context: Context[*WorldTs])`); the
   GPU trait only extends it with kernel binding.

### Why Archetypes Map Well to GPU

Archetype storage is already GPU-friendly:

1. Each component column is a contiguous array of trivial types — directly mappable
   to GPU buffers.
2. All entities in an archetype have the same component layout — uniform data shape.
3. Iteration is sequential over entity indices — natural fit for GPU thread indexing.
4. No pointer chasing — flat arrays, no indirection.

The challenge is bridging the gap between Larecs' CPU-side ownership model and Mojo's
GPU execution model (`DeviceContext`, `DeviceBuffer`, `TileTensor`).

### Mojo GPU Primitives

Mojo GPU programming (from `mojo-gpu-fundamentals` skill):

| Concept          | Mojo                                                              |
| ---------------- | ----------------------------------------------------------------- |
| Kernel           | Plain `def kernel(...)` — no decorator                            |
| Launch           | `ctx.enqueue_function[kernel](args, grid_dim=..., block_dim=...)` |
| GPU buffer       | `ctx.enqueue_create_buffer[dtype](count)`                         |
| Copy host↔device | `ctx.enqueue_copy(dst_buf, src_buf)`                              |
| Data view        | `TileTensor[dtype, LayoutType, MutAnyOrigin]`                     |
| Sync             | `ctx.synchronize()`                                               |
| Shared memory    | `stack_allocation[...](layout)` from `layout` package             |
| Thread index     | `global_idx.x`, `thread_idx.x`, `block_idx.x`                     |
| GPU check        | `from std.sys import has_accelerator`                             |

Kernel functions cannot raise. All GPU dimensions should be `comptime`.

### GPU API Design

#### 1. GpuContext — Device Lifecycle

A lightweight handle wrapping `DeviceContext`, stored as a resource or on the World.

```mojo
from std.gpu.host import DeviceContext

@fieldwise_init
struct GpuContext(Movable):
    """Manages GPU device lifecycle for Larecs."""
    var ctx: DeviceContext

    def __init__(out self):
        comptime assert has_accelerator(), "No GPU available"
        self.ctx = DeviceContext()

    def synchronize(mut self):
        self.ctx.synchronize()
```

Usage: store as a resource on the World, or pass to the Scheduler.

#### 2. GpuArchetypeStorage — Per-Archetype GPU Buffers

Extends `_ComponentStorage` concept to hold GPU-side device buffers alongside CPU
buffers. Each active component column gets a `DeviceBuffer[dtype]`.

```mojo
struct GpuArchetypeStorage:
    """GPU-side buffer cache for an archetype's component data.

    Maintains a mapping from component IDs to device buffers.
    Buffers are lazily allocated on first upload.
    """
    var _buffers: Dict[ComponentId, DeviceBuffer]
    var _dirty: Dict[ComponentId, Bool]  # needs upload before kernel launch

    def __init__(out self):
        self._buffers = Dict[ComponentId, DeviceBuffer]()
        self._dirty = Dict[ComponentId, Bool]()

    def upload_component[T: ComponentType](
        mut self,
        ctx: DeviceContext,
        component_id: ComponentId,
        cpu_ptr: UnsafePointer[T, MutUntrackedOrigin],
        count: Int,
    ):
        """Upload a component column from CPU to GPU.

        Args:
            ctx: The device context.
            component_id: The ID of the component.
            cpu_ptr: Pointer to the CPU-side component array.
            count: Number of entities.
        """
        ...

    def download_component[T: ComponentType](
        mut self,
        ctx: DeviceContext,
        component_id: ComponentId,
        cpu_ptr: UnsafePointer[T, MutUntrackedOrigin],
        count: Int,
    ):
        """Download a component column from GPU to CPU.

        Only downloads if the buffer is marked dirty (modified by kernel).
        """
        ...

    def get_buffer[T: ComponentType](
        ref self, component_id: ComponentId
    ) -> DeviceBuffer[dtype_of(T)]:
        """Returns the device buffer for a component column."""
        ...
```

#### 3. GpuSystem Trait

A system that executes its logic on the GPU. The kernel receives `TileTensor` views
of the archetype's component data.

`GpuSystem` extends the declarative `System` trait from
[System Metadata is Compile-Time](#system-metadata-is-compile-time). The system
declares its queries as `comptime Queries`, each carrying an `include`/`exclude`
bitmask and an `is_mut` flag, exactly as on the CPU. The framework introspects
`Queries` at `add_gpu_system` time to pre-allocate device buffers and build the
upload/launch/download plan; `update` then receives a `Context` (or a GPU-specific
`GpuContext` extension) the same way CPU systems do.

```mojo
trait GpuSystem(Copyable, ImplicitlyDeletable, Movable):
    """Trait for GPU-accelerated systems.

    The system specifies (all comptime, declarative):
    - Queries: List[Query] — which components it touches, with is_mut per query
    - Kernel: the kernel function to launch per matching archetype
    - BlockDim: thread block size (grid is derived from archetype count)

    The framework handles (at add_system time, via Queries introspection):
    - Pre-allocating device buffers for every included component
    - Uploading components for mutable queries (or all queries, if read-back
      is needed) before launch
    - Launching the kernel per matching archetype
    - Downloading components for mutable queries after launch
    """

    comptime Queries: List[Query]   # inherited from System; each Query carries
                                    # include + exclude bitmasks and is_mut
    comptime Kernel: def(...) capturing -> None
    comptime BlockDim: Int = 256

    def initialize[
        *ComponentTypes: ComponentType
    ](mut self, mut world: World[*ComponentTypes]) raises:
        pass

    def update[*WorldTs: ComponentType](
        mut self, context: Context[*WorldTs]
    ) raises:
        ...   # framework-supplied default: launch Kernel per archetype

    def finalize[
        *ComponentTypes: ComponentType
    ](mut self, mut world: World[*ComponentTypes]) raises:
        pass
```

Per-query `is_mut` drives the upload/download direction: components on a mutable
query are downloaded after launch; components on an immutable query only need
upload. Whether finer-grained per-component access modes are needed for GPU is an
open question (see [Open Questions](#open-questions)) — the current per-query
`is_mut` matches the CPU sketch and is enough to bootstrap the pipeline.

#### 4. GpuScheduler — Orchestrating GPU + CPU Systems

Extends `Scheduler` with GPU awareness. Manages the `GpuContext` and coordinates
data transfers.

```mojo
struct GpuScheduler[*ComponentTypes: ComponentType](Movable):
    """Scheduler that supports both CPU and GPU systems.

    GPU systems are launched on matching archetypes. Data is
    automatically uploaded before kernel execution and downloaded
    after.
    """

    var _base: Scheduler[*ComponentTypes]
    var _gpu_ctx: GpuContext
    var _gpu_storages: Dict[Int, GpuArchetypeStorage]  # archetype_index -> storage

    def __init__(out self):
        self._base = Scheduler[*ComponentTypes]()
        self._gpu_ctx = GpuContext()
        self._gpu_storages = Dict[Int, GpuArchetypeStorage]()

    def add_system[S: System](mut self, var system: S):
        """Add a CPU system."""
        self._base.add_system(system^)

    def add_gpu_system[S: GpuSystem](mut self, var system: S):
        """Add a GPU system."""
        ...

    def run(mut self, steps: Int) raises:
        self._base.initialize()
        self._update(steps)
        self._base.finalize()

    def _update(mut self, steps: Int) raises:
        for _ in range(steps):
            # Run CPU systems
            self._base.update(1)
            # Run GPU systems (upload, launch, download)
            ...
```

### Kernel Signature Pattern

User-defined kernels receive `TileTensor` views over archetype component data.

#### Simple 1D Kernel

```mojo
from layout import TileTensor, row_major

comptime dtype = DType.float32

def velocity_kernel(
    positions: TileTensor[dtype, row_major[N], MutAnyOrigin],
    velocities: TileTensor[dtype, row_major[N], MutAnyOrigin],
    count: Int,
):
    var tid = global_idx.x
    if tid < count:
        positions[tid] += velocities[tid]
```

#### Tiled 2D Kernel with Shared Memory

```mojo
comptime TILE = 16

def matmul_kernel(
    A: TileTensor[dtype, row_major[M, K], MutAnyOrigin],
    B: TileTensor[dtype, row_major[K, N], MutAnyOrigin],
    C: TileTensor[dtype, row_major[M, N], MutAnyOrigin],
):
    comptime assert A.flat_rank == 2
    # ... shared memory, tiling, etc.
```

#### Parametric Kernel (Any Layout)

```mojo
def scale_kernel[
    LT: TensorLayout,
](
    tensor: TileTensor[dtype, LT, MutAnyOrigin],
    factor: Scalar[dtype],
    count: Int,
):
    var tid = global_idx.x
    if tid < count:
        tensor[tid] = tensor[tid] * factor
```

### Data Flow

For each GPU system update step:

```
1. For each archetype matching the system's query:
   a. Get archetype's entity count
   b. For each InputComponent:
      - If no device buffer exists: allocate + upload
      - If device buffer exists but CPU modified it: re-upload
   c. Create TileTensor views from device buffers
   d. Launch kernel: ctx.enqueue_function[kernel](tensors..., count,
        grid_dim=ceildiv(count, block_dim), block_dim=BLOCK_SIZE)
   e. Mark OutputComponent buffers as dirty
   f. ctx.synchronize()

2. For each archetype with dirty output buffers:
   a. Download output component data back to CPU
   b. Mark buffers clean
```

### Dirty Tracking

A simple flag per component column tracks whether the CPU side has been modified
since the last upload. This avoids redundant transfers.

```mojo
# After CPU writes to a component:
world.set[Position](entity, new_pos)
# Mark Position as dirty for this archetype

# Before kernel launch:
if storage.is_dirty[Position](component_id):
    storage.upload_component[Position](ctx, component_id, ptr, count)
```

### Lifecycle Hooks

`GpuSystem` can override `initialize` and `finalize` for one-time setup. The
`Queries` list and `Kernel` binding are declarative comptime fields; `update`'s
default implementation launches the kernel per matching archetype, so systems
typically only override it for custom multi-archetype orchestration.

```mojo
@fieldwise_init
struct MyGpuSystem(GpuSystem):
    comptime move_query = (
        World.filter.include[Position, Velocity]().query(is_mut=True)
    )
    comptime Queries = [Self.move_query]
    comptime Kernel = move_kernel
    comptime BlockDim = 256

    def initialize[*ComponentTypes: ComponentType](
        mut self, mut world: World[*ComponentTypes]
    ) raises:
        # Optional: pre-allocate GPU buffers, validate dimensions
        pass

    def update[*WorldTs: ComponentType](
        mut self, context: Context[*WorldTs]
    ) raises:
        # Default impl launches Kernel per archetype; override only for
        # custom multi-archetype orchestration.
        ...

    def finalize[*ComponentTypes: ComponentType](
        mut self, mut world: World[*ComponentTypes]
    ) raises:
        # Optional: cleanup, sync remaining buffers
        pass
```

### Kernel Launch Helper

Internal helper that orchestrates the per-archetype GPU dispatch:

```mojo
def _launch_gpu_kernel[
    KernelType: def(...) capturing -> None,
    *ComponentTypes: ComponentType,
](
    mut ctx: GpuContext,
    mut arch_storage: GpuArchetypeStorage,
    archetype: Archetype[*ComponentTypes],
    kernel: KernelType,
    input_ids: InlineArray[ComponentId, num_inputs],
    output_ids: InlineArray[ComponentId, num_outputs],
    block_dim: Int = 256,
):
    """Launch a GPU kernel for a single archetype.

    1. Upload dirty input components
    2. Create TileTensor views
    3. Launch kernel
    4. Mark output components dirty
    """
    count = len(archetype)

    # Upload inputs
    comptime for i in range(num_inputs):
        arch_storage.upload_if_dirty(ctx, input_ids[i], archetype)

    # Create tensor views
    # ... (bind device buffers to TileTensor)

    # Launch
    grid_dim = ceildiv(count, block_dim)
    ctx.ctx.enqueue_function[kernel](
        tensors...,
        count,
        grid_dim=grid_dim,
        block_dim=block_dim,
    )

    # Mark outputs dirty
    comptime for i in range(num_outputs):
        arch_storage.mark_dirty(output_ids[i])
```

### SoA Component Layout for GPU

Larecs stores components in SoA layout (one array per component type). For GPU
kernels that need to access multiple components of the same entity, there are two
approaches:

#### Approach A: Separate TileTensors per Component (Recommended)

Each component gets its own `TileTensor`. The kernel receives multiple tensors and
indexes them with the same entity index.

```mojo
def physics_kernel(
    positions_x: TileTensor[DType.float32, row_major[N], MutAnyOrigin],
    positions_y: TileTensor[DType.float32, row_major[N], MutAnyOrigin],
    velocities_x: TileTensor[DType.float32, row_major[N], MutAnyOrigin],
    velocities_y: TileTensor[DType.float32, row_major[N], MutAnyOrigin],
    count: Int,
):
    var tid = global_idx.x
    if tid < count:
        positions_x[tid] += velocities_x[tid]
        positions_y[tid] += velocities_y[tid]
```

**Pros:** Matches Larecs' existing SoA storage. Zero-copy between archetype and
kernel.
**Cons:** Verbose for kernels touching many components.

#### Approach B: Struct-of-Arrays Packing

Pack related components into a single interleaved buffer before launch. More complex
setup, but cleaner kernel signatures for multi-component operations.

**Recommendation:** Start with Approach A. It maps directly to existing storage and
avoids a packing step. Add Approach B later as an optimization for common patterns
(e.g., position+velocity packed for physics).

### Complete GPU Usage Example

```mojo
from larecs import World, Scheduler, System
from larecs.gpu import GpuScheduler, GpuSystem, GpuContext
from layout import TileTensor, row_major
from std.gpu import global_idx
from std.math import ceildiv

# Components
@fieldwise_init
struct Position(Copyable, Movable):
    var x: Float32
    var y: Float32

@fieldwise_init
struct Velocity(Copyable, Movable):
    var x: Float32
    var y: Float32

# GPU kernel
comptime BLOCK_SIZE = 256

def move_kernel(
    positions: TileTensor[DType.float32, row_major[N], MutAnyOrigin],
    velocities: TileTensor[DType.float32, row_major[N], MutAnyOrigin],
    count: Int,
):
    var tid = global_idx.x
    if tid < count:
        # positions are stored as SoA: x[N] and y[N]
        # Kernel operates on raw component arrays
        positions[tid] += velocities[tid]

# GPU System
@fieldwise_init
struct MoveSystem(GpuSystem):
    comptime move_query = (
        World.filter.include[Position, Velocity]().query(is_mut=True)
    )
    comptime Queries = [Self.move_query]
    comptime Kernel = move_kernel
    comptime BlockDim = BLOCK_SIZE

    def update[*WorldTs: ComponentType](
        mut self, context: Context[*WorldTs]
    ) raises:
        # Framework default: for each archetype matching the query,
        # 1. Upload Position and Velocity to GPU
        # 2. Launch move_kernel per archetype
        # 3. Download Position (query is_mut=True) back to CPU
        pass

# CPU System (mixed usage) — uses the same declarative System trait
@fieldwise_init
struct ClampSystem(System):
    comptime clamp_query = World.filter.include[Position]().query(is_mut=True)
    comptime Queries = [Self.clamp_query]

    def update[*WorldTs: ComponentType](
        mut self, context: Context[*WorldTs]
    ) raises:
        for entity in context.query[Self.clamp_query]():
            ref pos = entity.get[Position]()
            pos.x = max(-100.0, min(100.0, pos.x))
            pos.y = max(-100.0, min(100.0, pos.y))

# Run
def main() raises:
    scheduler = GpuScheduler[Position, Velocity]()
    scheduler.add_system(MoveSystem())
    scheduler.add_system(ClampSystem())
    scheduler.run(100)
```

---

## Open Questions

These are the design decisions the sketch leaves unresolved and that need to be
settled before the trait stabilizes:

1. **Access mode granularity** — the sketch settled on a single `is_mut: Bool` per
   `Query` (all included components are either mutable or immutable together). This
   is enough to drive upload/download direction on GPU and conflict detection on
   CPU, but it is coarser than the original per-component `Read[*Ts]` / `Write[*Ts]`
   vision. Open: is per-query `is_mut` sufficient in practice, or do we need
   per-component access modes for cases like "read Velocity, write Position" in a
   single query? Candidates if per-component is needed:
    - A parallel `InlineArray[Access, N]` field on `Query`, populated by
      `QueryBuilder.read[*Ts]` / `.write[*Ts]` / `.read_write[*Ts]` chained builders.
    - Separate `include_read` / `include_write` bitmasks on `Query` (cheaper to
      intersect, but loses per-component pairing when a component appears in both).
2. **Compile-time enforcement of `.get[T]()` against the query** — the sketch marks
   `ref pos = entity.get[Position]()` inside the `name_query` loop (which excludes
   `Position`) with `# MUST fail!`. Today the `EntityAccessor.get[T]` body is a
   stubbed `_type_is_eq` dispatch and does not actually enforce this. The goal is
   for `Context.query[q]()` to return an iterator whose `EntityAccessor` is
   specialized at compile time so that `.get[T]()` only typechecks for components
   in `q.include` (and, for mutation, only when `q.is_mut`). How to thread the
   query's comptime include/exclude set into the accessor's type — without
   exploding monomorphization — is open.
3. **Conflict detection beyond `include.matches`** — the sketch's `conflicts_with`
   treats any `include` overlap as a conflict, ignoring `is_mut` and `exclude`. Two
   immutable queries over the same component are parallel-safe and should not
   conflict; a mutable query and an immutable query over the same component do
   conflict. Extending `conflicts_with` to be `is_mut`-aware (and eventually
   per-component-access-aware) is needed before the dependency graph is sound.
4. **`List[Query]` as a comptime value** — the sketch now exercises
   `comptime Queries: List[Query]` in three places: the `Move`/`Collision` struct
   bodies, `conflicts_with`'s `comptime for query1 in SystemType.Queries`, and
   `write_system`'s `comptime for query_id in range(len(SystemType.Queries))`.
   Comptime `List[Query]` is load-bearing and appears to work. The fallback
   (variadic comptime parameter on the system, `struct Move(System[Q0, Q1])`) is
   noted only if comptime `List` turns out to have limitations not yet hit.
5. **Coexistence with the current `System` trait** — the production trait
   (`src/larecs/scheduler.mojo`) uses
   `update[*ComponentTypes](mut self, mut world: World[*ComponentTypes])` with
   `world.query[T]()` called inside. The declarative trait is intended to _replace_
   it, but during the transition the two must coexist — likely via a separate
   `DeclaredSystem` trait or a superset trait that the scheduler dispatches on.
6. **Resources** — `Resource` access is in the original design but absent from the
   sketch. Likely modeled as a second comptime field (`comptime Resources:
List[ResourceQuery]`) parallel to `Queries`, with the scheduler injecting
   resource references into `update` (or onto the `Context`).
7. **World type parameter** — the sketch introduces `_World[*WorldTs]` with a
   `comptime filter` field, and systems reference `World.filter.include[...]()` via
   a comptime alias `comptime World = _World[Position, Velocity, Name]`. This
   statically binds each system to one world shape, matching the existing
   `World[*ComponentTypes]` model. Whether a system can be polymorphic over world
   shapes (e.g. for plugins) is open.

---

## Implementation Strategy

### Phase 0: Declarative System Trait (CPU)

- [x] Prototype `QueryBuilder[*WorldTs]` as a `Movable` fluent builder with
      `.include[*Ts]()` / `.exclude[*Ts]()` mutating `self` via `|=` and returning
      `self^`, plus `.query(is_mut=...)` (see `system_sketch.mojo`)
- [x] Prototype `Query` carrying `include`, `exclude`, and `is_mut` fields
- [x] Prototype `_World[*WorldTs]` with a `comptime filter` field as the canonical
      entry point for building queries
- [x] Prototype `System` trait with `comptime Queries: List[Query]` and
      `update[*WorldTs: ComponentType](self, context: Context[*WorldTs])`
- [x] Prototype `Context[*WorldTs]` with `query[q: Query](self) -> Iterator`
- [x] Prototype `EntityAccessor` with `.get[T: ComponentType]()`
- [x] Prototype `Scheduler` storing `List[Tuple[UnsafeBox, List[Query]]]` with
      `add_system[S]`, `get_conflicts`, and `conflicts_with`
- [x] Prototype comptime introspection of `SystemType.Queries` (`write_system`
      debug printer resolving include/exclude bitmasks to component type names)
- [ ] Enforce at compile time that `.get[T]()` is only callable for components in
      `q.include` (and mutation only when `q.is_mut`) — the `# MUST fail!` case
- [ ] Make `conflicts_with` `is_mut`-aware (immutable-vs-immutable over the same
      component is not a conflict)
- [ ] Decide whether per-query `is_mut` is sufficient, or add per-component access
      modes (`QueryBuilder.read[*Ts]` / `.write[*Ts]`) — see [Open Questions](#open-questions)
- [ ] Migrate `src/larecs/scheduler.mojo` `System` trait to the declarative shape
      (or introduce a superset trait and dispatch on it)
- [ ] Implement scheduler that materializes `Context` and dispatches
      `context.query[q]()` per declared `Query`
- [ ] Implement archetype-based entity selection from `Queries[i].include` / `exclude`
- [ ] Wire `add_system[S]` to feed the access set into `graph.mojo` so the
      dependency graph is built at registration time
- [ ] Model `Resource` access (likely `comptime Resources: List[ResourceQuery]`
      on the system, injected onto `Context`)
- [ ] Add generic system support (`struct GravitySystem[T: Numeric](System)`)

### Phase 1: GPU Foundation

- [ ] Add `GpuContext` struct (thin wrapper around `DeviceContext`)
- [ ] Add `gpu` submodule to `src/larecs/`
- [ ] Add `GpuArchetypeStorage` — manages per-archetype device buffers
- [ ] Extend `World` with optional GPU storage per archetype (via a
      `Dict[Int, GpuArchetypeStorage]` keyed by archetype index)

### Phase 2: GPU System Integration

- [ ] Define `GpuSystem` trait extending the declarative `System` trait with
      `Kernel` and `BlockDim` comptime fields
- [ ] Implement `GpuScheduler` — extends `Scheduler` with GPU dispatch, consuming
      the declared `Queries` to pre-allocate buffers at `add_gpu_system` time
- [ ] Implement the upload/launch/download pipeline driven by `Queries[i].is_mut`
      (upload all included components; download only mutable-query components)
- [ ] Add dirty tracking for component columns

### Phase 3: Ergonomics

- [ ] Refine `QueryBuilder` ergonomics — sensible defaults, clear error messages on
      `include`/`exclude` conflicts and on `is_mut` misuse
- [ ] Support parametric kernels via comptime layout inference
- [ ] Add `gpu_query` convenience that returns `TileTensor` views directly
- [ ] Support shared memory allocation helpers
- [ ] Create plugin composition system
- [ ] Add runtime `RegisteredSystem` for tooling (statistics, enable/disable,
      frequency)

### Phase 4: Optimization

- [ ] Implement double-buffering for overlapping compute and transfer
- [ ] Add batch archetype processing (launch all archetypes as one kernel)
- [ ] Use the registration-time dependency graph to overlap CPU and GPU systems
- [ ] Support multi-GPU via `DeviceContext` per device
- [ ] Profile and tune block/grid sizes per archetype

---

## Limitations

1. **Trivial types only** — GPU buffers require trivial types (no heap allocation).
   Larecs already enforces this for components.

2. **No entity mutation** — GPU systems cannot add/remove entities or change
   component masks. They only modify component values. Structural changes remain
   CPU-side.

3. **No dynamic dispatch** — Kernels are `comptime`-resolved. The system must know
   all kernel types at compile time. The declarative `System.Queries` list is also
   comptime-only, so a system's query set cannot be mutated at runtime.

4. **No fine-grained locking** — GPU execution is asynchronous. The World must not
   be mutated by CPU systems while GPU kernels are in-flight. The `synchronize()`
   call acts as a barrier.

5. **Single GPU** — Initial implementation targets one GPU. Multi-GPU requires
   separate `DeviceContext` instances and explicit data routing.

6. **Component size alignment** — GPU buffer sizes must be aligned to device
   requirements. The framework should pad buffers to the next compatible boundary.

---

## Future Considerations

- **GPU-only components**: Components that exist only on GPU (e.g., intermediate
  compute results). Skip CPU upload/download.
- **Persistent kernels**: Kernels that stay on GPU across frames, only uploading
  delta data.
- **Indirect dispatch**: Use GPU-generated counts for variable-size archetype
  processing.
- **Compute graph**: Build a DAG of GPU operations for automatic dependency
  resolution and overlap.
- **SIMD systems**: CPU-side vectorized systems using `vectorize` — not GPU, but
  leverages the same archetype SoA layout for SIMD processing.

---

## Inspiration Sources

- **Bevy**: System signature declares data access, scheduler infers dependencies
- **Flecs**: Rich runtime metadata and tooling, kept separate from execution
- **Legion**: Clear separation between queries and systems
- **Unity DOTS**: Dependency analysis and parallel execution emphasis
