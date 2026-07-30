+++
type = "docs"
title = "Systems and the scheduler"
weight = 60
+++

A key feature of entity-component systems is that
operations on the entities are organized in systems,
which operate independently from one another and can
be added or removed as required.

## Systems

Systems can be thought of as functions that take a
{{< api World >}} instance and perform operations on the
world's entities and/or resources. However, to allow storing intermediate
variables between multiple system calls, and to
support special initialization and finalization operations,
systems are expressed as structs implementing the
{{< api System >}} trait. This trait requires
systems to implement {{< api System.initialize initialize >}}, and
{{< api System.finalize finalize >}} methods, called before or
after the ECS run, respectively, and an {{< api System.update update >}}
method, called at every step of the ECS run.
Each of these methods takes a {{< api World >}} instance
on which they perform the desired operations.

```mojo {doctest="guide_systems_scheduler" global=true}
from larecs import World, System

@fieldwise_init
struct Move(System):

    # This is executed once at the beginning
    fn initialize(mut self, mut world: World) raises:
        # We do not need to do anything here
        pass

    # This is executed in each step
    fn update(mut self, mut world: World) raises:

        # Move all entities with a position and velocity
        for entity in world.storage.query[Position, Velocity]():
            entity.get[Position]().x += entity.get[Velocity]().dx
            entity.get[Position]().y += entity.get[Velocity]().dy

    # This is executed at the end
    fn finalize(mut self, mut world: World) raises:
        # We do not need to do anything here
        pass
```

## Scheduler

The {{< api Scheduler >}} is responsible for executing the systems
in the correct order. A `Scheduler` contains a {{< api World >}} instance
and a list of systems. The scheduler has
{{< api Scheduler.initialize initialize >}},
{{< api Scheduler.update update >}}, and {{< api Scheduler.finalize finalize >}}
methods, which call the respective functions of all
considered systems in the order they are added to the scheduler.
In addition, the scheduler has a {{< api Scheduler.run run >}}
method, which initializes the systems, runs them a desired
number of times, and finalizes them.

To construct an example of a scheduler, let us define
further systems for adding entities and logging their positions.

```mojo {doctest="guide_systems_scheduler" global=true hide=true}
@fieldwise_init
struct Position(Movable, Copyable):
    var x: Float64
    var y: Float64

@fieldwise_init
struct Velocity(Movable, Copyable):
    var dx: Float64
    var dy: Float64
```

```mojo {doctest="guide_systems_scheduler" global=true}
@fieldwise_init
struct AddMovers[count: Int](System):

    # This is executed once at the beginning
    fn initialize(mut self, mut world: World) raises:
        _ = world.add_entities(
            Position(0, 0), Velocity(1, 0), count=10
        )

    # This is executed in each step
    fn update(mut self, mut world: World) raises:
        # We do not need to do anything here
        pass

    # This is executed at the end
    fn finalize(mut self, mut world: World) raises:
        # We do not need to do anything here
        pass

@fieldwise_init
struct Logger[interval: Int](System):

    var _logging_step: Int

    fn __init__(out self):
        self._logging_step = 0

    fn _print_positions(self, mut world: World) raises:
        for entity in world.storage.query[Position, Velocity]():
            ref pos = entity.get[Position]()
            print("(", pos.x, ",", pos.y, ")")

    # This is executed once at the beginning
    fn initialize(mut self, mut world: World) raises:
        print("Starting with", len(world.storage.query[Position, Velocity]()),
              "moving entities.")

    # This is executed in each step
    fn update(mut self, mut world: World) raises:
        if not self._logging_step % self.interval:
            print("Current Mover positions:")
            self._print_positions(world)
        self._logging_step += 1

    # This is executed at the end
    fn finalize(mut self, mut world: World) raises:
        print("Final positions:")
        self._print_positions(world)
```

Now we can create a scheduler and add the systems to it.
Import the scheduler struct:

```mojo {doctest="guide_systems_scheduler" global=true}
from larecs import Scheduler
```

Create and run the scheduler:

```mojo {doctest="guide_systems_scheduler"}
# Create a scheduler
scheduler = Scheduler[Position, Velocity]()

# Add the systems to the scheduler
scheduler.add_system(AddMovers[10]())
scheduler.add_system(Move())
scheduler.add_system(Logger[2]())

# Run the scheduler for 10 steps
scheduler.run(10)
```
