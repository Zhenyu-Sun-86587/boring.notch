#!/usr/bin/env python3
"""Build production NSAlert factory and inspect only hidden, unshown native views."""
from pathlib import Path
import subprocess
import tempfile


def main():
    root = Path(__file__).resolve().parents[2]
    report = root / "build/clipboard-alert-report.txt"
    report.parent.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="boring-clipboard-alert-") as temporary:
        executable = Path(temporary) / "ClipboardAlertChecks"
        subprocess.run(["xcrun", "--sdk", "macosx", "swiftc", "-swift-version", "5", "-parse-as-library",
                        "-target", "arm64-apple-macos27.0",
                        str(root / "boringNotch/Clipboard/ClipboardPermissionAlert.swift"),
                        str(root / ".github/scripts/ClipboardAlertChecks.swift"), "-o", str(executable)],
                       check=True, cwd=root, timeout=120)
        with report.open("w") as output:
            result = subprocess.run([str(executable)], cwd=root, stdout=output,
                                    stderr=subprocess.STDOUT, timeout=20)
        print(report.read_text())
        if result.returncode:
            raise SystemExit(f"Clipboard alert layout checks failed ({result.returncode}); see {report}")


if __name__ == "__main__":
    main()
