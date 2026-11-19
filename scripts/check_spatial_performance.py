#!/usr/bin/env python3
"""Compare a bounded spatial driver against the PR base on the same machine."""

import argparse
import io
import json
import math
import os
from pathlib import Path
import re
import statistics
import subprocess
import sys
import tarfile
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
BOOTSTRAP = "42234f3b43d4dda58a674842374115f78ec2f08d"
# Broad shared-runner guard: require a repeatable >30% and >500ns slowdown.
RATIO_LIMIT = 1.30
ABSOLUTE_LIMIT_NS = 500


def run(*args, **kwargs):
    """Run an argument-vector command in the repository.

    Args:
        args: Executable and separate command arguments.
        kwargs: Additional subprocess options, including capture and timeout.

    Raises:
        subprocess.CalledProcessError: If the command fails.
        subprocess.TimeoutExpired: If its deadline expires.

    Returns:
        The completed process and any requested captured output."""
    try:
        return subprocess.run(args, cwd=ROOT, check=True, text=True, **kwargs)
    except subprocess.CalledProcessError as error:
        # Captured driver diagnostics must remain visible when CI fails.
        for output in (error.stdout, error.stderr):
            if output:
                print(output, file=sys.stderr, flush=True)
        raise


def expected_cases():
    """Return the complete driver manifest, including both layout controls.

    Returns:
        The set of six-field scenario identifiers."""
    return {
        (rows, group, stride, cadence, ordered, maintenance)
        for rows in (512, 2048)
        for ordered in (0, 1)
        for group, stride, cadence, maintenance in (
            (8, 1, 0, 0), (64, 1, 0, 0), (8, 1024, 0, 0),
            (8, 1, 0, 1), (64, 1, 0, 1), (8, 1024, 0, 1),
            (8, 1, 1, 0), (8, 1, 4, 0),
        )
    }


def parse_report(output):
    """Validate a complete driver report.

    Args:
        output: Captured driver stdout.

    Raises:
        ValueError: If records are missing, malformed, duplicated, or invalid.

    Returns:
        Nanoseconds per frame indexed by scenario identifier."""
    result = {}
    for line in output.splitlines():
        if not line.startswith("SPATIAL "):
            continue
        fields = line.split()
        if len(fields) != 8:
            raise ValueError(f"Malformed timing record: {line}")
        case = tuple(map(int, fields[1:7]))
        ns = float(fields[7])
        if case in result or not math.isfinite(ns) or ns <= 0:
            raise ValueError(f"Invalid timing record: {line}")
        result[case] = ns
    if result.keys() != expected_cases():
        raise ValueError("Spatial driver did not report the complete scenario matrix")
    return result


def regressions(base, head):
    """Require median slowdown and at least four of five paired slowdowns.

    Args:
        base: Five complete baseline reports.
        head: Five complete current reports in corresponding pair order.

    Returns:
        Scenarios with sustained relative and absolute slowdowns."""
    failures = []
    for case in sorted(expected_cases()):
        ratios = [new[case] / old[case] for old, new in zip(base, head)]
        deltas = [new[case] - old[case] for old, new in zip(base, head)]
        sustained = sum(
            ratio > RATIO_LIMIT and delta > ABSOLUTE_LIMIT_NS
            for ratio, delta in zip(ratios, deltas)
        )
        if (statistics.median(ratios) > RATIO_LIMIT
                and statistics.median(deltas) > ABSOLUTE_LIMIT_NS
                and sustained >= 4):
            failures.append(case)
    return failures


def base_revision(explicit):
    """Resolve the actual PR base; local runs compare against committed HEAD.

    Args:
        explicit: Optional command-line baseline override.

    Raises:
        OSError: If an advertised GitHub event file cannot be read.
        ValueError: If the event file is invalid JSON.

    Returns:
        A git revision or full PR base commit ID."""
    if explicit:
        return explicit
    event_path = os.environ.get("GITHUB_EVENT_PATH")
    if event_path:
        event = json.loads(Path(event_path).read_text())
        if "pull_request" in event:
            return event["pull_request"]["base"]["sha"]
    return "HEAD"


def ensure_commit(revision):
    """Resolve local refs, fetching only an unavailable full commit ID.

    Args:
        revision: Requested baseline revision.

    Raises:
        ValueError: If a missing revision is not a full commit ID.
        subprocess.SubprocessError: If fetching fails or times out.

    Returns:
        The resolved full commit ID."""
    resolved = subprocess.run(
        ["git", "rev-parse", "--verify", f"{revision}^{{commit}}"],
        cwd=ROOT, text=True, capture_output=True,
    )
    if resolved.returncode == 0:
        return resolved.stdout.strip()
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError(f"Baseline revision is unavailable: {revision}")
    # Public HTTPS also works in local checkouts whose origin uses SSH.
    run("git", "fetch", "--no-tags", "--depth=1",
        "https://github.com/larecs/larecs.git", revision, timeout=120)
    return revision


def compare(base_binary, head_binary):
    """Warm both binaries, then alternate five paired samples and report medians.

    Args:
        base_binary: Baseline executable path.
        head_binary: Current executable path.

    Raises:
        ValueError: If a report is invalid.
        subprocess.SubprocessError: If execution fails or times out.

    Returns:
        Scenarios that exceed both regression thresholds."""
    def sample(binary):
        """Execute one bounded batch and validate its complete report.

        Args:
            binary: Executable path.

        Raises:
            ValueError: If the report is invalid.
            subprocess.SubprocessError: If execution fails or times out.

        Returns:
            A complete scenario timing report."""
        return parse_report(run(str(binary), capture_output=True, timeout=30).stdout)

    sample(base_binary)
    sample(head_binary)
    base, head = [], []
    for pair in range(5):
        if pair % 2:
            new, old = sample(head_binary), sample(base_binary)
        else:
            old, new = sample(base_binary), sample(head_binary)
        base.append(old)
        head.append(new)
    for case in sorted(expected_cases()):
        old = statistics.median(item[case] for item in base)
        new = statistics.median(item[case] for item in head)
        rows, group, stride, cadence, ordered, maintenance = case
        mode = "maintenance" if maintenance else "gather" if not cadence else "mobile"
        print(f"{mode:11} rows={rows:4} group={group:2} stride={stride:4} "
              f"cadence={cadence} layout={'ordered' if ordered else 'scrambled':9} "
              f"base={old / 1000:8.2f}us head={new / 1000:8.2f}us "
              f"change={(new / old - 1) * 100:+6.1f}%", flush=True)
    print("Current ordered / scrambled frame time (lower is faster):", flush=True)
    for case in sorted(expected_cases()):
        rows, group, stride, cadence, ordered, maintenance = case
        if not ordered or maintenance:
            continue
        control = (rows, group, stride, cadence, 0, maintenance)
        ratio = statistics.median(item[case] / item[control] for item in head)
        print(f"  rows={rows} group={group} stride={stride} cadence={cadence}: "
              f"{ratio:.2f}x", flush=True)
    return regressions(base, head)


def main():
    """Build the current driver against both libraries and enforce the guard.

    Raises:
        SystemExit: If arguments are invalid or regressions recur.
        ValueError: If the baseline or a timing report is invalid.
        OSError: If source extraction or file operations fail.
        subprocess.SubprocessError: If git, compilation, or execution fails."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", help="Baseline git revision (default: PR base or HEAD)")
    args = parser.parse_args()
    started = time.monotonic()
    revision = ensure_commit(base_revision(args.base))
    has_spatial = subprocess.run(
        ["git", "cat-file", "-e", f"{revision}:src/larecs/spatial.mojo"],
        cwd=ROOT, capture_output=True,
    ).returncode == 0
    if not has_spatial:
        print("Base predates spatial API; using first implementation as bootstrap.", flush=True)
        revision = ensure_commit(BOOTSTRAP)
    print(f"Spatial baseline: {revision}; 512/2048 rows, 32 cases, five paired samples",
          flush=True)
    with tempfile.TemporaryDirectory(prefix="larecs-spatial-") as directory:
        scratch = Path(directory)
        archive = subprocess.run(
            ["git", "archive", revision, "src"], cwd=ROOT,
            check=True, capture_output=True,
        ).stdout
        # Extract only regular source files beneath src, never links or traversal.
        with tarfile.open(fileobj=io.BytesIO(archive)) as source:
            for member in source:
                path = Path(member.name)
                if (not member.isfile() or not path.parts or path.parts[0] != "src"
                        or ".." in path.parts or path.is_absolute()):
                    continue
                target = scratch / path
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(source.extractfile(member).read())
        binaries = [scratch / "base", scratch / "head"]
        for source, binary in zip((scratch / "src", ROOT / "src"), binaries):
            before = time.monotonic()
            run("mojo", "build", "-I", str(source),
                str(ROOT / "benchmark/spatial_smoke.mojo"), "-o", str(binary), timeout=180)
            print(f"Compiled {binary.name} in {time.monotonic() - before:.1f}s", flush=True)
        failures = compare(*binaries)
        if failures:
            print("Possible regression; repeating all pairs to reject transient load.", flush=True)
            failures = sorted(set(failures) & set(compare(*binaries)))
        if failures:
            raise SystemExit(f"Spatial performance regression (>30% and >500ns): {failures}")
    print(f"Spatial performance check passed in {time.monotonic() - started:.1f}s", flush=True)


if __name__ == "__main__":
    main()
