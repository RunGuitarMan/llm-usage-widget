#!/bin/bash
# Launch the already built common app. No compilation or second bundle.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 Scripts/launch-review.py "$@"
