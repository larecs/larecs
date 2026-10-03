"""Test paired regression policy, provenance, diagnostics, and failed runs."""

from contextlib import redirect_stderr, redirect_stdout
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch, Mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import check_performance as check


class PerformanceTest(unittest.TestCase):
    """Exercise the gate using deterministic timings rather than host performance."""

    suite = check.Suite("fixture", "fixture.mojo", "FIXTURE", frozenset({"a", "b"}))

    def samples(self, values, ns=10_000):
        """Build paired samples with controlled slowdowns.

        Args:
            values: Relative times for the five pairs.
            ns: Baseline operation duration.

        Returns:
            Complete timing reports.
        """
        return [dict.fromkeys(self.suite.cases, ns * value) for value in values]

    def analysis(self, values, ns=10_000):
        """Analyze five fixture pairs against a constant baseline.

        Args:
            values: Relative current timings.
            ns: Baseline duration.

        Returns:
            Per-case paired evidence.
        """
        return check.analyze(self.samples([1] * 5, ns), self.samples(values, ns), self.suite.cases)

    def test_repeatability_and_outliers(self):
        """Four slow pairs fail; three fail to establish a sustained slowdown."""
        self.assertTrue(self.analysis([1.5] * 4 + [0.8])["a"]["candidate"])
        self.assertFalse(self.analysis([1.5] * 3 + [1, 1])["a"]["candidate"])
        self.assertFalse(self.analysis([0.5] * 5)["a"]["candidate"])

    def test_strict_relative_and_absolute_thresholds(self):
        """Both strict boundaries must be crossed in the same four pairs."""
        self.assertFalse(self.analysis([1.30] * 5)["a"]["candidate"])
        self.assertFalse(self.analysis([2] * 5, 500)["a"]["candidate"])
        self.assertFalse(self.analysis([2] * 5, 400)["a"]["candidate"])
        self.assertTrue(self.analysis([2] * 5, 501)["a"]["candidate"])

    def test_samples_and_manifests_are_complete(self):
        """Partial sample sets and differing manifests cannot pass the gate."""
        base = self.samples([1] * 5)
        for head in (base[:-1], [{"a": 10_000}] * 5):
            with self.assertRaises(ValueError):
                check.analyze(base, head, self.suite.cases)

    def test_parser_rejects_invalid_records(self):
        """Reject missing, unexpected, malformed, duplicate, and invalid timers."""
        valid = "diagnostic\nFIXTURE a 1000\nFIXTURE b 2000\n"
        self.assertEqual(check.parse_report(valid, self.suite), {"a": 1000, "b": 2000})
        for invalid in ("", valid + "FIXTURE a 1", valid + "FIXTURE c 1",
                        valid + "FIXTURE", valid.replace("1000", "nan"),
                        valid.replace("1000", "inf"), valid.replace("1000", "-1"),
                        valid.replace("1000", "0"), valid.replace("1000", "oops"),
                        valid.replace("a 1000", "a extra 1000")):
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                check.parse_report(invalid, self.suite)

    def test_nonfinite_derived_evidence_fails(self):
        """Finite records that overflow paired arithmetic cannot produce a pass."""
        with self.assertRaises(ValueError):
            check.analyze([dict.fromkeys(self.suite.cases, 1e-300)] * 5,
                          [dict.fromkeys(self.suite.cases, 1e300)] * 5, self.suite.cases)

    def test_warmup_and_alternating_pair_order(self):
        """Warmup is validated but excluded from the five recorded pairs."""
        runner = Mock()
        runner.run.return_value = "FIXTURE a 1000\nFIXTURE b 1000"
        result = check.sample_round(self.suite, ["base", "head"], runner)
        self.assertEqual([call.args[0] for call in runner.run.call_args_list],
                         ["base", "head", "base", "head", "head", "base",
                          "base", "head", "head", "base", "base", "head"])
        self.assertEqual(result["a"]["base_ns"], [1000] * 5)

    def test_confirmation_keeps_only_repeated_cases(self):
        """Retain rejected candidates and fail only intersections across rounds."""
        first = self.analysis([1.5] * 5)
        second = self.analysis([1] * 5)
        second["b"]["candidate"] = True
        evidence = {"rounds": []}
        with patch.object(check, "sample_round", side_effect=[first, second]) as sample:
            with redirect_stdout(io.StringIO()):
                failures = check.compare_suite(self.suite, ["base", "head"], Mock(), evidence)
        self.assertEqual(failures, ["b"])
        self.assertEqual(sample.call_count, 2)
        self.assertEqual(evidence["rounds"], [first, second])

    def test_no_confirmation_when_first_round_passes(self):
        """A passing comparison needs no extra round."""
        with patch.object(check, "sample_round", return_value=self.analysis([1] * 5)) as sample:
            self.assertEqual(check.compare_suite(self.suite, [], Mock(), {"rounds": []}), [])
        self.assertEqual(sample.call_count, 1)

    def test_confirmation_failure_preserves_first_round(self):
        """An invalid confirmation must fail instead of declaring a transient pass."""
        evidence = {"rounds": []}
        first = self.analysis([1.5] * 5)
        with patch.object(check, "sample_round", side_effect=[first, ValueError("invalid")]):
            with redirect_stdout(io.StringIO()), self.assertRaises(ValueError):
                check.compare_suite(self.suite, [], Mock(), evidence)
        self.assertEqual(evidence["rounds"], [first])

    def test_baseline_precedence(self):
        """Explicit refs override PR bases; push checks use the previous commit."""
        with tempfile.TemporaryDirectory() as directory:
            event = Path(directory) / "event.json"
            with patch.dict(os.environ, {"GITHUB_EVENT_PATH": str(event)}, clear=True):
                event.write_text(json.dumps({"pull_request": {"base": {"sha": "pr-base"}}, "before": "push-base"}))
                self.assertEqual(check.base_revision(None), "pr-base")
                self.assertEqual(check.base_revision("override"), "override")
                event.write_text(json.dumps({"before": "push-base"}))
                self.assertEqual(check.base_revision(None), "push-base")
                event.write_text(json.dumps({"before": "0" * 40}))
                self.assertEqual(check.base_revision(None), "HEAD")
                event.write_text("invalid")
                with self.assertRaises(ValueError):
                    check.base_revision(None)
        with patch.dict(os.environ, {}, clear=True):
            self.assertEqual(check.base_revision(None), "HEAD")

    def test_missing_symbolic_revision_does_not_fetch(self):
        """A typo in a ref cannot silently select another baseline."""
        runner = Mock()
        with patch.object(check.subprocess, "run", return_value=Mock(returncode=1)):
            with self.assertRaises(ValueError):
                check.ensure_commit("missing-branch", runner)
        runner.run.assert_not_called()

    def test_source_extraction_rejects_links_and_traversal(self):
        """Only regular files below src are materialized in baseline extraction."""
        archive = io.BytesIO()
        with tarfile.open(fileobj=archive, mode="w") as target:
            for name in ("src/larecs/good.mojo", "src/../../escape", "/src/absolute", "other/file"):
                member = tarfile.TarInfo(name)
                member.size = 2
                target.addfile(member, io.BytesIO(b"ok"))
            link = tarfile.TarInfo("src/link")
            link.type = tarfile.SYMTYPE
            link.linkname = "/etc/passwd"
            target.addfile(link)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            completed = subprocess.CompletedProcess([], 0, archive.getvalue(), b"")
            with patch.object(check.subprocess, "run", return_value=completed):
                check.extract_sources("sha", root / "base", check.Runner(root))
            self.assertEqual([str(p.relative_to(root / "base")) for p in (root / "base").rglob("*") if p.is_file()],
                             ["src/larecs/good.mojo"])

    def test_runner_preserves_failure_and_timeout_diagnostics(self):
        """Failing binaries and timeouts retain captured stdout and stderr."""
        with tempfile.TemporaryDirectory() as directory:
            runner = check.Runner(Path(directory))
            with redirect_stderr(io.StringIO()), self.assertRaises(subprocess.CalledProcessError):
                runner.run(sys.executable, "-c", "import sys; print('checksum failed', file=sys.stderr); sys.exit(1)")
            self.assertIn("checksum failed", (runner.output / "command-001.log").read_text())
            with redirect_stderr(io.StringIO()), self.assertRaises(subprocess.TimeoutExpired):
                runner.run(sys.executable, "-c", "import time; print('started', flush=True); time.sleep(10)", timeout=0.1)
            self.assertIn("started", (runner.output / "command-002.log").read_text())

    def test_failed_checks_emit_reports_and_job_summary(self):
        """Baseline, compiler, and correctness failures remain reviewable."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            summary = root / "job.md"
            with patch.dict(os.environ, {"GITHUB_STEP_SUMMARY": str(summary)}, clear=True):
                for error in (ValueError("bad report"), OSError("missing compiler"),
                              subprocess.CalledProcessError(1, ["mojo", "build"])):
                    with patch.object(check, "execute", side_effect=error):
                        with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
                            self.assertEqual(check.main(["--output", str(root)]), 1)
                    report = json.loads((root / "report.json").read_text())
                    self.assertEqual(report["status"], "error")
                    self.assertIn(str(error), report["error"])
            self.assertIn("**error**", summary.read_text())
            self.assertTrue((root / "summary.md").exists())

    def test_confirmed_regression_exits_nonzero(self):
        """A valid timing report with a confirmed regression still fails CI."""
        with tempfile.TemporaryDirectory() as directory:
            def regression(args, report, runner):
                """Simulate a completed coordinator run with a confirmed slowdown."""
                report["status"] = "regression"
            with patch.object(check, "execute", side_effect=regression), redirect_stdout(io.StringIO()):
                self.assertEqual(check.main(["--output", directory]), 1)
            self.assertEqual(json.loads((Path(directory) / "report.json").read_text())["status"], "regression")


if __name__ == "__main__":
    unittest.main()
