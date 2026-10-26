#!/usr/bin/env python3
"""Verify opt-in geometry logging using hidden, non-key fixture windows only."""
from pathlib import Path
import os
import platform
import subprocess
import tempfile


def main() -> None:
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise SystemExit("Geometry trace checks require ARM64 macOS with the macOS 27 SDK")
    root = Path(__file__).resolve().parents[2]
    sources = [root / "boringNotch/Hermes/NotchHostingView.swift",
               root / "boringNotch/Hermes/IslandWindowBridge.swift",
               root / "boringNotch/Hermes/IslandKeyboardHandoff.swift",
               root / ".github/scripts/WindowLayoutChecks.swift"]
    with tempfile.TemporaryDirectory(prefix="boring-geometry-trace-") as temporary:
        executable = Path(temporary) / "IslandGeometryTraceChecks"
        subprocess.run(["xcrun", "--sdk", "macosx", "swiftc", "-parse-as-library", "-swift-version", "5",
                        "-target", "arm64-apple-macos27.0", *map(str, sources), "-o", str(executable)],
                       cwd=root, check=True, timeout=120)
        environment = dict(os.environ)
        environment.pop("BORING_GEOMETRY_TRACE", None)
        for arguments in [[], ["--island-geometry-trace"]]:
            subprocess.run([str(executable), "--geometry-trace-checks", *arguments], cwd=root,
                           env=environment, check=True, timeout=15)


if __name__ == "__main__":
    main()
