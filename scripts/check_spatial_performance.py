#!/usr/bin/env python3
"""Compatibility entry point for the spatial-only PR performance check."""

from pathlib import Path
import sys

# This module is also loaded by path in the original spatial guard tests.
sys.path.insert(0, str(Path(__file__).resolve().parent))
import check_performance as performance

BOOTSTRAP = performance.BOOTSTRAP
RATIO_LIMIT = performance.RATIO_LIMIT
ABSOLUTE_LIMIT_NS = performance.ABSOLUTE_LIMIT_NS


def expected_cases():
    """Return the original six-field spatial manifest.

    Returns:
        Integer scenario tuples supported by the current driver.
    """
    return {tuple(map(int, case.split("/"))) for case in performance.SUITES["spatial"].cases}


def parse_report(output):
    """Validate a complete spatial timing report.

    Args:
        output: Captured driver stdout.

    Raises:
        ValueError: If records are invalid or incomplete.

    Returns:
        Nanoseconds per frame indexed by original integer scenario tuples.
    """
    return {tuple(map(int, case.split("/"))): ns
            for case, ns in performance.parse_report(output, performance.SUITES["spatial"]).items()}


def regressions(base, head):
    """Apply the shared paired regression policy to legacy spatial reports.

    Args:
        base: Five baseline reports with tuple scenario keys.
        head: Five corresponding current reports.

    Raises:
        ValueError: If sample counts or manifests differ.

    Returns:
        Integer scenario tuples with sustained slowdowns.
    """
    def convert(reports):
        """Convert legacy keys to the shared report schema.

        Args:
            reports: Tuple-key timing reports.

        Returns:
            String-key timing reports.
        """
        return [{"/".join(map(str, case)): ns for case, ns in report.items()}
                for report in reports]

    evidence = performance.analyze(convert(base), convert(head), performance.SUITES["spatial"].cases)
    return [tuple(map(int, case.split("/"))) for case, data in evidence.items() if data["candidate"]]


if __name__ == "__main__":
    sys.exit(performance.main(["--suite", "spatial", *sys.argv[1:]]))
