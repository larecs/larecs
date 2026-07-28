from larecs import World, Scheduler, System, ResourceType, ComponentType
from std.testing import *


@fieldwise_init
struct MeanState(ResourceType):
    var value: Float64


struct UpdateOnlySystem(System):
    var updates: Int

    def __init__(out self):
        """Construct an update-only system."""
        self.updates = 0

    def update[
        *ComponentTypes: ComponentType
    ](mut self, mut world: World[*ComponentTypes]) raises:
        """Adds one entity during each update.

        Parameters:
            ComponentTypes: The component types in the world.

        Args:
            world: The world to update.
        """
        self.updates += 1
        _ = world.storage.add_entity(1)


def test_scheduler_default_lifecycle_hooks() raises:
    """Systems can rely on default initialize and finalize hooks."""
    scheduler = Scheduler[Int]()
    scheduler.add_system(UpdateOnlySystem())
    scheduler.run(3)
    assert_equal(len(scheduler.world), 3)


@fieldwise_init
struct TestSystem[copies: Int, count: Int = 10](System):
    var a: Int

    def __init__(out self):
        self.a = 0

    def initialize(mut self, mut world: World) raises:
        assert_equal(self.a, 0)
        _ = world.storage.add_entities(self.a, count=Self.count)
        self.a = 1

    def update(mut self, mut world: World) raises:
        assert_equal(self.a, 1)
        assert_equal(len(world), Self.count * self.copies)
        for entity in world.storage.query[Int]():
            entity.get[Int]() += 1

    def finalize(mut self, mut world: World) raises:
        sum = 0
        counter = 0
        for entity in world.storage.query[Int]():
            sum += entity.get[Int]()
            counter += 1
        world.resources.set[add_if_not_found=True](
            MeanState(Float64(sum) / Float64(counter))
        )


def test_test_system() raises:
    scheduler = Scheduler[Int, Float64]()
    scheduler.add_system(TestSystem[2]())
    scheduler.add_system(TestSystem[2]())
    scheduler.run(3)
    assert_equal(
        scheduler.world.resources.get[MeanState]().value,
        6,
    )


comptime functions = __functions_in_module()


def main() raises:
    TestSuite.discover_tests[functions]().run()
