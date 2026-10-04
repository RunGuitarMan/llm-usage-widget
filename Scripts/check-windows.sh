#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/ModuleCache
ditto LLMUsage/Resources/Providers build/Providers
source Scripts/toolchain.sh
SOURCES=(LLMUsage/App/RefreshSchedule.swift LLMUsage/App/UsageStore.swift LLMUsage/App/MenuBarBadge.swift
         LLMUsage/App/MenuBarUsageView.swift LLMUsage/App/MenuBarController.swift
         LLMUsage/Data/*.swift LLMUsage/Services/*.swift LLMUsage/Shared/*.swift
         LLMUsage/Dashboard/*.swift LLMUsage/Sessions/*.swift LLMUsage/Models/*.swift LLMUsage/Settings/*.swift
         LLMUsage/Widget/UsageWidgetViews.swift LLMUsage/Widget/UsageVariantViews.swift)
"$LLM_SWIFTC" -parse-as-library -sdk "$SDK_PATH" -target "$(uname -m)-apple-macosx26.0" \
  -module-cache-path "$PWD/build/ModuleCache" "${SOURCES[@]}" Scripts/WindowChecks.swift -o build/window-checks
build/window-checks | tee build/window-checks-output.log
# AppKit can terminate a process with exit 0 when WindowServer access is denied.
# Require the final assertion to have run; a partial run must never look successful.
grep -q '^PASS Popover updates' build/window-checks-output.log
"$LLM_SWIFTC" -parse-as-library -sdk "$SDK_PATH" -target "$(uname -m)-apple-macosx26.0" \
  -module-cache-path "$PWD/build/ModuleCache" "${SOURCES[@]}" Scripts/SessionNavigationChecks.swift -o build/session-navigation-checks
build/session-navigation-checks | tee build/session-navigation-checks-output.log
grep -q '^PASS Session links.* in ru$' build/session-navigation-checks-output.log
