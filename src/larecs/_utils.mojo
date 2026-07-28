from std.memory import unsafe_uninit_copy_n
from std.collections.check_bounds import check_bounds

from tracy import Zone


# FIXME: This is needed because of this [bug](https://github.com/modular/modular/issues/6636). Remove this and use `check_bounds` directly once the bug is fixed.
@always_inline
def _assert_index_in_bounds(index: Int, size: Int):
    """Asserts that an index refers to a valid element.

    Args:
        index: The candidate index to validate.
        size: The logical number of available elements.
    """
    with Zone(
        function_name="_utils._assert_index_in_bounds(index: Int, size: Int)"
    ):
        # assert 0 <= index and index < size, "Index out of bounds"
        check_bounds(index, size)


@always_inline
def assert_unreachable[
    MsgType: Writable & Movable
](reason: Optional[MsgType] = None):
    if reason is None:
        assert False, "Executed code that should be unreachable!"
    else:
        assert False, t"Executed code that should be unreachable: {reason}"


@always_inline
def concatenate_arrays[
    ElementType: Copyable, a_size: Int, b_size: Int
](
    a: Array[ElementType, a_size],
    b: Array[ElementType, b_size],
    out result: Array[ElementType, a_size + b_size],
):
    """Concatenates two inline arrays into an output inline array.

    Parameters:
        ElementType: The element type stored in both arrays.
        a_size: The compile-time length of the first array.
        b_size: The compile-time length of the second array.

    Args:
        a: The first array.
        b: The second array.

    Returns:
        The output array containing `a` followed by `b`.
    """
    result = {uninitialized = True}

    unsafe_uninit_copy_n[overlapping=False](
        dest=result.unsafe_ptr(), src=a.unsafe_ptr(), count=a_size
    )

    unsafe_uninit_copy_n[overlapping=False](
        dest=result.unsafe_ptr().unsafe_offset(a_size),
        src=b.unsafe_ptr(),
        count=b_size,
    )


@always_inline
def _assert_range_in_bounds(start_index: Int, count: Int, size: Int):
    """Asserts that a consecutive range fits into a logical size.

    Args:
        start_index: The index of the first element in the range.
        count: The number of elements in the range.
        size: The logical number of available elements.
    """
    with Zone(
        function_name=(
            "_utils._assert_range_in_bounds(start_index: Int, count: Int, size:"
            " Int)"
        )
    ):
        debug_assert(0 <= count, "Count must be non-negative.")

        if count == 0:
            return

        check_bounds(start_index, size)
        check_bounds(start_index + count - 1, size)
