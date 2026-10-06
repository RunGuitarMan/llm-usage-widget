#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/ModuleCache build/Previews
ditto LLMUsage/Resources/Providers build/Providers
source Scripts/toolchain.sh
SOURCES=(LLMUsage/App/AppUpdateCoordinator.swift LLMUsage/App/DashboardWindowCoordinator.swift LLMUsage/App/RefreshSchedule.swift LLMUsage/App/UsageStore.swift LLMUsage/App/MenuBarController.swift LLMUsage/App/MenuBarBadge.swift LLMUsage/App/MenuBarUsageView.swift LLMUsage/Data/*.swift LLMUsage/Services/*.swift
         LLMUsage/Shared/*.swift LLMUsage/Dashboard/*.swift LLMUsage/Sessions/*.swift
         LLMUsage/Models/*.swift LLMUsage/Settings/*.swift LLMUsage/Widget/UsageWidgetViews.swift LLMUsage/Widget/UsageVariantViews.swift Scripts/ManualReview/*.swift)
"$LLM_SWIFTC" -parse-as-library -module-name LLMUsagePreviews -sdk "$SDK_PATH" \
  -target "$(uname -m)-apple-macosx26.0" -module-cache-path "$PWD/build/ModuleCache" \
  "${SOURCES[@]}" Scripts/RenderPreviews.swift -o build/render-previews
build/render-previews "$PWD/build/Previews" "$@"
