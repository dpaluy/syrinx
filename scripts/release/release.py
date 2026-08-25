#!/usr/bin/env python3
"""Fail-closed release tooling for the standalone native macOS service.

The command uses argv-only subprocess calls. It never invokes a shell for
release values, and all captured external output is bounded and redacted.
"""

from __future__ import annotations

import argparse
import base64
import binascii
import ctypes
import datetime as dt
import hashlib
import http.client
import ipaddress
import io
import json
import os
import plistlib
import re
import selectors
import signal
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
import unicodedata
import urllib.error
import urllib.request
import zipfile
import uuid
from pathlib import Path, PurePosixPath
from typing import Any, Dict, Iterable, List, Optional, Sequence, Set, Tuple
from urllib.parse import quote, urlsplit


MAX_TOOL_OUTPUT = 64 * 1024
MAX_TOOL_SECONDS = 20 * 60
MAX_SIGNING_STATE_BYTES = 64 * 1024
MAX_SCAN_BYTES_PER_FILE = 2 * 1024 * 1024 * 1024
MAX_SCAN_BYTES_TOTAL = 8 * 1024 * 1024 * 1024
MAX_ARCHIVE_MEMBERS = 10000
MAX_ARCHIVE_MEMBER_BYTES = 2 * 1024 * 1024 * 1024
MAX_ARCHIVE_DECLARED_BYTES = 8 * 1024 * 1024 * 1024
MAX_ARTIFACT_ARCHIVE_BYTES = 8 * 1024 * 1024 * 1024
MAX_ARTIFACT_REDIRECT_LOCATION_BYTES = 4096
SECRET_VALUES: Set[str] = set()
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
VERSION_RE = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$")
TAG_RE = re.compile(r"^v[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$")
IDENTITY_RE = re.compile(r"^[A-Za-z][A-Za-z0-9_-]{2,63}$")
EXECUTABLE_RE = re.compile(r"^[A-Za-z][A-Za-z0-9._-]{1,127}$")
PACKAGE_ID_RE = re.compile(r"^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$")
SERVICE_LABEL_RE = PACKAGE_ID_RE
TEAM_ID_RE = re.compile(r"^[A-Z0-9]{10}$")
FORMULA_CLASS_RE = re.compile(r"^[A-Z][A-Za-z0-9]{1,63}$")
PLACEHOLDER_RE = re.compile(
    r"(?:newname|new-name|placeholder|unresolved|not[- ]selected|todo|example\.(?:com|org|net|invalid)|<[^>]+>)",
    re.IGNORECASE,
)
MUTABLE_URL_RE = re.compile(r"/(?:main|master|latest)(?:/|$)|/(?:resolve|raw)/[^/]+/(?:latest|main|master)(?:/|$)", re.IGNORECASE)
MODEL_BYTE_RE = re.compile(
    r"(?:^|/)(?:[^/]+\.(?:mlmodel|mlmodelc|mlpackage|safetensors|onnx|pt|pth|bin|mil)|"
    r"(?:[^/]+\.(?:mlmodelc|mlpackage))(?:/.*)?|(?:weights|weight|models?)(?:/|$))",
    re.IGNORECASE,
)
ABSOLUTE_BUILD_RE = re.compile(r"(?:^|[\" ])/(?:Users|home|private/tmp|tmp)/[A-Za-z0-9_. -]+")
MODEL_REPOSITORY = "FluidInference/parakeet-tdt-0.6b-v3-coreml"
MODEL_HOST = "huggingface.co"
PAYLOAD_ROOT_PREFIX = PurePosixPath("Library") / "Application Support"
OUTPUT_RESERVED_NAMES = {"artifact-inventory.json", "SHA256SUMS", "SHA256SUMS.sig"}
STATE_KEYS = {"schemaVersion", "keychain", "oldKeychains", "temporaryFiles", "profile"}
ARTIFACT_ID_RE = re.compile(r"^[1-9][0-9]{0,19}$")
ARTIFACT_DIGEST_RE = re.compile(r"^[0-9a-f]{64}$")
KEYCHAIN_PATH_RE = re.compile(r"^/(?:Users/[^/]+/Library/Keychains|Library/Keychains)/[^/]+\.keychain(?:-db)?$")
CERTIFICATE_IDENTITY_RE = re.compile(r"^Developer ID (Application|Installer): .+ \(([A-Z0-9]{10})\)$")
SYSTEM_DEPENDENCY_CONTRACT = {
    "/usr/lib/libc++.1.dylib", "/usr/lib/libSystem.B.dylib", "/usr/lib/libobjc.A.dylib",
    "/usr/lib/swift/libswiftAVFoundation.dylib", "/usr/lib/swift/libswiftAccelerate.dylib",
    "/usr/lib/swift/libswiftCore.dylib", "/usr/lib/swift/libswiftCoreAudio.dylib",
    "/usr/lib/swift/libswiftCoreFoundation.dylib", "/usr/lib/swift/libswiftCoreImage.dylib",
    "/usr/lib/swift/libswiftCoreMIDI.dylib", "/usr/lib/swift/libswiftCoreMedia.dylib",
    "/usr/lib/swift/libswiftDarwin.dylib", "/usr/lib/swift/libswiftDispatch.dylib",
    "/usr/lib/swift/libswiftIOKit.dylib", "/usr/lib/swift/libswiftMetal.dylib",
    "/usr/lib/swift/libswiftNaturalLanguage.dylib", "/usr/lib/swift/libswiftOSLog.dylib",
    "/usr/lib/swift/libswiftObjectiveC.dylib", "/usr/lib/swift/libswiftQuartzCore.dylib",
    "/usr/lib/swift/libswiftSynchronization.dylib", "/usr/lib/swift/libswiftSystem.dylib",
    "/usr/lib/swift/libswiftUniformTypeIdentifiers.dylib", "/usr/lib/swift/libswiftXPC.dylib",
    "/usr/lib/swift/libswift_Concurrency.dylib", "/usr/lib/swift/libswift_StringProcessing.dylib",
    "/usr/lib/swift/libswiftos.dylib", "/usr/lib/swift/libswiftsimd.dylib",
    "/usr/lib/swift/libswiftCoreML.dylib",
    "/System/Library/Frameworks/AVFAudio.framework/Versions/A/AVFAudio",
    "/System/Library/Frameworks/Accelerate.framework/Versions/A/Accelerate",
    "/System/Library/Frameworks/CFNetwork.framework/Versions/A/CFNetwork",
    "/System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation",
    "/System/Library/Frameworks/CoreML.framework/Versions/A/CoreML",
    "/System/Library/Frameworks/CoreMedia.framework/Versions/A/CoreMedia",
    "/System/Library/Frameworks/CryptoKit.framework/Versions/A/CryptoKit",
    "/System/Library/Frameworks/Foundation.framework/Versions/C/Foundation",
    "/System/Library/Frameworks/NaturalLanguage.framework/Versions/A/NaturalLanguage",
    "/System/Library/Frameworks/Network.framework/Versions/A/Network",
    "/System/Library/Frameworks/Security.framework/Versions/A/Security",
}
ALLOWED_RPATHS = {"@loader_path", "@executable_path", "/usr/lib/swift"}
SCAN_MARKERS = (b"Syrinx", b"syrinx", b"/Users/", b"/home/", b"/private/tmp/", b"/tmp/")
SUPPORTED_MODEL_FILES = {
    "Decoder.mlmodelc/analytics/coremldata.bin": (243, "4238c4e81ecd0dc94bd7dfbb60f7e2cc824107c1ffe0387b8607b72833dba350"),
    "Decoder.mlmodelc/coremldata.bin": (554, "18647af085d87bd8f3121c8a9b4d4564c1ede038dab63d295b4e745cf2d7fb99"),
    "Decoder.mlmodelc/metadata.json": (3427, "a39e93cd8371b8ded92635c7804fcd0590f0d1dd9415c6d19a0484be073077d9"),
    "Decoder.mlmodelc/model.mil": (13110, "ef2a0a281695398a62fde86ac269c68f73d5b578d7ed3b31f2ba91a2d1ea1f35"),
    "Decoder.mlmodelc/weights/weight.bin": (23604992, "48adf0f0d47c406c8253d4f7fef967436a39da14f5a65e66d5a4b407be355d41"),
    "Encoder.mlmodelc/analytics/coremldata.bin": (243, "42e638870d73f26b332918a3496ce36793fbb413a81cbd3d16ba01328637a105"),
    "Encoder.mlmodelc/coremldata.bin": (485, "d48034a167a82e88fc3df64f60af963ab3983538271175b8319e7d5720a0fb86"),
    "Encoder.mlmodelc/metadata.json": (2921, "da24da9cca943fb29d7fa8e376d57fca7cb3aa08ca51b956b0b0e56813f087e9"),
    "Encoder.mlmodelc/model.mil": (959769, "ed7b19156ca29fa7dfd6891deb9fda4b0e8893f68597c985d135736546a43808"),
    "Encoder.mlmodelc/weights/weight.bin": (445187200, "e2020f323703477a5b21d7c2d282c403e371afb5962e79877e3033e73ba6f421"),
    "JointDecisionv3.mlmodelc/analytics/coremldata.bin": (243, "26def4bf73dd56d29dee21c8ef97cb8969e62f6120ed1adc91e46828e2737b6c"),
    "JointDecisionv3.mlmodelc/coremldata.bin": (521, "f5fc08b741400f0088492c9e839418b1e18522f19cba28d361dd030c5f398342"),
    "JointDecisionv3.mlmodelc/metadata.json": (3453, "d9307211b9a37e0f0ac260c7660b1571a3de25841035cfdf9b58fd40425f890f"),
    "JointDecisionv3.mlmodelc/model.mil": (11775, "be60732943389a047175111a83f8839f3eb39d4803adafa828a0871b2f39818d"),
    "JointDecisionv3.mlmodelc/weights/weight.bin": (12642764, "4e0e63d840032f7f07ddb1d64446051166281e5491bf22da8a945c41f6eedb3e"),
    "Preprocessor.mlmodelc/analytics/coremldata.bin": (243, "c9beeb989c8d66f8be11df59bc6df277ec76cee404f6865b46243835ef562f6d"),
    "Preprocessor.mlmodelc/coremldata.bin": (486, "dbde3f2300842c1fd51ef3ff948a0bcffe65ffd2dca10707f2509f32c1d65b1d"),
    "Preprocessor.mlmodelc/metadata.json": (2841, "2a98699e22d279dd37fa1d238aeb1c6db1df0d6fad687775324157689d8f3acf"),
    "Preprocessor.mlmodelc/model.mil": (28181, "4b8518a956450fec57f06c2a21bdffc26973f7f1fa6842fb38fe917f896b6b93"),
    "Preprocessor.mlmodelc/weights/weight.bin": (491072, "129b76e3aeafa8afa3ea76d995b964b145fe83700d579f6ff42c4c38fa0968ea"),
    "parakeet_vocab.json": (151122, "7ec60e05f1b24480736ec0eed40900f4626bce1fa9a60fd700ec7e2a59198735"),
}
SUPPORTED_MODEL_ROOTS = ["Preprocessor.mlmodelc", "Encoder.mlmodelc", "Decoder.mlmodelc", "JointDecisionv3.mlmodelc", "parakeet_vocab.json"]
SUPPORTED_MODEL_COMMIT = "aed02740059203c4a87495924f685de3722ae9ce"
SUPPORTED_FLUIDAUDIO_COMMIT = "19600a485baa4998812e4654b70d2bab8f2c9949"
MANIFEST_DIGEST_PROCEDURE = "Serialize this JSON as UTF-8 with LF line endings, recursively sort object keys, preserve array order, remove the manifestContentDigest property, emit compact JSON with no trailing newline, then hash the bytes with SHA-256."
MANIFEST_DIGEST_SELF_EXCLUSION = "The manifestContentDigest property is excluded before hashing to avoid a self-reference."
SWIFT_RESOURCE_BUNDLE_NAME = "SYRINX_SyrinxCore.bundle"
SWIFT_RESOURCE_MANIFEST_NAME = "parakeet-tdt-0.6b-v3-int8.json"
DISABLED_SWIFTPM_FALLBACK = b"__T50B_SWIFTPM_RESOURCE_FALLBACK_DISABLED__"


class ReleaseError(RuntimeError):
    pass


def fail(message: str) -> None:
    raise ReleaseError(message)


def redact(text: str) -> str:
    for value in sorted(SECRET_VALUES, key=len, reverse=True):
        if value:
            text = text.replace(value, "[REDACTED]")
    text = re.sub(r"(?i)(password|passwd|token|secret|private[_ -]?key|api[_ -]?key)=\S+", r"\1=[REDACTED]", text)
    text = re.sub(r"(?i)(authorization:\s*bearer\s+)\S+", r"\1[REDACTED]", text)
    return text[:MAX_TOOL_OUTPUT]


def controlled_environment(additions: Optional[Dict[str, str]] = None) -> Dict[str, str]:
    """Return a non-secret environment. Secrets enter only explicit commands."""
    allowed = {
        "PATH", "HOME", "TMPDIR", "TMP", "TEMP", "LANG", "LC_ALL", "USER", "LOGNAME",
        "GIT_CONFIG_NOSYSTEM", "GIT_TERMINAL_PROMPT", "DEVELOPER_DIR", "COPYFILE_DISABLE",
    }
    result = {key: value for key, value in os.environ.items() if key in allowed}
    result.setdefault("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
    if additions:
        result.update(additions)
    return result


def run_tool(
    argv: Sequence[str],
    cwd: Optional[Path] = None,
    timeout: int = MAX_TOOL_SECONDS,
    env: Optional[Dict[str, str]] = None,
    input_bytes: Optional[bytes] = None,
) -> Tuple[int, str, str]:
    """Run a tool without a shell and bound both output streams."""

    if not argv or any(not isinstance(value, str) for value in argv):
        fail("invalid tool invocation")
    process_env = controlled_environment(env)
    try:
        process = subprocess.Popen(
            list(argv),
            cwd=str(cwd) if cwd else None,
            env=process_env,
            stdin=subprocess.PIPE if input_bytes is not None else subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            close_fds=True,
            start_new_session=True,
        )
    except OSError as error:
        fail("could not start %s: %s" % (argv[0], error))

    assert process.stdout is not None
    assert process.stderr is not None
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ, "stdout")
    selector.register(process.stderr, selectors.EVENT_READ, "stderr")
    captured = {"stdout": bytearray(), "stderr": bytearray()}
    started = time.monotonic()
    failure: Optional[str] = None

    def terminate_group() -> None:
        if process.poll() is not None:
            try:
                process.wait()
            except ChildProcessError:
                pass
            return
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except (OSError, ProcessLookupError):
            try:
                process.terminate()
            except OSError:
                pass
        try:
            process.wait(timeout=1)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except (OSError, ProcessLookupError):
                try:
                    process.kill()
                except OSError:
                    pass
            process.wait()

    try:
        if input_bytes is not None:
            assert process.stdin is not None
            try:
                process.stdin.write(input_bytes)
                process.stdin.close()
            except BrokenPipeError:
                process.stdin.close()

        while selector.get_map():
            if time.monotonic() - started > timeout:
                failure = "tool timed out: %s" % argv[0]
                break
            for key, _ in selector.select(0.2):
                chunk = os.read(key.fileobj.fileno(), 8192)
                if not chunk:
                    selector.unregister(key.fileobj)
                    key.fileobj.close()
                    continue
                stream = key.data
                captured[stream].extend(chunk)
                if len(captured[stream]) > MAX_TOOL_OUTPUT:
                    failure = "tool output exceeded the %d-byte bound: %s" % (MAX_TOOL_OUTPUT, argv[0])
                    break
            if failure:
                break
        if failure:
            terminate_group()
        return_code = process.wait()
    except BaseException:
        terminate_group()
        raise
    finally:
        try:
            selector.close()
        finally:
            for stream in (process.stdout, process.stderr, process.stdin):
                if stream is not None:
                    try:
                        stream.close()
                    except OSError:
                        pass
    stdout = captured["stdout"].decode("utf-8", errors="replace")
    stderr = captured["stderr"].decode("utf-8", errors="replace")
    if failure:
        fail(failure)
    if return_code != 0:
        details = redact((stderr or stdout).strip())
        fail("%s failed with exit %d%s" % (argv[0], return_code, ": " + details if details else ""))
    return return_code, stdout, stderr


def canonical_json(value: Any) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")


def json_bytes(value: Any) -> bytes:
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + "\n").encode("utf-8")


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    return sha256_file_pinned(path)[1]


def stat_identity(value: os.stat_result) -> Tuple[int, int, int, int, int, int, int]:
    return (value.st_dev, value.st_ino, value.st_mode, value.st_nlink, value.st_size, value.st_mtime_ns, value.st_ctime_ns)


def immutable_stat_identity(value: Any) -> Tuple[int, int, int, int, int, int]:
    """Return identity fields that must not change during a pinned read."""

    if isinstance(value, os.stat_result):
        return (value.st_dev, value.st_ino, value.st_mode, value.st_nlink, value.st_size, value.st_mtime_ns)
    if isinstance(value, tuple):
        return value[:6]
    return (value.st_dev, value.st_ino, value.st_mode, value.st_nlink, value.st_size, value.st_mtime_ns)


def identity_matches(before: Any, after: Any, allow_ctime_change: bool = False) -> bool:
    if immutable_stat_identity(before) != immutable_stat_identity(after):
        return False
    before_ctime = before[6] if isinstance(before, tuple) and not isinstance(before, os.stat_result) else before.st_ctime_ns
    after_ctime = after[6] if isinstance(after, tuple) and not isinstance(after, os.stat_result) else after.st_ctime_ns
    return allow_ctime_change or before_ctime == after_ctime


def open_pinned_regular(path: Path, label: str, private: bool = False) -> Tuple[int, Tuple[int, int, int, int, int, int, int]]:
    try:
        before = os.lstat(path)
    except OSError as error:
        fail("%s is not readable: %s" % (label, error))
    if not stat.S_ISREG(before.st_mode) or stat.S_ISLNK(before.st_mode) or before.st_nlink != 1:
        fail("%s must be a single-link regular file" % label)
    if private and stat.S_IMODE(before.st_mode) & 0o077:
        fail("%s must be private" % label)
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)
    try:
        descriptor = os.open(str(path), flags)
    except OSError as error:
        fail("%s could not be opened safely: %s" % (label, error))
    identity = stat_identity(before)
    try:
        opened = os.fstat(descriptor)
        if stat_identity(opened) != identity:
            os.close(descriptor)
            fail("%s changed before it was read" % label)
    except OSError as error:
        os.close(descriptor)
        fail("%s could not be checked safely: %s" % (label, error))
    return descriptor, identity


def verify_pinned_identity(
    path: Path,
    descriptor: int,
    identity: Tuple[int, int, int, int, int, int, int],
    label: str,
    allow_ctime_change: bool = False,
) -> None:
    try:
        after_descriptor = os.fstat(descriptor)
        after_path = os.lstat(path)
    except OSError as error:
        fail("%s could not be checked after reading: %s" % (label, error))
    if not identity_matches(identity, after_descriptor, allow_ctime_change) or not identity_matches(identity, after_path, allow_ctime_change):
        fail("%s was replaced or rewritten while it was read" % label)


def sha256_file_pinned(path: Path) -> Tuple[Tuple[int, int, int, int, int, int, int], str]:
    descriptor, identity = open_pinned_regular(path, "file digest")
    digest = hashlib.sha256()
    try:
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
        verify_pinned_identity(path, descriptor, identity, "file digest")
        return identity, digest.hexdigest()
    except OSError as error:
        fail("file digest could not be read safely: %s" % error)
    finally:
        os.close(descriptor)


def read_bounded_bytes(path: Path, label: str, limit: int, private: bool = False) -> bytes:
    """Read one pinned regular file without following replacement symlinks."""
    descriptor, identity = open_pinned_regular(path, label, private=private)
    if identity[4] > limit:
        os.close(descriptor)
        fail("%s exceeds its %d-byte bound" % (label, limit))
    try:
        data = bytearray()
        while True:
            chunk = os.read(descriptor, min(1024 * 1024, limit + 1 - len(data)))
            if not chunk:
                break
            data.extend(chunk)
            if len(data) > limit:
                fail("%s exceeds its %d-byte bound" % (label, limit))
        verify_pinned_identity(path, descriptor, identity, label)
        return bytes(data)
    except OSError as error:
        fail("%s could not be read safely: %s" % (label, error))
    finally:
        os.close(descriptor)


def read_bounded_text(path: Path, label: str, limit: int, private: bool = False) -> str:
    try:
        return read_bounded_bytes(path, label, limit, private=private).decode("utf-8")
    except UnicodeDecodeError as error:
        fail("%s is not valid UTF-8: %s" % (label, error))


def write_atomic(path: Path, data: bytes, mode: int = 0o644) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(prefix=".release-", dir=str(path.parent), delete=False) as handle:
        temporary = Path(handle.name)
        handle.write(data)
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(temporary, mode)
    os.replace(temporary, path)


def decode_secret_file(value: str, destination: Path, label: str) -> Path:
    try:
        decoded = base64.b64decode(value, validate=True)
    except (ValueError, binascii.Error) as error:
        fail("%s is not valid base64: %s" % (label, error))
    if not decoded:
        fail("%s is empty" % label)
    write_atomic(destination, decoded, mode=0o600)
    return destination


def ensure_temp_path(path: Path, label: str, runner_temp: Path) -> Path:
    if not path.is_absolute():
        fail("%s must be an absolute protected temporary path" % label)
    path = path.absolute()
    runner_temp = runner_temp.absolute()
    runner_temp_real = runner_temp.resolve()
    path_real = path.resolve(strict=False)
    try:
        path_real.relative_to(runner_temp_real)
    except ValueError:
        fail("%s must be inside the protected runner temporary directory" % label)
    if path_real == runner_temp_real or not path.name or "/" in path.name:
        fail("%s is not a safe temporary path" % label)
    current = path
    while current != runner_temp:
        if current.is_symlink():
            fail("%s may not contain a symlink" % label)
        current = current.parent
        if not current.is_relative_to(runner_temp):
            fail("%s escapes the protected runner temporary directory" % label)
    path.parent.mkdir(parents=True, exist_ok=True)
    return path


def ensure_temp_leaf_path(path: Path, label: str, runner_temp: Path) -> Path:
    """Validate a temporary pathname without following a possibly replaced leaf."""

    if not path.is_absolute():
        fail("%s must be an absolute protected temporary path" % label)
    path = path.absolute()
    runner_temp = runner_temp.absolute()
    try:
        relative = path.relative_to(runner_temp)
    except ValueError:
        fail("%s must be inside the protected runner temporary directory" % label)
    if not relative.parts or not path.name:
        fail("%s is not a safe temporary path" % label)
    current = path.parent
    while current != runner_temp:
        if current.is_symlink():
            fail("%s may not contain a symlink in its parent" % label)
        current = current.parent
        try:
            current.relative_to(runner_temp)
        except ValueError:
            fail("%s escapes the protected runner temporary directory" % label)
    path.parent.mkdir(parents=True, exist_ok=True)
    return path


def write_github_env(values: Dict[str, str], github_env: Optional[Path]) -> None:
    if not github_env:
        return
    with github_env.open("a", encoding="utf-8") as handle:
        for key, value in values.items():
            if "\n" in value or "\r" in value:
                fail("GitHub environment value contains a newline")
            handle.write("%s=%s\n" % (key, value))


def read_signing_state(state_path: Path) -> Dict[str, Any]:
    try:
        state = json.loads(read_bounded_text(state_path, "signing state", MAX_SIGNING_STATE_BYTES, private=True))
    except (OSError, ValueError) as error:
        fail("signing state is not valid: %s" % error)
    if not isinstance(state, dict):
        fail("signing state is not an object")
    return state


def validate_private_temp_target(path: Path, label: str, allow_missing: bool = True) -> Path:
    if path.is_symlink():
        fail("%s may not be a symlink" % label)
    if not path.exists():
        if allow_missing:
            return path
        fail("%s does not exist" % label)
    file_stat = path.stat()
    if not stat.S_ISREG(file_stat.st_mode) or file_stat.st_nlink != 1:
        fail("%s must be a single-link regular file" % label)
    if stat.S_IMODE(file_stat.st_mode) & 0o077:
        fail("%s must not be group or world accessible" % label)
    return path


def validate_keychain_reference(value: str) -> str:
    if not isinstance(value, str) or not KEYCHAIN_PATH_RE.fullmatch(value):
        fail("signing state contains an invalid old keychain reference")
    return value


def validate_cleanup_state(
    state_path: Path,
    state: Dict[str, Any],
    runner_temp: Path,
    keychain_path: Optional[Path],
    expected_files: Sequence[Path],
    allowed_old_keychains: Optional[Sequence[str]],
) -> Tuple[Optional[Path], List[Path]]:
    if set(state) - STATE_KEYS or state.get("schemaVersion") != 1:
        fail("signing state schema or keys are invalid")
    if state_path.is_symlink() or not state_path.is_file():
        fail("signing state must be a regular file")
    state_stat = state_path.stat()
    if state_stat.st_nlink != 1 or stat.S_IMODE(state_stat.st_mode) & 0o077:
        fail("signing state must be private and single-link")
    if "temporaryFiles" not in state:
        fail("signing state temporary file allowlist is missing")
    values = state["temporaryFiles"]
    if not isinstance(values, list) or any(not isinstance(value, str) for value in values):
        fail("signing state temporary file allowlist is invalid")
    if len(values) != len(set(values)):
        fail("signing state temporary file allowlist contains duplicates")
    expected = {ensure_temp_path(path, "cleanup allowlist file", runner_temp) for path in expected_files}
    listed = set()
    for value in values:
        path = ensure_temp_path(Path(value), "signing state temporary file", runner_temp)
        if path not in expected:
            fail("signing state temporary file is outside the prepared allowlist")
        listed.add(path)
        validate_private_temp_target(path, "signing state temporary file")
    if listed != expected:
        fail("signing state temporary files do not match the prepared allowlist")
    old_keychains = state.get("oldKeychains", [])
    if old_keychains is not None:
        if not isinstance(old_keychains, list):
            fail("signing state old keychain list is invalid")
        if len(old_keychains) != len(set(old_keychains)):
            fail("signing state old keychain list contains duplicates")
        for value in old_keychains:
            validate_keychain_reference(value)
    if allowed_old_keychains is None:
        if old_keychains:
            fail("signing state old keychains have no prepared allowlist")
    elif list(old_keychains or []) != list(allowed_old_keychains):
        fail("signing state old keychains do not match the prepared allowlist")
    if "profile" in state:
        profile = state["profile"]
        if not isinstance(profile, str) or not re.fullmatch(r"[A-Za-z0-9._-]{1,128}", profile):
            fail("signing state notary profile is invalid")
    state_chain: Optional[Path] = None
    if "keychain" in state:
        if not isinstance(state["keychain"], str):
            fail("signing state keychain path is invalid")
        state_chain = ensure_temp_path(Path(state["keychain"]), "signing state keychain", runner_temp)
        if state_chain.exists() and (state_chain.is_symlink() or not state_chain.is_file() or state_chain.stat().st_nlink != 1):
            fail("signing state keychain must be a single-link regular file")
        if state_chain.exists() and stat.S_IMODE(state_chain.stat().st_mode) & 0o077:
            fail("signing state keychain must be private")
    if keychain_path is not None:
        keychain_path = ensure_temp_path(keychain_path, "cleanup keychain", runner_temp)
        if state_chain is not None and keychain_path != state_chain:
            fail("cleanup keychain does not match the prepared keychain")
    elif state_chain is not None:
        fail("signing state keychain has no prepared allowlist")
    chain = state_chain or keychain_path
    return chain, sorted(expected)


def parse_keychain_list(output: str) -> List[str]:
    values = []
    for line in output.splitlines():
        value = line.strip().strip('"')
        if value:
            values.append(value)
    return values


def cleanup_signing_state(
    state_path: Path,
    keychain_path: Optional[Path] = None,
    runner_temp: Optional[Path] = None,
    expected_files: Optional[Sequence[Path]] = None,
    allowed_old_keychains: Optional[Sequence[str]] = None,
    trusted_plan_path: Optional[Path] = None,
    trusted_profile: Optional[str] = None,
) -> None:
    runner_temp_path = Path(runner_temp or tempfile.gettempdir()).absolute()
    state_path = ensure_temp_leaf_path(state_path, "signing state", runner_temp_path)
    if trusted_plan_path is not None:
        trusted_plan_path = ensure_temp_leaf_path(trusted_plan_path, "cleanup plan", runner_temp_path)

    failures: List[str] = []

    def safe_leaf(value: Path, label: str) -> Optional[Path]:
        try:
            return ensure_temp_leaf_path(value, label, runner_temp_path)
        except ReleaseError as error:
            failures.append(label + ": " + str(error))
            return None

    trusted_chain = safe_leaf(Path(keychain_path), "trusted cleanup keychain") if keychain_path is not None else None
    trusted_files: List[Path] = []
    for value in expected_files or []:
        path = safe_leaf(Path(value), "trusted cleanup file")
        if path is not None:
            if path in trusted_files:
                failures.append("duplicate trusted cleanup file")
            else:
                trusted_files.append(path)
    if trusted_chain is not None:
        try:
            validate_private_temp_target(trusted_chain, "trusted cleanup keychain")
        except ReleaseError as error:
            failures.append("trusted cleanup keychain: " + str(error))
    if trusted_profile and not re.fullmatch(r"[A-Za-z0-9._-]{1,128}", trusted_profile):
        failures.append("trusted cleanup profile is invalid")

    trusted_old_keychains: Optional[List[str]] = None
    if allowed_old_keychains is not None:
        trusted_old_keychains = list(allowed_old_keychains)
        if len(trusted_old_keychains) != len(set(trusted_old_keychains)):
            failures.append("trusted old keychain allowlist contains duplicates")
        for value in trusted_old_keychains:
            try:
                validate_keychain_reference(value)
            except ReleaseError as error:
                failures.append("trusted old keychain allowlist: " + str(error))

    state: Optional[Dict[str, Any]] = None
    state_valid = False
    state_present = state_path.is_symlink() or state_path.exists()
    if state_present:
        try:
            state = read_signing_state(state_path)
            state_chain, state_files = validate_cleanup_state(
                state_path, state, runner_temp_path, trusted_chain,
                trusted_files, trusted_old_keychains,
            )
            if trusted_chain is not None and state_chain != trusted_chain:
                raise ReleaseError("signing state keychain does not match the trusted job keychain")
            state_valid = True
        except ReleaseError as error:
            failures.append("state-invalid: " + str(error))
    else:
        failures.append("state-missing")

    if trusted_plan_path is not None:
        if trusted_plan_path.is_symlink() or not trusted_plan_path.exists():
            failures.append("cleanup-plan-missing-or-unsafe")
        else:
            try:
                plan = read_signing_state(trusted_plan_path)
                plan_chain, _ = validate_cleanup_state(
                    trusted_plan_path, plan, runner_temp_path, trusted_chain,
                    trusted_files, trusted_old_keychains,
                )
                if trusted_chain is not None and plan_chain != trusted_chain:
                    raise ReleaseError("cleanup plan keychain does not match the trusted job keychain")
            except ReleaseError as error:
                failures.append("cleanup-plan-invalid: " + str(error))

    # The mutable state and plan never select resources. If a temporary keychain
    # was prepared, filter it from the current OS search list and preserve every
    # other entry, even when preparation was killed before state was written.
    if trusted_chain is not None and not any(item.startswith("trusted cleanup keychain:") for item in failures):
        try:
            _, current_output, current_errors = run_tool(["security", "list-keychains", "-d", "user"])
            current_keychains = parse_keychain_list(current_output + current_errors)
            filtered = [value for value in current_keychains if value != str(trusted_chain)]
            run_tool(["security", "list-keychains", "-d", "user", "-s"] + filtered)
            _, restored_output, restored_errors = run_tool(["security", "list-keychains", "-d", "user"])
            if parse_keychain_list(restored_output + restored_errors) != filtered:
                failures.append("verify-keychains")
        except ReleaseError:
            failures.append("restore-keychains")
    elif trusted_chain is None and state_valid and state is not None:
        old_keychains = state.get("oldKeychains", [])
        if isinstance(old_keychains, list) and all(isinstance(value, str) for value in old_keychains):
            try:
                run_tool(["security", "list-keychains", "-d", "user", "-s"] + old_keychains)
                _, restored_output, restored_errors = run_tool(["security", "list-keychains", "-d", "user"])
                if parse_keychain_list(restored_output + restored_errors) != old_keychains:
                    failures.append("verify-keychains")
            except ReleaseError:
                failures.append("restore-keychains")

    if trusted_chain is not None and not any(item.startswith("trusted cleanup keychain:") for item in failures):
        if trusted_profile and trusted_chain.exists():
            try:
                run_tool(["xcrun", "notarytool", "delete-credentials", trusted_profile, "--keychain", str(trusted_chain)])
            except ReleaseError:
                failures.append("delete-notary-credentials")
        try:
            if trusted_chain.exists():
                validate_private_temp_target(trusted_chain, "cleanup keychain", allow_missing=False)
                run_tool(["security", "delete-keychain", str(trusted_chain)])
                if trusted_chain.exists():
                    failures.append("delete-keychain")
        except (OSError, ReleaseError):
            failures.append("delete-keychain")

    for path in trusted_files:
        try:
            if path.exists():
                validate_private_temp_target(path, "cleanup temporary file", allow_missing=False)
                path.unlink()
        except (OSError, ReleaseError):
            failures.append("delete-temporary-file")

    if not failures and state_valid:
        for path in (state_path, trusted_plan_path):
            if path is None:
                continue
            try:
                validate_private_temp_target(path, "cleanup state", allow_missing=False)
                path.unlink()
            except (OSError, ReleaseError):
                failures.append("delete-state")
    if failures:
        fail("signing cleanup failed: " + ", ".join(sorted(set(failures))))


def prepare_signing(args: argparse.Namespace) -> None:
    required = [
        "signing_state", "signing_keychain", "application_certificate_base64", "installer_certificate_base64",
        "application_certificate_password", "installer_certificate_password", "notary_credentials_base64",
        "notary_profile", "team_id", "application_certificate_path", "installer_certificate_path",
        "signature_private_key_base64", "signature_public_key_base64", "signature_private_key_path", "signature_public_key_path",
        "cleanup_plan",
    ]
    missing = [name for name in required if not getattr(args, name, None)]
    if missing:
        fail("prepare-signing is missing: " + ", ".join(missing))
    runner_temp = Path(args.runner_temp or tempfile.gettempdir()).absolute()
    state_path = ensure_temp_path(Path(args.signing_state), "signing state", runner_temp)
    keychain_path = ensure_temp_path(Path(args.signing_keychain), "signing keychain", runner_temp)
    cleanup_plan_path = ensure_temp_path(Path(args.cleanup_plan), "trusted cleanup plan", runner_temp)
    certificate_paths = [
        ensure_temp_path(Path(args.application_certificate_path), "application certificate", runner_temp),
        ensure_temp_path(Path(args.installer_certificate_path), "installer certificate", runner_temp),
    ]
    signature_paths = [
        ensure_temp_path(Path(args.signature_private_key_path), "signature private key", runner_temp),
        ensure_temp_path(Path(args.signature_public_key_path), "signature public key", runner_temp),
    ]
    secrets = [
        args.application_certificate_base64,
        args.installer_certificate_base64,
        args.application_certificate_password,
        args.installer_certificate_password,
        args.notary_credentials_base64,
        args.signature_private_key_base64,
        args.signature_public_key_base64,
    ]
    SECRET_VALUES.update(value for value in secrets if value)
    old_keychains: List[str] = []
    try:
        if state_path.exists() or keychain_path.exists() or cleanup_plan_path.exists():
            fail("signing temporary paths already exist")
        _, old_keychain_output, _ = run_tool(["security", "list-keychains", "-d", "user"])
        old_keychains = [line.strip().strip('"') for line in old_keychain_output.splitlines() if line.strip()]
        for value in old_keychains:
            validate_keychain_reference(value)
        state = {
            "schemaVersion": 1,
            "keychain": str(keychain_path),
            "oldKeychains": old_keychains,
            "temporaryFiles": [str(path) for path in certificate_paths + signature_paths],
        }
        cleanup_plan = dict(state)
        cleanup_plan["profile"] = args.notary_profile
        write_atomic(cleanup_plan_path, json_bytes(cleanup_plan), mode=0o600)
        write_atomic(state_path, json_bytes(state), mode=0o600)
        for path, value, label in zip(
            certificate_paths,
            (args.application_certificate_base64, args.installer_certificate_base64),
            ("application certificate", "installer certificate"),
        ):
            decode_secret_file(value, path, label)
        for path, value, label in zip(
            signature_paths,
            (args.signature_private_key_base64, args.signature_public_key_base64),
            ("signature private key", "signature public key"),
        ):
            decode_secret_file(value, path, label)
        keychain_password = base64.urlsafe_b64encode(os.urandom(24)).decode("ascii")
        secrets.append(keychain_password)
        SECRET_VALUES.add(keychain_password)
        run_tool(["security", "create-keychain", "-p", keychain_password, str(keychain_path)])
        run_tool(["security", "unlock-keychain", "-p", keychain_password, str(keychain_path)])
        run_tool(["security", "set-keychain-settings", "-lut", "21600", str(keychain_path)])
        run_tool(["security", "list-keychains", "-d", "user", "-s"] + old_keychains + [str(keychain_path)])
        for path, password in zip(certificate_paths, (args.application_certificate_password, args.installer_certificate_password)):
            SECRET_VALUES.add(password)
            run_tool([
                "security", "import", str(path), "-k", str(keychain_path), "-P", password,
                "-T", "/usr/bin/codesign", "-T", "/usr/bin/productsign", "-T", "/usr/bin/security",
            ])
        run_tool(["security", "set-key-partition-list", "-S", "apple-tool:,apple:", "-s", "-k", keychain_password, str(keychain_path)])
        try:
            notary = json.loads(base64.b64decode(args.notary_credentials_base64, validate=True).decode("utf-8"))
        except (ValueError, UnicodeError, binascii.Error) as error:
            fail("notary credentials are not valid protected JSON: %s" % error)
        if not isinstance(notary, dict) or not all(isinstance(notary.get(key), str) and notary.get(key) for key in ("appleId", "teamId", "password")):
            fail("notary credentials must contain appleId, teamId, and password")
        if notary["teamId"] != args.team_id:
            fail("notary credentials Team ID does not match release Team ID")
        secrets.extend((notary["appleId"], notary["password"]))
        SECRET_VALUES.update((notary["appleId"], notary["password"]))
        run_tool([
            "xcrun", "notarytool", "store-credentials", args.notary_profile,
            "--keychain", str(keychain_path), "--apple-id", notary["appleId"],
            "--team-id", notary["teamId"], "--password", notary["password"],
        ])
        state["profile"] = args.notary_profile
        write_atomic(state_path, json_bytes(state), mode=0o600)
        write_github_env({
            "RELEASE_SIGNING_KEYCHAIN": str(keychain_path),
            "RELEASE_TRUSTED_SIGNING_KEYCHAIN": str(keychain_path),
            "RELEASE_SIGNING_CLEANUP_PLAN": str(cleanup_plan_path),
            "RELEASE_NOTARY_KEYCHAIN": str(keychain_path),
            "RELEASE_SIGNATURE_PRIVATE_KEY": str(signature_paths[0]),
            "RELEASE_SIGNATURE_PUBLIC_KEY": str(signature_paths[1]),
            "RELEASE_OLD_KEYCHAINS": json.dumps(old_keychains, separators=(",", ":")),
        }, Path(args.github_env) if args.github_env else None)
    except BaseException:
        try:
            cleanup_signing_state(
                state_path,
                keychain_path,
                runner_temp,
                certificate_paths + signature_paths,
                old_keychains,
                cleanup_plan_path,
                args.notary_profile,
            )
        finally:
            SECRET_VALUES.difference_update(secrets)
        raise


def prepare_verification(args: argparse.Namespace) -> None:
    required = ["signing_state", "signature_public_key_base64", "signature_public_key_path"]
    missing = [name for name in required if not getattr(args, name, None)]
    if missing:
        fail("prepare-verification is missing: " + ", ".join(missing))
    runner_temp = Path(args.runner_temp or tempfile.gettempdir()).absolute()
    state_path = ensure_temp_path(Path(args.signing_state), "verification state", runner_temp)
    public_key_path = ensure_temp_path(Path(args.signature_public_key_path), "signature public key", runner_temp)
    SECRET_VALUES.add(args.signature_public_key_base64)
    try:
        if state_path.exists() or public_key_path.exists():
            fail("verification temporary paths already exist")
        decode_secret_file(args.signature_public_key_base64, public_key_path, "signature public key")
        write_atomic(state_path, json_bytes({"schemaVersion": 1, "temporaryFiles": [str(public_key_path)]}), mode=0o600)
        write_github_env({"RELEASE_SIGNATURE_PUBLIC_KEY": str(public_key_path)}, Path(args.github_env) if args.github_env else None)
    except BaseException:
        cleanup_signing_state(state_path, runner_temp=runner_temp, expected_files=[public_key_path])
        raise


def cleanup_signing(args: argparse.Namespace) -> None:
    if not args.signing_state:
        fail("cleanup-signing requires a signing state path")
    runner_temp = Path(args.runner_temp or tempfile.gettempdir()).absolute()
    keychain_value = getattr(args, "trusted_keychain", None)
    if getattr(args, "cleanup_plan", None) and not keychain_value:
        fail("cleanup-signing requires a separately trusted keychain path")
    keychain = Path(keychain_value) if keychain_value else None
    expected_files = [
        Path(value)
        for value in (
            getattr(args, "application_certificate_path", None),
            getattr(args, "installer_certificate_path", None),
            getattr(args, "signature_private_key_path", None),
            getattr(args, "signature_public_key_path", None),
        )
        if value
    ]
    allowed_old_keychains = None
    if getattr(args, "old_keychains", None) is not None:
        try:
            allowed_old_keychains = json.loads(args.old_keychains)
        except (TypeError, ValueError) as error:
            fail("prepared old keychain allowlist is not valid JSON: %s" % error)
        if not isinstance(allowed_old_keychains, list) or any(not isinstance(value, str) for value in allowed_old_keychains):
            fail("prepared old keychain allowlist is invalid")
        if len(allowed_old_keychains) != len(set(allowed_old_keychains)):
            fail("prepared old keychain allowlist contains duplicates")
        for value in allowed_old_keychains:
            validate_keychain_reference(value)
    cleanup_signing_state(
        Path(args.signing_state),
        keychain,
        runner_temp,
        expected_files,
        allowed_old_keychains,
        Path(args.cleanup_plan) if getattr(args, "cleanup_plan", None) else None,
        getattr(args, "trusted_profile", None),
    )


def copy_regular(source: Path, destination: Path, mode: int = 0o644) -> None:
    if source.is_symlink() or not source.is_file():
        fail("required release input is not a regular file: %s" % source)
    write_atomic(destination, source.read_bytes(), mode=mode)


def require_regular(path: Path, label: str) -> Path:
    if path.is_symlink() or not path.is_file():
        fail("%s must be a regular file: %s" % (label, path))
    return path


def require_directory(path: Path, label: str) -> Path:
    if path.is_symlink() or not path.is_dir():
        fail("%s must be a directory: %s" % (label, path))
    return path


def reject_placeholder(value: str, label: str) -> None:
    if not value or PLACEHOLDER_RE.search(value):
        fail("%s is missing or contains a placeholder" % label)


def validate_identity_args(args: argparse.Namespace, require_notary_profile: bool = True) -> None:
    fields = {
        "product identity": args.product_identity,
        "executable": args.executable,
        "package identifier": args.package_id,
        "service label": args.service_label,
        "version": args.version,
        "tag": args.tag,
        "source commit": args.source_commit,
        "application identity": args.application_identity,
        "installer identity": args.installer_identity,
        "team ID": args.team_id,
        "owner": args.owner,
        "security contact": args.security_contact,
        "repository URL": args.repository_url,
    }
    if require_notary_profile:
        fields["notary keychain profile"] = args.notary_profile
    for label, value in fields.items():
        reject_placeholder(value or "", label)
    if not IDENTITY_RE.fullmatch(args.product_identity):
        fail("product identity must be a final path-safe identifier")
    if not EXECUTABLE_RE.fullmatch(args.executable):
        fail("executable name must be a path-safe filename")
    if not PACKAGE_ID_RE.fullmatch(args.package_id):
        fail("package identifier must be reverse-DNS style")
    if not SERVICE_LABEL_RE.fullmatch(args.service_label):
        fail("service label must be reverse-DNS style")
    if not VERSION_RE.fullmatch(args.version):
        fail("version must be semantic version text without a leading v")
    if not TAG_RE.fullmatch(args.tag) or args.tag != "v" + args.version:
        fail("tag must be the annotated v-prefixed form of version")
    if not COMMIT_RE.fullmatch(args.source_commit):
        fail("source commit must be a lowercase 40-character commit ID")
    if not TEAM_ID_RE.fullmatch(args.team_id):
        fail("Team ID must be ten uppercase alphanumeric characters")
    for label, value, kind in (
        ("application identity", args.application_identity, "Application"),
        ("installer identity", args.installer_identity, "Installer"),
    ):
        match = CERTIFICATE_IDENTITY_RE.fullmatch(value)
        if not match or match.group(1) != kind or match.group(2) != args.team_id:
            fail("%s must be an exact Developer ID %s identity for the declared Team ID" % (label, kind))
    if require_notary_profile and (any(char.isspace() for char in args.notary_profile) or "/" in args.notary_profile):
        fail("notary keychain profile must be a single non-secret name")
    if not re.fullmatch(r"https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", args.repository_url):
        fail("repository URL must be a stable GitHub HTTPS repository URL")
    if MUTABLE_URL_RE.search(args.repository_url):
        fail("repository URL contains a mutable ref")
    if args.formula_class and not FORMULA_CLASS_RE.fullmatch(args.formula_class):
        fail("formula class is not a valid Ruby constant")


def repo_path(repo_root: Path, supplied: str) -> Path:
    path = Path(supplied)
    return path if path.is_absolute() else repo_root / path


def relative_source_path(repo_root: Path, supplied: str, label: str) -> Tuple[Path, PurePosixPath]:
    raw = Path(supplied)
    if raw.is_absolute() or not supplied or any(part in ("", ".", "..") for part in raw.parts):
        fail("%s must be a relative path inside the tagged checkout" % label)
    relative = PurePosixPath(*raw.parts)
    candidate = repo_root.joinpath(*relative.parts)
    current = repo_root
    for part in relative.parts:
        current = current / part
        if current.is_symlink():
            fail("%s may not contain a symlink: %s" % (label, supplied))
    try:
        resolved = candidate.resolve(strict=False)
        resolved.relative_to(repo_root)
    except ValueError:
        fail("%s escapes the tagged checkout: %s" % (label, supplied))
    return candidate, relative


def tracked_source_file(repo_root: Path, supplied: str, label: str) -> Path:
    candidate, relative = relative_source_path(repo_root, supplied, label)
    try:
        file_stat = candidate.stat()
    except OSError as error:
        fail("%s is not available: %s" % (label, error))
    if candidate.is_symlink() or not stat.S_ISREG(file_stat.st_mode):
        fail("%s must be a regular file: %s" % (label, supplied))
    if file_stat.st_nlink != 1:
        fail("%s must not be a hard link: %s" % (label, supplied))
    try:
        _, listing, _ = run_tool(
            ["git", "--literal-pathspecs", "ls-files", "--stage", "--error-unmatch", "--full-name", "--", relative.as_posix()],
            cwd=repo_root,
        )
    except ReleaseError:
        fail("%s must be Git-tracked in the tagged checkout: %s" % (label, supplied))
    lines = [line for line in listing.splitlines() if line.strip()]
    if len(lines) != 1:
        fail("%s must resolve to one Git-tracked file: %s" % (label, supplied))
    mode = lines[0].split(None, 1)[0]
    if mode not in ("100644", "100755"):
        fail("%s has an unsafe Git file mode: %s" % (label, supplied))
    return candidate


def tracked_source_tree(repo_root: Path, supplied: str, label: str) -> Tuple[Path, List[Path]]:
    directory, relative = relative_source_path(repo_root, supplied, label)
    if directory.is_symlink() or not directory.is_dir():
        fail("%s must be a regular directory: %s" % (label, supplied))
    files: List[Path] = []
    for path in sorted(directory.rglob("*"), key=lambda item: item.as_posix()):
        relative_file = PurePosixPath(*path.relative_to(repo_root).parts).as_posix()
        if path.is_symlink():
            fail("%s may not contain a symlink: %s" % (label, relative_file))
        if path.is_dir():
            continue
        files.append(tracked_source_file(repo_root, relative_file, label))
    if not files:
        fail("%s has no tracked regular files: %s" % (label, supplied))
    return directory, files


def validate_git_source(args: argparse.Namespace) -> int:
    repo_root = args.repo_root.resolve()
    require_directory(repo_root, "repository root")
    _, inside, _ = run_tool(["git", "rev-parse", "--is-inside-work-tree"], cwd=repo_root)
    if inside.strip() != "true":
        fail("repository root is not a Git worktree")
    _, head, _ = run_tool(["git", "rev-parse", "HEAD"], cwd=repo_root)
    if head.strip() != args.source_commit:
        fail("HEAD does not equal the declared source commit")
    _, status, _ = run_tool(["git", "status", "--porcelain=v1", "--untracked-files=all"], cwd=repo_root)
    if status.strip():
        fail("source checkout is not clean")
    _, tag_type, _ = run_tool(["git", "cat-file", "-t", "refs/tags/" + args.tag], cwd=repo_root)
    if tag_type.strip() != "tag":
        fail("release tag must be an annotated tag")
    _, tag_target, _ = run_tool(["git", "rev-parse", "refs/tags/" + args.tag + "^{}"], cwd=repo_root)
    if tag_target.strip() != args.source_commit:
        fail("annotated tag does not target the declared source commit")
    package_resolved = tracked_source_file(repo_root, "Package.resolved", "Package.resolved")
    try:
        resolved = json.loads(read_bounded_text(package_resolved, "Package.resolved", 4 * 1024 * 1024))
    except (OSError, ValueError) as error:
        fail("Package.resolved is not valid JSON: %s" % error)
    pins = resolved.get("pins")
    if not isinstance(pins, list) or not pins:
        fail("Package.resolved must contain locked pins")
    for pin in pins:
        revision = pin.get("state", {}).get("revision") if isinstance(pin, dict) else None
        if not isinstance(revision, str) or not COMMIT_RE.fullmatch(revision):
            fail("Package.resolved contains an unpinned dependency")
    tracked_source_file(repo_root, "Package.swift", "Package.swift")
    return int(run_tool(["git", "show", "-s", "--format=%ct", "HEAD"], cwd=repo_root)[1].strip())


def resolve_checked_out_source(repo_root: Path, tag: str, github_env: Optional[Path]) -> str:
    if not TAG_RE.fullmatch(tag):
        fail("source tag must be an exact semantic version tag")
    repo_root = repo_root.resolve()
    require_directory(repo_root, "repository root")
    _, head, _ = run_tool(["git", "rev-parse", "HEAD"], cwd=repo_root)
    source_commit = head.strip()
    if not COMMIT_RE.fullmatch(source_commit):
        fail("checked-out HEAD is not a full commit ID")
    _, status, _ = run_tool(["git", "status", "--porcelain=v1", "--untracked-files=all"], cwd=repo_root)
    if status.strip():
        fail("source checkout is not clean after tag checkout")
    _, tag_type, _ = run_tool(["git", "cat-file", "-t", "refs/tags/" + tag], cwd=repo_root)
    if tag_type.strip() != "tag":
        fail("release tag must be an annotated tag")
    _, tag_target, _ = run_tool(["git", "rev-parse", "refs/tags/" + tag + "^{}"], cwd=repo_root)
    if tag_target.strip() != source_commit:
        fail("checked-out HEAD does not equal the annotated tag target")
    if github_env:
        with github_env.open("a", encoding="utf-8") as handle:
            handle.write("RELEASE_SOURCE_COMMIT=%s\n" % source_commit)
    return source_commit


def validate_text_input(path: Path, label: str) -> Path:
    path = require_regular(path, label)
    data = read_bounded_bytes(path, label, 16 * 1024 * 1024)
    if not data.strip():
        fail("%s is empty" % label)
    if b"/Users/" in data or b"/home/" in data:
        fail("%s contains an absolute build-machine path" % label)
    return path


def validate_release_inputs(args: argparse.Namespace, require_notary_profile: bool = True) -> Dict[str, Any]:
    validate_identity_args(args, require_notary_profile=require_notary_profile)
    repo_root = args.repo_root.resolve()
    commit_time = validate_git_source(args)
    source_license = tracked_source_file(repo_root, args.source_license, "source LICENSE")
    source_license = validate_text_input(source_license, "source LICENSE")
    license_text = read_bounded_text(source_license, "source LICENSE", 16 * 1024 * 1024)
    if re.search(r"(?i)(not selected|recommendation only|must not be created until|placeholder)", license_text):
        fail("source LICENSE is not an approved license text")
    notices = validate_text_input(tracked_source_file(repo_root, args.notices, "third-party notice file"), "third-party notice file")
    compatibility = validate_text_input(tracked_source_file(repo_root, args.compatibility, "compatibility metadata"), "compatibility metadata")
    support = validate_text_input(tracked_source_file(repo_root, args.support, "support metadata"), "support metadata")
    changelog = validate_text_input(tracked_source_file(repo_root, args.changelog, "changelog"), "changelog")
    licenses_dir, license_files = tracked_source_tree(repo_root, args.licenses_dir, "license directory")
    manifest_path = validate_text_input(tracked_source_file(repo_root, args.model_manifest, "model manifest"), "model manifest")
    embedded_manifest_path = validate_text_input(
        tracked_source_file(repo_root, args.embedded_model_manifest, "embedded model manifest"),
        "embedded model manifest",
    )
    manifest_bytes = read_bounded_bytes(manifest_path, "model manifest", 2 * 1024 * 1024)
    embedded_manifest_bytes = read_bounded_bytes(embedded_manifest_path, "embedded model manifest", 2 * 1024 * 1024)
    validate_manifest_pair(manifest_bytes, embedded_manifest_bytes)
    try:
        manifest = json.loads(manifest_bytes)
    except (OSError, ValueError) as error:
        fail("model manifest is not valid JSON: %s" % error)
    validate_manifest(manifest)
    return {
        "repo_root": repo_root,
        "commit_time": commit_time,
        "source_license": source_license,
        "notices": notices,
        "compatibility": compatibility,
        "support": support,
        "changelog": changelog,
        "licenses_dir": licenses_dir,
        "license_files": license_files,
        "manifest_path": manifest_path,
        "embedded_manifest_path": embedded_manifest_path,
        "manifest": manifest,
        "manifest_bytes": manifest_bytes,
    }


def validate_manifest_pair(public_bytes: bytes, embedded_bytes: bytes) -> None:
    """Require the release manifest and the embedded runtime manifest to be identical."""

    if public_bytes != embedded_bytes:
        fail("public and embedded model manifests are not byte-identical")
    try:
        public = json.loads(public_bytes)
        embedded = json.loads(embedded_bytes)
    except (TypeError, ValueError) as error:
        fail("public and embedded model manifests are not valid JSON: %s" % error)
    if canonical_json(public) != canonical_json(embedded):
        fail("public and embedded model manifests are not semantically identical")
    validate_manifest(public)


def validate_manifest(manifest: Dict[str, Any]) -> None:
    if not isinstance(manifest, dict):
        fail("model manifest must be an object")
    def exact_keys(value: Any, expected: Set[str], label: str) -> Dict[str, Any]:
        if not isinstance(value, dict) or set(value) != expected:
            fail("model manifest %s fields are not exact" % label)
        return value

    top = {"schemaVersion", "status", "modelId", "variantId", "repository", "immutableCommit", "repositoryCommitUrl", "fluidAudioCompatibility", "license", "attribution", "staging", "files", "totalSize", "hashVerificationSummary", "manifestContentDigest", "releaseGate"}
    exact_keys(manifest, top, "top-level")
    if manifest["schemaVersion"] != 1 or manifest["status"] != "proposed-v0.1-baseline":
        fail("model manifest schema or status is not supported")
    if manifest["modelId"] != "parakeet-tdt-0.6b-v3" or manifest["variantId"] != "int8" or manifest["repository"] != MODEL_REPOSITORY:
        fail("model manifest is not the supported Parakeet v3 int8 model")
    immutable_commit = manifest["immutableCommit"]
    if immutable_commit != SUPPORTED_MODEL_COMMIT:
        fail("model manifest immutable commit is not the reviewed commit")
    expected_tree_url = "https://%s/%s/tree/%s" % (MODEL_HOST, MODEL_REPOSITORY, SUPPORTED_MODEL_COMMIT)
    if manifest["repositoryCommitUrl"] != expected_tree_url:
        fail("model manifest repository commit URL is not immutable")

    compatibility = exact_keys(manifest["fluidAudioCompatibility"], {"version", "commit", "commitUrl", "swiftToolsVersion", "platform", "architecture", "asrVersion", "encoderPrecision", "requiredArtifacts", "sourceAuthority"}, "FluidAudio compatibility")
    expected_compatibility = {
        "version": "0.15.5", "commit": SUPPORTED_FLUIDAUDIO_COMMIT,
        "commitUrl": "https://github.com/FluidInference/FluidAudio/commit/" + SUPPORTED_FLUIDAUDIO_COMMIT,
        "swiftToolsVersion": "6.0", "platform": "macOS 14+", "architecture": "Apple Silicon arm64",
        "asrVersion": "v3", "encoderPrecision": "int8", "requiredArtifacts": SUPPORTED_MODEL_ROOTS,
        "sourceAuthority": "AsrModels and ModelNames source at the pinned FluidAudio commit",
    }
    if compatibility != expected_compatibility:
        fail("model manifest FluidAudio compatibility is not exact")

    license_info = exact_keys(manifest["license"], {"spdx", "declaredBy", "modelCardUrl", "modelCardTextLicense", "apiLicenseField", "reviewStatus"}, "license")
    expected_license = {
        "spdx": "CC-BY-4.0", "declaredBy": "Hugging Face model-card front matter at the immutable model commit",
        "modelCardUrl": "https://%s/%s/blob/%s/README.md" % (MODEL_HOST, MODEL_REPOSITORY, SUPPORTED_MODEL_COMMIT),
        "modelCardTextLicense": "Apache-2.0", "apiLicenseField": None,
    }
    if any(license_info[key] != value for key, value in expected_license.items()) or not isinstance(license_info["reviewStatus"], str) or not license_info["reviewStatus"].lower().startswith("approved"):
        fail("model license fields are not reviewed and approved")

    attribution = exact_keys(manifest["attribution"], {"publisher", "model", "baseModel", "datasets", "notice", "sourceUrl"}, "attribution")
    if attribution != {
        "publisher": "FluidInference", "model": "parakeet-tdt-0.6b-v3 Core ML", "baseModel": "nvidia/parakeet-tdt-0.6b-v3",
        "datasets": ["nvidia/Granary", "nemo/asr-set-3.0"],
        "notice": "Parakeet TDT v3, 0.6B multilingual speech-to-text Core ML model, published by FluidInference. Apply CC BY 4.0 attribution and license terms before redistribution.",
        "sourceUrl": expected_tree_url,
    }:
        fail("model attribution fields are not exact")

    staging = exact_keys(manifest["staging"], {"modelsRoot", "repositoryFolder", "loadArgument", "layout", "callerMustPassRepositoryFolder", "symlinksAllowed", "extraFilesAllowed", "pathRule", "sourceEvidence"}, "staging")
    expected_staging = {
        "modelsRoot": "<models-root>", "repositoryFolder": "parakeet-tdt-0.6b-v3", "loadArgument": "<models-root>/parakeet-tdt-0.6b-v3",
        "layout": "<models-root>/parakeet-tdt-0.6b-v3/{Preprocessor.mlmodelc,Encoder.mlmodelc,Decoder.mlmodelc,JointDecisionv3.mlmodelc,parakeet_vocab.json}",
        "callerMustPassRepositoryFolder": True, "symlinksAllowed": False, "extraFilesAllowed": False,
        "pathRule": "All manifest paths are relative to the repository folder, use forward slashes, contain no dot segments, and must match one of the five required artifact prefixes or the vocabulary file.",
        "sourceEvidence": {
            "asrModelsLoad": "https://github.com/FluidInference/FluidAudio/blob/19600a485baa4998812e4654b70d2bab8f2c9949/Sources/FluidAudio/ASR/Parakeet/SlidingWindow/TDT/AsrModels.swift#L241-L255",
            "repoFolder": "https://github.com/FluidInference/FluidAudio/blob/19600a485baa4998812e4654b70d2bab8f2c9949/Sources/FluidAudio/ModelNames.swift#L207-L258",
            "v3Int8RequiredModels": "https://github.com/FluidInference/FluidAudio/blob/19600a485baa4998812e4654b70d2bab8f2c9949/Sources/FluidAudio/ModelNames.swift#L328-L359",
        },
    }
    if staging != expected_staging:
        fail("model staging rules are not exact")

    files = manifest["files"]
    if not isinstance(files, list) or len(files) != len(SUPPORTED_MODEL_FILES):
        fail("model manifest must contain exactly 21 file records")
    paths: Set[str] = set()
    urls: Set[str] = set()
    total = 0
    lfs_matches = 0
    expected_file_keys = {"relativePath", "size", "sha256", "url", "hashVerification"}
    expected_hash_keys = {"status", "method", "repositoryOid", "repositoryOidAlgorithm", "lfsObjectSha256", "lfsObjectMatchesLocalSha256"}
    for entry in files:
        exact_keys(entry, expected_file_keys, "file")
        relative = entry["relativePath"]
        if not isinstance(relative, str) or not relative or PurePosixPath(relative).is_absolute() or any(part in ("", ".", "..") for part in PurePosixPath(relative).parts) or "\\" in relative:
            fail("model manifest contains an unsafe relative path")
        if relative in paths or relative not in SUPPORTED_MODEL_FILES:
            fail("model manifest file set contains a duplicate or unsupported path")
        paths.add(relative)
        expected_size, expected_sha = SUPPORTED_MODEL_FILES[relative]
        if not isinstance(entry["size"], int) or entry["size"] != expected_size or not isinstance(entry["sha256"], str) or not SHA256_RE.fullmatch(entry["sha256"]) or entry["sha256"] != expected_sha:
            fail("model manifest size or SHA-256 is not the reviewed value: %s" % relative)
        url = entry["url"]
        try:
            parsed = urlsplit(url)
            parsed_port = parsed.port
        except (TypeError, ValueError):
            fail("model manifest contains an invalid download URL")
        expected_path = "/%s/resolve/%s/%s" % (MODEL_REPOSITORY, SUPPORTED_MODEL_COMMIT, relative)
        if not isinstance(url, str) or url in urls or parsed.scheme != "https" or parsed.netloc != MODEL_HOST or parsed.path != expected_path or parsed.query or parsed.fragment or parsed.username or parsed.password or parsed_port is not None:
            fail("model manifest contains a mutable, duplicate, or non-immutable download URL")
        urls.add(url)
        hash_info = exact_keys(entry["hashVerification"], expected_hash_keys, "hash verification")
        if hash_info["status"] != "locallyVerified" or not isinstance(hash_info["method"], str) or not hash_info["method"].startswith("Downloaded once and hashed locally with SHA-256") or not isinstance(hash_info["repositoryOid"], str) or not re.fullmatch(r"[0-9a-f]{40}", hash_info["repositoryOid"]) or hash_info["repositoryOidAlgorithm"] != "git-sha1":
            fail("model manifest hash verification is incomplete")
        if hash_info["lfsObjectSha256"] is not None and (hash_info["lfsObjectSha256"] != expected_sha or hash_info["lfsObjectMatchesLocalSha256"] is not True):
            fail("model manifest LFS verification does not match the file digest")
        if hash_info["lfsObjectSha256"] is not None:
            lfs_matches += 1
        if hash_info["lfsObjectSha256"] is None and hash_info["lfsObjectMatchesLocalSha256"] is not None:
            fail("model manifest has an LFS match without an LFS object")
        total += entry["size"]
    if paths != set(SUPPORTED_MODEL_FILES) or total != 483105645:
        fail("model manifest file set or total size is not exact")

    summary = exact_keys(manifest["hashVerificationSummary"], {"fileCount", "locallyVerifiedCount", "metadataOnlyCount", "lfsObjectMatchCount", "downloadedOnce", "sizeMatchesForAllFiles", "releaseGate"}, "hash verification summary")
    if summary != {"fileCount": 21, "locallyVerifiedCount": 21, "metadataOnlyCount": 0, "lfsObjectMatchCount": lfs_matches, "downloadedOnce": True, "sizeMatchesForAllFiles": True, "releaseGate": "open"}:
        fail("model manifest hash verification summary is not exact")
    digest_info = exact_keys(manifest["manifestContentDigest"], {"algorithm", "hex", "procedure", "selfExclusion"}, "content digest")
    if digest_info["algorithm"] != "SHA-256" or not SHA256_RE.fullmatch(str(digest_info["hex"])) or digest_info["procedure"] != MANIFEST_DIGEST_PROCEDURE or digest_info["selfExclusion"] != MANIFEST_DIGEST_SELF_EXCLUSION:
        fail("model manifest content digest contract is invalid")
    digest_object = dict(manifest)
    digest_object.pop("manifestContentDigest")
    if sha256_bytes(canonical_json(digest_object)) != digest_info["hex"]:
        fail("model manifest content digest does not match the canonical self-excluded content")
    gate = exact_keys(manifest["releaseGate"], {"status", "reasons"}, "release gate")
    if gate["status"] != "open" or not isinstance(gate["reasons"], list) or len(gate["reasons"]) < 3 or any(not isinstance(reason, str) or not reason for reason in gate["reasons"]):
        fail("model manifest release gate is incomplete")


def scan_stream(reader: Any, label: str, budget: Dict[str, int], extra_markers: Sequence[bytes] = (), writer: Optional[Any] = None) -> None:
    markers = tuple(SCAN_MARKERS) + tuple(extra_markers)
    overlap = max(len(marker) for marker in markers) - 1
    carry = b""
    file_bytes = 0
    while True:
        chunk = reader.read(1024 * 1024)
        if not chunk:
            break
        file_bytes += len(chunk)
        budget["used"] += len(chunk)
        if file_bytes > MAX_SCAN_BYTES_PER_FILE or budget["used"] > MAX_SCAN_BYTES_TOTAL:
            fail("bounded content scan exceeded its work limit: %s" % label)
        window = carry + chunk
        if any(marker in window for marker in markers):
            fail("placeholder or absolute build-machine path in %s" % label)
        if writer is not None:
            writer.write(chunk)
        carry = window[-overlap:]


def scan_file_stream(path: Path, label: str, budget: Optional[Dict[str, int]] = None, extra_markers: Sequence[bytes] = ()) -> None:
    with path.open("rb") as handle:
        scan_stream(handle, label, budget or {"used": 0}, extra_markers)


def safe_relative(path: Path) -> str:
    return path.as_posix().lstrip("./")


def ensure_safe_tree(root: Path) -> List[Path]:
    entries: List[Path] = []
    for path in root.rglob("*"):
        relative = path.relative_to(root)
        if any(part in ("", ".", "..") for part in relative.parts):
            fail("payload contains path traversal")
        if path.is_symlink():
            fail("payload contains a symlink: %s" % relative)
        if path.is_file():
            entries.append(path)
        elif not path.is_dir():
            fail("payload contains a special file: %s" % relative)
    names = [safe_relative(path.relative_to(root)) for path in entries]
    if len(names) != len(set(names)):
        fail("payload contains duplicate paths")
    for name in names:
        if MODEL_BYTE_RE.search(name):
            fail("payload includes model bytes: %s" % name)
    return sorted(entries, key=lambda path: safe_relative(path.relative_to(root)))


def validate_resource_bundle(bundle: Path, approved_manifest: bytes) -> List[Path]:
    """Validate the one SwiftPM resource bundle used by the native target."""

    if bundle.name != SWIFT_RESOURCE_BUNDLE_NAME or bundle.is_symlink() or not bundle.is_dir():
        fail("SwiftPM resource bundle has the wrong name or type")
    validate_clean_filesystem_metadata(bundle, "SwiftPM resource bundle")
    files = ensure_safe_tree(bundle)
    expected = bundle / SWIFT_RESOURCE_MANIFEST_NAME
    if files != [expected]:
        fail("SwiftPM resource bundle contains an unexpected file set")
    if read_bounded_bytes(expected, "SwiftPM resource manifest", 2 * 1024 * 1024) != approved_manifest:
        fail("SwiftPM resource manifest differs from the approved release manifest")
    return files


def copy_resource_bundle(source: Path, destination: Path, approved_manifest: bytes) -> Path:
    validate_resource_bundle(source, approved_manifest)
    if destination.exists() or destination.is_symlink():
        fail("SwiftPM resource bundle destination already exists")
    destination.mkdir(mode=0o755, parents=True, exist_ok=False)
    target = destination / SWIFT_RESOURCE_MANIFEST_NAME
    write_atomic(target, read_bounded_bytes(source / SWIFT_RESOURCE_MANIFEST_NAME, "SwiftPM resource manifest", 2 * 1024 * 1024), mode=0o644)
    validate_resource_bundle(destination, approved_manifest)
    return destination


def neutralize_swift_resource_fallback(executable: Path, source_bundle: Path) -> None:
    """Disable SwiftPM's absolute build-tree fallback after the preferred bundle is present."""

    require_regular(executable, "Swift executable")
    data = read_bounded_bytes(executable, "Swift executable", MAX_SCAN_BYTES_PER_FILE)
    candidates = [str(source_bundle), str(source_bundle.resolve())]
    matches = [candidate.encode("utf-8") for candidate in candidates if candidate.encode("utf-8") in data]
    if len(set(matches)) != 1:
        fail("Swift executable does not contain exactly one known resource build fallback")
    old = matches[0]
    if len(DISABLED_SWIFTPM_FALLBACK) > len(old):
        fail("Swift resource fallback replacement is longer than the generated path")
    replacement = DISABLED_SWIFTPM_FALLBACK + b"\0" * (len(old) - len(DISABLED_SWIFTPM_FALLBACK))
    if data.count(old) != 1:
        fail("Swift executable contains an ambiguous resource build fallback")
    patched = data.replace(old, replacement)
    write_atomic(executable, patched, mode=stat.S_IMODE(executable.stat().st_mode))
    if old in read_bounded_bytes(executable, "sanitized Swift executable", MAX_SCAN_BYTES_PER_FILE):
        fail("absolute Swift resource build fallback remains")
    if any(marker in patched for marker in (b"/Users/", b"/home/", b"/private/tmp/", b"/tmp/")):
        fail("sanitized Swift executable contains an absolute build path")


def payload_contract(root: Path) -> Dict[str, str]:
    contract: Dict[str, str] = {}
    for path in sorted(root.rglob("*"), key=lambda item: item.as_posix()):
        relative = PurePosixPath(path.relative_to(root).as_posix())
        if relative.is_absolute() or ".." in relative.parts or "" in relative.parts:
            fail("payload contract contains an unsafe path")
        name = "./" + relative.as_posix()
        if path.is_symlink():
            fail("payload contract contains a symlink: %s" % relative)
        if MODEL_BYTE_RE.search(relative.as_posix()):
            fail("payload contract includes model bytes: %s" % relative)
        if path.is_dir():
            contract[name] = "directory"
        elif path.is_file():
            contract[name] = "file"
        else:
            fail("payload contract contains a special file: %s" % relative)
    if not contract:
        fail("payload contract is empty")
    return contract


def descriptor_xattr_names(path: Path, label: str) -> Set[str]:
    """Enumerate xattrs through a pinned descriptor, without following a replacement path."""

    try:
        value = os.lstat(path)
    except OSError as error:
        fail("%s could not be inspected: %s" % (label, error))
    if stat.S_ISLNK(value.st_mode) or not (stat.S_ISREG(value.st_mode) or stat.S_ISDIR(value.st_mode)):
        fail("%s has an unsafe type" % label)
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)
    if stat.S_ISDIR(value.st_mode):
        flags |= getattr(os, "O_DIRECTORY", 0)
    try:
        descriptor = os.open(str(path), flags)
    except OSError as error:
        fail("%s could not be opened for metadata inspection: %s" % (label, error))
    libc = ctypes.CDLL(None, use_errno=True)
    libc.flistxattr.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int]
    libc.flistxattr.restype = ctypes.c_ssize_t
    try:
        before = stat_identity(os.fstat(descriptor))
        size = libc.flistxattr(descriptor, None, 0, 0)
        if size < 0:
            fail("%s metadata could not be enumerated" % label)
        buffer = ctypes.create_string_buffer(size) if size else None
        if size:
            result = libc.flistxattr(descriptor, buffer, size, 0)
            if result < 0 or result > size:
                fail("%s metadata could not be enumerated" % label)
            raw = buffer.raw[:result]
        else:
            raw = b""
        after = stat_identity(os.fstat(descriptor))
        after_path = os.lstat(path)
        if after != before or stat_identity(after_path) != before:
            fail("%s changed during metadata inspection" % label)
        try:
            return {item.decode("utf-8") for item in raw.split(b"\0") if item}
        except UnicodeDecodeError as error:
            fail("%s has a non-UTF-8 xattr name: %s" % (label, error))
    except OSError as error:
        fail("%s metadata could not be enumerated: %s" % (label, error))
    finally:
        os.close(descriptor)


def flistxattr_descriptor_names(descriptor: int, label: str) -> Set[str]:
    """Enumerate xattrs on an already pinned descriptor."""

    libc = ctypes.CDLL(None, use_errno=True)
    libc.flistxattr.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int]
    libc.flistxattr.restype = ctypes.c_ssize_t
    size = libc.flistxattr(descriptor, None, 0, 0)
    if size < 0:
        fail("%s metadata could not be enumerated" % label)
    buffer = ctypes.create_string_buffer(size) if size else None
    if not size:
        return set()
    result = libc.flistxattr(descriptor, buffer, size, 0)
    if result < 0 or result > size:
        fail("%s metadata could not be enumerated" % label)
    try:
        return {item.decode("utf-8") for item in buffer.raw[:result].split(b"\0") if item}
    except UnicodeDecodeError as error:
        fail("%s has a non-UTF-8 xattr name: %s" % (label, error))


def remove_descriptor_xattr(descriptor: int, name: str, label: str) -> None:
    libc = ctypes.CDLL(None, use_errno=True)
    libc.fremovexattr.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int]
    libc.fremovexattr.restype = ctypes.c_int
    if libc.fremovexattr(descriptor, name.encode("utf-8"), 0) != 0:
        fail("%s %s metadata could not be removed" % (label, name))


def remove_exact_host_provenance(root: Path, label: str) -> None:
    """Remove only host-added provenance from newly created staging nodes."""

    for path in [root] + sorted(root.rglob("*"), key=lambda item: item.as_posix()):
        names = descriptor_xattr_names(path, label + " entry")
        if not names:
            continue
        if names != {"com.apple.provenance"}:
            fail("%s has non-removable unexpected metadata at %s: %s" % (label, path.relative_to(root), sorted(names)))
        value = os.lstat(path)
        flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)
        if stat.S_ISDIR(value.st_mode):
            flags |= getattr(os, "O_DIRECTORY", 0)
        descriptor = os.open(str(path), flags)
        try:
            identity = stat_identity(value)
            if not identity_matches(identity, os.fstat(descriptor)):
                fail("%s changed before provenance removal" % label)
            before_digest = None
            if stat.S_ISREG(value.st_mode):
                _, before_digest = descriptor_hash(descriptor, label + " bytes before provenance removal", rewind=True)
            remove_descriptor_xattr(descriptor, "com.apple.provenance", label)
            if flistxattr_descriptor_names(descriptor, label + " post-removal entry"):
                fail("%s retained metadata after provenance removal at %s" % (label, path.relative_to(root)))
            if stat.S_ISREG(value.st_mode):
                reopened, reopened_identity = open_pinned_regular(path, label + " reopened after provenance removal")
            else:
                reopened, reopened_identity = open_directory_pinned(path, label + " reopened after provenance removal")
            try:
                if not identity_matches(identity, os.fstat(descriptor), allow_ctime_change=True) or not identity_matches(identity, reopened_identity, allow_ctime_change=True):
                    fail("%s changed during provenance removal" % label)
                if stat.S_ISREG(value.st_mode):
                    _, after_digest = descriptor_hash(reopened, label + " bytes after provenance removal", rewind=True)
                    if after_digest != before_digest:
                        fail("%s bytes changed during provenance removal" % label)
                if flistxattr_descriptor_names(reopened, label + " reopened post-removal entry"):
                    fail("%s retained metadata after reopening provenance target" % label)
                verify_pinned_identity(path, reopened, reopened_identity, label + " reopened provenance target", allow_ctime_change=True)
            finally:
                os.close(reopened)
        finally:
            os.close(descriptor)


def validate_clean_filesystem_metadata(root: Path, label: str, allowed_xattrs: Optional[Set[str]] = None) -> None:
    """Reject metadata that pkgbuild could carry into the install payload."""

    allowed = allowed_xattrs or set()
    if root.is_symlink() or not root.is_dir():
        fail("%s must be a real directory" % label)
    paths = [root] + sorted(root.rglob("*"), key=lambda item: item.as_posix())
    for path in paths:
        file_stat = os.lstat(path)
        if stat.S_ISLNK(file_stat.st_mode):
            fail("%s contains a symlink: %s" % (label, path.relative_to(root)))
        if not (stat.S_ISDIR(file_stat.st_mode) or stat.S_ISREG(file_stat.st_mode)):
            fail("%s contains a special file: %s" % (label, path.relative_to(root)))
        if stat.S_ISREG(file_stat.st_mode) and file_stat.st_nlink != 1:
            fail("%s contains a hard-linked file: %s" % (label, path.relative_to(root)))
        xattrs = descriptor_xattr_names(path, label + " entry")
        unexpected_xattrs = xattrs - allowed
        if unexpected_xattrs:
            fail("%s retained unexpected extended metadata at %s: %s" % (label, path.relative_to(root), sorted(unexpected_xattrs)))
        _, flags, _ = run_tool(["/usr/bin/stat", "-f", "%Sf", str(path)])
        if flags.strip() not in ("", "-"):
            fail("%s retained file flags at %s: %s" % (label, path.relative_to(root), flags.strip()))
        _, acl_listing, _ = run_tool(["/bin/ls", "-lde", str(path)])
        if any(re.match(r"^\s*[0-9]+:", line) for line in acl_listing.splitlines()[1:]):
            fail("%s retained an ACL at %s" % (label, path.relative_to(root)))


def validate_constructed_payload(
    root: Path,
    args: argparse.Namespace,
    inputs: Dict[str, Any],
    version_root: PurePosixPath,
) -> None:
    allowed_metadata = {"release.json", "model-manifest.json", "model-manifest.sha256", "model-attribution.txt"}
    allowed_docs = {"COMPATIBILITY.md", "SUPPORT.md", "CHANGELOG.md"}
    allowed_licenses = {"LICENSE", "THIRD_PARTY_NOTICES.md"}
    allowed_licenses.update(path.relative_to(inputs["licenses_dir"]).as_posix() for path in inputs["license_files"])
    scan_budget = {"used": 0}
    for path in ensure_safe_tree(root):
        scan_file_stream(path, "constructed payload " + safe_relative(path.relative_to(root)), scan_budget)
        relative = PurePosixPath(path.relative_to(root).as_posix())
        if relative.parts[: len(version_root.parts)] != version_root.parts:
            fail("constructed payload contains a path outside the versioned payload root")
        tail = relative.parts[len(version_root.parts):]
        if tail == (args.executable,) or (len(tail) == 1 and tail[0].endswith(".dylib")):
            continue
        if args.swift_build and tail == (SWIFT_RESOURCE_BUNDLE_NAME, SWIFT_RESOURCE_MANIFEST_NAME):
            continue
        if len(tail) == 2 and tail[0] == "metadata" and tail[1] in allowed_metadata:
            continue
        if len(tail) == 2 and tail[0] == "docs" and tail[1] in allowed_docs:
            continue
        if len(tail) >= 2 and tail[0] == "licenses" and PurePosixPath(*tail[1:]).as_posix() in allowed_licenses:
            continue
        fail("constructed payload contains an unallowed path: %s" % relative)


def archive_payload_contract(path: Path) -> Dict[str, str]:
    contract: Dict[str, str] = {}
    try:
        with tarfile.open(path, mode="r:gz") as tar:
            declared_total = 0
            seen: Dict[Tuple[str, ...], str] = {}
            kinds: Dict[Tuple[str, ...], str] = {}
            aliases: Dict[Tuple[str, ...], str] = {}
            for index, member in enumerate(tar, start=1):
                if index > MAX_ARCHIVE_MEMBERS:
                    fail("archive contains too many members")
                if member.size < 0 or member.size > MAX_ARCHIVE_MEMBER_BYTES:
                    fail("archive member declared size is outside the bound")
                declared_total += member.size
                if declared_total > MAX_ARCHIVE_DECLARED_BYTES:
                    fail("archive declared uncompressed size exceeds the bound")
                if member.issym() or member.islnk() or not member.isfile() and not member.isdir():
                    fail("archive payload contract contains an unsafe entry")
                normalized_name = validate_tar_member_name(member.name, "directory" if member.isdir() else "file", seen, kinds, aliases)
                name = PurePosixPath(normalized_name)
                normalized = "./" + name.as_posix()
                if MODEL_BYTE_RE.search(name.as_posix()):
                    fail("archive payload contract includes model bytes: %s" % name)
                if member.isdir():
                    contract[normalized] = "directory"
                elif member.isfile():
                    contract[normalized] = "file"
                else:
                    fail("archive payload contract contains an unsafe entry")
    except (OSError, tarfile.TarError) as error:
        fail("could not inspect archive payload contract: %s" % error)
    if not contract:
        fail("archive payload contract is empty")
    return contract


def validate_payload_modes(root: Path, executable_name: str) -> None:
    for path in ensure_safe_tree(root):
        mode = stat.S_IMODE(path.stat().st_mode)
        if mode & 0o022:
            fail("payload file is writable by group or other users: %s" % path.relative_to(root))
        if path.name == executable_name and mode != 0o755:
            fail("payload executable must have mode 0755")


def validate_payload_resource_bundle(payload_root: Path, args: argparse.Namespace, approved_manifest: bytes) -> None:
    version_root = payload_root / "Library" / "Application Support" / args.product_identity / "versions" / args.version
    metadata_path = version_root / "metadata" / "release.json"
    try:
        metadata = json.loads(read_bounded_text(metadata_path, "release metadata", 2 * 1024 * 1024))
    except (ValueError, TypeError) as error:
        fail("release metadata is not valid JSON: %s" % error)
    bundle_name = metadata.get("swiftResourceBundle")
    if bundle_name is None:
        if any(path.name.endswith(".bundle") for path in version_root.iterdir()):
            fail("payload contains an undeclared resource bundle")
        return
    if bundle_name != SWIFT_RESOURCE_BUNDLE_NAME:
        fail("payload declares an unsupported Swift resource bundle")
    validate_resource_bundle(version_root / bundle_name, approved_manifest)


def verify_archive_resource_bundle(archive: Path, args: argparse.Namespace, approved_manifest: bytes) -> None:
    if getattr(args, "unsigned_dry_run", False):
        verify_archive_resource_manifest(
            archive,
            args,
            approved_manifest,
            required=bool(getattr(args, "swift_build", False)),
        )
        return
    temporary = Path(tempfile.mkdtemp(prefix="release-resource-verify-"))
    staging_parent: Optional[Path] = None
    staging_mount: Optional[Path] = None
    try:
        if sys.platform == "darwin":
            staging_parent, staging_mount = create_clean_apfs_volume(temporary)
            clean_archive = staging_mount / "release-input.tar.gz"
            clean_payload = staging_mount / "payload"
            copy_archive_to_clean_boundary(archive, clean_archive)
            extract_safe_archive(clean_archive, clean_payload)
            validate_payload_resource_bundle(clean_payload, args, approved_manifest)
        else:
            extract_safe_archive(archive, temporary)
            validate_payload_resource_bundle(temporary, args, approved_manifest)
    finally:
        if staging_mount is not None:
            try:
                run_tool(["/usr/bin/hdiutil", "detach", "-force", str(staging_mount)])
            except ReleaseError:
                pass
        if staging_parent is not None:
            shutil.rmtree(staging_parent, ignore_errors=True)
        shutil.rmtree(temporary, ignore_errors=True)


def write_payload_file(root: Path, relative: str, data: bytes, mode: int = 0o644) -> Path:
    relative_path = PurePosixPath(relative)
    if relative_path.is_absolute() or ".." in relative_path.parts:
        fail("unsafe payload destination")
    destination = root.joinpath(*relative_path.parts)
    write_atomic(destination, data, mode=mode)
    return destination


def make_release_metadata(args: argparse.Namespace, inputs: Dict[str, Any], manifest_digest: str) -> Dict[str, Any]:
    product = args.product_identity
    relative_root = (PAYLOAD_ROOT_PREFIX / product / "versions" / args.version).as_posix()
    installed_root = "/" + relative_root
    formula_class = args.formula_class or re.sub(r"[^A-Za-z0-9]", "", product)
    if not FORMULA_CLASS_RE.fullmatch(formula_class):
        fail("product identity cannot derive a valid Homebrew formula class; pass --formula-class")
    return {
        "schemaVersion": 1,
        "productIdentity": product,
        "executable": args.executable,
        "packageIdentifier": args.package_id,
        "serviceLabel": args.service_label,
        "version": args.version,
        "tag": args.tag,
        "source": {"commit": args.source_commit, "annotatedTag": True},
        "owner": args.owner,
        "securityContact": args.security_contact,
        "teamId": args.team_id,
        "applicationIdentity": args.application_identity,
        "installerIdentity": args.installer_identity,
        "compatibility": {"minimumMacOS": "14.0", "architecture": "arm64"},
        "deliveryLayouts": {
            "package": {
                "payloadRoot": relative_root,
                "installLocation": "/",
                "installedRoot": installed_root,
                "executable": installed_root + "/" + args.executable,
                "serviceLabel": args.service_label,
            },
            "homebrew": {
                "sourcePayloadRoot": relative_root,
                "libexecRoot": "libexec",
                "executable": "libexec/" + args.executable,
                "binSymlink": "bin/" + args.executable,
                "currentPointer": "not applicable; Homebrew uses the formula prefix",
                "serviceLabel": args.service_label,
            },
        },
        "t50cRuntime": {
            "sourcePayloadRoot": relative_root,
            "materialization": "T50C copies the immutable versioned payload into its per-user service version store",
            "selection": "T50C lifecycle owns per-user version selection and rollback",
            "dataRootRelativeVersionPath": "service/versions/{version}",
            "selectionRecord": "service/selection.json",
            "selectionRecordOwner": "T50C lifecycle",
            "selectionField": "activeVersion",
        },
        "modelManifest": {"path": "metadata/model-manifest.json", "sha256": manifest_digest},
        "swiftResourceBundle": SWIFT_RESOURCE_BUNDLE_NAME if args.swift_build else None,
        "formulaClass": formula_class,
        "buildTimestamp": dt.datetime.fromtimestamp(inputs["commit_time"], tz=dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        "unsignedDryRun": bool(args.unsigned_dry_run),
    }


def make_payload(args: argparse.Namespace, inputs: Dict[str, Any], work_dir: Path) -> Tuple[Path, Dict[str, Any]]:
    payload_root = work_dir / "payload"
    payload_root.mkdir(parents=True, exist_ok=False)
    manifest_bytes = inputs["manifest_bytes"]
    manifest_digest = sha256_bytes(manifest_bytes)
    metadata = make_release_metadata(args, inputs, manifest_digest)
    version_root = PurePosixPath("Library") / "Application Support" / args.product_identity / "versions" / args.version
    executable_relative = version_root / args.executable
    executable_destination = payload_root.joinpath(*executable_relative.parts)
    binary = require_regular(repo_path(inputs["repo_root"], args.binary), "release executable")
    mode = stat.S_IMODE(binary.stat().st_mode)
    if mode & 0o022:
        fail("release executable is writable by group or other users")
    write_payload_file(payload_root, executable_relative.as_posix(), binary.read_bytes(), mode=0o755)
    if args.swift_build:
        source_bundle = binary.parent / SWIFT_RESOURCE_BUNDLE_NAME
        validate_resource_bundle(source_bundle, manifest_bytes)
        neutralize_swift_resource_fallback(executable_destination, source_bundle)
        copy_resource_bundle(source_bundle, executable_destination.parent / SWIFT_RESOURCE_BUNDLE_NAME, manifest_bytes)
        prepare_swift_runtime(args, executable_destination, executable_destination.parent)
    if not args.unsigned_dry_run:
        sign_and_verify_executable(args, executable_destination)
    metadata_relative = version_root / "metadata"
    write_payload_file(payload_root, (metadata_relative / "release.json").as_posix(), json_bytes(metadata))
    write_payload_file(payload_root, (metadata_relative / "model-manifest.json").as_posix(), manifest_bytes)
    write_payload_file(payload_root, (metadata_relative / "model-manifest.sha256").as_posix(), (manifest_digest + "  model-manifest.json\n").encode("ascii"))
    write_payload_file(payload_root, (metadata_relative / "model-attribution.txt").as_posix(), (str(inputs["manifest"]["attribution"]["notice"]) + "\n").encode("utf-8"))
    copy_payload_inputs(args, inputs, payload_root, version_root)
    validate_constructed_payload(payload_root, args, inputs, version_root)
    ensure_safe_tree(payload_root)
    validate_payload_modes(payload_root, args.executable)
    return payload_root, metadata


def copy_payload_inputs(args: argparse.Namespace, inputs: Dict[str, Any], payload_root: Path, version_root: PurePosixPath) -> None:
    license_root = version_root / "licenses"
    copy_regular(inputs["source_license"], write_payload_file(payload_root, (license_root / "LICENSE").as_posix(), inputs["source_license"].read_bytes()))
    copy_regular(inputs["notices"], write_payload_file(payload_root, (license_root / "THIRD_PARTY_NOTICES.md").as_posix(), inputs["notices"].read_bytes()))
    for license_file in inputs["license_files"]:
        relative = license_file.relative_to(inputs["licenses_dir"])
        copy_regular(license_file, write_payload_file(payload_root, (license_root / relative).as_posix(), license_file.read_bytes()))
    docs_root = version_root / "docs"
    for source, name in ((inputs["compatibility"], "COMPATIBILITY.md"), (inputs["support"], "SUPPORT.md"), (inputs["changelog"], "CHANGELOG.md")):
        copy_regular(source, write_payload_file(payload_root, (docs_root / name).as_posix(), source.read_bytes()))


def sign_and_verify_executable(args: argparse.Namespace, executable: Path) -> None:
    if sys.platform != "darwin":
        fail("Apple signing requires macOS")
    keychain = ["--keychain", args.signing_keychain] if args.signing_keychain else []
    _, application_identities, application_errors = run_tool(["security", "find-identity", "-v", "-p", "codesigning"] + keychain)
    application_names = set(re.findall(r'"(Developer ID Application: [^"]+ \([A-Z0-9]{10}\))"', application_identities + application_errors))
    if args.application_identity not in application_names:
        fail("declared Developer ID Application identity is not available in the signing keychain")
    _, installer_identities, installer_errors = run_tool(["security", "find-identity", "-v", "-p", "basic"] + keychain)
    installer_names = set(re.findall(r'"(Developer ID Installer: [^"]+ \([A-Z0-9]{10}\))"', installer_identities + installer_errors))
    if args.installer_identity not in installer_names:
        fail("declared Developer ID Installer identity is not available in the signing keychain")
    payload_root = executable.parents[4]
    for library in sorted(payload_root.rglob("*.dylib"), key=lambda path: path.as_posix()):
        sign_command = ["codesign", "--force", "--options", "runtime", "--timestamp", "--sign", args.application_identity]
        if args.signing_keychain:
            sign_command.extend(["--keychain", args.signing_keychain])
        run_tool(sign_command + [str(library)])
    sign_command = ["codesign", "--force", "--options", "runtime", "--timestamp", "--sign", args.application_identity]
    if args.signing_keychain:
        sign_command.extend(["--keychain", args.signing_keychain])
    run_tool(sign_command + [str(executable)])
    verify_signed_closure(args, executable, payload_root)


def parse_otool_dependencies(output: str) -> List[str]:
    dependencies: List[str] = []
    for line in output.splitlines()[1:]:
        match = re.match(r"\s+(\S+) \(", line)
        if match:
            dependencies.append(match.group(1))
    return dependencies


def parse_otool_rpaths(output: str) -> List[str]:
    return [match.group(1) for match in (re.match(r"\s+path (\S+) \(offset", line) for line in output.splitlines()) if match]


def expand_loader_token(value: str, owner: Path, executable: Path) -> str:
    expanded = value.replace("@loader_path", str(owner.parent)).replace("@executable_path", str(executable.parent))
    return expanded


def prohibited_library_path(value: str) -> bool:
    return any(value.startswith(prefix) for prefix in ("/opt/homebrew/", "/usr/local/", "/Library/Developer/", "/Applications/Xcode.app/", "/Users/", "/home/", "/private/tmp/", "/tmp/"))


def system_dependency_is_available(value: str) -> bool:
    """The reviewed minimum-OS contract includes dyld shared-cache members."""
    return value in SYSTEM_DEPENDENCY_CONTRACT


def resolve_dynamic_dependency(dependency: str, owner: Path, executable: Path, payload_root: Path, rpaths: List[str]) -> Optional[Path]:
    if "@" not in dependency:
        candidates = [Path(dependency)]
    elif dependency.startswith("@rpath/"):
        candidates = [Path(expand_loader_token(rpath, owner, executable)) / dependency[len("@rpath/"):] for rpath in rpaths]
    elif dependency.startswith("@loader_path/") or dependency.startswith("@executable_path/"):
        candidates = [Path(expand_loader_token(dependency, owner, executable))]
    else:
        fail("unresolved dynamic loader token: %s" % dependency)
    reviewed_system_candidate = False
    for candidate in candidates:
        candidate_text = str(candidate)
        if prohibited_library_path(candidate_text) or "@" in candidate_text:
            fail("forbidden or unresolved dynamic library: %s" % dependency)
        try:
            resolved = candidate.resolve(strict=False)
        except OSError:
            continue
        if resolved.is_file() and resolved.is_relative_to(payload_root):
            return resolved
        if str(resolved) in SYSTEM_DEPENDENCY_CONTRACT and system_dependency_is_available(str(resolved)):
            reviewed_system_candidate = True
            continue
    if reviewed_system_candidate:
        return None
    if dependency.startswith("/") and dependency in SYSTEM_DEPENDENCY_CONTRACT:
        if system_dependency_is_available(dependency):
            return None
        fail("system dynamic dependency is not locally proven: %s" % dependency)
    fail("unresolved dynamic library: %s" % dependency)


def dynamic_closure(executable: Path, payload_root: Path) -> Set[Path]:
    executable = executable.resolve()
    payload_root = payload_root.resolve()
    queue = [executable]
    seen: Set[Path] = set()
    bundled: Set[Path] = set()
    while queue:
        owner = queue.pop(0)
        if owner in seen:
            continue
        seen.add(owner)
        _, load_output, load_errors = run_tool(["otool", "-L", str(owner)])
        _, rpath_output, rpath_errors = run_tool(["otool", "-l", str(owner)])
        rpaths = parse_otool_rpaths(rpath_output + rpath_errors)
        for rpath in rpaths:
            if rpath in ALLOWED_RPATHS:
                continue
            expanded_rpath = expand_loader_token(rpath, owner, executable)
            if "@" in expanded_rpath or prohibited_library_path(expanded_rpath):
                fail("prohibited or unresolved dynamic rpath: %s" % rpath)
            try:
                canonical_rpath = Path(expanded_rpath).resolve(strict=False)
            except OSError:
                fail("dynamic rpath could not be canonicalized: %s" % rpath)
            if prohibited_library_path(str(canonical_rpath)):
                fail("prohibited dynamic rpath: %s" % rpath)
            if canonical_rpath == Path("/usr/lib/swift"):
                continue
            if not canonical_rpath.is_relative_to(payload_root):
                fail("dynamic rpath escapes the payload: %s" % rpath)
        for dependency in parse_otool_dependencies(load_output + load_errors):
            resolved = resolve_dynamic_dependency(dependency, owner, executable, payload_root, rpaths)
            if resolved is not None:
                bundled.add(resolved)
                if resolved not in seen:
                    queue.append(resolved)
    expected_bundled = {path.resolve() for path in payload_root.rglob("*.dylib")}
    if bundled != expected_bundled:
        unexpected = sorted(str(path) for path in expected_bundled - bundled)
        if unexpected:
            fail("payload contains an unreferenced dynamic library: " + unexpected[0])
    return bundled


def verify_signed_closure(args: argparse.Namespace, executable: Path, payload_root: Path) -> None:
    keychain = ["--keychain", args.signing_keychain] if args.signing_keychain else []
    for path in [executable] + sorted(payload_root.rglob("*.dylib"), key=lambda item: item.as_posix()):
        _, details, errors = run_tool(["codesign", "--verify", "--strict", "--verbose=2"] + keychain + [str(path)])
        combined = details + errors
        if "valid on disk" not in combined.lower() and "satisfies its designated requirement" not in combined.lower():
            fail("codesign verification did not report a valid signature: %s" % path.name)
        _, display, display_errors = run_tool(["codesign", "-dv", "--verbose=4"] + keychain + [str(path)])
        details_text = display + display_errors
        expected_authority = args.application_identity
        if "flags=" not in details_text or "runtime" not in details_text.lower():
            fail("signed file is missing Hardened Runtime: %s" % path.name)
        if "Timestamp=" not in details_text:
            fail("signed file is missing a trusted timestamp: %s" % path.name)
        if "TeamIdentifier=" + args.team_id not in details_text:
            fail("signed file Team ID does not match the declared Team ID: %s" % path.name)
        authorities = re.findall(r"^Authority=(.+)$", details_text, re.MULTILINE)
        if not authorities or authorities[0].strip() != expected_authority:
            fail("signed file authority does not match the declared Developer ID Application identity: %s" % path.name)
        _, requirement, requirement_errors = run_tool(["codesign", "-d", "-r-", "--verbose=2"] + keychain + [str(path)])
        if "designated =>" not in requirement + requirement_errors:
            fail("signed file has no designated requirement: %s" % path.name)
    dynamic_closure(executable, payload_root)


def sanitize_runtime_rpaths(args: argparse.Namespace, payload_root: Path, executable: Path) -> None:
    for path in [path for path in payload_root.rglob("*") if path.is_file() and (path.name == args.executable or path.suffix == ".dylib")]:
        _, load_output, load_errors = run_tool(["otool", "-L", str(path)])
        dependencies = parse_otool_dependencies(load_output + load_errors)
        _, output, errors = run_tool(["otool", "-l", str(path)])
        rpaths = parse_otool_rpaths(output + errors)
        bundled_names = {item.name for item in payload_root.rglob("*.dylib")}
        has_payload_rpath = any(rpath == "@loader_path" for rpath in rpaths)
        for rpath in rpaths:
            expanded = expand_loader_token(rpath, path, executable)
            try:
                canonical_expanded = Path(expanded).resolve(strict=False)
                payload_relative = canonical_expanded.is_relative_to(payload_root.resolve())
            except OSError:
                payload_relative = False
            bundled_name_conflict = expanded == "/usr/lib/swift" and any(
                dependency.startswith("@rpath/") and dependency[len("@rpath/"):].split("/")[-1] in bundled_names
                for dependency in dependencies
            )
            if not payload_relative and prohibited_library_path(expanded):
                run_tool(["install_name_tool", "-delete_rpath", rpath, str(path)])
            elif rpath == "/usr/lib/swift" and bundled_name_conflict:
                # Keep the reviewed system rpath, but make the payload-relative
                # rpath win for a compatibility library copied into the payload.
                run_tool(["install_name_tool", "-delete_rpath", rpath, str(path)])
                run_tool(["install_name_tool", "-add_rpath", rpath, str(path)])
        if path.name == args.executable and not has_payload_rpath and any(
            dependency.startswith("@rpath/") and dependency[len("@rpath/"):].split("/")[-1] in bundled_names
            for dependency in dependencies
        ):
            run_tool(["install_name_tool", "-add_rpath", "@loader_path", str(path)])


def prepare_swift_runtime(args: argparse.Namespace, executable: Path, version_root: Path) -> None:
    if not args.swift_build:
        return
    run_tool(["xcrun", "swift-stdlib-tool", "--copy", "--scan-executable", str(executable), "--destination", str(version_root), "--platform", "macosx"])
    payload_root = version_root.parents[4]
    sanitize_runtime_rpaths(args, payload_root, executable)
    dynamic_closure(executable, payload_root)


def add_tar_entry(tar: tarfile.TarFile, source: Path, name: str) -> None:
    info = tarfile.TarInfo(name=name)
    info.mtime = 0
    info.uid = 0
    info.gid = 0
    info.uname = "root"
    info.gname = "wheel"
    mode = stat.S_IMODE(source.stat().st_mode)
    info.mode = 0o755 if mode & 0o111 else 0o644
    data = source.read_bytes()
    info.size = len(data)
    tar.addfile(info, fileobj=__import__("io").BytesIO(data))


def create_deterministic_archive(source_root: Path, destination: Path, prefix: Optional[str] = None) -> None:
    files = ensure_safe_tree(source_root)
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_name("." + destination.name + ".tmp")
    with temporary.open("wb") as raw:
        import gzip

        with gzip.GzipFile(fileobj=raw, mode="wb", filename="", mtime=0) as compressed:
            with tarfile.open(fileobj=compressed, mode="w", format=tarfile.PAX_FORMAT) as tar:
                directories = set()
                for file_path in files:
                    relative = PurePosixPath(safe_relative(file_path.relative_to(source_root)))
                    if prefix:
                        relative = PurePosixPath(prefix) / relative
                    for index in range(1, len(relative.parts)):
                        directories.add(PurePosixPath(*relative.parts[:index]))
                for directory in sorted(directories, key=lambda item: item.as_posix()):
                    info = tarfile.TarInfo(name=directory.as_posix())
                    info.type = tarfile.DIRTYPE
                    info.mode = 0o755
                    info.mtime = 0
                    info.uid = 0
                    info.gid = 0
                    info.uname = "root"
                    info.gname = "wheel"
                    tar.addfile(info)
                for file_path in files:
                    relative = PurePosixPath(safe_relative(file_path.relative_to(source_root)))
                    name = (PurePosixPath(prefix) / relative).as_posix() if prefix else relative.as_posix()
                    add_tar_entry(tar, file_path, name)
        raw.flush()
        os.fsync(raw.fileno())
    os.replace(temporary, destination)


def create_source_archive(repo_root: Path, tag: str, destination: Path, prefix: str) -> None:
    source_fd, source_name = tempfile.mkstemp(prefix="release-source-", suffix=".tar", dir=str(destination.parent))
    os.close(source_fd)
    source_tar = Path(source_name)
    try:
        run_tool(["git", "archive", "--format=tar", "--output", str(source_tar), tag], cwd=repo_root)
        temporary = destination.with_name("." + destination.name + ".tmp")
        import gzip

        with temporary.open("wb") as raw:
            with gzip.GzipFile(fileobj=raw, mode="wb", filename="", mtime=0) as compressed:
                with tarfile.open(fileobj=compressed, mode="w", format=tarfile.PAX_FORMAT) as target:
                    with tarfile.open(source_tar, mode="r:") as source:
                        for member in sorted(source.getmembers(), key=lambda item: item.name):
                            name = PurePosixPath(prefix) / PurePosixPath(member.name)
                            if name.is_absolute() or ".." in name.parts or member.issym() or member.islnk() or not member.isfile() and not member.isdir():
                                fail("source archive contains an unsafe Git entry")
                            info = tarfile.TarInfo(name=name.as_posix())
                            info.type = tarfile.DIRTYPE if member.isdir() else tarfile.REGTYPE
                            info.mode = stat.S_IMODE(member.mode) & 0o777
                            info.mtime = 0
                            info.uid = 0
                            info.gid = 0
                            info.uname = "root"
                            info.gname = "wheel"
                            if member.isfile():
                                data = source.extractfile(member)
                                if data is None:
                                    fail("source archive contains an unreadable Git entry")
                                content = data.read()
                                info.size = len(content)
                                target.addfile(info, fileobj=__import__("io").BytesIO(content))
                            else:
                                target.addfile(info)
            raw.flush()
            os.fsync(raw.fileno())
        os.replace(temporary, destination)
    finally:
        source_tar.unlink(missing_ok=True)


def validate_package_signature(output: str, args: argparse.Namespace) -> None:
    lowered = output.lower()
    if "status: signed" not in lowered and "signed by" not in lowered:
        fail("installer package is not reported as signed")
    certificate_names = set(re.findall(r"Developer ID (?:Application|Installer): [^\n\r]+ \([A-Z0-9]{10}\)", output))
    if args.installer_identity not in certificate_names:
        fail("installer package signing identity does not match the declared identity")
    if any(name.startswith("Developer ID Application:") for name in certificate_names):
        fail("installer package certificate chain contains an application certificate instead of the selected installer leaf")
    if not any(name.endswith("(" + args.team_id + ")") for name in certificate_names):
        fail("installer package signing Team ID does not match the declared Team ID")


def stage_payload_without_metadata(source: Path, destination: Path) -> None:
    """Copy validated payload bytes and modes without filesystem metadata."""

    require_directory(source, "package staging source")
    source_files = ensure_safe_tree(source)
    validate_clean_filesystem_metadata(source, "package staging source", {"com.apple.provenance"})
    run_tool(["/bin/mkdir", "-p", str(destination)])
    for path in sorted(source.rglob("*"), key=lambda item: item.as_posix()):
        relative = path.relative_to(source)
        if path.is_symlink():
            fail("package staging source contains a symlink: %s" % relative)
        target = destination.joinpath(*relative.parts)
        if path.is_dir():
            run_tool(["/bin/mkdir", "-p", str(target)])
            run_tool(["/bin/chmod", "%o" % stat.S_IMODE(path.stat().st_mode), str(target)])
            continue
        if not path.is_file():
            fail("package staging source contains a special file: %s" % relative)
        run_tool(["/bin/mkdir", "-p", str(target.parent)])
        run_tool(["/bin/cp", "-X", str(path), str(target)], env={"COPYFILE_DISABLE": "1"})
        run_tool(["/bin/chmod", "%o" % stat.S_IMODE(path.stat().st_mode), str(target)])
    remove_exact_host_provenance(destination, "package staging")
    validate_clean_filesystem_metadata(destination, "package staging")

    for source_file in source_files:
        target = destination / source_file.relative_to(source)
        if sha256_file(source_file) != sha256_file(target):
            fail("package staging changed payload bytes: %s" % source_file.relative_to(source))
        if stat.S_IMODE(source_file.stat().st_mode) != stat.S_IMODE(target.stat().st_mode):
            fail("package staging changed payload mode: %s" % source_file.relative_to(source))


def create_clean_apfs_volume(destination_parent: Path) -> Tuple[Path, Path]:
    """Create a private APFS boundary that does not inherit host metadata."""
    if sys.platform == "darwin":
        clean_parent = Path("/tmp")
    else:
        clean_parent = destination_parent
    staging_parent = Path(run_tool(["/usr/bin/mktemp", "-d", str(clean_parent / "pkg-staging-XXXXXX")])[1].strip())
    if staging_parent.parent != clean_parent or staging_parent.is_symlink() or not staging_parent.is_dir():
        fail("clean APFS staging parent is not a private directory")
    image = staging_parent / "payload.sparseimage"
    volume_name = "ReleasePayload-" + staging_parent.name
    mount = Path("/Volumes/" + volume_name)
    attached = False
    try:
        run_tool(["/usr/bin/hdiutil", "create", "-size", "512m", "-fs", "APFS", "-type", "SPARSE", "-volname", volume_name, "-ov", str(image)])
        _, attach_output, attach_errors = run_tool(["/usr/bin/hdiutil", "attach", "-nobrowse", "-plist", str(image)])
        attached = True
        try:
            document = plistlib.loads(attach_output.encode("utf-8"))
        except (OSError, ValueError, plistlib.InvalidFileException) as error:
            fail("hdiutil attach did not return valid bounded plist metadata: %s" % error)
        entities = document.get("system-entities") if isinstance(document, dict) else None
        mounts = [
            entity.get("mount-point")
            for entity in entities or []
            if isinstance(entity, dict) and entity.get("volume-kind") == "apfs" and isinstance(entity.get("mount-point"), str)
        ]
        if len(mounts) != 1 or not mounts[0].startswith("/Volumes/") or "/" in mounts[0][len("/Volumes/"):]:
            fail("hdiutil attach did not return one safe APFS mount point")
        mount = Path(mounts[0])
        validate_clean_filesystem_metadata(mount, "clean APFS volume")
        return staging_parent, mount
    except BaseException:
        if attached:
            try:
                run_tool(["/usr/bin/hdiutil", "detach", "-force", str(mount)])
            except ReleaseError:
                pass
        shutil.rmtree(staging_parent, ignore_errors=True)
        raise


def create_clean_package_staging(source: Path, destination_parent: Path) -> Tuple[Path, Path, Path]:
    """Stage a package root on a temporary APFS volume without provenance metadata."""

    staging_parent, mount = create_clean_apfs_volume(destination_parent)
    try:
        package_root = mount / "root"
        stage_payload_without_metadata(source, package_root)
        return staging_parent, mount, package_root
    except BaseException:
        try:
            run_tool(["/usr/bin/hdiutil", "detach", "-force", str(mount)])
        except ReleaseError:
            pass
        shutil.rmtree(staging_parent, ignore_errors=True)
        raise


def parse_notary_result(output: str) -> Dict[str, Any]:
    try:
        result = json.loads(output)
    except (ValueError, TypeError) as error:
        fail("notarytool did not return valid JSON: %s" % error)
    if not isinstance(result, dict) or result.get("status") != "Accepted":
        fail("notarytool did not accept the package")
    return result


def package_with_apple_tools(args: argparse.Namespace, payload_root: Path, destination: Path) -> Dict[str, Any]:
    if sys.platform != "darwin":
        fail("signed package creation requires macOS; use --unsigned-dry-run for fixtures")
    staging_parent, staging_mount, package_root = create_clean_package_staging(payload_root, destination.parent)
    unsigned = destination.with_name("." + destination.name + ".unsigned.tmp")
    try:
        package_contract = payload_contract(package_root)
        run_tool(
            ["pkgbuild", "--root", str(package_root), "--identifier", args.package_id, "--version", args.version, "--install-location", "/", "--ownership", "recommended", str(unsigned)],
            env={"COPYFILE_DISABLE": "1"},
        )
        product_sign = ["productsign", "--sign", args.installer_identity]
        if args.signing_keychain:
            product_sign.extend(["--keychain", args.signing_keychain])
        run_tool(product_sign + [str(unsigned), str(destination)])
        unsigned.unlink(missing_ok=True)
        _, signature_output, signature_errors = run_tool(["pkgutil", "--check-signature", str(destination)])
        validate_package_signature(signature_output + signature_errors, args)
        _, payload, payload_errors = run_tool(["pkgutil", "--payload-files", str(destination)])
        validate_payload_listing(payload + payload_errors, package_contract)
        notary_command = ["xcrun", "notarytool", "submit", str(destination), "--keychain-profile", args.notary_profile]
        if args.notary_keychain:
            notary_command.extend(["--keychain", args.notary_keychain])
        notary_command.extend(["--wait", "--output-format", "json"])
        _, notary_output, notary_errors = run_tool(notary_command)
        notary_result = parse_notary_result(notary_output or notary_errors)
        run_tool(["xcrun", "stapler", "staple", "-v", str(destination)])
        run_tool(["xcrun", "stapler", "validate", "-v", str(destination)])
        quarantined_root = Path(tempfile.mkdtemp(prefix="release-quarantine-"))
        quarantined = quarantined_root / destination.name
        shutil.copy2(destination, quarantined)
        try:
            run_tool(["xattr", "-w", "com.apple.quarantine", "0081;00000000;release;release", str(quarantined)])
            run_tool(["spctl", "--assess", "--type", "install", "--context", "0", "--verbose", str(quarantined)])
        finally:
            shutil.rmtree(quarantined_root, ignore_errors=True)
        return notary_result
    finally:
        unsigned.unlink(missing_ok=True)
        try:
            run_tool(["/usr/bin/hdiutil", "detach", "-force", str(staging_mount)])
        finally:
            shutil.rmtree(staging_parent, ignore_errors=True)


def validate_payload_listing(output: str, expected: Dict[str, str]) -> None:
    actual: Dict[str, str] = {}
    root_marker_seen = False
    for raw_line in output.splitlines():
        line = raw_line.strip()
        if not line:
            continue
        if line in (".", "./"):
            if root_marker_seen:
                fail("installer payload listing contains a duplicate root marker")
            root_marker_seen = True
            continue
        if not line.startswith("./") or line.endswith("/"):
            fail("installer payload listing contains a malformed path")
        name = PurePosixPath(line[2:])
        if name.is_absolute() or ".." in name.parts or "." in name.parts or "" in name.parts:
            fail("installer payload listing contains traversal or dot segments")
        normalized = "./" + name.as_posix()
        if normalized in actual:
            fail("installer payload listing contains a duplicate path")
        actual[normalized] = "file"
    if not actual:
        fail("installer payload listing was empty or unparsable")
    for name in actual:
        if any(other != name and other.startswith(name + "/") for other in actual):
            actual[name] = "directory"
    validate_payload_contract(actual, expected)


def validate_payload_contract(actual: Dict[str, str], expected: Dict[str, str]) -> None:
    if set(actual) != set(expected):
        missing = sorted(set(expected) - set(actual))
        extra = sorted(set(actual) - set(expected))
        fail("installer payload paths differ, missing=%s extra=%s" % (missing[:1], extra[:1]))
    mismatches = sorted(name for name in expected if actual[name] != expected[name])
    if mismatches:
        fail("installer payload file or directory type differs: %s" % mismatches[0])


def compare_payload_trees(expected_root: Path, actual_root: Path, executable_name: str) -> None:
    expected_contract = payload_contract(expected_root)
    actual_contract = payload_contract(actual_root)
    validate_payload_contract(actual_contract, expected_contract)
    validate_clean_filesystem_metadata(actual_root, "expanded package payload")
    for relative, kind in expected_contract.items():
        target = actual_root / relative[2:]
        expected = expected_root / relative[2:]
        if kind == "directory":
            if stat.S_IMODE(target.stat().st_mode) != 0o755:
                fail("package directory mode is not 0755: %s" % relative)
            continue
        target_stat = target.stat()
        target_mode = stat.S_IMODE(target_stat.st_mode)
        expected_mode = 0o755 if target.name == executable_name or target.suffix == ".dylib" else 0o644
        if target_mode != expected_mode:
            fail("package payload mode is not exact: %s" % relative)
        if target_stat.st_nlink != 1 or sha256_file(target) != sha256_file(expected):
            fail("package payload bytes or link count differ: %s" % relative)


def verify_expanded_package(package: Path, expected_root: Path, executable_name: str) -> None:
    temporary = Path(tempfile.mkdtemp(prefix="release-pkg-expand-"))
    staging_parent: Optional[Path] = None
    staging_mount: Optional[Path] = None
    try:
        staging_parent, staging_mount = create_clean_apfs_volume(temporary)
        expanded = staging_mount / "expanded"
        run_tool(["/usr/sbin/pkgutil", "--expand-full", str(package), str(expanded)])
        bom_output = ""
        try:
            _, bom_output, bom_errors = run_tool(["/usr/sbin/pkgutil", "--bom", str(package)])
            bom_path = Path((bom_output or bom_errors).strip())
            if bom_path.is_file():
                run_tool(["/usr/bin/lsbom", "-s", "-m", str(bom_path)])
        except ReleaseError:
            fail("could not inspect the signed package BOM")
        payloads = [
            path for path in expanded.rglob("Payload")
            if (path.is_dir() or path.is_file()) and not path.is_symlink()
        ]
        if len(payloads) != 1:
            fail("signed package expansion did not produce exactly one payload")
        if payloads[0].is_dir():
            extracted = payloads[0]
        else:
            extracted = staging_mount / "payload"
            run_tool(["/usr/bin/ditto", "-x", "-f", "cpio", str(payloads[0]), str(extracted)])
        compare_payload_trees(expected_root, extracted, executable_name)
    finally:
        if staging_mount is not None:
            try:
                run_tool(["/usr/bin/hdiutil", "detach", "-force", str(staging_mount)])
            except ReleaseError:
                pass
        if staging_parent is not None:
            shutil.rmtree(staging_parent, ignore_errors=True)
        shutil.rmtree(temporary, ignore_errors=True)


def write_spdx(args: argparse.Namespace, inputs: Dict[str, Any], payload_root: Path, artifact_paths: List[Path], destination: Path) -> None:
    resolved = json.loads((inputs["repo_root"] / "Package.resolved").read_text(encoding="utf-8"))
    packages: List[Dict[str, Any]] = []
    relationships: List[Dict[str, str]] = []
    for index, pin in enumerate(sorted(resolved["pins"], key=lambda item: item["identity"]), start=1):
        state = pin["state"]
        package_id = "SPDXRef-Package-%03d" % index
        package = {
            "SPDXID": package_id,
            "name": pin["identity"],
            "versionInfo": state.get("version") or state["revision"],
            "downloadLocation": pin["location"] + "#" + state["revision"],
            "filesAnalyzed": False,
            "licenseConcluded": "NOASSERTION",
            "licenseDeclared": "NOASSERTION",
            "copyrightText": "NOASSERTION",
            "externalRefs": [{"referenceCategory": "OTHER", "referenceType": "git-commit", "referenceLocator": state["revision"]}],
        }
        packages.append(package)
        relationships.append({"spdxElementId": "SPDXRef-DOCUMENT", "relationshipType": "DESCRIBES", "relatedSpdxElement": package_id})
    files: List[Dict[str, Any]] = []
    for index, path in enumerate(ensure_safe_tree(payload_root), start=1):
        relative = safe_relative(path.relative_to(payload_root))
        file_id = "SPDXRef-File-%04d" % index
        files.append({
            "SPDXID": file_id,
            "fileName": "/" + relative,
            "checksums": [{"algorithm": "SHA256", "checksumValue": sha256_file(path)}],
            "licenseConcluded": "NOASSERTION",
            "copyrightText": "NOASSERTION",
        })
        relationships.append({"spdxElementId": "SPDXRef-DOCUMENT", "relationshipType": "CONTAINS", "relatedSpdxElement": file_id})
    external_artifacts = []
    for path in sorted(artifact_paths, key=lambda item: item.name):
        external_artifacts.append({"name": path.name, "sha256": sha256_file(path), "size": path.stat().st_size})
    document = {
        "spdxVersion": "SPDX-2.3",
        "dataLicense": "CC0-1.0",
        "SPDXID": "SPDXRef-DOCUMENT",
        "name": "%s-%s-sbom" % (args.product_identity, args.version),
        "documentNamespace": "%s/releases/%s/%s" % (args.repository_url, args.tag, args.source_commit),
        "creationInfo": {"created": "1970-01-01T00:00:00Z", "creators": ["Tool: native-parakeet-release-tooling"]},
        "packages": packages,
        "files": files,
        "relationships": relationships,
        "externalDocumentRefs": [],
        "comment": "Release artifact subjects: " + json.dumps(external_artifacts, sort_keys=True, separators=(",", ":")),
    }
    write_atomic(destination, json_bytes(document))


def write_provenance(args: argparse.Namespace, inputs: Dict[str, Any], artifact_paths: List[Path], destination: Path) -> None:
    subjects = [{"name": path.name, "digest": {"sha256": sha256_file(path)}} for path in sorted(artifact_paths, key=lambda item: item.name)]
    resolved_digest = sha256_file(inputs["repo_root"] / "Package.resolved")
    statement = {
        "_type": "https://in-toto.io/Statement/v1",
        "subject": subjects,
        "predicateType": "https://slsa.dev/provenance/v1",
        "predicate": {
            "buildDefinition": {
                "buildType": "https://github.com/slsa-framework/slsa-github-generator/generic@v1",
                "externalParameters": {"tag": args.tag, "sourceCommit": args.source_commit, "version": args.version},
                "internalParameters": {"runnerArchitecture": "arm64", "minimumMacOS": "14.0"},
                "resolvedDependencies": [
                    {"uri": args.repository_url, "digest": {"gitCommit": args.source_commit}},
                    {"uri": "Package.resolved", "digest": {"sha256": resolved_digest}},
                ],
            },
            "runDetails": {"builder": {"id": "https://github.com/actions/runner"}, "metadata": {"invocationId": args.tag}},
        },
    }
    write_atomic(destination, (json.dumps(statement, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8"))


def write_formula(args: argparse.Namespace, metadata: Dict[str, Any], archive_name: str, archive_digest: str, destination: Path) -> None:
    formula_class = metadata["formulaClass"]
    release_url = args.repository_url + "/releases/download/" + args.tag + "/" + archive_name
    if MUTABLE_URL_RE.search(release_url):
        fail("Homebrew URL contains a mutable release ref")
    formula = """class {formula_class} < Formula
  desc \"Signed native macOS {product} service\"
  homepage \"{repository_url}\"
  version \"{version}\"
  url \"{release_url}\"
  sha256 \"{archive_digest}\"

  depends_on macos: :sonoma
  depends_on arch: :arm64

  def install
    payload = buildpath/\"Library/Application Support/{product}/versions/{version}\"
    libexec.install Dir[\"#{{payload}}/*\"]
    bin.install_symlink libexec/\"{executable}\" => \"{executable}\"
  end

  def caveats
    <<~EOS
      The Core ML model is not included in this package and is never downloaded by Homebrew.
      Install the reviewed immutable model manifest with:
        {executable} models install --activate
      Then run the service preflight before enabling the LaunchAgent.
    EOS
  end
end
""".format(formula_class=formula_class, repository_url=args.repository_url, product=args.product_identity, version=args.version, release_url=release_url, archive_digest=archive_digest, executable=args.executable)
    write_atomic(destination, formula.encode("utf-8"))


def write_license_bundle(args: argparse.Namespace, inputs: Dict[str, Any], payload_root: Path, destination: Path) -> None:
    license_root = payload_root / "Library" / "Application Support" / args.product_identity / "versions" / args.version / "licenses"
    create_deterministic_archive(license_root, destination, prefix="licenses")


def write_checksums(paths: List[Path], destination: Path) -> None:
    lines = ["%s  %s" % (sha256_file(path), path.name) for path in sorted(paths, key=lambda item: item.name)]
    write_atomic(destination, ("\n".join(lines) + "\n").encode("ascii"))


def write_signature(args: argparse.Namespace, checksums: Path, destination: Path) -> None:
    if args.unsigned_dry_run:
        marker = {"schemaVersion": 1, "mode": "unsigned-dry-run", "algorithm": "SHA-256", "signedFile": checksums.name, "digest": sha256_file(checksums)}
        write_atomic(destination, json_bytes(marker))
        return
    if not args.signature_private_key or not args.signature_public_key:
        fail("real release requires detached-signature private and public key paths")
    private_key = require_regular(Path(args.signature_private_key), "detached-signature private key")
    public_key = require_regular(Path(args.signature_public_key), "detached-signature public key")
    if private_key == destination or public_key == destination:
        fail("signature key may not be an output artifact")
    if stat.S_IMODE(private_key.stat().st_mode) & 0o077 or stat.S_IMODE(public_key.stat().st_mode) & 0o077:
        fail("detached-signature key files must not be group or world readable")
    run_tool(["openssl", "dgst", "-sha256", "-sign", str(private_key), "-out", str(destination), str(checksums)])
    run_tool(["openssl", "dgst", "-sha256", "-verify", str(public_key), "-signature", str(destination), str(checksums)])


def formula_class_for(args: argparse.Namespace) -> str:
    formula_class = args.formula_class or re.sub(r"[^A-Za-z0-9]", "", args.product_identity)
    if not FORMULA_CLASS_RE.fullmatch(formula_class):
        fail("product identity cannot derive a valid Homebrew formula class; pass --formula-class")
    return formula_class


def expected_asset_names(args: argparse.Namespace, unsigned: bool) -> Set[str]:
    versioned_name = "%s-%s" % (args.product_identity, args.version)
    package_name = versioned_name + (".pkg.layout.tar.gz" if unsigned else ".pkg")
    return {
        versioned_name + ".tar.gz", package_name, versioned_name + ".licenses.tar.gz", versioned_name + ".source.tar.gz",
        "model-manifest.json", "model-manifest.sha256", versioned_name + ".compatibility.md", versioned_name + ".support.md",
        versioned_name + ".changelog.md", versioned_name + ".notary.json", formula_class_for(args) + ".rb",
        versioned_name + ".spdx.json", versioned_name + ".provenance.intoto.jsonl",
    }


def write_inventory(args: argparse.Namespace, paths: List[Path], destination: Path) -> None:
    artifacts = [{"name": path.name, "size": path.stat().st_size, "sha256": sha256_file(path)} for path in sorted(paths, key=lambda item: item.name)]
    expected = expected_asset_names(args, args.unsigned_dry_run)
    if {item["name"] for item in artifacts} != expected:
        fail("release inventory was not constructed from the exact V5 asset contract")
    inventory = {"schemaVersion": 1, "productIdentity": args.product_identity, "version": args.version, "tag": args.tag, "sourceCommit": args.source_commit, "artifacts": artifacts, "excludesSelf": True}
    write_atomic(destination, json_bytes(inventory))


def write_metadata_asset(source: Path, destination: Path) -> None:
    write_atomic(destination, source.read_bytes())


def build_release(args: argparse.Namespace) -> None:
    if args.unsigned_dry_run == args.sign:
        fail("choose exactly one of --unsigned-dry-run or --sign")
    if args.sign and sys.platform != "darwin":
        fail("--sign is supported only on macOS")
    inputs = validate_release_inputs(args, require_notary_profile=args.sign)
    output_dir = args.output_dir.absolute()
    if output_dir.is_symlink() or (output_dir.exists() and not output_dir.is_dir()):
        fail("release output directory must be a real directory")
    if output_dir.exists() and any(output_dir.iterdir()):
        fail("release output directory must be new and empty; immutable assets are never overwritten")
    output_dir.mkdir(parents=True, exist_ok=True)
    staging_parent: Optional[Path] = None
    staging_mount: Optional[Path] = None
    if args.sign and sys.platform == "darwin":
        staging_parent, staging_mount = create_clean_apfs_volume(output_dir.parent)
        work_dir = staging_mount / "release-build"
        run_tool(["/bin/mkdir", "-p", str(work_dir)])
    else:
        work_dir = Path(tempfile.mkdtemp(prefix="release-build-", dir=str(output_dir.parent)))
    try:
        binary = repo_path(inputs["repo_root"], args.binary) if args.binary else None
        if args.swift_build:
            if binary is not None:
                fail("--swift-build and --binary are mutually exclusive")
            run_tool(["swift", "build", "--disable-sandbox", "--configuration", "release", "--arch", "arm64"], cwd=inputs["repo_root"])
            _, bin_path, _ = run_tool(["swift", "build", "--show-bin-path", "--configuration", "release"], cwd=inputs["repo_root"])
            args.binary = str(Path(bin_path.strip()) / args.executable)
        elif not args.binary:
            fail("--binary or --swift-build is required")
        payload_root, metadata = make_payload(args, inputs, work_dir)
        versioned_name = "%s-%s" % (args.product_identity, args.version)
        archive = output_dir / (versioned_name + ".tar.gz")
        create_deterministic_archive(payload_root, archive)
        if args.unsigned_dry_run:
            package = output_dir / (versioned_name + ".pkg.layout.tar.gz")
            create_deterministic_archive(payload_root, package)
        else:
            package = output_dir / (versioned_name + ".pkg")
            notary_result = package_with_apple_tools(args, payload_root, package)
        if args.unsigned_dry_run:
            notary_result = {"schemaVersion": 1, "mode": "unsigned-dry-run", "status": "Not Applicable"}
        licenses = output_dir / (versioned_name + ".licenses.tar.gz")
        write_license_bundle(args, inputs, payload_root, licenses)
        source_archive = output_dir / (versioned_name + ".source.tar.gz")
        create_source_archive(inputs["repo_root"], args.tag, source_archive, versioned_name + "/")
        manifest = output_dir / "model-manifest.json"
        write_atomic(manifest, inputs["manifest_bytes"])
        manifest_digest = output_dir / "model-manifest.sha256"
        write_atomic(manifest_digest, (sha256_file(manifest) + "  model-manifest.json\n").encode("ascii"))
        compatibility = output_dir / (versioned_name + ".compatibility.md")
        support = output_dir / (versioned_name + ".support.md")
        changelog = output_dir / (versioned_name + ".changelog.md")
        write_metadata_asset(inputs["compatibility"], compatibility)
        write_metadata_asset(inputs["support"], support)
        write_metadata_asset(inputs["changelog"], changelog)
        notary = output_dir / (versioned_name + ".notary.json")
        write_atomic(notary, json_bytes(notary_result))
        subject_artifacts = [archive, source_archive, package, licenses, manifest, manifest_digest, compatibility, support, changelog, notary]
        formula = output_dir / (metadata["formulaClass"] + ".rb")
        write_formula(args, metadata, archive.name, sha256_file(archive), formula)
        subject_artifacts.append(formula)
        sbom = output_dir / (versioned_name + ".spdx.json")
        write_spdx(args, inputs, payload_root, subject_artifacts, sbom)
        provenance = output_dir / (versioned_name + ".provenance.intoto.jsonl")
        write_provenance(args, inputs, subject_artifacts + [sbom], provenance)
        core_artifacts = subject_artifacts + [sbom, provenance]
        inventory = output_dir / "artifact-inventory.json"
        write_inventory(args, core_artifacts, inventory)
        checksums = output_dir / "SHA256SUMS"
        write_checksums(core_artifacts + [inventory], checksums)
        signature = output_dir / "SHA256SUMS.sig"
        write_signature(args, checksums, signature)
        verify_artifacts(args, output_dir, unsigned=args.unsigned_dry_run, approved_manifest_bytes=inputs["manifest_bytes"])
        print(json.dumps({"output": str(output_dir), "artifacts": [path.name for path in core_artifacts + [inventory, checksums, signature]], "unsignedDryRun": args.unsigned_dry_run}, sort_keys=True))
    finally:
        if staging_mount is not None:
            try:
                run_tool(["/usr/bin/hdiutil", "detach", "-force", str(staging_mount)])
            except ReleaseError:
                pass
        if staging_parent is not None:
            shutil.rmtree(staging_parent, ignore_errors=True)
        else:
            shutil.rmtree(work_dir, ignore_errors=True)


def sign_input_bundle(args: argparse.Namespace) -> None:
    """Sign the verified build input without resolving dependencies or rebuilding."""
    inputs = validate_release_inputs(args)
    output_dir = args.output_dir.absolute()
    if getattr(args, "build_handoff_state", None):
        trusted_snapshot_state = os.environ.get("RELEASE_BUILD_SNAPSHOT_STATE")
        if not trusted_snapshot_state:
            fail("sign input is missing the trusted snapshot state")
        verify_extracted_artifact_handoff(output_dir, Path(trusted_snapshot_state), args.tag, args.source_commit)
    verify_artifacts(args, output_dir, unsigned=True, approved_manifest_bytes=inputs["manifest_bytes"])
    unsigned_names = expected_asset_names(args, True) | OUTPUT_RESERVED_NAMES
    archive_name = "%s-%s.tar.gz" % (args.product_identity, args.version)
    sign_snapshot_dir: Optional[Path] = None
    sign_snapshot_state: Optional[Path] = None
    sign_source = output_dir
    if getattr(args, "build_handoff_state", None):
        trusted_snapshot_state = os.environ.get("RELEASE_BUILD_SNAPSHOT_STATE")
        if not trusted_snapshot_state:
            fail("sign input is missing the trusted snapshot state")
        sign_snapshot_dir = output_dir.parent / ("." + output_dir.name + ".sign-snapshot-" + uuid.uuid4().hex)
        sign_snapshot_state = sign_snapshot_dir.with_name(sign_snapshot_dir.name + ".json")
        sign_source = snapshot_verified_handoff(
            output_dir,
            Path(trusted_snapshot_state),
            args.tag,
            args.source_commit,
            sign_snapshot_dir,
            sign_snapshot_state,
        )
    archive = sign_source / archive_name
    staging_parent: Optional[Path] = None
    staging_mount: Optional[Path] = None
    if sys.platform == "darwin":
        staging_parent, staging_mount = create_clean_apfs_volume(output_dir.parent)
        work_dir = staging_mount / "release-sign-input"
        run_tool(["/bin/mkdir", "-p", str(work_dir)])
    else:
        work_dir = Path(tempfile.mkdtemp(prefix="release-sign-input-", dir=str(output_dir.parent)))
    try:
        payload_root = work_dir / "payload"
        clean_archive = work_dir / "release-input.tar.gz"
        copy_archive_to_clean_boundary(archive, clean_archive)
        extract_safe_archive(clean_archive, payload_root)
        executable = payload_root / "Library" / "Application Support" / args.product_identity / "versions" / args.version / args.executable
        require_regular(executable, "downloaded release executable")
        validate_payload_resource_bundle(payload_root, args, inputs["manifest_bytes"])
        dynamic_closure(executable, payload_root)
        before_payload_root = work_dir / "payload-before-sign"
        shutil.copytree(payload_root, before_payload_root)
        before_inventory = payload_file_inventory(before_payload_root)
        sign_and_verify_executable(args, executable)
        verify_signed_payload_inventory(before_payload_root, payload_root, before_inventory)
        for name in sorted(unsigned_names):
            path = output_dir / name
            if path.is_file() and not path.is_symlink():
                path.unlink()
        signed_archive = output_dir / archive_name
        create_deterministic_archive(payload_root, signed_archive)
        package = output_dir / ("%s-%s.pkg" % (args.product_identity, args.version))
        notary_result = package_with_apple_tools(args, payload_root, package)
        versioned_name = "%s-%s" % (args.product_identity, args.version)
        licenses = output_dir / (versioned_name + ".licenses.tar.gz")
        write_license_bundle(args, inputs, payload_root, licenses)
        source_archive = output_dir / (versioned_name + ".source.tar.gz")
        create_source_archive(inputs["repo_root"], args.tag, source_archive, versioned_name + "/")
        manifest = output_dir / "model-manifest.json"
        write_atomic(manifest, inputs["manifest_bytes"])
        manifest_digest = output_dir / "model-manifest.sha256"
        write_atomic(manifest_digest, (sha256_file(manifest) + "  model-manifest.json\n").encode("ascii"))
        compatibility = output_dir / (versioned_name + ".compatibility.md")
        support = output_dir / (versioned_name + ".support.md")
        changelog = output_dir / (versioned_name + ".changelog.md")
        for source, destination in ((inputs["compatibility"], compatibility), (inputs["support"], support), (inputs["changelog"], changelog)):
            write_metadata_asset(source, destination)
        notary = output_dir / (versioned_name + ".notary.json")
        write_atomic(notary, json_bytes(notary_result))
        metadata = make_release_metadata(args, inputs, sha256_file(manifest))
        subject_artifacts = [signed_archive, source_archive, package, licenses, manifest, manifest_digest, compatibility, support, changelog, notary]
        formula = output_dir / (formula_class_for(args) + ".rb")
        write_formula(args, metadata, signed_archive.name, sha256_file(signed_archive), formula)
        subject_artifacts.append(formula)
        sbom = output_dir / (versioned_name + ".spdx.json")
        write_spdx(args, inputs, payload_root, subject_artifacts, sbom)
        provenance = output_dir / (versioned_name + ".provenance.intoto.jsonl")
        write_provenance(args, inputs, subject_artifacts + [sbom], provenance)
        core_artifacts = subject_artifacts + [sbom, provenance]
        inventory = output_dir / "artifact-inventory.json"
        write_inventory(args, core_artifacts, inventory)
        checksums = output_dir / "SHA256SUMS"
        write_checksums(core_artifacts + [inventory], checksums)
        signature = output_dir / "SHA256SUMS.sig"
        write_signature(args, checksums, signature)
        verify_artifacts(args, output_dir, unsigned=False, approved_manifest_bytes=inputs["manifest_bytes"])
    finally:
        if staging_mount is not None:
            try:
                run_tool(["/usr/bin/hdiutil", "detach", "-force", str(staging_mount)])
            except ReleaseError:
                pass
        if staging_parent is not None:
            shutil.rmtree(staging_parent, ignore_errors=True)
        else:
            shutil.rmtree(work_dir, ignore_errors=True)
        if sign_snapshot_dir is not None:
            shutil.rmtree(sign_snapshot_dir, ignore_errors=True)
        if sign_snapshot_state is not None:
            sign_snapshot_state.unlink(missing_ok=True)


def parse_checksum_file(path: Path) -> Dict[str, str]:
    result: Dict[str, str] = {}
    for line in read_bounded_text(path, "SHA256SUMS", 4 * 1024 * 1024).splitlines():
        if not line.strip():
            continue
        match = re.fullmatch(r"([0-9a-f]{64})  (.+)", line)
        if not match:
            fail("invalid SHA256SUMS line")
        if match.group(2) in result:
            fail("SHA256SUMS contains a duplicate artifact name")
        result[match.group(2)] = match.group(1)
    return result


def read_inventory(path: Path) -> Dict[str, Any]:
    try:
        value = json.loads(read_bounded_text(path, "artifact inventory", 1024 * 1024))
    except (OSError, ValueError) as error:
        fail("artifact inventory is not valid JSON: %s" % error)
    if not isinstance(value, dict) or set(value) != {"schemaVersion", "productIdentity", "version", "tag", "sourceCommit", "artifacts", "excludesSelf"} or value.get("schemaVersion") != 1 or value.get("excludesSelf") is not True or not isinstance(value.get("artifacts"), list):
        fail("artifact inventory schema is invalid")
    for entry in value["artifacts"]:
        if not isinstance(entry, dict) or set(entry) != {"name", "size", "sha256"} or not isinstance(entry["name"], str) or not isinstance(entry["size"], int) or entry["size"] < 0 or not SHA256_RE.fullmatch(str(entry["sha256"])):
            fail("artifact inventory entry schema is invalid")
    return value


def validate_output_directory(output_dir: Path, expected_assets: Set[str]) -> None:
    if output_dir.is_symlink() or not output_dir.is_dir():
        fail("release output directory must be a real directory")
    expected_names = set(expected_assets) | OUTPUT_RESERVED_NAMES
    actual_entries = list(output_dir.iterdir())
    actual_names = {entry.name for entry in actual_entries}
    if actual_names != expected_names:
        missing = sorted(expected_names - actual_names)
        extra = sorted(actual_names - expected_names)
        fail("release output directory is not exact, missing=%s extra=%s" % (missing[:1], extra[:1]))
    for entry in actual_entries:
        if entry.is_symlink() or not entry.is_file():
            fail("release output contains a non-regular direct entry: %s" % entry.name)
        file_stat = entry.stat()
        if file_stat.st_nlink != 1:
            fail("release output contains a hard-link alias: %s" % entry.name)
        if stat.S_IMODE(file_stat.st_mode) & 0o022:
            fail("release output file is group or world writable: %s" % entry.name)


def file_identity(path: Path) -> Tuple[int, int, int, str]:
    identity, digest = sha256_file_pinned(path)
    return (identity[4], stat.S_IMODE(identity[2]), identity[3], digest)


def freeze_publication_assets(output_dir: Path, names: Set[str]) -> Dict[str, Tuple[int, int, int, str]]:
    validate_output_directory(output_dir, names - OUTPUT_RESERVED_NAMES)
    return {name: file_identity(output_dir / name) for name in sorted(names)}


def verify_frozen_publication_assets(output_dir: Path, frozen: Dict[str, Tuple[int, int, int, str]]) -> List[Path]:
    actual_names = {entry.name for entry in output_dir.iterdir()}
    if actual_names != set(frozen):
        fail("release output changed after verification")
    assets = []
    for name in sorted(frozen):
        path = output_dir / name
        if file_identity(path) != frozen[name]:
            fail("release asset changed after verification: %s" % name)
        assets.append(path)
    return assets


def open_publication_assets(output_dir: Path, names: Set[str]) -> Tuple[int, Tuple[int, int, int, int, int, int, int], List[Dict[str, Any]]]:
    """Open and pin every release asset before any publication transition."""

    directory_fd, directory_identity = open_directory_pinned(output_dir, "release output directory")
    assets: List[Dict[str, Any]] = []
    try:
        actual_names = set(os.listdir(directory_fd))
        expected_names = set(names)
        if actual_names != expected_names:
            fail("release output changed before publication")
        for name in sorted(expected_names):
            if not name or "/" in name or name in (".", ".."):
                fail("release asset name is unsafe")
            descriptor = os.open(name, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0), dir_fd=directory_fd)
            try:
                identity, digest = descriptor_hash(descriptor, "release publication asset", rewind=True)
                if not stat.S_ISREG(identity[2]) or identity[3] != 1 or stat.S_IMODE(identity[2]) & 0o022:
                    fail("release publication asset has an unsafe identity: %s" % name)
                verify_pinned_identity(output_dir / name, descriptor, identity, "release publication asset")
                assets.append({
                    "name": name,
                    "descriptor": descriptor,
                    "identity": identity,
                    "size": identity[4],
                    "mode": stat.S_IMODE(identity[2]),
                    "sha256": digest,
                })
                descriptor = -1
            finally:
                if descriptor >= 0:
                    os.close(descriptor)
        verify_directory_identity(output_dir, directory_fd, directory_identity, "release output directory")
        return directory_fd, directory_identity, assets
    except BaseException:
        for asset in assets:
            os.close(asset["descriptor"])
        os.close(directory_fd)
        raise


def verify_publication_assets(output_dir: Path, directory_fd: int, directory_identity: Tuple[int, int, int, int, int, int, int], assets: List[Dict[str, Any]]) -> None:
    """Recheck pinned identities and bytes immediately before an upload."""

    verify_directory_identity(output_dir, directory_fd, directory_identity, "release output directory")
    expected_names = {asset["name"] for asset in assets}
    if set(os.listdir(directory_fd)) != expected_names:
        fail("release output changed before publication")
    for asset in assets:
        descriptor = asset["descriptor"]
        identity, digest = descriptor_hash(descriptor, "release publication asset", rewind=True)
        if identity != asset["identity"] or digest != asset["sha256"]:
            fail("release publication asset changed: %s" % asset["name"])
        verify_pinned_identity(output_dir / asset["name"], descriptor, identity, "release publication asset")


def upload_release_asset_descriptor(repository: str, release_id: str, asset: Dict[str, Any], token: str) -> None:
    """Upload one already pinned descriptor without reopening its mutable pathname."""

    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository) or not re.fullmatch(r"[0-9]+", release_id):
        fail("release upload identity is invalid")
    path = "/repos/%s/releases/%s/assets?name=%s" % (repository, release_id, quote(asset["name"], safe=""))
    connection = http.client.HTTPSConnection("uploads.github.com", timeout=MAX_TOOL_SECONDS)
    descriptor = asset["descriptor"]
    try:
        connection.putrequest("POST", path, skip_accept_encoding=True)
        connection.putheader("Authorization", "Bearer " + token)
        connection.putheader("Accept", "application/vnd.github+json")
        connection.putheader("Content-Type", "application/octet-stream")
        connection.putheader("Content-Length", str(asset["size"]))
        connection.putheader("User-Agent", "trusted-native-release")
        connection.endheaders()
        os.lseek(descriptor, 0, os.SEEK_SET)
        remaining = asset["size"]
        while remaining:
            chunk = os.read(descriptor, min(1024 * 1024, remaining))
            if not chunk:
                fail("release publication asset ended before upload: %s" % asset["name"])
            connection.send(chunk)
            remaining -= len(chunk)
        response = connection.getresponse()
        body = response.read(MAX_TOOL_OUTPUT + 1)
        if len(body) > MAX_TOOL_OUTPUT or response.status not in (201,):
            fail("GitHub release asset upload failed")
        identity, digest = descriptor_hash(descriptor, "release publication asset", rewind=True)
        if identity != asset["identity"] or digest != asset["sha256"]:
            fail("release publication asset changed during upload: %s" % asset["name"])
    except (OSError, http.client.HTTPException):
        fail("could not upload the exact GitHub release asset")
    finally:
        connection.close()


def is_macho_file(path: Path) -> bool:
    try:
        with path.open("rb") as handle:
            magic = handle.read(4)
    except OSError:
        fail("could not inspect payload file: %s" % path)
    return magic in {b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca"}


def payload_file_inventory(root: Path) -> Dict[str, Tuple[int, int, str, bool]]:
    inventory: Dict[str, Tuple[int, int, str, bool]] = {}
    for path in ensure_safe_tree(root):
        relative = safe_relative(path.relative_to(root))
        identity, digest = sha256_file_pinned(path)
        inventory[relative] = (stat.S_IMODE(identity[2]), identity[4], digest, is_macho_file(path))
    return inventory


def verify_macho_signature_only_change(before: Path, after: Path, relative: str) -> None:
    temporary = Path(tempfile.mkdtemp(prefix="release-signature-compare-"))
    try:
        before_copy = temporary / "before"
        after_copy = temporary / "after"
        run_tool(["/bin/cp", "-X", str(before), str(before_copy)])
        run_tool(["/bin/cp", "-X", str(after), str(after_copy)])
        before_signature_error = None
        try:
            run_tool(["codesign", "--remove-signature", str(before_copy)])
        except ReleaseError as error:
            before_signature_error = str(error)
        if before_signature_error and "not signed" not in before_signature_error.lower() and "code object is not signed" not in before_signature_error.lower():
            fail("could not normalize the pre-sign Mach-O: %s" % relative)
        run_tool(["codesign", "--remove-signature", str(after_copy)])
        if sha256_file_pinned(before_copy)[1] != sha256_file_pinned(after_copy)[1]:
            fail("signed Mach-O changed outside its code signature: %s" % relative)
    finally:
        shutil.rmtree(temporary, ignore_errors=True)


def verify_signed_payload_inventory(before_root: Path, after_root: Path, before: Dict[str, Tuple[int, int, str, bool]]) -> None:
    after = payload_file_inventory(after_root)
    if set(after) != set(before):
        fail("signed payload file set changed")
    for relative in sorted(before):
        before_mode, before_size, before_digest, before_macho = before[relative]
        after_mode, after_size, after_digest, after_macho = after[relative]
        if before_mode != after_mode or before_macho != after_macho:
            fail("signed payload mode or file type changed: %s" % relative)
        if before_digest == after_digest:
            continue
        if not before_macho or not after_macho:
            fail("non-Mach-O payload bytes changed during signing: %s" % relative)
        before_path = before_root / relative
        after_path = after_root / relative
        verify_macho_signature_only_change(before_path, after_path, relative)
        if after_size < before_size:
            fail("signed Mach-O was truncated: %s" % relative)


def archive_alias_key(parts: Sequence[str]) -> Tuple[str, ...]:
    return tuple(unicodedata.normalize("NFC", part).casefold() for part in parts)


def validate_tar_member_name(
    raw_name: str,
    member_kind: str,
    seen: Dict[Tuple[str, ...], str],
    kinds: Dict[Tuple[str, ...], str],
    aliases: Optional[Dict[Tuple[str, ...], str]] = None,
) -> str:
    if not isinstance(raw_name, str) or not raw_name or "\x00" in raw_name or "\\" in raw_name:
        fail("archive contains an unsafe path")
    normalized_name = raw_name[:-1] if raw_name.endswith("/") else raw_name
    parts = normalized_name.split("/")
    if not normalized_name or normalized_name.startswith("/") or any(not part or part in (".", "..") for part in parts):
        fail("archive contains an unsafe path")
    aliases = aliases if aliases is not None else {}
    alias = archive_alias_key(parts)
    for index in range(1, len(alias)):
        parent = alias[:index]
        parent_name = "/".join(parts[:index])
        if parent in aliases and aliases[parent] != parent_name:
            fail("archive contains a duplicate or aliased path component")
        aliases.setdefault(parent, parent_name)
        if kinds.get(parent) == "file":
            fail("archive contains a file and directory path collision")
        kinds.setdefault(parent, "directory")
    alias_name = "/".join(parts)
    if alias in aliases and aliases[alias] != alias_name:
        fail("archive contains a duplicate or aliased path")
    aliases.setdefault(alias, alias_name)
    if alias in seen:
        fail("archive contains a duplicate or aliased path")
    existing_kind = kinds.get(alias)
    if existing_kind is not None and existing_kind != member_kind:
        fail("archive contains a file and directory path collision")
    seen[alias] = normalized_name
    kinds[alias] = member_kind
    return normalized_name


def verify_archive_names(
    path: Path,
    budget: Optional[Dict[str, int]] = None,
    extra_markers: Sequence[bytes] = (),
    scan_content: bool = False,
) -> List[str]:
    names: List[str] = []
    try:
        with tarfile.open(path, mode="r:gz") as tar:
            declared_total = 0
            seen: Dict[Tuple[str, ...], str] = {}
            kinds: Dict[Tuple[str, ...], str] = {}
            aliases: Dict[Tuple[str, ...], str] = {}
            for index, member in enumerate(tar, start=1):
                if index > MAX_ARCHIVE_MEMBERS:
                    fail("archive contains too many members")
                if member.size < 0 or member.size > MAX_ARCHIVE_MEMBER_BYTES:
                    fail("archive member declared size is outside the bound")
                declared_total += member.size
                if declared_total > MAX_ARCHIVE_DECLARED_BYTES:
                    fail("archive declared uncompressed size exceeds the bound")
                if member.issym() or member.islnk() or not member.isfile() and not member.isdir():
                    fail("archive contains an unsafe entry")
                normalized_name = validate_tar_member_name(member.name, "directory" if member.isdir() else "file", seen, kinds, aliases)
                if MODEL_BYTE_RE.search(normalized_name):
                    fail("archive contains model bytes")
                if member.isfile() and scan_content:
                    content = tar.extractfile(member)
                    if content is None:
                        fail("archive contains an unreadable file")
                    scan_stream(content, "%s:%s" % (path.name, member.name), budget or {"used": 0}, extra_markers)
                names.append(normalized_name)
    except (OSError, tarfile.TarError) as error:
        fail("could not inspect archive: %s" % error)
    return names


def validate_archive_structure(path: Path) -> List[str]:
    """Validate archive paths and types without scanning arbitrary source text."""

    return verify_archive_names(path, scan_content=False)


def archive_file_names(path: Path) -> Set[str]:
    try:
        with tarfile.open(path, mode="r:gz") as tar:
            names = set()
            declared_total = 0
            seen: Dict[Tuple[str, ...], str] = {}
            kinds: Dict[Tuple[str, ...], str] = {}
            aliases: Dict[Tuple[str, ...], str] = {}
            for index, member in enumerate(tar, start=1):
                if index > MAX_ARCHIVE_MEMBERS:
                    fail("archive contains too many members")
                if member.size < 0 or member.size > MAX_ARCHIVE_MEMBER_BYTES:
                    fail("archive member declared size is outside the bound")
                declared_total += member.size
                if declared_total > MAX_ARCHIVE_DECLARED_BYTES:
                    fail("archive declared uncompressed size exceeds the bound")
                if member.issym() or member.islnk() or not member.isfile() and not member.isdir():
                    fail("archive contains an unsafe entry")
                normalized_name = validate_tar_member_name(member.name, "directory" if member.isdir() else "file", seen, kinds, aliases)
                if MODEL_BYTE_RE.search(normalized_name):
                    fail("archive contains model bytes")
                if member.isfile():
                    names.add(normalized_name)
            return names
    except (OSError, tarfile.TarError) as error:
        fail("could not inspect archive files: %s" % error)


def verify_spdx(path: Path, args: argparse.Namespace, artifact_paths: Dict[str, Path]) -> None:
    try:
        document = json.loads(read_bounded_text(path, "SPDX SBOM", 8 * 1024 * 1024))
    except (OSError, ValueError) as error:
        fail("SBOM is not valid JSON: %s" % error)
    if not isinstance(document, dict) or set(document) != {"spdxVersion", "dataLicense", "SPDXID", "name", "documentNamespace", "creationInfo", "packages", "files", "relationships", "externalDocumentRefs", "comment"} or document.get("spdxVersion") != "SPDX-2.3" or document.get("SPDXID") != "SPDXRef-DOCUMENT":
        fail("SBOM is not SPDX 2.3")
    if not isinstance(document.get("packages"), list) or not isinstance(document.get("files"), list):
        fail("SBOM must contain locked packages and built payload files")
    if args.source_commit not in document.get("documentNamespace", ""):
        fail("SBOM namespace does not identify the source commit")
    comment = document.get("comment", "")
    prefix = "Release artifact subjects: "
    if not isinstance(comment, str) or not comment.startswith(prefix):
        fail("SBOM does not contain artifact subject digests")
    try:
        subjects = json.loads(comment[len(prefix):])
    except ValueError as error:
        fail("SBOM artifact subjects are not valid JSON: %s" % error)
    if not isinstance(subjects, list) or not subjects:
        fail("SBOM artifact subjects are empty")
    sbom_name = path.name
    provenance_name = next((name for name in artifact_paths if name.endswith(".provenance.intoto.jsonl")), None)
    expected_subject_names = set(artifact_paths) - OUTPUT_RESERVED_NAMES - {sbom_name, provenance_name}
    actual_subject_names = set()
    for subject in subjects:
        if not isinstance(subject, dict) or set(subject) != {"name", "sha256", "size"} or not isinstance(subject.get("name"), str) or not isinstance(subject.get("size"), int) or not SHA256_RE.fullmatch(str(subject.get("sha256", ""))):
            fail("SBOM contains an invalid artifact subject digest")
        name = subject["name"]
        if name not in expected_subject_names or name in actual_subject_names or subject["size"] != artifact_paths[name].stat().st_size or subject["sha256"] != sha256_file(artifact_paths[name]):
            fail("SBOM artifact subject digest does not match the artifact")
        actual_subject_names.add(name)
    if actual_subject_names != expected_subject_names:
        fail("SBOM does not cover every intended external artifact subject")

    archive = next((artifact_paths[name] for name in artifact_paths if name.endswith(".tar.gz") and not name.endswith(".licenses.tar.gz") and not name.endswith(".source.tar.gz") and not name.endswith(".pkg.layout.tar.gz")), None)
    if archive is None:
        fail("SBOM has no executable archive subject")
    contract = archive_payload_contract(archive)
    expected_payload_names = {"/" + name[2:] for name, kind in contract.items() if kind == "file"}
    payload_check_root = Path(tempfile.mkdtemp(prefix="release-sbom-payload-"))
    try:
        extract_safe_archive(archive, payload_check_root)
    except BaseException:
        shutil.rmtree(payload_check_root, ignore_errors=True)
        raise
    file_ids = set()
    actual_payload_names = set()
    for file_info in document["files"]:
        if not isinstance(file_info, dict) or set(file_info) != {"SPDXID", "fileName", "checksums", "licenseConcluded", "copyrightText"} or not isinstance(file_info.get("SPDXID"), str) or file_info["SPDXID"] in file_ids:
            fail("SBOM file entry schema or SPDX ID is invalid")
        file_ids.add(file_info["SPDXID"])
        name = file_info.get("fileName")
        checksums = file_info.get("checksums")
        if name not in expected_payload_names or name in actual_payload_names or not isinstance(checksums, list) or len(checksums) != 1 or checksums[0].get("algorithm") != "SHA256" or not SHA256_RE.fullmatch(str(checksums[0].get("checksumValue", ""))):
            fail("SBOM payload file coverage is incomplete or malformed")
        actual_payload_names.add(name)
        payload_file = payload_check_root / name.lstrip("/")
        if not payload_file.is_file() or sha256_file(payload_file) != checksums[0]["checksumValue"]:
            shutil.rmtree(payload_check_root, ignore_errors=True)
            fail("SBOM payload file digest does not match the executable archive")
    if actual_payload_names != expected_payload_names:
        shutil.rmtree(payload_check_root, ignore_errors=True)
        fail("SBOM does not cover every payload file")
    shutil.rmtree(payload_check_root, ignore_errors=True)

    try:
        resolved = json.loads(read_bounded_text(args.repo_root.resolve() / "Package.resolved", "Package.resolved", 4 * 1024 * 1024))
    except (OSError, ValueError) as error:
        fail("Package.resolved is not valid while verifying SBOM: %s" % error)
    pins = sorted(resolved.get("pins", []), key=lambda item: item["identity"])
    if len(document["packages"]) != len(pins):
        fail("SBOM does not cover every locked dependency")
    package_ids = set()
    for package_info, pin in zip(document["packages"], pins):
        if not isinstance(package_info, dict) or set(package_info) != {"SPDXID", "name", "versionInfo", "downloadLocation", "filesAnalyzed", "licenseConcluded", "licenseDeclared", "copyrightText", "externalRefs"}:
            fail("SBOM package entry schema is invalid")
        state = pin.get("state", {})
        revision = state.get("revision")
        if package_info["SPDXID"] in package_ids or package_info["name"] != pin.get("identity") or package_info["versionInfo"] != (state.get("version") or revision) or package_info["downloadLocation"] != pin.get("location") + "#" + revision or package_info["externalRefs"] != [{"referenceCategory": "OTHER", "referenceType": "git-commit", "referenceLocator": revision}]:
            fail("SBOM locked dependency does not match Package.resolved")
        package_ids.add(package_info["SPDXID"])
    relationship_set = {(item.get("spdxElementId"), item.get("relationshipType"), item.get("relatedSpdxElement")) for item in document.get("relationships", []) if isinstance(item, dict)}
    expected_relationships = {("SPDXRef-DOCUMENT", "DESCRIBES", package_id) for package_id in package_ids} | {("SPDXRef-DOCUMENT", "CONTAINS", file_id) for file_id in file_ids}
    if relationship_set != expected_relationships or len(document["relationships"]) != len(expected_relationships):
        fail("SBOM relationships are incomplete or contain duplicates")


def verify_provenance(path: Path, artifact_paths: Dict[str, Path], args: argparse.Namespace) -> None:
    lines = read_bounded_text(path, "SLSA provenance", 4 * 1024 * 1024).splitlines()
    if len(lines) != 1:
        fail("provenance must be one bounded in-toto statement")
    try:
        statement = json.loads(lines[0])
    except ValueError as error:
        fail("provenance is not valid JSON: %s" % error)
    if not isinstance(statement, dict) or statement.get("predicateType") != "https://slsa.dev/provenance/v1":
        fail("provenance is not SLSA v1 compatible")
    external = statement.get("predicate", {}).get("buildDefinition", {}).get("externalParameters", {})
    if external.get("tag") != args.tag or external.get("sourceCommit") != args.source_commit:
        fail("provenance source identity does not match release inputs")
    subjects = statement.get("subject", [])
    if not isinstance(subjects, list) or not subjects:
        fail("provenance has no subjects")
    subject_names = set()
    for subject in subjects:
        if not isinstance(subject, dict) or set(subject) != {"name", "digest"} or not isinstance(subject.get("digest"), dict) or set(subject["digest"]) != {"sha256"}:
            fail("provenance subject schema is invalid")
        name = subject.get("name")
        digest = subject.get("digest", {}).get("sha256")
        if name not in artifact_paths or name in subject_names or digest != sha256_file(artifact_paths[name]):
            fail("provenance subject digest does not match the artifact")
        subject_names.add(name)
    expected = set(artifact_paths) - {"artifact-inventory.json", "SHA256SUMS", "SHA256SUMS.sig"}
    provenance_name = next((name for name in expected if name.endswith(".provenance.intoto.jsonl")), None)
    if provenance_name:
        expected.remove(provenance_name)
    if subject_names != expected:
        fail("provenance does not cover every primary immutable artifact")


def copy_archive_to_clean_boundary(source: Path, destination: Path) -> None:
    """Copy archive bytes into a trusted clean boundary without inheriting host metadata."""

    source_descriptor, source_identity = open_pinned_regular(source, "release archive")
    if destination.exists() or destination.is_symlink():
        os.close(source_descriptor)
        fail("clean archive destination already exists")
    parent_descriptor, parent_identity = open_directory_pinned(destination.parent, "clean archive output directory")
    try:
        source_identity, source_digest = descriptor_hash(source_descriptor, "release archive", rewind=True)
        destination_descriptor = os.open(
            destination.name,
            os.O_RDWR | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0),
            0o600,
            dir_fd=parent_descriptor,
        )
        try:
            provenance_removed = False
            os.lseek(source_descriptor, 0, os.SEEK_SET)
            remaining = source_identity[4]
            while remaining:
                chunk = os.read(source_descriptor, min(1024 * 1024, remaining))
                if not chunk:
                    fail("release archive ended during clean copy")
                offset = 0
                while offset < len(chunk):
                    offset += os.write(destination_descriptor, chunk[offset:])
                remaining -= len(chunk)
            os.fsync(destination_descriptor)
            os.fchmod(destination_descriptor, 0o644)
            destination_identity, destination_digest = descriptor_hash(destination_descriptor, "clean archive", rewind=True)
            if destination_identity[4] != source_identity[4] or destination_digest != source_digest:
                fail("clean archive bytes or size changed")
            names = flistxattr_descriptor_names(destination_descriptor, "clean archive")
            if names:
                if names != {"com.apple.provenance"}:
                    fail("clean archive retained unexpected extended metadata")
                libc = ctypes.CDLL(None, use_errno=True)
                libc.fremovexattr.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int]
                libc.fremovexattr.restype = ctypes.c_int
                if libc.fremovexattr(destination_descriptor, b"com.apple.provenance", 0) != 0:
                    fail("clean archive provenance metadata could not be removed")
                if flistxattr_descriptor_names(destination_descriptor, "clean archive post-removal"):
                    fail("clean archive retained metadata after provenance removal")
                provenance_removed = True
            final_identity, final_digest = descriptor_hash(destination_descriptor, "clean archive", rewind=True, allow_ctime_change=provenance_removed)
            if final_identity[4] != source_identity[4] or stat.S_IMODE(final_identity[2]) != 0o644 or final_digest != source_digest:
                fail("clean archive changed during metadata handling")
            verify_pinned_identity(destination, destination_descriptor, final_identity, "clean archive", allow_ctime_change=provenance_removed)
        finally:
            os.close(destination_descriptor)
        verify_pinned_identity(source, source_descriptor, source_identity, "release archive")
        verify_directory_identity(destination.parent, parent_descriptor, parent_identity, "clean archive output directory")
    finally:
        os.close(parent_descriptor)
        os.close(source_descriptor)


def verify_archive_resource_manifest(
    archive: Path,
    args: argparse.Namespace,
    approved_manifest: bytes,
    required: bool = False,
) -> None:
    """Verify the shipped resource manifest from the bounded archive stream."""

    expected = PurePosixPath("Library") / "Application Support" / args.product_identity / "versions" / args.version / SWIFT_RESOURCE_BUNDLE_NAME / SWIFT_RESOURCE_MANIFEST_NAME
    found = False
    bundle_found = False
    try:
        with tarfile.open(archive, mode="r:gz") as tar:
            declared_total = 0
            seen: Dict[Tuple[str, ...], str] = {}
            kinds: Dict[Tuple[str, ...], str] = {}
            aliases: Dict[Tuple[str, ...], str] = {}
            for index, member in enumerate(tar, start=1):
                if index > MAX_ARCHIVE_MEMBERS:
                    fail("archive contains too many members")
                if member.size < 0 or member.size > MAX_ARCHIVE_MEMBER_BYTES:
                    fail("archive member declared size is outside the bound")
                declared_total += member.size
                if declared_total > MAX_ARCHIVE_DECLARED_BYTES:
                    fail("archive declared uncompressed size exceeds the bound")
                if member.issym() or member.islnk() or not member.isfile() and not member.isdir():
                    fail("archive resource bundle contains an unsafe entry")
                name = PurePosixPath(validate_tar_member_name(member.name, "directory" if member.isdir() else "file", seen, kinds, aliases))
                if expected.parent == name or expected.parent in name.parents:
                    bundle_found = True
                    if member.isfile() and name != expected:
                        fail("archive resource bundle contains an unexpected regular file")
                if name == expected:
                    if not member.isfile() or found:
                        fail("archive resource manifest is not a unique regular file")
                    stream = tar.extractfile(member)
                    if stream is None:
                        fail("archive resource manifest is unreadable")
                    data = bytearray()
                    while True:
                        chunk = stream.read(1024 * 1024)
                        if not chunk:
                            break
                        data.extend(chunk)
                        if len(data) > 2 * 1024 * 1024:
                            fail("archive resource manifest is too large")
                    if bytes(data) != approved_manifest:
                        fail("archive resource manifest differs from the approved manifest")
                    found = True
                elif expected in name.parents and not (member.isfile() or member.isdir()):
                    fail("archive resource bundle contains an unsafe entry")
    except (OSError, tarfile.TarError) as error:
        fail("could not inspect archive resource manifest: %s" % error)
    if required and not found:
        fail("archive resource manifest is missing")
    if bundle_found and not found:
        fail("archive resource bundle manifest is missing")


def extract_safe_archive(path: Path, destination: Path, budget: Optional[Dict[str, int]] = None, extra_markers: Sequence[bytes] = ()) -> None:
    try:
        with tarfile.open(path, mode="r:gz") as tar:
            declared_total = 0
            seen: Dict[Tuple[str, ...], str] = {}
            kinds: Dict[Tuple[str, ...], str] = {}
            aliases: Dict[Tuple[str, ...], str] = {}
            validated_members: List[Tuple[tarfile.TarInfo, PurePosixPath]] = []
            for index, member in enumerate(tar, start=1):
                if index > MAX_ARCHIVE_MEMBERS:
                    fail("archive contains too many members")
                if member.size < 0 or member.size > MAX_ARCHIVE_MEMBER_BYTES:
                    fail("archive member declared size is outside the bound")
                declared_total += member.size
                if declared_total > MAX_ARCHIVE_DECLARED_BYTES:
                    fail("archive declared uncompressed size exceeds the bound")
                if member.issym() or member.islnk() or not member.isfile() and not member.isdir():
                    fail("archive contains an unsafe entry")
                normalized_name = validate_tar_member_name(member.name, "directory" if member.isdir() else "file", seen, kinds, aliases)
                name = PurePosixPath(normalized_name)
                if MODEL_BYTE_RE.search(name.as_posix()):
                    fail("archive contains model bytes")
                validated_members.append((member, name))
            scan_budget = budget if budget is not None else {"used": 0}
            for member, name in validated_members:
                target = destination.joinpath(*name.parts)
                if member.isdir():
                    target.mkdir(parents=True, exist_ok=True)
                    continue
                target.parent.mkdir(parents=True, exist_ok=True)
                data = tar.extractfile(member)
                if data is None:
                    fail("archive contains an unreadable file")
                temporary = target.with_name("." + target.name + ".extracting")
                with temporary.open("wb") as handle:
                    scan_stream(data, "%s:%s" % (path.name, member.name), scan_budget, extra_markers, writer=handle)
                    handle.flush()
                    os.fsync(handle.fileno())
                os.chmod(temporary, stat.S_IMODE(member.mode) & 0o777)
                os.replace(temporary, target)
    except (OSError, tarfile.TarError) as error:
        fail("could not extract archive: %s" % error)


def verify_source_archive(path: Path, args: argparse.Namespace) -> None:
    temporary = Path(tempfile.mkdtemp(prefix="release-source-verify-"))
    try:
        expected = temporary / path.name
        create_source_archive(args.repo_root.resolve(), args.tag, expected, "%s-%s/" % (args.product_identity, args.version))
        if sha256_file(expected) != sha256_file(path):
            fail("source archive does not match the exact annotated tag")
        validate_archive_structure(path)
    finally:
        shutil.rmtree(temporary, ignore_errors=True)


def verify_signed_apple_assets(args: argparse.Namespace, output_dir: Path, artifact_paths: Dict[str, Path]) -> None:
    if not args.signature_public_key:
        fail("signed verification requires the detached-signature public key")
    public_key = require_regular(Path(args.signature_public_key), "detached-signature public key")
    checksums = output_dir / "SHA256SUMS"
    signature = output_dir / "SHA256SUMS.sig"
    run_tool(["openssl", "dgst", "-sha256", "-verify", str(public_key), "-signature", str(signature), str(checksums)])
    notary_path = next((path for name, path in artifact_paths.items() if name.endswith(".notary.json")), None)
    if notary_path is None:
        fail("signed release is missing the notary result asset")
    parse_notary_result(read_bounded_text(notary_path, "notary result", 1024 * 1024))
    package = next((path for name, path in artifact_paths.items() if name.endswith(".pkg")), None)
    archive = next((path for name, path in artifact_paths.items() if name.endswith(".tar.gz") and not name.endswith(".licenses.tar.gz") and not name.endswith(".source.tar.gz") and not name.endswith(".pkg.layout.tar.gz")), None)
    if package is None or archive is None:
        fail("signed release is missing the installer package or executable archive")
    _, signature_output, signature_errors = run_tool(["pkgutil", "--check-signature", str(package)])
    validate_package_signature(signature_output + signature_errors, args)
    _, payload_output, payload_errors = run_tool(["pkgutil", "--payload-files", str(package)])
    validate_payload_listing(payload_output + payload_errors, archive_payload_contract(archive))
    run_tool(["xcrun", "stapler", "validate", "-v", str(package)])
    quarantined = Path(tempfile.mkdtemp(prefix="release-verify-quarantine-")) / package.name
    extracted = Path(tempfile.mkdtemp(prefix="release-verify-payload-"))
    try:
        shutil.copy2(package, quarantined)
        run_tool(["xattr", "-w", "com.apple.quarantine", "0081;00000000;release;release", str(quarantined)])
        run_tool(["spctl", "--assess", "--type", "install", "--context", "0", "--verbose", str(quarantined)])
        extract_safe_archive(archive, extracted)
        verify_expanded_package(package, extracted, args.executable)
        executable = extracted / "Library" / "Application Support" / args.product_identity / "versions" / args.version / args.executable
        require_regular(executable, "archived executable")
        verify_signed_closure(args, executable, extracted)
    finally:
        shutil.rmtree(quarantined.parent, ignore_errors=True)
        shutil.rmtree(extracted, ignore_errors=True)


def verify_artifacts(
    args: argparse.Namespace,
    output_dir: Path,
    unsigned: bool,
    approved_manifest_bytes: bytes,
) -> None:
    inventory = read_inventory(output_dir / "artifact-inventory.json")
    if (
        inventory.get("productIdentity") != args.product_identity
        or inventory.get("version") != args.version
        or inventory.get("sourceCommit") != args.source_commit
        or inventory.get("tag") != args.tag
    ):
        fail("artifact inventory source identity does not match release inputs")
    expected_names = expected_asset_names(args, unsigned)
    listed = inventory["artifacts"]
    listed_names = {entry["name"] for entry in listed}
    if listed_names != expected_names:
        fail("artifact inventory does not contain the exact expected V5 asset set")
    approved_manifest_path = output_dir / "model-manifest.json"
    artifact_manifest_bytes = read_bounded_bytes(approved_manifest_path, "release model manifest", 2 * 1024 * 1024)
    if artifact_manifest_bytes != approved_manifest_bytes:
        fail("release model manifest does not match the approved tracked manifest")
    validate_output_directory(output_dir, expected_names)
    artifact_paths: Dict[str, Path] = {}
    scan_budget = {"used": 0}
    for entry in listed:
        name = entry.get("name")
        if not isinstance(name, str) or name not in expected_names or Path(name).name != name or name.startswith(".") or name in OUTPUT_RESERVED_NAMES:
            fail("artifact inventory contains an unsafe name")
        if name in artifact_paths:
            fail("artifact inventory contains a duplicate name")
        path = output_dir / name
        require_regular(path, "inventory artifact")
        if entry.get("size") != path.stat().st_size or entry.get("sha256") != sha256_file(path):
            fail("artifact inventory digest or size mismatch: %s" % name)
        artifact_paths[name] = path
        if not name.endswith(".source.tar.gz"):
            scan_file_stream(path, "release artifact " + name, scan_budget, (str(output_dir).encode("utf-8"),))
    checksums = output_dir / "SHA256SUMS"
    checksum_values = parse_checksum_file(checksums)
    if set(checksum_values) != set(artifact_paths) | {"artifact-inventory.json"}:
        fail("SHA256SUMS does not cover exactly the immutable artifacts and inventory")
    for name, digest in checksum_values.items():
        path = output_dir / name
        if name == "artifact-inventory.json":
            path = output_dir / name
        if sha256_file(path) != digest:
            fail("SHA256SUMS digest mismatch: %s" % name)
    signature = output_dir / "SHA256SUMS.sig"
    require_regular(signature, "detached signature")
    if unsigned:
        try:
            marker = json.loads(read_bounded_text(signature, "unsigned signature marker", 1024 * 1024))
        except ValueError as error:
            fail("unsigned dry-run signature marker is invalid: %s" % error)
        if marker.get("mode") != "unsigned-dry-run" or marker.get("digest") != sha256_file(checksums):
            fail("unsigned dry-run signature marker does not match checksums")
    else:
        if not args.signature_public_key:
            fail("signed verification requires the detached-signature public key")
        run_tool(["openssl", "dgst", "-sha256", "-verify", str(require_regular(Path(args.signature_public_key), "detached-signature public key")), "-signature", str(signature), str(checksums)])
    archive_names = []
    for name, path in artifact_paths.items():
        if name.endswith(".tar.gz") and not name.endswith(".source.tar.gz"):
            archive_names.extend(verify_archive_names(path, scan_budget, (str(output_dir).encode("utf-8"),), scan_content=True))
    if not archive_names:
        fail("release inventory has no archive")
    source_archive = next((path for name, path in artifact_paths.items() if name.endswith(".source.tar.gz")), None)
    if source_archive is None:
        fail("release inventory has no exact-tag source archive")
    verify_source_archive(source_archive, args)
    for suffix, source in ((".compatibility.md", args.compatibility), (".support.md", args.support), (".changelog.md", args.changelog)):
        metadata_path = next((path for name, path in artifact_paths.items() if name.endswith(suffix)), None)
        if metadata_path is None or read_bounded_bytes(metadata_path, "release metadata " + suffix, 16 * 1024 * 1024) != read_bounded_bytes(tracked_source_file(args.repo_root.resolve(), source, suffix), "tagged metadata " + suffix, 16 * 1024 * 1024):
            fail("release metadata asset does not match the tagged source: %s" % suffix)
    verify_spdx(next(path for name, path in artifact_paths.items() if name.endswith(".spdx.json")), args, artifact_paths)
    verify_provenance(next(path for name, path in artifact_paths.items() if name.endswith(".provenance.intoto.jsonl")), artifact_paths, args)
    manifest_path = artifact_paths.get("model-manifest.json")
    manifest_digest_path = artifact_paths.get("model-manifest.sha256")
    if not manifest_path or not manifest_digest_path:
        fail("manifest and manifest digest are required artifacts")
    expected_digest = sha256_file(manifest_path)
    if read_bounded_text(manifest_digest_path, "model manifest digest", 1024) != expected_digest + "  model-manifest.json\n":
        fail("manifest digest does not match manifest")
    try:
        manifest_bytes = artifact_manifest_bytes
        validate_manifest(json.loads(manifest_bytes))
    except (OSError, ValueError) as error:
        fail("release model manifest is not valid JSON: %s" % error)
    formula_path = next((path for name, path in artifact_paths.items() if name.endswith(".rb")), None)
    archive_name = next((name for name in artifact_paths if name.endswith(".tar.gz") and not name.endswith(".licenses.tar.gz") and not name.endswith(".source.tar.gz") and not name.endswith(".pkg.layout.tar.gz")), None)
    formula_text = read_bounded_text(formula_path, "Homebrew formula", 1024 * 1024) if formula_path else ""
    if formula_path is None:
        fail("Homebrew formula is missing")
    if not archive_name or archive_name not in formula_text:
        fail("Homebrew formula does not point to the signed archive: %s" % archive_name)
    if ('sha256 "%s"' % sha256_file(artifact_paths[archive_name])) not in formula_text:
        fail("Homebrew formula archive digest does not match")
    if args.tag not in formula_text:
        fail("Homebrew formula does not point to the exact release tag")
    if "libexec.install" not in formula_text or "/usr/sbin/installer" in formula_text or "models install --activate" not in formula_text:
        fail("Homebrew formula has an unsafe install contract")
    if not any("licenses/" in name for name in archive_names):
        fail("archive does not contain license and notice paths")
    verify_archive_resource_bundle(artifact_paths[archive_name], args, manifest_bytes)
    license_archive = next((path for name, path in artifact_paths.items() if name.endswith(".licenses.tar.gz")), None)
    if license_archive is None:
        fail("license bundle is missing")
    expected_license_names = {"licenses/" + name.split("/licenses/", 1)[1] for name in archive_names if "/licenses/" in name and not name.startswith("./")}
    if archive_file_names(license_archive) != expected_license_names:
        fail("license bundle does not exactly match the packaged license and notice files")
    if not unsigned:
        verify_signed_apple_assets(args, output_dir, artifact_paths)


def validate_workflow(path: Path) -> None:
    text = path.read_text(encoding="utf-8")
    uses = re.findall(r"(?m)^\s*-?\s*uses:\s*([^\s#]+)", text)
    if not uses:
        fail("workflow has no actions")
    for value in uses:
        if not re.fullmatch(r"[^@\s]+@[0-9a-f]{40}", value):
            fail("workflow action is not pinned to a full commit SHA: %s" % value)
    if "actions/attest-build-provenance@c074443f1aee8d4aeeae555aebba3282517141b2" not in uses:
        fail("workflow must pin attest-build-provenance to the reviewed commit")
    if "runs-on: macos-26" not in text:
        fail("workflow must use the reviewed macos-26 Apple Silicon label")
    if "uname -m" not in text or "arm64" not in text:
        fail("workflow must enforce arm64")
    forbidden_dispatch_source = "RELEASE_SOURCE_COMMIT: ${{ github." + "sha }}"
    if "resolve-source" not in text or forbidden_dispatch_source in text:
        fail("workflow must resolve source identity after the requested tag checkout")
    if "prepare-signing" not in text:
        fail("workflow must prepare protected temporary signing material")
    if text.count("cleanup-signing") < 2 or text.count("if: ${{ always() }}") < 2:
        fail("workflow must always clean signing and verification material")
    if "prepare-verification" not in text or "Reverify downloaded release bundle" not in text:
        fail("publish job must reverify downloaded release assets")
    if "subject-path: ${{ env.RELEASE_OUTPUT_DIR }}/*" not in text:
        fail("attestation must cover every release asset")
    if re.search(r"(?m)^\s*permissions:\s*(?:write-all|\{\s*contents:\s*write)", text):
        fail("workflow grants broad or global write permission")
    if "environment: release" not in text:
        fail("signing job must be release-environment gated")
    def job_block(name: str) -> str:
        match = re.search(r"(?ms)^  %s:\n.*?(?=^  [A-Za-z0-9_-]+:\n|\Z)" % re.escape(name), text)
        if not match:
            fail("workflow is missing job: %s" % name)
        return match.group(0)
    build_block = job_block("build-verify")
    signing_block = job_block("sign-notarize")
    publish_block = job_block("publish")
    signing_job_env = signing_block.split("    steps:", 1)[0]
    forbidden_build_secrets = (
        "RELEASE_APPLICATION_CERTIFICATE_BASE64", "RELEASE_INSTALLER_CERTIFICATE_BASE64",
        "RELEASE_APPLICATION_CERTIFICATE_PASSWORD", "RELEASE_INSTALLER_CERTIFICATE_PASSWORD",
        "RELEASE_NOTARY_CREDENTIALS_BASE64", "RELEASE_SIGNATURE_PRIVATE_KEY_BASE64",
        "RELEASE_SIGNATURE_PUBLIC_KEY_BASE64", "RELEASE_SIGNING_KEYCHAIN", "RELEASE_SIGNING_STATE",
        "GH_TOKEN",
    )
    if any(secret_name in build_block for secret_name in forbidden_build_secrets):
        fail("unprivileged build job receives signing, notary, or publication secrets")
    if "RELEASE_NOTARY_PROFILE" in signing_job_env or "RELEASE_NOTARY_PROFILE" in build_block.split("    steps:", 1)[0]:
        fail("notary profile must not enter a job-wide environment")
    if signing_block.count("RELEASE_NOTARY_PROFILE: ${{ vars.RELEASE_NOTARY_PROFILE }}") < 3:
        fail("notary profile must be scoped to preparation, signing, and cleanup steps")
    if "--swift-build --unsigned-dry-run" not in build_block or "swift test --disable-sandbox" not in build_block or "clean-source-audit.sh" not in build_block:
        fail("build job must sanitize and hand off an unsigned Swift build input")
    if "artifact-id: ${{ steps.upload-build.outputs.artifact-id }}" not in build_block or "artifact-digest: ${{ steps.upload-build.outputs.artifact-digest }}" not in build_block:
        fail("build job must export the immutable artifact handoff identity")
    if "RELEASE_BUILD_ARTIFACT_ID" not in signing_block or "RELEASE_BUILD_ARTIFACT_DIGEST" not in signing_block or "RELEASE_BUILD_ARCHIVE" not in signing_block or "RELEASE_BUILD_HANDOFF_STATE" not in signing_block:
        fail("signing job must consume the exact build artifact handoff")
    if "actions/download-artifact" in signing_block:
        fail("signing job must fetch and hash the exact artifact archive itself")
    if "verify-artifact-handoff" not in signing_block or "GITHUB_TOKEN: ${{ github.token }}" not in signing_block:
        fail("signing job must verify the GitHub artifact ID and digest through the scoped token")
    if signing_block.index("verify-artifact-handoff") > signing_block.index("Prepare temporary signing keychain"):
        fail("artifact handoff digest must be verified before signing secrets are prepared")
    if "actions: read" not in signing_block:
        fail("signing job must have only read access to the artifact API")
    if "sign-input" not in signing_block or "sign-input --swift-build" in signing_block or "swift package resolve" in signing_block or "swift test" in signing_block or "swift build" in signing_block:
        fail("signing job must sign the downloaded input without rebuilding or testing")
    if "environment: release" not in signing_block or "environment: release-publish" not in publish_block:
        fail("privileged jobs must be separately environment gated")
    if "needs: sign-notarize" not in publish_block:
        fail("publish must require the signed and notarized job")
    if "GH_TOKEN:" in text and text.count("GH_TOKEN:") != 1:
        fail("GH_TOKEN must enter only the publication step")
    if "secrets.RELEASE_NOTARY_PROFILE" in signing_block:
        fail("notary profile must not be exposed as a signing-job secret")
    if "Reverify downloaded release bundle before attestation or publish" not in publish_block or publish_block.index("Reverify downloaded release bundle before attestation or publish") > publish_block.index("Publish frozen verified assets"):
        fail("publish must reverify before attestation and frozen publication")
    if "freeze_publication_assets" not in Path(__file__).read_text(encoding="utf-8"):
        fail("publish must freeze asset identities before gh")
    publish_block = text.split("publish:", 1)[1] if "publish:" in text else ""
    if "contents: write" not in publish_block or "attestations: write" not in publish_block:
        fail("publish job must hold the narrow publication permissions")
    if "contents: write" in text.split("publish:", 1)[0]:
        fail("build and verify jobs must not have contents write permission")
    if "set -x" in text or "echo ${{ secrets" in text:
        fail("workflow may expose secrets")
    print(json.dumps({"workflow": str(path), "pinnedActions": len(uses), "runner": "macos-26", "architecture": "arm64"}, sort_keys=True))


def publish_release(args: argparse.Namespace) -> None:
    if not args.tag or not TAG_RE.fullmatch(args.tag):
        fail("publish requires an exact semantic version tag")
    if not args.repository or not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", args.repository):
        fail("publish requires a repository in owner/name form")
    if args.repository_url != "https://github.com/" + args.repository:
        fail("publish repository does not match the declared repository URL")
    inputs = validate_release_inputs(args, require_notary_profile=False)
    output_dir = args.output_dir.absolute()
    verify_artifacts(args, output_dir, unsigned=False, approved_manifest_bytes=inputs["manifest_bytes"])
    inventory = read_inventory(output_dir / "artifact-inventory.json")
    if inventory.get("tag") != args.tag:
        fail("publication tag does not match the artifact inventory")
    expected_names = expected_asset_names(args, False) | OUTPUT_RESERVED_NAMES
    frozen = freeze_publication_assets(output_dir, expected_names)
    directory_fd, directory_identity, assets = open_publication_assets(output_dir, expected_names)
    for asset in assets:
        expected = frozen.get(asset["name"])
        actual = (asset["size"], asset["mode"], asset["identity"][3], asset["sha256"])
        if expected != actual:
            for opened in assets:
                os.close(opened["descriptor"])
            os.close(directory_fd)
            fail("publication asset changed between freeze and descriptor pin: %s" % asset["name"])
    gh_token = os.environ.get("GH_TOKEN")
    if not gh_token:
        for asset in assets:
            os.close(asset["descriptor"])
        os.close(directory_fd)
        fail("publication requires GH_TOKEN only at the gh invocation")
    SECRET_VALUES.add(gh_token)
    try:
        verify_publication_assets(output_dir, directory_fd, directory_identity, assets)
        run_tool(
            [
                "gh", "release", "create", args.tag, "--repo", args.repository,
                "--verify-tag", "--title", args.tag,
                "--notes", "Trusted native release assets. See the packaged changelog and provenance metadata.",
            ],
            cwd=output_dir,
            env={"GH_TOKEN": gh_token},
        )
        _, release_id_output, release_id_errors = run_tool(
            ["gh", "api", "--header", "Accept: application/vnd.github+json", "repos/%s/releases/tags/%s" % (args.repository, args.tag), "--jq", ".id"],
            cwd=output_dir,
            env={"GH_TOKEN": gh_token},
        )
        release_id = (release_id_output or release_id_errors).strip()
        if not re.fullmatch(r"[0-9]+", release_id):
            fail("GitHub release ID is invalid")
        for asset in assets:
            verify_publication_assets(output_dir, directory_fd, directory_identity, assets)
            upload_release_asset_descriptor(args.repository, release_id, asset, gh_token)
    finally:
        SECRET_VALUES.discard(gh_token)
        for asset in assets:
            os.close(asset["descriptor"])
        os.close(directory_fd)
    print(json.dumps({"published": args.tag, "assetCount": len(assets)}, sort_keys=True))


def add_env_argument(parser: argparse.ArgumentParser, name: str, env_name: str, required: bool = True) -> None:
    parser.add_argument(name, default=os.environ.get(env_name), required=False, help="release input, or " + env_name)


def add_common_arguments(parser: argparse.ArgumentParser) -> None:
    add_env_argument(parser, "--product-identity", "RELEASE_PRODUCT_IDENTITY")
    add_env_argument(parser, "--executable", "RELEASE_EXECUTABLE")
    add_env_argument(parser, "--package-id", "RELEASE_PACKAGE_ID")
    add_env_argument(parser, "--service-label", "RELEASE_SERVICE_LABEL")
    add_env_argument(parser, "--version", "RELEASE_VERSION")
    add_env_argument(parser, "--tag", "RELEASE_TAG")
    add_env_argument(parser, "--source-commit", "RELEASE_SOURCE_COMMIT")
    add_env_argument(parser, "--application-identity", "RELEASE_APPLICATION_IDENTITY")
    add_env_argument(parser, "--installer-identity", "RELEASE_INSTALLER_IDENTITY")
    add_env_argument(parser, "--team-id", "RELEASE_TEAM_ID")
    add_env_argument(parser, "--notary-profile", "RELEASE_NOTARY_PROFILE")
    add_env_argument(parser, "--owner", "RELEASE_OWNER")
    add_env_argument(parser, "--security-contact", "RELEASE_SECURITY_CONTACT")
    add_env_argument(parser, "--repository-url", "RELEASE_REPOSITORY_URL")
    add_env_argument(parser, "--formula-class", "RELEASE_FORMULA_CLASS", required=False)
    add_env_argument(parser, "--source-license", "RELEASE_SOURCE_LICENSE")
    add_env_argument(parser, "--notices", "RELEASE_NOTICES")
    add_env_argument(parser, "--licenses-dir", "RELEASE_LICENSES_DIR")
    add_env_argument(parser, "--model-manifest", "RELEASE_MODEL_MANIFEST")
    add_env_argument(parser, "--embedded-model-manifest", "RELEASE_EMBEDDED_MODEL_MANIFEST")
    add_env_argument(parser, "--compatibility", "RELEASE_COMPATIBILITY")
    add_env_argument(parser, "--support", "RELEASE_SUPPORT")
    add_env_argument(parser, "--changelog", "RELEASE_CHANGELOG")
    add_env_argument(parser, "--repo-root", "RELEASE_REPO_ROOT")
    add_env_argument(parser, "--output-dir", "RELEASE_OUTPUT_DIR")
    add_env_argument(parser, "--build-handoff-state", "RELEASE_BUILD_HANDOFF_STATE", required=False)
    add_env_argument(parser, "--binary", "RELEASE_BINARY", required=False)
    add_env_argument(parser, "--signature-private-key", "RELEASE_SIGNATURE_PRIVATE_KEY", required=False)
    add_env_argument(parser, "--signature-public-key", "RELEASE_SIGNATURE_PUBLIC_KEY", required=False)
    add_env_argument(parser, "--signing-keychain", "RELEASE_SIGNING_KEYCHAIN", required=False)
    add_env_argument(parser, "--notary-keychain", "RELEASE_NOTARY_KEYCHAIN", required=False)


def require_common(args: argparse.Namespace, require_notary_profile: bool = True) -> None:
    names = [
        "product_identity", "executable", "package_id", "service_label", "version", "tag", "source_commit",
        "application_identity", "installer_identity", "team_id", "owner", "security_contact",
        "repository_url", "source_license", "notices", "licenses_dir", "model_manifest", "embedded_model_manifest", "compatibility",
        "support", "changelog", "repo_root", "output_dir",
    ]
    if require_notary_profile:
        names.insert(11, "notary_profile")
    missing = [name for name in names if not getattr(args, name, None)]
    if missing:
        fail("missing release inputs: " + ", ".join(missing))


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="release.py")
    subparsers = parser.add_subparsers(dest="command", required=True)
    build = subparsers.add_parser("build", help="build and verify a release bundle")
    add_common_arguments(build)
    build.add_argument("--sign", action="store_true", help="perform real Apple signing and notarization")
    build.add_argument("--unsigned-dry-run", action="store_true", help="build fixture-safe unsigned package layout")
    build.add_argument("--swift-build", action="store_true", help="build the executable with SwiftPM")
    build.set_defaults(handler=handle_build)
    sign_input = subparsers.add_parser("sign-input", help="sign and package an already verified build input")
    add_common_arguments(sign_input)
    sign_input.set_defaults(handler=handle_sign_input, unsigned_dry_run=False)
    verify = subparsers.add_parser("verify", help="verify a release output directory")
    add_common_arguments(verify)
    verify.add_argument("--unsigned-dry-run", action="store_true")
    verify.set_defaults(handler=handle_verify)
    source = subparsers.add_parser("validate-source", help="validate exact annotated tag and release inputs")
    add_common_arguments(source)
    source.set_defaults(handler=handle_validate_source)
    workflow = subparsers.add_parser("validate-workflow", help="validate immutable action pins and release permissions")
    workflow.add_argument("workflow", type=Path)
    workflow.set_defaults(handler=handle_validate_workflow)
    resolve = subparsers.add_parser("resolve-source", help="resolve the checked-out annotated tag target")
    resolve.add_argument("--repo-root", default=os.environ.get("RELEASE_REPO_ROOT"), required=False)
    resolve.add_argument("--tag", default=os.environ.get("RELEASE_TAG"), required=False)
    resolve.add_argument("--github-env", default=os.environ.get("GITHUB_ENV"), required=False)
    resolve.set_defaults(handler=handle_resolve_source)
    artifact = subparsers.add_parser("verify-artifact-handoff", help="verify the immutable GitHub build artifact handoff")
    artifact.add_argument("--artifact-id", default=os.environ.get("RELEASE_BUILD_ARTIFACT_ID"), required=False)
    artifact.add_argument("--artifact-digest", default=os.environ.get("RELEASE_BUILD_ARTIFACT_DIGEST"), required=False)
    artifact.add_argument("--repository", default=os.environ.get("GITHUB_REPOSITORY"), required=False)
    artifact.add_argument("--github-token", default=os.environ.get("GITHUB_TOKEN"), required=False)
    artifact.add_argument("--archive-path", default=os.environ.get("RELEASE_BUILD_ARCHIVE"), required=False)
    artifact.add_argument("--output-dir", default=os.environ.get("RELEASE_BUILD_EXTRACTED_DIR") or os.environ.get("RELEASE_OUTPUT_DIR"), required=False)
    artifact.add_argument("--handoff-state", default=os.environ.get("RELEASE_BUILD_HANDOFF_STATE"), required=False)
    artifact.add_argument("--snapshot-dir", default=os.environ.get("RELEASE_BUILD_SNAPSHOT_DIR"), required=False)
    artifact.add_argument("--snapshot-state", default=os.environ.get("RELEASE_BUILD_SNAPSHOT_STATE"), required=False)
    artifact.add_argument("--tag", default=os.environ.get("RELEASE_TAG"), required=False)
    artifact.add_argument("--source-commit", default=os.environ.get("RELEASE_SOURCE_COMMIT"), required=False)
    artifact.set_defaults(handler=handle_verify_artifact_handoff)
    prepare = subparsers.add_parser("prepare-signing", help="create temporary signing and notary credentials")
    prepare.add_argument("--runner-temp", default=os.environ.get("RUNNER_TEMP"), required=False)
    prepare.add_argument("--signing-state", default=os.environ.get("RELEASE_SIGNING_STATE"), required=False)
    prepare.add_argument("--signing-keychain", default=os.environ.get("RELEASE_SIGNING_KEYCHAIN"), required=False)
    prepare.add_argument("--cleanup-plan", default=os.environ.get("RELEASE_SIGNING_CLEANUP_PLAN"), required=False)
    prepare.add_argument("--application-certificate-base64", default=os.environ.get("RELEASE_APPLICATION_CERTIFICATE_BASE64"), required=False)
    prepare.add_argument("--installer-certificate-base64", default=os.environ.get("RELEASE_INSTALLER_CERTIFICATE_BASE64"), required=False)
    prepare.add_argument("--application-certificate-password", default=os.environ.get("RELEASE_APPLICATION_CERTIFICATE_PASSWORD"), required=False)
    prepare.add_argument("--installer-certificate-password", default=os.environ.get("RELEASE_INSTALLER_CERTIFICATE_PASSWORD"), required=False)
    prepare.add_argument("--notary-credentials-base64", default=os.environ.get("RELEASE_NOTARY_CREDENTIALS_BASE64"), required=False)
    prepare.add_argument("--notary-profile", default=os.environ.get("RELEASE_NOTARY_PROFILE"), required=False)
    prepare.add_argument("--team-id", default=os.environ.get("RELEASE_TEAM_ID"), required=False)
    prepare.add_argument("--application-certificate-path", default=os.environ.get("RELEASE_APPLICATION_CERTIFICATE_PATH"), required=False)
    prepare.add_argument("--installer-certificate-path", default=os.environ.get("RELEASE_INSTALLER_CERTIFICATE_PATH"), required=False)
    prepare.add_argument("--signature-private-key-base64", default=os.environ.get("RELEASE_SIGNATURE_PRIVATE_KEY_BASE64"), required=False)
    prepare.add_argument("--signature-public-key-base64", default=os.environ.get("RELEASE_SIGNATURE_PUBLIC_KEY_BASE64"), required=False)
    prepare.add_argument("--signature-private-key-path", default=os.environ.get("RELEASE_SIGNATURE_PRIVATE_KEY_PATH"), required=False)
    prepare.add_argument("--signature-public-key-path", default=os.environ.get("RELEASE_SIGNATURE_PUBLIC_KEY_PATH"), required=False)
    prepare.add_argument("--github-env", default=os.environ.get("GITHUB_ENV"), required=False)
    prepare.set_defaults(handler=handle_prepare_signing)
    prepare_verify = subparsers.add_parser("prepare-verification", help="write a protected detached-signature public key")
    prepare_verify.add_argument("--runner-temp", default=os.environ.get("RUNNER_TEMP"), required=False)
    prepare_verify.add_argument("--signing-state", default=os.environ.get("RELEASE_SIGNING_STATE"), required=False)
    prepare_verify.add_argument("--signature-public-key-base64", default=os.environ.get("RELEASE_SIGNATURE_PUBLIC_KEY_BASE64"), required=False)
    prepare_verify.add_argument("--signature-public-key-path", default=os.environ.get("RELEASE_SIGNATURE_PUBLIC_KEY_PATH"), required=False)
    prepare_verify.add_argument("--github-env", default=os.environ.get("GITHUB_ENV"), required=False)
    prepare_verify.set_defaults(handler=handle_prepare_verification)
    cleanup = subparsers.add_parser("cleanup-signing", help="remove temporary signing material")
    cleanup.add_argument("--runner-temp", default=os.environ.get("RUNNER_TEMP"), required=False)
    cleanup.add_argument("--signing-state", default=os.environ.get("RELEASE_SIGNING_STATE"), required=False)
    cleanup.add_argument("--trusted-keychain", default=os.environ.get("RELEASE_TRUSTED_SIGNING_KEYCHAIN"), required=False)
    cleanup.add_argument("--cleanup-plan", default=os.environ.get("RELEASE_SIGNING_CLEANUP_PLAN"), required=False)
    cleanup.add_argument("--trusted-profile", default=os.environ.get("RELEASE_NOTARY_PROFILE"), required=False)
    cleanup.add_argument("--application-certificate-path", default=os.environ.get("RELEASE_APPLICATION_CERTIFICATE_PATH"), required=False)
    cleanup.add_argument("--installer-certificate-path", default=os.environ.get("RELEASE_INSTALLER_CERTIFICATE_PATH"), required=False)
    cleanup.add_argument("--signature-private-key-path", default=os.environ.get("RELEASE_SIGNATURE_PRIVATE_KEY_PATH"), required=False)
    cleanup.add_argument("--signature-public-key-path", default=os.environ.get("RELEASE_SIGNATURE_PUBLIC_KEY_PATH"), required=False)
    cleanup.add_argument("--old-keychains", default=os.environ.get("RELEASE_OLD_KEYCHAINS"), required=False)
    cleanup.set_defaults(handler=handle_cleanup_signing)
    publish = subparsers.add_parser("publish", help="publish an already verified bundle from the release environment")
    add_common_arguments(publish)
    publish.add_argument("--repository", default=os.environ.get("GITHUB_REPOSITORY"))
    publish.set_defaults(handler=handle_publish)
    return parser


def handle_build(args: argparse.Namespace) -> None:
    require_common(args, require_notary_profile=args.sign)
    build_release(args)


def handle_sign_input(args: argparse.Namespace) -> None:
    require_common(args)
    sign_input_bundle(args)


def handle_verify(args: argparse.Namespace) -> None:
    require_common(args, require_notary_profile=False)
    inputs = validate_release_inputs(args, require_notary_profile=False)
    output_dir = args.output_dir.absolute()
    verify_artifacts(args, output_dir, args.unsigned_dry_run, approved_manifest_bytes=inputs["manifest_bytes"])
    print(json.dumps({"verified": str(output_dir), "unsignedDryRun": args.unsigned_dry_run}, sort_keys=True))


def handle_validate_source(args: argparse.Namespace) -> None:
    require_common(args, require_notary_profile=False)
    validate_release_inputs(args, require_notary_profile=False)
    print(json.dumps({"sourceCommit": args.source_commit, "tag": args.tag, "annotated": True, "clean": True}, sort_keys=True))


def handle_validate_workflow(args: argparse.Namespace) -> None:
    validate_workflow(args.workflow.resolve())


def handle_resolve_source(args: argparse.Namespace) -> None:
    if not args.repo_root or not args.tag:
        fail("resolve-source requires repository root and tag")
    source_commit = resolve_checked_out_source(Path(args.repo_root), args.tag, Path(args.github_env) if args.github_env else None)
    print(json.dumps({"tag": args.tag, "sourceCommit": source_commit, "annotated": True, "clean": True}, sort_keys=True))


class _RejectRedirects(urllib.request.HTTPRedirectHandler):
    def _reject(self, request, code, headers):
        raise urllib.error.HTTPError(request.full_url, code, "redirect rejected", headers, None)

    def redirect_request(self, request, fp, code, msg, headers, newurl):
        return self._reject(request, code, headers)

    def http_error_301(self, request, fp, code, msg, headers):
        return self._reject(request, code, headers)

    def http_error_302(self, request, fp, code, msg, headers):
        return self._reject(request, code, headers)

    def http_error_303(self, request, fp, code, msg, headers):
        return self._reject(request, code, headers)

    def http_error_307(self, request, fp, code, msg, headers):
        return self._reject(request, code, headers)

    def http_error_308(self, request, fp, code, msg, headers):
        return self._reject(request, code, headers)


class _CaptureFirstRedirect(urllib.request.HTTPRedirectHandler):
    def http_error_302(self, request, fp, code, msg, headers):
        return fp

    def http_error_301(self, request, fp, code, msg, headers):
        raise urllib.error.HTTPError(request.full_url, code, "redirect rejected", headers, None)

    http_error_303 = http_error_301
    http_error_307 = http_error_301
    http_error_308 = http_error_301


def validate_signed_artifact_location(value: str) -> str:
    if not isinstance(value, str) or not value or len(value.encode("utf-8")) > MAX_ARTIFACT_REDIRECT_LOCATION_BYTES:
        fail("GitHub artifact redirect location is invalid")
    try:
        parsed = urlsplit(value)
        hostname = parsed.hostname
        port = parsed.port
    except (TypeError, ValueError):
        fail("GitHub artifact redirect location is invalid")
    if parsed.scheme != "https" or not hostname or parsed.username or parsed.password or parsed.fragment or port is not None:
        fail("GitHub artifact redirect location is unsafe")
    try:
        address = ipaddress.ip_address(hostname)
    except ValueError:
        address = None
    if hostname.lower() in {"localhost", "localhost.localdomain"} or (address is not None and (address.is_loopback or address.is_private or address.is_link_local or address.is_unspecified)):
        fail("GitHub artifact redirect location is local")
    return value


def response_header_values(response: Any, name: str) -> List[str]:
    headers = getattr(response, "headers", None)
    if headers is None:
        return []
    if hasattr(headers, "get_all"):
        values = headers.get_all(name, []) or []
    else:
        value = headers.get(name)
        values = [] if value is None else [value]
    return [value for value in values if isinstance(value, str)]


def download_artifact_archive(repository: str, artifact_id: str, token: str, destination: Path) -> None:
    """Download one GitHub artifact archive through GitHub's two-request contract."""

    request_url = "https://api.github.com/repos/%s/actions/artifacts/%s/zip" % (repository, artifact_id)
    first_request = urllib.request.Request(
        request_url,
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": "Bearer " + token,
            "User-Agent": "trusted-native-release",
        },
        method="GET",
    )
    temporary = destination.with_name("." + destination.name + ".downloading")
    try:
        if temporary.exists() or temporary.is_symlink():
            fail("artifact archive temporary path already exists")
        first_opener = urllib.request.build_opener(_CaptureFirstRedirect())
        with first_opener.open(first_request, timeout=MAX_TOOL_SECONDS) as response:
            status = getattr(response, "status", None)
            if status == 410:
                fail("GitHub artifact archive has expired")
            if status != 302 or response.geturl() != request_url:
                fail("GitHub artifact archive response is not the exact expected redirect")
            locations = response_header_values(response, "Location")
            if len(locations) != 1:
                fail("GitHub artifact archive redirect has an invalid Location")
            signed_location = validate_signed_artifact_location(locations[0])
        second_request = urllib.request.Request(
            signed_location,
            headers={"Accept": "application/zip", "User-Agent": "trusted-native-release"},
            method="GET",
        )
        second_opener = urllib.request.build_opener(_RejectRedirects())
        with second_opener.open(second_request, timeout=MAX_TOOL_SECONDS) as response:
            if getattr(response, "status", None) != 200 or response.geturl() != signed_location:
                fail("GitHub artifact archive signed response is not exact")
            content_lengths = response_header_values(response, "Content-Length")
            content_length = content_lengths[0] if len(content_lengths) == 1 else None
            if not content_length or not content_length.isdigit() or int(content_length) <= 0 or int(content_length) > MAX_ARTIFACT_ARCHIVE_BYTES:
                fail("GitHub artifact archive has no safe bounded Content-Length")
            content_types = response_header_values(response, "Content-Type")
            content_type = content_types[0].split(";", 1)[0].strip().lower() if len(content_types) == 1 else ""
            if content_type not in {"application/zip", "application/octet-stream"}:
                fail("GitHub artifact archive has an unexpected content type")
            with temporary.open("xb") as handle:
                os.fchmod(handle.fileno(), 0o600)
                received = 0
                while True:
                    chunk = response.read(1024 * 1024)
                    if not chunk:
                        break
                    received += len(chunk)
                    if received > MAX_ARTIFACT_ARCHIVE_BYTES or received > int(content_length):
                        fail("GitHub artifact archive exceeded its declared bound")
                    handle.write(chunk)
                if received != int(content_length):
                    fail("GitHub artifact archive ended before its declared length")
                handle.flush()
                os.fsync(handle.fileno())
        os.replace(temporary, destination)
        sha256_file_pinned(destination)
    except (OSError, urllib.error.URLError, urllib.error.HTTPError):
        fail("could not download the exact GitHub artifact archive")
    finally:
        if temporary.exists() or temporary.is_symlink():
            try:
                if temporary.is_file() and not temporary.is_symlink():
                    temporary.unlink()
            except OSError:
                pass


def descriptor_hash(
    descriptor: int,
    label: str,
    rewind: bool = False,
    allow_ctime_change: bool = False,
) -> Tuple[Tuple[int, int, int, int, int, int, int], str]:
    try:
        before = stat_identity(os.fstat(descriptor))
        os.lseek(descriptor, 0, os.SEEK_SET)
        digest = hashlib.sha256()
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
        after = stat_identity(os.fstat(descriptor))
        if not identity_matches(before, after, allow_ctime_change):
            fail("%s changed while it was read" % label)
        if rewind:
            os.lseek(descriptor, 0, os.SEEK_SET)
        return before, digest.hexdigest()
    except OSError as error:
        fail("%s could not be read safely: %s" % (label, error))


def open_directory_pinned(path: Path, label: str) -> Tuple[int, Tuple[int, int, int, int, int, int, int]]:
    try:
        before = os.lstat(path)
    except OSError as error:
        fail("%s is not readable: %s" % (label, error))
    if not stat.S_ISDIR(before.st_mode) or stat.S_ISLNK(before.st_mode):
        fail("%s must be a real directory" % label)
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)
    try:
        descriptor = os.open(str(path), flags)
        opened = os.fstat(descriptor)
    except OSError as error:
        fail("%s could not be opened safely: %s" % (label, error))
    identity = stat_identity(before)
    if stat_identity(opened) != identity:
        os.close(descriptor)
        fail("%s changed before it was opened" % label)
    return descriptor, identity


def verify_directory_identity(path: Path, descriptor: int, identity: Tuple[int, int, int, int, int, int, int], label: str) -> None:
    try:
        after_descriptor = os.fstat(descriptor)
        after_path = os.lstat(path)
    except OSError as error:
        fail("%s could not be checked after use: %s" % (label, error))
    stable_before = (identity[0], identity[1], stat.S_IFMT(identity[2]))
    stable_after_descriptor = (after_descriptor.st_dev, after_descriptor.st_ino, stat.S_IFMT(after_descriptor.st_mode))
    stable_after_path = (after_path.st_dev, after_path.st_ino, stat.S_IFMT(after_path.st_mode))
    if stable_after_descriptor != stable_before or stable_after_path != stable_before:
        fail("%s was replaced while it was used" % label)
    if not stat.S_ISDIR(identity[2]):
        fail("%s has an unsafe identity" % label)


def zip_alias_key(parts: Sequence[str]) -> Tuple[str, ...]:
    return tuple(unicodedata.normalize("NFC", part).casefold() for part in parts)


def validate_zip_member_name(raw_name: str, seen: Dict[Tuple[str, ...], str], kinds: Dict[Tuple[str, ...], str]) -> Tuple[List[str], bool, Tuple[str, ...]]:
    if not raw_name or "\x00" in raw_name or "\\" in raw_name:
        fail("artifact ZIP contains an unsafe path")
    is_directory = raw_name.endswith("/")
    normalized_name = raw_name[:-1] if is_directory else raw_name
    parts = normalized_name.split("/")
    if not normalized_name or any(not part or part in (".", "..") for part in parts) or normalized_name.startswith("/"):
        fail("artifact ZIP contains a path traversal entry")
    alias = zip_alias_key(parts)
    if alias in seen:
        fail("artifact ZIP contains a duplicate or aliased path")
    for index in range(1, len(alias)):
        parent = alias[:index]
        if kinds.get(parent) == "file":
            fail("artifact ZIP contains a file and directory path collision")
        kinds.setdefault(parent, "directory")
    kind = "directory" if is_directory else "file"
    if alias in kinds and kinds[alias] != kind:
        fail("artifact ZIP contains a file and directory path collision")
    seen[alias] = normalized_name
    kinds[alias] = kind
    return parts, is_directory, alias


def open_zip_directory_chain(root_fd: int, parts: Sequence[str], created: Set[Tuple[str, ...]]) -> Tuple[int, Tuple[str, ...]]:
    current_fd = os.dup(root_fd)
    current_alias: Tuple[str, ...] = ()
    try:
        for part in parts:
            current_alias = current_alias + (unicodedata.normalize("NFC", part).casefold(),)
            try:
                child_fd = os.open(part, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0), dir_fd=current_fd)
            except FileNotFoundError:
                os.mkdir(part, 0o755, dir_fd=current_fd)
                child_fd = os.open(part, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0), dir_fd=current_fd)
                created.add(current_alias)
            os.close(current_fd)
            current_fd = child_fd
        return current_fd, current_alias
    except BaseException:
        os.close(current_fd)
        raise


def extract_verified_zip_archive(path: Path, destination: Path) -> str:
    """Hash and extract one pinned ZIP descriptor without pathname reopening."""

    archive_fd, archive_identity = open_pinned_regular(path, "GitHub artifact archive")
    archive_file = os.fdopen(archive_fd, "rb", closefd=True)
    destination_fd: Optional[int] = None
    created_destination = False
    extraction_succeeded = False
    try:
        archive_identity, archive_digest = descriptor_hash(archive_file.fileno(), "GitHub artifact archive", rewind=True)
        if destination.is_symlink() or destination.exists():
            if not destination.is_dir() or any(destination.iterdir()):
                fail("artifact extraction directory must be new and empty")
        else:
            destination.mkdir(mode=0o700, parents=False, exist_ok=False)
            created_destination = True
        destination_fd, destination_identity = open_directory_pinned(destination, "artifact extraction directory")
        seen: Dict[Tuple[str, ...], str] = {}
        kinds: Dict[Tuple[str, ...], str] = {}
        declared_total = 0
        with zipfile.ZipFile(archive_file, "r") as archive:
            members = archive.infolist()
            if len(members) > MAX_ARCHIVE_MEMBERS:
                fail("artifact ZIP contains too many members")
            for index, info in enumerate(members):
                parts, is_directory, alias = validate_zip_member_name(info.filename, seen, kinds)
                mode = (info.external_attr >> 16) & 0xffff
                file_type = stat.S_IFMT(mode)
                if file_type not in (0, stat.S_IFREG, stat.S_IFDIR) or (file_type == stat.S_IFDIR and not is_directory) or (file_type == stat.S_IFREG and is_directory):
                    fail("artifact ZIP contains a link or special entry")
                if info.file_size < 0 or info.file_size > MAX_ARCHIVE_MEMBER_BYTES:
                    fail("artifact ZIP member declared size is outside the bound")
                declared_total += info.file_size
                if declared_total > MAX_ARCHIVE_DECLARED_BYTES:
                    fail("artifact ZIP declared uncompressed size exceeds the bound")
                if is_directory:
                    directory_fd, _ = open_zip_directory_chain(destination_fd, parts, set())
                    try:
                        os.fchmod(directory_fd, 0o755)
                    finally:
                        os.close(directory_fd)
                    continue
                parent_fd, _ = open_zip_directory_chain(destination_fd, parts[:-1], set())
                try:
                    name = parts[-1]
                    file_mode = stat.S_IMODE(mode) if mode else 0o644
                    if file_mode not in (0o644, 0o755):
                        fail("artifact ZIP member has an unsafe mode")
                    temporary_name = ".release-extract-%08d" % index
                    output_fd = os.open(temporary_name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0), 0o600, dir_fd=parent_fd)
                    try:
                        with archive.open(info, "r") as source:
                            copied = 0
                            while True:
                                chunk = source.read(1024 * 1024)
                                if not chunk:
                                    break
                                copied += len(chunk)
                                if copied > MAX_ARCHIVE_MEMBER_BYTES:
                                    fail("artifact ZIP member exceeded its bound")
                                offset = 0
                                while offset < len(chunk):
                                    offset += os.write(output_fd, chunk[offset:])
                            if copied != info.file_size:
                                fail("artifact ZIP member length does not match its declaration")
                        os.fsync(output_fd)
                        os.fchmod(output_fd, file_mode)
                        output_stat = os.fstat(output_fd)
                        if not stat.S_ISREG(output_stat.st_mode) or output_stat.st_nlink != 1 or stat.S_IMODE(output_stat.st_mode) != file_mode:
                            fail("artifact ZIP extracted file identity is unsafe")
                    finally:
                        os.close(output_fd)
                    os.rename(temporary_name, name, src_dir_fd=parent_fd, dst_dir_fd=parent_fd)
                finally:
                    os.close(parent_fd)
        verify_directory_identity(destination, destination_fd, destination_identity, "artifact extraction directory")
        verify_pinned_identity(path, archive_file.fileno(), archive_identity, "GitHub artifact archive")
        extraction_succeeded = True
        return archive_digest
    except (OSError, zipfile.BadZipFile, zipfile.LargeZipFile) as error:
        fail("could not safely extract the GitHub artifact archive: %s" % error)
    finally:
        if destination_fd is not None:
            os.close(destination_fd)
        archive_file.close()
        if created_destination and not extraction_succeeded and destination.exists() and not destination.is_symlink():
            shutil.rmtree(destination, ignore_errors=True)


def handoff_file_records(output_dir: Path) -> Tuple[Dict[str, int], List[Dict[str, Any]]]:
    directory_fd, directory_identity = open_directory_pinned(output_dir, "artifact handoff output directory")
    try:
        directory_record = {"device": directory_identity[0], "inode": directory_identity[1], "mode": stat.S_IMODE(directory_identity[2]), "links": directory_identity[3]}
        records: List[Dict[str, Any]] = []
        try:
            names = sorted(os.listdir(directory_fd))
        except OSError as error:
            fail("artifact handoff output directory could not be listed: %s" % error)
        for name in names:
            if not name or "/" in name or name in (".", ".."):
                fail("artifact handoff output contains an unsafe entry")
            try:
                descriptor = os.open(name, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0), dir_fd=directory_fd)
            except OSError as error:
                fail("artifact handoff output entry could not be opened safely: %s" % error)
            try:
                identity, digest = descriptor_hash(descriptor, "artifact handoff file", rewind=True)
                if not stat.S_ISREG(identity[2]) or identity[3] != 1:
                    fail("artifact handoff output contains an unsafe entry: %s" % name)
                verify_pinned_identity(output_dir / name, descriptor, identity, "artifact handoff file")
                records.append({"name": name, "device": identity[0], "inode": identity[1], "size": identity[4], "mode": stat.S_IMODE(identity[2]), "links": identity[3], "sha256": digest})
            finally:
                os.close(descriptor)
        if not records:
            fail("artifact handoff output is empty")
        verify_directory_identity(output_dir, directory_fd, directory_identity, "artifact handoff output directory")
        return directory_record, records
    finally:
        os.close(directory_fd)


def verify_extracted_artifact_handoff(output_dir: Path, handoff_state: Path, tag: str, source_commit: str) -> None:
    try:
        state = json.loads(read_bounded_text(handoff_state, "artifact handoff state", 4 * 1024 * 1024, private=True))
    except (OSError, ValueError) as error:
        fail("artifact handoff state is not valid: %s" % error)
    if not isinstance(state, dict) or set(state) != {"schemaVersion", "artifactId", "artifactDigest", "tag", "sourceCommit", "directory", "files"} or state.get("schemaVersion") != 1:
        fail("artifact handoff state schema is invalid")
    if state.get("tag") != tag or state.get("sourceCommit") != source_commit or not ARTIFACT_ID_RE.fullmatch(str(state.get("artifactId", ""))) or not ARTIFACT_DIGEST_RE.fullmatch(str(state.get("artifactDigest", ""))):
        fail("artifact handoff state identity is invalid")
    files = state.get("files")
    directory = state.get("directory")
    if not isinstance(directory, dict) or set(directory) != {"device", "inode", "mode", "links"} or any(not isinstance(directory[key], int) or directory[key] < 0 for key in directory):
        fail("artifact handoff directory identity is invalid")
    if not isinstance(files, list) or not files or any(not isinstance(item, dict) or set(item) != {"name", "device", "inode", "size", "mode", "links", "sha256"} for item in files):
        fail("artifact handoff state file records are invalid")
    expected = {item["name"] for item in files}
    if len(expected) != len(files) or any(Path(name).name != name or name.startswith(".") for name in expected):
        fail("artifact handoff state contains an unsafe or duplicate file name")
    actual_directory, actual = handoff_file_records(output_dir)
    if actual_directory != directory:
        fail("downloaded artifact output directory changed after archive verification")
    if {item["name"] for item in actual} != expected:
        fail("downloaded artifact output changed after archive extraction")
    actual_by_name = {item["name"]: item for item in actual}
    for item in files:
        if actual_by_name[item["name"]] != item:
            fail("downloaded artifact file changed after archive verification: %s" % item["name"])


def copy_descriptor_to_directory(source_fd: int, destination_fd: int, name: str, mode: int) -> None:
    if not name or "/" in name or name in (".", ".."):
        fail("verified artifact snapshot file name is unsafe")
    output_fd = os.open(
        name,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0),
        mode,
        dir_fd=destination_fd,
    )
    try:
        os.lseek(source_fd, 0, os.SEEK_SET)
        while True:
            chunk = os.read(source_fd, 1024 * 1024)
            if not chunk:
                break
            offset = 0
            while offset < len(chunk):
                offset += os.write(output_fd, chunk[offset:])
        os.fsync(output_fd)
        os.fchmod(output_fd, mode)
    finally:
        os.close(output_fd)


def snapshot_verified_handoff(
    output_dir: Path,
    handoff_state: Path,
    tag: str,
    source_commit: str,
    destination: Path,
    snapshot_state: Optional[Path] = None,
) -> Path:
    verify_extracted_artifact_handoff(output_dir, handoff_state, tag, source_commit)
    state = json.loads(read_bounded_text(handoff_state, "artifact handoff state", 4 * 1024 * 1024, private=True))
    source_fd, source_identity = open_directory_pinned(output_dir, "artifact handoff source directory")
    destination_fd: Optional[int] = None
    try:
        if destination.exists() or destination.is_symlink():
            fail("verified artifact snapshot destination already exists")
        destination.mkdir(mode=0o700, parents=False, exist_ok=False)
        destination_fd, destination_identity = open_directory_pinned(destination, "verified artifact snapshot directory")
        for item in state["files"]:
            name = item["name"]
            descriptor = os.open(name, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0), dir_fd=source_fd)
            try:
                identity, digest = descriptor_hash(descriptor, "verified artifact snapshot source", rewind=True)
                actual = {"name": name, "device": identity[0], "inode": identity[1], "size": identity[4], "mode": stat.S_IMODE(identity[2]), "links": identity[3], "sha256": digest}
                if actual != item:
                    fail("verified artifact snapshot source changed: %s" % name)
                copy_descriptor_to_directory(descriptor, destination_fd, name, actual["mode"])
                verify_pinned_identity(output_dir / name, descriptor, identity, "verified artifact snapshot source")
            finally:
                os.close(descriptor)
        verify_directory_identity(output_dir, source_fd, source_identity, "artifact handoff source directory")
        verify_directory_identity(destination, destination_fd, destination_identity, "verified artifact snapshot directory")
        snapshot_directory, snapshot_files = handoff_file_records(destination)
        if snapshot_directory["mode"] != state["directory"]["mode"] or snapshot_directory["links"] != state["directory"]["links"]:
            fail("verified artifact snapshot directory identity changed")
        if {item["name"]: item["sha256"] for item in snapshot_files} != {item["name"]: item["sha256"] for item in state["files"]}:
            fail("verified artifact snapshot bytes changed")
        if snapshot_state is not None:
            write_atomic(snapshot_state, json_bytes({
                "schemaVersion": 1,
                "artifactId": state["artifactId"],
                "artifactDigest": state["artifactDigest"],
                "tag": tag,
                "sourceCommit": source_commit,
                "directory": snapshot_directory,
                "files": snapshot_files,
            }), mode=0o600)
        return destination
    finally:
        if destination_fd is not None:
            os.close(destination_fd)
        os.close(source_fd)


def verify_artifact_handoff(
    artifact_id: str,
    artifact_digest: str,
    repository: str,
    token: str,
    archive_path: Path,
    output_dir: Path,
    handoff_state: Path,
    tag: str,
    source_commit: str,
    snapshot_dir: Optional[Path] = None,
    snapshot_state: Optional[Path] = None,
) -> None:
    if not artifact_id or not ARTIFACT_ID_RE.fullmatch(artifact_id):
        fail("build artifact ID is missing or invalid")
    if not artifact_digest or not ARTIFACT_DIGEST_RE.fullmatch(artifact_digest):
        fail("build artifact digest is missing or invalid")
    if not repository or not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        fail("artifact handoff repository is invalid")
    if not token:
        fail("artifact handoff requires the scoped GitHub token")
    runner_temp = Path(os.environ.get("RUNNER_TEMP") or tempfile.gettempdir()).absolute()
    archive_path = ensure_temp_leaf_path(archive_path, "artifact archive", runner_temp)
    handoff_state = ensure_temp_leaf_path(handoff_state, "artifact handoff state", runner_temp)
    output_dir = ensure_temp_leaf_path(output_dir, "artifact extraction directory", runner_temp)
    snapshot_dir = ensure_temp_leaf_path(snapshot_dir or output_dir.with_name(output_dir.name + "-snapshot"), "artifact snapshot directory", runner_temp)
    snapshot_state = ensure_temp_leaf_path(snapshot_state or handoff_state.with_name(handoff_state.name + ".snapshot"), "artifact snapshot state", runner_temp)
    if any(path.exists() or path.is_symlink() for path in (archive_path, handoff_state, snapshot_dir, snapshot_state)):
        fail("artifact handoff destination already exists")
    if output_dir.is_symlink() or (output_dir.exists() and (not output_dir.is_dir() or any(output_dir.iterdir()))):
        fail("artifact extraction directory is not new and empty")
    SECRET_VALUES.add(token)
    try:
        _, output, errors = run_tool(
            [
                "gh", "api", "--header", "Accept: application/vnd.github+json",
                "repos/%s/actions/artifacts/%s" % (repository, artifact_id),
            ],
            env={"GITHUB_TOKEN": token},
        )
        try:
            response = json.loads(output or errors)
        except (TypeError, ValueError) as error:
            fail("GitHub artifact metadata is not valid JSON: %s" % error)
        if not isinstance(response, dict) or response.get("id") != int(artifact_id):
            fail("GitHub artifact ID does not match the uploaded build handoff")
        if response.get("digest") != "sha256:" + artifact_digest:
            fail("GitHub artifact digest does not match the uploaded build handoff")
        download_artifact_archive(repository, artifact_id, token, archive_path)
        archive_digest = extract_verified_zip_archive(archive_path, output_dir)
        if archive_digest != artifact_digest:
            fail("downloaded GitHub artifact bytes do not match the uploaded digest")
        inventory = read_inventory(output_dir / "artifact-inventory.json")
        if inventory.get("tag") != tag or inventory.get("sourceCommit") != source_commit:
            fail("downloaded artifact inventory does not match the exact source identity")
        directory, records = handoff_file_records(output_dir)
        write_atomic(handoff_state, json_bytes({
            "schemaVersion": 1,
            "artifactId": artifact_id,
            "artifactDigest": artifact_digest,
            "tag": tag,
            "sourceCommit": source_commit,
            "directory": directory,
            "files": records,
        }), mode=0o600)
        verify_extracted_artifact_handoff(output_dir, handoff_state, tag, source_commit)
        snapshot_verified_handoff(output_dir, handoff_state, tag, source_commit, snapshot_dir, snapshot_state)
        print(json.dumps({"artifactId": artifact_id, "artifactDigest": artifact_digest, "snapshot": str(snapshot_dir)}, sort_keys=True))
    finally:
        SECRET_VALUES.discard(token)


def handle_verify_artifact_handoff(args: argparse.Namespace) -> None:
    missing = [name for name in ("archive_path", "output_dir", "handoff_state", "tag", "source_commit") if not getattr(args, name, None)]
    if missing:
        fail("verify-artifact-handoff is missing: " + ", ".join(missing))
    verify_artifact_handoff(
        args.artifact_id,
        args.artifact_digest,
        args.repository,
        args.github_token,
        Path(args.archive_path),
        Path(args.output_dir),
        Path(args.handoff_state),
        args.tag,
        args.source_commit,
        Path(args.snapshot_dir) if args.snapshot_dir else None,
        Path(args.snapshot_state) if args.snapshot_state else None,
    )


def handle_prepare_signing(args: argparse.Namespace) -> None:
    prepare_signing(args)
    print(json.dumps({"prepared": True, "keychain": str(args.signing_keychain)}, sort_keys=True))


def handle_prepare_verification(args: argparse.Namespace) -> None:
    prepare_verification(args)
    print(json.dumps({"prepared": True}, sort_keys=True))


def handle_cleanup_signing(args: argparse.Namespace) -> None:
    cleanup_signing(args)
    print(json.dumps({"cleaned": True}, sort_keys=True))


def handle_publish(args: argparse.Namespace) -> None:
    require_common(args, require_notary_profile=False)
    publish_release(args)


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    for path_name in ("repo_root", "output_dir"):
        if hasattr(args, path_name) and getattr(args, path_name):
            setattr(args, path_name, Path(getattr(args, path_name)))
    try:
        args.handler(args)
    except ReleaseError as error:
        print("release error: " + redact(str(error)), file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        print("release error: interrupted", file=sys.stderr)
        return 130
    return 0


if __name__ == "__main__":
    sys.exit(main())
