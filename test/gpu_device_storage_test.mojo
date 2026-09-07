# SKIP_ASAN
# SKIP_DEBUG

# `DeviceComponentStorage` is not itself a GPU kernel, but every method it
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
# (it doesn't route through `SystemContext.run`'s `GPUComponentType`
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


comptime functions = __functions_in_module()


def main() raises:
    TestSuite.discover_tests[functions]().run()
