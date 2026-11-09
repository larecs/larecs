#!/usr/bin/env bash
# Modo's suffix-named tests must be passed explicitly to mogo-tester.
# The source-derived inventory rejects missing tests before running any.
set -euo pipefail
: "${CONDA_PREFIX:?run via 'pixi run doctest'}"
exec python scripts/doc_examples.py run
