#!/usr/bin/env python3
"""Read the manually selected repository version and enforce strictly increasing PRs."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess

VERSION_FILE = ".github/release.json"


def git(repository, *arguments):
    return subprocess.check_output(
        ["git", "-C", str(repository), *arguments], text=True
    ).strip()


def parse_version(version):
    if not isinstance(version, str) or not re.fullmatch(
        r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)", version
    ):
        raise ValueError("Version must be MAJOR.MINOR.PATCH, without a prefix, suffix or leading zeros")
    return tuple(map(int, version.split(".")))


def configured_version(config):
    if not isinstance(config, dict) or set(config) != {"version"}:
        raise ValueError(f'{VERSION_FILE} must contain exactly {{"version": "MAJOR.MINOR.PATCH"}}')
    parse_version(config["version"])
    return config["version"]


def require_full_history(repository):
    if git(repository, "rev-parse", "--is-shallow-repository") != "false":
        raise ValueError("Versioning requires full Git history; fetch with --unshallow")


def release_version(repository, config=None, revision="HEAD"):
    require_full_history(repository)
    if config is None:
        config = json.loads((Path(repository) / VERSION_FILE).read_text())
    version = configured_version(config)
    build = git(repository, "rev-list", "--first-parent", "--count", revision)
    return {"version": version, "tag": f"v{version}", "build": build}


def previous_version(repository, revision):
    config = json.loads(git(repository, "show", f"{revision}:{VERSION_FILE}"))
    if isinstance(config, dict) and set(config) == {"base_version", "base_commit"}:
        # Migration only: compare the first manual-version PR with the old main.
        # Builds themselves never infer a version from titles or release tags.
        major, minor, patch = parse_version(config["base_version"])
        base = config["base_commit"]
        if not isinstance(base, str) or not re.fullmatch(r"[0-9a-f]{40}", base):
            raise ValueError("Invalid legacy version baseline")
        history = git(repository, "rev-list", "--first-parent", revision).splitlines()
        if base not in history:
            raise ValueError("Legacy baseline is not on the target branch's first-parent history")
        for commit in reversed(history[:history.index(base)]):
            title = git(repository, "show", "-s", "--format=%s", commit)
            match = re.fullmatch(
                r"(feat|fix|docs|refactor|perf|test|build|ci|chore|revert)(?:\([^()\r\n]+\))?: [^\s][^\r\n]*", title
            )
            if not match:
                raise ValueError(f"Cannot read the legacy version at {revision}: unsupported title {title!r}")
            if match[1] == "feat":
                minor, patch = minor + 1, 0
            else:
                patch += 1
        return f"{major}.{minor}.{patch}"
    return configured_version(config)


def check_increase(repository, base):
    current = release_version(repository)
    previous = previous_version(repository, base)
    if parse_version(current["version"]) <= parse_version(previous):
        raise ValueError(
            f'Every PR must increase {VERSION_FILE}: {current["version"]} must be greater than {previous}. '
            "Update your branch from main and choose a higher version."
        )
    return current


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--github-output", action="store_true")
    parser.add_argument("--check-increase", metavar="BASE_COMMIT", help="Require a version above the PR base or previous main")
    args = parser.parse_args()
    repository = Path(__file__).resolve().parent.parent
    result = check_increase(repository, args.check_increase) if args.check_increase else release_version(repository)
    print(json.dumps(result))
    if args.github_output:
        with open(os.environ["GITHUB_OUTPUT"], "a") as output:
            for key, value in result.items():
                output.write(f"{key}={value}\n")


if __name__ == "__main__":
    main()
