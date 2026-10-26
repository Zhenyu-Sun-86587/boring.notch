#!/usr/bin/env python3
"""Run Store+Presentation against private history/pasteboard and passive OS adapters.

Only OS singleton/type names are replaced in a temporary source copy; production
method bodies execute unchanged. No app is activated, input posted, permission
requested, or general clipboard accessed. --presentation-source can compare an
exported historical source against the same behavior checks; CI uses the worktree.
"""
import argparse
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--presentation-source", type=Path,
                    default=root / "boringNotch/Hermes/ClipboardPresentation.swift")
args = parser.parse_args()
with tempfile.TemporaryDirectory(prefix="clipboard-presentation-runtime-") as temporary:
    work = Path(temporary)
    compiler = ["xcrun", "--sdk", "macosx", "swiftc", "-swift-version", "5",
                "-target", "arm64-apple-macos27.0"]
    for name, sources in [
        ("IslandCore", list((root / "Packages/IslandCore/Sources/IslandCore").glob("*.swift"))),
        ("Defaults", [root / ".github/scripts/ClipboardDefaultsStub.swift"]),
    ]:
        subprocess.run(compiler + ["-emit-library", "-emit-module", "-module-name", name,
            *map(str, sources), "-o", str(work / f"lib{name}.dylib")],
            cwd=work, check=True, timeout=120)
    source = args.presentation_source.read_text()
    for native, fixture in [
        ("NSRunningApplication", "FixtureRunningApplication"),
        ("NSWorkspace", "FixtureWorkspace"),
        ("NSApp.", "FixtureApplication.shared."),
        ("NSEvent.", "FixtureEvent."),
        ("ClipboardStore.shared", "FixtureStore.shared"),
    ]:
        source = source.replace(native, fixture)
    presentation = work / "ClipboardPresentation.swift"
    presentation.write_text(source)
    sources = [presentation,
        root / "Shared/ClipboardDestinationTracker.swift",
        root / "Shared/ClipboardPasteAccess.swift",
        root / "Shared/ClipboardPasteCoordinator.swift",
        root / "Shared/ClipboardFocusRestoration.swift",
        root / "boringNotch/Clipboard/ClipboardStore.swift",
        root / ".github/scripts/ClipboardSessionRuntimeChecks.swift"]
    executable = work / "ClipboardSessionRuntimeChecks"
    subprocess.run(compiler + ["-parse-as-library", "-I", temporary, "-L", temporary,
        "-lIslandCore", "-lDefaults", "-Xlinker", "-rpath", "-Xlinker", temporary,
        *map(str, sources), "-o", str(executable)], cwd=root, check=True, timeout=120)
    subprocess.run([str(executable)], cwd=root, check=True, timeout=20)
