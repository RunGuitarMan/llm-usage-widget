"""Give the containing app and extension the same content-addressed gallery icon."""
import hashlib
from pathlib import Path
import plistlib
import re
import shutil
import sys


def install_icon(bundle, icon):
    bundle, icon = Path(bundle), Path(icon)
    data = icon.read_bytes()
    if data[:4] != b"icns" or len(data) < 8 or int.from_bytes(data[4:8], "big") != len(data):
        raise ValueError("Expected a complete icns resource")
    name = "LLMUsage-" + hashlib.sha256(data).hexdigest()[:16]
    resources = bundle / "Contents/Resources"
    resources.mkdir(parents=True, exist_ok=True)
    info_path = bundle / "Contents/Info.plist"
    info = plistlib.loads(info_path.read_bytes())
    previous = info.get("CFBundleIconFile")
    shutil.copyfile(icon, resources / (name + ".icns"))
    info["CFBundleIconFile"] = name
    info_path.write_bytes(plistlib.dumps(info))
    # A reused build directory must not retain the obsolete fallback icon.
    if previous and previous != name and "/" not in previous:
        (resources / (previous if previous.endswith(".icns") else previous + ".icns")).unlink(missing_ok=True)
    for old in resources.glob("LLMUsage-*.icns"):
        if old.stem != name and re.fullmatch(r"LLMUsage-[0-9a-f]{16}", old.stem):
            old.unlink()
    return name


if __name__ == "__main__":
    install_icon(*sys.argv[1:])
