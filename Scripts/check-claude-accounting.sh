#!/bin/bash
# One focused, non-UI build/run. No app windows or personal Claude logs.
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/toolchain.sh
mkdir -p build/ModuleCache
CORE=(LLMUsage/Data/*.swift LLMUsage/Services/*.swift LLMUsage/Shared/UsageModels.swift LLMUsage/Shared/UsageHealth.swift
      LLMUsage/Shared/Localization.swift LLMUsage/Shared/UsageFormatting.swift LLMUsage/Shared/UsageHistory.swift LLMUsage/Shared/UsageRoute.swift
      LLMUsage/Shared/SnapshotStorage.swift LLMUsage/Shared/SampleData.swift LLMUsage/App/RefreshSchedule.swift LLMUsage/App/UsageStore.swift)
"$LLM_SWIFTC" -parse-as-library -D PORTABLE_CHECKS -module-name LLMUsageChecks -sdk "$SDK_PATH" \
  -target "$(uname -m)-apple-macosx14.0" -module-cache-path "$PWD/build/ModuleCache" \
  "${CORE[@]}" LLMUsage/Tests/*Scenarios.swift Scripts/PortableChecks.swift Scripts/TranscriptChecks.swift \
  Scripts/HistoryChecks.swift Scripts/LocalizationChecks.swift Scripts/RefreshChecks.swift -o build/portable-checks
build/portable-checks --accounting-only "$@"
