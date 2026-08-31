#!/usr/bin/env python3

import argparse
import importlib.util
import os
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock


MODULE_PATH = Path(__file__).with_name("app-release.py")
BUILD_SCRIPT = MODULE_PATH.parents[2] / "build.sh"
SPEC = importlib.util.spec_from_file_location("app_release", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
app_release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(app_release)


class BuildWrapperVersionTests(unittest.TestCase):
    def test_default_version_comes_from_info_plist(self):
        with tempfile.TemporaryDirectory() as raw:
            repo = Path(raw)
            build_script = repo / "build.sh"
            shutil.copy2(BUILD_SCRIPT, build_script)

            info_plist = repo / app_release.INFO_PLIST_SOURCE
            info_plist.parent.mkdir(parents=True)
            info_plist.write_bytes(
                plistlib.dumps({"CFBundleShortVersionString": "1.1.0"})
            )

            release_script = repo / "scripts" / "release" / "build-app.sh"
            release_script.parent.mkdir(parents=True)
            release_script.write_text(
                "#!/bin/sh\n"
                "while [ \"$#\" -gt 0 ]; do\n"
                "    if [ \"$1\" = \"--version\" ]; then\n"
                "        printf '%s' \"$2\" > \"$VERSION_CAPTURE\"\n"
                "        exit 42\n"
                "    fi\n"
                "    shift\n"
                "done\n"
                "exit 43\n"
            )
            release_script.chmod(0o755)

            capture = repo / "version.txt"
            environment = os.environ.copy()
            environment.pop("SYRINX_BUILD_VERSION", None)
            environment["VERSION_CAPTURE"] = str(capture)
            result = subprocess.run(
                [str(build_script)],
                cwd=repo,
                env=environment,
                capture_output=True,
                text=True,
                check=False,
            )

            self.assertEqual(result.returncode, 42, result.stderr)
            self.assertEqual(capture.read_text(), "1.1.0")


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
