#!/usr/bin/env bash
# verify-structure: required files and directories exist (deterministic).
set -euo pipefail
cd "$(dirname "$0")/.."

fail=0
require() {
  if [ -e "$1" ]; then
    echo "  ok   $1"
  else
    echo "  MISS $1" >&2
    fail=1
  fi
}

echo "verify-structure:"
require README.md
require AGENTS.md
require contracts/observability-capability-contract-v1.md
require profiles/ok-observability-standard/README.md
require tests/README.md
require implementations/prometheus
require implementations/grafana
require implementations/opensearch
require dashboards
require alerting
require architecture/decisions

if [ "$fail" -ne 0 ]; then
  echo "verify-structure: FAIL" >&2
  exit 1
fi
echo "verify-structure: PASS"
