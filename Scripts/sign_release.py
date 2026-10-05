#!/usr/bin/env python3
"""Create a signed, immutable appcast for a complete GitHub release."""
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import xml.etree.ElementTree as ET
from release_artifacts import archive_file, release_identity, verify_archive
from release_version import git

ROOT = Path(__file__).resolve().parent.parent
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)


def make_feed(version, build, url, signature, length, notes, previous=None):
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,2}", version) or not build.isdecimal():
        raise ValueError("Expected a release version and monotonic numeric build")
    root = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(root, "channel")
    ET.SubElement(channel, "title").text = "LLM Usage"
    item = ET.SubElement(channel, "item")
    ET.SubElement(item, "title").text = "LLM Usage " + version
    ET.SubElement(item, f"{{{SPARKLE}}}version").text = build
    ET.SubElement(item, f"{{{SPARKLE}}}shortVersionString").text = version
    ET.SubElement(item, f"{{{SPARKLE}}}minimumSystemVersion").text = "26.0"
    ET.SubElement(item, "description", {f"{{{SPARKLE}}}descriptionFormat": "plain-text"}).text = notes
    ET.SubElement(item, "enclosure", {"url": url, "length": str(length), "type": "application/octet-stream",
                                     f"{{{SPARKLE}}}edSignature": signature})
    if previous is not None:
        # Keep older compatible updates for Macs unable to run a later minimum OS.
        old_items = previous.findall("./channel/item")
        old_items.sort(key=lambda old: int(old.findtext(f"{{{SPARKLE}}}version", "0")), reverse=True)
        for old in old_items[:19]:
            old_build = old.findtext(f"{{{SPARKLE}}}version", "0")
            if old_build != build:
                channel.append(old)
    ET.indent(root)
    return ET.tostring(root, encoding="utf-8", xml_declaration=True)


def main():
    repository = os.environ.get("GITHUB_REPOSITORY", "RunGuitarMan/llm-usage-widget")
    tag = os.environ["RELEASE_TAG"]
    if not re.fullmatch(r"v[0-9]+\.[0-9]+(?:\.[0-9]+)?", tag):
        raise SystemExit("Invalid release tag")
    identity = release_identity(tag, os.environ.get("GITHUB_SHA", git(ROOT, "rev-parse", "HEAD")))
    archive = ROOT / f"build/release/LLM-Usage-{tag}-macOS-arm64.zip"
    info = verify_archive(archive, identity)
    signer = ROOT / "build/Dependencies/current/sparkle/bin/sign_update"
    private_key = os.environ.get("SPARKLE_PRIVATE_KEY")
    signing_args = ["--ed-key-file", "-"] if private_key else ["--account", "llmusage-widget"]

    def sign(*args):
        result = subprocess.run([str(signer), *signing_args, *args], input=private_key,
                                text=True, capture_output=True)
        if result.returncode:
            raise RuntimeError("Sparkle signing/verification failed: " + result.stderr.strip())
        return result.stdout.strip()

    signature = sign("-p", str(archive))
    subprocess.run([str(ROOT / "build/verify-update"), info["SUPublicEDKey"], signature, str(archive)], check=True)
    previous = None
    with tempfile.TemporaryDirectory(prefix="appcast-", dir=ROOT / "build") as temporary:
        old_feed = Path(temporary) / "appcast.xml"
        # The first updater-enabled release has no appcast. Only a genuine 404 is optional.
        response = subprocess.run(["/usr/bin/curl", "--location", "--silent", "--show-error", "--proto", "=https",
            "--proto-redir", "=https", "--max-time", "60", "--max-filesize", "2097152", "--output", str(old_feed),
            "--write-out", "%{http_code}", f"https://github.com/{repository}/releases/latest/download/appcast.xml"],
            capture_output=True, text=True, check=True)
        if response.stdout == "200":
            sign("--verify", str(old_feed))
            previous = ET.fromstring(old_feed.read_bytes())
        elif response.stdout != "404":
            raise RuntimeError("Could not retrieve the previous signed appcast")
    manifest = json.loads(archive_file(archive, "LLM Usage.app/Contents/Resources/CCUsageRuntime.json"))
    notes = subprocess.check_output(["git", "log", "-1", "--format=%s"], text=True).strip()
    notes += "\n\nBundled ccusage " + manifest["version"] + ". No Node.js or npm installation is required."
    feed = ROOT / "build/release/appcast.xml"
    feed.write_bytes(make_feed(tag[1:], info["CFBundleVersion"],
        f"https://github.com/{repository}/releases/download/{tag}/{archive.name}",
        signature, archive.stat().st_size, notes, previous))
    sign(str(feed))
    sign("--verify", str(feed))
    print("Verified update archive and signed appcast against the app's public key")


if __name__ == "__main__":
    main()
