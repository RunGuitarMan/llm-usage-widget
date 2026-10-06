#!/usr/bin/env python3
"""Identity of the one built app; launchers never compile, copy or re-sign it."""
import argparse
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def sha256(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def source_identity(root=ROOT):
    names = subprocess.check_output(['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z'], cwd=root).decode().split('\0')
    inputs = [name for name in set(names) if name.startswith(('LLMUsage/', 'Scripts/', 'Configuration/')) or name == '.github/release.json']
    digest = hashlib.sha256()
    for name in sorted(inputs):
        path = root / name
        if not path.is_file():
            raise ValueError(f'Missing build input: {name}')
        digest.update(name.encode() + b'\0' + path.read_bytes() + b'\0')
    return {'commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip(),
            'sourceSHA256': digest.hexdigest()}


def bundle_files(app):
    result = {}
    for directory, dirs, files in os.walk(app, followlinks=False):
        for name in sorted(dirs + files):
            path = Path(directory) / name
            relative = str(path.relative_to(app))
            if path.is_symlink():
                result[relative] = {'link': os.readlink(path)}
            elif path.is_file():
                result[relative] = {'sha256': sha256(path), 'executable': bool(path.stat().st_mode & 0o111)}
    return result


def record(app, manifest, expected):
    if source_identity() != expected:
        raise ValueError('Sources changed during the build; build again before testing')
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    executable = app / 'Contents/MacOS' / info['CFBundleExecutable']
    value = dict(expected, schema=1, bundleID=info['CFBundleIdentifier'],
                 version=info['CFBundleShortVersionString'], build=info['CFBundleVersion'],
                 executableSHA256=sha256(executable), files=bundle_files(app))
    manifest.write_text(json.dumps(value, indent=2, sort_keys=True) + '\n')
    return value


def verify(app, manifest, current_sources=True):
    value = json.loads(manifest.read_text())
    if value.get('schema') != 1:
        raise ValueError('Unknown app artifact manifest')
    if current_sources and any(value[key] != item for key, item in source_identity().items()):
        raise ValueError('App is stale: run bash Scripts/build-local.sh, then repeat the check')
    if bundle_files(app) != value['files']:
        raise ValueError('App differs from the built artifact (including its widget/signatures); rebuild it')
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if info['CFBundleIdentifier'] != value['bundleID'] or '.ManualReview' in value['bundleID']:
        raise ValueError('Expected the common app identity, not a separate review bundle')
    return value


def processes(app):
    executable = str(app / 'Contents/MacOS/LLM Usage')
    for line in subprocess.check_output(['ps', '-axo', 'pid=,args='], text=True).splitlines():
        fields = line.strip().split(None, 1)
        if len(fields) == 2 and (fields[1] == executable or fields[1].startswith(executable + ' ')):
            yield int(fields[0]), fields[1]


@contextmanager
def artifact_lock(root=ROOT):
    path = root / 'build/.app-artifact.lock'
    try:
        path.mkdir()
    except FileExistsError:
        raise ValueError('The common app is being built or checked; finish that operation first')
    try:
        yield
    finally:
        path.rmdir()


@contextmanager
def ui_check_lock():
    # Serialize GUI automation across worktrees; app-specific build locks cannot.
    path = Path(tempfile.gettempdir()) / 'llmusage-ui-check.lock'
    try:
        path.mkdir()
    except FileExistsError:
        raise ValueError(f'Another UI check is running on this Mac: {path}')
    try:
        yield
    finally:
        path.rmdir()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['inputs', 'record', 'verify', 'idle'])
    parser.add_argument('--app', type=Path, default=ROOT / 'build/LLM Usage.app')
    parser.add_argument('--manifest', type=Path, default=ROOT / 'build/app-artifact.json')
    parser.add_argument('--inputs', type=Path)
    args = parser.parse_args()
    app = args.app.resolve()
    if args.action == 'inputs':
        args.inputs.write_text(json.dumps(source_identity()))
    elif args.action == 'record':
        record(app, args.manifest, json.loads(args.inputs.read_text()))
    elif args.action == 'verify':
        value = verify(app, args.manifest)
        print(f"PASS Common app artifact: {value['bundleID']} {value['version']}; SHA-256 {value['executableSHA256']}")
    elif list(processes(app)):
        raise ValueError(f'Close the running app before replacing its bundle: {app}')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError) as error:
        raise SystemExit(str(error))
