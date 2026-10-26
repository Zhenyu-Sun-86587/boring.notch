#!/usr/bin/env python3
"""Real PID-scoped event delivery + a sandbox-host/non-sandbox-XPC-helper chain.

No window, activation, clipboard access, global CGEventPost, input tap or permission request.
Missing pre-existing CG event-post access is recorded as SKIP, never granted by this test.
Receiving Cmd+V proves transport only, not a user editor's paste acceptance.
"""
from pathlib import Path
import plistlib
import subprocess
import tempfile
import uuid

root = Path(__file__).resolve().parents[2]
report = root / "build/clipboard-native-checks"
report.mkdir(parents=True, exist_ok=True)


def run(command, *, log=None):
    result = subprocess.run(list(map(str, command)), cwd=root, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, timeout=120)
    if log:
        (report / log).write_text(result.stdout)
        print(result.stdout, end="")
    elif result.returncode:
        print(result.stdout, end="")
    result.check_returncode()


def plist(path, values):
    path.write_bytes(plistlib.dumps(values))


with tempfile.TemporaryDirectory(prefix="boring-native-clipboard-") as temporary:
    work = Path(temporary)
    compiler = ["xcrun", "swiftc", "-parse-as-library", "-swift-version", "5", "-target", "arm64-apple-macos27.0"]
    direct = work / "ClipboardNativeEventChecks"
    run(compiler + [root / "Shared/ClipboardPasteEvent.swift", root / ".github/scripts/ClipboardNativeEventChecks.swift", "-o", direct])
    run([direct], log="direct-route.log")

    identifier = "com.boringnotch.fixture.clipboard." + uuid.uuid4().hex
    app = work / "Clipboard Native Fixture.app"
    macos = app / "Contents/MacOS"
    helper = app / "Contents/XPCServices/ClipboardNativeFixtureHelper.xpc"
    helper_macos = helper / "Contents/MacOS"
    macos.mkdir(parents=True)
    helper_macos.mkdir(parents=True)
    plist(app / "Contents/Info.plist", {"CFBundleIdentifier": identifier, "CFBundleExecutable": "ClipboardNativeFixture",
        "CFBundlePackageType": "APPL", "CFBundleVersion": "1", "LSUIElement": True})
    plist(helper / "Contents/Info.plist", {"CFBundleIdentifier": identifier + ".Helper",
        "CFBundleExecutable": "ClipboardNativeFixtureHelper", "CFBundlePackageType": "XPC!", "CFBundleVersion": "1",
        "XPCService": {"ServiceType": "Application"}})
    protocol = root / ".github/scripts/ClipboardNativeXPCProtocol.swift"
    run(compiler + ["-module-name", "ClipboardNativeFixture", protocol,
        root / "Shared/ClipboardPasteAccess.swift", root / ".github/scripts/ClipboardNativeXPCChecks.swift",
        "-o", macos / "ClipboardNativeFixture"])
    production = [path for path in (root / "BoringNotchXPCHelper").glob("*.swift") if path.name != "main.swift"]
    run(compiler + ["-module-name", "ClipboardNativeFixture", protocol, *production,
        *(root / "Shared").glob("*.swift"), root / ".github/scripts/ClipboardNativeXPCService.swift",
        "-o", helper_macos / "ClipboardNativeFixtureHelper"])
    entitlements = work / "sandbox.plist"
    plist(entitlements, {"com.apple.security.app-sandbox": True})
    run(["codesign", "--force", "--sign", "-", helper])
    run(["codesign", "--force", "--sign", "-", "--entitlements", entitlements, app])
    run(["codesign", "--verify", "--deep", "--strict", app])
    run([macos / "ClipboardNativeFixture"], log="xpc-route.log")
print("Native clipboard reports:", report)
