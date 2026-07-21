from larecs.bitmask import BitMask
from larecs.component import ComponentType, ComponentManager
from larecs.archetype import _ComponentStorage
from larecs.unsafe_box import UnsafeBox

from std.sys.intrinsics import _type_is_eq


@fieldwise_init
struct Position(Copyable):
    var x: Float32
    var y: Float32


@fieldwise_init
struct Velocity(Copyable):
    var dx: Float32
    var dy: Float32


@fieldwise_init
struct Name(Copyable):
    var name: String


@fieldwise_init
struct QueryBuilder[*WorldTs: ComponentType](Movable):
    comptime component_manager = ComponentManager[*Self.WorldTs]

    var _include: BitMask
    var _exclude: BitMask

    def include[*Ts: ComponentType](deinit self) -> Self:
        self._include |= BitMask(Self.component_manager.get_id_arr[*Ts]())
        return self^

    def exclude[*Ts: ComponentType](deinit self) -> Self:
        self._exclude |= BitMask(Self.component_manager.get_id_arr[*Ts]())
        return self^

    def query(deinit self, is_mut: Bool = False) -> Query:
        return Query(
            include=self._include, exclude=self._exclude, is_mut=is_mut
        )


@fieldwise_init
struct _World[*WorldTs: ComponentType]:
    comptime component_manager = ComponentManager[*Self.WorldTs]
    comptime QueryBuilder = QueryBuilder[*Self.WorldTs]

    comptime filter = Self.QueryBuilder(_include=BitMask(), _exclude=BitMask())


@fieldwise_init
struct Query(Copyable):
    var is_mut: Bool
    var include: BitMask
    var exclude: BitMask


# struct Iterator[iterable_mut: Bool,//, origin: Origin[mut=iterable_mut], *WorldTs: ComponentType](Iterable, Movable):
#     comptime IteratorType[iterable_mut: Bool, //, origin: Origin[mut=iterable_mut]] = Iterator[origin, *Self.WorldTs]

#     def __init__(out self):
#         pass

#     def __iter__(deinit self) -> Self.IteratorType[Self.origin]:
#         return self^


struct EntityAccessor(Copyable):
    var id: Int

    def __init__(out self, id: Int):
        self.id = id

    def get[T: ComponentType](self) -> T:
        comptime if _type_is_eq[T, Position]():
            return rebind_var[T](Position(x=1.0, y=-1.0))
        elif _type_is_eq[T, Velocity]():
            return rebind_var[T](Velocity(dx=1.0, dy=-1.0))
        else:
            return rebind_var[T](Name(name=String(self.id)))


struct Iter2(Iterator, Movable):
    comptime Element = EntityAccessor

    var elems: List[EntityAccessor]
    var idx: Int

    def __init__(out self):
        self.elems = [
            EntityAccessor(id=1),
            EntityAccessor(id=2),
            EntityAccessor(id=3),
            EntityAccessor(id=4),
            EntityAccessor(id=5),
        ]
        self.idx = 0

    def __iter__(deinit self) -> Self:
        return self^

    def __next__(
        mut self,
    ) raises StopIteration -> ref[origin_of(self.elems)] Self.Element:
        if self.idx >= len(self.elems):
            raise StopIteration()
        ref result = self.elems[self.idx]
        self.idx += 1
        return result


struct Context[*WorldTs: ComponentType]:
    # comptime Iterator[iterable_mut: Bool, //, origin: Origin[mut=iterable_mut]] = Iterator[origin, *Self.WorldTs]

    def query[q: Query](self) -> Iter2:
        return Iter2()


trait System(Copyable, ImplicitlyDeletable):
    comptime Queries: List[Query]

    def update[*WorldTs: ComponentType](self, context: Context[*WorldTs]):
        ...


comptime World = _World[Position, Velocity, Name]


@fieldwise_init
struct Move(System):
    comptime pos_vel_query = World.filter.include[Position, Velocity]().query(
        is_mut=True
    )
    comptime name_query = World.filter.include[Name]().exclude[
        Position, Velocity
    ]().query()

    comptime Queries = [
        Self.pos_vel_query,
        Self.name_query,
    ]

    def update[*WorldTs: ComponentType](self, context: Context[*WorldTs]):
        for entity in context.query[Self.pos_vel_query]():
            ref pos = entity.get[Position]()
            ref vel = entity.get[Velocity]()

            pos.x += vel.dx
            pos.y += vel.dy

        for entity in context.query[Self.name_query]():
            ref pos = entity.get[Position]()  # MUST fail!
            ref name = entity.get[Name]()

            print(t"Entity named {name.name}")


@fieldwise_init
struct Collision(System):
    comptime Queries = [
        World.filter.include[Position]().query(),
    ]

    def update[*WorldTs: ComponentType](self, context: Context[*WorldTs]):
        pass


@fieldwise_init
struct Scheduler:
    var systems: List[Tuple[UnsafeBox, List[Query]]]

    def __init__(out self):
        self.systems = List[Tuple[UnsafeBox, List[Query]]]()

    def add_system[SystemType: System](mut self, var system: SystemType):
        var builder = StringBuilder("")
        write_system[SystemType](builder)
        print(builder.s)

        if self.get_conflicts(system):
            print("Conflicts with existing systems")
            return

        self.systems.append(
            (UnsafeBox(system^), materialize[SystemType.Queries]())
        )

    def get_conflicts[
        SystemType: System
    ](self, system: SystemType, out conflicts: List[Int]):
        conflicts = List[Int]()
        for sys_idx in range(len(self.systems)):
            ref queries = self.systems[sys_idx][1]
            if conflicts_with(system, queries):
                conflicts.append(sys_idx)


def conflicts_with[
    SystemType: System
](system: SystemType, queries: List[Query]) -> Bool:
    comptime for query1 in SystemType.Queries:
        for query2 in queries:
            if query1.include.matches(query2.include):
                return True
    return False


def main():
    scheduler = Scheduler()
    scheduler.add_system(Move())
    scheduler.add_system(Collision())


@fieldwise_init
struct StringBuilder(Writer):
    var s: String

    def write_string(mut self, string: StringSlice):
        self.s += string


def write_system[SystemType: System](mut writer: Some[Writer]):
    writer.write(t"System: {reflect[SystemType].name()}\n")
    comptime for query_id in range(len(SystemType.Queries)):
        comptime query = SystemType.Queries[query_id]
        writer.write(
            t"query_id: {query_id} -- ",
            "(mut)" if query.is_mut else "(immut)",
            "\n",
        )
        writer.write("  include:\n")
        for comp_id in query.include.get_indices():
            component_name = World.component_manager.get_type_name(comp_id)
            writer.write(t"    - {component_name} [{comp_id}]\n")
        else:
            writer.write("    (none)\n")

        writer.write("  exclude:\n")
        for comp_id in query.exclude.get_indices():
            component_name = World.component_manager.get_type_name(comp_id)
            writer.write(t"    - {component_name} [{comp_id}]\n")
        else:
            writer.write("    (none)\n")

        writer.write("\n")
