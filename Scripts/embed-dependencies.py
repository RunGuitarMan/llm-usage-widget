#!/usr/bin/env python3
"""Embed and sign pinned native code before the outer app is sealed."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent


def sign(path, identity):
    command = ["/usr/bin/codesign", "--force", "--preserve-metadata=identifier,entitlements", "--sign", identity]
    if identity != "-":
        command += ["--options", "runtime", "--timestamp"]
    subprocess.run(command + [str(path)], check=True)


def embed(app, identity="-"):
    deps = ROOT / "build/Dependencies/current"
    lock = json.loads((ROOT / "Configuration/Dependencies.json").read_text())
    binary = deps / "ccusage/package/bin/ccusage"
    if hashlib.sha256(binary.read_bytes()).hexdigest() != lock["ccusage"]["binarySHA256"]:
        raise ValueError("The locked ccusage binary was modified")
    helpers = app / "Contents/Helpers"
    helpers.mkdir(parents=True, exist_ok=True)
    helper = helpers / "ccusage"
    shutil.copy2(binary, helper)
    helper.chmod(0o755)
    sign(helper, identity)
    resources = app / "Contents/Resources"
    resources.mkdir(parents=True, exist_ok=True)
    # Signing changes the Mach-O bytes: seal the digest of the final shipped helper.
    spec = lock["ccusage"]
    manifest = {key: spec[key] for key in ["version", "contractVersion", "architecture"]}
    manifest.update(schemaVersion=1, binarySHA256=hashlib.sha256(helper.read_bytes()).hexdigest())
    (resources / "CCUsageRuntime.json").write_text(json.dumps(manifest, indent=2) + "\n")
    licenses = resources / "Licenses"
    licenses.mkdir(exist_ok=True)
    shutil.copy2(ROOT / "LLMUsage/Resources/Licenses/ccusage.txt", licenses / "ccusage.txt")
    shutil.copy2(deps / "sparkle/LICENSE", licenses / "Sparkle.txt")
    framework = app / "Contents/Frameworks/Sparkle.framework"
    if framework.exists():
        shutil.rmtree(framework)
    framework.parent.mkdir(exist_ok=True)
    subprocess.run(["/usr/bin/ditto", str(deps / "sparkle/Sparkle.framework"), str(framework)], check=True)
    for part in ["Versions/B/XPCServices/Downloader.xpc", "Versions/B/XPCServices/Installer.xpc",
                 "Versions/B/Updater.app", "Versions/B/Autoupdate"]:
        sign(framework / part, identity)
    sign(framework, identity)
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(framework)], check=True)


if __name__ == "__main__":
    embed(Path(sys.argv[1]), os.environ.get("LLM_CODESIGN_IDENTITY", "-"))
