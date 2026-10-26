#!/usr/bin/env python3
"""Exercise actual Store copy with private pasteboard/history and passive dependencies.
No general clipboard, AX tree, app activation, windows, events or permission requests.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix="boring-clipboard-store-") as temporary:
    work = Path(temporary)
    compiler = ["xcrun", "--sdk", "macosx", "swiftc", "-swift-version", "5",
                "-target", "arm64-apple-macos27.0"]
    subprocess.run(compiler + ["-emit-library", "-emit-module", "-module-name", "IslandCore",
        *map(str, (root / "Packages/IslandCore/Sources/IslandCore").glob("*.swift")),
        "-o", str(work / "libIslandCore.dylib")], cwd=work, check=True, timeout=120)
    executable = work / "ClipboardStoreChecks"
    subprocess.run(compiler + ["-parse-as-library", "-I", str(work), "-L", str(work), "-lIslandCore",
        "-Xlinker", "-rpath", "-Xlinker", str(work),
        str(root / "boringNotch/Clipboard/ClipboardStore.swift"),
        str(root / ".github/scripts/ClipboardStoreFixtureDependencies.swift"),
        str(root / ".github/scripts/ClipboardStoreChecks.swift"), "-o", str(executable)],
        cwd=root, check=True, timeout=120)
    subprocess.run([str(executable)], cwd=root, check=True, timeout=20)
