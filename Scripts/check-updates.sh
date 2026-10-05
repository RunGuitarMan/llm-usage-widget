#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/toolchain.sh
source Scripts/dependencies.sh
mkdir -p build/ModuleCache
CORE=(LLMUsage/Data/*.swift LLMUsage/Services/*.swift
      LLMUsage/Shared/UsageModels.swift LLMUsage/Shared/Localization.swift
      LLMUsage/Shared/UsageFormatting.swift LLMUsage/Shared/UsageHistory.swift
      LLMUsage/Shared/UsageRoute.swift LLMUsage/Shared/SnapshotStorage.swift
      LLMUsage/Shared/SampleData.swift LLMUsage/App/RefreshSchedule.swift
      LLMUsage/App/UsageStore.swift LLMUsage/App/AppUpdateCoordinator.swift)
"$LLM_SWIFTC" -parse-as-library -D UPDATE_TESTING -sdk "$SDK_PATH" \
  -target arm64-apple-macosx26.0 -module-cache-path "$PWD/build/ModuleCache" \
  "${CORE[@]}" Scripts/UpdateIntegration.swift "${LLM_SPARKLE_FLAGS[@]}" \
  -Xlinker -rpath -Xlinker "$LLM_SPARKLE_DIRECTORY" -o build/update-integration
python3 Scripts/check_updates.py "$@"
