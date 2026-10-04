#!/bin/bash
# Development app with all WidgetKit families embedded; ad-hoc signed by default.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/ModuleCache
source Scripts/toolchain.sh
APP="$PWD/build/LLM Usage.app"
python3 Scripts/package-bundle.py app "$APP"
# Regenerate on every build so an icon update cannot reuse an old .icns.
"$LLM_SWIFTC" -sdk "$SDK_PATH" -module-cache-path "$PWD/build/ModuleCache" Scripts/GenerateIcon.swift LLMUsage/Shared/BrandGeometry.swift -o build/generate-icon
build/generate-icon "$PWD"
iconutil --convert icns build/LLMUsage.iconset --output build/LLMUsage.icns
source Scripts/app-sources.sh
"$LLM_SWIFTC" -parse-as-library -module-name LLMUsage -sdk "$SDK_PATH" \
  -target "$(uname -m)-apple-macosx26.0" -module-cache-path "$PWD/build/ModuleCache" \
  "${LLM_APP_SOURCES[@]}" -o "$APP/Contents/MacOS/LLM Usage"
python3 Scripts/verify-review-boundary.py "$APP/Contents/MacOS/LLM Usage"
if [ -f build/LLMUsage.icns ]; then cp build/LLMUsage.icns "$APP/Contents/Resources/LLMUsage.icns"; fi
bash Scripts/build-widget.sh
mkdir -p "$APP/Contents/PlugIns"
ditto build/LLMUsageWidget.appex "$APP/Contents/PlugIns/LLMUsageWidget.appex"
codesign --force --sign "${LLM_CODESIGN_IDENTITY:--}" --entitlements build/app-build.entitlements "$APP"
codesign --verify --deep --strict "$APP"
python3 Scripts/verify-bundle.py "$APP"
printf 'Built: %s\nDemo: open "%s" --args --demo\n' "$APP" "$APP"
