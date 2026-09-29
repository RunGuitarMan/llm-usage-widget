#!/bin/bash
# Sourced by local build scripts. Prefer an explicitly selected developer directory,
# then the project-local Apple toolchain, then the system's selected Xcode/CLT.
LLM_PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LLM_LOCAL_TOOLS="$LLM_PROJECT_ROOT/build/AppleTools26/CommandLineTools"
if [[ -z "${DEVELOPER_DIR:-}" && -x "$LLM_LOCAL_TOOLS/usr/bin/swiftc" ]]; then
  export DEVELOPER_DIR="$LLM_LOCAL_TOOLS"
fi
LLM_SWIFTC="$(xcrun --find swiftc)"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
LLM_SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
if (( ${LLM_SDK_VERSION%%.*} < 26 )); then
  printf 'macOS SDK 26+ is required for native Tahoe chrome. Select Xcode/CLT 26+ using DEVELOPER_DIR.\n' >&2
  return 1
fi
