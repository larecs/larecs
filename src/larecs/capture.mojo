"""Explicit bindings of CPU-local values for synchronous CPU/GPU kernels."""

from std.memory import is_trivially_copyable, is_trivially_deletable
from std.sys import size_of
from max.gpu.host import DeviceContext, DeviceBuffer


trait CaptureSpec:
    """Describes a capture's value type and access convention."""

    comptime Value: Copyable
    comptime writable: Bool


struct ReadCapture[T: Copyable](CaptureSpec):
    """Declares a read-only capture slot.

    Parameters:
        T: The captured value type.
    """

    comptime Value = Self.T
    comptime writable = False


struct MutCapture[T: Copyable](CaptureSpec):
    """Declares a mutable capture slot copied back after GPU execution.

    Parameters:
        T: The captured value type.
    """

    comptime Value = Self.T
    comptime writable = True


@fieldwise_init
struct Captures[*Specs: CaptureSpec](Sized):
    """Ordered capture declarations; repeated value types are allowed.

    Parameters:
        Specs: ReadCapture or MutCapture declarations in binding order.
    """

    def __len__(self) -> Int:
        """Returns the number of declared slots.

        Returns:
            The capture count.
        """
        return len(Self.Specs)


trait CaptureBindingType(Copyable):
    """A host borrow retained throughout a synchronous kernel invocation."""

    comptime Value: Copyable
    comptime writable: Bool

    def _address(self) -> Int:
        """Returns the borrowed address for internal transfer operations.

        Returns:
            The host value's address.
        """
        ...


@fieldwise_init
struct CaptureBinding[mut: Bool, //, T: Copyable, origin: Origin[mut=mut]](
    CaptureBindingType
):
    """Borrows one host value until the binding's last use.

    Parameters:
        mut: Whether the binding permits mutation and copy-back.
        T: The captured value type.
        origin: The borrowed host value's origin.
    """

    comptime Value = Self.T
    comptime writable = Self.mut
    var _pointer: Pointer[Self.T, Self.origin]

    def _address(self) -> Int:
        """Returns the borrowed address for internal transfer operations.

        Returns:
            The host value's address.
        """
        return Int(self._pointer)


def read_capture[
    T: Copyable, origin: ImmOrigin
](ref[origin] value: T) -> CaptureBinding[T, origin]:
    """Binds a CPU-local value for read-only kernel access.

    Parameters:
        T: The captured value type.
        origin: The inferred borrow origin of the CPU-local value.

    Args:
        value: The value to borrow and upload on GPU execution.

    Returns:
        A read-only binding borrowing value.
    """
    return {Pointer(to=value)}


def mut_capture[
    T: Copyable, origin: MutOrigin
](ref[origin] value: T) -> CaptureBinding[T, origin]:
    """Binds a CPU-local value for kernel mutation and GPU copy-back.

    Parameters:
        T: The captured value type.
        origin: The inferred borrow origin of the CPU-local value.

    Args:
        value: The value to borrow, upload, and overwrite after GPU execution.

    Returns:
        A mutable binding borrowing value.
    """
    return {Pointer(to=value)}


@fieldwise_init
struct CaptureAccessor[captures: Captures](Copyable):
    """Typed access to the local values bound for one kernel invocation.

    Parameters:
        captures: The ordered capture declarations.
    """

    var _pointers: Array[Pointer[UInt8, MutUntrackedOrigin], len(Self.captures)]

    def get[
        index: Int
    ](self) -> ref[
        UntrackedOrigin[mut=Self.captures.Specs[index].writable]
    ] Self.captures.Specs[index].Value:
        """Borrows a capture by its compile-time slot index.

        Parameters:
            index: The zero-based capture slot.

        Returns:
            An immutable or mutable reference according to the slot declaration.
            The reference must not escape the kernel invocation.

        Constraints:
            Index must identify a declared capture.
        """
        comptime assert 0 <= index < len(Self.captures), "Invalid capture slot"
        comptime Spec = Self.captures.Specs[index]
        return (
            self._pointers[index]
            .unsafe_bitcast[Spec.Value]()
            .unsafe_mut_cast[Spec.writable]()[]
        )


def _bind_captures[
    captures: Captures, *Bindings: CaptureBindingType
](*bindings: *Bindings) -> CaptureAccessor[captures]:
    """Checks host bindings and constructs an accessor for synchronous CPU use.

    Parameters:
        captures: The kernel's declared slots.
        Bindings: The supplied host binding types.

    Args:
        bindings: Borrows of the CPU-local values in slot order.

    Returns:
        An accessor retaining the bindings' addresses for this invocation.

    Constraints:
        Binding count, value types, and mutability must match the declarations.
    """
    comptime assert len(Bindings) == len(
        captures
    ), "Capture binding count mismatch"
    var pointers = Array[Pointer[UInt8, MutUntrackedOrigin], len(captures)](
        uninitialized=True
    )
    comptime for i in range(len(captures)):
        comptime assert (
            Bindings[i].Value == captures.Specs[i].Value
        ), "Capture type mismatch"
        comptime assert (
            Bindings[i].writable == captures.Specs[i].writable
        ), "Capture mutability mismatch"
        pointers[i] = Pointer[UInt8, MutUntrackedOrigin](
            unsafe_from_address=bindings[i]._address()
        )
    return {pointers^}


struct DeviceCaptureStorage[captures: Captures]:
    """Owns uploaded capture values until execution and copy-back finish.

    Parameters:
        captures: The kernel's declared capture slots.
    """

    var _buffers: Array[Optional[DeviceBuffer[DType.uint8]], len(Self.captures)]

    def __init__(
        out self, device: DeviceContext, host: CaptureAccessor[Self.captures]
    ) raises:
        """Uploads each bound host value into its own device allocation.

        Args:
            device: The device queue used for the kernel invocation.
            host: Addresses of the borrowed CPU-local values.

        Raises:
            Error: If allocating or uploading a capture fails.

        Constraints:
            GPU captures must be trivially copyable and trivially deletable.
            Values must not contain pointers to host-only memory.
        """
        self._buffers = {fill = None}
        comptime for i in range(len(Self.captures)):
            comptime T = Self.captures.Specs[i].Value
            comptime assert (
                is_trivially_copyable[T]() and is_trivially_deletable[T]()
            ), (
                "GPU captures require plain values without owned heap"
                " allocations"
            )
            self._buffers[i] = device.enqueue_create_buffer[DType.uint8](
                max(1, size_of[T]())
            )
            comptime if size_of[T]() > 0:
                self._buffers[i].unsafe_value().enqueue_copy_from(
                    host._pointers[i].unsafe_mut_cast[False]()
                )

    def copy_back(self, host: CaptureAccessor[Self.captures]) raises:
        """Queues downloads of mutable captures to their original CPU locals.

        Args:
            host: Addresses retained by the invocation's host bindings.

        Raises:
            Error: If enqueueing a download fails.
        """
        comptime for i in range(len(Self.captures)):
            comptime if Self.captures.Specs[i].writable and size_of[
                Self.captures.Specs[i].Value
            ]() > 0:
                self._buffers[i].unsafe_value().enqueue_copy_to(
                    host._pointers[i]
                )
