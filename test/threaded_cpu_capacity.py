"""Report CPUs available to the threaded overlap test, including Linux quotas."""

import os
from pathlib import Path
import re


def _mount_path(value: str) -> Path:
    """Decode octal escapes used by Linux mountinfo paths.

    Args:
        value: Encoded path field.

    Returns:
        Decoded filesystem path.
    """
    return Path(re.sub(r"\\([0-7]{3})", lambda m: chr(int(m[1], 8)), value))


def available_cpus(proc: Path = Path("/proc"), cpu_count: int | None = None) -> int:
    """Bound affinity by every visible ancestor CPU quota (cgroup v1 or v2).

    Fractional quotas round down conservatively because this test requires two
    CPUs of capacity. Missing quota files mean that controller imposes no bound.

    Args:
        proc: Procfs root, replaceable by fixtures.
        cpu_count: Optional affinity count override for fixtures.

    Raises:
        OSError: If existing capacity metadata cannot be read.
        ValueError: If capacity metadata is malformed.

    Returns:
        Available CPU capacity, rounded down with a minimum of one.
    """
    if cpu_count is None:
        cpu_count = (
            len(os.sched_getaffinity(0))
            if hasattr(os, "sched_getaffinity")
            else os.cpu_count() or 1
        )
    capacity = max(1, cpu_count)
    try:
        memberships = (proc / "self/cgroup").read_text().splitlines()
        mounts = (proc / "self/mountinfo").read_text().splitlines()
    except FileNotFoundError:
        return capacity  # Non-Linux hosts have no procfs cgroup metadata.
    for entry in mounts:
        fields, filesystem = entry.split(" - ", 1)
        mount_fields = fields.split()
        fs_fields = filesystem.split()
        version = fs_fields[0]
        if version not in ("cgroup", "cgroup2"):
            continue
        if version == "cgroup" and "cpu" not in fs_fields[2].split(","):
            continue
        root, mount = _mount_path(mount_fields[3]), _mount_path(mount_fields[4])
        for membership in memberships:
            _, controllers, name = membership.split(":", 2)
            if (version == "cgroup2" and controllers) or (
                version == "cgroup" and "cpu" not in controllers.split(",")
            ):
                continue
            group = Path(name)
            # A cgroup namespace can report membership relative to its root
            # while mountinfo exposes the host subtree. Its mount-root quota
            # still bounds this process even when those paths cannot be joined.
            directory = (
                mount / group.relative_to(root)
                if group.is_relative_to(root)
                else mount
            )
            while True:
                try:
                    if version == "cgroup2":
                        quota, period = (directory / "cpu.max").read_text().split()
                        limit = None if quota == "max" else int(quota)
                    else:
                        limit = int((directory / "cpu.cfs_quota_us").read_text())
                        period = (directory / "cpu.cfs_period_us").read_text()
                    if limit is not None and limit >= 0:
                        capacity = min(capacity, max(1, limit // int(period)))
                except FileNotFoundError:
                    pass
                if directory == mount:
                    break
                directory = directory.parent
    return capacity


if __name__ == "__main__":
    print(available_cpus())
