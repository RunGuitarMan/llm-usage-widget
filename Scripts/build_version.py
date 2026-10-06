#!/usr/bin/env python3
"""One build identity for script builds, Xcode, review builds and release artifacts."""
import argparse
import json
import os
from pathlib import Path
import plistlib

from release_version import git, release_version

ROOT = Path(__file__).resolve().parent.parent
def build_identity(repository=ROOT, channel="development", overrides=None):
    if channel not in ("development", "release"):
        raise ValueError("Unknown build channel")
    commit = git(repository, "rev-parse", "HEAD")
    dirty = bool(git(repository, "status", "--porcelain", "--untracked-files=normal"))
    if channel == "release" and dirty:
        raise ValueError("Release builds require a clean source tree")
    version = release_version(repository, revision=commit)
    for key, field in (("MARKETING_VERSION", "version"), ("CURRENT_PROJECT_VERSION", "build")):
        supplied = (overrides or {}).get(key)
        if supplied and supplied != version[field]:
            raise ValueError(f"{key} is set by the repository; refusing conflicting override {supplied!r}")
    return dict(version, commit=commit, versionCommit=commit, dirty=dirty, channel=channel)


def version_fields(identity):
    return dict(CFBundleShortVersionString=identity["version"], CFBundleVersion=identity["build"],
                UsageSourceCommit=identity["commit"], UsageVersionCommit=identity["versionCommit"],
                UsageSourceDirty=identity["dirty"], UsageUpdateChannel=identity["channel"])


def validate_info(info, identity):
    for key, expected in version_fields(identity).items():
        if info.get(key) != expected:
            raise ValueError(f"Bundle {key}: expected {expected!r}, found {info.get(key)!r}")
    if identity["channel"] == "release" and "ManualReviewBuild" in info:
        raise ValueError("A review build cannot be released")


def verify_bundle(bundle, identity, with_widget=False):
    paths = [Path(bundle) / "Contents/Info.plist"]
    if with_widget:
        paths.append(Path(bundle) / "Contents/PlugIns/LLMUsageWidget.appex/Contents/Info.plist")
    for path in paths:
        validate_info(plistlib.loads(path.read_bytes()), identity)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    action = parser.add_mutually_exclusive_group()
    action.add_argument("--write-template", nargs=2, metavar=("TEMPLATE", "OUTPUT"))
    action.add_argument("--verify-bundle", type=Path)
    parser.add_argument("--with-widget", action="store_true")
    args = parser.parse_args()
    channel = "development"
    if args.verify_bundle:
        channel = plistlib.loads((args.verify_bundle / "Contents/Info.plist").read_bytes())["UsageUpdateChannel"]
    identity = build_identity(channel=os.environ.get("LLM_UPDATE_CHANNEL", channel), overrides=os.environ)
    if args.write_template:
        source, output = map(Path, args.write_template)
        info = plistlib.loads(source.read_bytes())
        info.update(version_fields(identity))
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_bytes(plistlib.dumps(info))
    elif args.verify_bundle:
        verify_bundle(args.verify_bundle, identity, args.with_widget)
        print("PASS Bundle version and source identity match Git")
    else:
        print(json.dumps(identity))


if __name__ == "__main__":
    main()
