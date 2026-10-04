#!/bin/bash
# Install an already built development app without altering macOS security settings.
set -euo pipefail
cd "$(dirname "$0")/.."
SOURCE="$PWD/build/LLM Usage.app"
DESTINATION="$HOME/Applications/LLM Usage.app"
REGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
python3 Scripts/install_bundle.py "$SOURCE" "$DESTINATION"
# WidgetKit may keep the old extension executable alive after its bundle is replaced.
# That process still advertises the old version, so the new timeline is rejected.
# Stop only this installed extension; macOS will launch the replacement on demand.
python3 - "$DESTINATION/Contents/PlugIns/LLMUsageWidget.appex/Contents/MacOS/LLMUsageWidget" <<'PY'
import os
import signal
import subprocess
import sys

executable = sys.argv[1]
processes = subprocess.check_output(["/bin/ps", "-axo", "pid=,comm="], text=True)
for line in processes.splitlines():
    fields = line.strip().split(None, 1)
    if len(fields) == 2 and fields[1] == executable:
        try:
            os.kill(int(fields[0]), signal.SIGTERM)
            print("Stopped the previous installed widget process")
        except ProcessLookupError:
            pass
PY
# Register only the installed copy so the gallery does not select a build-directory duplicate.
"$REGISTER" -u "$SOURCE"
"$REGISTER" -f "$DESTINATION"
/usr/bin/pluginkit -a "$DESTINATION/Contents/PlugIns/LLMUsageWidget.appex"
printf 'Installed: %s\nQuit the old running copy and open this app, then check Edit Widgets → LLM Usage.\n' "$DESTINATION"
