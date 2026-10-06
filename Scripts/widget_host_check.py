#!/usr/bin/env python3
"""Fail a system WidgetKit check on stale/missing deliveries or host errors.

Place all three widget kinds in all three sizes, refresh the common app, then
run this against that same artifact. An empty desktop is a failure, never a pass.
This checks the actual extension and chronod; visual layout is still inspected.
"""
import argparse
from datetime import datetime
import json
from pathlib import Path
import plistlib
import re
import subprocess
from app_artifact import ROOT, verify

KINDS = {"ClaudeUsageWidget", "LLMUsageSessionsWidget", "LLMUsageTrendWidget"}
EXPECTED = {(kind, str(family)) for kind in KINDS for family in range(3)}
LAUNCH_FAILURES = ("missing executable detected", "could not find and/or execute program",
                   "attempt to re-bootstrap service from different path, will use existing",
                   "failed to create extensionprocess", "failed to launch extension")


def assess(events, bundle_id, version, generation):
    observed = set()
    errors = []
    for event in events:
        message = event.get("eventMessage", "")
        if bundle_id not in message:
            continue
        if "bundleStubNotSupported" in message or "ValidationError" in message or "failed with error" in message:
            errors.append("WidgetKit rejected an archive: " + message)
        if any(failure in message.lower() for failure in LAUNCH_FAILURES):
            errors.append("WidgetKit launch/registration failed: " + message)
        if "WidgetDelivery " not in message:
            continue
        fields = dict(re.findall(r"(\w+)=([^\s]+)", message))
        if fields.get("bundle") != bundle_id or fields.get("phase") not in ("snapshot", "timeline"):
            continue
        if fields.get("storageUnavailable") not in ("0", "false"):
            errors.append("The extension could not read its data")
            continue
        if fields.get("version") != version:
            errors.append("A previous extension version is still delivering widgets")
            continue
        try:
            fresh = float(fields.get("generation", "0")) >= generation
        except ValueError:
            fresh = False
        if fresh:
            observed.add((fields.get("kind"), fields.get("family")))
    missing = EXPECTED - observed
    if missing:
        errors.append("Missing fresh system deliveries: " + ", ".join(f"{kind}/{family}" for kind, family in sorted(missing)))
    if errors:
        raise ValueError("\n".join(dict.fromkeys(errors)))
    return sorted(observed)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=ROOT / "build/LLM Usage.app")
    parser.add_argument("--manifest", type=Path, help="Manifest of the same artifact, if it was installed at another path")
    parser.add_argument("--since", required=True, help="ISO-8601 start of the desktop test, including timezone")
    parser.add_argument("--output", type=Path, default=ROOT / "build/widget-host-check.json")
    args = parser.parse_args()
    app = args.app.resolve()
    identity = verify(app, args.manifest or app.parent / "app-artifact.json")
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if info.get("UsageWidgetStorageMode") != "local-files":
        raise ValueError("This host check currently supports the local-files release channel only")
    relative = f"Library/Application Support/{info['CFBundleIdentifier']}/WidgetData"
    if info.get("UsageLocalWidgetDataPath") != relative:
        raise ValueError("Unexpected widget data location")
    snapshot = json.loads((Path.home() / relative / "latest-usage-v2.json").read_text())
    generation = datetime.fromisoformat(snapshot["generatedAt"].replace("Z", "+00:00")).timestamp()
    start = datetime.fromisoformat(args.since.replace("Z", "+00:00"))
    if start.tzinfo is None:
        raise ValueError("--since must include a timezone")
    bundle_id = identity["bundleID"] + ".Widget"
    if not re.fullmatch(r"[A-Za-z0-9.-]+", bundle_id):
        raise ValueError("Invalid bundle identifier")
    predicate = f'(process == "chronod" OR process == "launchd" OR subsystem == "local.ClaudeUsage.Widget") AND eventMessage CONTAINS "{bundle_id}"'
    result = subprocess.run(["/usr/bin/log", "show", "--style", "json", "--info", "--start",
                             start.astimezone().strftime("%Y-%m-%d %H:%M:%S"), "--predicate", predicate],
                            capture_output=True, text=True, check=True)
    deliveries = assess(json.loads(result.stdout), bundle_id, identity["version"], generation)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps({"bundleID": bundle_id, "version": identity["version"],
        "executableSHA256": identity["executableSHA256"], "since": args.since,
        "generation": generation, "deliveries": deliveries}, indent=2) + "\n")
    print("PASS Actual WidgetKit delivery for all 9 kind/size pairs; no archive or launch errors in the test interval")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, subprocess.SubprocessError) as error:
        raise SystemExit(str(error))
