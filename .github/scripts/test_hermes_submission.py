#!/usr/bin/env python3
"""Run the production HermesStore against isolated configuration/file/streaming fixtures.

This executable never creates application windows, reads the clipboard/Keychain/user settings,
requests permissions or contacts a service. All files are below a temporary fixture directory.
"""
import json
from pathlib import Path
import shutil
import subprocess
import tempfile


def main() -> None:
    root = Path(__file__).resolve().parents[2]
    report = root / "build/hermes-submission-report.txt"
    report.parent.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="boring-hermes-submission-") as directory:
        project = Path(directory)
        sources = project / "Sources/HermesSubmissionChecks"
        sources.mkdir(parents=True)
        shutil.copy2(root / "boringNotch/Hermes/HermesStore.swift", sources / "HermesStore.swift")
        shutil.copy2(root / ".github/scripts/HermesSubmissionChecks.swift", sources / "SubmissionChecks.swift")
        package = '''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "HermesSubmissionChecks", platforms: [.macOS(.v14)], dependencies: [
    .package(path: CORE_PATH)
], targets: [.executableTarget(name: "HermesSubmissionChecks", dependencies: [
    .product(name: "IslandCore", package: "IslandCore")
], swiftSettings: [.swiftLanguageMode(.v5)])])
'''.replace("CORE_PATH", json.dumps(str(root / "Packages/IslandCore"), ensure_ascii=False))
        (project / "Package.swift").write_text(package)
        result = subprocess.run(["xcrun", "--sdk", "macosx", "swift", "run", "--package-path", str(project),
                                 "-c", "release", "HermesSubmissionChecks"], cwd=root, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=180)
        report.write_text(result.stdout)
        print(result.stdout)
        if result.returncode:
            raise SystemExit(f"Hermes submission checks failed ({result.returncode}); see {report}")


if __name__ == "__main__":
    main()
