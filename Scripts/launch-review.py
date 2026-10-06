#!/usr/bin/env python3
"""Launch and verify the same immutable .app in normal or runtime review mode."""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import uuid
from app_artifact import ROOT, artifact_lock, processes, ui_check_lock, verify


def stop(pid):
    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return
        time.sleep(.1)
    raise ValueError(f'App process {pid} did not stop')


def launch(args):
    app = args.app.resolve()
    manifest = args.manifest or app.parent / 'app-artifact.json'
    identity = verify(app, manifest)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    for pid, command in processes(app):
        if '--review-launch-token ' not in command:
            raise ValueError('The common app is already open normally. Close it before starting review.')
        stop(pid)
    normal = args.normal_smoke
    report = ROOT / ('build/manual-review/normal-report' if normal else 'build/manual-review/check-report' if (args.self_check or args.widget_check) else 'build/UIReview')
    if not normal and not (args.self_check or args.widget_check) and os.environ.get('LLM_REVIEW_REPORT_DIR'):
        report = Path(os.environ['LLM_REVIEW_REPORT_DIR']).expanduser().resolve()
    report.mkdir(parents=True, exist_ok=True)
    receipt = report / 'launch.json'
    receipt.unlink(missing_ok=True)
    token = str(uuid.uuid4())
    exe = app / 'Contents/MacOS/LLM Usage'
    options = ['--demo'] if normal else ['--review']
    options += ['--review-report-dir', str(report), '--review-launch-token', token]
    if (args.self_check or args.widget_check):
        options.append('--review-widget-check' if args.widget_check else '--review-self-check')
    fd, name = tempfile.mkstemp(prefix='llm-usage-review-', suffix='.log')
    os.close(fd)
    log = Path(name)
    subprocess.run(['/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister', '-f', str(app)], check=True)
    subprocess.run(['open', '-n', '-F', '-a', str(app), '--stdout', str(log), '--stderr', str(log), '--args', *options],
                   stdin=subprocess.DEVNULL, check=True)
    pid = None
    try:
        started = time.monotonic()
        deadline = started + 30
        reopened = False
        while time.monotonic() < deadline:
            # Menu-bar apps can finish launching without an initial open event.
            # Ask the same registered app to reopen via its ordinary scene route.
            if not reopened and time.monotonic() - started > 1:
                subprocess.run(['open', '-a', str(app)], check=True, stdin=subprocess.DEVNULL)
                reopened = True
            if receipt.exists():
                result = json.loads(receipt.read_text())
                if result.get('token') == token:
                    matches = (result.get('executable') == str(exe) and result.get('executableSHA256') == identity['executableSHA256']
                               and result.get('bundleID') == identity['bundleID'] and result.get('appRoot') is True
                               and result.get('review') == (not normal) and result.get('alpha') == 1
                               and result.get('toolbarControls', 0) > 0)
                    if not matches:
                        raise ValueError(f'Wrong application/mode or incomplete dashboard: {result}')
                    candidate = result.get('pid')
                    if any(p == candidate and token in command for p, command in processes(app)):
                        pid = candidate
                        break
            time.sleep(.1)
        if pid is None:
            raise ValueError(f'App did not confirm the expected binary and dashboard. See {report / "app.log" if normal or (args.self_check or args.widget_check) else log}')
        print(f"Confirmed SAME app: {app}; PID {pid}; SHA-256 {identity['executableSHA256']}; review={not normal}", flush=True)
        if normal:
            stop(pid)
            print('PASS Normal launch uses the common executable without activating the review catalogue')
        elif (args.self_check or args.widget_check):
            deadline = time.monotonic() + 600
            while time.monotonic() < deadline:
                try:
                    os.kill(pid, 0)
                except ProcessLookupError:
                    break
                time.sleep(.2)
            else:
                raise ValueError('Review self-check timed out')
            output = log.read_text()
            (report / 'app.log').write_text(output)
            print(output)
            marker = 'PASS Widget checks in common app' if args.widget_check else 'PASS Manual review: production App/Scene'
            if marker not in output:
                raise ValueError('App self-check failed')
        verify(app, manifest)
        (report / 'artifact.json').write_text(json.dumps({k: v for k, v in identity.items() if k != 'files'}, indent=2) + '\n')
        print('PASS App bundle and its embedded widget remained byte-for-byte unchanged')
    except BaseException:
        for candidate, command in processes(app):
            if token in command:
                stop(candidate)
        raise
    finally:
        if normal or (args.self_check or args.widget_check):
            (report / 'app.log').write_text(log.read_text())
            log.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument('--self-check', action='store_true')
    modes.add_argument('--widget-check', action='store_true', help='Focused provider and mapped-process regression checks in the common app')
    modes.add_argument('--normal-smoke', action='store_true', help='Same normal startup, with demo data to avoid reading user logs')
    parser.add_argument('--app', type=Path, default=ROOT / 'build/LLM Usage.app')
    parser.add_argument('--manifest', type=Path)
    args = parser.parse_args()
    with artifact_lock(), ui_check_lock():
        launch(args)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        raise SystemExit(str(error))
