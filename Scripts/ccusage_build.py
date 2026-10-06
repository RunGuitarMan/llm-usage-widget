"""Build our narrow Claude patch from checksum-locked upstream inputs."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def checked_patch(root, spec):
    path = root / spec["patch"]["path"]
    if digest(path) != spec["patch"]["sha256"]:
        raise ValueError("ccusage patch checksum mismatch; review and update the lock")
    return path


def verify_built(directory, spec):
    receipt = json.loads((directory / "build-receipt.json").read_text())
    expected_inputs = hashlib.sha256(json.dumps(spec, sort_keys=True).encode()).hexdigest()
    if receipt["inputsSHA256"] != expected_inputs or receipt["binarySHA256"] != digest(directory / "package/bin/ccusage"):
        raise ValueError("ccusage build receipt mismatch")


def build_ccusage(root, spec, destination, cache, download, extract):
    patch = checked_patch(root, spec)

    def archive(item):
        path = cache / (item["sha256"] + ".archive")
        download(item["url"], path, "sha256", item["sha256"])
        return path

    toolchain = cache / ("rust-" + spec["rust"]["version"])
    # Toolchain components are cached as verified archives; a toolchain receipt
    # seals all installed files, just like the outer dependency cache.
    from importlib.util import module_from_spec, spec_from_file_location
    module_spec = spec_from_file_location("locked_dependencies", root / "Scripts/prepare-dependencies.py")
    dependencies = module_from_spec(module_spec)
    module_spec.loader.exec_module(dependencies)
    if not (toolchain / "ready").is_file() or (toolchain / "ready").read_text() != dependencies.contents_digest(toolchain):
        if toolchain.exists():
            shutil.rmtree(toolchain)
        toolchain.mkdir()
        for item in spec["rust"]["components"]:
            with tempfile.TemporaryDirectory(dir=cache) as temporary:
                stage = Path(temporary)
                extract(archive(item), stage)
                package = next(stage.iterdir())
                subprocess.run(["bash", str(package / "install.sh"), "--prefix=" + str(toolchain),
                                "--disable-ldconfig"], check=True, stdout=subprocess.DEVNULL)
        (toolchain / "ready").write_text(dependencies.contents_digest(toolchain))
    source = destination / "source"
    source.mkdir(parents=True)
    extract(archive(spec["source"]), source)
    tree = next(source.iterdir())
    subprocess.run(["/usr/bin/patch", "--batch", "--fuzz=0", "-p1", "-i", str(patch)], cwd=tree, check=True,
                   stdout=subprocess.DEVNULL)
    pricing = archive(spec["pricing"])
    environment = dict(os.environ, PATH=str(toolchain / "bin") + ":/usr/bin:/bin:/usr/sbin:/sbin",
                       CARGO_HOME=str(cache / "cargo"), CARGO_TARGET_DIR=str(cache / "ccusage-target"),
                       CCUSAGE_PRICING_JSON_PATH=str(pricing), CCUSAGE_VERSION=spec["version"],
                       MACOSX_DEPLOYMENT_TARGET="14.0",
                       RUSTFLAGS="--remap-path-prefix=" + str(tree) + "=/ccusage " +
                                 "--remap-path-prefix=" + str(cache) + "=/ccusage-build")
    for key in ("CARGO_ENCODED_RUSTFLAGS", "RUSTC", "RUSTDOC", "RUSTC_WRAPPER", "RUSTC_WORKSPACE_WRAPPER"):
        environment.pop(key, None)
    subprocess.run([str(toolchain / "bin/cargo"), "build", "--locked", "--release", "--manifest-path",
                    str(tree / "rust/Cargo.toml"), "-p", "ccusage"], env=environment, check=True)
    binary = destination / "package/bin/ccusage"
    binary.parent.mkdir(parents=True)
    shutil.copy2(cache / "ccusage-target/release/ccusage", binary)
    version = subprocess.check_output([str(binary), "--version"], text=True).strip()
    if version != "ccusage " + spec["version"]:
        raise ValueError("Built ccusage version mismatch")
    receipt = {"inputsSHA256": hashlib.sha256(json.dumps(spec, sort_keys=True).encode()).hexdigest(),
               "binarySHA256": digest(binary), "sourceCommit": spec["source"]["commit"],
               "patchSHA256": spec["patch"]["sha256"], "rustVersion": spec["rust"]["version"]}
    (destination / "build-receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    shutil.rmtree(source)
    verify_built(destination, spec)
