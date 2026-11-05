# SKIP_ASAN
# SKIP_DEBUG

# `DeviceComponentStorage` is not itself a device kernel, but every method it
# exposes talks to a `DeviceContext`, so these tests need real device
# hardware behind `has_accelerator()` just like a kernel-launching test.
#
# Every test body below lives entirely inside a `comptime if
# has_accelerator():` block rather than an early `comptime if not
# has_accelerator(): return` followed by unconditional code. The two look
# equivalent at runtime, but they are not equivalent to the compiler: a
# `comptime if` only elides the code *inside* the untaken branch, not
# code that merely follows an early `return` in the taken one. On a
# machine whose compilation target has no accelerator support at all
# (unlike this repo's usual dev/CI machines, which do), the trailing
# `DeviceContext()`/`DeviceComponentStorage` calls after a bare early
# return still got fully instantiated and failed with a hard compile-time
# "Unknown GPU architecture detected" error, even though they would never
# have run. Nesting them inside the `comptime if` body itself is what
# actually removes them from compilation on such a target.

from std.sys import has_accelerator
from std.testing import *

from max.gpu.host import DeviceContext

from larecs.device_storage import DeviceComponentStorage


# `DeviceComponentStorage` itself is only constrained to `ComponentType`
# (it doesn't route through `SystemContext.run`'s `DeviceComponentType`
# compile-time check), but everything it does is a raw byte copy, so
# `Vec3` conforms to `TrivialRegisterPassable` anyway to stay honest about
# what these tests exercise.
@fieldwise_init
struct Vec3(Copyable, TrivialRegisterPassable):
    var x: Float32
    var y: Float32
    var z: Float32


def test_copy_to_host_list_overload_reports_element_count() raises:
    """`copy_to_host(out data: List[T])` must report `self._length`
    elements, not `self._length * size_of[T]()`.

    The previous implementation built a `List[UInt8]` sized in *bytes* and
    reinterpreted it as `List[T]` via `rebind_var`, which bit-copies the
    list's `length`/`capacity` fields without rescaling them from a byte
    count to an element count. For `Vec3` (12 bytes), a 4-row column came
    back reporting `len() == 48`, not `4`.
    """
    comptime if has_accelerator():
        var storage = DeviceComponentStorage[Vec3](DeviceContext(), 4)

        var host_data = List[Vec3]()
        host_data.append(Vec3(1, 2, 3))
        host_data.append(Vec3(4, 5, 6))
        host_data.append(Vec3(7, 8, 9))
        host_data.append(Vec3(10, 11, 12))
        storage.copy_from_host[Vec3](Span(host_data))

        var result = storage.copy_to_host[Vec3]()

        assert_equal(len(result), 4)
        assert_equal(result[0].x, 1)
        assert_equal(result[0].z, 3)
        assert_equal(result[3].x, 10)
        assert_equal(result[3].z, 12)


def test_copy_to_host_pointer_overload_default_length_copies_remainder() raises:
    """A negative (default) `length` copies every row from `offset` onward.

    Previously `length` defaulted to `-1` with no special handling, so an
    unspecified `length` multiplied out to a negative byte count in
    `create_sub_buffer` instead of meaning "the rest of the column".
    """
    comptime if has_accelerator():
        var storage = DeviceComponentStorage[Vec3](DeviceContext(), 4)

        var host_data = List[Vec3]()
        host_data.append(Vec3(1, 1, 1))
        host_data.append(Vec3(2, 2, 2))
        host_data.append(Vec3(3, 3, 3))
        host_data.append(Vec3(4, 4, 4))
        storage.copy_from_host[Vec3](Span(host_data))

        var out = List[Vec3](unsafe_uninit_length=2)
        storage.copy_to_host[Vec3](
            out.unsafe_ptr().unsafe_origin_cast[MutUntrackedOrigin](),
            offset=2,
        )

        assert_equal(out[0].x, 3)
        assert_equal(out[1].x, 4)


def test_copy_to_host_pointer_overload_rejects_out_of_bounds_range() raises:
    """An `offset`/`length` range outside the column raises, rather than
    handing `create_sub_buffer` a range past the end of the device buffer.
    """
    comptime if has_accelerator():
        var storage = DeviceComponentStorage[Vec3](DeviceContext(), 4)

        var host_data = List[Vec3]()
        host_data.append(Vec3(1, 1, 1))
        host_data.append(Vec3(2, 2, 2))
        host_data.append(Vec3(3, 3, 3))
        host_data.append(Vec3(4, 4, 4))
        storage.copy_from_host[Vec3](Span(host_data))

        var out = List[Vec3](unsafe_uninit_length=4)
        var raised = False
        try:
            storage.copy_to_host[Vec3](
                out.unsafe_ptr().unsafe_origin_cast[MutUntrackedOrigin](),
                offset=2,
                length=4,
            )
        except:
            raised = True

        assert_true(raised)


def check_independent_columns[reverse: Bool]() raises:
    """Checks independent growth, valid ranges, and deep copies in either order.

    Parameters:
        reverse: Whether the wider column is uploaded first.

    Raises:
        Error: If a device operation or assertion fails.
    """
    comptime if has_accelerator():
        var storage = DeviceComponentStorage[Float32, Float64, UInt8](
            DeviceContext(), 0
        )
        var narrow: List[Float32] = [1, 2]
        var wide: List[Float64] = [10, 20, 30, 40]
        comptime if reverse:
            storage.copy_from_host[Float64](Span(wide))
            storage.copy_from_host[Float32](Span(narrow))
        else:
            storage.copy_from_host[Float32](Span(narrow))
            storage.copy_from_host[Float64](Span(wide))

        var result = storage.copy_to_host[Float32]()
        assert_equal(len(result), 2)
        assert_equal(result[0], 1)
        assert_equal(result[1], 2)
        var wide_result = storage.copy_to_host[Float64]()
        assert_equal(len(wide_result), 4)
        for i in range(4):
            assert_equal(wide_result[i], wide[i])

        var copied = storage.copy()
        assert_true(copied.has_component[Float32]())
        assert_true(copied.has_component[Float64]())
        assert_false(copied.has_component[UInt8]())
        var copied_narrow = copied.copy_to_host[Float32]()
        var copied_wide = copied.copy_to_host[Float64]()
        assert_equal(len(copied_narrow), 2)
        assert_equal(len(copied_wide), 4)
        for i in range(2):
            assert_equal(copied_narrow[i], narrow[i])
        for i in range(4):
            assert_equal(copied_wide[i], wide[i])

        var tail = List[Float32](unsafe_uninit_length=1)
        storage.copy_to_host[Float32](
            tail.unsafe_ptr().unsafe_origin_cast[MutUntrackedOrigin](), offset=1
        )
        storage.synchronize()
        assert_equal(tail[0], 2)
        with assert_raises():
            storage.copy_to_host[Float32](
                tail.unsafe_ptr().unsafe_origin_cast[MutUntrackedOrigin](),
                offset=2,
                length=1,
            )
        with assert_raises():
            storage.copy_to_host[Float32](
                tail.unsafe_ptr().unsafe_origin_cast[MutUntrackedOrigin](),
                offset=3,
            )
        # An empty range at the logical end is valid.
        storage.copy_to_host[Float32](
            tail.unsafe_ptr().unsafe_origin_cast[MutUntrackedOrigin](), offset=2
        )

        # Growing the smaller column must preserve its prefix and leave the
        # other column's valid range alone.
        var append: List[Float32] = [3, 4, 5]
        storage.copy_from_host[Float32](Span(append), offset=2)
        var replacement: List[Float32] = [9]
        storage.copy_from_host[Float32](Span(replacement))
        storage.copy_from_host[Float32](Span(replacement), offset=3)
        storage.ensure_column[Float32](1)
        result = storage.copy_to_host[Float32]()
        assert_equal(len(result), 5)
        assert_equal(result[0], 9)
        assert_equal(result[1], 2)
        assert_equal(result[2], 3)
        assert_equal(result[3], 9)
        assert_equal(result[4], 5)
        wide_result = storage.copy_to_host[Float64]()
        assert_equal(len(wide_result), 4)
        for i in range(4):
            assert_equal(wide_result[i], wide[i])
        copied_narrow = copied.copy_to_host[Float32]()
        assert_equal(len(copied_narrow), 2)
        assert_equal(copied_narrow[0], 1)
        assert_equal(copied_narrow[1], 2)
        var grown_copy = storage.copy()
        copied_narrow = grown_copy.copy_to_host[Float32]()
        assert_equal(len(copied_narrow), 5)
        for i in range(5):
            assert_equal(copied_narrow[i], result[i])
        copied_wide = grown_copy.copy_to_host[Float64]()
        assert_equal(len(copied_wide), 4)
        for i in range(4):
            assert_equal(copied_wide[i], wide[i])


def test_columns_grow_narrow_first() raises:
    """Checks growing the wider column after a smaller narrow column.

    Raises:
        Error: If a device operation or assertion fails.
    """
    check_independent_columns[False]()


def test_columns_grow_wide_first() raises:
    """Checks initializing a narrow column after a larger wide column.

    Raises:
        Error: If a device operation or assertion fails.
    """
    check_independent_columns[True]()


def test_initial_capacity_does_not_expose_unwritten_rows() raises:
    """Checks valid bounds and copies when allocation exceeds valid data.

    Raises:
        Error: If a device operation or assertion fails.
    """
    comptime if has_accelerator():
        var storage = DeviceComponentStorage[Float32, Float64](
            DeviceContext(), 8
        )
        var empty = List[Float32]()
        storage.copy_from_host[Float32](Span(empty))
        assert_false(storage.has_component[Float32]())
        var missing = storage.copy_to_host[Float32]()
        assert_equal(len(missing), 0)
        var data: List[Float32] = [1, 2]
        storage.copy_from_host[Float32](Span(data))
        var result = storage.copy_to_host[Float32]()
        assert_equal(len(result), 2)
        var copied = storage.copy()
        assert_true(copied.has_component[Float32]())
        result = copied.copy_to_host[Float32]()
        assert_equal(len(result), 2)
        assert_equal(result[0], 1)
        assert_equal(result[1], 2)
        with assert_raises():
            storage.copy_to_host[Float32](
                data.unsafe_ptr().unsafe_origin_cast[MutUntrackedOrigin](),
                offset=2,
                length=1,
            )
        with assert_raises():
            storage.copy_from_host[Float32](Span(data), offset=-1)
        with assert_raises():
            storage.copy_from_host[Float32](Span(data), offset=3)
        with assert_raises():
            storage.ensure_column[Float32](-1)
        result = storage.copy_to_host[Float32]()
        assert_equal(len(result), 2)

        # Ensured columns are promises of kernel output, even without upload.
        storage.ensure_column[Float64](0)
        assert_true(storage.has_component[Float64]())
        var empty_copy = storage.copy()
        assert_true(empty_copy.has_component[Float64]())
        var empty_result = empty_copy.copy_to_host[Float64]()
        assert_equal(len(empty_result), 0)

        var zero_capacity = DeviceComponentStorage[Float32](DeviceContext(), 0)
        zero_capacity.ensure_column[Float32](0)
        var zero_copy = zero_capacity.copy()
        assert_true(zero_copy.has_component[Float32]())
        var zero_result = zero_copy.copy_to_host[Float32]()
        assert_equal(len(zero_result), 0)
        zero_capacity.copy_from_host[Float32](Span(data))
        zero_result = zero_capacity.copy_to_host[Float32]()
        assert_equal(len(zero_result), 2)
        assert_equal(zero_result[0], 1)
        assert_equal(zero_result[1], 2)


def test_reservation_keeps_rows_private_and_columns_independent() raises:
    """Checks reservation, gaps, valid prefixes, and copies of empty columns.

    Raises:
        Error: If a device operation or assertion fails.
    """
    comptime if has_accelerator():
        var storage = DeviceComponentStorage[Float32, Float64](
            DeviceContext(), 8
        )
        storage.reserve_column[Float32](2)
        assert_equal(len(storage._columns[0].unsafe_value()), 8 * 4)
        assert_false(storage.has_component[Float64]())
        var result = storage.copy_to_host[Float32]()
        assert_equal(len(result), 0)
        var data: List[Float32] = [1, 2]
        with assert_raises():
            storage.copy_from_host[Float32](Span(data), offset=1)
        with assert_raises():
            storage.copy_to_host[Float32](
                data.unsafe_ptr().unsafe_origin_cast[MutUntrackedOrigin](),
                length=1,
            )
        var copied = storage.copy()
        result = copied.copy_to_host[Float32]()
        assert_equal(len(result), 0)
        assert_true(copied.has_component[Float32]())
        storage.copy_from_host[Float32](Span(data))
        storage.reserve_column[Float32](9)
        assert_equal(len(storage._columns[0].unsafe_value()), 16 * 4)
        result = storage.copy_to_host[Float32]()
        assert_equal(len(result), 2)
        assert_equal(result[0], 1)
        assert_equal(result[1], 2)
        with assert_raises():
            storage.copy_from_host[Float32](Span(data), offset=3)
        with assert_raises():
            storage.reserve_column[Float64](-1)
        assert_false(storage.has_component[Float64]())
        storage.reserve_column[Float64](0)
        result = copied.copy_to_host[Float32]()
        assert_equal(len(result), 0)
        assert_equal(storage._lengths[1], 0)


def test_incremental_uploads_amortize_growth_and_retain_suffixes() raises:
    """Checks logarithmic allocation count and all rows after prefix copying.

    Raises:
        Error: If a device operation or assertion fails.
    """
    comptime if has_accelerator():
        var storage = DeviceComponentStorage[Float32](DeviceContext(), 0)
        var capacity = 0
        var allocations = 0
        for i in range(65):
            var data: List[Float32] = [Float32(i)]
            storage.copy_from_host[Float32](Span(data), offset=i)
            var next_capacity = len(storage._columns[0].unsafe_value())
            if next_capacity != capacity:
                allocations += 1
            capacity = next_capacity
        assert_equal(allocations, 8)
        assert_equal(capacity, 128 * 4)
        var replacement: List[Float32] = [99]
        storage.copy_from_host[Float32](Span(replacement))
        storage.reserve_column[Float32](1)
        storage.ensure_column[Float32](1)
        assert_equal(len(storage._columns[0].unsafe_value()), capacity)
        var result = storage.copy_to_host[Float32]()
        assert_equal(len(result), 65)
        assert_equal(result[0], 99)
        for i in range(1, 65):
            assert_equal(result[i], Float32(i))


def test_full_reservation_prevents_segment_reallocation() raises:
    """Checks stable capacity during flattened uploads and output promises.

    Raises:
        Error: If a device operation or assertion fails.
    """
    comptime if has_accelerator():
        var storage = DeviceComponentStorage[Float32](DeviceContext(), 0)
        storage.reserve_column[Float32](32)
        var pointer = storage.get_device_ptr[Float32]()
        for i in range(8):
            var data: List[Float32] = [Float32(i), 2, 3, 4]
            storage.copy_from_host[Float32](Span(data), offset=i * 4)
            assert_equal(storage.get_device_ptr[Float32](), pointer)
            assert_equal(len(storage._columns[0].unsafe_value()), 32 * 4)
            assert_equal(storage._lengths[0], (i + 1) * 4)
        # ensure_column deliberately publishes output rows. Fill them on the
        # device before downloading, just as a write-only kernel must do.
        storage.ensure_column[Float32](33)
        storage._columns[0].unsafe_value().enqueue_fill(0)
        var result = storage.copy_to_host[Float32]()
        assert_equal(len(result), 33)
        for value in result:
            assert_equal(value, 0)


comptime functions = __functions_in_module()


def main() raises:
    TestSuite.discover_tests[functions]().run()
