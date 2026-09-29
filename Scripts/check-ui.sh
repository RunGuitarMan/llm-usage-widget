#!/bin/bash
# Validate UI integration as well as the extension's restricted API surface.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/ModuleCache
source Scripts/toolchain.sh
COMMON=(-parse-as-library -typecheck -sdk "$SDK_PATH" -target "$(uname -m)-apple-macosx26.0"
        -module-cache-path "$PWD/build/ModuleCache")
"$LLM_SWIFTC" "${COMMON[@]}" -module-name LLMUsage \
  LLMUsage/App/*.swift LLMUsage/Data/*.swift LLMUsage/Services/*.swift LLMUsage/Shared/*.swift \
  LLMUsage/Dashboard/*.swift LLMUsage/Sessions/*.swift LLMUsage/Models/*.swift LLMUsage/Settings/*.swift \
  LLMUsage/Widget/UsageWidgetViews.swift LLMUsage/Widget/UsageVariantViews.swift
"$LLM_SWIFTC" "${COMMON[@]}" -application-extension -module-name LLMUsageWidget \
  LLMUsage/Shared/*.swift LLMUsage/Widget/*.swift
printf 'App and Widget UI typechecks passed.\n'
