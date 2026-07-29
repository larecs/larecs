from std.os import os
from std.python import Python, PythonObject
from std.time import perf_counter_ns

import larecs as lx

comptime RESULTS_DIR = "results"
"""Output directory for benchmark results."""

comptime FILE_NAME = "aos_benchmark"
"""Base name of benchmark output file."""

comptime TARGET_ITERATIONS = 10**9
"""Target number of total entity iterations for each benchmark."""


@fieldwise_init
struct BenchResult(ImplicitlyCopyable):
    var components: Int
    var entities: Int
    var nanos_ecs: Float64
    var nanos_aos: Float64


@fieldwise_init
struct BenchConfig[max_comp_exp: Int](ImplicitlyCopyable):
    var max_entity_exp: Int
    var target_iters: Int


def plot(config: BenchConfig, results: List[BenchResult]) raises:
    plt = Python.import_module("matplotlib.pyplot")

    var component_ticks: PythonObject = [2, 4, 8, 16, 32]
    var legend_point: PythonObject = [0]

    csv_file = os.path.join(RESULTS_DIR, FILE_NAME + ".csv")

    df = to_dataframe(results)
    df.to_csv(csv_file, index=False)

    fig_and_ax = plt.subplots(ncols=2, figsize=Python.tuple(10, 4))
    fig = fig_and_ax[0]
    ax = fig_and_ax[1]

    ax1 = ax[0]
    ax2 = ax[1]

    var handles: PythonObject = []
    var labels: PythonObject = []
    for comp_exp in range(1, config.max_comp_exp + 1):
        comp = 2**comp_exp
        var entities: PythonObject = []
        var nanos_ecs: PythonObject = []
        var nanos_aos: PythonObject = []
        for row in results:
            if row.components == comp:
                entities.append(row.entities)
                nanos_ecs.append(row.nanos_ecs)
                nanos_aos.append(row.nanos_aos)

        lw = 0.5 + Float64(comp_exp) / 4
        ax1.plot(
            entities,
            nanos_ecs,
            "-",
            c="k",
            lw=lw,
        )
        ax1.plot(
            entities,
            nanos_aos,
            "--",
            c="b",
            lw=lw,
        )
        if comp_exp == 1:
            labels.append("Larecs")
            handles.append(
                plt.Line2D(
                    legend_point,
                    legend_point,
                    color="k",
                    lw=1,
                    linestyle="-",
                )
            )
            labels.append("Array of Structs")
            handles.append(
                plt.Line2D(
                    legend_point,
                    legend_point,
                    color="b",
                    lw=1,
                    linestyle="--",
                )
            )
        labels.append(String("{0} components").format(String(comp)))
        handles.append(
            plt.Line2D(
                legend_point, legend_point, color="k", lw=lw, linestyle="-"
            )
        )

    ax1.set_xscale("log")
    ax1.set_xlabel("Entities")
    ax1.set_ylabel("Time per entity [ns]")
    ax1.legend(
        loc="upper left",
        fontsize="small",
        handles=handles,
        labels=labels,
    )

    handles = []
    labels = []
    for entity_exp in range(2, config.max_entity_exp + 1):
        num_entities = 10**entity_exp
        var components: PythonObject = []
        var nanos_ecs: PythonObject = []
        var nanos_aos: PythonObject = []
        for row in results:
            if row.entities == num_entities:
                components.append(row.components)
                nanos_ecs.append(row.nanos_ecs)
                nanos_aos.append(row.nanos_aos)

        lw = 0.5 + Float64(entity_exp) / 4
        ax2.plot(
            components,
            nanos_ecs,
            "-",
            c="k",
            lw=lw,
        )
        ax2.plot(
            components,
            nanos_aos,
            "--",
            c="b",
            lw=lw,
        )
        if entity_exp == 2:
            labels.append("Larecs")
            handles.append(
                plt.Line2D(
                    legend_point,
                    legend_point,
                    color="k",
                    lw=1,
                    linestyle="-",
                )
            )
            labels.append("Array of Structs")
            handles.append(
                plt.Line2D(
                    legend_point,
                    legend_point,
                    color="b",
                    lw=1,
                    linestyle="--",
                )
            )
        labels.append(String("10^{0} entities").format(String(entity_exp)))
        handles.append(
            plt.Line2D(
                legend_point, legend_point, color="k", lw=lw, linestyle="-"
            )
        )

    ax2.set_xscale("log")
    ax2.set_xlabel("Components")
    ax2.set_ylabel("Time per entity [ns]")
    ax2.set_xticks(component_ticks)
    ax2.set_xticklabels(component_ticks)
    ax2.legend(
        loc="upper left",
        fontsize="small",
        handles=handles,
        labels=labels,
    )

    fig.tight_layout()
    fig.savefig(os.path.join(RESULTS_DIR, FILE_NAME + ".svg"))
    fig.savefig(os.path.join(RESULTS_DIR, FILE_NAME + ".png"))


def to_dataframe(results: List[BenchResult]) raises -> PythonObject:
    pd = Python.import_module("pandas")
    var entities: PythonObject = []
    var components: PythonObject = []
    var nanos_ecs: PythonObject = []
    var nanos_aos: PythonObject = []
    for result in results:
        entities.append(result.entities)
        components.append(result.components)
        nanos_ecs.append(result.nanos_ecs)
        nanos_aos.append(result.nanos_aos)

    var data = Python.dict()
    data["entities"] = entities
    data["components"] = components
    data["nanos_ecs"] = nanos_ecs
    data["nanos_aos"] = nanos_aos

    return pd.DataFrame(data)


def run_benchmarks(config: BenchConfig, out results: List[BenchResult]) raises:
    results = List[BenchResult]()

    for ent_exp in range(2, config.max_entity_exp + 1):
        entities = 10**ent_exp
        rounds = config.target_iters // entities
        print(entities, "entities")

        comptime for compExp in range(1, config.max_comp_exp + 1):
            result = benchmark[compExp](rounds, entities)
            results.append(result)


def benchmark[
    components_exp: Int
](rounds: Int, entities: Int) raises -> BenchResult:
    w1 = create_ecs_world[components_exp](entities)
    var start_ecs = perf_counter_ns()
    for _ in range(rounds):
        for entity in w1.storage.query[Position, Velocity]():
            ref position = entity.get[Position]()
            ref velocity = entity.get[Velocity]()
            position.x += velocity.x
            position.y += velocity.y
    dur_ecs = Float64(perf_counter_ns() - start_ecs) / Float64(
        entities * rounds
    )

    w2 = AosWorld[components_exp](entities)
    var start_aos = perf_counter_ns()
    for _ in range(rounds):
        w2.update()
    dur_aos = Float64(perf_counter_ns() - start_aos) / Float64(
        entities * rounds
    )

    return BenchResult(
        entities=entities,
        components=2**components_exp,
        nanos_ecs=dur_ecs,
        nanos_aos=dur_aos,
    )


def create_ecs_world[components_exp: Int](entities: Int, out w: World) raises:
    w = World()
    for _ in range(entities):
        _ = create_ecs_entity[components_exp](w)


def create_ecs_entity[
    components_exp: Int
](mut w: World, out e: lx.Entity) raises:
    e = w.storage.add_entity(Position(1, 2), Velocity(1, 2))

    comptime for i in range(2**components_exp):
        w.storage.add(e, PayloadComponent[i](1.0, 2.0))


struct AosWorld[components_exp: Int](Copyable, Movable):
    var entities: List[AosEntity[Self.components_exp]]

    def __init__(out self, entities: Int):
        self.entities = List[AosEntity[Self.components_exp]]()
        for _ in range(entities):
            self.entities.append(AosEntity[Self.components_exp]())

    @always_inline
    def update(mut self):
        for ref entity in self.entities:
            entity.update()


@fieldwise_init
struct AosEntity[components_exp: Int](ImplicitlyCopyable):
    var comps: InlineArray[Position, 2**Self.components_exp]

    def __init__(out self):
        self.comps = InlineArray[Position, 2**Self.components_exp](
            fill=Position(1.0, 2.0)
        )

    def __init__(out self, *, copy: Self):
        self.comps = copy.comps.copy()

    @always_inline
    def update(mut self):
        self.comps[0].x += self.comps[1].x
        self.comps[0].y += self.comps[1].y


@fieldwise_init
struct Position(lx.ComponentType):
    var x: Float64
    var y: Float64


@fieldwise_init
struct Velocity(lx.ComponentType):
    var x: Float64
    var y: Float64


@fieldwise_init
struct PayloadComponent[i: Int](lx.ComponentType):
    var x: Float64
    var y: Float64


comptime World = lx.World[
    Position,
    Velocity,
    PayloadComponent[0],
    PayloadComponent[1],
    PayloadComponent[2],
    PayloadComponent[3],
    PayloadComponent[4],
    PayloadComponent[5],
    PayloadComponent[6],
    PayloadComponent[7],
    PayloadComponent[8],
    PayloadComponent[9],
    PayloadComponent[10],
    PayloadComponent[11],
    PayloadComponent[12],
    PayloadComponent[13],
    PayloadComponent[14],
    PayloadComponent[15],
]


def main() raises:
    config = BenchConfig[max_comp_exp=4](
        max_entity_exp=6, target_iters=TARGET_ITERATIONS
    )

    results = run_benchmarks(config)

    if not os.path.exists(RESULTS_DIR):
        os.mkdir(RESULTS_DIR)

    plot(config, results)
