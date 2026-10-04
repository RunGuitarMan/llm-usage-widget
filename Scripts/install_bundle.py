"""Install a verified local bundle; registration is handled by install-local.sh."""
import plistlib
from pathlib import Path
import fcntl
import shutil
import subprocess
import sys
import tempfile


def verify_bundle(bundle):
    subprocess.run([sys.executable, str(Path(__file__).with_name("verify-bundle.py")), str(bundle)], check=True)


def bundle_id(bundle):
    with (bundle / "Contents/Info.plist").open("rb") as source:
        return plistlib.load(source)["CFBundleIdentifier"]


def install(source, destination, verify=verify_bundle):
    source, destination = Path(source), Path(destination)
    verify(source)
    destination.parent.mkdir(parents=True, exist_ok=True)
    # Serialize installers through a stable lock inode, including initial installs.
    with (destination.parent / f".{destination.name}.install.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if destination.is_symlink() or source.resolve() == destination.resolve():
            raise ValueError("Source and destination must be distinct bundles; destination cannot be a symlink")
        if destination.exists() and bundle_id(source) != bundle_id(destination):
            raise ValueError(f"Refusing to replace an app with a different bundle identifier: {destination}")
        work = Path(tempfile.mkdtemp(prefix=f".{destination.name}.install-", dir=destination.parent))
        staged, previous = work / destination.name, work / "previous.app"
        committed = False
        try:
            # ditto merges directories. Copy into an empty staging path so removed
            # resources cannot survive the upgrade or invalidate the code signature.
            subprocess.run(["/usr/bin/ditto", str(source), str(staged)], check=True)
            verify(staged)
            if destination.exists():
                destination.rename(previous)
            try:
                staged.rename(destination)
            except BaseException:
                if previous.exists():
                    try:
                        previous.rename(destination)
                    except OSError as error:
                        raise RuntimeError(f"Cannot restore previous installation; preserved at {previous}") from error
                raise
            committed = True
        finally:
            # Never delete the recovery copy if rollback itself failed.
            if committed or not previous.exists():
                shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    install(*sys.argv[1:])
