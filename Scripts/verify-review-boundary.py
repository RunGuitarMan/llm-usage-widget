#!/usr/bin/env python3
"""The common executable includes runtime review, never a separate integration app."""
from pathlib import Path
import sys
binary = Path(sys.argv[1]).read_bytes()
for marker in [b'ManualReviewController', b'ManualReviewPanel', b'--review']:
    if marker not in binary:
        raise SystemExit(f'FAIL: common app is missing runtime review capability: {marker.decode()}')
for marker in [b'UpdateIntegration', b'IntegrationOutput']:
    if marker in binary:
        raise SystemExit(f'FAIL: standalone update test entry point in app: {marker.decode()}')
print('PASS Common executable includes runtime review and excludes standalone integration entry points')
