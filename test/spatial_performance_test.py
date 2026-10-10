"""Exercise the PR performance guard's noise and failure boundaries."""

import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location(
    "spatial_performance", Path(__file__).resolve().parents[1]
    / "scripts/check_spatial_performance.py",
)
check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check)


class PerformanceGuardTest(unittest.TestCase):
    """Protect the distinction between repeatable regressions and timing noise."""

    def samples(self, multipliers, ns=10_000):
        """Build complete reports with controlled paired slowdowns.

        Args:
            multipliers: Relative times for individual samples.
            ns: Baseline nanoseconds per frame.

        Returns:
            Complete reports with the requested sample times."""
        return [dict.fromkeys(check.expected_cases(), ns * value) for value in multipliers]

    def test_repeatable_regression_fails(self):
        """A sustained slowdown fails even with one faster outlier."""
        base = self.samples([1] * 5)
        self.assertEqual(set(check.regressions(base, self.samples([1.5] * 4 + [0.8]))),
                         check.expected_cases())

    def test_transient_load_passes(self):
        """Three slow pairs cannot fail the four-of-five requirement."""
        self.assertFalse(check.regressions(self.samples([1] * 5),
                                           self.samples([1.5] * 3 + [1, 1])))

    def test_absolute_floor_and_improvements_pass(self):
        """Sub-microsecond noise and faster implementations pass."""
        self.assertFalse(check.regressions(self.samples([1] * 5, 400),
                                           self.samples([2] * 5, 400)))
        self.assertFalse(check.regressions(self.samples([1] * 5),
                                           self.samples([0.5] * 5)))

    def test_missing_duplicate_nonfinite_records_fail(self):
        """Incomplete reports and invalid timers cannot silently pass CI."""
        lines = ["SPATIAL " + " ".join(map(str, case)) + " 10000"
                 for case in sorted(check.expected_cases())]
        report = "\n".join(lines)
        self.assertEqual(set(check.parse_report(report)), check.expected_cases())
        for malformed in ("\n".join(lines[:-1]), report + "\n" + lines[0],
                          report.replace("10000", "nan", 1),
                          report.replace("10000", "0", 1)):
            with self.assertRaises(ValueError):
                check.parse_report(malformed)


if __name__ == "__main__":
    unittest.main()
