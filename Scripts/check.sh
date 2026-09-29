#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/ModuleCache
source Scripts/toolchain.sh
CORE=(LLMUsage/Data/*.swift LLMUsage/Services/*.swift LLMUsage/Shared/UsageModels.swift
      LLMUsage/Shared/Localization.swift LLMUsage/Shared/UsageFormatting.swift LLMUsage/Shared/UsageHistory.swift LLMUsage/Shared/UsageRoute.swift
      LLMUsage/Shared/SnapshotStorage.swift LLMUsage/Shared/SampleData.swift LLMUsage/App/RefreshSchedule.swift LLMUsage/App/UsageStore.swift)
"$LLM_SWIFTC" -parse-as-library -D PORTABLE_CHECKS -module-name LLMUsageChecks -sdk "$SDK_PATH" \
  -target "$(uname -m)-apple-macosx14.0" -module-cache-path "$PWD/build/ModuleCache" \
  "${CORE[@]}" LLMUsage/Tests/RegressionScenarios.swift Scripts/PortableChecks.swift Scripts/TranscriptChecks.swift Scripts/HistoryChecks.swift Scripts/LocalizationChecks.swift Scripts/RefreshChecks.swift -o build/portable-checks
build/portable-checks "$@"
# Exercise native menu updates in an isolated AppKit process.
"$LLM_SWIFTC" -parse-as-library -module-name LLMUsageMenuChecks -sdk "$SDK_PATH" \
  -target "$(uname -m)-apple-macosx14.0" -module-cache-path "$PWD/build/ModuleCache" \
  LLMUsage/Shared/UsageModels.swift LLMUsage/Shared/UsageHistory.swift LLMUsage/Shared/SnapshotStorage.swift \
  LLMUsage/Shared/Localization.swift LLMUsage/Shared/UsageFormatting.swift \
  LLMUsage/App/AppMenuLocalization.swift Scripts/MenuLocalizationChecks.swift -o build/menu-localization-checks
build/menu-localization-checks
bash Scripts/check-ui.sh
