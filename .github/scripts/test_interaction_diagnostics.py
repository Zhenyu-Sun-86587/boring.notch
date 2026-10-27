#!/usr/bin/env python3
"""Exercise the production logger in an isolated temporary directory, no UI/content access."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix="boring-interaction-log-") as directory:
    executable = Path(directory) / "InteractionDiagnosticsChecks"
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6",
        str(root / "Shared/InteractionDiagnostics.swift"),
        str(root / ".github/scripts/InteractionDiagnosticsChecks.swift"), "-o", str(executable)], check=True, timeout=120)
    subprocess.run([str(executable)], check=True, timeout=15)
