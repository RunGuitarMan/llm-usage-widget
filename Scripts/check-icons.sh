#!/bin/bash
# Verify actual AppKit appearance changes in an isolated process, without changing the OS theme.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/ModuleCache
source Scripts/toolchain.sh
"$LLM_SWIFTC" -parse-as-library -sdk "$SDK_PATH" -module-cache-path "$PWD/build/ModuleCache" \
  LLMUsage/Shared/BrandGeometry.swift LLMUsage/App/AppIconAppearance.swift Scripts/IconChecks.swift \
  -o build/icon-checks
build/icon-checks "$PWD"
