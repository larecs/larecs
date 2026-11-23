"""Compile accepted and rejected struct bindings, including type-only uses.

Run with `pixi run -e test python test/check_struct_constraints.py`.
Type annotations deliberately avoid constructors: struct invariants must hold
before a constructor or operation is instantiated.
"""

from pathlib import Path
import subprocess
import tempfile


IMPORTS = """from larecs.bitmask import _BitMask, _BitMaskIndexIter
from larecs.sync import AtomicValue, AtomicView, SyncView
from larecs.component import Components, ComponentManager
from larecs.resource import Resources
from larecs.filter import Filter
from larecs.world import World
from larecs.device_storage import DeviceComponentStorage
from larecs.static_optional import StaticOptional
"""

# Each rejection is paired with a valid binding of the same struct.
CASES = [
    ("minimum_mask", "_BitMask[8]", "_BitMask[4]", "_BitMask"),
    ("zero_mask", "_BitMask[256]", "_BitMask[0]", "_BitMask"),
    ("negative_mask", "_BitMask[512]", "_BitMask[-8]", "_BitMask"),
    ("non_power_mask", "_BitMask[16]", "_BitMask[24]", "_BitMask"),
    ("minimum_iterator", "_BitMaskIndexIter[8]", "_BitMaskIndexIter[4]", "_BitMaskIndexIter"),
    ("non_power_iterator", "_BitMaskIndexIter[256]", "_BitMaskIndexIter[24]", "_BitMaskIndexIter"),
    ("unsigned_atomic", "AtomicValue[UInt32]", "AtomicValue[UInt64]", "AtomicValue"),
    ("signed_atomic", "AtomicValue[Int32]", "AtomicValue[Int64]", "AtomicValue"),
    ("float_atomic", "AtomicValue[Int32]", "AtomicValue[Float32]", "AtomicValue"),
    ("view_scalar", "AtomicView[False, Int32, ImmUntrackedOrigin]", "AtomicView[False, UInt64, ImmUntrackedOrigin]", "AtomicView"),
    ("view_origin", "AtomicView[True, UInt32, MutUntrackedOrigin]", "AtomicView[True, UInt32, ImmUntrackedOrigin]", "AtomicView"),
    ("sync_origin", "SyncView[True, String, MutUntrackedOrigin]", "SyncView[True, String, ImmUntrackedOrigin]", "SyncView"),
]

# These bindings protect intentional exclusions from overconstraint.
ACCEPTED = [
    "AtomicView[False, UInt32, MutUntrackedOrigin]",
    "SyncView[False, String, ImmUntrackedOrigin]",
    "SyncView[False, String, MutUntrackedOrigin]",
    "ComponentManager[]",
    "ComponentManager[Int, Int]",
    "ComponentManager[" + ", ".join(["Int"] * 256) + "]",
    "Components[Int, Int]",
    "Resources[Int, Int]",
    "Filter[].read[Int].write[Int]",
    "World[String]",
    "DeviceComponentStorage[String]",
    "StaticOptional[String, False]",
]


def main():
    """Check type bindings and require constraint-specific negative diagnostics.

    Raises:
        RuntimeError: If a valid binding fails or an invalid binding is accepted
            or rejected without a diagnostic identifying its struct constraint.
    """
    root = Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix="larecs-struct-constraints-") as directory:
        temporary = Path(directory)

        def compile_binding(name, binding, rejected_struct=None):
            """Compile a type-only binding and check its expected outcome.

            Args:
                name: Case name used for diagnostics.
                binding: Mojo type expression to bind without construction.
                rejected_struct: Struct whose constraint must reject the binding,
                    or None for an accepted binding.

            Raises:
                RuntimeError: If compilation disagrees with the contract.
            """
            source = temporary / "binding.mojo"
            source.write_text(
                IMPORTS + '\ndef main():\n    """Binds a struct without constructing it."""\n'
                + f"    var value: {binding}\n"
            )
            result = subprocess.run(
                ["mojo", "build", "--emit", "llvm", "-I", str(root / "src"),
                 str(source), "-o", str(temporary / "binding.ll")],
                text=True, capture_output=True, timeout=120,
            )
            output = result.stdout + result.stderr
            if rejected_struct is None:
                valid = result.returncode == 0
            else:
                valid = (
                    result.returncode != 0
                    and "constraint declared here" in output
                    and (f"'{rejected_struct}' declared here" in output
                         or f"invalid bindings for '{rejected_struct}'" in output)
                )
            if not valid:
                raise RuntimeError(f"{name}: unexpected compiler result\n{output}")
            print(f"PASS: struct constraint {name}", flush=True)

        for name, accepted, rejected, struct in CASES:
            compile_binding(name + "_accepted", accepted)
            compile_binding(name + "_rejected", rejected, struct)
        for i, binding in enumerate(ACCEPTED):
            compile_binding(f"preserved_{i}", binding)


if __name__ == "__main__":
    main()
