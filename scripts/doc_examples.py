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
DOCTEST_SOURCES = ("src/larecs", "docs/src")
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


def source_doctests(root: Path = ROOT) -> set[str]:
    """Inventory first fence locations per source/docstring and doctest name.

    Read authored sources independently of runner output or generated files.
    Ignore prose labels and fences nested in other fenced examples. Repeated
    names share one program within a Markdown file or a Mojo docstring.
    """
    expected = set()
    for directory in DOCTEST_SOURCES:
        base = root / directory
        if not base.is_dir():
            raise ValueError(f"Missing doctest source directory: {directory}")
        for path in sorted(base.rglob("*")):
            if path.suffix not in {".mojo", ".md"} or not path.is_file():
                continue
            if any(part.startswith(".") for part in path.relative_to(base).parts):
                continue
            groups = set()
            scope = 0
            delimiter = None
            fence = None
            for number, line in enumerate(path.read_text().splitlines(), 1):
                if fence:
                    if re.fullmatch(r"[ \t]*" + re.escape(fence[0]) +
                                    "{" + str(len(fence)) + r",}[ \t]*", line):
                        fence = None
                    continue
                opening = re.match(r"^[ \t]*(`{3,}|~{3,})(.*)$", line)
                if opening:
                    fence, info = opening.groups()
                    if re.match(r"mojo(?:[ {]|$)", info):
                        label = re.search(r'\bdoctest\s*=\s*"([^"]+)"', info)
                        if label and (scope, label[1]) not in groups:
                            groups.add((scope, label[1]))
                            expected.add(f"{path.relative_to(root)}:{number}#{label[1]}")
                    continue
                if path.suffix == ".mojo":
                    # Code inside a fence cannot change its owning docstring.
                    quotes = re.finditer(r"\"{3}|'{3}", line)
                    for quote in quotes:
                        if delimiter is None:
                            delimiter = quote[0]
                            scope += 1
                        elif quote[0] == delimiter:
                            delimiter = None
                            scope += 1
    if not expected:
        raise ValueError("No source doctests found")
    return expected


def coverage(output: str, programs: list[Path], root: Path = ROOT,
             *, expected_doctests: set[str] | None = None) -> dict:
    """Require complete source doctest results and distinguish device skips."""
    clean = ANSI.sub("", output)
    sections = re.split(r"(?m)^=== (.+) ===\s*$", clean)
    labels = sections[1::2]
    results = dict(zip(labels, sections[2::2]))
    expected = source_doctests(root) if expected_doctests is None else expected_doctests
    actual = {label for label in labels if re.search(r":\d+#", label)}
    if not expected or expected != actual:
        raise ValueError(f"Doctest coverage differs: missing={sorted(expected - actual)}, "
                         f"unexpected={sorted(actual - expected)}")
    for label in sorted(expected):
        if labels.count(label) != 1:
            raise ValueError(f"Duplicate doctest result: {label}")
        block = results[label]
        if not (re.search(r"(?m)^compile: PASS exit=0\b", block) and
                re.search(r"(?m)^run: PASS exit=0\b", block) and
                re.search(r"(?m)^result: PASS[ \t]*$", block)):
            raise ValueError(f"Incomplete or unsuccessful doctest result: {label}")
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
            "doctests": sorted(expected),
            "actual_device_execution": executed, "hardware_skips": skipped}


def run() -> None:
    """Execute source doctests and examples, retaining device execution evidence."""
    output = ROOT / "output/docs"
    output.mkdir(parents=True, exist_ok=True)
    (output / "examples.json").unlink(missing_ok=True)
    programs = inventory()
    expected_doctests = source_doctests()
    prefix = os.environ["CONDA_PREFIX"]
    # The runner needs Mojo 1.2's runtime, while its child compiler must stay
    # on the project's Mojo 1.0 PATH. Install separately and invoke it directly.
    subprocess.run(["pixi", "install", "--locked", "-e", "doctest-runner"],
                   cwd=ROOT, check=True)
    runner = ROOT / ".pixi/envs/doctest-runner/bin/mogo-tester"
    command = [str(runner), "--precompile", "src/larecs",
               *[arg for path in DOCTEST_SOURCES for arg in ("--doctests", path)]]
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
    report = coverage((output / "examples.log").read_text(), programs,
                      expected_doctests=expected_doctests)
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
