# SKIP_ASAN
# SKIP_DEBUG

"""CPU/GPU execution and host copy-back after spatial maintenance."""

from std.sys import has_accelerator
from std.testing import assert_equal, assert_false, TestSuite
from larecs import (
    World,
    Filter,
    SpatialClassifier,
    SystemContext,
    KernelContext,
)
from larecs.entity import EntityAccessor


@fieldwise_init
struct Position(Copyable, TrivialRegisterPassable):
    """GPU-safe classifier input and writable kernel column."""

    var value: Int32


@fieldwise_init
struct Payload(Copyable, TrivialRegisterPassable):
    """Column moved together with positions but not used for classification."""

    var value: Int32


comptime spatial_filter = Filter().read[Position]()


@fieldwise_init
struct Policy(SpatialClassifier):
    """Nonnegative test positions are ordered by their value."""

    comptime Accessor = EntityAccessor[spatial_filter]

    def classify(self, entity: Self.Accessor) raises -> UInt64:
        """Returns a value-based key.

        Args:
            entity: Position accessor for one host row.

        Returns:
            The position as an unsigned ordering key.
        """
        return UInt64(entity.get[Position]().value)


def update(context: KernelContext[Filter().include[Position, Payload]()]):
    """Reverses positions and updates the associated payload.

    Args:
        context: Component columns on either execution target.
    """
    for entity in context:
        entity.get[Position]().value = 10 - entity.get[Position]().value
        entity.get[Payload]().value += 1


def _check_execution[on_gpu: Bool]() raises:
    """Maintains rows before and after execution and checks copied-back values.

    Parameters:
        on_gpu: Whether to run on the actual accelerator.

    Raises:
        Error: If execution, maintenance, or validation fails.
    """
    var world = World[Position, Payload]()
    var a = world.storage.add_entity(Position(3), Payload(30))
    var b = world.storage.add_entity(Position(1), Payload(10))
    world.register_spatial_classifier[spatial_filter](Policy())
    world.maintain_spatial()
    var index = world.storage._entity_locations[a.get_id()].archetype_index
    assert_equal(world.storage._archetypes[index].get_entity(0), b)
    var context = SystemContext(world)
    context.run[update, on_gpu=on_gpu]()
    assert_equal(context.world[].storage.get[Position](a).value, 7)
    assert_equal(context.world[].storage.get[Payload](a).value, 31)
    assert_equal(context.world[].storage.get[Position](b).value, 9)
    assert_equal(context.world[].storage.get[Payload](b).value, 11)
    # Copy-back/kernel completion does not reorder; explicit maintenance does.
    assert_equal(context.world[].storage._archetypes[index].get_entity(0), b)
    context.world[].maintain_spatial()
    assert_equal(context.world[].storage._archetypes[index].get_entity(0), a)
    context.run[update, on_gpu=on_gpu]()
    assert_equal(context.world[].storage.get[Position](a).value, 3)
    assert_equal(context.world[].storage.get[Payload](a).value, 32)
    assert_equal(context.world[].storage.get[Position](b).value, 1)
    assert_equal(context.world[].storage.get[Payload](b).value, 12)
    assert_false(context.world[].storage.is_locked())


def test_cpu_execution_after_spatial_maintenance() raises:
    """Runs the same kernel on CPU before and after reordering.

    Raises:
        Error: If validation fails.
    """
    _check_execution[False]()


def test_gpu_execution_after_spatial_maintenance() raises:
    """Exercises real GPU upload and copy-back when an accelerator is available.

    Raises:
        Error: If validation fails.
    """
    comptime if not has_accelerator():
        print("SKIP: spatial GPU execution; no accelerator support")
        return
    else:
        var probe = World[Position, Payload]()
        if not probe._device_storage:
            print("SKIP: spatial GPU execution; no working device")
            return
        _check_execution[True]()
        print("Executed spatial maintenance integration on actual GPU")


def main() raises:
    """Runs spatial execution integration tests.

    Raises:
        Error: If a test fails.
    """
    TestSuite.discover_tests[__functions_in_module()]().run()
