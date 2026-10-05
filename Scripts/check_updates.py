"""Exercise the production coordinator and Sparkle with disposable signed app bundles.

Requires a logged-in macOS session. Uses fresh test keys, no production secrets or logs.
"""
import functools
import argparse
import http.server
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import threading
import time
import uuid

from sign_release import make_feed

ROOT = Path(__file__).resolve().parent.parent
SIGNER = ROOT / "build/Dependencies/current/sparkle/bin/sign_update"


def run(*args, **kwargs):
    return subprocess.run(args, check=True, capture_output=True, **kwargs)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=["manual", "ask", "bad-signature", "install", "automatic"])
    options = parser.parse_args()
    keys = json.loads(run(str(ROOT / "build/update-integration"), "--keypair").stdout)
    with tempfile.TemporaryDirectory(prefix="llm-update-integration-", dir=ROOT / "build") as temporary:
        directory = Path(temporary)
        handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(directory))
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        base_url = f"http://127.0.0.1:{server.server_port}"
        try:
            for mode in ([options.mode] if options.mode else ["manual", "ask", "bad-signature", "install", "automatic"]):
                scenario = directory / mode
                scenario.mkdir()
                identifier = "local.LLMUsage.UpdateIntegration." + uuid.uuid4().hex
                output = scenario / "result.txt"
                app = scenario / "Update Test.app"
                info = {"CFBundleIdentifier": identifier, "CFBundleExecutable": "Update Test",
                        "CFBundleName": "Update Test", "CFBundlePackageType": "APPL",
                        "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0",
                        "LSMinimumSystemVersion": "26.0", "LSUIElement": True,
                        "UsageUpdateChannel": "release", "SUPublicEDKey": keys["public"],
                        "SUFeedURL": base_url + f"/{mode}/appcast.xml", "SUEnableAutomaticChecks": False,
                        "SUAutomaticallyUpdate": False, "SUAllowsAutomaticUpdates": False,
                        "SURequireSignedFeed": True, "SUSignedFeedFailureExpirationInterval": 0,
                        "SUVerifyUpdateBeforeExtraction": True,
                        "NSAppTransportSecurity": {"NSAllowsLocalNetworking": True},
                        "IntegrationOutput": str(output), "IntegrationMode": mode}
                (app / "Contents/MacOS").mkdir(parents=True)
                shutil.copy2(ROOT / "build/update-integration", app / "Contents/MacOS/Update Test")
                run("/usr/bin/ditto", str(ROOT / "build/Dependencies/current/sparkle/Sparkle.framework"),
                    str(app / "Contents/Frameworks/Sparkle.framework"))
                # Ad-hoc sign nested code as production does, retaining XPC entitlements.
                framework = app / "Contents/Frameworks/Sparkle.framework"
                for part in ["Versions/B/XPCServices/Downloader.xpc", "Versions/B/XPCServices/Installer.xpc",
                             "Versions/B/Updater.app", "Versions/B/Autoupdate", ""]:
                    run("/usr/bin/codesign", "--force", "--preserve-metadata=identifier,entitlements", "--sign", "-", str(framework / part))

                def write_version(version):
                    info.update(CFBundleVersion=str(version), CFBundleShortVersionString=f"{version}.0")
                    (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
                    run("/usr/bin/codesign", "--force", "--sign", "-", str(app))

                write_version(2)
                archive = scenario / "update.zip"
                run("/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(archive))
                signature = run(str(SIGNER), "--ed-key-file", "-", "-p", str(archive), input=keys["private"], text=True).stdout.strip()
                if mode == "bad-signature":
                    signature = ("A" if signature[0] != "A" else "B") + signature[1:]
                feed = scenario / "appcast.xml"
                feed.write_bytes(make_feed("2.0", "2", base_url + f"/{mode}/update.zip", signature,
                                           archive.stat().st_size, "Synthetic signed update"))
                run(str(SIGNER), "--ed-key-file", "-", str(feed), input=keys["private"], text=True)
                write_version(1)
                process = subprocess.Popen([str(app / "Contents/MacOS/Update Test")],
                    stdout=subprocess.DEVNULL, stderr=(scenario / "stderr.log").open("w"))
                try:
                    deadline = time.monotonic() + 130
                    while time.monotonic() < deadline:
                        result = output.read_text() if output.exists() else ""
                        if "ERROR" in result or "TIMEOUT" in result or "RELAUNCHED 2" in result:
                            break
                        if process.poll() is not None and mode not in ("install", "automatic"):
                            break
                        time.sleep(0.2)
                    if mode in ("install", "automatic"):
                        assert "RELAUNCHED 2" in result, result + (scenario / "stderr.log").read_text()
                        assert plistlib.loads((app / "Contents/Info.plist").read_bytes())["CFBundleVersion"] == "2"
                    else:
                        process.wait(timeout=5)
                        time.sleep(2)  # Explicitly prove download-only cannot install on quit.
                        assert plistlib.loads((app / "Contents/Info.plist").read_bytes())["CFBundleVersion"] == "1", result
                        expected = {"manual": "MANUAL AVAILABLE", "ask": "QUIT WITHOUT INSTALL", "bad-signature": "ERROR"}[mode]
                        assert expected in result, result
                    print(f"PASS Sparkle integration: {mode}", flush=True)
                finally:
                    if process.poll() is None:
                        process.terminate(); process.wait(timeout=5)
                    subprocess.run(["/usr/bin/defaults", "delete", identifier], capture_output=True)
                    shutil.rmtree(Path.home() / "Library/Caches" / identifier, ignore_errors=True)
        finally:
            server.shutdown()


if __name__ == "__main__":
    main()
