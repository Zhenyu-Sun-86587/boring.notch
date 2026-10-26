#!/usr/bin/env python3
"""Compare old/new window hosts using actual ordered, non-key panels far outside every screen.

The baseline is a separate child: a layout SIGABRT is evidence, never allowed to stop the
production run. Logs distinguish a reproduced anomaly from an inconclusive baseline.
No installed app, real user window, clipboard, focus or permission is touched.
"""
from pathlib import Path
import os
import platform
import resource
import subprocess
import tempfile


def no_core_dump():
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))


def main():
    if platform.system() != 'Darwin' or platform.machine() != 'arm64':
        raise SystemExit('Ordered window checks require ARM64 macOS with the macOS 27 SDK')
    root = Path(__file__).resolve().parents[2]
    evidence = root / 'build/ordered-window-checks'
    evidence.mkdir(parents=True, exist_ok=True)
    sources = [root / 'boringNotch/Hermes/NotchHostingView.swift', root / '.github/scripts/OrderedWindowLayoutChecks.swift']
    with tempfile.TemporaryDirectory(prefix='boring-ordered-layout-') as temporary:
        executable = Path(temporary) / 'OrderedWindowLayoutChecks'
        subprocess.run(['xcrun', '--sdk', 'macosx', 'swiftc', '-parse-as-library', '-swift-version', '5',
                        '-target', 'arm64-apple-macos27.0', *map(str, sources), '-o', str(executable)],
                       cwd=root, check=True, timeout=120)
        results = {}
        for mode in ['baseline', 'production']:
            log = evidence / f'{mode}.log'
            environment = dict(os.environ, NSUnbufferedIO='YES')
            with log.open('w') as output:
                try:
                    run = subprocess.run([str(executable), '--' + mode], cwd=root, env=environment,
                                         stdout=output, stderr=subprocess.STDOUT, timeout=35, preexec_fn=no_core_dump)
                    results[mode] = run.returncode
                except subprocess.TimeoutExpired:
                    results[mode] = 'timeout'
            text = log.read_text()
            for line in text.splitlines():
                if line.startswith(('ORDERED ', 'RESULT ', 'PASS ', 'BASELINE_', 'FAIL ')):
                    print(line)
            print(f'{mode}: exit={results[mode]}; evidence={log}')
            if mode == 'production' and results[mode] != 0:
                raise SystemExit('Production ordered window check failed; inspect its saved log')
        baseline = (evidence / 'baseline.log').read_text()
        if results['baseline'] == 2 and 'BASELINE_ANOMALY_OBSERVED' in baseline:
            print('Verified comparison: old direct-host geometry anomaly reproduced; production container passed.')
        elif isinstance(results['baseline'], int) and results['baseline'] < 0:
            print('Baseline crashed independently; production container passed. Inspect baseline log for matching layout evidence.')
        else:
            print('Production container passed, but the old direct-host anomaly was not reproduced; do not claim the original crash excluded.')


if __name__ == '__main__':
    main()
