#!/usr/bin/env python3
"""Check owned UI literals and catalog translations without translating user content.

This is a source/catalog audit, not a substitute for visual acceptance. It checks
the UI constructors and localized-resource declarations used by this project,
including interpolated keys; arbitrary dynamically generated strings still need
review. Proper names and format-only strings are explicit exceptions.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[2]
CATALOG = ROOT / "boringNotch/Localizable.xcstrings"
CHINESE = re.compile(r"[\u3400-\u9fff]")
BRANDS = {
    "Boring Notch", "boring.notch", "GitHub", "Apple Music", "Spotify",
    "YouTube Music", "BetterDisplay", "Lunar", "Hermes", "Vikunja REST",
    "HermesSurface", "API", "URL", "PNG", "JPEG", "TIFF", "PDF", "RTF",
    "HTML", "UTF-8", "Markdown", "macOS", "AirDrop", "Google Meet", "Zoom",
    "Microsoft Teams", "Webex", "Whereby", "Jitsi",
    "com.example.app",  # Example bundle identifier in the exclusion field.
}
UI_CALLS = re.compile(
    r"(?:\b(?:Text|Button|Toggle|Picker|Section|Label|Link|TextField|SecureField|"
    r"LabeledContent|ContentUnavailableView|NSLocalizedString|LocalizedStringResource|"
    r"HelpText|warningBadge|footerText|powerStatusLabel)\s*\(\s*|"
    r"\bKeyboardShortcuts\.Recorder\s*\(\s*|"
    r"\.(?:help|accessibilityLabel|navigationTitle|alert|confirmationDialog)\s*\(\s*|"
    r"\bString\s*\(\s*localized\s*:\s*|\bcustomBadge\s*\(\s*text\s*:\s*)$"
)
NATIVE_ASSIGNMENT = re.compile(
    r"\b(?:messageText|informativeText|(?:panel|window|savePanel)\.(?:title|message|prompt))\s*=\s*$"
)
DYNAMIC_LABEL_PATHS = {
    "components/Onboarding/PermissionsRequestView.swift": [
        "Text(LocalizedStringKey(title))", "Text(LocalizedStringKey(description))",
        "Text(LocalizedStringKey(privacyNote))",
    ],
    "components/Notch/BoringExtrasMenu.swift": ["var title: LocalizedStringKey"],
    "components/Tabs/TabButton.swift": [
        ".help(LocalizedStringKey(label))", ".accessibilityLabel(LocalizedStringKey(label))",
    ],
}


def skip_string(source: str, start: int) -> int:
    """Skip a Swift literal, including nested strings inside interpolation."""
    delimiter = '"""' if source.startswith('"""', start) else '"'
    cursor = start + len(delimiter)
    while cursor < len(source):
        if source.startswith(delimiter, cursor):
            return cursor + len(delimiter)
        if source.startswith("\\(", cursor):
            depth = 1
            cursor += 2
            while cursor < len(source) and depth:
                if source[cursor] == '"':
                    cursor = skip_string(source, cursor)
                    continue
                if source[cursor] == "(":
                    depth += 1
                elif source[cursor] == ")":
                    depth -= 1
                cursor += 1
        elif source[cursor] == "\\":
            cursor += 2
        else:
            cursor += 1
    return len(source)


def literals(source: str):
    """Yield offset and raw literal, omitting comments and interpolation internals."""
    cursor = 0
    while cursor < len(source):
        if source.startswith("//", cursor):
            newline = source.find("\n", cursor)
            cursor = len(source) if newline < 0 else newline + 1
        elif source.startswith("/*", cursor):
            depth = 1
            cursor += 2
            while cursor < len(source) and depth:
                if source.startswith("/*", cursor):
                    depth += 1
                    cursor += 2
                elif source.startswith("*/", cursor):
                    depth -= 1
                    cursor += 2
                else:
                    cursor += 1
        elif source[cursor] == '"':
            end = skip_string(source, cursor)
            length = 3 if source.startswith('"""', cursor) else 1
            yield cursor, source[cursor + length:end - length]
            cursor = end
        else:
            cursor += 1


def key_template(raw: str) -> str:
    result = []
    cursor = 0
    while cursor < len(raw):
        if raw.startswith("\\(", cursor):
            depth = 1
            cursor += 2
            start = cursor
            while cursor < len(raw) and depth:
                if raw[cursor] == '"':
                    cursor = skip_string(raw, cursor)
                    continue
                if raw[cursor] == "(":
                    depth += 1
                elif raw[cursor] == ")":
                    depth -= 1
                cursor += 1
            expression = raw[start:cursor - 1]
            # Most SwiftUI interpolation in this app uses String or FormatStyle.
            result.append("%lld" if expression.startswith("Int(") else "%@")
        elif raw[cursor] == "\\" and cursor + 1 < len(raw):
            escaped = raw[cursor + 1]
            result.append({"n": "\n", "t": "\t", "r": "\r", '"': '"', "\\": "\\"}.get(escaped, escaped))
            cursor += 2
        else:
            result.append(raw[cursor])
            cursor += 1
    return "".join(result)


def exempt(key: str) -> bool:
    if not key or key in BRANDS or key.startswith(("https://", "http://")):
        return True
    if re.fullmatch(r"\d+(?:\.\d+)? (?:KB|MB|GB)", key):
        return True  # Standard storage unit labels, independent of UI language.
    stripped = re.sub(r"%(?:\d+\$)?[-+ #0]*(?:\d+)?(?:\.\d+)?(?:ll|l)?[@diufge]", "", key)
    return not re.search(r"[A-Za-z]", stripped)


def resource_ranges(source: str) -> list[tuple[int, int]]:
    ranges = []
    # A localized-resource/key computed property contains localizable switch literals.
    for match in re.finditer(r"\bvar\s+\w+\s*:\s*LocalizedString(?:Resource|Key)\s*\{", source):
        cursor = match.end()
        depth = 1
        while cursor < len(source) and depth:
            if source[cursor] == '"':
                cursor = skip_string(source, cursor)
                continue
            if source[cursor] == "{":
                depth += 1
            elif source[cursor] == "}":
                depth -= 1
            cursor += 1
        ranges.append((match.end(), cursor))
    # Onboarding passes strings through a reusable view, which localizes them.
    for match in re.finditer(r"\b(?:PermissionsRequestView|PermissionRequestView|BoringLargeButtons)\s*\(", source):
        cursor = match.end()
        depth = 1
        while cursor < len(source) and depth:
            if source[cursor] == '"':
                cursor = skip_string(source, cursor)
                continue
            if source[cursor] == "(":
                depth += 1
            elif source[cursor] == ")":
                depth -= 1
            cursor += 1
        ranges.append((match.end(), cursor))
    return ranges


def first_label_ranges(source: str) -> list[tuple[int, int]]:
    """Include both sides of conditional UI labels, not only initial literals."""
    ranges = []
    for match in re.finditer(
        r"(?:\b(?:Text|Button|Toggle|Picker|Section|Label|Link|TextField|SecureField|"
        r"LabeledContent|ContentUnavailableView|HelpText|footerText|powerStatusLabel)|"
        r"\.(?:help|accessibilityLabel|navigationTitle|alert|confirmationDialog)|"
        r"\bKeyboardShortcuts\.Recorder)\s*\(", source
    ):
        cursor = match.end()
        # Action/header/value arguments aren't label literals; nested Text calls
        # are checked independently and log messages must not become UI keys.
        if re.match(r"\s*\w+\s*:", source[cursor:]):
            continue
        depth = 0
        while cursor < len(source):
            char = source[cursor]
            if char == '"':
                cursor = skip_string(source, cursor)
                continue
            if char in "([{":
                depth += 1
            elif char in ")]}":
                if depth == 0:
                    break
                depth -= 1
            elif char == "," and depth == 0:
                break
            cursor += 1
        ranges.append((match.end(), cursor))
    return ranges


def source_keys():
    found: dict[str, list[str]] = {}
    native_errors = []
    for path in sorted((ROOT / "boringNotch").rglob("*.swift")):
        source = path.read_text()
        ranges = resource_ranges(source)
        label_ranges = first_label_ranges(source)
        for offset, raw in literals(source):
            prefix = source[max(0, offset - 200):offset]
            location = f"{path.relative_to(ROOT)}:{source.count(chr(10), 0, offset) + 1}"
            key = key_template(raw)
            if re.search(r"\bcomment\s*:\s*$", prefix):
                continue
            is_named_label = re.search(r"\b(?:title|description|privacyNote)\s*:\s*$", prefix)
            direct_label = UI_CALLS.search(prefix) or any(a <= offset < b for a, b in label_ranges)
            selected = direct_label or any(a <= offset < b for a, b in ranges)
            if NATIVE_ASSIGNMENT.search(prefix) and not exempt(key) and not CHINESE.search(key):
                native_errors.append(f"{location}: AppKit text bypasses localization: {key!r}")
                selected = True
            if selected and not exempt(key) and not CHINESE.search(key):
                # Resource ranges contain unrelated SF Symbol names and runtime keys too.
                if not direct_label and not is_named_label and re.fullmatch(r"[a-z][a-z0-9.]*", key):
                    continue
                found.setdefault(key, []).append(location)
    for relative_path, expressions in DYNAMIC_LABEL_PATHS.items():
        path = ROOT / "boringNotch" / relative_path
        if path.exists():
            source = path.read_text()
            for expression in expressions:
                if expression not in source:
                    native_errors.append(f"{path.relative_to(ROOT)}: Dynamic label no longer localizes: {expression}")
    return found, native_errors


def units(localization: dict):
    if "stringUnit" in localization:
        yield localization["stringUnit"]
    for key, value in localization.items():
        if isinstance(value, dict) and key != "stringUnit":
            yield from units(value)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--list-missing", action="store_true", help="Print unrecognized source keys as JSON")
    args = parser.parse_args()
    catalog = json.loads(CATALOG.read_text())["strings"]
    keys, errors = source_keys()
    # Formatting expressions can use equivalent %@ / %lld catalog placeholders.
    normalize = lambda key: re.sub(r"%(?:ll)?[diufge@]", "%@", key)
    known = {normalize(key): key for key in catalog}
    missing = {key: locations for key, locations in keys.items() if normalize(key) not in known}
    if args.list_missing:
        print(json.dumps(missing, ensure_ascii=False, indent=2))
        return 0
    for key, entry in catalog.items():
        if exempt(key):
            continue
        translated = list(units(entry.get("localizations", {}).get("zh-Hans", {})))
        if not translated or any(not unit.get("value") or not CHINESE.search(unit["value"]) for unit in translated):
            errors.append(f"Catalog lacks Simplified Chinese: {key!r}")
    for key, locations in missing.items():
        errors.append(f"{locations[0]}: Missing catalog key: {key!r}")
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print(f"Simplified Chinese audit passed: {len(catalog)} catalog entries, {len(keys)} owned source keys.")
    print("Proper names, URLs, format-only labels and user/system-provided content are preserved.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
