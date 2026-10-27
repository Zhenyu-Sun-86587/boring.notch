#!/usr/bin/env python3
"""Compile production drop decoding, bookmarks and Shelf state against isolated persistence."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
report = root / 'build/shelf-context-report.txt'
report.parent.mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix='boring-shelf-context-') as directory:
    work = Path(directory)
    compiler = ['xcrun', '--sdk', 'macosx', 'swiftc', '-swift-version', '5']
    core = root / 'Packages/IslandCore/Sources/IslandCore'
    subprocess.run(compiler + ['-emit-library', '-emit-module', '-module-name', 'IslandCore',
        *map(str, core.glob('*.swift')), '-o', str(work / 'libIslandCore.dylib')], cwd=work, check=True, timeout=120)
    sources = ['boringNotch/components/Shelf/Services/ShelfDropService.swift',
        'boringNotch/components/Shelf/ViewModels/ShelfStateViewModel.swift',
        'boringNotch/components/Shelf/Models/ShelfItem.swift',
        'boringNotch/components/Shelf/Models/Bookmark.swift',
        'boringNotch/extensions/URL+SecurityScoped.swift',
        'boringNotch/extensions/NSItemProvider+LoadHelpers.swift',
        '.github/scripts/ShelfContextChecks.swift']
    binary = work / 'ShelfContextChecks'
    subprocess.run(compiler + ['-parse-as-library', '-I', str(work), '-L', str(work), '-lIslandCore',
        '-Xlinker', '-rpath', '-Xlinker', str(work), *[str(root / p) for p in sources], '-o', str(binary)],
        cwd=work, check=True, timeout=120)
    result = subprocess.run([str(binary)], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=30)
    report.write_text(result.stdout)
    print(result.stdout)
    if result.returncode:
        raise SystemExit(f'Shelf context checks failed ({result.returncode})')
