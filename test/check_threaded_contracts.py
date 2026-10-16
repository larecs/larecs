"""Check threaded eligibility and unconditional world lifetime diagnostics."""

from pathlib import Path
import subprocess
import tempfile

PRELUDE = """from std.utils import StaticTuple
from larecs import World, SystemContext, KernelContext, Filter, Resources, Captures, ReadCapture, read_capture, mut_capture, ThreadedExecutionConfig

@fieldwise_init
struct Owner(Copyable, Movable):
    var data: List[Int32]

@fieldwise_init
struct Indirect(Copyable, Movable):
    var pointer: Pointer[Int32, ImmUntrackedOrigin]

@fieldwise_init
struct Undeclared(Copyable, Movable):
    var values: StaticTuple[Float32, 4]
"""


def thin_program(component="Int32", resources="Resources()", captures="Captures()", options="threaded=True", selected=False, binding=None):
    """Build a forbidden public invocation, including its fallback path.

    Args:
        component: Accessed component type.
        resources: Resource access declarations.
        captures: Explicit capture declarations.
        options: Engine selection parameters.
        selected: Use an empty exact selection.
        binding: Optional binding expression overriding the declared-capture default.

    Returns:
        Source text for the complete program.
    """
    target = "selection" if selected else "context"
    extra = "    var selection = context._empty_selection()\n" if selected else ""
    if binding is None:
        binding = "read_capture(value)" if captures != "Captures()" else ""
    return (
        f"def kernel(rows: KernelContext[Filter().include[{component}](), {resources}, {captures}]):\n    pass\n"
        f"def main() raises:\n    var world = World[{component}]()\n"
        "    var context = SystemContext(world)\n    var value = Int32(1)\n"
        + extra + f"    {target}.run[kernel, {options}]({binding})\n"
    )


CASES = {
    "owning_component": (thin_program(component="Owner"), "Threaded components require pointer-free trivial plain values"),
    "pointer_component": (thin_program(component="Indirect"), "Threaded components require pointer-free trivial plain values"),
    "undeclared_array_component": (thin_program(component="Undeclared"), "Threaded components require pointer-free trivial plain values"),
    "owning_read_resource": (thin_program(resources="Resources().read[Owner]()"), "Threaded resources require pointer-free plain values or KernelView adapters"),
    "mutable_resource": (thin_program(resources="Resources[Int32]()"), "Threaded resources require explicit read access"),
    "read_write_resource": (thin_program(resources="Resources().read_write[Int32]()"), "Threaded resources require explicit read access"),
    "write_resource": (thin_program(resources="Resources().write[Int32]()"), "Threaded resources require explicit read access"),
    "read_capture": (thin_program(captures="Captures[ReadCapture[Int32]]()"), "Threaded execution does not support captures"),
    "conflicting_engines": (thin_program(options="threaded=True, on_device=True"), "Threaded and device execution are mutually exclusive"),
    "selected_component": (thin_program(component="Owner", selected=True), "Threaded components require pointer-free trivial plain values"),
    "selected_resource": (thin_program(resources="Resources[Int32]()", selected=True), "Threaded resources require explicit read access"),
    "selected_conflict": (thin_program(options="threaded=True, on_device=True", selected=True), "Threaded and device execution are mutually exclusive"),
}

for selected in (False, True):
    for access in ("read", "mut"):
        CASES[f"stray_{access}_binding_{selected}"] = (
            thin_program(selected=selected, binding=f"{access}_capture(value)"),
            "Threaded execution does not support captures",
        )
    target = "selection" if selected else "context"
    extra = "    var selection = context._empty_selection()\n" if selected else ""
    CASES[f"closure_{selected}"] = (
        "def main() raises:\n    var world = World[Int32]()\n    var context = SystemContext(world)\n"
        "    var calls = 0\n    def kernel(rows: KernelContext[Filter().include[Int32]()]) {mut calls}:\n        calls += 1\n"
        + extra + f"    {target}.run[threaded=True](kernel)\n",
        "Threaded execution requires a thin kernel; lexical closures are unsupported",
    )

# A live tracked context must prevent moving its owner before its last use.
CASES["move_borrowed_world"] = (
    "def kernel(rows: KernelContext[Filter().include[Int32]()]):\n    pass\n"
    "def main() raises:\n    var world = World[Int32]()\n    var context = SystemContext(world)\n"
    "    var moved = world^\n    context.run[kernel, threaded=True]()\n",
    "use of uninitialized value 'world'",
)

RUNTIME_PRELUDE = """from larecs import World, SystemContext, KernelContext, Filter, Resources, ThreadedExecutionConfig, DevicePassableResource, ResourceAdapter, ResourceDeviceCache
from std.testing import assert_equal, assert_false
comptime W = World[Int32]

@fieldwise_init
struct View(TrivialRegisterPassable):
    var active: Pointer[Bool, ImmUntrackedOrigin]

@fieldwise_init
struct Probe(DevicePassableResource):
    comptime KernelView = View
    comptime Adapter = Adapter
    var world: Pointer[W, MutUntrackedOrigin]

struct Adapter(ResourceAdapter):
    comptime Source = Probe
    comptime View = View
    @staticmethod
    def validate(source: Self.Source) raises:
        pass
    @staticmethod
    def prepare_device(source: Self.Source, mut cache: ResourceDeviceCache) raises -> Self.View:
        raise Error("host-only test")
    @staticmethod
    def bind_host(source: Self.Source) raises -> Self.View:
{action}
        return {Pointer[Bool, ImmUntrackedOrigin](unsafe_from_address=Int(Pointer(to=source.world[]._execution_active)))}

def plain(rows: KernelContext[Filter().include[Int32]()]):
    pass

def kernel(rows: KernelContext[Filter().include[Int32](), Resources().read[Probe]()]):
    for row in rows:
        row.get[Int32]() += Int32(1 if rows.resources.get[Probe]().active[] else 1000)

def main() raises:
    var world = W(execution_config=ThreadedExecutionConfig(workers=4, min_parallel_rows=0))
    var entity = world.storage.add_entity(Int32(1))
    _ = world.storage.add_entities(Int32(1), count=63)
    world.resources.add(Probe(Pointer[W, MutUntrackedOrigin](unsafe_from_address=Int(Pointer(to=world)))))
    var context = SystemContext(world)
{invoke}
"""

RUNTIME_CASES = {
    "copy": ("        var copied = source.world[].copy()", "Cannot copy an executing world"),
    "replace": ("        source.world[] = W()", "Cannot destroy an executing world"),
}


def build(source, binary, root):
    """Compile a contract program with runtime assertions disabled.

    Args:
        source: Mojo program path.
        binary: Output executable path.
        root: Repository root.

    Raises:
        OSError: If the compiler cannot be started.
        subprocess.TimeoutExpired: If compilation exceeds its bounded timeout.

    Returns:
        Completed compiler process with captured diagnostics.
    """
    return subprocess.run(
        ["mojo", "build", "-DASSERT=none", "-I", str(root / "src"), str(source), "-o", str(binary)],
        text=True, capture_output=True, timeout=90,
    )


def main():
    """Require precise compile failures and unconditional lifetime enforcement.

    Raises:
        RuntimeError: If a program violates the expected public contract.
    """
    root = Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix="larecs-threaded-contracts-") as directory:
        temporary = Path(directory)
        for name, (program, diagnostic) in CASES.items():
            source = temporary / f"{name}.mojo"
            source.write_text(PRELUDE + "\n" + program)
            result = build(source, temporary / name, root)
            if result.returncode == 0 or diagnostic not in result.stdout + result.stderr:
                raise RuntimeError(f"{name}: expected {diagnostic!r}\n{result.stdout}{result.stderr}")
            print(f"PASS: threaded contract {name}", flush=True)
        runtime = dict(RUNTIME_CASES)
        runtime["nested"] = ("        var nested = SystemContext(source.world[])\n        nested.run[plain]()", None)
        runtime["structural"] = ("        _ = source.world[].storage.add_entity(Int32(99))", None)
        runtime["active_until_join"] = ("        pass", None)
        for name, (action, diagnostic) in runtime.items():
            invoke = "    context.run[kernel, threaded=True]()\n"
            if name in ("nested", "structural"):
                invoke = (
                    "    var rejected = False\n    try:\n        context.run[kernel, threaded=True]()\n"
                    "    except:\n        rejected = True\n    assert_equal(rejected, True)\n"
                    "    assert_false(world._execution_active)\n    assert_false(world.storage.is_locked())\n"
                    "    assert_equal(world.storage.get[Int32](entity), 1)\n"
                )
            elif name == "active_until_join":
                invoke += "    assert_equal(world.storage.get[Int32](entity), 2)\n    assert_false(world._execution_active)\n"
            source = temporary / f"live_{name}.mojo"
            source.write_text(RUNTIME_PRELUDE.replace("{action}", action).replace("{invoke}", invoke))
            binary = temporary / f"live_{name}"
            result = build(source, binary, root)
            if result.returncode:
                raise RuntimeError(f"{name}: build failed\n{result.stdout}{result.stderr}")
            result = subprocess.run([str(binary)], text=True, capture_output=True, timeout=30)
            if diagnostic:
                if result.returncode == 0 or diagnostic not in result.stdout + result.stderr:
                    raise RuntimeError(f"{name}: expected abort {diagnostic!r}\n{result.stdout}{result.stderr}")
            elif result.returncode:
                raise RuntimeError(f"{name}: execution failed\n{result.stdout}{result.stderr}")
            print(f"PASS: threaded lifetime {name} (assertions disabled)", flush=True)


if __name__ == "__main__":
    main()
