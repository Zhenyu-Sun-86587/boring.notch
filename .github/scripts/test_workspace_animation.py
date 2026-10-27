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
    sources = [root / "Shared/InteractionDiagnostics.swift", root / "Shared/InteractionDiagnosticContext.swift", root / "boringNotch/Hermes/NotchHostingView.swift", root / "boringNotch/Hermes/IslandWindowBridge.swift",
               root / "boringNotch/Hermes/IslandKeyboardHandoff.swift", root / "boringNotch/Hermes/WorkspaceSurfaceFrame.swift",
               root / ".github/scripts/WorkspaceAnimationChecks.swift"]
    with tempfile.TemporaryDirectory(prefix="boring-workspace-animation-") as temporary:
        executable = Path(temporary) / "WorkspaceAnimationChecks"
        shape = Path(temporary) / "NotchShape.swift"
        # Compile the production path implementation; the editor-only preview macro is unavailable
        # in Apple's standalone Command Line Tools and has no runtime code under test.
        shape.write_text((root / "boringNotch/components/Notch/NotchShape.swift").read_text().split("\n#Preview {", 1)[0])
        sources.append(shape)
        subprocess.run(["xcrun", "--sdk", "macosx", "swiftc", "-parse-as-library", "-swift-version", "5",
                        "-target", "arm64-apple-macos27.0", *map(str, sources), "-o", str(executable)],
                       cwd=root, check=True, timeout=120)
        def no_core_dump():
            resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
        environment = dict(os.environ, NSUnbufferedIO="YES", BORING_WORKSPACE_FRAMES=str(root / "build/workspace-animation-frames"))
        with report.open("w") as output:
            result = subprocess.run([str(executable)], cwd=root, env=environment, stdout=output,
                                    stderr=subprocess.STDOUT, timeout=90, preexec_fn=no_core_dump)
        print(report.read_text())
        if result.returncode:
            raise SystemExit(f"Workspace animation checks failed ({result.returncode}); see {report}")


if __name__ == "__main__":
    main()
