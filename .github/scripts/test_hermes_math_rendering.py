#!/usr/bin/env python3
"""Run actual pinned Textual parser checks with the selected Xcode toolchain.

Requires the application's resolved textual checkout from an earlier Xcode build. It compiles the
production HermesMarkdownParser and IslandCore in a temporary SwiftPM executable without modifying
vendors, invoking Hermes, creating application windows or accessing the clipboard/permissions.
"""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import tempfile


def main() -> None:
    root = Path(__file__).resolve().parents[2]
    args = argparse.ArgumentParser()
    args.add_argument("--textual-checkout", type=Path, default=root / "build/DerivedData/SourcePackages/checkouts/textual")
    options = args.parse_args()
    checkout = options.textual_checkout.resolve()
    if not (checkout / "Package.swift").is_file():
        raise SystemExit(f"Resolved Textual checkout missing: {checkout}; run the application build first")
    build = root / "build"
    build.mkdir(exist_ok=True)
    report = build / "hermes-markdown-report.txt"
    messages = [f"Production parser: {root / 'boringNotch/Hermes/HermesMarkdownParser.swift'}\n", f"Textual checkout: {checkout}\n"]
    try:
        resolved = json.loads((root / "boringNotch.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved").read_text())
        revision = next(pin["state"]["revision"] for pin in resolved["pins"] if pin["identity"] == "textual")
        actual = subprocess.check_output(["git", "-C", str(checkout), "rev-parse", "HEAD"], text=True).strip()
        if actual != revision:
            raise RuntimeError(f"Textual checkout {actual} does not match pinned {revision}")
        messages.append(f"Pinned Textual revision: {actual}\n")
        with tempfile.TemporaryDirectory(prefix="hermes-math-render-") as directory:
            project = Path(directory)
            sources = project / "Sources/HermesMathRenderingChecks"
            sources.mkdir(parents=True)
            shutil.copy2(root / "boringNotch/Hermes/HermesMarkdownParser.swift", sources / "HermesMarkdownParser.swift")
            shutil.copy2(root / ".github/scripts/HermesMathRenderChecks.swift", sources / "RenderChecks.swift")
            # JSON quoting is compatible with these absolute Swift string literals and avoids shell interpolation.
            package = '''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "HermesMathRenderingChecks", platforms: [.macOS(.v15)], dependencies: [
    .package(path: TEXTUAL_PATH), .package(path: CORE_PATH)
], targets: [.executableTarget(name: "HermesMathRenderingChecks", dependencies: [
    .product(name: "Textual", package: "textual"), .product(name: "IslandCore", package: "IslandCore")
], swiftSettings: [.swiftLanguageMode(.v5)])])
'''.replace("TEXTUAL_PATH", json.dumps(str(checkout), ensure_ascii=False)).replace("CORE_PATH", json.dumps(str(root / "Packages/IslandCore"), ensure_ascii=False))
            (project / "Package.swift").write_text(package)
            # Preserve verified dependency pins for SwiftUIMath and ConcurrencyExtras as well.
            (project / "Package.resolved").write_text(json.dumps(resolved))
            result = subprocess.run(["xcrun", "--sdk", "macosx", "swift", "run", "--package-path", str(project),
                                     "-c", "release", "HermesMathRenderingChecks"], cwd=root, text=True,
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=240)
            messages.append(result.stdout)
            if result.returncode:
                raise RuntimeError(f"Native Textual checks exited {result.returncode}")
            print(result.stdout)
    except BaseException as error:
        if isinstance(error, subprocess.TimeoutExpired):
            captured = error.stdout or b""
            messages.append(captured.decode(errors="replace") if isinstance(captured, bytes) else captured)
        messages.append(f"\nFAIL: {error}\n")
        raise
    finally:
        report.write_text("".join(messages))


if __name__ == "__main__":
    main()
