from std.sys import size_of

from tracy import Zone


def _destructor[T: ImplicitlyDeletable](box_storage: UnsafeBox.data_type):
    """
    Destructor for the UnsafeBox.

    It destroys the pointee and frees the memory associated with the box.

    Parameters:
        T: The type of the element stored in the UnsafeBox.

    Args:
        box_storage: The UnsafeBox.data_type instance to be destroyed.
    """
    with Zone(
        function_name=(
            "unsafe_box._destructor[T: ImplicitlyDeletable](box_storage:"
            " UnsafeBox.data_type)"
        )
    ):
        debug_assert(
            box_storage is not None,
            "Attempting to destroy an empty UnsafeBox.",
        )

        box_storage.unsafe_value().bitcast[T]().unsafe_deinit_pointee()
        comptime if size_of[T]() > 0:
            box_storage.unsafe_value().free()


def _dummy_destructor(box: UnsafeBox.data_type):
    """
    No-op destructor for the UnsafeBox.

    Args:
        box: The UnsafeBox.data_type instance to be destroyed.
             Note, this will not be touched here.
    """
    with Zone(
        function_name="unsafe_box._dummy_destructor(box: UnsafeBox.data_type)"
    ):
        pass


def _copy_initializer[
    T: Copyable
](existing_box: UnsafeBox.data_type, out self_data: UnsafeBox.data_type):
    """
    Copy initializer for the data in the UnsafeBox.

    It creates a new pointer to the data and initializes it with the
    existing data.

    Parameters:
        T: The type of the element stored in the UnsafeBox.

    Args:
        existing_box: The UnsafeBox.data_type instance to be copied.

    Returns:
        A pointer to the newly allocated data.
    """

    with Zone(
        function_name=(
            "unsafe_box._copy_initializer[T: Copyable](existing_box:"
            " UnsafeBox.data_type)"
        )
    ):
        if existing_box is None:
            self_data = None
            return

        comptime if size_of[T]() == 0:
            self_data = None
            self_data = {
                UnsafePointer(to=self_data._value)
                .bitcast[Byte]()
                .unsafe_origin_cast[MutUntrackedOrigin]()
            }
        else:
            ptr = alloc[T](1)
            ptr.unsafe_write(copy=existing_box.unsafe_value().bitcast[T]()[])
            self_data = ptr.bitcast[Byte]()


def _dummy_copy_initializer(
    existing_box: UnsafeBox.data_type,
) -> UnsafeBox.data_type:
    """
    No-op copy initializer for the data in the UnsafeBox.

    Returns a dummy pointer.

    Args:
        existing_box: The UnsafeBox instance to be copied.

    Returns:
        A null pointer.
    """
    with Zone(
        function_name=(
            "unsafe_box._dummy_copy_initializer(existing_box:"
            " UnsafeBox.data_type)"
        )
    ):
        return Optional[UnsafePointer[Byte, MutUntrackedOrigin]]()


struct UnsafeBox(Copyable, Movable):
    """
    A box that can hold a single value without knowing its type at compile time.

    This is useful for generic programming, where the type of the value
    is not known until runtime.

    Note: This is an unsafe feature. Retrieving the value from the box
    requires knowing the type of the value stored in the box. If the
    wrong type is used, it can lead to undefined behavior.
    """

    comptime data_type = Optional[UnsafePointer[Byte, MutUntrackedOrigin]]
    """The type of the data stored in the box."""

    comptime EltType = Copyable & ImplicitlyDeletable
    """Trait requirements for values that can be stored in the box."""

    var _data: Self.data_type
    """Pointer to the boxed allocation, or None for empty storage."""

    var _destructor: def(self: Self.data_type) thin
    """Type-erased destructor for the boxed allocation."""

    var _copy_initializer: def(
        existing_box: Self.data_type
    ) thin -> Self.data_type
    """Type-erased copy initializer for the boxed allocation."""

    def __init__[used_internally: Bool = False](out self):
        """
        Trivial constructor for the UnsafeBox used only internally.

        Parameters:
            used_internally: A flag indicating whether this constructor
                is used internally.

        Constraints:
            `used_internally` must be `True` to use this constructor.
        """
        with Zone(function_name="UnsafeBox.__init__[used_internally: Bool]()"):
            comptime assert (
                used_internally
            ), "This constructor is meant for internal use only."
            self._data = None
            self._destructor = _dummy_destructor
            self._copy_initializer = _dummy_copy_initializer

    def __init__[T: Self.EltType](out self, var data: T):
        """
        Constructor for the UnsafeBox.

        Parameters:
            T: The type of the element stored in the UnsafeBox.

        Args:
            data: The value to be stored in the box.
        """

        with Zone(
            function_name="UnsafeBox.__init__[T: Self.EltType](var data: T)"
        ):
            comptime if size_of[T]() == 0:
                self._data = None
                self._data = {
                    UnsafePointer(to=self._data._value)
                    .bitcast[Byte]()
                    .unsafe_origin_cast[MutUntrackedOrigin]()
                }
            else:
                var ptr = alloc[T](1)
                ptr.unsafe_write(data^)
                self._data = ptr.bitcast[Byte]()

            self._destructor = _destructor[T]
            self._copy_initializer = _copy_initializer[T]

    def __init__(out self, *, copy: Self):
        """
        Copy constructor for the UnsafeBox.

        Args:
            copy: The UnsafeBox instance to be copied from.
        """
        with Zone(function_name="UnsafeBox.__init__(copy: Self)"):
            self = Self.__init__[used_internally=True]()
            self._data = copy._copy_initializer(copy._data)
            self._destructor = copy._destructor
            self._copy_initializer = copy._copy_initializer

    @always_inline
    def __del__(deinit self):
        """
        Destructor for the UnsafeBox.

        It destroys the data stored in the box and frees the memory
        associated with the box.
        """
        with Zone(function_name="UnsafeBox.__del__()"):
            debug_assert(
                self._data is not None,
                "Attempting to destroy an empty UnsafeBox.",
            )
            self._destructor(self._data)

    @always_inline
    def unsafe_get[T: Self.EltType](ref self) -> ref[self] T:
        """
        Returns a reference to the data stored in the box.

        Parameters:
            T: The type of the element stored in the UnsafeBox.

        Returns:
            A reference to the data stored in the box.
        """
        with Zone(function_name="UnsafeBox.unsafe_get[T: Self.EltType]()"):
            debug_assert(
                self._data is not None,
                (
                    t"Attempting to get `{String(reflect[T].base_name())}` from"
                    t" an empty UnsafeBox."
                ),
            )
            return self._data.unsafe_value().bitcast[T]()[]
