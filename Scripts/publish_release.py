#!/usr/bin/env python3
"""Publish a complete release; safely resume a failed draft or an existing release."""
import argparse
import json
import os
from pathlib import Path
import subprocess
from release_artifacts import verify_release_assets
from release_version import parse_version


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


def main(check_only=False, github_output=False):
    repository = os.environ["GITHUB_REPOSITORY"]
    commit = os.environ["GITHUB_SHA"]
    tag = os.environ["RELEASE_TAG"]
    if os.environ["GITHUB_REF"] != "refs/heads/main":
        raise SystemExit("Releases must run from main")
    if os.environ.get("GITHUB_EVENT_NAME") != "workflow_dispatch":
        raise SystemExit("Releases require a manual workflow_dispatch run")
    if not tag.startswith("v"):
        raise SystemExit("Invalid release tag")
    version = parse_version(tag[1:])
    root = f"repos/{repository}"
    existing_tag = api(f"{root}/git/ref/tags/{tag}", missing_ok=True)
    if existing_tag and existing_tag["object"]["sha"] != commit:
        raise SystemExit("Release tag already points at another commit; refusing to overwrite it")
    release = api(f"{root}/releases/tags/{tag}", missing_ok=True)
    if release and not release["draft"] and not existing_tag:
        raise SystemExit("Existing release is missing its source tag")
    published = bool(release and not release["draft"])
    if github_output:
        with open(os.environ["GITHUB_OUTPUT"], "a") as output:
            output.write(f"published={str(published).lower()}\n")
    if published:
        print(f"Release already published: {release['html_url']}")
        return
    latest = api(f"{root}/releases/latest", missing_ok=True)
    if latest:
        latest_tag = latest["tag_name"]
        if not latest_tag.startswith("v") or version <= parse_version(latest_tag[1:]):
            raise SystemExit(f"Release {tag} must be greater than the latest published release {latest_tag}")
    if check_only:
        print(f"Ready to publish {tag} from {commit}")
        return
    assets = [Path(f"build/release/LLM-Usage-{tag}-macOS-arm64.zip"), Path("build/release/SHA256SUMS.txt"), Path("build/release/appcast.xml")]
    if not all(asset.is_file() and asset.stat().st_size for asset in assets):
        raise SystemExit("Release ZIP, checksum, or signed appcast is missing")
    # Validate the actual ZIP and feed before any create/upload/publish mutation.
    verify_release_assets(tag, commit, repository)
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
        "draft": False, "make_latest": "legacy", "name": f"LLM Usage {tag[1:]}",
    })
    print(f"Published: {release['html_url']}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Read-only publication eligibility check")
    parser.add_argument("--github-output", action="store_true")
    args = parser.parse_args()
    main(check_only=args.check, github_output=args.github_output)
