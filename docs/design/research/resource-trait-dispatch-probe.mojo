"""Probe optional resource traits through broad bounds without a GPU.

Run with `pixi run mojo run -I src docs/design/research/resource-trait-dispatch-probe.mojo`.
This models registration hooks around the real ResourceStorage; it does not add
an adapter API or validate device allocation/queue lifetime handling.
"""

from std.reflection import reflect
from std.testing import assert_equal
from larecs.resource import ResourceStorage, ResourceType


trait ProbeAdapter:
    """Stateless adapter metadata used only by this compiler probe."""

    @staticmethod
    def tag() -> Int:
        """Returns an adapter marker.

        Returns:
            An integer identifying the adapter implementation.
        """
        ...


trait ProbeResource(Copyable):
    """Optional source capability with associated view and adapter types."""

    comptime KernelView: TrivialRegisterPassable
    comptime Adapter: ProbeAdapter


struct StatelessAdapter(ProbeAdapter):
    """An adapter type called without constructing an instance."""

    @staticmethod
    def tag() -> Int:
        """Returns this adapter's marker.

        Returns:
            The marker 17.
        """
        return 17


@fieldwise_init
struct Adapted(Movable, ProbeResource):
    """Owning source for which generic registration resolves associated types.
    """

    comptime KernelView = Int32
    comptime Adapter = StatelessAdapter
    var values: List[Int32]


@fieldwise_init
struct Plain(Copyable, Movable):
    """Ordinary resource without the optional capability."""

    var value: Int


def adapter_tag[T: ResourceType](value: T) -> Int:
    """Resolves optional associated types inside a broad ResourceType bound.

    Parameters:
        T: Concrete source type.

    Args:
        value: Source used to infer T; no source data is captured.

    Returns:
        The associated adapter marker, or zero for an ordinary resource.
    """
    comptime if conforms_to(T, ProbeResource):
        comptime assert conforms_to(T, ProbeResource)
        comptime assert T.KernelView == Int32
        return T.Adapter.tag()
    else:
        return 0


struct ProbeRegistry(Copyable, Movable):
    """Registration model wrapping actual host storage and type-only metadata.
    """

    var resources: ResourceStorage
    var tags: Dict[String, Int]

    def __init__(out self):
        """Creates empty storage and a registration metadata table."""
        self.resources = ResourceStorage()
        self.tags = Dict[String, Int]()

    def add[*Ts: ResourceType](mut self, var *values: *Ts) raises:
        """Models the variadic consume pattern in ResourceStorage.add.

        Parameters:
            Ts: Concrete resource types with only the broad storage bound.

        Args:
            values: Sources transferred into storage.

        Raises:
            Error: If a source type is already stored.
        """
        comptime for idx in range(len(Ts)):
            if self.resources.has[Ts[idx]]():
                raise Error("Duplicate probe resource")

        def take[idx: Int](var value: Ts[idx]) capturing:
            """Records type metadata and inserts one concrete source.

            Parameters:
                idx: Position in the heterogeneous argument tuple.

            Args:
                value: Source transferred into actual ResourceStorage.
            """
            self.tags[String(reflect[Ts[idx]].name())] = adapter_tag(value)
            self.resources._add(reflect[Ts[idx]].name(), value^)

        values^.consume_elements[take]()

    def set[*Ts: ResourceType](mut self, var *values: *Ts):
        """Models insertion via ResourceStorage.set[add_if_not_found=True].

        Parameters:
            Ts: Concrete resource types with only the broad storage bound.

        Args:
            values: Sources replacing existing or creating missing entries.
        """

        def take[idx: Int](var value: Ts[idx]) capturing:
            """Resolves type metadata and sets one concrete source.

            Parameters:
                idx: Position in the heterogeneous argument tuple.

            Args:
                value: Source transferred into actual ResourceStorage.
            """
            self.tags[String(reflect[Ts[idx]].name())] = adapter_tag(value)
            self.resources._set[add_if_not_found=True](
                reflect[Ts[idx]].name(), value^
            )

        values^.consume_elements[take]()


def main() raises:
    """Checks add, insert-on-set, copy metadata, and independent source copies.

    Raises:
        Error: If registration dispatch or source-copy checks fail.
    """
    var values: List[Int32] = [1, 2]
    var registry = ProbeRegistry()
    registry.add(Plain(3), Adapted(values^))
    assert_equal(registry.tags[String(reflect[Adapted].name())], 17)
    assert_equal(registry.tags[String(reflect[Plain].name())], 0)

    var inserted = ProbeRegistry()
    var replacement: List[Int32] = [4, 5]
    inserted.set(Plain(6), Adapted(replacement^))
    assert_equal(inserted.tags[String(reflect[Adapted].name())], 17)
    assert_equal(inserted.resources.get[Adapted]().values[0], 4)

    var copied = registry.copy()
    copied.resources.get[Adapted]().values[0] = 9
    assert_equal(copied.tags[String(reflect[Adapted].name())], 17)
    assert_equal(registry.resources.get[Adapted]().values[0], 1)
    assert_equal(copied.resources.get[Adapted]().values[0], 9)
    print(
        "PASS: optional traits, associated types, add/set dispatch, copied"
        " metadata"
    )
