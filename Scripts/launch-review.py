#!/usr/bin/env python3
"""Publish one clean development bundle and verify the exact production app process started."""
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import sys
import time
import tempfile
import uuid

root = Path(__file__).resolve().parent.parent
stage = Path(sys.argv[1]).resolve()
mode = sys.argv[2] if len(sys.argv) > 2 else ''
target = root/'build/manual-review/LLM Usage.app'
legacy = [root/'build'/name for name in [
    'LLM Usage UI Review.app', 'LLM Usage UI Review Final.app', 'LLM Usage Manual Review.app',
    'LLM Usage Chat Preview.app', 'Issue17 Preview.app',
]]
legacy_binaries = [root/'build'/name for name in ['window-checks', 'session-navigation-checks']]
executables = [str(target/'Contents/MacOS/LLM Usage')]
for app in legacy:
    executables += [str(app/'Contents/MacOS'/name) for name in ['UIReview', 'LLMUsageUIReview', 'LLM Usage']]
executables += [str(path) for path in legacy_binaries]
# Stage must contain exactly the executable declared by its plist.
info = plistlib.loads((stage/'Contents/Info.plist').read_bytes())
assert info['CFBundleExecutable'] == 'LLM Usage'
assert sorted(p.name for p in (stage/'Contents/MacOS').iterdir()) == ['LLM Usage']
assert info['CFBundleIdentifier'] == 'local.ClaudeUsage.ManualReview'
# Match complete known executable paths, never the installed app or unrelated processes.
rows = subprocess.check_output(['ps', '-axo', 'pid=,args='], text=True).splitlines()
for row in rows:
    fields = row.strip().split(None, 1)
    if len(fields) != 2:
        continue
    pid, command = fields
    if not any(command == exe or command.startswith(exe+' ') for exe in executables):
        continue
    try:
        os.kill(int(pid), signal.SIGTERM)
    except ProcessLookupError:
        continue
    for _ in range(50):
        try:
            os.kill(int(pid), 0)
        except ProcessLookupError:
            break
        time.sleep(.1)
    else:
        raise SystemExit(f'Review process {pid} did not stop; the bundle was not replaced.')
for app in legacy:
    if app.exists():
        shutil.rmtree(app)
for binary in legacy_binaries:
    binary.unlink(missing_ok=True)
backup = target.with_suffix('.previous')
if backup.exists():
    shutil.rmtree(backup)
if target.exists():
    target.rename(backup)
try:
    stage.rename(target)
except BaseException:
    if backup.exists():
        backup.rename(target)
    raise
if backup.exists():
    shutil.rmtree(backup)
print(f'Built production app with private review controls: {target}', flush=True)
if mode == '--build-only':
    sys.exit(0)
report = root/('build/manual-review/check-report' if mode == '--self-check' else 'build/UIReview')
report.mkdir(parents=True, exist_ok=True)
receipt = report/'launch.json'
receipt.unlink(missing_ok=True)
token = str(uuid.uuid4())
exe = target/'Contents/MacOS/LLM Usage'
args = [str(exe), '--manual-review', '--review-report-dir', str(report), '--review-launch-token', token]
if mode == '--self-check':
    args.append('--review-self-check')
# launchd cannot open stdout paths in TCC-protected Documents on some Macs.
# Its log goes to a private temporary file; copy completed test output into the report.
fd, temporary_log = tempfile.mkstemp(prefix='llm-usage-review-', suffix='.log')
os.close(fd)
log_path = Path(temporary_log)
# LaunchServices sends the normal application-open event required by SwiftUI scenes.
# A fresh, single-executable bundle plus the receipt avoids stale bundle resolution.
subprocess.run(['open', '-n', '-a', str(target), '--stdout', str(log_path),
                '--stderr', str(log_path), '--args', *args[1:]],
               stdin=subprocess.DEVNULL, check=True)
app_pid = None
for attempt in range(200):
    if attempt == 10:
        # Agent applications may need a reopen event to present their existing scene.
        subprocess.run(['open', '-a', str(target)], check=True, stdin=subprocess.DEVNULL)
    if receipt.exists():
        result = json.loads(receipt.read_text())
        candidate = result.get('pid')
        if (result.get('token') == token and result.get('executable') == str(exe)
                and result.get('build') == info['ManualReviewBuild'] and result.get('appRoot') is True
                and isinstance(candidate, int)):
            command = subprocess.check_output(['ps', '-p', str(candidate), '-o', 'args='], text=True).strip()
            if command.startswith(str(exe)+' ') and token in command:
                app_pid = candidate
                print(f'Confirmed production AppRootView: PID {app_pid}, build {result["build"]}', flush=True)
                break
    time.sleep(.1)
else:
    for row in subprocess.check_output(['ps', '-axo', 'pid=,args='], text=True).splitlines():
        fields = row.strip().split(None, 1)
        if len(fields) == 2 and fields[1].startswith(str(exe)+' ') and token in fields[1]:
            os.kill(int(fields[0]), signal.SIGTERM)
    raise SystemExit('App did not confirm the expected executable and production window. See '+str(log_path))
if mode == '--self-check':
    deadline = time.monotonic() + 600
    while time.monotonic() < deadline:
        try:
            os.kill(app_pid, 0)
        except ProcessLookupError:
            break
        time.sleep(.2)
    else:
        os.kill(app_pid, signal.SIGTERM)
        raise SystemExit('Review self-check timed out')
    output = log_path.read_text()
    (report/'app.log').write_text(output)
    log_path.unlink(missing_ok=True)
    print(output)
    if 'PASS Manual review: production App/Scene' not in output:
        raise SystemExit(1)
