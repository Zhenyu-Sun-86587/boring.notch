"""Regressions for the catalog/source audit's easy-to-miss UI paths."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "check_chinese_localization.py"
spec = importlib.util.spec_from_file_location("chinese_audit", SCRIPT)
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)


class ChineseLocalizationChecks(unittest.TestCase):
    def scan(self, source):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "boringNotch").mkdir()
            (root / "boringNotch/Test.swift").write_text(source)
            with patch.object(audit, "ROOT", root):
                return audit.source_keys()

    def test_conditional_labels_and_shortcut_recorders_are_checked(self):
        keys, errors = self.scan('''
            Text(enabled ? "Ready" : "Waiting")
            .help(enabled ? "Enabled" : "Disabled")
            KeyboardShortcuts.Recorder("Open clipboard:", name: .clipboard)
        ''')
        self.assertEqual(set(keys), {"Ready", "Waiting", "Enabled", "Disabled", "Open clipboard:"})
        self.assertEqual(errors, [])

    def test_nested_interpolation_is_one_localization_key(self):
        raw = 'Open \\(file.name ?? "Untitled") in \\(application)'
        self.assertEqual(audit.key_template(raw), "Open %@ in %@")
        keys, _ = self.scan('Text("' + raw + '")')
        self.assertEqual(set(keys), {"Open %@ in %@"})

    def test_onboarding_strings_are_checked_but_comments_and_symbols_are_not(self):
        keys, _ = self.scan('''
            PermissionsRequestView(icon: Image(systemName: "camera.fill"),
                title: "Enable camera", description: "Allow the camera", privacyNote: "Kept locally")
            var title: LocalizedStringResource {
                LocalizedStringResource("Camera unavailable", comment: "Explanation for translators")
            }
            // Text("Unreachable comment")
        ''')
        self.assertEqual(set(keys), {"Enable camera", "Allow the camera", "Kept locally", "Camera unavailable"})

    def test_action_implementation_strings_are_not_ui_labels(self):
        keys, _ = self.scan('''
            Button(action: { print("internal log") }) { Text("Run") }
            Text(userProvidedTitle)
            Text("用户输入")
        ''')
        self.assertEqual(set(keys), {"Run"})

    def test_unlocalized_native_window_text_is_rejected(self):
        keys, errors = self.scan('''
            panel.title = "Choose files"
            window.title = String(localized: "Settings")
        ''')
        self.assertEqual(set(keys), {"Choose files", "Settings"})
        self.assertEqual(len(errors), 1)
        self.assertIn("bypasses localization", errors[0])

    def test_exceptions_are_bounded_to_proper_names_and_formats(self):
        for key in ["Hermes", "%lld", "(%@)", "256 MB", "com.example.app"]:
            self.assertTrue(audit.exempt(key), key)
        for key in ["Grant Access", "Unknown", "%@ Required", "Check Again"]:
            self.assertFalse(audit.exempt(key), key)

    def test_english_translation_cannot_pass_as_chinese(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "boringNotch").mkdir()
            (root / "boringNotch/Test.swift").write_text('Text("Settings")')
            catalog = root / "catalog.json"
            catalog.write_text(json.dumps({"strings": {"Settings": {"localizations": {
                "zh-Hans": {"stringUnit": {"state": "translated", "value": "Settings"}}
            }}}}))
            output = io.StringIO()
            with patch.object(audit, "ROOT", root), patch.object(audit, "CATALOG", catalog), \
                    patch("sys.argv", [str(SCRIPT)]), contextlib.redirect_stderr(output):
                self.assertEqual(audit.main(), 1)
            self.assertIn("lacks Simplified Chinese", output.getvalue())


if __name__ == "__main__":
    unittest.main()
