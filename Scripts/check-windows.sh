#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Automated checks and interactive review share the production App/Scene and catalogue.
bash Scripts/manual-review.sh --self-check
