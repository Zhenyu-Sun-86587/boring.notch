#!/usr/bin/env python3
"""Compile the production notch hosting/bridge sources and check hidden native window behavior.

This creates fixture-only unshown NSPanels. It never launches the installed app, orders a
window, reads the clipboard, or requests permissions. It checks frame ownership and update
scheduling; it is not a substitute for visible UI/WindowServer display-cycle acceptance.
"""
from pathlib import Path
import platform
import subprocess
import tempfile


def main() -> None:
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise SystemExit("Window layout checks require ARM64 macOS with the macOS 27 SDK")
    root = Path(__file__).resolve().parents[2]
    sources = [root / "Shared/InteractionDiagnostics.swift", root / "Shared/InteractionDiagnosticContext.swift",
        root / "boringNotch/Hermes/NotchHostingView.swift",
        root / "boringNotch/Hermes/IslandWindowBridge.swift",
        root / "boringNotch/Hermes/IslandKeyboardHandoff.swift",
        root / ".github/scripts/WindowLayoutChecks.swift",
    ]
    with tempfile.TemporaryDirectory(prefix="boring-window-layout-") as temporary:
        executable = Path(temporary) / "WindowLayoutChecks"
        subprocess.run([
            "xcrun", "--sdk", "macosx", "swiftc", "-parse-as-library", "-swift-version", "5",
            "-target", "arm64-apple-macos27.0", *map(str, sources), "-o", str(executable),
        ], cwd=root, check=True, timeout=120)
        subprocess.run([str(executable)], cwd=root, check=True, timeout=40)


if __name__ == "__main__":
    main()
