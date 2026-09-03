from larecs import (
    World,
    Scheduler,
    System,
    ResourceType,
    Resources,
    ComponentType,
    SystemContext,
    KernelContext,
    Filter,
)
from std.testing import *


@fieldwise_init
struct MeanState(ResourceType):
    var value: Float64


struct UpdateOnlySystem(System):
    var updates: Int

    def __init__(out self):
        """Construct an update-only system."""
        self.updates = 0

    def update(mut self, mut context: SystemContext[...]) raises:
        """Adds one entity during each update.

        Args:
            context: The system context.
        """
        self.updates += 1
        _ = context.world[].storage.add_entity(1)


def test_scheduler_default_lifecycle_hooks() raises:
    """Systems can rely on default initialize and finalize hooks."""
    var scheduler = Scheduler[Int]()
    scheduler.add_system(UpdateOnlySystem())
    scheduler.run(3)
    assert_equal(len(scheduler.world), 3)


@fieldwise_init
struct TestSystem[copies: Int, count: Int = 10](System):
    var a: Int

    def __init__(out self):
        self.a = 0

    def initialize(mut self, mut context: SystemContext[...]) raises:
        assert_equal(self.a, 0)
        _ = context.world[].storage.add_entities(self.a, count=Self.count)
        self.a = 1

    def update(mut self, mut context: SystemContext[...]) raises:
        assert_equal(self.a, 1)
        assert_equal(len(context.world[]), Self.count * Self.copies)

        comptime filter = Filter().include[Int]()

        def increment_entities(context: KernelContext[filter]):
            for entity in context:
                entity.get[Int]() += 1

        context.run[increment_entities]()

    def finalize(mut self, mut context: SystemContext[...]) raises:
        var sum = 0
        var counter = 0

        comptime filter = Filter().include[Int]()

        def sum_entities(
            context: KernelContext[filter],
        ) {mut sum, mut counter}:
            for entity in context:
                sum += entity.get[Int]()
                counter += 1

        context.run(sum_entities)

        assert_equal(counter, Self.count * Self.copies)

        context.world[].resources.set[add_if_not_found=True](
            MeanState(Float64(sum) / Float64(counter))
        )


def test_test_system() raises:
    var scheduler = Scheduler[Int, Float64]()
    scheduler.add_system(TestSystem[2]())
    scheduler.add_system(TestSystem[2]())
    scheduler.run(3)
    assert_equal(
        scheduler.world.resources.get[MeanState]().value,
        6,
    )


@fieldwise_init
struct Scale(ResourceType):
    var value: Int


def scale_entities(
    context: KernelContext[Filter().include[Int](), Resources[Scale]()]
):
    """Multiplies every matching entity's value by the `Scale` resource."""
    ref scale = context.resources.get[Scale]()
    for entity in context:
        entity.get[Int]() *= scale.value


def test_kernel_context_required_resources() raises:
    """A kernel can declare and read a resource via `KernelContext.resources`."""
    var world = World[Int]()
    world.resources.add(Scale(3))
    _ = world.storage.add_entities(1, count=5)

    var context = SystemContext(world)
    context.run[scale_entities]()

    var total = 0
    for entity in world.storage.query[Int]():
        total += entity.get[Int]()

    assert_equal(total, 15)


comptime functions = __functions_in_module()


def main() raises:
    TestSuite.discover_tests[functions]().run()
