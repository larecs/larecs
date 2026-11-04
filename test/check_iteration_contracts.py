"""Check public query/range origins and selection ownership with Mojo."""

from pathlib import Path
import subprocess
import tempfile

PRELUDE = """from larecs import World, SystemContext, Filter, EntitySelection
from larecs.host_storage import HostStorage
from larecs.iteration import LockedEntityRange
"""
CASES = {
    "query_read_only": (
        "def main() raises:\n    var storage = HostStorage[Int]()\n"
        "    _ = storage.add_entity(1)\n"
        "    for row in storage.query[Filter().include[Int]()]():\n"
        "        row.get[Int]() = 2\n",
        "expression must be mutable",
        "print(row.get[Int]())",
    ),
    "selection_noncopyable": (
        "def main() raises:\n    var world = World[Int]()\n"
        "    var context = SystemContext(world)\n"
        "    var selected = context.add_entities(1, count=2)\n"
        "    var copied = selected.copy()\n    copied^.release()\n",
        "copy",
        "var copied = selected^",
    ),
    "query_storage_origin": (
        "def bad(mut storage: HostStorage[Int]) raises -> "
        "LockedEntityRange[ImmOrigin(origin_of(storage._archetypes)), origin_of(storage._locks), Int, row_filter=Filter().include[Int]()]:\n"
        "    var local = HostStorage[Int]()\n"
        "    return local.query[Filter().include[Int]()]()\n\n"
        "def main() raises:\n    var storage = HostStorage[Int]()\n"
        "    var rows = bad(storage)\n    print(len(rows))\n",
        "origin",
        "return storage.query[Filter().include[Int]()]()",
    ),
    "scoped_selection_origin": (
        "def bad(mut world: World[Int]) raises -> EntitySelection[origin_of(world), Int]:\n"
        "    var context = SystemContext(world)\n"
        "    with context.add_entities(1, count=2) as selected:\n        return selected^\n\n"
        "def main() raises:\n    var world = World[Int]()\n"
        "    var selected = bad(world)\n    selected^.release()\n",
        "origin",
        "    return context.add_entities(1, count=2)",
    ),
    "range_storage_origin": (
        "def bad(mut storage: HostStorage[Int]) raises -> "
        "LockedEntityRange[origin_of(storage._archetypes), origin_of(storage._locks), Int, has_ranges=True]:\n"
        "    var local = HostStorage[Int]()\n"
        "    return local.add_entities(1, count=2)\n\n"
        "def main() raises:\n    var storage = HostStorage[Int]()\n"
        "    var rows = bad(storage)\n    print(len(rows))\n",
        "origin",
        "return storage.add_entities(1, count=2)",
    ),
}


def main():
    """Require each forbidden program to fail and its allowed control to build.

    Raises:
        RuntimeError: If an ownership violation compiles or its control fails.
    """
    root = Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix="larecs-iteration-contracts-") as directory:
        temporary = Path(directory)
        for name, (program, diagnostic, replacement) in CASES.items():
            if name == "query_read_only":
                control = program.replace("row.get[Int]() = 2", replacement)
            elif name == "selection_noncopyable":
                control = program.replace("var copied = selected.copy()", replacement)
            elif name == "query_storage_origin":
                control = program.replace("return local.query[Filter().include[Int]()]()", replacement)
            elif name == "scoped_selection_origin":
                control = program.replace("    with context.add_entities(1, count=2) as selected:\n        return selected^", replacement)
            else:
                control = program.replace("return local.add_entities(1, count=2)", replacement)
            for allowed, source in ((False, program), (True, control)):
                path = temporary / f"{name}_{allowed}.mojo"
                path.write_text(PRELUDE + source)
                result = subprocess.run(
                    ["mojo", "build", "-I", str(root / "src"), str(path),
                     "-o", str(temporary / name)],
                    capture_output=True, text=True, timeout=120,
                )
                if allowed and result.returncode or not allowed and (
                    result.returncode == 0 or diagnostic not in result.stderr
                ):
                    raise RuntimeError(f"{name} allowed={allowed}:\n{result.stderr}")
            print(f"PASS: {name}", flush=True)


if __name__ == "__main__":
    main()
