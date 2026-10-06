#!/bin/bash
# Build a complete extension bundle. Distribution signing/provisioning uses Xcode.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/ModuleCache
source Scripts/toolchain.sh
WIDGET="${1:-$PWD/build/LLMUsageWidget.appex}"
python3 Scripts/package-bundle.py widget "$WIDGET"
bash Scripts/build-icons.sh
python3 Scripts/package_icon.py "$WIDGET" build/LLMUsage.icns
# Widget.main registers the widget; NSExtensionMain keeps the extension serving XPC.
"$LLM_SWIFTC" -parse-as-library -application-extension -module-name LLMUsageWidget \
  -target "$(uname -m)-apple-macosx26.0" -sdk "$SDK_PATH" \
  -module-cache-path "$PWD/build/ModuleCache" \
  -Xlinker -e -Xlinker _NSExtensionMain \
  LLMUsage/Shared/*.swift LLMUsage/Widget/*.swift -o "$WIDGET/Contents/MacOS/LLMUsageWidget"
python3 Scripts/build_version.py --verify-bundle "$WIDGET"
codesign --force --sign "${LLM_CODESIGN_IDENTITY:--}" --entitlements build/widget-build.entitlements "$WIDGET"
codesign --verify --strict "$WIDGET"
printf 'Built extension: %s\n' "$WIDGET"
