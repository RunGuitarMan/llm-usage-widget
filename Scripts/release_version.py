#!/usr/bin/env python3
"""Derive minor/patch releases from squash commit titles after a released baseline."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess


def git(repository, *arguments):
    return subprocess.check_output(
        ["git", "-C", str(repository), *arguments], text=True
    ).strip()


def release_kind(title):
    match = re.fullmatch(
        r"(feat|fix|docs|refactor|perf|test|build|ci|chore|revert)(?:\([^()\r\n]+\))?: [^\s][^\r\n]*", title
    )
    if not match:
        raise ValueError("Use a PR title such as 'feat: add calendar' or 'fix: restore chat navigation' "
                         "(also supported: docs, refactor, perf, test, build, ci, chore, revert)")
    return "minor" if match[1] == "feat" else "patch"


def release_version(repository, config, revision="HEAD"):
    base = config["base_commit"]
    version = config["base_version"]
    if not re.fullmatch(r"[0-9a-f]{40}", base):
        raise ValueError("base_commit must be a full Git commit SHA")
    if not re.fullmatch(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)", version):
        raise ValueError("base_version must be MAJOR.MINOR.PATCH")
    history = git(repository, "rev-list", "--first-parent", revision).splitlines()
    if base not in history:
        raise ValueError("Release baseline must be on the commit's first-parent history")
    major, minor, patch = map(int, version.split("."))
    for commit in reversed(history[:history.index(base)]):
        title = git(repository, "show", "-s", "--format=%s", commit)
        if release_kind(title) == "minor":
            minor, patch = minor + 1, 0
        else:
            patch += 1
    version = f"{major}.{minor}.{patch}"
    return {"version": version, "tag": f"v{version}", "build": str(len(history))}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--github-output", action="store_true")
    parser.add_argument("--check-title", help="Validate a PR title without reading Git history")
    args = parser.parse_args()
    if args.check_title is not None:
        print(release_kind(args.check_title))
        return
    repository = Path(__file__).resolve().parent.parent
    config = json.loads((repository / ".github/release.json").read_text())
    result = release_version(repository, config)
    print(json.dumps(result))
    if args.github_output:
        with open(os.environ["GITHUB_OUTPUT"], "a") as output:
            for key, value in result.items():
                output.write(f"{key}={value}\n")


if __name__ == "__main__":
    main()
