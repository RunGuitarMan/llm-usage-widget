#!/usr/bin/env python3
"""Expand the same plist/entitlement templates for local app and extension builds."""
import os
from pathlib import Path
import plistlib
import re
import sys

kind, destination = sys.argv[1:]
root = Path(__file__).resolve().parent.parent
bundle = Path(destination)
settings = {}
for name in ["Shared.xcconfig", "Local.xcconfig"]:
    path = root / "Configuration" / name
    if path.exists():
        for line in path.read_text().splitlines():
            match = re.match(r"^([A-Z_]+)\s*=\s*(.*?)\s*$", line.split("//", 1)[0])
            if match:
                settings[match[1]] = match[2]
for key in ["LLM_USAGE_APP_GROUP", "CLAUDE_USAGE_APP_GROUP", "MARKETING_VERSION", "CURRENT_PROJECT_VERSION"]:
    if key in os.environ:
        settings[key] = os.environ[key]
app_id = os.environ.get("LLM_APP_BUNDLE_ID", "local.ClaudeUsage.Development")
if not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", app_id):
    raise SystemExit("Expected a reverse-DNS app bundle identifier")
storage_mode = os.environ.get("LLM_WIDGET_STORAGE_MODE",
    "local-files" if os.environ.get("LLM_CODESIGN_IDENTITY", "-") == "-" else "app-group")
if storage_mode not in ("local-files", "app-group"):
    raise SystemExit("LLM_WIDGET_STORAGE_MODE must be local-files or app-group")
is_widget = kind == "widget"
if kind not in ("app", "widget"):
    raise SystemExit("Expected app or widget")
settings.update(
    EXECUTABLE_NAME="LLMUsageWidget" if is_widget else "LLM Usage",
    PRODUCT_NAME="LLMUsageWidget" if is_widget else "LLM Usage",
    PRODUCT_BUNDLE_IDENTIFIER=app_id + ".Widget" if is_widget else app_id,
    MACOSX_DEPLOYMENT_TARGET="26.0",
)

def expand(value):
    if isinstance(value, str):
        for _ in range(10):
            updated = re.sub(r"\$\(([^)]+)\)", lambda m: settings[m[1]], value)
            if updated == value:
                return value
            value = updated
        raise ValueError("Circular build setting")
    if isinstance(value, list):
        return [expand(item) for item in value]
    if isinstance(value, dict):
        return {key: expand(item) for key, item in value.items()}
    return value

stem = "Widget" if is_widget else "App"
resources = root / "LLMUsage/Resources"
info = expand(plistlib.loads((resources / f"{stem}-Info.plist").read_bytes()))
info["CFBundleSupportedPlatforms"] = ["MacOSX"]
info["UsageWidgetStorageMode"] = storage_mode
if storage_mode == "local-files":
    info["UsageLocalWidgetDataPath"] = f"Library/Application Support/{app_id}/WidgetData"
if not is_widget:
    info["CFBundleIconFile"] = "LLMUsage"
for directory in ["MacOS", "Resources"]:
    (bundle / "Contents" / directory).mkdir(parents=True, exist_ok=True)
(bundle / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
entitlements = expand(plistlib.loads((resources / f"{stem}.entitlements").read_bytes()))
if storage_mode == "local-files":
    # Ad-hoc signatures cannot read TCC-protected App Groups on recent macOS.
    # The extension gets read-only access to four derived data files, not CLI logs.
    entitlements.pop("com.apple.security.application-groups", None)
    if is_widget:
        entitlements["com.apple.security.temporary-exception.files.home-relative-path.read-only"] = [
            f"/{info['UsageLocalWidgetDataPath']}/{name}" for name in
            ("latest-usage-v2.json", "previous-day-usage-v2.json", "refresh-status.json", "daily-history-v1.json")
        ]
(root / "build" / f"{kind}-build.entitlements").write_bytes(plistlib.dumps(entitlements))
