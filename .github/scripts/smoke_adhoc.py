#!/usr/bin/env python3
"""Launch the actual signed app in its noninteractive CI diagnostic mode."""
import json
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import sys

app = Path(sys.argv[1]).resolve(strict=True)
with (app / 'Contents/Info.plist').open('rb') as source:
    info = plistlib.load(source)
executable = app / 'Contents/MacOS' / info['CFBundleExecutable']
process = subprocess.Popen(
    [str(executable), '--island-smoke-test', '-AppleLanguages', '(zh-Hans)', '-firstLaunch', 'NO'],
    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, start_new_session=True)
try:
    output, _ = process.communicate(timeout=25)
except subprocess.TimeoutExpired:
    os.killpg(process.pid, signal.SIGTERM)
    output, _ = process.communicate(timeout=5)
    Path('build/startup-report.txt').write_text(output + '\nFAILED: startup timeout\n')
    raise SystemExit('Packaged application or XPC helper did not respond')
Path('build/startup-report.txt').write_text(output)
assert process.returncode == 0, f'Packaged app exited {process.returncode}; see startup-report.txt'
line = next((line for line in output.splitlines() if line.startswith('ISLAND_SMOKE ')), None)
assert line, 'Packaged app never reached its startup diagnostic'
result = json.loads(line.removeprefix('ISLAND_SMOKE '))
assert result['status'] == 'ready' and result['helperAvailable'], result
assert result['hermes'] is True and result['version'] == '2.8-rc.2', result
assert any('\u3400' <= c <= '\u9fff' for c in result['localizedGeneral']), result
assert result['calendarUsage'] and result['reminderUsage'], result
print('PASS: signed ARM64 app launches, XPC replies, Chinese resources and EventKit usage keys present')
