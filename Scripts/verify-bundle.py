#!/usr/bin/env python3
"""Fail a build if the host and its WidgetKit extension aren't a usable bundle pair."""
from pathlib import Path
import base64
import hashlib
import json
import plistlib
import subprocess
import sys
from build_version import build_identity, verify_bundle

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
verify_bundle(app, build_identity(channel=host["UsageUpdateChannel"]), with_widget=True)
runtime = json.loads((app / "Contents/Resources/CCUsageRuntime.json").read_text())
lock = json.loads((Path(__file__).resolve().parent.parent / "Configuration/Dependencies.json").read_text())["ccusage"]
helper = app / "Contents/Helpers/ccusage"
assert not helper.is_symlink(), "ccusage must be a bundled regular executable"
assert runtime["version"] == lock["version"] and runtime["contractVersion"] == lock["contractVersion"]
if "source" in lock:
    assert runtime["sourceCommit"] == lock["source"]["commit"] and runtime["patchSHA256"] == lock["patch"]["sha256"]
assert runtime["binarySHA256"] == hashlib.sha256(helper.read_bytes()).hexdigest(), "Bundled ccusage digest mismatch"
assert subprocess.check_output([str(helper), "--version"], text=True).strip() == "ccusage " + lock["version"]
subprocess.run(["codesign", "--verify", "--strict", str(helper)], check=True)
subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app / "Contents/Frameworks/Sparkle.framework")], check=True)
assert host["SURequireSignedFeed"] and host["SUVerifyUpdateBeforeExtraction"]
assert host["SUAutomaticallyUpdate"] is False and host["SUAllowsAutomaticUpdates"] is False
assert host["SUSignedFeedFailureExpirationInterval"] == 0
assert len(base64.b64decode(host["SUPublicEDKey"], validate=True)) == 32, "Missing update verification key"
assert host["UsageUpdateChannel"] in ("release", "development")
print("PASS Bundled ccusage version/digest/signature and signed-update configuration")
for provider in ["anthropic", "openai", "google"]:
    assert (app / "Contents/Resources/Providers" / f"{provider}.svg").is_file(), f"Missing provider logo: {provider}"
extension, entitlements = inspect(widget)
def icon_bytes(bundle, info):
    name = info.get("CFBundleIconFile", "")
    assert name and "/" not in name, "Missing gallery icon metadata"
    data = (bundle / "Contents/Resources" / (name + ".icns")).read_bytes()
    assert name == "LLMUsage-" + hashlib.sha256(data).hexdigest()[:16], "Stale gallery icon identity"
    return data

assert icon_bytes(app, host) == icon_bytes(widget, extension), "App and gallery extension icons differ"
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
                ("latest-usage-v2.json", "previous-day-usage-v2.json", "refresh-status.json", "daily-history-v1.json", "widget-presentation-v1.json")}
    read_key = "com.apple.security.temporary-exception.files.home-relative-path.read-only"
    assert set(entitlements.get(read_key, [])) == expected, "Widget must read only the five data files"
    assert set(entitlements) == {"com.apple.security.app-sandbox", read_key}, "Unexpected development widget access"
executable = widget / "Contents/MacOS" / extension["CFBundleExecutable"]
imports = subprocess.run(["xcrun", "nm", "-u", str(executable)], capture_output=True, text=True, check=True).stdout
assert "_NSExtensionMain" in imports.split(), "Missing NSExtensionMain entry point; Widget.main alone exits before serving WidgetKit"
print(f"PASS Embedded WidgetKit bundle, identifiers, versions, {storage_mode} storage, sandbox, extension entry point and signatures")
print("System gallery display and cross-process data access require a separate runtime check.")
