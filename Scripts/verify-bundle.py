#!/usr/bin/env python3
"""Fail a build if the host and its WidgetKit extension aren't a usable bundle pair."""
from pathlib import Path
import plistlib
import subprocess
import sys

app = Path(sys.argv[1]).resolve()
widget = app / "Contents/PlugIns/LLMUsageWidget.appex"

def inspect(bundle):
    info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
    assert (bundle / "Contents/MacOS" / info["CFBundleExecutable"]).is_file(), f"Missing executable: {bundle}"
    assert "$(" not in repr(info), f"Unexpanded build settings: {bundle}"
    result = subprocess.run(["codesign", "-d", "--entitlements", ":-", str(bundle)],
                            capture_output=True, check=True)
    entitlements = plistlib.loads(result.stdout)
    if info.get("UsageWidgetStorageMode", "app-group") == "app-group":
        assert info["UsageAppGroup"] in entitlements["com.apple.security.application-groups"], "Missing App Group entitlement"
    subprocess.run(["codesign", "--verify", "--strict", str(bundle)], check=True)
    return info, entitlements

host, _ = inspect(app)
for provider in ["anthropic", "openai", "google"]:
    assert (app / "Contents/Resources/Providers" / f"{provider}.svg").is_file(), f"Missing provider logo: {provider}"
extension, entitlements = inspect(widget)
assert extension["NSExtension"]["NSExtensionPointIdentifier"] == "com.apple.widgetkit-extension"
assert extension["CFBundlePackageType"] == "XPC!"
assert extension["CFBundleIdentifier"].startswith(host["CFBundleIdentifier"] + "."), "Extension ID must extend host ID"
assert extension["UsageAppGroup"] == host["UsageAppGroup"], "App Group mismatch"
assert extension["CFBundleVersion"] == host["CFBundleVersion"], "Build version mismatch"
assert extension["CFBundleShortVersionString"] == host["CFBundleShortVersionString"], "Marketing version mismatch"
assert entitlements["com.apple.security.app-sandbox"] is True, "Extension sandbox missing"
storage_mode = host.get("UsageWidgetStorageMode", "app-group")
assert extension.get("UsageWidgetStorageMode", "app-group") == storage_mode, "Storage mode mismatch"
assert storage_mode in ("local-files", "app-group"), "Unknown widget storage mode"
if storage_mode == "local-files":
    path = f"Library/Application Support/{host['CFBundleIdentifier']}/WidgetData"
    assert host["UsageLocalWidgetDataPath"] == extension["UsageLocalWidgetDataPath"] == path, "Local data path mismatch"
    expected = {f"/{path}/{name}" for name in
                ("latest-usage-v2.json", "previous-day-usage-v2.json", "refresh-status.json", "daily-history-v1.json")}
    read_key = "com.apple.security.temporary-exception.files.home-relative-path.read-only"
    assert set(entitlements.get(read_key, [])) == expected, "Widget must read only the four data files"
    assert set(entitlements) == {"com.apple.security.app-sandbox", read_key}, "Unexpected development widget access"
executable = widget / "Contents/MacOS" / extension["CFBundleExecutable"]
imports = subprocess.run(["xcrun", "nm", "-u", str(executable)], capture_output=True, text=True, check=True).stdout
assert "_NSExtensionMain" in imports.split(), "Missing NSExtensionMain entry point; Widget.main alone exits before serving WidgetKit"
print(f"PASS Embedded WidgetKit bundle, identifiers, versions, {storage_mode} storage, sandbox, extension entry point and signatures")
print("System gallery display and cross-process data access require a separate runtime check.")
