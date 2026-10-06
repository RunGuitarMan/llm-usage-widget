#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Both launches consume the exact artifact created by build-local.sh.
bash Scripts/manual-review.sh --normal-smoke
bash Scripts/manual-review.sh --self-check
