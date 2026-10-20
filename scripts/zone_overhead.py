#!/usr/bin/env python3
"""Time core_smoke without Tracy, with coarse zones, and with fine zones.

Each build runs ``--repetitions`` times, interleaved so that drift affects all
three alike. The table reports the median nanoseconds per operation and the
instrumented builds' ratios to the uninstrumented one. No profiler connects,
so this is the cost an instrumented build pays while nobody captures; a
connected capture adds the cost of transmitting every zone on top.
"""

import argparse
import os
from pathlib import Path
import statistics
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
DRIVER = ROOT / "benchmark/core_smoke.mojo"
BUILDS = {
    "none": [],
    "coarse": ["-DTRACY_ENABLED"],
    "fine": ["-DTRACY_ENABLED", "-DLARECS_FINE_ZONES"],
}


def build(directory, name, flags):
    binary = Path(directory) / name
    prefix = Path(os.environ["CONDA_PREFIX"])
    command = ["mojo", "build", "-I", str(ROOT / "src"), *flags, str(DRIVER), "-o", str(binary)]
    if flags:
        command += ["-Xlinker", f"-L{prefix / 'lib'}", "-Xlinker", "-lmojotracy",
                    "-Xlinker", "-rpath", "-Xlinker", str(prefix / "lib")]
    subprocess.run(command, check=True)
    return binary


def records(binary):
    """``CORE <operation> <rows> <ns per operation>`` lines of one run."""
    output = subprocess.run([str(binary)], check=True, capture_output=True, text=True).stdout
    result = {}
    for line in output.splitlines():
        fields = line.split()
        if len(fields) == 4 and fields[0] == "CORE":
            result[f"{fields[1]}/{fields[2]}"] = float(fields[3])
    if not result:
        raise RuntimeError(f"{binary.name} printed no CORE records")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repetitions", type=int, default=5)
    args = parser.parse_args()
    if args.repetitions < 1:
        parser.error("--repetitions must be positive")
    with tempfile.TemporaryDirectory(prefix="larecs-zones-") as directory:
        binaries = {name: build(directory, name, flags) for name, flags in BUILDS.items()}
        runs = {name: [] for name in BUILDS}
        for _ in range(args.repetitions):
            for name, binary in binaries.items():
                runs[name].append(records(binary))
    cases = sorted(set.intersection(*(set(run) for name in runs for run in runs[name])))
    medians = {name: {case: statistics.median(run[case] for run in runs[name]) for case in cases}
               for name in runs}
    print(f"{'case':32} {'none ns':>10} {'coarse ns':>10} {'fine ns':>10} {'coarse x':>9} {'fine x':>9}")
    for case in cases:
        base = medians["none"][case]
        print(f"{case:32} {base:10.1f} {medians['coarse'][case]:10.1f} {medians['fine'][case]:10.1f} "
              f"{medians['coarse'][case] / base:9.2f} {medians['fine'][case] / base:9.2f}")


if __name__ == "__main__":
    sys.exit(main())
