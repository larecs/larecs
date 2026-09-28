# SKIP_ASAN
# SKIP_DEBUG

# Every GPU test file needs both markers above: a `for entity in context`
# GPU kernel reliably crashes Apple's Metal compiler when compiled with
# `-g`. See "Known issues" in AGENTS.md for the full writeup.

from std.gpu import global_idx
from std.sys import has_accelerator
from std.sys.info import is_gpu
from std.testing import *

from larecs import (
    World,
    SystemContext,
    KernelContext,
    Filter,
    Resources,
    ResourceType,
    Int32DictResource,
    StringDictResource,
    Int32DictView,
    StringDictView,
    GPUResource,
)
from larecs.resource import ResourceEncoder


# Required resources must be trivially movable for raw-byte transfer.
# Scale contains only an Int32 and needs no TrivialRegisterPassable conformance.
@fieldwise_init
struct Scale(ResourceType):
    var value: Int32


def scale_entities(
    context: KernelContext[Filter().include[Int32](), Resources[Scale]()]
):
    """Multiplies every matching entity's value by the `Scale` resource."""
    ref scale = context.resources.get[Scale]()
    for entity in context:
        entity.get[Int32]() *= scale.value


def test_kernel_context_required_resources_on_gpu() raises:
    """A GPU kernel can declare and read a resource via `KernelContext.resources`.
    """
    comptime if not has_accelerator():
        return

    var world = World[Int32]()
    world.resources.add(Scale(3))
    _ = world.storage.add_entities(Int32(1), count=5)

    var context = SystemContext(world)
    context.run[scale_entities, on_gpu=True]()

    var total: Int32 = 0
    for entity in world.storage.query[Filter().include[Int32]()]():
        total += entity.get[Int32]()

    assert_equal(total, 15)


def overwrite_scale(
    context: KernelContext[Filter().include[Int32](), Resources[Scale]()]
):
    """Overwrites the `Scale` resource with a fixed value.

    Only the first thread writes, avoiding concurrent resource mutation.

    Args:
        context: Matching component rows and the shared scale resource.
    """
    comptime if is_gpu():
        if global_idx.x != 0:
            return
    context.resources.get[Scale]() = Scale(42)


def test_kernel_context_resource_mutation_is_copied_back_to_host() raises:
    """A resource mutated on the GPU is copied back to host after the kernel runs.
    """
    comptime if not has_accelerator():
        return

    var world = World[Int32]()
    world.resources.add(Scale(3))
    _ = world.storage.add_entities(Int32(1), count=5)

    var context = SystemContext(world)
    context.run[overwrite_scale, on_gpu=True]()

    assert_equal(world.resources.get[Scale]().value, 42)


def update_with_local_captures(
    context: KernelContext[Filter().include[Int32](), Resources[Scale]()]
):
    """Uses closures capturing variables local to each GPU thread.

    Args:
        context: Matching integer components and the shared scale resource.
    """
    var factor = context.resources.get[Scale]().value
    var processed: Int32 = 0

    def transform(value: Int32) {imm factor, mut processed} -> Int32:
        """Transforms one component and counts this thread's processed rows.

        Args:
            value: The component value to scale.

        Returns:
            The scaled value plus this thread's processed row count.
        """
        processed += 1
        return value * factor + processed

    for entity in context:
        entity.get[Int32]() = transform(entity.get[Int32]())


def test_gpu_kernel_local_captures() raises:
    """Captures kernel-local values without borrowing host stack memory.

    Raises:
        Error: If execution fails or a component has an unexpected value.
    """
    comptime if not has_accelerator():
        return
    var world = World[Int32]()
    world.resources.add(Scale(3))
    # More than one block, with a partially populated final block.
    _ = world.storage.add_entities(Int32(2), count=37)
    var context = SystemContext(world)
    context.run[update_with_local_captures, on_gpu=True]()
    for entity in world.storage.query[Filter().include[Int32]()]():
        assert_equal(entity.get[Int32](), 7)


def lookup_int32_dict(
    context: KernelContext[
        Filter().include[Int32](), Resources[Int32DictResource]()
    ]
):
    """Replaces each integer key with its dictionary value or -1.

    Args:
        context: Matching integer components and the dictionary resource.
    """
    var lookup = context.resources.get[Int32DictResource]()
    for entity in context:
        var key = entity.get[Int32]()
        entity.get[Int32]() = lookup.get_or(key, -1)


def test_gpu_int32_dict_resource_lookup() raises:
    """Looks up present and absent keys, then observes a host edit on rerun.

    Raises:
        Error: If GPU execution or an assertion fails.
    """
    comptime if not has_accelerator():
        return

    var world = World[Int32]()
    var dictionary = Int32DictResource()
    dictionary.entries[2] = 20
    dictionary.entries[-3] = 30
    dictionary.entries[1] = 10
    dictionary.entries[9] = 90
    world.resources.add(dictionary^)
    var first = world.storage.add_entity(Int32(2))
    var second = world.storage.add_entity(Int32(-3))
    var missing = world.storage.add_entity(Int32(9))
    var collision = world.storage.add_entity(Int32(1))

    var context = SystemContext(world)
    context.run[lookup_int32_dict, on_gpu=True]()
    assert_equal(world.storage.get[Int32](first), 20)
    assert_equal(world.storage.get[Int32](second), 30)
    assert_equal(world.storage.get[Int32](missing), 90)
    assert_equal(world.storage.get[Int32](collision), 10)

    world.resources.get[Int32DictResource]().entries[20] = 200
    world.storage.get[Int32](first) = 20
    context.run[lookup_int32_dict, on_gpu=True]()
    assert_equal(world.storage.get[Int32](first), 200)
    assert_equal(world.storage.get[Int32](missing), -1)


def test_int32_dict_resource_cpu_and_selected_gpu_runs() raises:
    """Uses the same lookup kernel on CPU and on a packed GPU selection.

    Raises:
        Error: If execution or an assertion fails.
    """
    var world = World[Int32]()
    var dictionary = Int32DictResource()
    dictionary.entries[4] = 40
    world.resources.add(dictionary^)
    var cpu_entity = world.storage.add_entity(Int32(4))
    var untouched = world.storage.add_entity(Int32(99))
    var context = SystemContext(world)
    context.run[lookup_int32_dict]()
    assert_equal(world.storage.get[Int32](cpu_entity), 40)
    assert_equal(world.storage.get[Int32](untouched), -1)

    comptime if has_accelerator():
        var selected = context.add_entities(Int32(4), count=2)
        selected.run[lookup_int32_dict, on_gpu=True]()
        selected^.release()
        assert_equal(world.storage.get[Int32](cpu_entity), 40)
        assert_equal(world.storage.get[Int32](untouched), -1)
        var updated = 0
        for entity in world.storage.query[Filter().include[Int32]()]():
            if entity.get[Int32]() == 40:
                updated += 1
        assert_equal(updated, 3)


def test_gpu_empty_int32_dict_resource() raises:
    """An empty uploaded table returns the requested default.

    Raises:
        Error: If execution or an assertion fails.
    """
    comptime if not has_accelerator():
        return
    var world = World[Int32]()
    world.resources.add(Int32DictResource())
    var entity = world.storage.add_entity(Int32(123))
    var context = SystemContext(world)
    context.run[lookup_int32_dict, on_gpu=True]()
    assert_equal(world.storage.get[Int32](entity), -1)


def lookup_string_dict(
    context: KernelContext[
        Filter().include[Int32](), Resources[StringDictResource]()
    ]
):
    """Looks up static string keys selected by each integer component.

    Args:
        context: Integer rows and the string dictionary resource.
    """
    var lookup = context.resources.get[StringDictResource]()
    for entity in context:
        var selector = entity.get[Int32]()
        if selector == 0:
            entity.get[Int32]() = lookup.get_or("a", -1)
        elif selector == 1:
            entity.get[Int32]() = lookup.get_or("i", -1)
        elif selector == 2:
            entity.get[Int32]() = lookup.get_or("café", -1)
        elif selector == 3:
            entity.get[Int32]() = lookup.get_or("", -1)
        elif selector == 4:
            entity.get[Int32]() = lookup.get_or(
                "a string key longer than the inline buffer", -1
            )
        elif selector == 6:
            var key_bytes: Array[UInt8, 1] = [97]
            var key = StringSlice(unsafe_from_utf8=Span(key_bytes))
            entity.get[Int32]() = lookup.get_or(key, -1)
        else:
            entity.get[Int32]() = lookup.get_or("missing", -1)


def test_gpu_string_dict_resource_lookup() raises:
    """Looks up UTF-8, empty, colliding, long, and missing string keys.

    Raises:
        Error: If execution or an assertion fails.
    """
    comptime if not has_accelerator():
        return
    var world = World[Int32]()
    var dictionary = StringDictResource()
    dictionary.entries["a"] = 10
    dictionary.entries["i"] = 20
    dictionary.entries["café"] = 30
    dictionary.entries[""] = 40
    dictionary.entries["a string key longer than the inline buffer"] = 50
    world.resources.add(dictionary^)
    var first = world.storage.add_entity(Int32(0))
    var second = world.storage.add_entity(Int32(1))
    var unicode = world.storage.add_entity(Int32(2))
    var empty = world.storage.add_entity(Int32(3))
    var long_key = world.storage.add_entity(Int32(4))
    var missing = world.storage.add_entity(Int32(5))
    var runtime_key = world.storage.add_entity(Int32(6))
    var context = SystemContext(world)
    context.run[lookup_string_dict, on_gpu=True]()
    assert_equal(world.storage.get[Int32](first), 10)
    assert_equal(world.storage.get[Int32](second), 20)
    assert_equal(world.storage.get[Int32](unicode), 30)
    assert_equal(world.storage.get[Int32](empty), 40)
    assert_equal(world.storage.get[Int32](long_key), 50)
    assert_equal(world.storage.get[Int32](missing), -1)
    assert_equal(world.storage.get[Int32](runtime_key), 10)

    world.resources.get[StringDictResource]().entries["a"] = 99
    world.storage.get[Int32](first) = 0
    context.run[lookup_string_dict, on_gpu=True]()
    assert_equal(world.storage.get[Int32](first), 99)


def test_string_dict_cpu_and_selected_gpu_runs() raises:
    """Uses string lookup on CPU and through the GPU selection path.

    Raises:
        Error: If execution or an assertion fails.
    """
    var world = World[Int32]()
    var dictionary = StringDictResource()
    dictionary.entries["a"] = 10
    world.resources.add(dictionary^)
    var cpu_entity = world.storage.add_entity(Int32(0))
    var context = SystemContext(world)
    context.run[lookup_string_dict]()
    assert_equal(world.storage.get[Int32](cpu_entity), 10)

    comptime if has_accelerator():
        var selected = context.add_entities(Int32(0), count=2)
        selected.run[lookup_string_dict, on_gpu=True]()
        selected^.release()
        var updated = 0
        for entity in world.storage.query[Filter().include[Int32]()]():
            if entity.get[Int32]() == 10:
                updated += 1
        assert_equal(updated, 3)


def test_gpu_empty_string_dict_resource() raises:
    """An empty string dictionary returns the requested default.

    Raises:
        Error: If execution or an assertion fails.
    """
    comptime if not has_accelerator():
        return
    var world = World[Int32]()
    world.resources.add(StringDictResource())
    var entity = world.storage.add_entity(Int32(0))
    var context = SystemContext(world)
    context.run[lookup_string_dict, on_gpu=True]()
    assert_equal(world.storage.get[Int32](entity), -1)


def lookup_both_dicts(
    context: KernelContext[
        Filter().include[Int32](),
        Resources[Int32DictResource, StringDictResource](),
    ]
):
    """Reads two GPU-safe resource views in one kernel.

    Args:
        context: Integer rows and both dictionary resources.
    """
    var integers = context.resources.get[Int32DictResource]()
    var strings = context.resources.get[StringDictResource]()
    for entity in context:
        entity.get[Int32]() = integers.get_or(3, -1) + strings.get_or("a", -1)


def test_gpu_kernel_uses_two_dictionary_views() raises:
    """Both packed dictionary resource views coexist in one GPU launch.

    Raises:
        Error: If GPU execution or an assertion fails.
    """
    comptime if not has_accelerator():
        return
    var world = World[Int32]()
    var integers = Int32DictResource()
    integers.entries[3] = 30
    var strings = StringDictResource()
    strings.entries["a"] = 12
    world.resources.add(integers^, strings^)
    var entity = world.storage.add_entity(Int32(0))
    var context = SystemContext(world)
    context.run[lookup_both_dicts, on_gpu=True]()
    assert_equal(world.storage.get[Int32](entity), 42)


@fieldwise_init
struct LookupConfigView(TrivialRegisterPassable):
    var bias: Int32
    var integers: Int32DictView
    var strings: StringDictView
    var alternate_strings: StringDictView


@fieldwise_init
struct LookupConfig(GPUResource):
    comptime ViewType = LookupConfigView
    var bias: Int32
    var integers: Int32DictResource
    var strings: StringDictResource
    var alternate_strings: StringDictResource

    def encode(self, mut encoder: ResourceEncoder) raises -> LookupConfigView:
        """Builds the kernel view for both dictionary fields.

        Args:
            encoder: Owns the packed tables through the kernel call.

        Returns:
            The GPU-safe view of this resource.

        Raises:
            Error: If either dictionary cannot be packed or uploaded.
        """
        return LookupConfigView(
            self.bias,
            self.integers.encode(encoder),
            self.strings.encode(encoder),
            self.alternate_strings.encode(encoder),
        )


def lookup_nested_dicts(
    context: KernelContext[Filter().include[Int32](), Resources[LookupConfig]()]
):
    """Reads two dictionary fields from a single resource view.

    Args:
        context: Integer rows and the nested dictionary resource.
    """
    ref config = context.resources.get[LookupConfig]()
    for entity in context:
        entity.get[Int32]() = (
            config.bias
            + config.integers.get_or(3, -1)
            + config.strings.get_or("a", -1)
            + config.alternate_strings.get_or("b", -1)
        )


def test_nested_dictionary_resource_cpu_and_gpu() raises:
    """A composite resource uses the same getter and kernel on both targets.

    Raises:
        Error: If CPU or GPU execution or an assertion fails.
    """
    var integers = Int32DictResource()
    integers.entries[3] = 30
    var strings = StringDictResource()
    strings.entries["a"] = 12
    var alternate_strings = StringDictResource()
    alternate_strings.entries["b"] = 7
    var world = World[Int32]()
    world.resources.add(
        LookupConfig(1, integers^, strings^, alternate_strings^)
    )
    var entity = world.storage.add_entity(Int32(0))
    var context = SystemContext(world)
    context.run[lookup_nested_dicts]()
    assert_equal(world.storage.get[Int32](entity), 50)
    comptime if has_accelerator():
        world.resources.get[LookupConfig]().strings.entries["a"] = 20
        context.run[lookup_nested_dicts, on_gpu=True]()
        assert_equal(world.storage.get[Int32](entity), 58)


comptime functions = __functions_in_module()


def main() raises:
    TestSuite.discover_tests[functions]().run()
