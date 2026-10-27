#!/usr/bin/env python3
"""Actual drawer scrolling in an offscreen host with passive synthetic records.

Only append numeric observation to the production geometry callbacks. No input
events, app activation, general pasteboard, user records or permissions are used.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix="boring-drawer-scroll-") as temporary:
    work = Path(temporary)
    compiler = ["xcrun", "--sdk", "macosx", "swiftc", "-swift-version", "5",
                "-target", "arm64-apple-macos27.0"]
    subprocess.run(compiler + ["-emit-library", "-emit-module", "-module-name", "IslandCore",
        *map(str, (root / "Packages/IslandCore/Sources/IslandCore").glob("*.swift")),
        "-o", str(work / "libIslandCore.dylib")], cwd=work, check=True, timeout=120)
    source = (root / "boringNotch/Clipboard/ClipboardDrawer.swift").read_text()
    for original, replacement in [
        ("contentRowFrames = $0", "contentRowFrames = $0; DrawerMetrics.rows = $0"),
        ("visibleContentRect = rectangle", "visibleContentRect = rectangle; DrawerMetrics.viewport = rectangle"),
    ]:
        assert source.count(original) == 1
        source = source.replace(original, replacement)
    drawer = work / "ClipboardDrawer.swift"
    drawer.write_text(source)
    executable = work / "ClipboardDrawerScrollChecks"
    subprocess.run(compiler + ["-parse-as-library", "-I", temporary, "-L", temporary,
        "-lIslandCore", "-Xlinker", "-rpath", "-Xlinker", temporary,
        str(drawer), str(root / "boringNotch/Hermes/HermesInputFocusObserver.swift"),
        str(root / ".github/scripts/ClipboardDrawerScrollChecks.swift"),
        "-o", str(executable)], check=True, timeout=120)
    subprocess.run([str(executable)], check=True, timeout=35)
