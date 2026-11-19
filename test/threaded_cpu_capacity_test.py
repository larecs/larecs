"""CPU capacity probe fixtures for constrained threaded test runners."""

import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from threaded_cpu_capacity import available_cpus


class CapacityTest(unittest.TestCase):
    def setUp(self):
        """Create isolated procfs and cgroup mount fixtures."""
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.proc = self.base / "proc"
        (self.proc / "self").mkdir(parents=True)
        self.mount = self.base / "cpu"
        (self.mount / "parent/leaf").mkdir(parents=True)

    def metadata(self, version="cgroup2", root="/", group="/parent/leaf"):
        """Write cgroup metadata.

        Args:
            version: Controller filesystem type.
            root: Mounted controller subtree.
            group: Process membership path.
        """
        controllers = "" if version == "cgroup2" else "cpu,cpuacct"
        (self.proc / "self/cgroup").write_text(f"0:{controllers}:{group}\n")
        options = "rw" if version == "cgroup2" else "rw,cpu,cpuacct"
        mount = str(self.mount).replace(" ", r"\040")
        (self.proc / "self/mountinfo").write_text(
            f"1 0 0:1 {root} {mount} rw - {version} cgroup {options}\n"
        )

    def test_no_procfs(self):
        """Preserve the host capacity when procfs is absent."""
        self.assertEqual(available_cpus(self.base / "missing", 8), 8)

    def test_affinity(self):
        """Use process affinity instead of the host CPU count."""
        with patch(
            "threaded_cpu_capacity.os.sched_getaffinity", return_value={3}, create=True
        ):
            self.assertEqual(available_cpus(self.base / "missing"), 1)

    def test_v2_inherited_fractional_quota(self):
        """Apply the tightest ancestor quota and round down."""
        self.metadata()
        (self.mount / "parent/leaf/cpu.max").write_text("max 100000")
        (self.mount / "parent/cpu.max").write_text("150000 100000")
        (self.mount / "cpu.max").write_text("400000 100000")
        self.assertEqual(available_cpus(self.proc, 16), 1)

    def test_v2_affinity_remains_upper_bound(self):
        """Never exceed process affinity when quotas are larger."""
        self.metadata()
        (self.mount / "cpu.max").write_text("800000 100000")
        self.assertEqual(available_cpus(self.proc, 2), 2)

    def test_v1_inherited_quota(self):
        """Ignore unlimited child quotas and honor the parent limit."""
        self.metadata("cgroup")
        (self.mount / "parent/leaf/cpu.cfs_quota_us").write_text("-1")
        (self.mount / "parent/leaf/cpu.cfs_period_us").write_text("100000")
        (self.mount / "parent/cpu.cfs_quota_us").write_text("200000")
        (self.mount / "parent/cpu.cfs_period_us").write_text("100000")
        self.assertEqual(available_cpus(self.proc, 16), 2)

    def test_namespaced_mount_root_and_escaped_path(self):
        """Map membership through a subtree mount with escaped spaces."""
        self.mount = self.base / "cpu controller"
        (self.mount / "leaf").mkdir(parents=True)
        self.metadata(root="/parent", group="/parent/leaf")
        (self.mount / "cpu.max").write_text("100000 100000")
        self.assertEqual(available_cpus(self.proc, 8), 1)

    def test_namespace_relative_membership(self):
        """Honor the mounted root when namespace paths cannot be joined."""
        self.metadata(root="/parent", group="/")
        (self.mount / "cpu.max").write_text("100000 100000")
        self.assertEqual(available_cpus(self.proc, 8), 1)

    @unittest.skipUnless(hasattr(os, "sched_setaffinity"), "Linux affinity required")
    def test_process_pinned_to_one_cpu(self):
        """Probe a real subprocess restricted to one CPU."""
        cpu = min(os.sched_getaffinity(0))
        result = subprocess.check_output(
            [sys.executable, str(Path(__file__).with_name("threaded_cpu_capacity.py"))],
            preexec_fn=lambda: os.sched_setaffinity(0, {cpu}),
            text=True,
        )
        self.assertEqual(int(result), 1)


if __name__ == "__main__":
    unittest.main()
