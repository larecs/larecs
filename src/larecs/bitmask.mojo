from std.bit import pop_count, bit_not
from std.collections.check_bounds import check_bounds
from .types import ComponentId
from std.hashlib import Hasher
from std.io.write import Writable, Writer
from std.sys import bit_width_of

from tracy import Zone


# TODO: Implement `Iterable` for this
# TODO: Implement `IterableOwned` for this
# TODO: Implement `Iterator` for this
@fieldwise_init
struct _BitMaskIndexIter[total_bits: Int](ImplicitlyCopyable, Sized):
    """Iterator for BitMask indices.

    Iterates over the indices of all bits that are set to True in a BitMask,
    providing efficient access to set bit positions.
    """

    comptime bitmask = _BitMask[Self.total_bits]
    """The bitmask type iterated by this index iterator."""

    var _byte_index: Int
    """Current byte index while scanning the byte vector."""
    var _offset_index: Int
    """Current bit offset within the active byte."""
    var _index: Int
    """Number of set-bit indices already yielded."""
    var _size: Int
    """Total number of set bits available to yield."""
    var _bytes: Self.bitmask.BytesType
    """The bytes being scanned for set bits."""
    var _mask: Self.bitmask.BytesType
    """The per-byte bit mask for the current bit offset."""
    var _compare: Self.bitmask.BytesType
    """The masked byte vector used to find set bits at the current offset."""

    def __init__(out self, var bytes: Self.bitmask.BytesType):
        """Initializes an index iterator over raw bitmask bytes.

        Args:
            bytes: The bytes to scan for set bits.

        Constraints:
            `total_bits` must be a power of two.
        """
        with Zone(
            function_name=(
                "_BitMaskIndexIter.__init__(var bytes: Self.bitmask.BytesType)"
            )
        ):
            comptime assert (
                Self.total_bits.is_power_of_two()
            ), "BitMask size must be a power of two."
            self._bytes = bytes
            self._mask = Self.bitmask.BytesType(1)
            self._compare = self._bytes & self._mask
            self._byte_index = 0
            self._offset_index = 0
            self._index = 0
            self._size = self._bytes.reduce_bit_count()

    def __iter__(self) -> Self:
        """Returns this iterator."""
        with Zone(function_name="_BitMaskIndexIter.__iter__()"):
            return self

    def __next__(
        mut self,
    ) -> Int:
        """Returns the next set-bit index or the sentinel end index.

        Returns:
            The next set-bit index, or `total_bits` when iteration is complete.
        """
        with Zone(function_name="_BitMaskIndexIter.__next__()"):
            for i in range(self._offset_index, 8):
                for j in range(self._byte_index, Self.bitmask.total_bytes):
                    if self._compare[j]:
                        self._offset_index = i
                        self._byte_index = j + 1
                        self._index += 1
                        return j * 8 + i
                self._mask <<= 1
                self._compare = self._bytes & self._mask
                self._byte_index = 0
            return (
                Self.total_bits
            )  # Sentinel value indicating the end of iteration

    @always_inline
    def __has_next__(self) -> Bool:
        """Returns whether another set-bit index is available."""
        with Zone(function_name="_BitMaskIndexIter.__has_next__()"):
            return self._index < self._size

    @always_inline
    def __len__(self) -> Int:
        """Returns the number of set bits in the iterated mask."""
        with Zone(function_name="_BitMaskIndexIter.__len__()"):
            return self._size


comptime BitMask = _BitMask[256]
"""The default 256-bit ECS component mask type."""


struct _BitMask[total_bits: Int](
    Equatable,
    ImplicitlyCopyable,
    KeyElement,
    Movable,
    RegisterPassable,
    Writable,
):
    """A 256-bit bitmask for efficient set operations."""

    comptime total_bytes = Self.total_bits // 8
    """The number of bytes required to store the bitmask."""
    comptime BytesType = SIMD[DType.uint8, Self.total_bytes]
    """The SIMD byte vector used as bitmask storage."""

    var _bytes: Self.BytesType
    """Raw byte storage for the bitmask."""

    @always_inline
    def __init__(out self, *, bytes: Self.BytesType):
        """Initializes the mask with the given bytes.

        Creates a new BitMask from a raw byte representation.

        Args:
            bytes: The raw byte data representing the bitmask state.
        """
        comptime assert (
            Self.total_bits.is_power_of_two()
        ), "BitMask size must be a power of two."
        self._bytes = bytes

    @always_inline
    def __init__[size: Int](out self, bits: Array[Int, size]):
        """Initializes the mask with the bits at the given indices set to True.

        Creates a new BitMask with only the specified bit indices set.

        Parameters:
            size: The compile-time size of the inline array.

        Args:
            bits: An inline array of bit indices to set to True.
        """
        comptime assert (
            Self.total_bits.is_power_of_two()
        ), "BitMask size must be a power of two."
        self._bytes = Self.BytesType()

        comptime for i in range(size):
            self.set[True](bits[i])

    @always_inline
    def __init__(out self, *bits: Int):
        """Initializes the mask with the bits at the given indices set to True.

        Creates a new BitMask with only the specified bit indices set.

        Args:
            bits: Variadic bit indices to set to True.
        """
        comptime assert (
            Self.total_bits.is_power_of_two()
        ), "BitMask size must be a power of two."
        self._bytes = Self.BytesType()
        for bit in bits:
            self.set[True](bit)

    @always_inline
    def __hash__[H: Hasher](self, mut hasher: H):
        """Hashes the mask.

        Computes a hash value for the mask by hashing its underlying byte representation.

        Parameters:
            H: The hasher type to use.

        Args:
            hasher: The hasher to update with the mask's bytes.
        """
        with Zone(function_name="BitMask.__hash__[H: Hasher](mut hasher: H)"):
            hasher.update(self._bytes)

    @always_inline
    def __eq__(self, other: Self) -> Bool:
        """Compares two masks for equality.

        Checks if all bits in both masks have the same state.

        Args:
            other: The other BitMask to compare with.

        Returns:
            True if both masks are identical, False otherwise.
        """
        with Zone(function_name="BitMask.__eq__(other: Self)"):
            return self._bytes == other._bytes

    @always_inline
    def __ne__(self, other: Self) -> Bool:
        """Compares two masks for inequality.

        Checks if the masks differ in at least one bit.

        Args:
            other: The other BitMask to compare with.

        Returns:
            True if the masks are different, False otherwise.
        """
        with Zone(function_name="BitMask.__ne__(other: Self)"):
            return not self.__eq__(other)

    @always_inline
    def __invert__(self) -> Self:
        """Returns the inversion of this mask.

        Creates a new mask where all bits are flipped (0 becomes 1, 1 becomes 0).

        Returns:
            A new BitMask with all bits inverted.
        """
        with Zone(function_name="BitMask.__invert__()"):
            return Self(bytes=~self._bytes)

    @always_inline
    def __or__(self, other: Self, out result: Self):
        """Returns the bitwise OR of this mask and another mask.

        Performs element-wise bitwise OR operation between this mask and another mask,
        creating a new mask where a bit is set if it's set in either operand.

        Args:
            other: The other BitMask to OR with this mask.

        Returns:
            A new BitMask containing the bitwise OR of both masks.
        """
        with Zone(
            function_name="BitMask.__or__(other: Self, out result: Self)"
        ):
            result = self.copy()
            result |= other

    @always_inline
    def __ior__(mut self, other: Self):
        """Performs in-place bitwise OR with another BitMask.

        This method modifies the current BitMask by performing a bitwise OR operation
        with another BitMask. Each bit in the resulting BitMask is set if it is set
        in either the current BitMask or the provided BitMask.

        Args:
            other: The BitMask to perform the bitwise OR operation with.
        """
        with Zone(function_name="BitMask.__ior__(other: Self)"):
            self._bytes |= other._bytes

    @always_inline
    def __and__(self, other: Self, out result: Self):
        """Returns the bitwise AND of this mask and another mask.

        Performs element-wise bitwise AND operation between this mask and another mask,
        creating a new mask where a bit is set if it's set in both operands.

        Args:
            other: The other BitMask to AND with this mask.

        Returns:
            A new BitMask containing the bitwise AND of both masks.
        """
        with Zone(
            function_name="BitMask.__and__(other: Self, out result: Self)"
        ):
            result = self.copy()
            result &= other

    @always_inline
    def __iand__(mut self, other: Self):
        """Performs in-place bitwise AND with another BitMask.

        This method modifies the current BitMask by performing a bitwise AND operation
        with another BitMask. Each bit in the resulting BitMask is set if it is set
        in both the current BitMask and the provided BitMask.

        Args:
            other: The BitMask to perform the bitwise AND operation with.
        """
        with Zone(function_name="BitMask.__iand__(other: Self)"):
            self._bytes &= other._bytes

    @always_inline
    def __xor__(self, other: Self, out result: Self):
        """Returns the bitwise XOR of this mask and another mask.

        Performs element-wise bitwise XOR operation between this mask and another mask,
        creating a new mask where a bit is set if it's set in one mask but not the other.

        Args:
            other: The other BitMask to XOR with this mask.

        Returns:
            A new BitMask containing the bitwise XOR of both masks.
        """
        with Zone(
            function_name="BitMask.__xor__(other: Self, out result: Self)"
        ):
            result = self.copy()
            result ^= other

    @always_inline
    def __ixor__(mut self, other: Self):
        """Performs in-place bitwise XOR with another BitMask.

        This method modifies the current BitMask by performing a bitwise XOR operation
        with another BitMask. Each bit in the resulting BitMask is set if it is set
        in one mask but not the other.

        Args:
            other: The BitMask to perform the bitwise XOR operation with.
        """
        with Zone(function_name="BitMask.__ixor__(other: Self)"):
            self._bytes ^= other._bytes

    @deprecated(use=write_to)
    def __str__(self) -> String:
        """Implements String(...).

        Converts the mask to a string representation showing all 256 bits.

        Returns:
            A string in the format "[01101...]" showing the state of all bits.
        """
        with Zone(function_name="BitMask.__str__()"):
            var result: String = "["
            for i in range(len(self._bytes) * 8):
                if self.get(i):
                    result += "1"
                else:
                    result += "0"
            result += "]"
            return result

    def write_to(self, mut writer: Some[Writer]):
        """Writes the mask to a writer.

        Emits the bitmask in the same format as [.__str__], as a bracketed
        256-bit string.

        Args:
            writer: The destination writer.
        """
        with Zone(function_name="BitMask.write_to(mut writer: Some[Writer])"):
            writer.write("[")
            for i in range(len(self._bytes) * 8):
                if self.get(i):
                    writer.write("1")
                else:
                    writer.write("0")
            writer.write("]")

    def write_repr_to(self, mut writer: Some[Writer]):
        """Writes the mask to a writer in a debug representation.

        Emits the bitmask in a format showing the internal byte structure for debugging.

        Args:
            writer: The destination writer.
        """
        with Zone(
            function_name="BitMask.write_repr_to(mut writer: Some[Writer])"
        ):
            writer.write(
                "BitMask[total_bits=",
                String(self.total_bits),
                "](",
                String(self._bytes),
                ")",
            )

    @deprecated(use=write_repr_to)
    @always_inline
    def __repr__(self) -> String:
        """Representation string of the mask.

        Creates a debug representation showing the internal byte structure.

        Returns:
            A string in the format "BitMask(<bytes>)" for debugging.
        """
        with Zone(function_name="BitMask.__repr__()"):
            return (
                "BitMask[total_bits="
                + String(self.total_bits)
                + "]("
                + String(self._bytes)
                + ")"
            )

    @always_inline
    def matches(self, bits: Self) -> Bool:
        """Matches the mask as filter against another mask.

        Checks if the provided mask contains all bits set in this mask.

        This is the flipped version of `contains()`, i.e. `self.matches(bits) == bits.contains(self)`.

        Args:
            bits: The BitMask to check against.

        Returns:
            True if bits contains all bits set in this mask, False otherwise.
        """
        with Zone(function_name="BitMask.matches(bits: Self)"):
            return bits.contains(self)

    @always_inline
    def get(self, bit: Int) -> Bool:
        """Reports whether the bit at the given index is set.

        Args:
            bit: The index of the bit to check.

        Returns:
            True if the bit is set, False otherwise.
        """
        with Zone(function_name="BitMask.get(bit: Int)"):
            check_bounds(bit, Self.total_bits)

            var idx = bit >> 3  # equivalent to bit // 8
            var offset = bit & 7  # equivalent to bit - (8 * idx)
            var mask = 1 << UInt8(offset)
            return (self._bytes[idx] & mask) == mask

    @always_inline
    def set(mut self, bit: Int, value: Bool):
        """Sets the state of bit at the given index.

        Args:
            bit: The index of the bit to modify.
            value: The value to set the bit to (True or False).
        """
        with Zone(function_name="BitMask.set(bit: Int, value: Bool)"):
            if value:
                self.set[True](bit)
            else:
                self.set[False](bit)

    @always_inline
    def set[value: Bool](mut self, bit: Int):
        """Sets the state of bit at the given index.

        Parameters:
            value: The compile-time value to set the bit to (True or False).

        Args:
            bit: The index of the bit to modify.
        """
        check_bounds(bit, Self.total_bits)

        var idx = bit >> 3  # equivalent to bit // 8
        var offset = UInt8(bit) & 7  # equivalent to bit - (8 * idx)

        comptime if value:
            self._bytes[idx] |= 1 << offset
        else:
            self._bytes[idx] &= ~(1 << offset)

    @always_inline
    def set(mut self, *comps: Int, value: Bool):
        """Modifies the [BitMask] to set the components given as arguments to the provided value.

        Args:
            comps: Variadic bit indices to modify.
            value: The value to set the bits to (True or False).
        """
        with Zone(function_name="BitMask.set(*comps: Int, value: Bool)"):
            self.set(Self(*comps), value)

    @always_inline
    def set[value: Bool](mut self, *comps: Int):
        """Modifies the [BitMask] to set the components given as arguments to the provided value.

        Parameters:
            value: The compile-time value to set the bits to (True or False).

        Args:
            comps: Variadic bit indices to modify.
        """
        with Zone(function_name="BitMask.set[value: Bool](*comps: Int)"):
            self.set[value](Self(*comps))

    @always_inline
    def set(mut self, comps: Array[Int, ...], value: Bool):
        """Modifies the [BitMask] to set the components given in the array to the provided value.

        Args:
            comps: An inline array of bit indices to modify.
            value: The value to set the bits to (True or False).
        """
        with Zone(
            function_name="BitMask.set(comps: Array[Int, ...], value: Bool)"
        ):
            self.set(Self(comps), value)

    @always_inline
    def set[value: Bool](mut self, comps: Array[Int, ...]):
        """Modifies the [BitMask] to set the components given in the array to the provided value.

        Parameters:
            value: The compile-time value to set the bits to (True or False).

        Args:
            comps: An inline array of bit indices to modify.
        """
        with Zone(
            function_name="BitMask.set[value: Bool](comps: Array[Int, ...])"
        ):
            self.set[value](Self(comps))

    @always_inline
    def set(mut self, other: Self, value: Bool):
        """Modifies the [BitMask] to set the components set in the given [BitMask] to the provided value.

        Args:
            other: A [BitMask] whose set bits identify which bits to modify.
            value: The value to set the bits to (True or False).
        """
        with Zone(function_name="BitMask.set(other: Self, value: Bool)"):
            if value:
                self.set[True](other)
            else:
                self.set[False](other)

    @always_inline
    def set[value: Bool](mut self, other: Self):
        """Modifies the [BitMask] to set the components set in the given [BitMask] to the provided value.

        Creates a new [BitMask] with all bits set in the other mask modified to the
        compile-time known value.

        Parameters:
            value: The compile-time value to set the bits to (True or False).

        Args:
            other: A [BitMask] whose set bits identify which bits to modify.
        """

        with Zone(function_name="BitMask.set[value: Bool](other: Self)"):
            comptime if value:
                self |= other
            else:
                self &= ~other

    @always_inline
    def flip(mut self, bit: Int):
        """Flips the state of bit at the given index.

        Toggles the bit at the specified index (0 becomes 1, 1 becomes 0).

        Args:
            bit: The index of the bit to flip.
        """
        with Zone(function_name="BitMask.flip(bit: Int)"):
            check_bounds(bit, Self.total_bits)

            var idx = bit >> 3  # equivalent to bit // 8
            var offset = UInt8(bit) & 7  # equivalent to bit - (8 * idx)
            self._bytes[idx] ^= 1 << offset

    @always_inline
    def is_zero(self) -> Bool:
        """Returns whether no bits are set in the mask.

        Checks if the mask is completely empty (all bits are False).

        Returns:
            True if no bits are set, False otherwise.
        """
        with Zone(function_name="BitMask.is_zero()"):
            return not self._bytes.reduce_or()

    @always_inline
    def reset(mut self):
        """Resets the mask setting all bits to False.

        Clears all bits in the mask, setting the entire mask to zero.
        """
        with Zone(function_name="BitMask.reset()"):
            self._bytes = 0

    @always_inline
    def contains(self, other: Self) -> Bool:
        """Reports if the other mask is a subset of this mask.

        Checks whether all bits set in the other mask are also set in this mask.

        Args:
            other: The [BitMask] to check for containment.

        Returns:
            True if all bits set in other are also set in this mask, False otherwise.
        """
        with Zone(function_name="BitMask.contains(other: Self)"):
            return (self._bytes & other._bytes) == other._bytes

    @always_inline
    def contains_any(self, other: Self) -> Bool:
        """Reports if any bit of the other mask is in this mask.

        Checks whether at least one bit set in the other mask is also set in this mask.

        Args:
            other: The [BitMask] to check for overlap.

        Returns:
            True if any bit set in other is also set in this mask, False otherwise.
        """
        with Zone(function_name="BitMask.contains_any(other: Self)"):
            return (self._bytes & other._bytes) != 0

    @always_inline
    def total_bits_set(self) -> Int:
        """Returns how many bits are set in this mask.

        Counts the total number of bits that are set to True.

        Returns:
            The number of bits set to True in the mask.
        """
        with Zone(function_name="BitMask.total_bits_set()"):
            return self._bytes.reduce_bit_count()

    @always_inline
    def get_indices(
        self,
        out result: _BitMaskIndexIter[Self.total_bits],
    ):
        """Returns the indices of the bits that are set.

        Creates an iterator that yields the index of each bit set to True.

        Returns:
            An iterator over the indices of the bits that are set.
        """
        with Zone(
            function_name=(
                "BitMask.get_indices(out result:"
                " _BitMaskIndexIter[Self.total_bits])"
            )
        ):
            result = _BitMaskIndexIter[Self.total_bits](self._bytes)
