"""Opt-in host spatial classification and explicit row maintenance."""

from std.math import floor, isfinite

from .component import ComponentType
from .entity import EntityAccessor
from .error import LarecsError
from .filter import Filter
from .host_storage import HostStorage
from .unsafe_box import UnsafeBox


trait SpatialClassifier(Copyable, Deinitable):
    """Read-only spatial policy with owned, copyable configuration.

    Implementations must be deterministic for unchanged declared components
    and configuration, must not mutate the world, and must not retain accessors
    or component references. Equal UInt64 keys identify one cluster; ascending
    key order determines physical order within each eligible archetype.
    """

    comptime Accessor: Copyable
    """EntityAccessor specialized for the registration filter."""

    def classify(self, entity: Self.Accessor) raises -> UInt64:
        """Computes the entity's cluster identity and ordering key.

        Args:
            entity: Borrowed component view, valid only during this call.

        Raises:
            Error: If classification fails; no rows move during classification.

        Returns:
            The cluster key, ordered numerically rather than by a hash.
        """
        ...


def grid_cell(position: Float64, cell_size: Float64) raises -> Int:
    """Maps a finite coordinate to a signed 21-bit cell using floor.

    Args:
        position: Coordinate relative to the application's grid origin.
        cell_size: Finite, strictly positive cell width.

    Raises:
        Error: If either input is invalid or the cell is outside
            [-1048576, 1048575]. Coordinates are never clamped or wrapped.

    Returns:
        The cell coordinate, including floor-based negative coordinates.
    """
    if not isfinite(position) or not isfinite(cell_size) or cell_size <= 0:
        raise Error(
            "Grid coordinates require finite inputs and positive cell size"
        )
    var cell = floor(position / cell_size)
    if not isfinite(cell) or cell < -1048576 or cell >= 1048576:
        raise Error("Grid cell is outside the signed 21-bit coordinate range")
    return Int(cell)


def morton_key_3d(x: Int, y: Int, z: Int = 0) raises -> UInt64:
    """Encodes signed 21-bit cells in a collision-free 63-bit Morton key.

    Each axis is biased by 1048576, then interleaved x/y/z from low bits
    upward. Use z=0 for a planar grid. Key adjacency does not imply spatial
    neighborhood; exact neighbor queries need a separate spatial index.

    Args:
        x: X cell in [-1048576, 1048575].
        y: Y cell in [-1048576, 1048575].
        z: Z cell in [-1048576, 1048575], defaulting to zero.

    Raises:
        Error: If any coordinate is outside the supported range.

    Returns:
        An injective key ordered by the biased Morton encoding.
    """
    if (
        x < -1048576
        or x >= 1048576
        or y < -1048576
        or y >= 1048576
        or z < -1048576
        or z >= 1048576
    ):
        raise Error("Morton cell is outside the signed 21-bit coordinate range")
    var bx = UInt64(x + 1048576)
    var by = UInt64(y + 1048576)
    var bz = UInt64(z + 1048576)
    var key = UInt64(0)
    for bit in range(21):
        key |= ((bx >> UInt64(bit)) & 1) << UInt64(3 * bit)
        key |= ((by >> UInt64(bit)) & 1) << UInt64(3 * bit + 1)
        key |= ((bz >> UInt64(bit)) & 1) << UInt64(3 * bit + 2)
    return key


def _sort_spatial_rows(keys: List[UInt64], mut rows: List[Int]):
    """Sorts destination-to-source rows by key in O(n log n) time.

    Args:
        keys: Cluster keys indexed by original row.
        rows: Row indices to sort; ties currently retain their input order.
    """
    var scratch = rows.copy()
    var width = 1
    while width < len(rows):
        var start = 0
        while start < len(rows):
            var middle = min(start + width, len(rows))
            var end = min(middle + width, len(rows))
            var left = start
            var right = middle
            for destination in range(start, end):
                if right == end or (
                    left < middle and keys[rows[left]] <= keys[rows[right]]
                ):
                    scratch[destination] = rows[left]
                    left += 1
                else:
                    scratch[destination] = rows[right]
                    right += 1
            start = end
        for index in range(len(rows)):
            rows[index] = scratch[index]
        width *= 2


def _maintain_spatial[
    filter: Filter, C: SpatialClassifier, *Ts: ComponentType
](mut storage: HostStorage[*Ts], classifier: UnsafeBox) raises LarecsError:
    """Classifies all eligible rows before applying typed permutations.

    Parameters:
        filter: Explicit read-only eligibility and access declaration.
        C: Registered policy type, checked by World.register_spatial_classifier.
        Ts: World component types.

    Args:
        storage: Unlocked world storage to maintain.
        classifier: Owned policy box paired with this function specialization.

    Raises:
        LarecsError: If storage is locked or classification fails. Classifier
            errors preserve all row orders and their original error message.
    """
    comptime assert (
        C.Accessor == EntityAccessor[filter]
    ), "Classifier Accessor must match its registration filter"
    storage._assert_unlocked()
    var indices = List[Int]()
    var permutations = List[List[Int]]()
    comptime mask = filter.get_bitmask_filter[*Ts]()
    ref policy = classifier.unsafe_get[C]()
    # Protect component pointers against reentrant structural operations while
    # user code is running. Release this lock before applying permutations.
    with storage._locked():
        for index in range(len(storage._archetypes)):
            ref archetype = storage._archetypes[index]
            if not mask.matches(archetype.get_mask()):
                continue
            var columns = Array[
                Pointer[UInt8, MutUntrackedOrigin], len(filter)
            ](uninitialized=True)
            comptime for column in range(len(filter)):
                comptime T = filter._include.ComponentTypes[column]
                columns[column] = archetype._storage.get_component_ptr[
                    T
                ]().unsafe_bitcast[UInt8]()
            var keys = List[UInt64](capacity=len(archetype))
            var ordered = True
            for row in range(len(archetype)):
                try:
                    var key = policy.classify(
                        rebind[C.Accessor](
                            EntityAccessor[filter](row, columns.copy())
                        )
                    )
                    if row > 0 and key < keys[row - 1]:
                        ordered = False
                    keys.append(key)
                except err:
                    raise LarecsError(err^)
            if ordered:
                continue
            var rows = List[Int](capacity=len(archetype))
            for row in range(len(archetype)):
                rows.append(row)
            _sort_spatial_rows(keys, rows)
            indices.append(index)
            permutations.append(rows^)
    storage._assert_unlocked()
    for plan in range(len(indices)):
        storage._reorder_archetype_rows(indices[plan], permutations[plan])
