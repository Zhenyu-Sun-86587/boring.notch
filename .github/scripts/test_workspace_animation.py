#!/usr/bin/env python3
"""Exercise actual shared workspace animation code with an ordered offscreen SwiftUI App.

Every fixture window is pinned beyond all screens, never becomes key/main, and is removed on exit.
The check does not touch the installed application, clipboard, user windows, or pointer position.
"""
from pathlib import Path
import os
import platform
import resource
import subprocess
import tempfile


def main():
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise SystemExit("Workspace animation checks require ARM64 macOS and macOS 27 SDK")
    root = Path(__file__).resolve().parents[2]
    report = root / "build/workspace-animation-report.txt"
    report.parent.mkdir(exist_ok=True)
    sources = [root / "boringNotch/Hermes/NotchHostingView.swift", root / "boringNotch/Hermes/IslandWindowBridge.swift",
               root / "boringNotch/Hermes/WorkspaceSurfaceFrame.swift", root / ".github/scripts/WorkspaceAnimationChecks.swift"]
    with tempfile.TemporaryDirectory(prefix="boring-workspace-animation-") as temporary:
        executable = Path(temporary) / "WorkspaceAnimationChecks"
        subprocess.run(["xcrun", "--sdk", "macosx", "swiftc", "-parse-as-library", "-swift-version", "5",
                        "-target", "arm64-apple-macos27.0", *map(str, sources), "-o", str(executable)],
                       cwd=root, check=True, timeout=120)
        def no_core_dump():
            resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
        environment = dict(os.environ, NSUnbufferedIO="YES")
        with report.open("w") as output:
            result = subprocess.run([str(executable)], cwd=root, env=environment, stdout=output,
                                    stderr=subprocess.STDOUT, timeout=30, preexec_fn=no_core_dump)
        print(report.read_text())
        if result.returncode:
            raise SystemExit(f"Workspace animation checks failed ({result.returncode}); see {report}")


if __name__ == "__main__":
    main()
