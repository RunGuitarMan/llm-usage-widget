#!/bin/bash
# Compile the production app entry/scene with private development-only scenario controls.
set -euo pipefail
cd "$(dirname "$0")/.."
case "${1:-}" in ""|--build-only|--self-check) ;; *) echo 'Usage: bash Scripts/manual-review.sh [--build-only|--self-check]' >&2; exit 2 ;; esac
source Scripts/toolchain.sh
source Scripts/app-sources.sh
source Scripts/dependencies.sh
mkdir -p build/manual-review build/ModuleCache
LOCK="$PWD/build/manual-review/.build-lock"
if ! mkdir "$LOCK" 2>/dev/null; then echo 'Another manual review build is running.' >&2; exit 1; fi
STAGE="$(mktemp -d "$PWD/build/manual-review/.stage.XXXXXX")"
trap 'rm -rf "$STAGE"; rmdir "$LOCK"' EXIT
REVIEW_APP="$STAGE/LLM Usage.app"
LLM_APP_BUNDLE_ID=local.ClaudeUsage.ManualReview LLM_CODESIGN_IDENTITY=- python3 Scripts/package-bundle.py app "$REVIEW_APP"
python3 - "$REVIEW_APP" "${LLM_APP_SOURCES[@]}" Scripts/ManualReview/*.swift <<'PY'
import hashlib, plistlib, subprocess, sys
from pathlib import Path
app = Path(sys.argv[1])
fingerprint = hashlib.sha256()
for name in sorted(sys.argv[2:]):
    fingerprint.update(name.encode())
    fingerprint.update(Path(name).read_bytes())
info_file = app/'Contents/Info.plist'
info = plistlib.loads(info_file.read_bytes())
info['CFBundleDisplayName'] = 'LLM Usage (Development)'
info['ManualReviewBuild'] = subprocess.check_output(['git','rev-parse','--short','HEAD'],text=True).strip()+'-'+fingerprint.hexdigest()[:12]
# The development bundle must not claim links belonging to the installed app.
info.pop('CFBundleURLTypes', None)
info_file.write_bytes(plistlib.dumps(info))
PY
"$LLM_SWIFTC" -parse-as-library -D MANUAL_REVIEW -module-name LLMUsage -sdk "$SDK_PATH" \
  -target "$(uname -m)-apple-macosx26.0" -module-cache-path "$PWD/build/ModuleCache" \
  "${LLM_APP_SOURCES[@]}" Scripts/ManualReview/*.swift "${LLM_SPARKLE_FLAGS[@]}" -o "$REVIEW_APP/Contents/MacOS/LLM Usage"
if [ -f build/LLMUsage.icns ]; then cp build/LLMUsage.icns "$REVIEW_APP/Contents/Resources/LLMUsage.icns"; fi
LLM_CODESIGN_IDENTITY=- python3 Scripts/embed-dependencies.py "$REVIEW_APP"
codesign --force --sign - "$REVIEW_APP"
codesign --verify --strict "$REVIEW_APP"
python3 Scripts/launch-review.py "$REVIEW_APP" "${1:-}"
