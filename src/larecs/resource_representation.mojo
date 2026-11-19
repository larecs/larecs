"""Conservative pointer-free raw-byte transfer eligibility."""

from std.memory import (
    is_trivially_copyable,
    is_trivially_deletable,
    is_trivially_movable,
)


def _plain_device_value[T: AnyType]() -> Bool:
    """Checks pointer-free, trivial value representation recursively.

    Parameters:
        T: The candidate type, including nested field types.

    Returns:
        True for numeric values and trivial aggregates of supported values.
        Owning containers, pointers, and opaque representations are rejected.
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
