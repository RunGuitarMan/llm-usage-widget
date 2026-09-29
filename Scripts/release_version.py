#!/usr/bin/env python3
"""Derive a stable release version from first-parent commits after a baseline."""
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


def release_version(repository, config, revision="HEAD"):
    base = config["base_commit"]
    version = config["base_version"]
    if not re.fullmatch(r"[0-9a-f]{40}", base):
        raise ValueError("base_commit must be a full Git commit SHA")
    if not re.fullmatch(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:\.(?:0|[1-9][0-9]*))?", version):
        raise ValueError("base_version must be MAJOR.MINOR or MAJOR.MINOR.PATCH")
    history = git(repository, "rev-list", "--first-parent", revision).splitlines()
    if base not in history:
        raise ValueError("Release baseline must be on the commit's first-parent history")
    distance = history.index(base)
    if distance == 0:
        raise ValueError("The baseline itself is not a release; merge a PR first")
    parts = version.split(".")
    patch = (int(parts[2]) if len(parts) == 3 else 0) + distance - 1
    if distance > 1 or len(parts) == 3:
        version = f"{parts[0]}.{parts[1]}.{patch}"
    return {"version": version, "tag": f"v{version}", "build": str(len(history))}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--github-output", action="store_true")
    args = parser.parse_args()
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
