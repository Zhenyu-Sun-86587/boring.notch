#!/usr/bin/env python3
"""Exercise the production paste sequence with synthetic observations only."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix="boring-paste-checks-") as temporary:
    executable = Path(temporary) / "ClipboardPasteChecks"
    subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library",
                    str(root / "Shared/ClipboardPasteCoordinator.swift"),
                    str(root / "Shared/ClipboardFocusRestoration.swift"),
                    str(root / "Shared/ClipboardDestinationTracker.swift"),
                    str(root / ".github/scripts/ClipboardPasteChecks.swift"),
                    "-o", str(executable)], check=True, cwd=root, timeout=120)
    subprocess.run([str(executable)], check=True, cwd=root, timeout=15)
