#!/usr/bin/env python3
"""Compile production clipboard state and permission sources without running any UI."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix="boring-clipboard-typecheck-") as temporary:
    work = Path(temporary)
    compiler = ["xcrun", "--sdk", "macosx", "swiftc", "-swift-version", "5",
                "-target", "arm64-apple-macos27.0"]
    for name, sources in [("IslandCore", list((root / "Packages/IslandCore/Sources/IslandCore").glob("*.swift"))),
                          ("Defaults", [root / ".github/scripts/ClipboardDefaultsStub.swift"])]:
        subprocess.run(compiler + ["-emit-module", "-module-name", name, *map(str, sources)],
            cwd=work, check=True, timeout=120)
    subprocess.run(compiler + ["-typecheck", "-I", str(work),
        str(root / "boringNotch/Clipboard/ClipboardStore.swift"),
        str(root / "boringNotch/Hermes/ClipboardPresentation.swift"),
        str(root / "boringNotch/Clipboard/ClipboardPermissionController.swift"),
        str(root / "boringNotch/Clipboard/ClipboardPermissionAlert.swift"),
        *map(str, (root / "Shared").glob("Clipboard*.swift")),
        str(root / ".github/scripts/ClipboardPresentationFixtureDependencies.swift")],
        cwd=root, check=True, timeout=120)
    print("PASS production clipboard Store/Presentation/PermissionController typecheck; passive dependencies only, no UI executed")
