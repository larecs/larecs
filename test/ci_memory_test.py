"""Verify CI memory parsing, command failures, and cancellation forwarding."""

import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "monitor_ci_memory.py"
SPEC = importlib.util.spec_from_file_location("monitor_ci_memory", SCRIPT)
monitor = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(monitor)


class MemoryMonitorTest(unittest.TestCase):
    """Exercise telemetry attribution and subprocess supervision contracts."""

    def test_kernel_units_and_inherited_cgroup_limits(self):
        """Preserve units, unlimited children, parent limits, and OOM counts."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            meminfo = root / "meminfo"
            meminfo.write_text("MemAvailable: 128 kB\noom_kill 3\n")
            self.assertEqual(
                monitor.read_counters(meminfo),
                {"MemAvailable": 128 * 1024, "oom_kill": 3},
            )
            child = root / "job"
            child.mkdir()
            membership = root / "membership"
            membership.write_text("0::/job\n")
            (child / "memory.current").write_text("1024\n")
            (child / "memory.max").write_text("max\n")
            (root / "memory.max").write_text("4096\n")
            (child / "memory.events").write_text("oom 2\noom_kill 1\n")
            groups = monitor.cgroup_memory(root, membership)
            self.assertEqual(groups[0]["memory.current"], 1024)
            self.assertEqual(groups[0]["memory.max"], "max")
            self.assertEqual(groups[0]["memory.events"]["oom_kill"], 1)
            self.assertEqual(groups[1]["memory.max"], 4096)

    def test_process_tree_excludes_unrelated_processes_and_arguments(self):
        """Attribute descendants while keeping command arguments out of logs."""
        processes = (
            "100 1 10 /bin/bash\n"
            "101 100 20 /bin/mojo build test/example.mojo --private=secret\n"
            "102 101 30 /bin/clang\n"
            "103 1 900 /bin/unrelated --private=other\n"
        )
        with patch.object(monitor.subprocess, "check_output", return_value=processes):
            result = monitor.process_memory(100)
        self.assertEqual(result["rss_bytes"], 60 * 1024)
        self.assertEqual(result["process_count"], 3)
        self.assertEqual(result["largest"][0]["name"], "clang")
        self.assertEqual(result["largest"][1]["sources"], ["test/example.mojo"])
        self.assertNotIn("secret", json.dumps(result))
        self.assertNotIn("other", json.dumps(result))

    def test_command_failure_is_preserved_and_samples_are_flushed(self):
        """A failing command must not become a successful CI job."""
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "memory.jsonl"
            result = subprocess.run(
                [sys.executable, str(SCRIPT), "--output", str(output), "--",
                 sys.executable, "-c", "raise SystemExit(7)"],
                capture_output=True, text=True, timeout=10,
            )
            self.assertEqual(result.returncode, 7, result.stderr)
            records = [json.loads(line) for line in output.read_text().splitlines()]
            self.assertEqual(records[0]["event"], "start")
            self.assertEqual(records[-1]["event"], "finish")
            self.assertEqual(records[-1]["returncode"], 7)
            self.assertIn("CI_MEMORY ", result.stdout)

    def test_periodic_samples_capture_live_child_memory(self):
        """Record a live child's memory and retain the sampled high-water mark."""
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "memory.jsonl"
            result = subprocess.run(
                [sys.executable, str(SCRIPT), "--output", str(output),
                 "--interval", "0.05", "--", sys.executable, "-c",
                 "import time; data = bytearray(16 * 1024 * 1024); time.sleep(0.3)"],
                capture_output=True, text=True, timeout=10,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            records = [json.loads(line) for line in output.read_text().splitlines()]
            self.assertTrue(any(item["event"] == "periodic" for item in records))
            self.assertGreater(records[-1]["sampled_peak_tree_rss_bytes"], 0)

    @unittest.skipUnless(os.name == "posix", "CI runner cancellation uses POSIX signals")
    def test_cancellation_reaches_child_and_cannot_report_success(self):
        """Forward SIGTERM and report interruption even if the child exits zero."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            ready = root / "ready"
            delivered = root / "delivered"
            output = root / "memory.jsonl"
            child_code = (
                "import signal, sys, time; from pathlib import Path; "
                "signal.signal(signal.SIGTERM, lambda *_: "
                "(Path(sys.argv[2]).write_text('term'), sys.exit(0))); "
                "Path(sys.argv[1]).write_text('ready'); time.sleep(60)"
            )
            process = subprocess.Popen(
                [sys.executable, str(SCRIPT), "--output", str(output),
                 "--interval", "0.05", "--", sys.executable, "-c",
                 child_code, str(ready), str(delivered)],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            )
            try:
                deadline = time.monotonic() + 10
                while not ready.exists() and time.monotonic() < deadline:
                    if process.poll() is not None:
                        self.fail("monitor exited before child setup")
                    time.sleep(0.01)
                self.assertTrue(ready.exists())
                process.terminate()
                _, stderr = process.communicate(timeout=10)
                self.assertEqual(process.returncode, 128 + signal.SIGTERM, stderr)
                self.assertEqual(delivered.read_text(), "term")
                final = json.loads(output.read_text().splitlines()[-1])
                self.assertEqual(final["signal"], signal.SIGTERM)
            finally:
                if process.poll() is None:
                    process.terminate()
                    process.communicate(timeout=10)


if __name__ == "__main__":
    unittest.main()
