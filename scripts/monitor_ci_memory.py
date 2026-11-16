"""Run a CI command while streaming memory evidence to the log and JSONL.

RSS samples include shared pages and may miss peaks between samples. Linux
cgroup peaks cover the cgroup's lifetime; compare OOM counters with the initial
sample. Console samples remain available if a runner dies before artifact upload.
"""

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys


def read_counters(path: Path) -> dict[str, int]:
    """Read whitespace-separated kernel counters, converting kB to bytes.

    Args:
        path: A meminfo, vmstat, or cgroup events file.

    Returns:
        Available numeric counters; an empty mapping if inaccessible.
    """
    try:
        result = {}
        for line in path.read_text().splitlines():
            parts = line.split()
            if len(parts) >= 2 and parts[1].isdigit():
                value = int(parts[1])
                if len(parts) >= 3 and parts[2] == "kB":
                    value *= 1024
                result[parts[0].rstrip(":")] = value
        return result
    except OSError:
        return {}


def cgroup_memory(
    root: Path = Path("/sys/fs/cgroup"),
    membership: Path = Path("/proc/self/cgroup"),
) -> list[dict]:
    """Read cgroup v2 memory usage, limits, and events at every ancestor.

    Args:
        root: The cgroup v2 filesystem mount.
        membership: The current process's cgroup membership file.

    Returns:
        Accessible cgroups, including ancestor limits inherited by the job.
    """
    root = root.resolve()
    try:
        entry = next(
            line[3:]
            for line in membership.read_text().splitlines()
            if line.startswith("0::")
        )
    except (OSError, StopIteration):
        return []
    current = (root / entry.lstrip("/")).resolve()
    if not current.is_relative_to(root):
        return []
    groups = []
    while True:
        group = {"path": str(current)}
        for name in ("memory.current", "memory.peak", "memory.max", "memory.swap.current"):
            try:
                value = (current / name).read_text().strip()
                group[name] = int(value) if value.isdigit() else value
            except OSError:
                pass
        events = read_counters(current / "memory.events")
        if events:
            group["memory.events"] = events
        if len(group) > 1:
            groups.append(group)
        if current == root:
            return groups
        current = current.parent


def host_memory() -> dict:
    """Read host memory and system OOM counters without privileged access.

    Returns:
        Linux byte counters, or macOS VM page counts and physical memory.
    """
    if sys.platform == "linux":
        counters = read_counters(Path("/proc/meminfo"))
        result = {
            key: counters[key]
            for key in ("MemTotal", "MemAvailable", "SwapTotal", "SwapFree")
            if key in counters
        }
        result["oom_kill"] = read_counters(Path("/proc/vmstat")).get("oom_kill")
        return result
    if sys.platform == "darwin":
        total = subprocess.check_output(["sysctl", "-n", "hw.memsize"], text=True)
        vm = subprocess.check_output(["vm_stat"], text=True)
        return {"total_bytes": int(total), "vm_stat": vm.strip()}
    return {}


def process_memory(root_pid: int) -> dict:
    """Sample the command's descendant RSS without logging command arguments.

    Args:
        root_pid: The supervised command's process ID.

    Returns:
        Aggregate RSS and the ten largest descendants with Mojo source labels.
        RSS includes shared pages and is not a unique-memory measurement.
    """
    output = subprocess.check_output(
        ["ps", "-axo", "pid=,ppid=,rss=,args="], text=True
    )
    processes = {}
    for line in output.splitlines():
        fields = line.split(None, 3)
        if len(fields) != 4:
            continue
        pid, parent, rss = map(int, fields[:3])
        command = fields[3]
        # Emit only the executable name and Mojo source paths, never argv.
        processes[pid] = {
            "pid": pid,
            "ppid": parent,
            "rss_bytes": rss * 1024,
            "name": Path(command.split()[0]).name,
            "sources": re.findall(r"(?:^|\s)([\w./-]+\.mojo)(?=\s|$)", command),
        }
    selected = {root_pid}
    while True:
        descendants = {
            pid for pid, item in processes.items() if item["ppid"] in selected
        }
        expanded = selected | descendants
        if expanded == selected:
            break
        selected = expanded
    rows = [item for pid, item in processes.items() if pid in selected]
    return {
        "rss_bytes": sum(item["rss_bytes"] for item in rows),
        "process_count": len(rows),
        "largest": sorted(rows, key=lambda item: item["rss_bytes"], reverse=True)[:10],
    }


def main() -> int:
    """Supervise a command, preserving its exit status and forwarding signals.

    Returns:
        The command's exit status, or 128 plus its terminating signal.
    """
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--interval", type=float, default=15)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command or args.interval <= 0:
        parser.error("a command and positive sampling interval are required")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    received = None
    peak_rss = 0
    child = subprocess.Popen(command, start_new_session=True)

    def forward(signum: int, _frame: object) -> None:
        """Record and forward the runner's signal to the entire command group.

        Args:
            signum: The received signal number.
            _frame: The interrupted interpreter frame.
        """
        nonlocal received
        received = signum
        try:
            os.killpg(child.pid, signum)
        except ProcessLookupError:
            pass

    for signum in (signal.SIGTERM, signal.SIGINT):
        signal.signal(signum, forward)
    with args.output.open("w", buffering=1) as log:

        def sample(event: str) -> None:
            """Write one best-effort sample without changing command success.

            Args:
                event: Whether this is a start, periodic, or final sample.
            """
            nonlocal peak_rss
            record = {
                "timestamp": datetime.now(timezone.utc).isoformat(),
                "event": event,
                "signal": received,
                "returncode": child.poll(),
            }
            try:
                record["host"] = host_memory()
                record["cgroups"] = cgroup_memory()
                record["processes"] = process_memory(child.pid)
                peak_rss = max(peak_rss, record["processes"]["rss_bytes"])
            except (OSError, ValueError, subprocess.SubprocessError) as error:
                record["sampling_error"] = str(error)
            record["sampled_peak_tree_rss_bytes"] = peak_rss
            encoded = json.dumps(record, separators=(",", ":"))
            log.write(encoded + "\n")
            print("CI_MEMORY " + encoded, flush=True)

        sample("start")
        while True:
            try:
                child.wait(timeout=args.interval)
                break
            except subprocess.TimeoutExpired:
                sample("periodic")
        sample("finish")
    if received:
        return 128 + received
    return child.returncode if child.returncode >= 0 else 128 - child.returncode


if __name__ == "__main__":
    sys.exit(main())
