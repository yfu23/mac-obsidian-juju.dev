#!/bin/bash
# Core logic checks plus the read-only guard.
set -euo pipefail
cd "$(dirname "$0")"
./scripts/check_readonly.sh
swift run CoreChecks
