#!/usr/bin/env python3
"""Compare private and joined XPC audit sessions with the shipping service configuration.

Only session-availability booleans cross XPC. No windows, user input, clipboard,
accessibility tree, input events, permission requests, or installed app changes.
"""
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import uuid

root = Path(__file__).resolve().parents[2]
source = root / ".github/scripts/ClipboardGUISessionChecks.swift"
production = plistlib.loads((root / "BoringNotchXPCHelper/Info.plist").read_bytes())["XPCService"]
compiler = ["xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
            "-target", "arm64-apple-macos27.0", "-module-name", "ClipboardGUISessionFixture"]


def run(args):
    subprocess.run(list(map(str, args)), check=True, timeout=120)


def plist(path, contents):
    path.write_bytes(plistlib.dumps(contents))


with tempfile.TemporaryDirectory(prefix="boring-gui-session-") as temporary:
    work = Path(temporary)
    identifier = "com.boringnotch.fixture.session." + uuid.uuid4().hex
    app = work / "GUI Session Fixture.app"
    macos = app / "Contents/MacOS"
    macos.mkdir(parents=True)
    plist(app / "Contents/Info.plist", {"CFBundleIdentifier": identifier,
        "CFBundleExecutable": "SessionHost", "CFBundlePackageType": "APPL", "LSUIElement": True})
    run(compiler + [source, "-o", macos / "SessionHost"])
    helper_binary = work / "SessionHelper"
    run(compiler + ["-D", "SESSION_HELPER", source, "-o", helper_binary])
    configurations = [
        ("private", {"ServiceType": "Application"}, False),
        ("joined", {"ServiceType": "Application", "JoinExistingSession": True}, True),
        ("production", production, True),
    ]
    for name, configuration, _ in configurations:
        helper = app / f"Contents/XPCServices/{name}.xpc"
        executable = helper / "Contents/MacOS/SessionHelper"
        executable.parent.mkdir(parents=True)
        shutil.copy2(helper_binary, executable)
        plist(helper / "Contents/Info.plist", {"CFBundleIdentifier": identifier + "." + name,
            "CFBundleExecutable": "SessionHelper", "CFBundlePackageType": "XPC!",
            "XPCService": configuration})
        run(["codesign", "--force", "--sign", "-", helper])
    entitlements = work / "host-entitlements.plist"
    plist(entitlements, {"com.apple.security.app-sandbox": True})
    run(["codesign", "--force", "--sign", "-", "--entitlements", entitlements, app])
    run(["codesign", "--verify", "--deep", "--strict", app])
    try:
        for name, _, expected in configurations:
            print("Checking XPC configuration:", name, flush=True)
            run([macos / "SessionHost", identifier + "." + name, str(expected).lower()])
    finally:
        # This freshly generated identifier belongs only to this fixture.
        container = Path.home() / "Library/Containers" / identifier
        if container.is_dir() and not container.is_symlink():
            shutil.rmtree(container)
print("PASS native XPC GUI session: default-private has no Quartz session; joined and shipping helper inherit the GUI client's session; no input posted")
