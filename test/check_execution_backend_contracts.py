"""Verify callable, boolean, invalid and runtime backend restrictions."""

from pathlib import Path
import subprocess
import tempfile


def main():
    """Compile public calls and require each unsupported form to fail clearly."""
    root = Path(__file__).resolve().parents[1]
    prelude = """from larecs import ExecutionBackend, World, SystemContext, KernelContext, Filter

def kernel(rows: KernelContext[Filter().include[Int32]()]):
    pass

def main() raises:
    var world = World[Int32]()
    var context = SystemContext(world)
"""
    with tempfile.TemporaryDirectory() as directory:
        for selected in (False, True):
            target = "selection" if selected else "context"
            setup = "    var selection = context._empty_selection()\n" if selected else ""
            cases = {
                "callable_device": (f"    {target}.run[backend=ExecutionBackend.DEVICE](kernel)\n", "Value-taking kernel callables require ExecutionBackend.HOST"),
                "lexical_device": ("    var calls = 0\n    def closure(rows: KernelContext[Filter().include[Int32]()]) {mut calls}:\n        calls += 1\n" + f"    {target}.run[backend=ExecutionBackend.DEVICE](closure)\n", "Value-taking kernel callables require ExecutionBackend.HOST"),
                "boolean": (f"    {target}.run[kernel, backend=True]()\n", "ExecutionBackend"),
                "old_flag": (f"    {target}.run[kernel, on_device=True]()\n", "on_device"),
                "invalid": (f"    {target}.run[kernel, backend=ExecutionBackend(2)]()\n", "Invalid execution backend"),
                "runtime": (f"    var backend = ExecutionBackend.HOST\n    {target}.run[kernel, backend=backend]()\n", "cannot use a dynamic value in a parameter list"),
                "host_callable": (f"    {target}.run[backend=ExecutionBackend.HOST](kernel)\n", None),
            }
            for name, (call, diagnostic) in cases.items():
                source = Path(directory) / "fixture.mojo"
                source.write_text(prelude + setup + call)
                result = subprocess.run(
                    ["mojo", "build", "--emit", "llvm", "-I", str(root / "src"), str(source), "-o", str(Path(directory) / "fixture.ll")],
                    capture_output=True, text=True, timeout=120,
                )
                if diagnostic:
                    if result.returncode == 0 or diagnostic not in result.stderr:
                        raise RuntimeError(f"{name} selected={selected}: expected {diagnostic!r}\n{result.stderr}")
                elif result.returncode:
                    raise RuntimeError(result.stderr)
                print(f"PASS: backend {name} selected={selected}", flush=True)


if __name__ == "__main__":
    main()
