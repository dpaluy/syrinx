#!/usr/bin/env python3
"""Build, sign, notarize, and verify the Syrinx.app distribution artifact."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path
from typing import Any, Dict, Optional


PRODUCT = "Syrinx"
APP_NAME = "Syrinx.app"
EXECUTABLE = "syrinx"
BUNDLE_IDENTIFIER = "com.dpaluy.syrinx"
MINIMUM_MACOS = "14.0"
INFO_PLIST_SOURCE = Path("parrot/Resources/SyrinxApp/Info.plist")
APP_ICON_FILE = "AppIcon.icns"
APP_ICON_SOURCE = Path("parrot/Resources/SyrinxApp") / APP_ICON_FILE
APP_ENTITLEMENTS_SOURCE = Path("parrot/Resources/SyrinxApp/Syrinx.entitlements")
OUTPUT_NAMES = (
    "{product}-{version}.zip",
    "{product}-{version}.metadata.json",
    "{product}-{version}.notary.json",
    "SHA256SUMS",
)
PROHIBITED_USAGE_KEYS = {
    "NSAppleEventsUsageDescription",
    "NSInputMonitoringUsageDescription",
    "NSScreenCaptureUsageDescription",
    "NSSystemAdministrationUsageDescription",
}
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
VERSION_RE = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$")
TAG_RE = re.compile(r"^v[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$")
COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
MAX_TOOL_OUTPUT = 2 * 1024 * 1024
USAGE_DESCRIPTIONS = {
    "NSMicrophoneUsageDescription": "Syrinx records audio only while you hold the Fn or Globe key to transcribe it on this Mac.",
    "NSAccessibilityUsageDescription": "Syrinx uses Accessibility to detect the Fn or Globe key and insert your local transcript at the active cursor.",
}


class AppReleaseError(RuntimeError):
    pass


def fail(message: str) -> None:
    raise AppReleaseError(message)


def run_tool(argv: list[str], cwd: Optional[Path] = None, timeout: int = 20 * 60) -> str:
    try:
        result = subprocess.run(
            argv,
            cwd=str(cwd) if cwd else None,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=timeout,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        fail("could not run %s: %s" % (argv[0], error))
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip().splitlines()
        fail("%s failed%s" % (argv[0], ": " + detail[-1][:400] if detail else ""))
    if len(result.stdout) > MAX_TOOL_OUTPUT or len(result.stderr) > MAX_TOOL_OUTPUT:
        fail("%s produced output over the configured bound" % argv[0])
    return result.stdout


def run_tool_combined(argv: list[str], cwd: Optional[Path] = None, timeout: int = 20 * 60) -> str:
    try:
        result = subprocess.run(
            argv,
            cwd=str(cwd) if cwd else None,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=timeout,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        fail("could not run %s: %s" % (argv[0], error))
    if result.returncode != 0:
        detail = result.stdout.strip().splitlines()
        fail("%s failed%s" % (argv[0], ": " + detail[-1][:400] if detail else ""))
    if len(result.stdout) > MAX_TOOL_OUTPUT:
        fail("%s produced output over the configured bound" % argv[0])
    return result.stdout


def env_or(name: str, default: Optional[str] = None) -> Optional[str]:
    return os.environ.get(name) or default


def require_path(path: Path, label: str) -> Path:
    if path.is_symlink() or not path.exists():
        fail("%s is missing or symlinked: %s" % (label, path))
    return path


def validate_identity(args: argparse.Namespace, source_required: bool = True) -> None:
    if args.version is None or not VERSION_RE.fullmatch(args.version):
        fail("version must be semantic version text")
    if args.tag is None or not TAG_RE.fullmatch(args.tag) or args.tag != "v" + args.version:
        fail("tag must be the annotated v-prefixed form of version")
    if source_required and (args.source_commit is None or not COMMIT_RE.fullmatch(args.source_commit)):
        fail("source commit must be a lowercase 40-character commit ID")
    if args.application_identity and not args.application_identity.startswith("Developer ID Application: "):
        fail("application identity must be a Developer ID Application identity")
    if args.team_id and not re.fullmatch(r"[A-Z0-9]{10}", args.team_id):
        fail("Team ID must be ten uppercase alphanumeric characters")


def validate_source(args: argparse.Namespace) -> None:
    repo = require_path(args.repo_root.resolve(), "repository root")
    validate_identity(args)
    head = run_tool(["git", "rev-parse", "HEAD"], cwd=repo).strip()
    if head != args.source_commit:
        fail("HEAD does not equal the declared source commit")
    if run_tool(["git", "status", "--porcelain=v1", "--untracked-files=all"], cwd=repo).strip():
        fail("source checkout is not clean")
    if run_tool(["git", "cat-file", "-t", "refs/tags/" + args.tag], cwd=repo).strip() != "tag":
        fail("release tag must be annotated")
    if run_tool(["git", "rev-parse", "refs/tags/" + args.tag + "^{}"], cwd=repo).strip() != args.source_commit:
        fail("annotated tag does not target the declared source commit")
    require_path(repo / INFO_PLIST_SOURCE, "Syrinx Info.plist")
    require_path(repo / APP_ICON_SOURCE, "Syrinx app icon")
    load_app_entitlements(repo)


def load_app_entitlements(repo_root: Path) -> Path:
    source = require_path(repo_root / APP_ENTITLEMENTS_SOURCE, "Syrinx signing entitlements")
    try:
        with source.open("rb") as handle:
            entitlements = plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException, ValueError) as error:
        fail("Syrinx signing entitlements are invalid: %s" % error)
    if entitlements != {"com.apple.security.device.audio-input": True}:
        fail("Syrinx signing entitlements must enable only audio input")
    return source


def signed_entitlements(app: Path) -> Dict[str, Any]:
    output = run_tool_combined([
        "codesign", "--display", "--entitlements", ":-", str(app),
    ])
    start = output.find("<?xml")
    if start < 0:
        start = output.find("<plist")
    end = output.find("</plist>", start)
    if start < 0 or end < 0:
        fail("signed app does not contain readable entitlements")
    try:
        value = plistlib.loads(output[start:end + len("</plist>")].encode("utf-8"))
    except (plistlib.InvalidFileException, ValueError) as error:
        fail("signed app entitlements are invalid: %s" % error)
    if not isinstance(value, dict):
        fail("signed app entitlements are not a dictionary")
    return value


def validate_signed_entitlements(app: Path) -> None:
    if signed_entitlements(app).get("com.apple.security.device.audio-input") is not True:
        fail("signed app is missing the audio input entitlement")


def safe_relative(path: Path) -> str:
    relative = path.as_posix()
    if relative.startswith("/") or any(part in ("", ".", "..") for part in Path(relative).parts):
        fail("unsafe archive path")
    return relative


def zip_app(app: Path, destination: Path) -> None:
    files = sorted([path for path in app.rglob("*") if path.is_file()], key=lambda path: path.as_posix())
    directories = {Path("Contents/Resources")}
    for file_path in files:
        relative = file_path.relative_to(app)
        for index in range(1, len(relative.parts)):
            directories.add(Path(*relative.parts[:index]))
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_name("." + destination.name + ".tmp")
    with zipfile.ZipFile(temporary, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for directory in sorted(directories, key=lambda path: path.as_posix()):
            name = safe_relative(Path(APP_NAME) / directory)
            info = zipfile.ZipInfo(name + "/")
            info.date_time = (1980, 1, 1, 0, 0, 0)
            info.create_system = 3
            info.external_attr = (0o755 & 0o777) << 16
            archive.writestr(info, b"")
        for path in files:
            relative = safe_relative(Path(APP_NAME) / path.relative_to(app))
            info = zipfile.ZipInfo(relative)
            info.date_time = (1980, 1, 1, 0, 0, 0)
            info.create_system = 3
            info.external_attr = (stat.S_IMODE(path.stat().st_mode) & 0o777) << 16
            archive.writestr(info, path.read_bytes())
    os.replace(temporary, destination)


def extract_zip(source: Path, destination: Path) -> Path:
    destination.mkdir(parents=True, exist_ok=False)
    with zipfile.ZipFile(source) as archive:
        names = archive.namelist()
        if len(names) > 10000:
            fail("app archive contains too many entries")
        for name in names:
            path = Path(name)
            if path.is_absolute() or any(part in ("", ".", "..") for part in path.parts):
                fail("app archive contains an unsafe path")
            target = destination.joinpath(*path.parts)
            if name.endswith("/"):
                target.mkdir(parents=True, exist_ok=True)
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            temporary = target.with_name("." + target.name + ".extracting")
            with temporary.open("wb") as handle:
                handle.write(archive.read(name))
            os.chmod(temporary, (archive.getinfo(name).external_attr >> 16) & 0o777 or 0o644)
            os.replace(temporary, target)
    app = destination / APP_NAME
    if not app.is_dir():
        fail("app archive does not contain Syrinx.app")
    return app


def validate_app_bundle(app: Path) -> Dict[str, Any]:
    if app.name != APP_NAME or app.is_symlink() or not app.is_dir():
        fail("Syrinx.app has the wrong name or type")
    plist_path = app / "Contents" / "Info.plist"
    executable = app / "Contents" / "MacOS" / EXECUTABLE
    resources = app / "Contents" / "Resources"
    require_path(plist_path, "app Info.plist")
    require_path(executable, "app executable")
    require_path(resources, "app Resources directory")
    icon = resources / APP_ICON_FILE
    require_path(icon, "app icon")
    if not icon.is_file():
        fail("app icon is not a regular file")
    try:
        with plist_path.open("rb") as handle:
            info = plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException, ValueError) as error:
        fail("app Info.plist is invalid: %s" % error)
    expected = {
        "CFBundleDisplayName": PRODUCT,
        "CFBundleExecutable": EXECUTABLE,
        "CFBundleIdentifier": BUNDLE_IDENTIFIER,
        "CFBundleName": PRODUCT,
        "CFBundlePackageType": "APPL",
        "CFBundleIconFile": APP_ICON_FILE,
        "LSMinimumSystemVersion": MINIMUM_MACOS,
    }
    for key, value in expected.items():
        if info.get(key) != value:
            fail("app Info.plist has an incorrect %s" % key)
    if info.get("LSUIElement") is not True:
        fail("app must be a menu bar-only application")
    for key, value in USAGE_DESCRIPTIONS.items():
        if info.get(key) != value:
            fail("app Info.plist has an incorrect %s" % key)
    if PROHIBITED_USAGE_KEYS.intersection(info):
        fail("app requests a prohibited macOS permission")
    if stat.S_IMODE(executable.stat().st_mode) != 0o755:
        fail("app executable must have mode 0755")
    return info


def copy_runtime(binary: Path, frameworks: Path) -> None:
    frameworks.mkdir(parents=True, exist_ok=True)
    if sys.platform == "darwin":
        run_tool([
            "xcrun", "swift-stdlib-tool", "--copy", "--scan-executable",
            str(binary), "--destination", str(frameworks), "--platform", "macosx",
        ])


def make_app(args: argparse.Namespace, binary: Path, destination: Path, workspace: Path) -> Path:
    app = workspace / APP_NAME
    contents = app / "Contents"
    macos = contents / "MacOS"
    resources = contents / "Resources"
    macos.mkdir(parents=True)
    resources.mkdir()
    target = macos / EXECUTABLE
    shutil.copyfile(binary, target)
    os.chmod(target, 0o755)
    copy_runtime(target, contents / "Frameworks")
    icon_source = require_path(args.repo_root / APP_ICON_SOURCE, "Syrinx app icon")
    if not icon_source.is_file():
        fail("Syrinx app icon is not a regular file")
    shutil.copyfile(icon_source, resources / APP_ICON_FILE)
    with (args.repo_root / INFO_PLIST_SOURCE).open("rb") as handle:
        info = plistlib.load(handle)
    info["CFBundleShortVersionString"] = args.version
    info["CFBundleVersion"] = args.version
    with (contents / "Info.plist").open("wb") as handle:
        plistlib.dump(info, handle, sort_keys=False)
    validate_app_bundle(app)
    zip_app(app, destination)
    return app


def signing_keychain_args(args: argparse.Namespace) -> list[str]:
    return ["--keychain", args.signing_keychain] if args.signing_keychain else []


def sign_app(args: argparse.Namespace, app: Path) -> None:
    if sys.platform != "darwin":
        fail("Apple signing requires macOS")
    if not args.application_identity:
        fail("signed app requires RELEASE_APPLICATION_IDENTITY")
    entitlements = load_app_entitlements(args.repo_root)
    for path in sorted(app.rglob("*"), key=lambda item: (len(item.parts), item.as_posix()), reverse=True):
        if path.is_file() and path.suffix == ".dylib":
            run_tool([
                "codesign", "--force", "--options", "runtime", "--timestamp",
                "--sign", args.application_identity, *signing_keychain_args(args), str(path),
            ])
    run_tool([
        "codesign", "--force", "--options", "runtime", "--timestamp",
        "--entitlements", str(entitlements),
        "--sign", args.application_identity, *signing_keychain_args(args), str(app),
    ])
    run_tool(["codesign", "--verify", "--deep", "--strict", "--verbose=2", str(app)])
    validate_signed_entitlements(app)
    display = run_tool(["codesign", "--display", "--verbose=4", str(app)])
    if args.team_id and ("TeamIdentifier=" + args.team_id) not in display:
        fail("app signature Team ID does not match RELEASE_TEAM_ID")


def notarize_app(args: argparse.Namespace, app: Path, workspace: Path) -> Dict[str, Any]:
    if not args.notary_profile:
        fail("signed app requires RELEASE_NOTARY_PROFILE")
    submission = workspace / "Syrinx-notary-input.zip"
    zip_app(app, submission)
    result = run_tool([
        "xcrun", "notarytool", "submit", str(submission),
        "--keychain-profile", args.notary_profile,
        "--wait", "--output-format", "json",
    ], timeout=45 * 60)
    try:
        parsed = json.loads(result)
    except ValueError as error:
        fail("notarytool did not return JSON: %s" % error)
    if not isinstance(parsed, dict) or parsed.get("status") != "Accepted":
        fail("notarytool did not accept Syrinx.app")
    run_tool(["xcrun", "stapler", "staple", str(app)], timeout=10 * 60)
    run_tool(["xcrun", "stapler", "validate", "-v", str(app)], timeout=10 * 60)
    run_tool(["spctl", "--assess", "--type", "execute", "--verbose=4", str(app)], timeout=10 * 60)
    return {"schemaVersion": 1, "status": "Accepted", "requestUUID": parsed.get("id")}


def write_metadata(args: argparse.Namespace, destination: Path, signed: bool) -> None:
    metadata = {
        "schemaVersion": 1,
        "product": PRODUCT,
        "bundleIdentifier": BUNDLE_IDENTIFIER,
        "executable": EXECUTABLE,
        "version": args.version,
        "tag": args.tag,
        "sourceCommit": args.source_commit,
        "architecture": "arm64",
        "minimumMacOS": MINIMUM_MACOS,
        "signed": signed,
        "notarized": signed,
        "localTranscription": True,
        "transcriptionEngine": "WhisperKit in-process",
        "requiredPermissions": ["Microphone", "Accessibility"],
        "fnKeySetting": "Do Nothing",
        "prohibitedPermissions": sorted(PROHIBITED_USAGE_KEYS),
    }
    destination.write_text(json.dumps(metadata, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def write_checksums(output: Path) -> None:
    names = sorted(path.name for path in output.iterdir() if path.is_file() and path.name != "SHA256SUMS")
    lines = []
    for name in names:
        digest = hashlib.sha256((output / name).read_bytes()).hexdigest()
        lines.append("%s  %s" % (digest, name))
    (output / "SHA256SUMS").write_text("\n".join(lines) + "\n", encoding="utf-8")


def expected_output(args: argparse.Namespace) -> set[str]:
    return {template.format(product=PRODUCT, version=args.version) for template in OUTPUT_NAMES}


def read_handoff_inventory(args: argparse.Namespace, input_dir: Path) -> Dict[str, Any]:
    if input_dir.is_symlink():
        fail("app handoff directory may not be a symlink")
    input_dir = require_path(input_dir.resolve(), "app handoff directory")
    if not input_dir.is_dir():
        fail("app handoff path is not a directory")
    inventory_path = input_dir / "artifact-inventory.json"
    require_path(inventory_path, "app handoff inventory")
    try:
        inventory = json.loads(inventory_path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        fail("app handoff inventory is invalid: %s" % error)
    if not isinstance(inventory, dict) or set(inventory) != {
        "schemaVersion", "productIdentity", "version", "tag", "sourceCommit", "artifacts", "excludesSelf"
    }:
        fail("app handoff inventory schema is invalid")
    if (
        inventory.get("schemaVersion") != 1
        or inventory.get("productIdentity") != PRODUCT
        or inventory.get("version") != args.version
        or inventory.get("tag") != args.tag
        or inventory.get("sourceCommit") != args.source_commit
        or inventory.get("excludesSelf") is not True
        or not isinstance(inventory.get("artifacts"), list)
    ):
        fail("app handoff inventory identity is invalid")
    expected_names = expected_output(args)
    artifacts = inventory["artifacts"]
    if {item.get("name") for item in artifacts if isinstance(item, dict)} != expected_names:
        fail("app handoff inventory does not cover the exact app outputs")
    if len(artifacts) != len(expected_names):
        fail("app handoff inventory contains duplicate or extra outputs")
    for item in artifacts:
        if (
            not isinstance(item, dict)
            or set(item) != {"name", "size", "sha256"}
            or item["name"] not in expected_names
            or not isinstance(item["size"], int)
            or item["size"] < 0
            or not SHA256_RE.fullmatch(str(item["sha256"]))
        ):
            fail("app handoff inventory entry is invalid")
        path = input_dir / item["name"]
        require_path(path, "app handoff output")
        if not path.is_file() or path.stat().st_size != item["size"]:
            fail("app handoff output size does not match its inventory")
        if hashlib.sha256(path.read_bytes()).hexdigest() != item["sha256"]:
            fail("app handoff output digest does not match its inventory")
    if {path.name for path in input_dir.iterdir()} != expected_names | {"artifact-inventory.json"}:
        fail("app handoff directory contains unexpected files")
    return inventory


def create_handoff(args: argparse.Namespace) -> None:
    if args.input_dir.is_symlink():
        fail("app handoff source directory may not be a symlink")
    source = args.input_dir.resolve()
    if not source.is_dir():
        fail("app handoff source directory is invalid")
    original_output = args.output_dir
    args.output_dir = source
    try:
        verify_output(args, signed=False)
    finally:
        args.output_dir = original_output
    if args.output_dir.is_symlink():
        fail("app handoff output directory may not be a symlink")
    destination = args.output_dir.resolve()
    if destination.exists():
        fail("app handoff output directory must be new")
    destination.mkdir(parents=True)
    try:
        for name in sorted(expected_output(args)):
            source_file = require_path(source / name, "app release output")
            if not source_file.is_file():
                fail("app release output is not a regular file: " + name)
            target = destination / name
            shutil.copyfile(source_file, target)
            os.chmod(target, stat.S_IMODE(source_file.stat().st_mode))
        inventory = {
            "schemaVersion": 1,
            "productIdentity": PRODUCT,
            "version": args.version,
            "tag": args.tag,
            "sourceCommit": args.source_commit,
            "artifacts": [
                {
                    "name": name,
                    "size": (destination / name).stat().st_size,
                    "sha256": hashlib.sha256((destination / name).read_bytes()).hexdigest(),
                }
                for name in sorted(expected_output(args))
            ],
            "excludesSelf": True,
        }
        (destination / "artifact-inventory.json").write_text(
            json.dumps(inventory, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
    except BaseException:
        shutil.rmtree(destination, ignore_errors=True)
        raise
    read_handoff_inventory(args, destination)
    print(json.dumps({"handoff": str(destination), "files": len(expected_output(args))}, sort_keys=True))


def import_handoff(args: argparse.Namespace) -> None:
    read_handoff_inventory(args, args.input_dir)
    if args.output_dir.is_symlink():
        fail("app release output directory may not be a symlink")
    destination = args.output_dir.resolve()
    if destination.is_symlink() or (destination.exists() and not destination.is_dir()):
        fail("app release output directory is invalid")
    if destination.exists() and any(destination.iterdir()):
        fail("app release output directory must be new and empty")
    destination.mkdir(parents=True, exist_ok=True)
    for name in sorted(expected_output(args)):
        source = args.input_dir.resolve() / name
        target = destination / name
        shutil.copyfile(source, target)
        os.chmod(target, stat.S_IMODE(source.stat().st_mode))
    verify_output(args, signed=False)
    print(json.dumps({"output": str(destination), "imported": True}, sort_keys=True))


def verify_output(args: argparse.Namespace, signed: bool) -> None:
    if args.output_dir.is_symlink():
        fail("release output directory may not be a symlink")
    output = args.output_dir.resolve()
    if not output.is_dir():
        fail("release output directory is missing")
    expected = expected_output(args)
    if {path.name for path in output.iterdir()} != expected:
        fail("release output files are not exact")
    metadata_path = output / ("%s-%s.metadata.json" % (PRODUCT, args.version))
    notary_path = output / ("%s-%s.notary.json" % (PRODUCT, args.version))
    metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
    notary = json.loads(notary_path.read_text(encoding="utf-8"))
    if (
        metadata.get("bundleIdentifier") != BUNDLE_IDENTIFIER
        or metadata.get("version") != args.version
        or metadata.get("tag") != args.tag
        or metadata.get("sourceCommit") != args.source_commit
        or metadata.get("signed") is not signed
    ):
        fail("release metadata does not match the verification mode")
    if signed and notary.get("status") != "Accepted":
        fail("signed release does not contain an Accepted notarization result")
    if not signed and notary.get("status") != "Not Applicable":
        fail("unsigned dry run has a signing result")
    with tempfile.TemporaryDirectory(prefix="syrinx-app-verify-") as raw:
        app = extract_zip(output / ("%s-%s.zip" % (PRODUCT, args.version)), Path(raw) / "input")
        info = validate_app_bundle(app)
        if info.get("CFBundleShortVersionString") != args.version:
            fail("app version does not match the release version")
        if signed:
            run_tool(["codesign", "--verify", "--deep", "--strict", "--verbose=2", str(app)])
            validate_signed_entitlements(app)
    lines = (output / "SHA256SUMS").read_text(encoding="utf-8").splitlines()
    names = set()
    for line in lines:
        match = re.fullmatch(r"([0-9a-f]{64})  (.+)", line)
        if not match or match.group(2) not in expected:
            fail("SHA256SUMS contains an invalid entry")
        name = match.group(2)
        names.add(name)
        if hashlib.sha256((output / name).read_bytes()).hexdigest() != match.group(1):
            fail("SHA256SUMS does not match the release output")
    if names != expected - {"SHA256SUMS"}:
        fail("SHA256SUMS does not cover every release output")


def build(args: argparse.Namespace) -> None:
    if args.sign == args.unsigned_dry_run:
        fail("choose exactly one of --unsigned-dry-run or --sign")
    if args.skip_source_validation and not args.unsigned_dry_run:
        fail("--skip-source-validation is only allowed for an unsigned dry run")
    if not args.skip_source_validation:
        validate_source(args)
    output = args.output_dir.resolve()
    if output.exists() and any(output.iterdir()):
        fail("release output directory must be new and empty")
    output.mkdir(parents=True, exist_ok=True)
    if args.swift_build:
        run_tool([
            "swift", "build", "--package-path", "parrot",
            "--configuration", "release", "--product", EXECUTABLE, "--arch", "arm64",
        ], cwd=args.repo_root)
        binary = Path(run_tool([
            "swift", "build", "--package-path", "parrot",
            "--show-bin-path", "--configuration", "release",
        ], cwd=args.repo_root).strip()) / EXECUTABLE
    elif args.binary:
        binary = Path(args.binary).resolve()
    else:
        fail("build requires --swift-build or --binary")
    require_path(binary, "Syrinx executable")
    zip_path = output / ("%s-%s.zip" % (PRODUCT, args.version))
    workspace = Path(tempfile.mkdtemp(prefix="syrinx-app-"))
    try:
        app = make_app(args, binary, zip_path, workspace)
        signed = False
        notary = {"schemaVersion": 1, "status": "Not Applicable"}
        if args.sign:
            sign_app(args, app)
            notary = notarize_app(args, app, workspace)
            zip_app(app, zip_path)
            signed = True
        write_metadata(args, output / ("%s-%s.metadata.json" % (PRODUCT, args.version)), signed)
        (output / ("%s-%s.notary.json" % (PRODUCT, args.version))).write_text(
            json.dumps(notary, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
        write_checksums(output)
        verify_output(args, signed)
    finally:
        shutil.rmtree(workspace, ignore_errors=True)
    print(json.dumps({"output": str(output), "app": APP_NAME, "signed": signed}, sort_keys=True))


def sign_input(args: argparse.Namespace) -> None:
    validate_source(args)
    output = args.output_dir.resolve()
    archive = output / ("%s-%s.zip" % (PRODUCT, args.version))
    require_path(archive, "unsigned app archive")
    verify_output(args, signed=False)
    workspace = Path(tempfile.mkdtemp(prefix="syrinx-sign-input-"))
    try:
        app = extract_zip(archive, workspace / "input")
        validate_app_bundle(app)
        sign_app(args, app)
        notary = notarize_app(args, app, workspace)
        zip_app(app, archive)
        write_metadata(args, output / ("%s-%s.metadata.json" % (PRODUCT, args.version)), True)
        (output / ("%s-%s.notary.json" % (PRODUCT, args.version))).write_text(
            json.dumps(notary, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
        write_checksums(output)
        verify_output(args, signed=True)
    finally:
        shutil.rmtree(workspace, ignore_errors=True)
    print(json.dumps({"output": str(output), "app": APP_NAME, "signed": True}, sort_keys=True))


def verify_release(args: argparse.Namespace) -> None:
    if not args.skip_source_validation:
        validate_source(args)
    verify_output(args, args.signed)
    print(json.dumps({"output": str(args.output_dir.resolve()), "signed": args.signed}, sort_keys=True))


def validate_source_command(args: argparse.Namespace) -> None:
    validate_source(args)
    print(json.dumps({"tag": args.tag, "sourceCommit": args.source_commit, "annotated": True, "clean": True}, sort_keys=True))


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(prog="app-release.py")
    subparsers = result.add_subparsers(dest="command", required=True)

    def common(command: argparse.ArgumentParser) -> None:
        command.add_argument("--repo-root", type=Path, default=Path(env_or("RELEASE_REPO_ROOT", ".") or "."))
        command.add_argument("--output-dir", type=Path, default=Path(env_or("RELEASE_OUTPUT_DIR", "dist") or "dist"))
        command.add_argument("--version", default=env_or("RELEASE_VERSION", "0.0.0"))
        command.add_argument("--tag", default=env_or("RELEASE_TAG", "v0.0.0"))
        command.add_argument("--source-commit", default=env_or("RELEASE_SOURCE_COMMIT"))
        command.add_argument("--binary", default=env_or("RELEASE_BINARY"))
        command.add_argument("--application-identity", default=env_or("RELEASE_APPLICATION_IDENTITY"))
        command.add_argument("--team-id", default=env_or("RELEASE_TEAM_ID"))
        command.add_argument("--notary-profile", default=env_or("RELEASE_NOTARY_PROFILE"))
        command.add_argument("--signing-keychain", default=env_or("RELEASE_SIGNING_KEYCHAIN"))
        command.add_argument("--skip-source-validation", action="store_true")

    build_command = subparsers.add_parser("build")
    common(build_command)
    build_command.add_argument("--swift-build", action="store_true")
    build_command.add_argument("--unsigned-dry-run", action="store_true")
    build_command.add_argument("--sign", action="store_true")
    build_command.set_defaults(handler=build)

    sign_command = subparsers.add_parser("sign-input")
    common(sign_command)
    sign_command.set_defaults(handler=sign_input)

    source_parser = subparsers.add_parser("validate-source")
    common(source_parser)
    source_parser.set_defaults(handler=validate_source_command)

    verify_parser = subparsers.add_parser("verify")
    common(verify_parser)
    verify_parser.add_argument("--signed", action="store_true")
    verify_parser.set_defaults(handler=verify_release)

    create_handoff_parser = subparsers.add_parser("create-handoff")
    common(create_handoff_parser)
    create_handoff_parser.add_argument("--input-dir", type=Path, required=True)
    create_handoff_parser.set_defaults(handler=create_handoff)

    import_handoff_parser = subparsers.add_parser("import-handoff")
    common(import_handoff_parser)
    import_handoff_parser.add_argument("--input-dir", type=Path, required=True)
    import_handoff_parser.set_defaults(handler=import_handoff)

    return result


def main() -> int:
    try:
        args = parser().parse_args()
        args.handler(args)
        return 0
    except AppReleaseError as error:
        print("error: " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
