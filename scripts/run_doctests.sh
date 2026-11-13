#!/usr/bin/env bash
# Pass every source-derived program explicitly to mogo-tester.
# The source-derived inventory rejects missing tests before running any.
set -euo pipefail
: "${CONDA_PREFIX:?run via 'pixi run doctest'}"
exec python scripts/doc_examples.py run
