#!/usr/bin/env python3
"""Publish a complete release; safely resume a failed draft or an existing release."""
import json
import os
from pathlib import Path
import re
import subprocess


def api(endpoint, method="GET", payload=None, missing_ok=False):
    command = ["gh", "api", endpoint, "--method", method]
    if payload is not None:
        command += ["--input", "-"]
    result = subprocess.run(command, input=json.dumps(payload) if payload is not None else None,
                            capture_output=True, text=True)
    if result.returncode:
        if missing_ok and "(HTTP 404)" in result.stderr:
            return None
        raise RuntimeError(result.stderr.strip())
    return json.loads(result.stdout)


def main():
    repository = os.environ["GITHUB_REPOSITORY"]
    commit = os.environ["GITHUB_SHA"]
    tag = os.environ["RELEASE_TAG"]
    if os.environ["GITHUB_REF"] != "refs/heads/main":
        raise SystemExit("Releases must run from main")
    if not re.fullmatch(r"v[0-9]+\.[0-9]+(?:\.[0-9]+)?", tag):
        raise SystemExit("Invalid release tag")
    root = f"repos/{repository}"
    existing_tag = api(f"{root}/git/ref/tags/{tag}", missing_ok=True)
    if existing_tag and existing_tag["object"]["sha"] != commit:
        raise SystemExit("Release tag already points at another commit; refusing to overwrite it")
    release = api(f"{root}/releases/tags/{tag}", missing_ok=True)
    if release and not release["draft"]:
        print(f"Release already published: {release['html_url']}")
        return
    assets = [Path(f"build/release/LLM-Usage-{tag}-macOS-arm64.zip"), Path("build/release/SHA256SUMS.txt")]
    if not all(asset.is_file() and asset.stat().st_size for asset in assets):
        raise SystemExit("Release ZIP or checksum is missing")
    if release is None:
        notes = Path("docs/release-notes.md").read_text()
        release = api(f"{root}/releases", "POST", {
            "tag_name": tag, "target_commitish": commit, "name": f"LLM Usage {tag[1:]}",
            "body": notes, "generate_release_notes": True, "draft": True,
        })
    # Upload while still a draft, so users never see a release without its assets.
    subprocess.run(["gh", "release", "upload", tag, *map(str, assets),
                    "--repo", repository, "--clobber"], check=True)
    # GitHub chooses Latest by semantic version, even if two runs finish out of order.
    release = api(f"{root}/releases/{release['id']}", "PATCH", {
        "draft": False, "make_latest": "legacy",
    })
    print(f"Published: {release['html_url']}")


if __name__ == "__main__":
    main()
