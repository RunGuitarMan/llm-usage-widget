#!/bin/bash
# Development app with all WidgetKit families embedded; ad-hoc signed by default.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/ModuleCache
source Scripts/toolchain.sh
source Scripts/dependencies.sh
LOCK="$PWD/build/.app-artifact.lock"
if ! mkdir "$LOCK" 2>/dev/null; then echo 'The common app is being built or checked.' >&2; exit 1; fi
STAGE="$(mktemp -d "$PWD/build/.app-stage.XXXXXX")"
trap 'rm -rf "$STAGE"; rmdir "$LOCK"' EXIT
TARGET="$PWD/build/LLM Usage.app"
APP="$STAGE/LLM Usage.app"
python3 Scripts/app_artifact.py idle --app "$TARGET"
# Regenerate on every build so an icon update cannot reuse an old .icns.
bash Scripts/build-icons.sh
python3 Scripts/app_artifact.py inputs --inputs "$STAGE/inputs.json"
python3 Scripts/package-bundle.py app "$APP"
source Scripts/app-sources.sh
"$LLM_SWIFTC" -parse-as-library -module-name LLMUsage -sdk "$SDK_PATH" \
  -target "$(uname -m)-apple-macosx26.0" -module-cache-path "$PWD/build/ModuleCache" \
  "${LLM_APP_SOURCES[@]}" "${LLM_SPARKLE_FLAGS[@]}" -o "$APP/Contents/MacOS/LLM Usage"
python3 Scripts/verify-review-boundary.py "$APP/Contents/MacOS/LLM Usage"
python3 Scripts/package_icon.py "$APP" build/LLMUsage.icns
mkdir -p "$APP/Contents/PlugIns"
bash Scripts/build-widget.sh "$APP/Contents/PlugIns/LLMUsageWidget.appex"
python3 Scripts/build_version.py --verify-bundle "$APP" --with-widget
python3 Scripts/embed-dependencies.py "$APP"
codesign --force --sign "${LLM_CODESIGN_IDENTITY:--}" --entitlements build/app-build.entitlements "$APP"
codesign --verify --deep --strict "$APP"
python3 Scripts/verify-bundle.py "$APP"
python3 Scripts/app_artifact.py record --app "$APP" --manifest "$STAGE/app-artifact.json" --inputs "$STAGE/inputs.json"
# Publish only a complete, verified artifact. Never replace an app being inspected.
python3 Scripts/app_artifact.py idle --app "$TARGET"
python3 - "$APP" "$TARGET" "$STAGE/app-artifact.json" <<'PYTHON'
from pathlib import Path
import shutil, sys
source, target, manifest = map(Path, sys.argv[1:])
backup = target.with_suffix('.previous')
if backup.exists(): shutil.rmtree(backup)
if target.exists(): target.rename(backup)
try: source.rename(target)
except BaseException:
    if backup.exists(): backup.rename(target)
    raise
manifest.replace(target.parent / 'app-artifact.json')
if backup.exists(): shutil.rmtree(backup)
PYTHON
printf 'Built common app: %s\nReview: bash Scripts/manual-review.sh\n' "$TARGET"
