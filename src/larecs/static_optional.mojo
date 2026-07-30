from std.memory import UnsafePointer
from std.utils.type_functions import ConditionalType

from tracy import Zone


@fieldwise_init
struct _EmptyStaticOptionalStorage(
    Copyable, ImplicitlyDeletable, Movable, Writable
):
    """Zero-sized backing storage for an absent `StaticOptional` value.

    Raises:
        No runtime exceptions.

    Returns:
        A zero-sized storage value.
    """

    def write_to(self, mut writer: Some[Writer]):
        """Writes a value to the storage.

        This is a no-op since the storage is zero-sized.

        Args:
            writer: The writer to write to.
        """
        with Zone(
            function_name=(
                "_EmptyStaticOptionalStorage.write_to(mut writer: Some[Writer])"
            )
        ):
            writer.write("_EmptyStaticOptionalStorage")


@fieldwise_init
struct StaticOptional[
    ElementType: Copyable & ImplicitlyDeletable,
    has_value: Bool = True,
](
    Boolable,
    Copyable,
    Movable,
    Writable where conforms_to(ElementType, Writable),
):
    """An optional type with compile-time presence.

    `StaticOptional` stores `ElementType` directly when `has_value` is `True`
    and uses zero-sized empty storage when `has_value` is `False`.

    Parameters:
        ElementType: The stored element type.
        has_value: Whether the optional contains a value at compile time.
    """

    comptime Storage = Self.ElementType if Self.has_value else _EmptyStaticOptionalStorage
    """Selected backing storage type."""

    var _value: Self.Storage
    """Backing storage selected by `ConditionalType`."""

    @always_inline
    @implicit
    def __init__(out self, none: None = None) where Self.has_value == False:
        """Construct an absent optional.

        This constructor is only valid when `has_value` is `False`.

        Args:
            none: Must be `None`.

        Returns:
            A `StaticOptional` with empty backing storage.
        """
        with Zone(function_name="StaticOptional.__init__(none: None)"):
            comptime assert (
                not Self.has_value
            ), "Cannot initialize with `None` if `has_value` is `True`"

            self._value = rebind_var[dest_type=Self.Storage](
                _EmptyStaticOptionalStorage()
            )

    @always_inline
    @implicit
    def __init__(
        out self, var value: Self.ElementType
    ) where Self.has_value == True:
        """Construct a present optional.

        Args:
            value: The value to store.

        Returns:
            A `StaticOptional` initialized with selected backing storage.
        """
        with Zone(
            function_name="StaticOptional.__init__(var value: Self.ElementType)"
        ):
            comptime assert (
                Self.has_value
            ), "Cannot initialize with a value if `has_value` is `False`"

            self._value = rebind_var[dest_type=Self.Storage](value^)

    @always_inline
    def __del__(deinit self):
        """Destroy the stored value when present."""
        with Zone(function_name="StaticOptional.__del__()"):
            comptime if Self.has_value:
                _ = self._value^

    @always_inline
    def __getitem__(ref self) -> ref[self._value] Self.ElementType:
        """Get a reference to the stored value.

        Returns:
            A reference to the contained value.
        """
        with Zone(function_name="StaticOptional.__getitem__()"):
            comptime assert (
                Self.has_value
            ), "The value is not present. Use `has_value` to check first."

            return rebind[Self.ElementType](self._value)

    @always_inline
    def or_else(
        ref self, ref value: Self.ElementType
    ) -> ref[self._value, value] Self.ElementType:
        """Return the stored value or the provided fallback.

        Args:
            value: The fallback value returned when no value is present.

        Returns:
            The stored value when present, otherwise `value`.
        """
        with Zone(
            function_name="StaticOptional.or_else(ref value: Self.ElementType)"
        ):
            comptime if Self.has_value:
                return self[]
            else:
                return value

    @always_inline
    def unsafe_ptr(
        ref self,
    ) -> UnsafePointer[Self.ElementType, origin_of(self._value)]:
        """Get a pointer to the stored value.

        Returns:
            An `UnsafePointer` to the contained value.
        """
        with Zone(function_name="StaticOptional.unsafe_ptr()"):
            comptime assert (
                Self.has_value
            ), "The value is not present. Use `has_value` to check first."

            return UnsafePointer(to=rebind[Self.ElementType](self._value))

    @always_inline
    def __bool__(self) -> Bool:
        """Check whether the optional has a value.

        Returns:
            The value of `has_value`.
        """
        with Zone(function_name="StaticOptional.__bool__()"):
            return Self.has_value
