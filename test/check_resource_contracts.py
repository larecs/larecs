"""Compile forbidden resource programs and verify their public diagnostics."""

from pathlib import Path
import subprocess
import tempfile

PRELUDE = """from larecs import World, SystemContext, KernelContext, Filter, Resources, ResourceType, BufferResource, DevicePassableResource, ResourceAdapter, ResourceDeviceCache
from larecs.resource import ResourceStorage, _validate_resource_spec, _ResourceInvocation

@fieldwise_init
struct Plain(ResourceType):
    var value: Int32

@fieldwise_init
struct Owner(ResourceType):
    var values: List[Int32]

comptime Samples = BufferResource[DType.int32]
"""

CASES = {
    "mutable_descriptor": (
        "@fieldwise_init\nstruct View(TrivialRegisterPassable):\n    var samples: Pointer[Int32, MutUntrackedOrigin]\n"
        "@fieldwise_init\nstruct Adapted(DevicePassableResource):\n    comptime KernelView = View\n    comptime Adapter = BadAdapter\n    var values: List[Int32]\n"
        "struct BadAdapter(ResourceAdapter):\n    comptime Source = Adapted\n    comptime View = View\n"
        "    @staticmethod\n    def validate(source: Self.Source) raises:\n        pass\n"
        "    @staticmethod\n    def bind_host(source: Self.Source) raises -> Self.View:\n        return {Pointer[Int32, MutUntrackedOrigin](unsafe_from_address=1)}\n"
        "    @staticmethod\n    def prepare_device(source: Self.Source, mut cache: ResourceDeviceCache) raises -> Self.View:\n        return {Pointer[Int32, MutUntrackedOrigin](unsafe_from_address=1)}\n"
        "def main() raises:\n    var resources = ResourceStorage()\n    resources.add(Adapted(List[Int32]()))\n",
        "KernelView requires trivial metadata and immutable pointers",
    ),
    "move_borrowed_storage": (
        "def main() raises:\n    var resources = ResourceStorage()\n    resources.add(Plain(1))\n"
        "    var binding = _ResourceInvocation[Resources().read[Plain](), origin_of(resources)](resources)\n"
        "    var moved = resources^\n    binding.release()\n",
        "use of uninitialized value 'resources'",
    ),
    "immutable_plain": (
        "def bad(context: KernelContext[Filter().include[Int32](), Resources().read[Plain]()]):\n"
        "    context.resources.get[Plain]().value = 9\n\ndef main():\n    pass\n",
        "expression must be mutable",
    ),
    "immutable_view": (
        "def bad(context: KernelContext[Filter().include[Int32](), Resources().read[Samples]()]):\n"
        "    context.resources.get[Samples]()._pointer[] = 9\n\ndef main():\n    pass\n",
        "expression must be mutable",
    ),
    "write_only_get": (
        "def bad(context: KernelContext[Filter().include[Int32](), Resources().write[Plain]()]):\n"
        "    _ = context.resources.get[Plain]()\n\ndef main() raises:\n"
        "    var world = World[Int32]()\n    var context = SystemContext(world)\n    context.run[bad]()\n",
        "Write-only resources provide set, not get",
    ),
    "read_only_set": (
        "def bad(context: KernelContext[Filter().include[Int32](), Resources().read[Plain]()]):\n"
        "    context.resources.set[Plain](Plain(9))\n\ndef main() raises:\n"
        "    var world = World[Int32]()\n    var context = SystemContext(world)\n    context.run[bad]()\n",
        "Read resources cannot be set",
    ),
    "adapted_legacy": (
        "def main():\n    _validate_resource_spec[Resources[Samples](), False]()\n",
        "DevicePassableResource requires read access on both targets",
    ),
    "adapted_write": (
        "def main():\n    _validate_resource_spec[Resources().write[Samples](), False]()\n",
        "DevicePassableResource requires read access on both targets",
    ),
    "duplicate_source": (
        "def main():\n    _validate_resource_spec[Resources().read[Plain]().read_write[Plain](), False]()\n",
        "Duplicate resource source declaration",
    ),
    "device_write": (
        "def main():\n    _validate_resource_spec[Resources().write[Plain](), True]()\n",
        "Device write-only resources are unsupported",
    ),
    "device_owner": (
        "def main():\n    _validate_resource_spec[Resources().read[Owner](), True]()\n",
        "Device resources require pointer-free trivial plain values or DevicePassableResource",
    ),
    "view_type_lookup": (
        "def bad(context: KernelContext[Filter().include[Int32](), Resources().read[Samples]()]):\n"
        "    _ = context.resources.get[Samples.KernelView]()\n\ndef main() raises:\n"
        "    var world = World[Int32]()\n    var context = SystemContext(world)\n    context.run[bad]()\n",
        "T must be part of the kernel's required_resources",
    ),
}


RUNTIME_CASES = {
    "copy": ("var copied = escaped[].copy()", "Cannot copy leased or unusable resources"),
    "destroy": ("escaped[] = ResourceStorage()", "Cannot destroy leased resources"),
}


def main():
    """Require compilation failures to report the intended access violations."""
    root = Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix="larecs-resource-contracts-") as directory:
        temporary = Path(directory)
        for name, (program, diagnostic) in CASES.items():
            source = temporary / f"{name}.mojo"
            source.write_text(PRELUDE + "\n" + program)
            result = subprocess.run(
                ["mojo", "build", "-I", str(root / "src"), str(source), "-o", str(temporary / name)],
                text=True, capture_output=True, timeout=60,
            )
            output = result.stdout + result.stderr
            if result.returncode == 0 or diagnostic not in output:
                raise RuntimeError(f"{name}: expected {diagnostic!r}\n{output}")
            print(f"PASS: resource contract {name}")
        for name, (action, diagnostic) in RUNTIME_CASES.items():
            source = temporary / f"live_{name}.mojo"
            source.write_text(
                PRELUDE + "\nfrom larecs.resource import _ResourceInvocation\n"
                "def main() raises:\n    var resources = ResourceStorage()\n    resources.add(Plain(1))\n"
                "    var escaped = Pointer[ResourceStorage, MutUntrackedOrigin](unsafe_from_address=Int(Pointer(to=resources)))\n"
                "    var binding = _ResourceInvocation[Resources().read[Plain](), origin_of(resources)](resources)\n"
                "    " + action + "\n    binding.release()\n"
            )
            binary = temporary / f"live_{name}"
            subprocess.run(["mojo", "build", "-DASSERT=none", "-I", str(root / "src"), str(source), "-o", str(binary)],
                           check=True, text=True, capture_output=True, timeout=60)
            result = subprocess.run([str(binary)], text=True, capture_output=True, timeout=30)
            if result.returncode == 0 or diagnostic not in result.stdout + result.stderr:
                raise RuntimeError(f"live_{name}: expected abort {diagnostic!r}\n{result.stdout}{result.stderr}")
            print(f"PASS: resource lifetime guard {name} (assertions disabled)")


if __name__ == "__main__":
    main()
