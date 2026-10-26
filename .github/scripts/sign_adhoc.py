#!/usr/bin/env python3
"""Thin build products, sign from the inside out, and verify every Mach-O is ARM64."""
import os
from pathlib import Path
import plistlib
import subprocess
import sys


def run(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT).strip()


def sign_app(app):
    app = app.resolve(strict=True)
    report = []
    binaries = []
    for path in sorted(app.rglob("*")):
        if path.is_symlink() or not path.is_file():
            continue
        if "Mach-O" not in run("file", "-b", str(path)):
            continue
        architectures = run("lipo", "-archs", str(path)).split()
        if "arm64" not in architectures:
            raise RuntimeError(f"Missing ARM64: {path}")
        if architectures != ["arm64"]:
            temporary = path.with_name(path.name + ".arm64")
            mode = path.stat().st_mode
            run("lipo", str(path), "-thin", "arm64", "-output", str(temporary))
            os.chmod(temporary, mode)
            os.replace(temporary, path)
        binaries.append(path)
        run("codesign", "--force", "--sign", "-", "--timestamp=none", "--preserve-metadata=entitlements", str(path))
    bundles = [p for p in app.rglob("*") if p.is_dir() and not p.is_symlink() and p.suffix in {".framework", ".xpc", ".app", ".bundle"}]
    for bundle in sorted(bundles, key=lambda p: len(p.parts), reverse=True) + [app]:
        # Resource-only bundles do not contain code and need no signature.
        if bundle != app and not any(p.is_relative_to(bundle) for p in binaries):
            continue
        args = ["codesign", "--force", "--sign", "-", "--timestamp=none"]
        if bundle == app:
            args += ["--options", "runtime", "--entitlements", "boringNotch/boringNotch.entitlements"]
        elif bundle.suffix == ".xpc" and bundle.name == "BoringNotchXPCHelper.xpc":
            args += ["--entitlements", "BoringNotchXPCHelper/BoringNotchXPCHelper.entitlements"]
        else:
            args += ["--preserve-metadata=entitlements"]
        run(*args, str(bundle))
    run("codesign", "--verify", "--deep", "--strict", "--verbose=2", str(app))
    for binary in binaries:
        assert run("lipo", "-archs", str(binary)) == "arm64", binary
        report.append(f"arm64: {binary.relative_to(app)}")
    with (app / "Contents/Info.plist").open("rb") as source:
        info = plistlib.load(source)
    assert info.get("SUEnableAutomaticChecks") is False
    assert info.get("SUAllowsAutomaticUpdates") is False
    assert os.access(app / "Contents/MacOS" / info["CFBundleExecutable"], os.X_OK)
    report.append(run("codesign", "--display", "--verbose=2", str(app)))
    Path("build/signing-report.txt").write_text("\n".join(report) + "\n")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: sign_adhoc.py path/to/Boring Notch.app")
    sign_app(Path(sys.argv[1]))
