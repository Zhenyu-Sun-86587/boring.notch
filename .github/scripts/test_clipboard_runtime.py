#!/usr/bin/env python3
"""Causal XPC runtime check: process metadata only, no permission requests or UI/input."""
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import uuid

root = Path(__file__).resolve().parents[2]
source = root / '.github/scripts/ClipboardRuntimeChecks.swift'
runtime = root / 'Shared/ClipboardPasteEvent.swift'
entry = (root / 'BoringNotchXPCHelper/main.swift').read_text()
assert entry.index('ClipboardHelperRuntime.prepare()') < entry.index('let delegate = ServiceDelegate()')
report = root / 'build/clipboard-runtime-report.txt'
report.parent.mkdir(exist_ok=True)
compiler = ['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '5',
            '-target', 'arm64-apple-macos27.0', '-D', 'CLIPBOARD_EVENT_FIXTURE']

def run(args):
    subprocess.run(list(map(str, args)), check=True, timeout=120)

def plist(path, data):
    path.write_bytes(plistlib.dumps(data))

with tempfile.TemporaryDirectory(prefix='boring-runtime-') as temporary:
    work = Path(temporary)
    identifier = 'com.boringnotch.fixture.runtime.' + uuid.uuid4().hex
    app = work / 'Runtime Fixture.app'
    macos = app / 'Contents/MacOS'
    macos.mkdir(parents=True)
    plist(app / 'Contents/Info.plist', {'CFBundleIdentifier': identifier, 'CFBundleExecutable': 'RuntimeHost',
        'CFBundlePackageType': 'APPL', 'LSUIElement': True})
    run(compiler + [runtime, source, '-o', macos / 'RuntimeHost'])
    for name, flags in [('Helper', []), ('ColdHelper', ['-D', 'RUNTIME_COLD_START'])]:
        helper = app / f'Contents/XPCServices/{name}.xpc'
        helper_macos = helper / 'Contents/MacOS'
        helper_macos.mkdir(parents=True)
        plist(helper / 'Contents/Info.plist', {'CFBundleIdentifier': identifier + '.' + name,
            'CFBundleExecutable': 'RuntimeHelper', 'CFBundlePackageType': 'XPC!',
            'XPCService': plistlib.loads((root / 'BoringNotchXPCHelper/Info.plist').read_bytes())['XPCService']})
        run(compiler + ['-D', 'RUNTIME_HELPER', *flags, runtime, source, '-o', helper_macos / 'RuntimeHelper'])
        run(['codesign', '--force', '--sign', '-', helper])
    entitlements = work / 'host.plist'
    plist(entitlements, {'com.apple.security.app-sandbox': True})
    run(['codesign', '--force', '--sign', '-', '--entitlements', entitlements, app])
    run(['codesign', '--verify', '--deep', '--strict', app])
    try:
        with report.open('w') as output:
            for mode in ['baseline', 'cold']:
                result = subprocess.run([macos / 'RuntimeHost', mode], cwd=root, stdout=output, stderr=subprocess.STDOUT, timeout=15)
                if result.returncode:
                    break
        print(report.read_text())
        result.check_returncode()
    finally:
        container = Path.home() / 'Library/Containers' / identifier
        if container.is_dir() and not container.is_symlink():
            shutil.rmtree(container)
