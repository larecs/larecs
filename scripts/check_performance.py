#!/usr/bin/env python3
"""Gate bounded CPU workloads against a same-runner PR baseline."""

import argparse
from dataclasses import dataclass
import hashlib
import io
import json
import math
import os
from pathlib import Path
import platform
import re
import statistics
import subprocess
import sys
import tarfile
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
BOOTSTRAP = "42234f3b43d4dda58a674842374115f78ec2f08d"
PAIRS = 5
RATIO_LIMIT = 1.30
ABSOLUTE_LIMIT_NS = 500


@dataclass(frozen=True)
class Suite:
    """A focused driver and its exact timing-record manifest."""

    name: str
    driver: str
    prefix: str
    cases: frozenset


SUITES = {
    "core": Suite("core", "benchmark/core_smoke.mojo", "CORE", frozenset(
        f"{operation}/{rows}"
        for rows in (512, 2048)
        for operation in ("access", "query", "execute", "selected_execute",
                          "selected_mutation", "batch_cycle")
    )),
    "spatial": Suite("spatial", "benchmark/spatial_smoke.mojo", "SPATIAL",
                     frozenset("/".join(map(str, case))
                               for case in (
                                   (rows, group, stride, cadence, ordered, maintenance)
                                   for rows in (512, 2048) for ordered in (0, 1)
                                   for group, stride, cadence, maintenance in (
                                       (8, 1, 0, 0), (64, 1, 0, 0), (8, 1024, 0, 0),
                                       (8, 1, 0, 1), (64, 1, 0, 1), (8, 1024, 0, 1),
                                       (8, 1, 1, 0), (8, 1, 4, 0),
                                   )
                               ))),
}


def parse_report(output, suite):
    """Validate complete, unique, positive finite nanosecond records.

    Args:
        output: Driver stdout.
        suite: Expected record prefix and manifest.

    Raises:
        ValueError: If any record is invalid or the manifest differs.

    Returns:
        Nanoseconds per operation indexed by stable scenario ID.
    """
    result = {}
    for line in output.splitlines():
        fields = line.split()
        if not fields or fields[0] != suite.prefix:
            continue
        if len(fields) < 3:
            raise ValueError(f"Malformed {suite.name} record: {line}")
        case = "/".join(fields[1:-1])
        ns = float(fields[-1])
        if case not in suite.cases or case in result or not math.isfinite(ns) or ns <= 0:
            raise ValueError(f"Invalid {suite.name} record: {line}")
        result[case] = ns
    if result.keys() != suite.cases:
        raise ValueError(f"Incomplete {suite.name} report: missing {sorted(suite.cases - result.keys())}")
    return result


def analyze(base, head, cases):
    """Calculate paired evidence and sustained regression candidates.

    Args:
        base: Five validated baseline reports in pair order.
        head: Five validated current reports in corresponding pair order.
        cases: Complete scenario manifest.

    Raises:
        ValueError: If sample counts or manifests differ.

    Returns:
        Per-case medians, raw paired samples, and candidate flags.
    """
    if len(base) != PAIRS or len(head) != PAIRS:
        raise ValueError("Performance comparison requires exactly five pairs")
    if any(report.keys() != cases for report in base + head):
        raise ValueError("Performance sample manifests differ")
    result = {}
    for case in sorted(cases):
        old = [sample[case] for sample in base]
        new = [sample[case] for sample in head]
        ratios = [h / b for b, h in zip(old, new)]
        deltas = [h - b for b, h in zip(old, new)]
        if not all(math.isfinite(value) for value in ratios + deltas):
            raise ValueError(f"Nonfinite paired evidence: {case}")
        sustained = sum(r > RATIO_LIMIT and d > ABSOLUTE_LIMIT_NS
                        for r, d in zip(ratios, deltas))
        result[case] = {
            "base_ns": old, "head_ns": new,
            "base_median_ns": statistics.median(old),
            "head_median_ns": statistics.median(new),
            "paired_ratio_median": statistics.median(ratios),
            "paired_delta_median_ns": statistics.median(deltas),
            "slow_pairs": sustained,
            "candidate": sustained >= 4 and statistics.median(ratios) > RATIO_LIMIT
            and statistics.median(deltas) > ABSOLUTE_LIMIT_NS,
        }
    return result


def base_revision(explicit):
    """Choose an override, PR base, previous push commit, or local HEAD.

    Args:
        explicit: Optional CLI revision.

    Raises:
        OSError: If the event cannot be read.
        ValueError: If event JSON is invalid.

    Returns:
        Requested Git baseline revision.
    """
    if explicit:
        return explicit
    event_path = os.environ.get("GITHUB_EVENT_PATH")
    if event_path:
        event = json.loads(Path(event_path).read_text())
        if "pull_request" in event:
            return event["pull_request"]["base"]["sha"]
        previous = event.get("before")
        if previous and previous != "0" * 40:
            return previous
    return "HEAD"


class Runner:
    """Run bounded sequential commands and preserve diagnostics on failure."""

    def __init__(self, output):
        """Initialize a per-run command log.

        Args:
            output: Directory for command logs and final reports.
        """
        self.output = Path(tempfile.mkdtemp(prefix="run-", dir=output))
        self.sequence = 0

    def run(self, *args, timeout=30):
        """Execute one command with captured output and an explicit deadline.

        Args:
            args: Executable and individual arguments.
            timeout: Maximum command runtime in seconds.

        Raises:
            OSError: If the executable cannot start.
            subprocess.SubprocessError: If the command fails or times out.

        Returns:
            Captured stdout on success.
        """
        self.sequence += 1
        log = self.output / f"command-{self.sequence:03}.log"
        log.write_text(json.dumps(list(map(str, args))) + "\n")
        try:
            completed = subprocess.run(list(map(str, args)), cwd=ROOT, text=True,
                                       capture_output=True, timeout=timeout, check=True)
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
            with log.open("a") as target:
                for content in (error.stdout, error.stderr):
                    if content:
                        text = content.decode(errors="replace") if isinstance(content, bytes) else content
                        target.write(text)
                        print(text, file=sys.stderr, flush=True)
            raise
        with log.open("a") as target:
            target.write(completed.stdout)
            target.write(completed.stderr)
        return completed.stdout


def ensure_commit(revision, runner):
    """Resolve local refs, fetching only an unavailable full commit SHA.

    Args:
        revision: Requested baseline revision.
        runner: Logger for any necessary fetch.

    Raises:
        ValueError: If an unavailable revision is not a full SHA.
        subprocess.SubprocessError: If resolution or fetch fails.

    Returns:
        Resolved full commit SHA.
    """
    resolved = subprocess.run(
        ["git", "rev-parse", "--verify", f"{revision}^{{commit}}"],
        cwd=ROOT, text=True, capture_output=True, timeout=30,
    )
    if resolved.returncode == 0:
        return resolved.stdout.strip()
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError(f"Baseline revision is unavailable: {revision}")
    runner.run("git", "fetch", "--no-tags", "--depth=1",
               "https://github.com/larecs/larecs.git", revision, timeout=120)
    return runner.run("git", "rev-parse", "--verify", f"{revision}^{{commit}}").strip()


def extract_sources(revision, destination, runner):
    """Export regular baseline sources without links or path traversal.

    Args:
        revision: Resolved Git commit SHA.
        destination: Temporary source root.
        runner: Command runner used to capture archive diagnostics.

    Raises:
        OSError: If extraction fails.
        subprocess.SubprocessError: If git archive fails.
        tarfile.TarError: If the archive is invalid.
    """
    # Text subprocess capture is unsuitable for tar bytes; record stderr separately.
    archive = subprocess.run(["git", "archive", revision, "src"], cwd=ROOT,
                             capture_output=True, timeout=30)
    (runner.output / "archive.log").write_bytes(archive.stderr)
    archive.check_returncode()
    with tarfile.open(fileobj=io.BytesIO(archive.stdout)) as source:
        for member in source:
            path = Path(member.name)
            if (not member.isfile() or path.is_absolute() or ".." in path.parts
                    or not path.parts or path.parts[0] != "src"):
                continue
            target = destination / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(source.extractfile(member).read())


def sample_round(suite, binaries, runner):
    """Warm both binaries and collect five alternating paired samples.

    Args:
        suite: Driver manifest.
        binaries: Baseline and current executable paths.
        runner: Bounded command runner.

    Raises:
        ValueError: If a timing report is invalid.
        subprocess.SubprocessError: If execution fails or times out.

    Returns:
        Validated per-case paired evidence.
    """
    def sample(binary):
        """Execute and validate a complete driver batch.

        Args:
            binary: Executable path.

        Returns:
            Complete nanosecond report.

        Raises:
            ValueError: If records are invalid.
            subprocess.SubprocessError: If execution fails.
        """
        return parse_report(runner.run(binary), suite)

    for binary in binaries:
        sample(binary)
    base, head = [], []
    for pair in range(PAIRS):
        if pair % 2:
            new, old = sample(binaries[1]), sample(binaries[0])
        else:
            old, new = sample(binaries[0]), sample(binaries[1])
        base.append(old)
        head.append(new)
    return analyze(base, head, suite.cases)


def compare_suite(suite, binaries, runner, evidence):
    """Confirm candidates with a fresh round, retaining both sets of evidence.

    Args:
        suite: Workload and manifest.
        binaries: Baseline and current executables.
        runner: Sequential process runner.
        evidence: Mutable per-suite report, including partial failure evidence.

    Raises:
        ValueError: If a driver report is invalid.
        subprocess.SubprocessError: If execution fails.

    Returns:
        Scenario IDs confirmed as regressions in both rounds.
    """
    first = sample_round(suite, binaries, runner)
    evidence["rounds"].append(first)
    candidates = {case for case, data in first.items() if data["candidate"]}
    if not candidates:
        return []
    print(f"{suite.name}: confirming {len(candidates)} candidate regressions", flush=True)
    second = sample_round(suite, binaries, runner)
    evidence["rounds"].append(second)
    return sorted(candidates & {case for case, data in second.items() if data["candidate"]})


def markdown(report):
    """Render reviewable timings, policy, provenance, and failures.

    Args:
        report: Structured report, including incomplete/failed runs.

    Returns:
        Markdown job summary.
    """
    lines = ["## PR performance comparison", "", f"Status: **{report['status']}**",
             f"Requested base: `{report.get('requested_base', 'unresolved')}`",
             f"Current checkout: `{report.get('head_sha', 'unresolved')}`",
             f"Compiler: `{report.get('compiler', 'unresolved')}`",
             f"Host: `{report.get('platform', '')}`; CPU: `{report.get('cpu', '')}`",
             "", "Gate: >30% AND >500 ns in at least 4/5 pairs and paired medians,",
             "confirmed in a fresh round. Times below are per operation/frame.", ""]
    for name, suite in report["suites"].items():
        lines += [f"### {name}", "", f"Effective base: `{suite['base_sha']}`",
                  f"Driver SHA-256: `{suite['driver_sha256']}`",
                  f"Compile: {suite['compile_seconds']}; sampling: {suite.get('execution_seconds', 0):.2f}s", "",
                  "| Case | Base ns | Current ns | Paired change | Slow pairs | Result |",
                  "| --- | ---: | ---: | ---: | ---: | --- |"]
        if not suite["rounds"]:
            lines += ["| No completed samples | | | | | error |"]
        for case, data in (suite["rounds"][0] if suite["rounds"] else {}).items():
            result = ("REGRESSION" if case in suite["regressions"] else
                      "transient candidate" if data["candidate"] else "pass")
            lines.append(f"| {case} | {data['base_median_ns']:.1f} | {data['head_median_ns']:.1f} | "
                         f"{(data['paired_ratio_median'] - 1) * 100:+.1f}% | {data['slow_pairs']}/5 | {result} |")
        if len(suite["rounds"]) > 1:
            lines += ["", "Confirmation samples are retained in report.json."]
        lines.append("")
    if report.get("error"):
        lines += ["### Error", "", "```", report["error"], "```", ""]
    lines += [f"Total check: {report['elapsed_seconds']:.2f}s", ""]
    return "\n".join(lines)


def execute(args, report, runner):
    """Build each driver against both libraries and collect sequential evidence.

    Args:
        args: Parsed CLI options.
        report: Mutable report preserved on success and failure.
        runner: Command logger.

    Raises:
        ValueError: If baselines or records are invalid.
        OSError: If extraction or command execution fails.
        subprocess.SubprocessError: If build or execution fails.
    """
    report["requested_base"] = base_revision(args.base)
    revision = ensure_commit(report["requested_base"], runner)
    report["base_sha"] = revision
    report["head_sha"] = runner.run("git", "rev-parse", "HEAD").strip()
    report["dirty"] = bool(runner.run("git", "status", "--porcelain").strip())
    report["compiler"] = runner.run("mojo", "--version").strip()
    if sys.platform == "darwin":
        report["cpu"] = runner.run("sysctl", "-n", "machdep.cpu.brand_string").strip()
    elif Path("/proc/cpuinfo").exists():
        report["cpu"] = next((line.split(":", 1)[1].strip() for line in
                              Path("/proc/cpuinfo").read_text().splitlines()
                              if line.startswith("model name")), platform.machine())
    with tempfile.TemporaryDirectory(prefix="larecs-performance-") as directory:
        scratch = Path(directory)
        for name in args.suite or SUITES:
            suite = SUITES[name]
            effective = revision
            if name == "spatial" and subprocess.run(
                    ["git", "cat-file", "-e", f"{revision}:src/larecs/spatial.mojo"],
                    cwd=ROOT, capture_output=True, timeout=30).returncode:
                effective = ensure_commit(BOOTSTRAP, runner)
                print(f"Spatial API absent at requested base; bootstrap: {effective}", flush=True)
            evidence = {"base_sha": effective, "driver": suite.driver,
                        "driver_sha256": hashlib.sha256((ROOT / suite.driver).read_bytes()).hexdigest(),
                        "compile_seconds": {}, "rounds": [], "regressions": []}
            report["suites"][name] = evidence
            source_root = scratch / effective
            if not source_root.exists():
                extract_sources(effective, source_root, runner)
            binaries = [scratch / f"{name}-base", scratch / f"{name}-head"]
            print(f"{name}: baseline {effective}, {len(suite.cases)} cases", flush=True)
            for label, source, binary in zip(("base", "head"),
                                            (source_root / "src", ROOT / "src"), binaries):
                before = time.monotonic()
                runner.run("mojo", "build", "-I", source, ROOT / suite.driver,
                           "-o", binary, timeout=180)
                evidence["compile_seconds"][label] = time.monotonic() - before
            before = time.monotonic()
            try:
                evidence["regressions"] = compare_suite(suite, binaries, runner, evidence)
            finally:
                evidence["execution_seconds"] = time.monotonic() - before
            for case, data in evidence["rounds"][0].items():
                print(f"{name}/{case}: {data['base_median_ns']:.1f} -> "
                      f"{data['head_median_ns']:.1f}ns "
                      f"({(data['paired_ratio_median'] - 1) * 100:+.1f}%)", flush=True)
    report["status"] = "regression" if any(s["regressions"] for s in report["suites"].values()) else "passed"


def main(argv=None):
    """Run the gate and always emit reports for completed or failed checks.

    Args:
        argv: Optional CLI arguments, defaulting to process arguments.

    Returns:
        Zero on success, one for regressions or invalid/failed comparisons.
    """
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", help="Baseline revision (default: PR base, previous push, or HEAD)")
    parser.add_argument("--suite", action="append", choices=SUITES,
                        help="Run only this suite; repeat to select more (default: all)")
    parser.add_argument("--output", type=Path, default=ROOT / "output/performance",
                        help="Report/log directory (default: output/performance)")
    args = parser.parse_args(argv)
    args.output.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    report = {"schema_version": 1, "status": "error", "platform": platform.platform(),
              "cpu": platform.processor(), "thresholds": {"ratio": RATIO_LIMIT,
              "absolute_ns": ABSOLUTE_LIMIT_NS, "pairs": PAIRS, "required_slow_pairs": 4},
              "suites": {}, "run_url": None}
    if os.environ.get("GITHUB_RUN_ID"):
        report["run_url"] = (f"{os.environ.get('GITHUB_SERVER_URL', 'https://github.com')}/"
                             f"{os.environ.get('GITHUB_REPOSITORY')}/actions/runs/{os.environ['GITHUB_RUN_ID']}")
    runner = Runner(args.output)
    report["log_directory"] = str(runner.output.relative_to(args.output))
    try:
        execute(args, report, runner)
    except (OSError, ValueError, subprocess.SubprocessError, tarfile.TarError) as error:
        report["error"] = str(error)
        print(f"Performance check failed: {error}", file=sys.stderr, flush=True)
    finally:
        report["elapsed_seconds"] = time.monotonic() - started
        (args.output / "report.json").write_text(json.dumps(report, indent=2, allow_nan=False) + "\n")
        summary = markdown(report)
        (args.output / "summary.md").write_text(summary)
        if os.environ.get("GITHUB_STEP_SUMMARY"):
            with Path(os.environ["GITHUB_STEP_SUMMARY"]).open("a") as target:
                target.write(summary)
    print(f"Performance check {report['status']} in {report['elapsed_seconds']:.1f}s; reports: {args.output}", flush=True)
    return 0 if report["status"] == "passed" else 1


if __name__ == "__main__":
    sys.exit(main())
