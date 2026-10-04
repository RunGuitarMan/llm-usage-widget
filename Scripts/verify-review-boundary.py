#!/usr/bin/env python3
"""Fail closed if a shipping executable contains the private review entry point or catalogue."""
from pathlib import Path
import sys
binary = Path(sys.argv[1]).read_bytes()
for marker in [b'ManualReviewController', b'ManualReviewPanel', b'--manual-review', b'review-launch-token', b'ReviewFixtureService']:
    if marker in binary:
        raise SystemExit(f'FAIL: development review code in shipping executable: {marker.decode()}')
print('PASS Shipping executable contains no manual review entry point or catalogue')
