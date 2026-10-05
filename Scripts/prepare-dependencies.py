#!/usr/bin/env python3
"""Fetch only locked build inputs. End users never need a package manager."""
import fcntl
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def contents_digest(directory):
    entries = {}
    for path in sorted(directory.rglob("*")):
        name = path.relative_to(directory).as_posix()
        if name == "ready":
            continue
        if path.is_symlink():
            entries[name] = "link:" + str(path.readlink())
        elif path.is_file():
            entries[name] = hashlib.sha256(path.read_bytes()).hexdigest()
    return hashlib.sha256(json.dumps(entries, sort_keys=True).encode()).hexdigest()


def download(url, destination, algorithm, expected):
    if not url.startswith("https://"):
        raise ValueError("Dependencies require HTTPS")
    if not destination.exists() or hashlib.new(algorithm, destination.read_bytes()).hexdigest() != expected:
        partial = destination.with_suffix(".partial")
        try:
            subprocess.run(["/usr/bin/curl", "--fail", "--location", "--silent", "--show-error",
                            "--proto", "=https", "--proto-redir", "=https", "--connect-timeout", "15",
                            "--max-time", "180", "--retry", "2", "--output", str(partial), url], check=True)
            if hashlib.new(algorithm, partial.read_bytes()).hexdigest() != expected:
                raise ValueError("Dependency archive checksum mismatch")
            partial.replace(destination)
        finally:
            partial.unlink(missing_ok=True)


def extract(archive, destination):
    # Verified archives can contain framework symlinks, but must stay within staging.
    with tarfile.open(archive) as source:
        for member in source.getmembers():
            path = (destination / member.name).resolve()
            if not path.is_relative_to(destination.resolve()) or member.isdev() or member.isfifo():
                raise ValueError("Unsafe dependency archive entry")
            if member.issym() or member.islnk():
                base = path.parent if member.issym() else destination
                if not (base / member.linkname).resolve().is_relative_to(destination.resolve()):
                    raise ValueError("Unsafe dependency archive link")
        source.extractall(destination, filter="data")


def prepare(root=ROOT):
    manifest = json.loads((root / "Configuration/Dependencies.json").read_text())
    directory = root / "build/Dependencies"
    directory.mkdir(parents=True, exist_ok=True)
    fingerprint = hashlib.sha256((root / "Configuration/Dependencies.json").read_bytes()).hexdigest()
    with (directory / ".lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        ready = directory / fingerprint
        if not (ready / "ready").is_file() or (ready / "ready").read_text() != contents_digest(ready):
            with tempfile.TemporaryDirectory(prefix=".stage-", dir=directory) as temporary:
                stage = Path(temporary)
                for name, algorithm in [("ccusage", "sha512"), ("sparkle", "sha256")]:
                    spec = manifest[name]
                    archive = directory / (spec[algorithm] + ".archive")
                    download(spec["url"], archive, algorithm, spec[algorithm])
                    target = stage / name
                    target.mkdir()
                    extract(archive, target)
                binary = stage / "ccusage/package/bin/ccusage"
                if hashlib.sha256(binary.read_bytes()).hexdigest() != manifest["ccusage"]["binarySHA256"]:
                    raise ValueError("ccusage binary checksum mismatch")
                (stage / "ready").write_text(contents_digest(stage))
                if ready.exists():
                    shutil.rmtree(ready)
                stage.rename(ready)
        # A stable path lets both swiftc and Xcode use the very same framework.
        link = directory / "current"
        staged_link = directory / ".current"
        staged_link.unlink(missing_ok=True)
        staged_link.symlink_to(fingerprint, target_is_directory=True)
        staged_link.replace(link)
    return ready


if __name__ == "__main__":
    print(prepare())
