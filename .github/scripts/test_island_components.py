#!/usr/bin/env python3
"""Real toolbar / atomic page replacement checks in an isolated offscreen panel.

Compile the actual BoringHeader, TabSelectionView, TabButton and shared page/shell
containers. Only passive model/preference dependencies and page payloads are stubbed.
The frozen baseline header sources are verbatim b39850c. Both variants receive the same
passive background marker on the real SF Image (no layout effect), and editor previews
are removed at compile time. This never opens the installed app, activates a window, changes the
pasteboard, sends input, or requests permissions.
"""
from pathlib import Path
import os
import platform
import resource
import subprocess
import tempfile


def main():
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise SystemExit("Island component checks require ARM64 macOS and macOS 27 SDK")
    root = Path(__file__).resolve().parents[2]
    evidence = root / "build/island-components-checks"
    report = root / "build/island-components-report.txt"
    notes = []
    evidence.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="boring-island-components-") as temporary:
        temporary = Path(temporary)
        subprocess.run(["xcrun", "--sdk", "macosx", "swiftc", "-swift-version", "5",
                        "-target", "arm64-apple-macos27.0", "-emit-library", "-emit-module",
                        "-module-name", "Defaults", str(root / ".github/scripts/IslandDefaultsStub.swift"),
                        "-o", str(temporary / "libDefaults.dylib")], cwd=temporary, check=True, timeout=120)
        shared = [root / "boringNotch/Hermes/NotchHostingView.swift",
                  root / "boringNotch/Hermes/WorkspaceSurfaceFrame.swift",
                  root / ".github/scripts/IslandComponentsDependencies.swift",
                  root / ".github/scripts/IslandComponentsChecks.swift"]
        shape = temporary / "NotchShape.swift"
        shape.write_text((root / "boringNotch/components/Notch/NotchShape.swift").read_text().split("\n#Preview {", 1)[0])
        shared.append(shape)
        def no_core_dump():
            resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
        results = {}
        for mode in ["baseline", "production"]:
            paths = [root / ".github/scripts/fixtures/island-header-b39850c" / name for name in
                     ("BoringHeader.swift", "TabSelectionView.swift", "TabButton.swift")] if mode == "baseline" else [
                     root / "boringNotch/components/Notch/BoringHeader.swift",
                     root / "boringNotch/components/Tabs/TabSelectionView.swift",
                     root / "boringNotch/components/Tabs/TabButton.swift"]
            sources = list(shared)
            for path in paths:
                prepared = temporary / f"{mode}-{path.name}"
                source = path.read_text().split("\n#Preview {", 1)[0]
                if path.name == "TabButton.swift":
                    anchor = "Image(systemName: icon)"
                    if source.count(anchor) != 1:
                        raise SystemExit("TabButton source changed; update the passive image-bounds probe")
                    source = source.replace(anchor, anchor + '\n                .background(ComponentMarker(name: "tab-\\(icon)"))')
                prepared.write_text(source)
                sources.append(prepared)
            if mode == "production":
                sources.append(root / "boringNotch/Hermes/IslandPageContainer.swift")
            executable = temporary / f"IslandComponents-{mode}"
            command = ["xcrun", "--sdk", "macosx", "swiftc", "-parse-as-library", "-swift-version", "5",
                       "-target", "arm64-apple-macos27.0", "-I", str(temporary), "-L", str(temporary),
                       "-lDefaults", "-Xlinker", "-rpath", "-Xlinker", str(temporary),
                       *map(str, sources), "-o", str(executable)]
            if mode == "baseline": command += ["-D", "BASELINE"]
            subprocess.run(command, cwd=root, check=True, timeout=120)
            with (evidence / f"{mode}.log").open("w") as output:
                results[mode] = subprocess.run([str(executable)], cwd=root,
                    env=dict(os.environ, NSUnbufferedIO="YES", BORING_COMPONENT_FRAMES=str(evidence / mode)),
                    stdout=output, stderr=subprocess.STDOUT, timeout=75, preexec_fn=no_core_dump).returncode
            log = (evidence / f"{mode}.log").read_text()
            print(log)
            notes.append(log)
            report.write_text("\n".join(notes))
            if mode == "production" and results[mode] != 0:
                raise SystemExit("Production island component checks failed")
        baseline = (evidence / "baseline.log").read_text()
        if results["baseline"] == 2 and "BASELINE_GHOST_REPRODUCED" in baseline:
            conclusion = "PASS real-component comparison: prior nested page transition overlapped old/new pages; production page replacement passed."
        else:
            conclusion = "Production passed; baseline overlap was not reproduced. Do not claim visual issue excluded."
        print(conclusion)
        notes.append(conclusion)
        report.write_text("\n".join(notes))


if __name__ == "__main__":
    main()
