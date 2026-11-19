#!/usr/bin/env bash
# Run source doctests with mogo-tester 3 and every referenced example program.
# The inventory rejects unchecked listings and missing examples before running.
set -euo pipefail
: "${CONDA_PREFIX:?run via 'pixi run doctest'}"
exec python scripts/doc_examples.py run
