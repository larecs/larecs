"""Account for and execute documentation programs without an exclusion list."""

import argparse
import json
import os
import platform
import re
import subprocess
import textwrap
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LABEL = re.compile(r'doctest="([\w-]+)"')
EXAMPLE = re.compile(r'{{<\s*example\s+([^>]+)>}}')
ANSI = re.compile(r"\x1b\[[0-9;]*m")


def regions(source: str) -> dict[str, str]:
    """Read balanced, unique, nonempty excerpt regions from a checked program."""
    result = {}
    active = []
    lines = source.splitlines()
    for index, line in enumerate(lines):
        marker = re.fullmatch(r"\s*# (end)?region ([\w-]+)\s*", line)
        if not marker:
            continue
        end, name = marker.groups()
        if end:
            if not active or active[-1][0] != name:
                raise ValueError(f"Unbalanced example region: {name}")
            _, start = active.pop()
            result[name] = textwrap.dedent("\n".join(lines[start:index])).strip()
            if not result[name]:
                raise ValueError(f"Empty example region: {name}")
        else:
            if name in result or any(name == item[0] for item in active):
                raise ValueError(f"Duplicate example region: {name}")
            active.append((name, index + 1))
    if active:
        raise ValueError(f"Unclosed example region: {active[-1][0]}")
    return result


def inventory(root: Path = ROOT) -> list[Path]:
    """Reject unchecked listings and require every referenced program to exist."""
    programs = set((root / "examples/particles").glob("*.mojo"))
    if not programs:
        raise ValueError("Missing particle example programs")
    for page in (root / "docs/src").rglob("*.md"):
        text = page.read_text()
        for fence in re.findall(r"(?m)^```mojo([^\n]*)", text):
            if not LABEL.search(fence):
                raise ValueError(f"Unchecked Mojo listing: {page.relative_to(root)}")
        for match in EXAMPLE.finditer(text):
            attrs = dict(re.findall(r'(\w+)="([^"]*)"', match[1]))
            program = (root / "examples" / attrs["file"]).resolve()
            if not program.is_relative_to((root / "examples").resolve()) or not program.is_file():
                raise ValueError(f"Missing example: {attrs['file']}")
            excerpts = regions(program.read_text())
            if "region" in attrs and attrs["region"] not in excerpts:
                raise ValueError(f"Missing example region: {attrs['file']}:{attrs['region']}")
            programs.add(program)

    paths = sorted({p.resolve() for p in programs})
    for path in paths:
        if not re.search(r"(?m)^def main\(", path.read_text()):
            raise ValueError(f"Missing runnable entry point: {path}")
    return paths


def coverage(output: str, programs: list[Path], root: Path = ROOT) -> dict:
    """Separate explicit accelerator execution evidence from hardware skips."""
    clean = ANSI.sub("", output)
    sections = re.split(r"(?m)^=== (.+) ===\s*$", clean)
    results = dict(zip(sections[1::2], sections[2::2]))
    executed, skipped = [], []
    for program in programs:
        if not program.is_relative_to(root / "examples") or "has_accelerator()" not in program.read_text():
            continue
        relative = str(program.relative_to(root))
        block = results.get(relative, "")
        passed = re.findall(r"(?m)^PASS: actual device .+$", block)
        unavailable = re.findall(r"(?m)^SKIP: .+$", block)
        if len(passed) + len(unavailable) != 1:
            raise ValueError(f"Missing or ambiguous device execution evidence: {relative}")
        executed.extend(f"{relative}: {line}" for line in passed)
        skipped.extend(f"{relative}: {line}" for line in unavailable)
    return {"programs": [str(p.relative_to(root)) for p in programs],
            "doctests": [label for label in results if re.search(r":\d+#", label)],
            "actual_device_execution": executed, "hardware_skips": skipped}


def run() -> None:
    """Execute source doctests and examples, retaining device execution evidence."""
    programs = inventory()
    output = ROOT / "output/docs"
    output.mkdir(parents=True, exist_ok=True)
    (output / "examples.json").unlink(missing_ok=True)
    prefix = os.environ["CONDA_PREFIX"]
    # The runner needs Mojo 1.2's runtime, while its child compiler must stay
    # on the project's Mojo 1.0 PATH. Install separately and invoke it directly.
    subprocess.run(["pixi", "install", "--locked", "-e", "doctest-runner"],
                   cwd=ROOT, check=True)
    runner = ROOT / ".pixi/envs/doctest-runner/bin/mogo-tester"
    command = [str(runner), "--precompile", "src/larecs",
               "--doctests", "src/larecs", "--doctests", "docs/src"]
    for arg in ("-DASSERT=all", "-Xlinker", f"-L{prefix}/lib", "-Xlinker",
                "-lmojotracy", "-DTRACY_ENABLED"):
        command.extend(["--mojo-build-arg", arg])
    command.extend(str(p.relative_to(ROOT)) for p in programs)
    print(f"Running source doctests and {len(programs)} example programs (no exclusions)", flush=True)
    with (output / "examples.log").open("w") as log:
        process = subprocess.Popen(command, cwd=ROOT, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, text=True)
        for line in process.stdout:
            print(line, end="", flush=True)
            log.write(line)
        if process.wait():
            raise SystemExit(process.returncode)
    report = coverage((output / "examples.log").read_text(), programs)
    report["environment"] = {
        "revision": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        "compiler": subprocess.check_output(["mojo", "--version"], text=True).strip(),
        "platform": platform.platform(),
    }
    (output / "examples.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"Device examples: {len(report['actual_device_execution'])} actually executed; "
          f"{len(report['hardware_skips'])} hardware skips", flush=True)
    if os.environ.get("DOCS_REQUIRE_DEVICE") == "1" and report["hardware_skips"]:
        raise ValueError("DOCS_REQUIRE_DEVICE=1 rejects hardware skips")


def contracts() -> None:
    """Reuse diagnostic checks for documented backend, type and spatial errors."""
    for command in (["python", "test/check_execution_backend_contracts.py"],
                    ["python", "test/check_resource_compile_failures.py"],
                    ["bash", "test/check_spatial_filters.sh"]):
        subprocess.run(command, cwd=ROOT, check=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["inventory", "run", "contracts"])
    match parser.parse_args().command:
        case "inventory":
            for program in inventory():
                print(program.relative_to(ROOT))
        case "run":
            run()
        case "contracts":
            contracts()
