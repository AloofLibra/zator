#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 "$ROOT/tests/adaptive_stats_v2_test.py"
python3 "$ROOT/tests/adaptive_stats_v2_deploy_test.py"
