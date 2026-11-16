"""Conservative pointer-free raw-byte transfer eligibility."""

from std.memory import (
    is_trivially_copyable,
    is_trivially_deletable,
    is_trivially_movable,
)


trait PlainValue:
    """Declares that a trivial type stores only plain numeric values.

    Conform when reflection cannot inspect a pointer-free representation,
    such as a `StaticTuple` or `InlineArray` field of scalars. The declaring
    author guarantees that no field, at any depth, holds a pointer, reference,
    or handle; Larecs cannot verify this. Declared types must still be
    trivially copyable, movable, and deletable.
    """

    pass


def _plain_device_value[T: AnyType]() -> Bool:
    """Checks pointer-free, trivial value representation recursively.

    Parameters:
        T: The candidate type, including nested field types.

    Returns:
        True for numeric values, declared `PlainValue` types, and trivial
        aggregates of supported values. Owning containers, pointers, and
        undeclared opaque representations are rejected.
    """
    comptime if not conforms_to(T, Copyable):
        return False
    else:
        comptime assert conforms_to(T, Copyable)
        comptime if not (
            is_trivially_copyable[T]()
            and is_trivially_deletable[T]()
            and is_trivially_movable[T]()
        ):
            return False
        elif conforms_to(T, PlainValue):
            return True
        elif not reflect[T].is_struct():
            return False
        elif T == Bool or reflect[T].name().startswith("SIMD["):
            return True
        else:
            comptime fields = reflect[T].field_types()
            comptime for i in range(len(fields)):
                comptime if not _plain_device_value[fields[i]]():
                    return False
            return True
