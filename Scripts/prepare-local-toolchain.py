#!/usr/bin/env python3
"""Prepare project-local Apple CLT 26.6 + SDK 26.5; never run installer scripts.

Downloads ~800 MB, expands ~4 GB under ignored build/AppleTools26. This is optional:
a system Xcode/CLT 26+ selected through DEVELOPER_DIR works with the same scripts.
Sources: Apple's Software Update catalog, product 140-17812. Requires macOS 26.2+.
"""
import concurrent.futures
import json
from pathlib import Path
import subprocess

PACKAGES = [{'name': 'CLTools_Executables_Universal.pkg',
  'size': 775796124,
  'url': 'https://swcdn.apple.com/content/downloads/33/19/140-17812-A_21ZLMMLY4E/zu3xwktttpoe71qiawhzgzvqss6rovawsa/CLTools_Executables_Universal.pkg'},
 {'name': 'CLTools_macOSNMOS_SDK.pkg',
  'size': 61622368,
  'url': 'https://swcdn.apple.com/content/downloads/33/19/140-17812-A_21ZLMMLY4E/zu3xwktttpoe71qiawhzgzvqss6rovawsa/CLTools_macOSNMOS_SDK.pkg'}]
ROOT = Path(__file__).resolve().parent.parent / "build/AppleTools26"


def prepare(package):
    archive = ROOT / package["name"]
    expanded = ROOT / (package["name"] + ".expanded")
    if expanded.joinpath("Payload/Library/Developer/CommandLineTools").is_dir():
        return
    if not archive.exists() or archive.stat().st_size != package["size"]:
        subprocess.run(["curl", "-fL", "--retry", "2", "--max-time", "600", package["url"], "-o", str(archive)], check=True)
    if archive.stat().st_size != package["size"]:
        raise RuntimeError("Package size mismatch: " + package["name"])
    signature = subprocess.run(["pkgutil", "--check-signature", str(archive)], capture_output=True, text=True, check=True)
    if "signed Apple Software" not in signature.stdout or "Apple Root CA" not in signature.stdout:
        raise RuntimeError("Expected an Apple-signed package: " + package["name"])
    print(signature.stdout)
    subprocess.run(["pkgutil", "--expand-full", str(archive), str(expanded)], check=True)


def link(path, target):
    if not path.exists() and not path.is_symlink():
        path.symlink_to(target, target_is_directory=True)


def main():
    version = tuple(map(int, subprocess.check_output(["sw_vers", "-productVersion"], text=True).strip().split(".")))
    if version < (26, 2):
        raise SystemExit("Apple CLT 26.6 requires macOS 26.2 or newer.")
    ROOT.mkdir(parents=True, exist_ok=True)
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        list(pool.map(prepare, PACKAGES))
    toolchain = ROOT / "CLTools_Executables_Universal.pkg.expanded/Payload/Library/Developer/CommandLineTools"
    sdk = ROOT / "CLTools_macOSNMOS_SDK.pkg.expanded/Payload/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
    (toolchain / "SDKs").mkdir(exist_ok=True)
    link(ROOT / "CommandLineTools", toolchain)
    link(toolchain / "SDKs/MacOSX.sdk", sdk)
    link(toolchain / "SDKs/MacOSX26.5.sdk", sdk)
    (ROOT / "download-manifest.json").write_text(json.dumps(PACKAGES, indent=2) + "\n")
    subprocess.run([str(toolchain / "usr/bin/swiftc"), "--version"], check=True)
    print("Ready: " + str(ROOT / "CommandLineTools"))


if __name__ == "__main__":
    main()
