"""Validate the bytes being published, independently of the unpacked build directory."""
import hashlib
from pathlib import Path
import plistlib
import xml.etree.ElementTree as ET
import zipfile

from build_version import ROOT, build_identity, validate_info

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
APP_INFO = "LLM Usage.app/Contents/Info.plist"
WIDGET_INFO = "LLM Usage.app/Contents/PlugIns/LLMUsageWidget.appex/Contents/Info.plist"


def release_identity(tag, commit, repository=ROOT):
    identity = build_identity(repository, "release")
    if identity["tag"] != tag or identity["commit"] != commit:
        raise ValueError("Release tag/commit does not match the checked-out source identity")
    return identity


def archive_file(archive, name):
    with zipfile.ZipFile(archive) as zipped:
        entries = [item for item in zipped.infolist() if item.filename == name]
        if len(entries) != 1 or entries[0].file_size > 1024 * 1024:
            raise ValueError(f"Missing, duplicate or oversized archive metadata: {name}")
        return zipped.read(entries[0])


def verify_archive(archive, identity):
    archive = Path(archive)
    expected_name = f"LLM-Usage-{identity['tag']}-macOS-arm64.zip"
    if archive.name != expected_name:
        raise ValueError("Archive filename does not match the release version")
    host = plistlib.loads(archive_file(archive, APP_INFO))
    widget = plistlib.loads(archive_file(archive, WIDGET_INFO))
    validate_info(host, identity)
    validate_info(widget, identity)
    return host


def verify_release_assets(tag, commit, github_repository, directory=ROOT / "build/release", repository=ROOT):
    identity = release_identity(tag, commit, repository)
    directory = Path(directory)
    archive = directory / f"LLM-Usage-{tag}-macOS-arm64.zip"
    verify_archive(archive, identity)
    checksum = hashlib.sha256(archive.read_bytes()).hexdigest()
    if (directory / "SHA256SUMS.txt").read_text().strip() != f"{checksum}  {archive.name}":
        raise ValueError("Release checksum does not describe the exact archive")
    feed = ET.fromstring((directory / "appcast.xml").read_bytes())
    item = feed.find("./channel/item")
    if item is None:
        raise ValueError("Missing release appcast item")
    expected = {"title": "LLM Usage " + identity["version"],
                f"{{{SPARKLE}}}version": identity["build"],
                f"{{{SPARKLE}}}shortVersionString": identity["version"]}
    for key, value in expected.items():
        if item.findtext(key) != value:
            raise ValueError(f"Appcast {key} does not match the archived application")
    enclosure = item.find("enclosure")
    url = f"https://github.com/{github_repository}/releases/download/{tag}/{archive.name}"
    if (enclosure is None or enclosure.get("url") != url
            or enclosure.get("length") != str(archive.stat().st_size)
            or not enclosure.get(f"{{{SPARKLE}}}edSignature")):
        raise ValueError("Appcast enclosure does not identify the release archive")
    return identity
