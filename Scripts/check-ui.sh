#!/bin/bash
# Validate UI integration as well as the extension's restricted API surface.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/ModuleCache
source Scripts/toolchain.sh
COMMON=(-parse-as-library -typecheck -sdk "$SDK_PATH" -target "$(uname -m)-apple-macosx26.0"
        -module-cache-path "$PWD/build/ModuleCache")
source Scripts/app-sources.sh
source Scripts/dependencies.sh
"$LLM_SWIFTC" "${COMMON[@]}" -module-name LLMUsage "${LLM_APP_SOURCES[@]}" -F "$LLM_SPARKLE_DIRECTORY"
"$LLM_SWIFTC" "${COMMON[@]}" -application-extension -module-name LLMUsageWidget \
  LLMUsage/Shared/*.swift LLMUsage/Widget/*.swift
printf 'App and Widget UI typechecks passed.\n'
