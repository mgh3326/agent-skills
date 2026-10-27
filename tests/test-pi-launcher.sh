#!/usr/bin/env bash
# Invoked by test-wrk.sh, so both canonical CI OS jobs exercise this contract.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 -m unittest discover -s "$ROOT/tests" -p test_wrk_pi.py -v
