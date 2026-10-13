"""Verify public permission and ownership diagnostics with the locked compiler."""

from pathlib import Path
import subprocess
import tempfile


CASES = {
    "atomic_read_only": (
        "var owner = AtomicValue[UInt32](0)\nvar view = owner.read_view()\nview.store(1)",
        "Atomic view is read-only",
    ),
    "guard_read_only": (
        "var owner = Synchronized[UInt32](0)\nvar view = owner.read_view()\n_ = view.try_write()",
        "Synchronized view is read-only",
    ),
    "invalid_scalar": ("var owner = AtomicValue[UInt64](0)", "Atomics require UInt32 or Int32"),
    "invalid_load_order": (
        "var owner = AtomicValue[UInt32](0)\nvar view = owner.read_view()\n_ = view.load[Ordering.RELEASE]()",
        "Invalid atomic load ordering",
    ),
    "invalid_store_order": (
        "var owner = AtomicValue[UInt32](0)\nvar view = owner.write_view()\nview.store[Ordering.ACQUIRE](1)",
        "Invalid atomic store ordering",
    ),
    "invalid_update_order": (
        "var owner = AtomicValue[UInt32](0)\nvar view = owner.write_view()\n_ = view.fetch_add[Ordering.SEQUENTIAL](1)",
        "Invalid atomic update ordering",
    ),
    "owner_copy": ("var owner = Synchronized[UInt32](0)\nvar copy = owner.copy()", "value has no attribute 'copy'"),
    "guard_copy": (
        "var owner = Synchronized[UInt32](0)\nvar view = owner.write_view()\n"
        "var result = view.try_write()\nvar guard = result^.take()\nvar copy = guard.copy()",
        "value has no attribute 'copy'",
    ),
    "reference_after_release": (
        "var owner = Synchronized[UInt32](0)\nvar view = owner.write_view()\n"
        "var result = view.try_write()\nvar guard = result^.take()\nref payload = guard.value()\n"
        "guard^.release()\npayload += 1",
        "use of uninitialized value 'guard'",
    ),
    "read_reference_write": (
        "var owner = Synchronized[UInt32](0)\nvar view = owner.read_view()\n"
        "var result = view.try_read()\nvar guard = result^.take()\nguard.value() = 1",
        "expression must be mutable",
    ),
    "owner_move_with_live_guard": (
        "var owner = Synchronized[UInt32](0)\nvar view = owner.write_view()\n"
        "var result = view.try_write()\nvar guard = result^.take()\n"
        "var moved = owner^\nprint(guard.value())",
        "use of uninitialized value 'owner'",
    ),
    "read_reference_after_release": (
        "var owner = Synchronized[UInt32](0)\nvar view = owner.read_view()\n"
        "var result = view.try_read()\nvar guard = result^.take()\nref payload = guard.value()\n"
        "guard^.release()\nprint(payload)",
        "use of uninitialized value 'guard'",
    ),
    "owner_move_with_live_view": (
        "var owner = AtomicValue[UInt32](0)\nvar view = owner.write_view()\n"
        "var moved = owner^\n_ = view.load()",
        "use of uninitialized value 'owner'",
    ),
}


def main():
    """Build forbidden programs and require their contract diagnostics.

    Raises:
        RuntimeError: If forbidden code compiles or fails for an unrelated reason.
    """
    root = Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix="larecs-sync-contracts-") as directory:
        temporary = Path(directory)
        for name, (body, diagnostic) in CASES.items():
            source = temporary / f"{name}.mojo"
            source.write_text(
                "from larecs.sync import AtomicValue, Synchronized\n"
                "from std.atomic import Ordering\n\n"
                'def main():\n    """Attempts forbidden synchronization access."""\n'
                + "\n".join("    " + line for line in body.splitlines()) + "\n"
            )
            result = subprocess.run(
                ["mojo", "build", "-I", str(root / "src"), str(source), "-o", str(temporary / name)],
                text=True, capture_output=True, timeout=60,
            )
            output = result.stdout + result.stderr
            if result.returncode == 0 or diagnostic not in output:
                raise RuntimeError(f"{name}: expected rejection containing {diagnostic!r}\n{output}")
            print(f"PASS: synchronization contract {name}")


if __name__ == "__main__":
    main()
