#!/bin/bash
# Probe harness runner for Notchmeter providers.
# Inspects all AI provider installations, ChatGPT-heavy multi-window metrics, and Advisor burn routing.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "=== Notchmeter Provider Probe Harness ==="
swift test --filter ProbeHarnessTests "$@"
