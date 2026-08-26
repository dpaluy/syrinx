#!/usr/bin/env python3

import argparse
import importlib.util
import plistlib
import tempfile
import unittest
from pathlib import Path
from unittest import mock


MODULE_PATH = Path(__file__).with_name("app-release.py")
SPEC = importlib.util.spec_from_file_location("app_release", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
app_release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(app_release)


class AppReleaseSigningTests(unittest.TestCase):
    def test_release_entitlements_require_audio_input(self):
        with tempfile.TemporaryDirectory() as raw:
            repo = Path(raw)
            source = repo / app_release.APP_ENTITLEMENTS_SOURCE
            source.parent.mkdir(parents=True)
            source.write_bytes(plistlib.dumps({"com.apple.security.device.audio-input": True}))

            self.assertEqual(app_release.load_app_entitlements(repo), source)

    def test_sign_app_applies_and_verifies_entitlements(self):
        with tempfile.TemporaryDirectory() as raw:
            repo = Path(raw)
            app = repo / "Syrinx.app"
            app.mkdir()
            entitlements = repo / app_release.APP_ENTITLEMENTS_SOURCE
            entitlements.parent.mkdir(parents=True)
            entitlements.write_bytes(
                plistlib.dumps({"com.apple.security.device.audio-input": True})
            )
            args = argparse.Namespace(
                repo_root=repo,
                application_identity="Developer ID Application: Syrinx (TEAMID1234)",
                signing_keychain=None,
                team_id=None,
            )
            calls = []

            def fake_run_tool(argv, cwd=None, timeout=20 * 60):
                calls.append(argv)
                return ""

            encoded_entitlements = plistlib.dumps(
                {"com.apple.security.device.audio-input": True}
            ).decode("utf-8")
            with mock.patch.object(app_release, "run_tool", side_effect=fake_run_tool), mock.patch.object(
                app_release, "run_tool_combined", return_value=encoded_entitlements
            ) as combined:
                app_release.sign_app(args, app)

            signing_call = next(call for call in calls if "--sign" in call)
            self.assertIn("--entitlements", signing_call)
            self.assertIn(str(entitlements), signing_call)
            combined.assert_called_once_with(
                ["codesign", "--display", "--entitlements", ":-", str(app)]
            )


if __name__ == "__main__":
    unittest.main()
