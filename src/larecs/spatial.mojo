"""Opt-in host spatial classification and explicit row maintenance."""

from std.math import floor, isfinite
from std.hashlib import Hasher

from .component import ComponentType
from .entity import Entity, EntityAccessor, EntityLocation
from .error import LarecsError
from .filter import Filter, BitMaskFilter
from .host_storage import HostStorage
from .unsafe_box import UnsafeBox


@fieldwise_init
struct _PartitionId(Equatable, Hashable, ImplicitlyCopyable):
    """A cluster beneath one component-defined transition-graph node."""

    var node: Int
    var key: UInt64

    def __eq__(self, other: Self) -> Bool:
        """Compare both parts of a partition identity.

        Args:
            other: Identity to compare.

        Returns:
            Whether both the logical archetype and cluster key match.
        """
        return self.node == other.node and self.key == other.key

    def __hash__[H: Hasher](self, mut hasher: H):
        """Hash both parts without collapsing distinct logical archetypes.

        Parameters:
            H: Hash implementation.

        Args:
            hasher: Accumulator receiving the node and cluster key.
        """
        hasher.update(self.node)
        hasher.update(self.key)


trait SpatialClassifier(Copyable, Deinitable):
    """Read-only spatial policy with owned, copyable configuration.

    Implementations must be deterministic for unchanged declared components
    and configuration, must not mutate the world, and must not retain accessors
    or component references. Equal UInt64 keys identify one cluster. The default
    reordering mode traverses ascending keys; partition blocks have no global
    key-order or allocation-adjacency guarantee.
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
    """Classifies deferred invalidations before applying typed permutations.

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
    if not storage._spatial_full and len(storage._spatial_dirty) == 0:
        return
    # When every allocated identity is marked, contiguous classification avoids
    # per-dirty-location setup. Holes or excluded identities only delay this
    # conservative optimization; they cannot cause a missed invalidation.
    if len(storage._spatial_dirty) == len(storage._entity_locations) - 1:
        storage._spatial_full = True
    var indices = List[Int]()
    var permutations = List[List[Int]]()
    var pending = List[UInt64]()
    if not storage._spatial_full:
        pending = storage._spatial_keys.copy()
    pending.resize(len(storage._entity_locations), UInt64(0))
    var affected = Dict[Int, Bool]()
    comptime mask = filter.get_bitmask_filter[*Ts]()
    ref policy = classifier.unsafe_get[C]()
    # Keep committed keys and invalidations intact until every callback succeeds.
    with storage._locked():
        for index in range(len(storage._archetypes)):
            ref archetype = storage._archetypes[index]
            if (
                len(archetype) == 0
                or not storage._spatial_full
                or not mask.matches(archetype.get_mask())
            ):
                continue
            var columns = Array[
                Pointer[UInt8, MutUntrackedOrigin], len(filter)
            ](uninitialized=True)
            comptime for column in range(len(filter)):
                comptime T = filter._include.ComponentTypes[column]
                columns[column] = archetype._storage.get_component_ptr[
                    T
                ]().unsafe_bitcast[UInt8]()
            if storage._spatial_full:
                if not storage._spatial_partitioned:
                    affected[index] = True
                for row in range(len(archetype)):
                    try:
                        pending[
                            Int(archetype.get_entity(row).get_id())
                        ] = policy.classify(
                            rebind[C.Accessor](
                                EntityAccessor[filter](row, columns.copy())
                            )
                        )
                    except err:
                        raise LarecsError(err^)
        if not storage._spatial_full:
            for entity in storage._spatial_dirty:
                if not storage.is_alive(entity):
                    continue
                var location = storage._entity_locations[entity.get_id()]
                ref archetype = storage._archetypes[location.archetype_index]
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
                try:
                    pending[Int(entity.get_id())] = policy.classify(
                        rebind[C.Accessor](
                            EntityAccessor[filter](
                                location.entity_index, columns.copy()
                            )
                        )
                    )
                except err:
                    raise LarecsError(err^)
                if not storage._spatial_partitioned:
                    affected[location.archetype_index] = True
        if not storage._spatial_partitioned:
            _prepare_spatial_permutations(
                storage, affected, pending, indices, permutations
            )
    storage._assert_unlocked()
    if storage._spatial_partitioned:
        _partition_spatial_rows(storage, pending, mask)
    for plan in range(len(indices)):
        storage._reorder_archetype_rows(indices[plan], permutations[plan])
    storage._spatial_keys = pending^
    if storage._spatial_full:
        storage._spatial_marked = List[Bool]()
        storage._spatial_marked.resize(len(storage._entity_locations), False)
    else:
        for entity in storage._spatial_dirty:
            storage._spatial_marked[Int(entity.get_id())] = False
    storage._spatial_dirty.clear()
    storage._spatial_full = False


def _prepare_spatial_permutations[
    *Ts: ComponentType
](
    storage: HostStorage[*Ts],
    affected: Dict[Int, Bool],
    pending: List[UInt64],
    mut indices: List[Int],
    mut permutations: List[List[Int]],
) raises LarecsError:
    """Prepare row reordering without moving live component values.

    Parameters:
        Ts: World component types.

    Args:
        storage: Locked storage.
        affected: Physical stores with updated keys.
        pending: Classified keys by identity.
        indices: Output store indices.
        permutations: Output permutations.

    Raises:
        LarecsError: If component access fails.
    """
    for index in affected:
        ref archetype = storage._archetypes[index]
        var keys = List[UInt64](capacity=len(archetype))
        var ordered = True
        for row in range(len(archetype)):
            var entity = archetype.get_entity(row)
            var key = pending[Int(entity.get_id())]
            if row > 0 and key < keys[row - 1]:
                ordered = False
            keys.append(key)
        if ordered:
            continue
        var rows = List[Int](capacity=len(archetype))
        for row in range(len(archetype)):
            rows.append(row)
        _sort_spatial_rows(keys, rows)
        indices.append(index)
        permutations.append(rows^)


def _transfer_partition_row[
    *Ts: ComponentType
](mut storage: HostStorage[*Ts], entity: Entity, destination: Int,):
    """Move one initialized row and repair both identities after compaction.

    Parameters:
        Ts: World component types.

    Args:
        storage: Unlocked storage; source and destination have identical masks.
        entity: Live identity to transfer.
        destination: Distinct physical block with available capacity.
    """
    var location = storage._entity_locations[entity.get_id()]
    ref target = storage._archetypes[destination]
    ref source = storage._archetypes[location.archetype_index]
    debug_assert(
        location.archetype_index != destination,
        "Partition transfer must have distinct stores",
    )
    debug_assert(
        source.get_mask() == target.get_mask(),
        "Partition transfer must preserve component composition",
    )
    debug_assert(
        len(target) < storage._spatial_block_capacity, "Partition block is full"
    )
    # Pre-grow both owners so ordinary append cannot apply its eight-row floor.
    if len(target) == target._storage._capacity:
        target._storage.reserve(
            min(target._storage._capacity * 2, storage._spatial_block_capacity)
        )
    target._entities.reserve(target._storage._capacity)
    var row = target.add_entity(entity)
    target._storage.unsafe_move_shared_components_from(
        row,
        Pointer(to=source._storage).as_unsafe_any_origin(),
        1,
        location.entity_index,
    )
    var destination_mask = target.get_mask().copy()
    if source.unsafe_remove_after_moving_shared_components(
        location.entity_index, destination_mask
    ):
        var displaced = source.get_entity(location.entity_index)
        storage._entity_locations[
            displaced.get_id()
        ].entity_index = location.entity_index
    storage._entity_locations[entity.get_id()] = EntityLocation(
        row, destination
    )


def _partition_spatial_rows[
    *Ts: ComponentType
](mut storage: HostStorage[*Ts], keys: List[UInt64], mask: BitMaskFilter,):
    """Place changed identities, compact within clusters, and reclaim empty blocks.

    Partition directories are rebuilt at active boundaries. Graph values name
    staging stores; physical blocks share their node but never enter the graph.
    Allocation failure is fatal, as for ordinary storage. All classifier calls
    and recoverable validation finish before this non-raising movement phase.

    Parameters:
        Ts: World component types.

    Args:
        storage: Unlocked storage with successfully classified pending keys.
        keys: Final keys indexed by entity identity.
        mask: Classifier eligibility filter.
    """
    var blocks = Dict[_PartitionId, Int]()
    var groups = List[List[Int]]()
    var candidates = List[Entity]()
    for index in range(len(storage._archetypes)):
        ref block = storage._archetypes[index]
        if block._partition_key:
            var cluster = _PartitionId(
                block.get_node_index(), block._partition_key.value()
            )
            if cluster not in blocks:
                blocks[cluster] = len(groups)
                groups.append(List[Int]())
            groups[blocks.get(cluster).value()].append(index)
        if storage._spatial_full and mask.matches(block.get_mask()):
            for entity in block.get_entities():
                candidates.append(entity)
    if not storage._spatial_full:
        for entity in storage._spatial_dirty:
            if storage.is_alive(entity):
                var location = storage._entity_locations[entity.get_id()]
                if mask.matches(
                    storage._archetypes[location.archetype_index].get_mask()
                ):
                    candidates.append(entity)
    var limit = storage._spatial_block_capacity
    for entity in candidates:
        var location = storage._entity_locations[entity.get_id()]
        var source_index = location.archetype_index
        var key = keys[Int(entity.get_id())]
        if storage._archetypes[source_index]._partition_key:
            if storage._archetypes[source_index]._partition_key.value() == key:
                continue
        var node = storage._archetypes[source_index].get_node_index()
        var cluster = _PartitionId(node, key)
        if cluster not in blocks:
            blocks[cluster] = len(groups)
            groups.append(List[Int]())
        var group_index = blocks.get(cluster).value()
        var destination = -1
        if len(groups[group_index]) > 0:
            var last = groups[group_index][len(groups[group_index]) - 1]
            if len(storage._archetypes[last]) < limit:
                destination = last
        if destination == -1:
            var component_mask = (
                storage._archetypes[source_index].get_mask().copy()
            )
            var fresh = storage.Archetype(node, component_mask, capacity=1)
            fresh._partition_key = key
            if len(storage._spatial_free_blocks) > 0:
                destination = storage._spatial_free_blocks.pop()
                storage._archetypes[destination] = fresh^
            else:
                destination = len(storage._archetypes)
                storage._archetypes.append(fresh^)
            groups[group_index].append(destination)
        _transfer_partition_row(storage, entity, destination)
    # Fill earlier blocks from the final block of the SAME logical cluster.
    # No locations or pending row indices survive a transfer.
    for ref indices in groups:
        var left = 0
        var right = len(indices) - 1
        while left < right:
            var destination = indices[left]
            var source = indices[right]
            if len(storage._archetypes[destination]) == limit:
                left += 1
            elif len(storage._archetypes[source]) == 0:
                right -= 1
            else:
                var entity = storage._archetypes[source].get_entity(
                    len(storage._archetypes[source]) - 1
                )
                _transfer_partition_row(storage, entity, destination)
    # Replacing empty storage destroys its allocations, never live values.
    for index in range(len(storage._archetypes)):
        if len(storage._archetypes[index]) != 0:
            continue
        if storage._archetypes[index]._partition_key:
            storage._archetypes[index] = storage.Archetype()
            storage._archetypes[index]._node_index = -1
            storage._spatial_free_blocks.append(index)
        elif (
            storage._archetypes[index].get_node_index() >= 0
            and storage._archetypes[index]._storage._capacity > 0
        ):
            var node = storage._archetypes[index].get_node_index()
            var component_mask = storage._archetypes[index].get_mask().copy()
            storage._archetypes[index] = storage.Archetype(
                node, component_mask, capacity=0
            )
    # Drop trailing tombstones without changing any live or graph-owned index.
    while (
        storage._archetypes[len(storage._archetypes) - 1].get_node_index() == -1
    ):
        _ = storage._archetypes.pop()
    var reusable = List[Int]()
    for index in storage._spatial_free_blocks:
        if index < len(storage._archetypes):
            reusable.append(index)
    storage._spatial_free_blocks = reusable^
