#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/toolchain.sh
mkdir -p build/ModuleCache
"$LLM_SWIFTC" -sdk "$SDK_PATH" -module-cache-path "$PWD/build/ModuleCache" Scripts/GenerateIcon.swift LLMUsage/Shared/BrandGeometry.swift -o build/generate-icon
build/generate-icon "$PWD"
iconutil --convert icns build/LLMUsage.iconset --output build/LLMUsage.icns
