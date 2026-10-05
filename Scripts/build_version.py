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
    if git(repository, "rev-parse", "--is-shallow-repository") != "false":
        raise ValueError("Versioning requires full Git history and tags; fetch with --unshallow --tags")
    config = json.loads((Path(repository) / ".github/release.json").read_text())
    commit = git(repository, "rev-parse", "HEAD")
    dirty = bool(git(repository, "status", "--porcelain", "--untracked-files=normal"))
    if channel == "release":
        if dirty:
            raise ValueError("Release builds require a clean source tree")
        version_commit = commit
        version = release_version(repository, config, commit)
    else:
        # Branch commits are squashed before release. Do not invent future release
        # numbers by counting those intermediate commits or reading a moving latest URL.
        tag = git(repository, "describe", "--tags", "--first-parent", "--match", "v[0-9]*", "--abbrev=0", commit)
        version_commit = git(repository, "rev-parse", tag + "^{commit}")
        version = release_version(repository, config, version_commit)
        if tag != version["tag"]:
            raise ValueError("Base release tag disagrees with the release version calculation")
    for key, field in (("MARKETING_VERSION", "version"), ("CURRENT_PROJECT_VERSION", "build")):
        supplied = (overrides or {}).get(key)
        if supplied and supplied != version[field]:
            raise ValueError(f"{key} is derived from Git; refusing conflicting override {supplied!r}")
    return dict(version, commit=commit, versionCommit=version_commit, dirty=dirty, channel=channel)


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
