from std.collections.dict import Dict, DictKeyError
from std.reflection import reflect

from tracy import Zone

from .unsafe_box import UnsafeBox

comptime ResourceType = Copyable & Deinitable
"""The trait that resources must conform to."""


@fieldwise_init
struct Resources(Copyable, Movable, Sized):
    """Manages resources."""

    comptime IdType = StringSlice[ImmStaticOrigin]
    """The type of the internal type IDs."""

    var _storage: Dict[Self.IdType, UnsafeBox]

    @always_inline
    def __init__(out self):
        """
        Constructs an empty resource container.
        """
        with Zone(function_name="Resources.__init__()"):
            self._storage = Dict[Self.IdType, UnsafeBox]()

    @always_inline("nodebug")
    def __len__(self) -> Int:
        """Gets the number of stored resources.

        Returns:
            The number of stored resources.
        """
        with Zone(function_name="Resources.__len__()"):
            return len(self._storage)

    def add[*Ts: ResourceType](mut self, var *resources: *Ts) raises:
        """Adds resources.

        Parameters:
            Ts: The types of the resources to add.

        Args:
            resources: The resources to add.

        Raises:
            Error: If some resource already exists.
        """

        with Zone(
            function_name=(
                "Resources.add[*Ts: ResourceType](var *resources: *Ts)"
            )
        ):
            conflicting_ids = List[StringSlice[ImmStaticOrigin]](capacity=0)

            comptime for idx in range(len(Ts)):
                comptime id = reflect[Ts[idx]].name()
                if id in self._storage:
                    conflicting_ids.append(id)

            if conflicting_ids:
                raise Error("Duplicate resource: " + ", ".join(conflicting_ids))

            def take_resource[
                idx: Int
            ](var resource: Ts[idx]) capturing -> None:
                self._add(reflect[Ts[idx]].name(), resource^)

            resources^.consume_elements[take_resource]()

    @always_inline
    def _add(mut self, id: Self.IdType, var resource: Some[ResourceType]):
        """Adds a resource by ID.

        Args:
            id: The ID of the resource to add. It has to be not used already.
            resource: The resource to add.
        """
        with Zone(
            function_name=(
                "Resources._add(id: Self.IdType, var resource:"
                " Some[ResourceType])"
            )
        ):
            self._storage[id] = UnsafeBox(resource^)

    def set[
        *Ts: ResourceType, add_if_not_found: Bool = False
    ](mut self: Resources, var *resources: *Ts) raises:
        """Sets the values of resources.

        Parameters:
            Ts: The types of the resources to set.
            add_if_not_found: If true, adds resources that do not exist.

        Args:
            resources: The resources to set.

        Raises:
            Error: If one of the resources does not exist.
        """

        with Zone(
            function_name=(
                "Resources.set[*Ts: ResourceType, add_if_not_found: Bool](var"
                " *resources: *Ts)"
            )
        ):
            comptime if not add_if_not_found:
                conflicting_ids = List[StringSlice[ImmStaticOrigin]]()

                comptime for idx in range(len(Ts)):
                    comptime id = reflect[Ts[idx]].name()
                    if id not in self._storage:
                        conflicting_ids.append(id)

                if len(conflicting_ids) > 0:
                    raise Error(
                        "Unknown resource: " + ", ".join(conflicting_ids)
                    )

            def take_resource[
                idx: Int
            ](var resource: Ts[idx]) capturing -> None:
                self._set[add_if_not_found=add_if_not_found](
                    reflect[Ts[idx]].name(),
                    resource^,
                )

            resources^.consume_elements[take_resource]()

    @always_inline
    def _set[
        add_if_not_found: Bool
    ](mut self, id: Self.IdType, var resource: Some[ResourceType]):
        """Sets the values of the resources

        Parameters:
            add_if_not_found: If true, adds resources that do not exist.

        Args:
            id: The ID of the resource to set. If add_if_not_found is false, the resource ID must be already known.
            resource: The resource to set.
        """

        with Zone(
            function_name=(
                "Resources._set[add_if_not_found: Bool](id: Self.IdType, var"
                " resource: Some[ResourceType])"
            )
        ):
            try:
                self._storage[id].unsafe_get[type_of(resource)]() = resource^
            except:
                comptime if add_if_not_found:
                    self._add(id, resource^)

    def remove[*Ts: ResourceType](mut self: Resources) raises:
        """Removes resources.

        Parameters:
            Ts: The types of the resources to remove.

        Raises:
            Error: If one of the resources does not exist.
        """

        with Zone(function_name="Resources.remove[*Ts: ResourceType]()"):
            comptime for i in range(len(Ts)):
                self._remove[Ts[i]](reflect[Ts[i]].name())

    @always_inline
    def _remove[T: ResourceType](mut self, id: Self.IdType) raises:
        """Removes resources.

        Parameters:
            T: The type of the resource to remove.

        Raises:
            Error: If the resource does not exist.
        """
        with Zone(
            function_name="Resources._remove[T: ResourceType](id: Self.IdType)"
        ):
            try:
                _ = self._storage.pop(id)
            except DictKeyError:
                raise Error(t"The resource `{id}` does not exist.")

    @__unsafe_nested_origins_read_only
    @always_inline
    def get[
        T: ResourceType
    ](ref self) raises -> ref[
        origin_of(self._storage)._get_owned_interior["value"]
    ] T:
        """Gets a resource.

        Parameters:
            T: The type of the resource to get.

        Returns:
            A reference to the resource.
        """
        with Zone(function_name="Resources.get[T: ResourceType]()"):
            try:
                return self._storage[reflect[T].name()].unsafe_get[T]()
            except DictKeyError:
                raise Error(
                    t"The resource `{reflect[T].name()}` does not exist."
                )

    @always_inline
    def has[T: ResourceType](mut self) -> Bool:
        """Checks if the resource is present.

        Parameters:
            T: The type of the resource to check.

        Returns:
            True if the resource is present, otherwise False.
        """
        with Zone(function_name="Resources.has[T: ResourceType]()"):
            return reflect[T].name() in self._storage
