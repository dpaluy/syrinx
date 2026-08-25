#!/bin/bash
set -Eeuo pipefail

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
exec python3 - "$script_dir" <<'PY'
import hashlib
import base64
import http.server
import io
import json
import os
import shutil
import socket
import stat
import subprocess
import sys
import signal
import threading
import tarfile
import tempfile
import time
import warnings
import zipfile
from pathlib import Path


script_dir = Path(sys.argv[1]).resolve()
sys.path.insert(0, str(script_dir))
import release as tooling


counts = {
    "positive": 0,
    "negative": 0,
    "attack": 0,
    "cleanup": 0,
    "timeout": 0,
    "descendant": 0,
    "secret-redaction": 0,
    "payload-contract": 0,
    "pkg-probe": 0,
    "layout": 0,
    "handoff": 0,
    "manifest": 0,
}
fixture_limits = []


def check(condition, message):
    if not condition:
        raise AssertionError(message)


def write_fixture_evidence(output_dir, pkg_probe_listing=None):
    evidence_file = os.environ.get("RELEASE_FIXTURE_EVIDENCE_FILE")
    if not evidence_file:
        return
    inventory_text = (output_dir / "artifact-inventory.json").read_text(encoding="utf-8")
    checksums_text = (output_dir / "SHA256SUMS").read_text(encoding="utf-8")
    archive_entries = {}
    for path in sorted(output_dir.glob("*.tar.gz")):
        archive_entries[path.name] = sorted(set(
            tooling.validate_archive_structure(path)
            if path.name.endswith(".source.tar.gz")
            else tooling.verify_archive_names(path, scan_content=True)
        ))
    probe_text = ""
    if pkg_probe_listing is not None:
        probe_text = "fixture_pkg_probe_listing=\n" + pkg_probe_listing
    Path(evidence_file).write_text(
        "fixture_inventory=\n" + inventory_text +
        "fixture_sha256sums=\n" + checksums_text +
        "fixture_archive_entries=" + json.dumps(archive_entries, sort_keys=True, separators=(",", ":")) + "\n" + probe_text,
        encoding="utf-8",
    )


def run_cli(core, args, env):
    process = subprocess.Popen(
        [sys.executable, str(core)] + args,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    stdout, stderr = process.communicate()
    check(len(stdout) <= tooling.MAX_TOOL_OUTPUT and len(stderr) <= tooling.MAX_TOOL_OUTPUT, "fixture command output exceeded bound")
    return process.returncode, stdout.decode("utf-8", errors="replace"), stderr.decode("utf-8", errors="replace")


def write(path, data, mode=0o644):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data if isinstance(data, bytes) else data.encode("utf-8"))
    path.chmod(mode)


def compare_payload_layout(expected_root, actual_root, executable_name):
    expected = tooling.payload_contract(expected_root)
    actual = tooling.payload_contract(actual_root)
    tooling.validate_payload_contract(actual, expected)
    for relative, kind in expected.items():
        expected_path = expected_root / relative[2:]
        actual_path = actual_root / relative[2:]
        if kind == "directory":
            check(stat.S_IMODE(actual_path.stat().st_mode) == 0o755, "layout directory mode is not 0755: " + relative)
            continue
        expected_mode = 0o755 if actual_path.name == executable_name or actual_path.suffix == ".dylib" else 0o644
        check(stat.S_IMODE(actual_path.stat().st_mode) == expected_mode, "layout file mode is not exact: %s (%o != %o)" % (relative, stat.S_IMODE(actual_path.stat().st_mode), expected_mode))
        check(actual_path.stat().st_nlink == 1, "layout file is not single-link: " + relative)
        check(actual_path.read_bytes() == expected_path.read_bytes(), "layout file bytes differ: " + relative)


def normalize_disposable_fixture_tree(root, label):
    paths = [root] + sorted(root.rglob("*"), key=lambda item: item.as_posix())
    for path in paths:
        names = tooling.descriptor_xattr_names(path, label + " before fixture normalization")
        if not names:
            continue
        check(names == {"com.apple.provenance"}, "%s retained unexpected metadata at %s: %s" % (label, path.relative_to(root), sorted(names)))
        result = subprocess.run(
            ["/usr/bin/xattr", "-c", str(path)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        check(result.returncode == 0, "%s fixture metadata removal failed: %s" % (label, result.stderr.strip()))
        check(not tooling.descriptor_xattr_names(path, label + " after fixture normalization"), "%s fixture normalization retained provenance at %s" % (label, path.relative_to(root)))
    tooling.validate_clean_filesystem_metadata(root, label + " normalized fixture")


def manifest(commit=None):
    source = script_dir.parent.parent / "Sources" / "SyrinxCore" / "Resources" / "parakeet-tdt-0.6b-v3-int8.json"
    value = json.loads(source.read_text(encoding="utf-8"))
    value["license"]["reviewStatus"] = "approved-fixture-model-license-review"
    digest_object = dict(value)
    digest_object.pop("manifestContentDigest")
    value["manifestContentDigest"]["hex"] = hashlib.sha256(tooling.canonical_json(digest_object)).hexdigest()
    if commit is not None:
        value["immutableCommit"] = commit
    return value


def make_fixture(base, version="1.2.3", manifest_value=None):
    root = base / "repo"
    root.mkdir()
    write(root / "Package.swift", "// swift-tools-version: 6.0\n")
    write(root / "Package.resolved", json.dumps({"version": 3, "pins": [{
        "identity": "fixture-dependency",
        "location": "https://github.com/fixture/dependency.git",
        "state": {"revision": "a" * 40, "version": "1.0.0"},
    }]}, sort_keys=True) + "\n")
    write(root / "LICENSE", "Apache License\nCopyright Fixture Maintainer\n")
    write(root / "THIRD_PARTY_NOTICES.md", "Fixture third-party notices.\n")
    write(root / "LICENSES" / "fixture.txt", "Fixture dependency license.\n")
    write(root / "COMPATIBILITY.md", "macOS 14 or later, Apple Silicon arm64.\n")
    write(root / "SUPPORT.md", "Fixture support contact.\n")
    write(root / "CHANGELOG.md", "# 1.2.3\nFixture release.\n")
    manifest_text = json.dumps(manifest_value or manifest(), sort_keys=True) + "\n"
    write(root / "ModelManifests" / "fixture.json", manifest_text)
    write(root / "Sources" / "SyrinxCore" / "Resources" / "fixture.json", manifest_text)
    write(root / "Sources" / "SourceMarker.swift", 'let sourceMarker = "Syrinx source fixture marker"\n')
    binary = root / "fixture-service"
    write(binary, b"#!/bin/sh\nprintf '%s\\n' fixture\n", mode=0o755)
    subprocess.run(["git", "init", "--quiet"], cwd=root, check=True)
    subprocess.run(["git", "config", "user.email", "fixture@example.test"], cwd=root, check=True)
    subprocess.run(["git", "config", "user.name", "Fixture Maintainer"], cwd=root, check=True)
    subprocess.run(["git", "config", "commit.gpgsign", "false"], cwd=root, check=True)
    subprocess.run(["git", "config", "tag.gpgsign", "false"], cwd=root, check=True)
    subprocess.run(["git", "add", "-A"], cwd=root, check=True)
    subprocess.run(["git", "commit", "--quiet", "-m", "fixture"], cwd=root, check=True)
    commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
    subprocess.run(["git", "tag", "-a", "v" + version, "-m", "fixture tag"], cwd=root, check=True)
    return root, binary, commit


def base_env(root, output, version, commit, binary):
    values = {
        "RELEASE_REPO_ROOT": str(root),
        "RELEASE_OUTPUT_DIR": str(output),
        "RELEASE_PRODUCT_IDENTITY": "FixtureProduct",
        "RELEASE_EXECUTABLE": "fixture-service",
        "RELEASE_PACKAGE_ID": "com.fixture.product",
        "RELEASE_SERVICE_LABEL": "com.fixture.product.service",
        "RELEASE_VERSION": version,
        "RELEASE_TAG": "v" + version,
        "RELEASE_SOURCE_COMMIT": commit,
        "RELEASE_APPLICATION_IDENTITY": "Developer ID Application: Fixture Product (FIXTUR1234)",
        "RELEASE_INSTALLER_IDENTITY": "Developer ID Installer: Fixture Product (FIXTUR1234)",
        "RELEASE_TEAM_ID": "FIXTUR1234",
        "RELEASE_NOTARY_PROFILE": "fixture-profile",
        "RELEASE_OWNER": "Fixture Maintainer",
        "RELEASE_SECURITY_CONTACT": "security@fixture.test",
        "RELEASE_REPOSITORY_URL": "https://github.com/fixture-owner/fixture-product",
        "RELEASE_SOURCE_LICENSE": "LICENSE",
        "RELEASE_NOTICES": "THIRD_PARTY_NOTICES.md",
        "RELEASE_LICENSES_DIR": "LICENSES",
        "RELEASE_MODEL_MANIFEST": "ModelManifests/fixture.json",
        "RELEASE_EMBEDDED_MODEL_MANIFEST": "Sources/SyrinxCore/Resources/fixture.json",
        "RELEASE_COMPATIBILITY": "COMPATIBILITY.md",
        "RELEASE_SUPPORT": "SUPPORT.md",
        "RELEASE_CHANGELOG": "CHANGELOG.md",
        "RELEASE_BINARY": str(binary),
    }
    result = os.environ.copy()
    result.update(values)
    return result


with tempfile.TemporaryDirectory(prefix="syrinx-release-fixtures-") as temporary:
    temporary_root = Path(temporary)
    forbidden = temporary_root / "forbidden-tools"
    forbidden.mkdir()
    marker = temporary_root / "forbidden-called"
    stub = "#!/bin/sh\nprintf '%s\\n' called >> '%s'\nexit 99\n" % ("$0", marker)
    for name in ("codesign", "pkgbuild", "productsign", "xcrun", "stapler", "spctl", "pkgutil", "installer", "brew", "gh", "security", "otool"):
        write(forbidden / name, stub, mode=0o755)
    env_path = str(forbidden) + os.pathsep + os.environ.get("PATH", "")

    root, binary, commit = make_fixture(temporary_root)
    output_one = temporary_root / "out-one"
    env = base_env(root, output_one, "1.2.3", commit, binary)
    env["PATH"] = env_path
    core = script_dir / "release.py"

    code, stdout, stderr = run_cli(core, ["build", "--unsigned-dry-run"], env)
    check(code == 0, "positive dry run failed: " + stderr)
    counts["positive"] += 1

    source_archive = output_one / "FixtureProduct-1.2.3.source.tar.gz"
    tooling.validate_archive_structure(source_archive)
    source_args = tooling.argparse.Namespace(repo_root=root, tag="v1.2.3", product_identity="FixtureProduct", version="1.2.3")
    tooling.verify_source_archive(source_archive, source_args)
    counts["positive"] += 1

    dispatch_env = temporary_root / "dispatch-github-env"
    resolved = tooling.resolve_checked_out_source(root, "v1.2.3", dispatch_env)
    check(resolved == commit, "workflow dispatch source identity did not resolve the requested annotated tag")
    check("RELEASE_SOURCE_COMMIT=" + commit in dispatch_env.read_text(encoding="utf-8"), "resolved source commit was not exported")
    counts["positive"] += 1

    public_manifest_bytes = (root / "ModelManifests" / "fixture.json").read_bytes()
    embedded_manifest_bytes = (root / "Sources" / "SyrinxCore" / "Resources" / "fixture.json").read_bytes()
    tooling.validate_manifest_pair(public_manifest_bytes, embedded_manifest_bytes)
    for label, mutated in (
        ("public", public_manifest_bytes.replace(b'"int8"', b'"int9"', 1)),
        ("embedded", embedded_manifest_bytes.replace(b'"int8"', b'"int9"', 1)),
    ):
        try:
            tooling.validate_manifest_pair(mutated if label == "public" else public_manifest_bytes, mutated if label == "embedded" else embedded_manifest_bytes)
        except tooling.ReleaseError:
            counts["manifest"] += 1
        else:
            raise AssertionError("manifest parity drift was accepted: " + label)

    formula_text = (output_one / "FixtureProduct.rb").read_text(encoding="utf-8")
    check("libexec.install" in formula_text and "bin.install_symlink" in formula_text, "formula does not use a Cellar-local layout")
    check("/usr/sbin/installer" not in formula_text, "formula invokes the system installer")
    check("models install --activate" in formula_text, "formula does not use the real model activation command")
    check(subprocess.run(["ruby", "-c", str(output_one / "FixtureProduct.rb")], stdout=subprocess.PIPE, stderr=subprocess.PIPE).returncode == 0, "formula syntax is invalid")
    formula_layout_root = temporary_root
    formula_extract = temporary_root / "formula-extract"
    tooling.extract_safe_archive(output_one / "FixtureProduct-1.2.3.tar.gz", formula_extract)
    formula_payload = formula_extract / "Library" / "Application Support" / "FixtureProduct" / "versions" / "1.2.3"
    formula_cellar = formula_layout_root / "Cellar" / "fixture-product" / "1.2.3" / "libexec"
    shutil.copytree(formula_payload, formula_cellar)
    formula_bin = formula_layout_root / "Cellar" / "fixture-product" / "1.2.3" / "bin"
    formula_bin.mkdir(parents=True)
    os.symlink(os.path.relpath(formula_cellar / "fixture-service", formula_bin), formula_bin / "fixture-service")
    check((formula_cellar / "fixture-service").is_file() and (formula_bin / "fixture-service").is_symlink(), "formula layout fixture was not Cellar-local")
    check(not os.path.isabs(os.readlink(formula_bin / "fixture-service")), "formula symlink was not relative")
    check(not (temporary_root / "Library").exists(), "formula layout fixture mutated the system path")
    package_contract = tooling.payload_contract(formula_extract)
    stub_listing = ".\n" + "\n".join(sorted(package_contract)) + "\n"
    tooling.validate_payload_listing(stub_listing, package_contract)
    compare_payload_layout(formula_payload, formula_cellar, "fixture-service")
    mode_probe = formula_layout_root / "mode-probe"
    shutil.copytree(formula_payload, mode_probe)
    (mode_probe / "fixture-service").chmod(0o644)
    try:
        compare_payload_layout(formula_payload, mode_probe, "fixture-service")
    except (tooling.ReleaseError, AssertionError):
        counts["attack"] += 1
    else:
        raise AssertionError("package mode substitution was accepted")
    content_probe = formula_layout_root / "content-probe"
    shutil.copytree(formula_payload, content_probe)
    (content_probe / "metadata" / "release.json").write_bytes(b"tampered\n")
    try:
        compare_payload_layout(formula_payload, content_probe, "fixture-service")
    except (tooling.ReleaseError, AssertionError):
        counts["attack"] += 1
    else:
        raise AssertionError("package content substitution was accepted")
    counts["payload-contract"] += 1

    def expect_payload_failure(listing, expected, label):
        try:
            tooling.validate_payload_listing(listing, expected)
        except tooling.ReleaseError:
            counts["attack"] += 1
        else:
            raise AssertionError(label + " was accepted")

    contract_entries = sorted(package_contract)
    expect_payload_failure("\n".join(contract_entries[1:]) + "\n", package_contract, "missing payload path")
    expect_payload_failure(stub_listing + "./unexpected\n", package_contract, "extra payload path")
    expect_payload_failure(stub_listing + contract_entries[0] + "\n", package_contract, "duplicate payload path")
    expect_payload_failure(stub_listing + "../escape\n", package_contract, "traversal payload path")
    expect_payload_failure("Package contents\n", package_contract, "unparsable payload listing")
    wrong_type = dict(package_contract)
    wrong_type[next(name for name, kind in wrong_type.items() if kind == "file")] = "directory"
    try:
        tooling.validate_payload_contract(package_contract, wrong_type)
    except tooling.ReleaseError:
        counts["attack"] += 1
    else:
        raise AssertionError("payload directory/file mismatch was accepted")

    write_fixture_evidence(output_one)

    provenance_positive_root = temporary_root / "provenance-positive"
    provenance_positive_root.mkdir()
    provenance_positive_file = provenance_positive_root / "payload.bin"
    provenance_positive_file.write_bytes(b"provenance-positive-bytes\n")
    provenance_set = subprocess.run(
        ["/usr/bin/xattr", "-w", "com.apple.provenance", "fixture-provenance", str(provenance_positive_file)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    check(provenance_set.returncode == 0, "could not create the singleton provenance fixture: " + provenance_set.stderr)
    provenance_removal_supported = True
    try:
        tooling.remove_exact_host_provenance(provenance_positive_root, "provenance positive")
    except tooling.ReleaseError as error:
        if "provenance" not in str(error):
            raise
        provenance_removal_supported = False
        fixture_limits.append("single-node provenance removal blocked by host-added com.apple.provenance")
    if provenance_removal_supported:
        check(provenance_positive_file.read_bytes() == b"provenance-positive-bytes\n", "valid provenance removal changed file bytes")
        check(not tooling.descriptor_xattr_names(provenance_positive_file, "provenance positive result"), "valid provenance removal retained metadata")
        counts["positive"] += 1

    provenance_attack_root = temporary_root / "provenance-byte-attack"
    provenance_attack_root.mkdir()
    provenance_attack_file = provenance_attack_root / "payload.bin"
    original_provenance_bytes = b"original-provenance-bytes\n"
    provenance_attack_file.write_bytes(original_provenance_bytes)
    provenance_set = subprocess.run(
        ["/usr/bin/xattr", "-w", "com.apple.provenance", "fixture-provenance", str(provenance_attack_file)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    check(provenance_set.returncode == 0, "could not create the provenance byte attack fixture: " + provenance_set.stderr)
    original_remove_descriptor_xattr = tooling.remove_descriptor_xattr
    provenance_mutated = [False]

    def mutate_after_provenance_removal(descriptor, name, label):
        result = original_remove_descriptor_xattr(descriptor, name, label)
        if name == "com.apple.provenance" and not provenance_mutated[0] and os.fstat(descriptor).st_ino == os.stat(provenance_attack_file).st_ino:
            provenance_mutated[0] = True
            before = os.stat(provenance_attack_file)
            with provenance_attack_file.open("r+b") as handle:
                handle.seek(0)
                handle.write(b"tampered-provenance-bytes\n")
            os.utime(provenance_attack_file, ns=(before.st_atime_ns, before.st_mtime_ns))
        return result

    if provenance_removal_supported:
        tooling.remove_descriptor_xattr = mutate_after_provenance_removal
        try:
            try:
                tooling.remove_exact_host_provenance(provenance_attack_root, "provenance byte attack")
            except tooling.ReleaseError as error:
                check("bytes" in str(error) or "digest" in str(error) or "changed" in str(error), "provenance byte mutation failed at the wrong gate: " + str(error))
                check(provenance_mutated[0], "provenance byte mutation hook did not run")
                counts["attack"] += 1
            else:
                raise AssertionError("provenance byte mutation was accepted")
        finally:
            tooling.remove_descriptor_xattr = original_remove_descriptor_xattr

    pkgbuild = Path("/usr/bin/pkgbuild")
    pkgutil = Path("/usr/sbin/pkgutil")
    hdiutil = Path("/usr/bin/hdiutil")
    if pkgbuild.is_file() and pkgutil.is_file() and hdiutil.is_file():
        probe_source_parent = None
        probe_source_mount = None
        try:
            probe_source_parent, probe_source_mount = tooling.create_clean_apfs_volume(temporary_root)
            try:
                probe_source_root = probe_source_mount / "payload"
                probe_version_root = probe_source_root / "Library" / "Application Support" / "Probe" / "versions" / "1.0.0"
                tooling.run_tool(["/bin/mkdir", "-p", str(probe_version_root)])
                tooling.run_tool(["/bin/cp", "-X", "/usr/bin/true", str(probe_version_root / "probe")], env={"COPYFILE_DISABLE": "1"})
                tooling.run_tool(["/bin/chmod", "755", str(probe_version_root / "probe")])
                normalize_disposable_fixture_tree(probe_source_root, "clean pkgbuild source")

                probe_package = temporary_root / "payload-contract-probe.pkg"
                probe_staging_parent, probe_mount, pkgbuild_root = tooling.create_clean_package_staging(probe_source_root, temporary_root)
                try:
                    xattr_probe = subprocess.run([str(Path("/usr/bin/xattr")), "-lr", str(pkgbuild_root)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                    check(not xattr_probe.stdout.strip(), "fixture pkgbuild root retained extended attributes: " + xattr_probe.stdout)
                    probe = subprocess.run(
                        [str(pkgbuild), "--root", str(pkgbuild_root), "--identifier", "com.fixture.probe", "--version", "1.0.0", "--install-location", "/", "--ownership", "recommended", str(probe_package)],
                        stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE,
                        text=True,
                        env=dict(os.environ, COPYFILE_DISABLE="1"),
                    )
                    check(probe.returncode == 0, "local pkgbuild payload probe failed: " + probe.stderr)
                    listing = subprocess.check_output([str(pkgutil), "--payload-files", str(probe_package)], text=True)
                    tooling.validate_payload_listing(listing, tooling.payload_contract(pkgbuild_root))
                    tooling.verify_expanded_package(probe_package, pkgbuild_root, "probe")
                    counts["pkg-probe"] += 1
                    write_fixture_evidence(output_one, listing)
                finally:
                    tooling.run_tool(["/usr/bin/hdiutil", "detach", "-force", str(probe_mount)])
                    shutil.rmtree(probe_staging_parent, ignore_errors=True)

                provenance_parent = temporary_root / "provenance-parent"
                provenance_parent.mkdir()
                provenance_marker = subprocess.run(
                    ["/usr/bin/xattr", "-w", "com.apple.provenance", "fixture-provenance", str(provenance_parent)],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                )
                if provenance_marker.returncode == 0:
                    clean_parent, clean_mount, clean_root = tooling.create_clean_package_staging(probe_source_root, provenance_parent)
                    try:
                        tooling.validate_clean_filesystem_metadata(clean_root, "provenance-parent package staging")
                        check(not subprocess.check_output(["/usr/bin/xattr", "-lr", str(clean_root)], text=True).strip(), "provenance parent metadata crossed the APFS staging boundary")
                        counts["pkg-probe"] += 1
                    finally:
                        tooling.run_tool(["/usr/bin/hdiutil", "detach", "-force", str(clean_mount)])
                        shutil.rmtree(clean_parent, ignore_errors=True)
            finally:
                tooling.run_tool(["/usr/bin/hdiutil", "detach", "-force", str(probe_source_mount)])
                shutil.rmtree(probe_source_parent, ignore_errors=True)
                probe_source_mount = None
                probe_source_parent = None
        except (tooling.ReleaseError, AssertionError) as error:
            if "provenance" not in str(error):
                raise
            fixture_limits.append("real APFS pkgbuild probe failed: fixture-only single-node xattr -c did not clear host-added com.apple.provenance")
        finally:
            if probe_source_mount is not None:
                tooling.run_tool(["/usr/bin/hdiutil", "detach", "-force", str(probe_source_mount)])
            if probe_source_parent is not None:
                shutil.rmtree(probe_source_parent, ignore_errors=True)
    else:
        counts["pkg-probe"] += 0

    formula_contract = tooling.payload_contract(formula_payload)
    for payload_path in sorted(formula_contract):
        relative = payload_path[2:]
        package_file = formula_payload / relative
        cellar_file = formula_cellar / relative
        if formula_contract[payload_path] == "file":
            check(package_file.read_bytes() == cellar_file.read_bytes(), "package and Homebrew payload bytes differ: " + relative)
    release_metadata = json.loads((formula_payload / "metadata" / "release.json").read_text(encoding="utf-8"))
    check("installLayout" not in release_metadata, "release metadata contains the removed false layout field")
    check("currentPointer" not in release_metadata["deliveryLayouts"]["package"], "package metadata contains a nonexistent pointer")
    check(release_metadata["deliveryLayouts"]["homebrew"]["currentPointer"].startswith("not applicable"), "Homebrew pointer contract is false")
    runtime_lifecycle = release_metadata["runtimeLifecycle"]
    check(runtime_lifecycle["dataRootRelativeVersionPath"] == "service/versions/{version}", "runtime version-store contract is not machine-usable")
    check(runtime_lifecycle["selectionRecord"] == "service/selection.json", "runtime selection record contract is missing")
    check(runtime_lifecycle["selectionRecordOwner"] == "service lifecycle", "runtime selection ownership is not explicit")
    check(not runtime_lifecycle["dataRootRelativeVersionPath"].startswith("/"), "runtime version-store contract contains an absolute path")
    service_data_root = temporary_root / "per-user-data"
    service_version_root = service_data_root / "service" / "versions" / "1.2.3"
    shutil.copytree(formula_payload, service_version_root)
    selection_record = service_data_root / "service" / "selection.json"
    write(selection_record, json.dumps({"schemaVersion": 1, "activeVersion": "1.2.3"}, sort_keys=True) + "\n")
    check(selection_record.is_file() and json.loads(selection_record.read_text(encoding="utf-8"))["activeVersion"] == "1.2.3", "service lifecycle fixture did not create the per-user record")
    for payload_path in sorted(formula_contract):
        relative = payload_path[2:]
        if formula_contract[payload_path] == "file":
            check((formula_payload / relative).read_bytes() == (service_version_root / relative).read_bytes(), "materialized service payload differs: " + relative)
    check(not any(path.name == "current" for path in formula_payload.rglob("*")), "package payload contains a nonexistent current pointer")
    counts["layout"] += 1

    copy_root = Path(subprocess.check_output(["/usr/bin/mktemp", "-d", "/tmp/syrinx-release-copy-XXXXXX"], text=True).strip())
    try:
        copy_source = copy_root / "source"
        copy_destination = copy_root / "destination"
        try:
            copy_source = script_dir / "release.py"
            tooling.copy_archive_to_clean_boundary(copy_source, copy_destination)
            check(copy_destination.read_bytes() == copy_source.read_bytes(), "descriptor copy changed clean bytes")
            check(not tooling.descriptor_xattr_names(copy_destination, "clean copy destination"), "clean copy destination retained metadata")

            aba_source = copy_root / "aba-source"
            aba_replacement = copy_root / "aba-replacement"
            aba_hold = copy_root / "aba-original"
            aba_replaced = copy_root / "aba-replaced"
            aba_destination = copy_root / "aba-destination"
            aba_source.write_bytes(b"original descriptor bytes\n")
            aba_replacement.write_bytes(b"replacement pathname bytes\n")
            original_read = tooling.os.read
            swapped = [False]
            read_calls = [0]

            def swap_and_restore(descriptor, size):
                read_calls[0] += 1
                if read_calls[0] == 3 and not swapped[0]:
                    swapped[0] = True
                    os.replace(aba_source, aba_hold)
                    os.replace(aba_replacement, aba_source)
                    data = original_read(descriptor, size)
                    os.replace(aba_source, aba_replaced)
                    os.replace(aba_hold, aba_source)
                    return data
                return original_read(descriptor, size)

            tooling.os.read = swap_and_restore
            try:
                try:
                    tooling.copy_archive_to_clean_boundary(aba_source, aba_destination)
                except tooling.ReleaseError as error:
                    check(any(marker in str(error) for marker in ("changed", "replaced or rewritten")), "ABA source replacement was not rejected: " + str(error))
                    check(aba_destination.read_bytes() == b"original descriptor bytes\n", "ABA destination did not contain held-descriptor bytes")
                    counts["handoff"] += 1
                else:
                    check(aba_destination.read_bytes() == b"original descriptor bytes\n", "descriptor copy read replacement pathname bytes")
                    counts["handoff"] += 1
            finally:
                tooling.os.read = original_read
            check(aba_source.read_bytes() == b"original descriptor bytes\n", "descriptor copy did not restore the source pathname")
        except tooling.ReleaseError as error:
            if "provenance" not in str(error):
                raise
            fixture_limits.append("descriptor-copy and source-path ABA positives blocked by host-added com.apple.provenance")
    finally:
        shutil.rmtree(copy_root, ignore_errors=True)
    counts["positive"] += 1
    code, stdout, stderr = run_cli(core, ["verify", "--unsigned-dry-run"], env)
    check(code == 0, "positive verification failed: " + stderr)
    counts["positive"] += 1
    no_profile_env = dict(env)
    no_profile_env.pop("RELEASE_NOTARY_PROFILE", None)
    code, stdout, stderr = run_cli(core, ["verify", "--unsigned-dry-run"], no_profile_env)
    check(code == 0, "unsigned verification inherited a required notary profile: " + stderr)
    counts["positive"] += 1

    signed_verify_args = {
        "product_identity": "FixtureProduct", "executable": "fixture-service", "package_id": "com.fixture.product",
        "service_label": "com.fixture.product.service", "version": "1.2.3", "tag": "v1.2.3", "source_commit": commit,
        "application_identity": "Developer ID Application: Fixture Product (FIXTUR1234)",
        "installer_identity": "Developer ID Installer: Fixture Product (FIXTUR1234)", "team_id": "FIXTUR1234",
        "owner": "Fixture Maintainer", "security_contact": "security@fixture.test",
        "repository_url": "https://github.com/fixture-owner/fixture-product", "source_license": "LICENSE",
        "notices": "THIRD_PARTY_NOTICES.md", "licenses_dir": "LICENSES", "model_manifest": "ModelManifests/fixture.json",
        "embedded_model_manifest": "Sources/SyrinxCore/Resources/fixture.json", "compatibility": "COMPATIBILITY.md",
        "support": "SUPPORT.md", "changelog": "CHANGELOG.md", "repo_root": root, "output_dir": output_one,
        "unsigned_dry_run": False,
    }
    original_validate_inputs = tooling.validate_release_inputs
    original_verify_artifacts = tooling.verify_artifacts
    tooling.validate_release_inputs = lambda args, require_notary_profile=True: {"manifest_bytes": public_manifest_bytes}
    tooling.verify_artifacts = lambda args, output_dir, unsigned, approved_manifest_bytes: None
    try:
        tooling.handle_verify(tooling.argparse.Namespace(**signed_verify_args))
    finally:
        tooling.validate_release_inputs = original_validate_inputs
        tooling.verify_artifacts = original_verify_artifacts
    counts["positive"] += 1

    manifest_drift_root = temporary_root / "manifest-drift-output"
    shutil.copytree(output_one, manifest_drift_root)
    drift_manifest = manifest_drift_root / "model-manifest.json"
    drift_manifest.write_bytes(drift_manifest.read_bytes() + b"\n")
    drift_args = tooling.argparse.Namespace(**signed_verify_args)
    drift_args.unsigned_dry_run = True
    drift_args.formula_class = None
    try:
        tooling.verify_artifacts(drift_args, manifest_drift_root, True, public_manifest_bytes)
    except tooling.ReleaseError as error:
        check("approved tracked manifest" in str(error), "artifact manifest drift failed at the wrong release gate")
        counts["attack"] += 1
    else:
        raise AssertionError("artifact model manifest drift was accepted")

    bundle_fixture = temporary_root / "bundle-fixture"
    bundle_source = bundle_fixture / "SYRINX_SyrinxCore.bundle"
    bundle_manifest = bundle_source / "parakeet-tdt-0.6b-v3-int8.json"
    write(bundle_manifest, public_manifest_bytes)
    try:
        tooling.validate_resource_bundle(bundle_source, public_manifest_bytes)
        bundle_destination = bundle_fixture / "relocated" / "SYRINX_SyrinxCore.bundle"
        tooling.copy_resource_bundle(bundle_source, bundle_destination, public_manifest_bytes)
        check(bundle_destination.joinpath(bundle_manifest.name).read_bytes() == public_manifest_bytes, "resource bundle manifest was not copied exactly")
        extra_bundle_file = bundle_source / "extra.json"
        write(extra_bundle_file, "unexpected\n")
        try:
            tooling.validate_resource_bundle(bundle_source, public_manifest_bytes)
        except tooling.ReleaseError:
            counts["manifest"] += 1
        else:
            raise AssertionError("resource bundle extra file was accepted")
        extra_bundle_file.unlink()
    except tooling.ReleaseError as error:
        if "com.apple.provenance" not in str(error):
            raise
        fixture_limits.append("resource-bundle relocation positive blocked by host-added com.apple.provenance")
    resource_archive = bundle_fixture / "resource-drift.tar.gz"
    resource_name = "Library/Application Support/FixtureProduct/versions/1.2.3/SYRINX_SyrinxCore.bundle/parakeet-tdt-0.6b-v3-int8.json"
    with tarfile.open(resource_archive, "w:gz") as resource_tar:
        resource_info = tarfile.TarInfo(resource_name)
        resource_info.mode = 0o644
        resource_info.size = len(public_manifest_bytes) + 1
        resource_tar.addfile(resource_info, io.BytesIO(public_manifest_bytes + b"x"))
    resource_args = tooling.argparse.Namespace(product_identity="FixtureProduct", version="1.2.3", unsigned_dry_run=True, swift_build=True)
    try:
        tooling.verify_archive_resource_manifest(resource_archive, resource_args, public_manifest_bytes, required=True)
    except tooling.ReleaseError:
        counts["manifest"] += 1
    else:
        raise AssertionError("resource manifest drift was accepted during offline archive verification")
    resource_extra_archive = bundle_fixture / "resource-extra.tar.gz"
    resource_extra_manifest_name = "Library/Application Support/FixtureProduct/versions/1.2.3/SYRINX_SyrinxCore.bundle/parakeet-tdt-0.6b-v3-int8.json"
    resource_extra_name = "Library/Application Support/FixtureProduct/versions/1.2.3/SYRINX_SyrinxCore.bundle/extra.json"
    with tarfile.open(resource_extra_archive, "w:gz") as resource_tar:
        for name, content in ((resource_extra_manifest_name, public_manifest_bytes), (resource_extra_name, b"unexpected\n")):
            resource_info = tarfile.TarInfo(name)
            resource_info.mode = 0o644
            resource_info.size = len(content)
            resource_tar.addfile(resource_info, io.BytesIO(content))
    try:
        tooling.verify_archive_resource_bundle(resource_extra_archive, resource_args, public_manifest_bytes)
    except tooling.ReleaseError as error:
        check("unexpected regular file" in str(error), "offline resource bundle extra file failed at the wrong gate: " + str(error))
        counts["attack"] += 1
    else:
        raise AssertionError("offline resource bundle extra file was accepted")
    fallback_binary = bundle_fixture / "fixture-service"
    fallback_path = str(bundle_source).encode("utf-8")
    write(fallback_binary, b"prefix " + fallback_path + b" suffix\n", mode=0o755)
    tooling.neutralize_swift_resource_fallback(fallback_binary, bundle_source)
    check(fallback_path not in fallback_binary.read_bytes() and b"/Users/" not in fallback_binary.read_bytes(), "SwiftPM build fallback was not neutralized")
    counts["positive"] += 1

    release_source = (script_dir / "release.py").read_text(encoding="utf-8")
    check('"/usr/bin/xattr", "-d"' not in release_source and '"xattr", "-c"' not in release_source, "production release code contains a fixture-only xattr sanitizer")
    publish_source = release_source[release_source.index("def publish_release"):]
    check(publish_source.index("verify_artifacts(args, output_dir, unsigned=False, approved_manifest_bytes=inputs[\"manifest_bytes\"])") < publish_source.index("open_publication_assets(output_dir, expected_names)"), "publish pins assets after verification")
    check("[str(path) for path in assets]" not in publish_source and "upload_release_asset_descriptor" in publish_source, "publish does not upload pinned descriptors")
    check("artifact-inventory.json" in release_source and "SHA256SUMS.sig" in release_source, "publish does not retain the inventory and detached signature assets")

    publication_aba_root = temporary_root / "publication-aba"
    shutil.copytree(output_one, publication_aba_root)
    publication_names = {path.name for path in publication_aba_root.iterdir()}
    publication_directory_fd, publication_directory_identity, publication_assets = tooling.open_publication_assets(publication_aba_root, publication_names)
    try:
        publication_target = publication_aba_root / sorted(publication_names)[0]
        replacement = publication_target.with_name(".publication-replacement")
        write(replacement, publication_target.read_bytes(), mode=0o644)
        publication_target.unlink()
        os.replace(replacement, publication_target)
        try:
            tooling.verify_publication_assets(publication_aba_root, publication_directory_fd, publication_directory_identity, publication_assets)
        except tooling.ReleaseError:
            counts["handoff"] += 1
        else:
            raise AssertionError("publication ABA replacement was accepted")
    finally:
        for asset in publication_assets:
            os.close(asset["descriptor"])
        os.close(publication_directory_fd)

    def expect_output_attack(label, mutate):
        target = Path(tempfile.mkdtemp(prefix="syrinx-output-attack-", dir="/tmp"))
        shutil.rmtree(target)
        try:
            shutil.copytree(output_one, target)
            mutate(target)
            attack_env = dict(env)
            attack_env["RELEASE_OUTPUT_DIR"] = str(target)
            code, stdout, stderr = run_cli(core, ["verify", "--unsigned-dry-run"], attack_env)
            check(code != 0, label + " output attack was accepted")
            check(not marker.exists(), label + " caused an external publication tool call")
            counts["attack"] += 1
        finally:
            shutil.rmtree(target, ignore_errors=True)

    expect_output_attack("extra-file", lambda target: write(target / "unverified.txt", "must not publish\n"))
    expect_output_attack("extra-directory", lambda target: write(target / "unverified-dir" / "child", "must not publish\n"))
    expect_output_attack("extra-symlink", lambda target: os.symlink(target / "FixtureProduct.rb", target / "unverified-link"))
    expect_output_attack("extra-hardlink", lambda target: os.link(target / "FixtureProduct.rb", target / "unverified-hardlink"))

    def make_socket(target):
        socket_path = target / "unverified-socket"
        sock = socket.socket(socket.AF_UNIX)
        try:
            sock.bind(str(socket_path))
        finally:
            sock.close()

    expect_output_attack("extra-socket", make_socket)

    for missing_name in sorted(json.loads((output_one / "artifact-inventory.json").read_text(encoding="utf-8"))["artifacts"] and [item["name"] for item in json.loads((output_one / "artifact-inventory.json").read_text(encoding="utf-8"))["artifacts"]]):
        expect_output_attack("missing-" + missing_name, lambda target, name=missing_name: (target / name).unlink())

    def arbitrary_inventory(target):
        inventory_path = target / "artifact-inventory.json"
        value = json.loads(inventory_path.read_text(encoding="utf-8"))
        write(target / "unverified-inventory-artifact", "not reviewed\n")
        value["artifacts"].append({"name": "unverified-inventory-artifact", "size": 14, "sha256": hashlib.sha256(b"not reviewed\n").hexdigest()})
        write(inventory_path, json.dumps(value, sort_keys=True, indent=2) + "\n")

    expect_output_attack("arbitrary-self-inventory", arbitrary_inventory)

    def replace_with_hardlink(target):
        original = target / "FixtureProduct.rb"
        sentinel = temporary_root / "formula-hardlink-sentinel"
        write(sentinel, original.read_bytes(), mode=0o644)
        original.unlink()
        os.link(sentinel, original)

    expect_output_attack("hardlink-replacement", replace_with_hardlink)
    expect_output_attack("symlink-replacement", lambda target: (target / "FixtureProduct.rb").unlink() or os.symlink(output_one / "FixtureProduct.rb", target / "FixtureProduct.rb"))

    oversized_inventory_root = temporary_root / "oversized-inventory"
    shutil.copytree(output_one, oversized_inventory_root)
    write(oversized_inventory_root / "artifact-inventory.json", "{" + "x" * (1024 * 1024 + 1) + "}")
    try:
        tooling.read_inventory(oversized_inventory_root / "artifact-inventory.json")
    except tooling.ReleaseError:
        counts["attack"] += 1
    else:
        raise AssertionError("oversized inventory was accepted")

    replacement_root = temporary_root / "inventory-replacement"
    shutil.copytree(output_one, replacement_root)
    replacement_inventory = replacement_root / "artifact-inventory.json"
    replacement_sentinel = temporary_root / "replacement-sentinel.json"
    write(replacement_sentinel, "{}", mode=0o600)
    original_open = tooling.os.open

    def replace_before_open(path, flags, *args, **kwargs):
        if str(path) == str(replacement_inventory):
            replacement_inventory.unlink()
            os.symlink(replacement_sentinel, replacement_inventory)
        return original_open(path, flags, *args, **kwargs)

    tooling.os.open = replace_before_open
    try:
        try:
            tooling.read_inventory(replacement_inventory)
        except tooling.ReleaseError:
            counts["attack"] += 1
        else:
            raise AssertionError("inventory replacement race was accepted")
    finally:
        tooling.os.open = original_open

    rewrite_root = temporary_root / "in-place-rewrite"
    shutil.copytree(output_one, rewrite_root)
    rewrite_inventory = rewrite_root / "artifact-inventory.json"
    original_read = tooling.os.read
    rewrite_once = [True]

    def rewrite_during_read(descriptor, size):
        if rewrite_once[0]:
            rewrite_once[0] = False
            with rewrite_inventory.open("ab") as handle:
                handle.write(b"\n")
        return original_read(descriptor, size)

    tooling.os.read = rewrite_during_read
    try:
        try:
            tooling.read_inventory(rewrite_inventory)
        except tooling.ReleaseError:
            counts["attack"] += 1
        else:
            raise AssertionError("same-inode in-place rewrite was accepted")
    finally:
        tooling.os.read = original_read

    def change_inventory_identity(target):
        inventory_path = target / "artifact-inventory.json"
        value = json.loads(inventory_path.read_text(encoding="utf-8"))
        value["productIdentity"] = "OtherProduct"
        write(inventory_path, json.dumps(value, sort_keys=True, indent=2) + "\n")

    expect_output_attack("inventory-identity", change_inventory_identity)

    output_two = temporary_root / "out-two"
    env["RELEASE_OUTPUT_DIR"] = str(output_two)
    code, stdout, stderr = run_cli(core, ["build", "--unsigned-dry-run"], env)
    check(code == 0, "second deterministic dry run failed: " + stderr)
    for first in sorted(output_one.iterdir()):
        second = output_two / first.name
        check(second.is_file() and hashlib.sha256(first.read_bytes()).digest() == hashlib.sha256(second.read_bytes()).digest(), "artifact is not deterministic: " + first.name)
    counts["positive"] += 1

    def expect_failure(changes, label):
        changed = dict(env)
        changed.update(changes)
        code, stdout, stderr = run_cli(core, ["build", "--unsigned-dry-run"], changed)
        check(code != 0 and "release error:" in stderr, label + " did not fail closed")
        return stderr

    expect_failure({"RELEASE_SOURCE_LICENSE": "missing-license"}, "missing source license")
    counts["negative"] += 1
    expect_failure({"RELEASE_SOURCE_COMMIT": "c" * 40}, "wrong source commit")
    counts["negative"] += 1
    expect_failure({"RELEASE_PRODUCT_IDENTITY": "placeholder"}, "placeholder identity")
    counts["negative"] += 1

    external_metadata = temporary_root / "external-notices.md"
    write(external_metadata, "external metadata\n")
    expect_failure({"RELEASE_NOTICES": str(external_metadata)}, "absolute external metadata")
    counts["negative"] += 1
    code, stdout, stderr = run_cli(core, ["build"], env)
    check(code != 0, "missing signing mode did not fail")
    counts["negative"] += 1
    code, stdout, stderr = run_cli(core, ["build", "--unsigned-dry-run", "--unknown-option"], env)
    check(code != 0, "unknown option did not fail")
    counts["negative"] += 1

    valid_manifest = manifest()
    attack_values = []
    path_attack = json.loads(json.dumps(valid_manifest))
    path_attack["files"][0]["relativePath"] = "../escape"
    attack_values.append(path_attack)
    absolute_attack = json.loads(json.dumps(valid_manifest))
    absolute_attack["files"][0]["relativePath"] = "/tmp/escape"
    attack_values.append(absolute_attack)
    mutable_attack = json.loads(json.dumps(valid_manifest))
    mutable_attack["files"][0]["url"] = "https://models.example.test/fixture/resolve/main/metadata.json"
    attack_values.append(mutable_attack)
    branch_commit_attack = json.loads(json.dumps(valid_manifest))
    branch_commit_attack["files"][0]["url"] = "https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml/resolve/main-" + ("d" * 40) + "/metadata.json"
    attack_values.append(branch_commit_attack)
    filename_commit_attack = json.loads(json.dumps(valid_manifest))
    filename_commit_attack["files"][0]["url"] = "https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml/resolve/main/metadata-" + ("d" * 40) + ".json"
    attack_values.append(filename_commit_attack)
    query_attack = json.loads(json.dumps(valid_manifest))
    query_attack["files"][0]["url"] += "?download=1"
    attack_values.append(query_attack)
    fragment_attack = json.loads(json.dumps(valid_manifest))
    fragment_attack["files"][0]["url"] += "#mutable"
    attack_values.append(fragment_attack)
    unsupported_host_attack = json.loads(json.dumps(valid_manifest))
    unsupported_host_attack["files"][0]["url"] = "https://evil.example.test/FluidInference/parakeet-tdt-0.6b-v3-coreml/resolve/" + ("d" * 40) + "/metadata.json"
    attack_values.append(unsupported_host_attack)
    wrong_model_attack = json.loads(json.dumps(valid_manifest))
    wrong_model_attack["modelId"] = "other-model"
    attack_values.append(wrong_model_attack)
    wrong_fluid_audio_attack = json.loads(json.dumps(valid_manifest))
    wrong_fluid_audio_attack["fluidAudioCompatibility"]["commit"] = "b" * 40
    attack_values.append(wrong_fluid_audio_attack)
    wrong_size_attack = json.loads(json.dumps(valid_manifest))
    wrong_size_attack["files"][0]["size"] += 1
    attack_values.append(wrong_size_attack)
    extra_file_attack = json.loads(json.dumps(valid_manifest))
    extra_file_attack["files"].append(dict(extra_file_attack["files"][0], relativePath="extra.json", url=extra_file_attack["files"][0]["url"].replace("Decoder.mlmodelc/analytics/coremldata.bin", "extra.json")))
    attack_values.append(extra_file_attack)
    duplicate_url_attack = json.loads(json.dumps(valid_manifest))
    duplicate_url_attack["files"][1]["url"] = duplicate_url_attack["files"][0]["url"]
    attack_values.append(duplicate_url_attack)
    summary_attack = json.loads(json.dumps(valid_manifest))
    summary_attack["hashVerificationSummary"]["fileCount"] = 20
    attack_values.append(summary_attack)
    review_attack = json.loads(json.dumps(valid_manifest))
    review_attack["license"]["reviewStatus"] = "release review required"
    attack_values.append(review_attack)
    digest_attack = json.loads(json.dumps(valid_manifest))
    digest_attack["manifestContentDigest"]["hex"] = "0" * 64
    attack_values.append(digest_attack)
    for attack in attack_values:
        try:
            tooling.validate_manifest(attack)
        except tooling.ReleaseError:
            counts["attack"] += 1
        else:
            raise AssertionError("manifest attack was accepted")

    symlink_manifest = root / "ModelManifests" / "symlink.json"
    os.symlink(root / "ModelManifests" / "fixture.json", symlink_manifest)
    env["RELEASE_MODEL_MANIFEST"] = "ModelManifests/symlink.json"
    expect_failure({}, "symlink model manifest")
    counts["attack"] += 1
    symlink_manifest.unlink()
    env["RELEASE_MODEL_MANIFEST"] = "ModelManifests/fixture.json"

    license_symlink = root / "LICENSES" / "symlink.txt"
    os.symlink(root / "LICENSE", license_symlink)
    expect_failure({}, "symlink in license tree")
    counts["attack"] += 1
    license_symlink.unlink()

    license_hardlink = root / "LICENSES" / "hardlink.txt"
    os.link(root / "LICENSE", license_hardlink)
    expect_failure({}, "hard link in license tree")
    counts["attack"] += 1
    license_hardlink.unlink()

    untracked_notice = root / "untracked-notices.md"
    write(untracked_notice, "untracked\n")
    expect_failure({"RELEASE_NOTICES": "untracked-notices.md"}, "untracked metadata")
    counts["attack"] += 1
    untracked_notice.unlink()

    tampered = temporary_root / "tampered-output"
    shutil.copytree(output_one, tampered)
    tampered_archive = tampered / "FixtureProduct-1.2.3.tar.gz"
    tampered_archive.write_bytes(tampered_archive.read_bytes() + b"tampered")
    tampered_env = dict(env)
    tampered_env["RELEASE_OUTPUT_DIR"] = str(tampered)
    code, stdout, stderr = run_cli(core, ["verify", "--unsigned-dry-run"], tampered_env)
    check(code != 0 and "digest" in stderr.lower(), "tampered downloaded artifact was accepted")
    counts["attack"] += 1

    try:
        tooling.validate_payload_listing("", {"./payload": "file"})
    except tooling.ReleaseError:
        counts["attack"] += 1
    else:
        raise AssertionError("empty package payload listing was accepted")
    try:
        tooling.parse_notary_result('{"status":"Rejected"}')
    except tooling.ReleaseError:
        counts["negative"] += 1
    else:
        raise AssertionError("rejected notary result was accepted")
    model_extensions = ("mlmodel", "mlmodelc", "mlpackage", "safetensors", "onnx", "pt", "pth", "bin", "mil")
    for index, extension in enumerate(model_extensions):
        model_payload = temporary_root / ("model-payload-%d" % index)
        model_path = model_payload / ("nested.%s" % extension)
        if extension in ("mlmodelc", "mlpackage"):
            model_path = model_path / "weights.bin"
        write(model_path, "not a real model")
        try:
            tooling.ensure_safe_tree(model_payload)
        except tooling.ReleaseError:
            counts["attack"] += 1
        else:
            raise AssertionError("model-byte payload attack was accepted: " + extension)

    large_clean = temporary_root / "large-clean.bin"
    with large_clean.open("wb") as handle:
        handle.write(b"A" * (32 * 1024 * 1024 + 4096))
    tooling.scan_file_stream(large_clean, "large clean fixture")
    split_marker = temporary_root / "split-marker.bin"
    with split_marker.open("wb") as handle:
        handle.write(b"A" * (1024 * 1024 - 3) + b"Syrinx" + b"B")
    try:
        tooling.scan_file_stream(split_marker, "split marker fixture")
    except tooling.ReleaseError:
        counts["attack"] += 1
    else:
        raise AssertionError("boundary-split placeholder was accepted")
    compressed_placeholder = temporary_root / "compressed-placeholder.tar.gz"
    with tarfile.open(compressed_placeholder, "w:gz") as tar:
        info = tarfile.TarInfo("safe.txt")
        info.size = len(b"Syrinx")
        tar.addfile(info, io.BytesIO(b"Syrinx"))
    try:
        tooling.verify_archive_names(compressed_placeholder, scan_content=True)
    except tooling.ReleaseError:
        counts["attack"] += 1
    else:
        raise AssertionError("compressed placeholder was accepted")
    too_many_members = temporary_root / "too-many-members.tar.gz"
    with tarfile.open(too_many_members, "w:gz") as tar:
        for index in range(tooling.MAX_ARCHIVE_MEMBERS + 1):
            info = tarfile.TarInfo("member-%05d" % index)
            info.size = 0
            tar.addfile(info)
    try:
        tooling.verify_archive_names(too_many_members)
    except tooling.ReleaseError:
        counts["attack"] += 1
    else:
        raise AssertionError("excessive archive member count was accepted")
    oversized_member = temporary_root / "oversized-member.tar.gz"
    with tarfile.open(oversized_member, "w:gz") as tar:
        info = tarfile.TarInfo("oversized")
        info.size = tooling.MAX_ARCHIVE_MEMBER_BYTES + 1
        try:
            tar.addfile(info, io.BytesIO(b"x"))
        except (OSError, tarfile.TarError):
            pass
    try:
        tooling.verify_archive_names(oversized_member)
    except tooling.ReleaseError:
        counts["attack"] += 1
    else:
        raise AssertionError("oversized archive member was accepted")

    def make_tar_alias_fixture(path, members):
        with tarfile.open(path, "w:gz") as tar:
            for name, kind, data in members:
                info = tarfile.TarInfo(name)
                if kind == "directory":
                    info.type = tarfile.DIRTYPE
                    info.mode = 0o755
                    info.size = 0
                    tar.addfile(info)
                else:
                    info.mode = 0o644
                    info.size = len(data)
                    tar.addfile(info, io.BytesIO(data))

    tar_alias_cases = {
        "tar-exact-duplicate": [("same.txt", "file", b"one"), ("same.txt", "file", b"two")],
        "tar-casefold-alias": [("Case/File", "file", b"one"), ("case/file", "file", b"two")],
        "tar-nfc-nfd-alias": [("caf\u00e9/file", "file", b"one"), ("cafe\u0301/file", "file", b"two")],
        "tar-nested-component-alias": [("root/Dir/one", "file", b"one"), ("ROOT/dir/two", "file", b"two")],
        "tar-file-directory-collision": [("same", "file", b"one"), ("same/", "directory", b"")],
    }
    for label, members in tar_alias_cases.items():
        archive_path = temporary_root / (label + ".tar.gz")
        extraction_path = temporary_root / (label + "-extract")
        make_tar_alias_fixture(archive_path, members)
        try:
            tooling.extract_safe_archive(archive_path, extraction_path)
        except tooling.ReleaseError:
            check(not extraction_path.exists(), "tar alias rejection wrote extraction output: " + label)
            counts["attack"] += 1
        else:
            raise AssertionError("tar alias was accepted: " + label)

    class NonSeekable:
        def __init__(self, data):
            self.data = data
        def read(self, size=-1):
            if not self.data:
                return b""
            value, self.data = self.data[:size], self.data[size:]
            return value
        def seek(self, *args):
            raise AssertionError("scanner attempted to seek a non-seekable stream")
    non_seekable_destination = temporary_root / "non-seekable-copy"
    with non_seekable_destination.open("wb") as destination:
        tooling.scan_stream(NonSeekable(b"non-seekable content"), "non-seekable member", {"used": 0}, writer=destination)
    check(non_seekable_destination.read_bytes() == b"non-seekable content", "non-seekable stream was not copied in one pass")
    absolute_marker = temporary_root / "absolute-marker.bin"
    write(absolute_marker, b"/private/tmp/build-output\n")
    try:
        tooling.scan_file_stream(absolute_marker, "absolute path fixture")
    except tooling.ReleaseError:
        counts["attack"] += 1
    else:
        raise AssertionError("absolute build path was accepted")

    closure_root = temporary_root / "runtime-closure"
    closure_root.mkdir()
    closure_binary = closure_root / "fixture-service"
    closure_dylib = closure_root / "libswiftCompatibilitySpan.dylib"
    write(closure_binary, "binary\n", mode=0o755)
    write(closure_dylib, "dylib\n")
    closure_args = tooling.argparse.Namespace(signing_keychain=None, team_id="FIXTUR1234", executable="fixture-service", application_identity="Developer ID Application: Fixture Product (FIXTUR1234)")
    original_run_tool = tooling.run_tool
    original_system_dependency = tooling.system_dependency_is_available

    def closure_run_tool(argv, cwd=None, timeout=tooling.MAX_TOOL_SECONDS, env=None, input_bytes=None):
        if argv[:2] == ["otool", "-L"]:
            path = Path(argv[-1])
            if path.resolve() == closure_binary.resolve():
                return 0, "fixture-service:\n\t@rpath/libswiftCompatibilitySpan.dylib (compatibility version 1.0.0, current version 1.0.0)\n\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1.0.0)\n", ""
            return 0, "libswiftCompatibilitySpan.dylib:\n\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1.0.0)\n", ""
        if argv[:2] == ["otool", "-l"]:
            return 0, "Load command 1\n          path @loader_path (offset 12)\n", ""
        if argv[0] == "codesign" and "--verify" in argv:
            return 0, "", "valid on disk"
        if argv[0] == "codesign" and "-dv" in argv:
            return 0, "", "flags=0x10000(runtime)\nTimestamp=2026-08-14\nTeamIdentifier=FIXTUR1234\nAuthority=Developer ID Application: Fixture Product (FIXTUR1234)"
        if argv[0] == "codesign" and "-d" in argv and "-r-" in argv:
            return 0, "", "designated => anchor apple generic and identifier \"fixture-service\""
        raise AssertionError("unexpected closure tool: " + " ".join(argv))

    tooling.run_tool = closure_run_tool
    tooling.system_dependency_is_available = lambda value: value in tooling.SYSTEM_DEPENDENCY_CONTRACT
    try:
        tooling.verify_signed_closure(closure_args, closure_binary, closure_root)
        counts["positive"] += 1
        unresolved = closure_binary

        def unresolved_run_tool(argv, cwd=None, timeout=tooling.MAX_TOOL_SECONDS, env=None, input_bytes=None):
            if argv[:2] == ["otool", "-L"]:
                return 0, "fixture-service:\n\t@rpath/missing-compatibility.dylib (compatibility version 1.0.0, current version 1.0.0)\n", ""
            if argv[:2] == ["otool", "-l"]:
                return 0, "Load command 1\n          path @loader_path (offset 12)\n", ""
            raise AssertionError("unexpected unresolved closure tool: " + " ".join(argv))

        tooling.run_tool = unresolved_run_tool
        try:
            tooling.dynamic_closure(unresolved, closure_root)
        except tooling.ReleaseError:
            counts["attack"] += 1
        else:
            raise AssertionError("unresolved compatibility dylib was accepted")
        nonexistent = closure_binary

        def nonexistent_run_tool(argv, cwd=None, timeout=tooling.MAX_TOOL_SECONDS, env=None, input_bytes=None):
            if argv[:2] == ["otool", "-L"]:
                return 0, "fixture-service:\n\t/usr/lib/not-a-real-system-library.dylib (compatibility version 1.0.0, current version 1.0.0)\n", ""
            if argv[:2] == ["otool", "-l"]:
                return 0, "Load command 1\n          path @loader_path (offset 12)\n", ""
            raise AssertionError("unexpected nonexistent dependency tool: " + " ".join(argv))

        tooling.run_tool = nonexistent_run_tool
        try:
            tooling.dynamic_closure(nonexistent, closure_root)
        except tooling.ReleaseError:
            counts["attack"] += 1
        else:
            raise AssertionError("nonexistent system dependency was accepted")
    finally:
        tooling.run_tool = original_run_tool
        tooling.system_dependency_is_available = original_system_dependency

    check(tooling.system_dependency_is_available("/usr/lib/libSystem.B.dylib"), "reviewed dyld shared-cache dependency was not accepted")
    check(not tooling.system_dependency_is_available("/usr/lib/not-a-real-system-library.dylib"), "arbitrary system dependency was accepted")

    for unsafe_rpath in ("@loader_path/../../../../tmp", "@loader_path/../..", "/opt/homebrew/lib", "/Applications/Xcode.app/Contents/Developer/Toolchains"):
        def unsafe_rpath_run_tool(argv, cwd=None, timeout=tooling.MAX_TOOL_SECONDS, env=None, input_bytes=None, rpath=unsafe_rpath):
            if argv[:2] == ["otool", "-l"]:
                return 0, "Load command 1\n          path %s (offset 12)\n" % rpath, ""
            return closure_run_tool(argv, cwd=cwd, timeout=timeout, env=env, input_bytes=input_bytes)
        tooling.run_tool = unsafe_rpath_run_tool
        try:
            tooling.dynamic_closure(closure_binary, closure_root)
        except tooling.ReleaseError:
            counts["attack"] += 1
        else:
            raise AssertionError("unsafe dynamic rpath was accepted: " + unsafe_rpath)

    relative_root = temporary_root / "relative-rpath-closure"
    relative_root.mkdir()
    relative_binary = relative_root / "fixture-service"
    relative_library = relative_root / "libs" / "libswiftCompatibilitySpan.dylib"
    write(relative_binary, "binary\n", mode=0o755)
    write(relative_library, "dylib\n")

    def relative_rpath_run_tool(argv, cwd=None, timeout=tooling.MAX_TOOL_SECONDS, env=None, input_bytes=None):
        if argv[:2] == ["otool", "-L"]:
            path = Path(argv[-1])
            if path.resolve() == relative_binary.resolve():
                return 0, "fixture-service:\n\t@rpath/libswiftCompatibilitySpan.dylib (compatibility version 1.0.0, current version 1.0.0)\n", ""
            return 0, "libswiftCompatibilitySpan.dylib:\n\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1.0.0)\n", ""
        if argv[:2] == ["otool", "-l"]:
            return 0, "Load command 1\n          path @loader_path/libs (offset 12)\n", ""
        raise AssertionError("unexpected relative rpath tool: " + " ".join(argv))

    tooling.run_tool = relative_rpath_run_tool
    tooling.dynamic_closure(relative_binary, relative_root)
    tooling.run_tool = original_run_tool
    counts["positive"] += 1

    sanitized_root = temporary_root / "sanitized-rpath-closure"
    sanitized_root.mkdir()
    sanitized_binary = sanitized_root / "fixture-service"
    sanitized_library = sanitized_root / "libswiftCompatibilitySpan.dylib"
    write(sanitized_binary, "binary\n", mode=0o755)
    write(sanitized_library, "dylib\n")
    sanitizer_calls = []

    def sanitizer_run_tool(argv, cwd=None, timeout=tooling.MAX_TOOL_SECONDS, env=None, input_bytes=None):
        if argv[:2] == ["otool", "-L"]:
            path = Path(argv[-1])
            if path.resolve() == sanitized_binary.resolve():
                return 0, "fixture-service:\n\t@rpath/libswiftCompatibilitySpan.dylib (compatibility version 1.0.0, current version 1.0.0)\n", ""
            return 0, "libswiftCompatibilitySpan.dylib:\n\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1.0.0)\n", ""
        if argv[:2] == ["otool", "-l"]:
            return 0, "Load command 1\n          path /usr/lib/swift (offset 12)\nLoad command 2\n          path @loader_path (offset 12)\nLoad command 3\n          path /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift-6.2/macosx (offset 12)\n", ""
        if argv[0] == "install_name_tool":
            sanitizer_calls.append(list(argv))
            return 0, "", ""
        raise AssertionError("unexpected runtime sanitizer tool: " + " ".join(argv))

    tooling.run_tool = sanitizer_run_tool
    try:
        tooling.sanitize_runtime_rpaths(closure_args, sanitized_root, sanitized_binary)
    finally:
        tooling.run_tool = original_run_tool
    check(any(call[1:3] == ["-delete_rpath", "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift-6.2/macosx"] for call in sanitizer_calls), "Xcode runtime rpath was not removed")
    check(any(call[1:3] == ["-delete_rpath", "/usr/lib/swift"] for call in sanitizer_calls), "system runtime rpath was not normalized")
    check(any(call[1:3] == ["-add_rpath", "/usr/lib/swift"] for call in sanitizer_calls), "reviewed system runtime rpath was not preserved")
    check(not any(call[1:3] == ["-delete_rpath", "@loader_path"] for call in sanitizer_calls), "payload-relative rpath was removed")
    counts["positive"] += 1

    versioned_rpath_root = temporary_root / "versioned-rpath-closure"
    versioned_executable = versioned_rpath_root / "Library" / "Application Support" / "FixtureProduct" / "versions" / "1.2.3" / "fixture-service"
    versioned_executable.parent.mkdir(parents=True)
    write(versioned_executable, "binary\n", mode=0o755)
    expanded_executable_paths = []

    def versioned_rpath_run_tool(argv, cwd=None, timeout=tooling.MAX_TOOL_SECONDS, env=None, input_bytes=None):
        if argv[:2] == ["otool", "-L"]:
            return 0, "fixture-service:\n\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1.0.0)\n", ""
        if argv[:2] == ["otool", "-l"]:
            return 0, "Load command 1\n          path @executable_path/../libs (offset 12)\n", ""
        raise AssertionError("unexpected versioned rpath tool: " + " ".join(argv))

    original_prohibited_path = tooling.prohibited_library_path
    original_expand_loader_token = tooling.expand_loader_token

    def record_expanded_path(value, owner, executable):
        expanded = original_expand_loader_token(value, owner, executable)
        expanded_executable_paths.append(expanded)
        return expanded

    tooling.run_tool = versioned_rpath_run_tool
    tooling.expand_loader_token = record_expanded_path
    try:
        tooling.sanitize_runtime_rpaths(closure_args, versioned_rpath_root, versioned_executable)
    finally:
        tooling.run_tool = original_run_tool
        tooling.prohibited_library_path = original_prohibited_path
        tooling.expand_loader_token = original_expand_loader_token
    expected_expanded = str(versioned_executable.parent / "../libs")
    check(expected_expanded in expanded_executable_paths, "@executable_path did not resolve against the versioned executable")
    check(str(versioned_rpath_root / "../libs") not in expanded_executable_paths, "@executable_path resolved against the payload root")
    counts["positive"] += 1

    signature_args = tooling.argparse.Namespace(installer_identity="Developer ID Installer: Fixture Product (FIXTUR1234)", team_id="FIXTUR1234")
    valid_package_signature = "Status: signed by a certificate trusted by Mac OS X\nDeveloper ID Installer: Fixture Product (FIXTUR1234)\n"
    tooling.validate_package_signature(valid_package_signature, signature_args)
    for bad_signature in (
        "Status: signed\nDeveloper ID Application: Fixture Product (FIXTUR1234)\n",
        "Status: signed\nDeveloper ID Installer: Other Product (FIXTUR1234)\n",
        "Status: signed\nadhoc signature\n",
    ):
        try:
            tooling.validate_package_signature(bad_signature, signature_args)
        except tooling.ReleaseError:
            counts["attack"] += 1
        else:
            raise AssertionError("invalid package certificate was accepted")

    binary.chmod(0o775)
    cleanup_output = temporary_root / "out-cleanup"
    env["RELEASE_OUTPUT_DIR"] = str(cleanup_output)
    code, stdout, stderr = run_cli(core, ["build", "--unsigned-dry-run"], env)
    check(code != 0, "writable executable was accepted")
    check(not list(temporary_root.glob("release-build-*")), "temporary release directory was not cleaned")
    counts["cleanup"] += 1
    binary.chmod(0o755)

    try:
        tooling.run_tool([sys.executable, "-c", "import time; time.sleep(2)"], timeout=1)
    except tooling.ReleaseError as error:
        check("timed out" in str(error), "timeout did not report a bounded timeout")
        counts["timeout"] += 1
    else:
        raise AssertionError("timeout case unexpectedly passed")

    child_pid_file = temporary_root / "child.pid"
    child_code = "import os,sys,subprocess,time; child=subprocess.Popen([sys.executable,'-c','import time; time.sleep(10)']); open(sys.argv[1],'w').write(str(child.pid)); time.sleep(10)"
    try:
        tooling.run_tool([sys.executable, "-c", child_code, str(child_pid_file)], timeout=1)
    except tooling.ReleaseError as error:
        check("timed out" in str(error), "descendant timeout did not report a bounded timeout")
        child_pid = int(child_pid_file.read_text(encoding="utf-8"))
        alive = True
        for _ in range(20):
            try:
                os.kill(child_pid, 0)
            except ProcessLookupError:
                alive = False
                break
            time.sleep(0.05)
        check(not alive, "timed-out descendant survived process-group cleanup")
        counts["descendant"] += 1
    else:
        raise AssertionError("descendant timeout unexpectedly passed")

    original_run_tool = tooling.run_tool
    signing_events = []
    current_keychains = ["/Users/fixture/Library/Keychains/old.keychain-db"]

    def stub_run_tool(argv, cwd=None, timeout=tooling.MAX_TOOL_SECONDS, env=None, input_bytes=None):
        global current_keychains
        signing_events.append(list(argv))
        if argv[:3] == ["security", "list-keychains", "-d"]:
            if "-s" in argv:
                index = argv.index("-s") + 1
                current_keychains = list(argv[index:])
                return 0, "", ""
            return 0, "".join('"%s"\n' % value for value in current_keychains), ""
        if argv[:2] == ["security", "create-keychain"]:
            Path(argv[-1]).touch(mode=0o600)
        if argv[:2] == ["security", "delete-keychain"]:
            Path(argv[-1]).unlink(missing_ok=True)
        return 0, "", ""

    signing_temp = temporary_root / "signing-temp"
    signing_temp.mkdir()
    signing_args = tooling.argparse.Namespace(
        runner_temp=str(signing_temp), signing_state=str(signing_temp / "state.json"), signing_keychain=str(signing_temp / "release.keychain-db"), cleanup_plan=str(signing_temp / "cleanup-plan.json"),
        application_certificate_base64=base64.b64encode(b"application-p12").decode(), installer_certificate_base64=base64.b64encode(b"installer-p12").decode(),
        application_certificate_password="app-pass", installer_certificate_password="installer-pass",
        notary_credentials_base64=base64.b64encode(json.dumps({"appleId":"fixture@example.test","teamId":"FIXTUR1234","password":"notary-pass"}).encode()).decode(),
        notary_profile="fixture-profile", team_id="FIXTUR1234", application_certificate_path=str(signing_temp / "app.p12"),
        installer_certificate_path=str(signing_temp / "installer.p12"), signature_private_key_base64=base64.b64encode(b"private").decode(),
        signature_public_key_base64=base64.b64encode(b"public").decode(), signature_private_key_path=str(signing_temp / "private.pem"),
        signature_public_key_path=str(signing_temp / "public.pem"), github_env=str(signing_temp / "github.env"),
    )
    tooling.run_tool = stub_run_tool
    try:
        try:
            tooling.prepare_signing(signing_args)
            raise RuntimeError("stubbed signing build failure")
        except RuntimeError:
            pass
    finally:
        tooling.cleanup_signing(tooling.argparse.Namespace(
            runner_temp=str(signing_temp),
            signing_state=signing_args.signing_state,
            trusted_keychain=signing_args.signing_keychain,
            cleanup_plan=signing_args.cleanup_plan,
            trusted_profile="fixture-profile",
            application_certificate_path=signing_args.application_certificate_path,
            installer_certificate_path=signing_args.installer_certificate_path,
            signature_private_key_path=signing_args.signature_private_key_path,
            signature_public_key_path=signing_args.signature_public_key_path,
            old_keychains=json.dumps(["/Users/fixture/Library/Keychains/old.keychain-db"]),
        ))
        tooling.run_tool = original_run_tool
    check(any(event[:2] == ["security", "delete-keychain"] for event in signing_events), "cleanup did not delete the temporary keychain after failure")
    check(not any(path.exists() for path in (Path(signing_args.signing_state), Path(signing_args.signing_keychain), Path(signing_args.application_certificate_path), Path(signing_args.signature_private_key_path))), "signing cleanup left temporary material")
    counts["cleanup"] += 1

    for boundary in ("create-keychain", "list-keychains -s", "security import", "set-key-partition-list", "store-credentials"):
        boundary_root = temporary_root / ("killed-prepare-" + boundary.replace(" ", "-"))
        boundary_root.mkdir()
        boundary_args = tooling.argparse.Namespace(**vars(signing_args))
        boundary_args.runner_temp = str(boundary_root)
        boundary_args.signing_state = str(boundary_root / "state.json")
        boundary_args.signing_keychain = str(boundary_root / "release.keychain-db")
        boundary_args.cleanup_plan = str(boundary_root / "cleanup-plan.json")
        boundary_args.application_certificate_path = str(boundary_root / "app.p12")
        boundary_args.installer_certificate_path = str(boundary_root / "installer.p12")
        boundary_args.signature_private_key_path = str(boundary_root / "private.pem")
        boundary_args.signature_public_key_path = str(boundary_root / "public.pem")
        boundary_args.github_env = str(boundary_root / "github.env")
        fired = [False]
        def failing_prepare_tool(argv, cwd=None, timeout=tooling.MAX_TOOL_SECONDS, env=None, input_bytes=None):
            rendered = " ".join(argv)
            should_fail = ((boundary == "security import" and argv[:2] == ["security", "import"]) or (boundary == "list-keychains -s" and argv[:3] == ["security", "list-keychains", "-d"] and "-s" in argv) or (boundary == "create-keychain" and argv[:2] == ["security", "create-keychain"]) or (boundary == "set-key-partition-list" and argv[:3] == ["security", "set-key-partition-list", "-S"]) or (boundary == "store-credentials" and argv[:3] == ["xcrun", "notarytool", "store-credentials"]))
            if not fired[0] and should_fail:
                fired[0] = True
                raise tooling.ReleaseError("fixture killed prepare at " + boundary)
            return stub_run_tool(argv, cwd=cwd, timeout=timeout, env=env, input_bytes=input_bytes)
        current_keychains[:] = ["/Users/fixture/Library/Keychains/old.keychain-db"]
        tooling.run_tool = failing_prepare_tool
        try:
            try:
                tooling.prepare_signing(boundary_args)
            except tooling.ReleaseError:
                pass
            else:
                raise AssertionError("prepare failure boundary was accepted: " + boundary)
        finally:
            tooling.run_tool = original_run_tool
        check(not any(path.exists() for path in (Path(boundary_args.signing_state), Path(boundary_args.signing_keychain), Path(boundary_args.cleanup_plan), Path(boundary_args.application_certificate_path), Path(boundary_args.signature_private_key_path))), "killed prepare left resources at: " + boundary)
        counts["cleanup"] += 1

    trusted_cleanup_root = temporary_root / "trusted-cleanup-fixtures"
    trusted_cleanup_root.mkdir()
    trusted_keychain = trusted_cleanup_root / "trusted.keychain-db"
    trusted_plan = trusted_cleanup_root / "trusted-plan.json"
    trusted_state = trusted_cleanup_root / "trusted-state.json"
    trusted_file = trusted_cleanup_root / "trusted.pem"
    write(trusted_file, "fixture key\n", mode=0o600)
    trusted_keychain.touch(mode=0o600)
    trusted_old_keychains = ["/Users/fixture/Library/Keychains/old.keychain-db"]
    trusted_document = {
        "schemaVersion": 1,
        "keychain": str(trusted_keychain),
        "oldKeychains": trusted_old_keychains,
        "temporaryFiles": [str(trusted_file)],
        "profile": "fixture-profile",
    }
    write(trusted_plan, json.dumps(trusted_document), mode=0o600)
    current_keychains = ["/Users/fixture/Library/Keychains/unexpected.keychain-db"]
    tooling.run_tool = stub_run_tool
    try:
        tooling.cleanup_signing_state(
            trusted_state,
            trusted_keychain,
            trusted_cleanup_root,
            [trusted_file],
            trusted_old_keychains,
            trusted_plan,
            "fixture-profile",
        )
    except tooling.ReleaseError:
        pass
    else:
        raise AssertionError("missing signing state was accepted")
    check(not trusted_keychain.exists(), "missing signing state did not delete the exact trusted keychain")
    check(trusted_plan.exists(), "failed missing-state cleanup did not retain its trusted retry plan")
    write(trusted_state, json.dumps(trusted_document), mode=0o600)
    tooling.cleanup_signing_state(
        trusted_state,
        trusted_keychain,
        trusted_cleanup_root,
        [trusted_file],
        trusted_old_keychains,
        trusted_plan,
        "fixture-profile",
    )
    check(not trusted_plan.exists() and not trusted_state.exists() and not trusted_file.exists(), "cleanup retry did not finish trusted cleanup")
    counts["cleanup"] += 1

    for state_label, state_bytes in (
        ("corrupt", b"{not-json"),
        ("truncated", b'{"schemaVersion":1,"temporaryFiles":['),
    ):
        attack_root = trusted_cleanup_root / state_label
        attack_root.mkdir()
        chain = attack_root / "trusted.keychain-db"
        plan = attack_root / "trusted-plan.json"
        state = attack_root / "trusted-state.json"
        file_path = attack_root / "trusted.pem"
        outside = temporary_root / ("cleanup-outside-" + state_label)
        write(outside, "outside\n", mode=0o600)
        chain.touch(mode=0o600)
        write(file_path, "fixture\n", mode=0o600)
        document = {"schemaVersion": 1, "keychain": str(chain), "oldKeychains": [], "temporaryFiles": [str(file_path)], "profile": "fixture-profile"}
        write(plan, json.dumps(document), mode=0o600)
        write(state, state_bytes, mode=0o600)
        try:
            tooling.cleanup_signing_state(state, chain, attack_root, [file_path], [], plan, "fixture-profile")
        except tooling.ReleaseError:
            pass
        else:
            raise AssertionError("invalid trusted cleanup state was accepted: " + state_label)
        check(not chain.exists() and outside.exists(), "invalid cleanup state touched an unrelated path: " + state_label)
        counts["attack"] += 1

    replaced_root = trusted_cleanup_root / "replaced"
    replaced_root.mkdir()
    replaced_chain = replaced_root / "trusted.keychain-db"
    replaced_plan = replaced_root / "trusted-plan.json"
    replaced_state = replaced_root / "trusted-state.json"
    replaced_file = replaced_root / "trusted.pem"
    replaced_outside = temporary_root / "cleanup-outside-replaced"
    write(replaced_outside, "outside\n", mode=0o600)
    replaced_chain.touch(mode=0o600)
    write(replaced_file, "fixture\n", mode=0o600)
    replaced_document = {"schemaVersion": 1, "keychain": str(replaced_chain), "oldKeychains": [], "temporaryFiles": [str(replaced_file)], "profile": "fixture-profile"}
    write(replaced_plan, json.dumps(replaced_document), mode=0o600)
    os.symlink(replaced_outside, replaced_state)
    try:
        tooling.cleanup_signing_state(replaced_state, replaced_chain, replaced_root, [replaced_file], [], replaced_plan, "fixture-profile")
    except tooling.ReleaseError:
        pass
    else:
        raise AssertionError("replaced cleanup state was accepted")
    check(not replaced_chain.exists() and replaced_outside.exists(), "replaced cleanup state touched an unrelated path")
    counts["attack"] += 1

    def expect_bad_plan_cleanup(label, plan_kind):
        attack_root = trusted_cleanup_root / ("plan-" + label)
        attack_root.mkdir()
        chain = attack_root / "trusted.keychain-db"
        state = attack_root / "state.json"
        plan = attack_root / "cleanup-plan.json"
        credential = attack_root / "credential.p12"
        outside = temporary_root / ("plan-outside-" + label)
        chain.touch(mode=0o600)
        write(credential, "credential\n", mode=0o600)
        write(outside, "outside\n", mode=0o600)
        if plan_kind == "missing":
            pass
        elif plan_kind == "corrupt":
            write(plan, b"{not-json", mode=0o600)
        elif plan_kind == "truncated":
            write(plan, b'{"schemaVersion":1,"temporaryFiles":[', mode=0o600)
        elif plan_kind == "symlink":
            os.symlink(outside, plan)
        elif plan_kind == "hardlink":
            plan_source = attack_root / "plan-source.json"
            write(plan_source, b"{not-json", mode=0o600)
            os.link(plan_source, plan)
        elif plan_kind == "replaced":
            write(plan, b"{not-json", mode=0o600)
            plan.unlink()
            os.symlink(outside, plan)
        else:
            raise AssertionError("unknown plan fixture")
        current_keychains[:] = ["/Users/fixture/Library/Keychains/old.keychain-db", str(chain)]
        try:
            tooling.cleanup_signing_state(
                state,
                chain,
                attack_root,
                [credential],
                ["/Users/fixture/Library/Keychains/old.keychain-db"],
                plan,
                "fixture-profile",
            )
        except tooling.ReleaseError:
            pass
        else:
            raise AssertionError("unsafe cleanup plan was accepted: " + label)
        check(not chain.exists() and not credential.exists(), "trusted cleanup did not remove resources for plan state: " + label)
        check(current_keychains == ["/Users/fixture/Library/Keychains/old.keychain-db"], "cleanup did not preserve unrelated keychains: " + label)
        check(outside.exists(), "cleanup followed an untrusted plan target: " + label)
        counts["cleanup"] += 1

    for plan_label in ("missing", "corrupt", "truncated", "symlink", "hardlink", "replaced"):
        expect_bad_plan_cleanup(plan_label, plan_label)

    handoff_events = []
    handoff_original_run_tool = tooling.run_tool
    handoff_original_download = tooling.download_artifact_archive

    handoff_root = temporary_root / "artifact-handoff"
    handoff_root.mkdir()
    handoff_source = handoff_root / "source"
    handoff_source.mkdir()
    write(handoff_source / "payload.txt", "exact uploaded bytes\n")
    handoff_inventory = {
        "schemaVersion": 1,
        "productIdentity": "FixtureProduct",
        "version": "1.2.3",
        "tag": "v1.2.3",
        "sourceCommit": commit,
        "artifacts": [{"name": "payload.txt", "size": (handoff_source / "payload.txt").stat().st_size, "sha256": tooling.sha256_file(handoff_source / "payload.txt")}],
        "excludesSelf": True,
    }
    write(handoff_source / "artifact-inventory.json", json.dumps(handoff_inventory, sort_keys=True) + "\n")
    handoff_zip = handoff_root / "uploaded.zip"
    with zipfile.ZipFile(handoff_zip, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(handoff_source.iterdir()):
            archive.write(path, path.name)
    handoff_digest = hashlib.sha256(handoff_zip.read_bytes()).hexdigest()
    handoff_archive_destination = handoff_root / "downloaded.zip"
    handoff_output = handoff_root / "extracted"
    handoff_state = handoff_root / "handoff.json"

    def fake_download(repository, artifact_id, token, destination):
        check(repository == "fixture-owner/fixture-product" and artifact_id == "123" and token == "fixture-github-token", "handoff download inputs were not exact")
        shutil.copy2(handoff_zip, destination)

    tooling.download_artifact_archive = fake_download

    def handoff_run_tool(argv, cwd=None, timeout=tooling.MAX_TOOL_SECONDS, env=None, input_bytes=None):
        handoff_events.append(list(argv))
        if argv[0] == "gh":
            return 0, json.dumps({"id": 123, "digest": "sha256:" + handoff_digest}), ""
        raise AssertionError("unexpected privileged tool during artifact handoff: " + " ".join(argv))

    tooling.run_tool = handoff_run_tool
    try:
        tooling.verify_artifact_handoff("123", handoff_digest, "fixture-owner/fixture-product", "fixture-github-token", handoff_archive_destination, handoff_output, handoff_state, "v1.2.3", commit)
        tooling.verify_extracted_artifact_handoff(handoff_output, handoff_state, "v1.2.3", commit)
        handoff_output.joinpath("payload.txt").write_bytes(b"replacement\n")
        try:
            tooling.verify_extracted_artifact_handoff(handoff_output, handoff_state, "v1.2.3", commit)
        except tooling.ReleaseError:
            counts["handoff"] += 1
        else:
            raise AssertionError("post-handoff byte replacement was accepted")
        handoff_output.joinpath("payload.txt").write_bytes(b"exact uploaded bytes\n")
        for bad_id, bad_digest, label in (
            ("124", "a" * 64, "wrong-id"),
            ("123", "b" * 64, "digest-mismatch"),
            ("", "a" * 64, "missing-id"),
            ("123", "", "missing-digest"),
        ):
            try:
                tooling.verify_artifact_handoff(bad_id, bad_digest, "fixture-owner/fixture-product", "fixture-github-token", handoff_archive_destination, handoff_output, handoff_state, "v1.2.3", commit)
            except tooling.ReleaseError:
                counts["attack"] += 1
            else:
                raise AssertionError("artifact handoff attack was accepted: " + label)
        handoff_bad_digest = "b" * 64
        bad_digest_root = handoff_root / "raw-digest-mismatch"
        bad_digest_root.mkdir()
        handoff_run_tool_original_digest = handoff_run_tool
        def handoff_bad_digest_run_tool(argv, cwd=None, timeout=tooling.MAX_TOOL_SECONDS, env=None, input_bytes=None):
            handoff_events.append(list(argv))
            if argv[0] == "gh":
                return 0, json.dumps({"id": 123, "digest": "sha256:" + handoff_bad_digest}), ""
            raise AssertionError("unexpected privileged tool during raw artifact digest attack: " + " ".join(argv))
        tooling.run_tool = handoff_bad_digest_run_tool
        try:
            tooling.verify_artifact_handoff("123", handoff_bad_digest, "fixture-owner/fixture-product", "fixture-github-token", bad_digest_root / "downloaded.zip", bad_digest_root / "extracted", bad_digest_root / "handoff.json", "v1.2.3", commit)
        except tooling.ReleaseError:
            counts["attack"] += 1
        else:
            raise AssertionError("raw downloaded artifact digest mismatch was accepted")
        tooling.run_tool = handoff_run_tool_original_digest
    finally:
        tooling.run_tool = handoff_original_run_tool
        tooling.download_artifact_archive = handoff_original_download
    tooling.run_tool = original_run_tool
    check(all(event[0] == "gh" for event in handoff_events), "artifact handoff invoked a privileged tool")
    counts["handoff"] += 1
    counts["positive"] += 1

    snapshot_aba_destination = handoff_root / "snapshot-aba"
    original_snapshot_copy = tooling.copy_descriptor_to_directory
    def replace_snapshot_source(descriptor, destination_fd, name, mode):
        if name == "payload.txt":
            replacement = handoff_output / ".payload-replacement"
            write(replacement, b"replacement bytes\n", mode=mode)
            (handoff_output / "payload.txt").unlink()
            os.replace(replacement, handoff_output / "payload.txt")
        return original_snapshot_copy(descriptor, destination_fd, name, mode)
    tooling.copy_descriptor_to_directory = replace_snapshot_source
    try:
        try:
            tooling.snapshot_verified_handoff(handoff_output, handoff_state, "v1.2.3", commit, snapshot_aba_destination)
        except tooling.ReleaseError:
            counts["handoff"] += 1
        else:
            raise AssertionError("handoff snapshot ABA replacement was accepted")
    finally:
        tooling.copy_descriptor_to_directory = original_snapshot_copy

    def expect_zip_failure(label, entries):
        zip_path = handoff_root / (label + ".zip")
        extract_path = handoff_root / (label + "-extract")
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)
            with zipfile.ZipFile(zip_path, "w") as archive:
                for name, data, external_attr, declared_size in entries:
                    info = zipfile.ZipInfo(name)
                    if external_attr is not None:
                        info.external_attr = external_attr
                    if declared_size is not None:
                        info.file_size = declared_size
                    archive.writestr(info, data)
        try:
            tooling.extract_verified_zip_archive(zip_path, extract_path)
        except tooling.ReleaseError:
            counts["attack"] += 1
        else:
            raise AssertionError("unsafe artifact ZIP was accepted: " + label)

    expect_zip_failure("zip-traversal", [("../escape", b"x", 0, None)])
    expect_zip_failure("zip-duplicate", [("same", b"one", 0, None), ("same", b"two", 0, None)])
    expect_zip_failure("zip-case-alias", [("Case/file", b"one", 0, None), ("case/FILE", b"two", 0, None)])
    expect_zip_failure("zip-nfc-nfd-alias", [("café/file", b"one", 0, None), ("café/FILE", b"two", 0, None)])
    expect_zip_failure("zip-directory-file-alias", [("same/", b"", 0, None), ("same", b"file", 0, None)])
    expect_zip_failure("zip-symlink", [("link", b"target", (stat.S_IFLNK | 0o777) << 16, None)])
    expect_zip_failure("zip-special", [("fifo", b"x", (stat.S_IFIFO | 0o644) << 16, None)])
    expect_zip_failure("zip-oversized", [("large", b"x", 0, tooling.MAX_ARCHIVE_MEMBER_BYTES + 1)])

    zip_aba = handoff_root / "zip-aba.zip"
    with zipfile.ZipFile(zip_aba, "w") as archive:
        archive.writestr("safe.txt", b"original")
    zip_aba_replacement = handoff_root / "zip-aba-replacement.zip"
    with zipfile.ZipFile(zip_aba_replacement, "w") as archive:
        archive.writestr("safe.txt", b"replacement")
    original_zip_read = tooling.os.read
    zip_swapped = [False]
    def replace_zip_during_hash(descriptor, size):
        if not zip_swapped[0]:
            zip_swapped[0] = True
            os.replace(zip_aba_replacement, zip_aba)
        return original_zip_read(descriptor, size)
    tooling.os.read = replace_zip_during_hash
    try:
        try:
            tooling.extract_verified_zip_archive(zip_aba, handoff_root / "zip-aba-extract")
        except tooling.ReleaseError:
            counts["handoff"] += 1
        else:
            raise AssertionError("ZIP hash/extract ABA replacement was accepted")
    finally:
        tooling.os.read = original_zip_read

    class RedirectResponse:
        status = 302
        headers = {}
        def geturl(self):
            return "https://unexpected.example/artifact.zip"
        def __enter__(self):
            return self
        def __exit__(self, *args):
            return False

    original_build_opener = tooling.urllib.request.build_opener
    tooling.urllib.request.build_opener = lambda *handlers: type("RedirectOpener", (), {"open": lambda self, request, timeout: RedirectResponse()})()
    redirect_destination = handoff_root / "redirect.zip"
    try:
        tooling.download_artifact_archive("fixture-owner/fixture-product", "123", "fixture-github-token", redirect_destination)
    except tooling.ReleaseError:
        counts["attack"] += 1
    else:
        raise AssertionError("artifact redirect was accepted")
    finally:
        tooling.urllib.request.build_opener = original_build_opener

    for redirect_status in (301, 302, 303, 307, 308):
        handler = tooling._CaptureFirstRedirect()
        redirect_request = tooling.urllib.request.Request("https://api.github.com/repos/fixture-owner/fixture-product/actions/artifacts/123/zip")
        try:
            if redirect_status == 302:
                response = handler.http_error_302(None, None, redirect_status, "redirect", {})
                check(response is None, "fixture did not preserve the exact first 302 response")
            else:
                getattr(handler, "http_error_%d" % redirect_status)(redirect_request, None, redirect_status, "redirect", {})
        except Exception as error:
            if redirect_status == 302:
                raise
            check(isinstance(error, tooling.urllib.error.HTTPError), "redirect status was not rejected: %s" % redirect_status)
            counts["attack"] += 1
        else:
            if redirect_status != 302:
                raise AssertionError("redirect status was accepted: %s" % redirect_status)

    class ActualRedirectHandler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(307)
            self.send_header("Location", "/unexpected-third-hop")
            self.end_headers()
        def log_message(self, *args):
            return

    actual_redirect_server = http.server.HTTPServer(("127.0.0.1", 0), ActualRedirectHandler)
    actual_redirect_thread = threading.Thread(target=actual_redirect_server.serve_forever, daemon=True)
    actual_redirect_thread.start()
    actual_redirect_url = "http://127.0.0.1:%d/second-hop" % actual_redirect_server.server_address[1]
    try:
        actual_redirect_opener = tooling.urllib.request.build_opener(tooling._RejectRedirects())
        try:
            actual_redirect_opener.open(tooling.urllib.request.Request(actual_redirect_url), timeout=2)
        except tooling.urllib.error.HTTPError as error:
            check(error.code == 307, "actual urllib second-hop redirect returned the wrong status")
            counts["attack"] += 1
        except TypeError as error:
            raise AssertionError("actual urllib redirect handler raised a signature TypeError: " + str(error))
        else:
            raise AssertionError("actual urllib second-hop redirect was accepted")
    finally:
        actual_redirect_server.shutdown()
        actual_redirect_server.server_close()
        actual_redirect_thread.join(timeout=2)

    class HandoffResponse:
        def __init__(self, status, url, body=b"", headers=None):
            self.status = status
            self._url = url
            self._body = io.BytesIO(body)
            self.headers = headers or {}
        def geturl(self):
            return self._url
        def read(self, size=-1):
            return self._body.read(size)
        def __enter__(self):
            return self
        def __exit__(self, *args):
            return False

    signed_location = "https://objects.example.test/fixture.zip?sig=fixture-secret"
    requests_seen = []
    response_body = handoff_zip.read_bytes()
    def exact_redirect_opener(*handlers):
        class Opener:
            def open(self, request, timeout):
                requests_seen.append((request.full_url, {key.lower(): value for key, value in request.header_items()}))
                if len(requests_seen) == 1:
                    return HandoffResponse(302, "https://api.github.com/repos/fixture-owner/fixture-product/actions/artifacts/123/zip", headers={"Location": signed_location})
                return HandoffResponse(200, signed_location, response_body, {"Content-Type": "application/zip", "Content-Length": str(len(response_body))})
        return Opener()
    tooling.urllib.request.build_opener = exact_redirect_opener
    redirected_destination = handoff_root / "redirect-success.zip"
    tooling.download_artifact_archive("fixture-owner/fixture-product", "123", "fixture-github-token", redirected_destination)
    check(len(requests_seen) == 2 and requests_seen[0][0].endswith("/actions/artifacts/123/zip") and requests_seen[1][0] == signed_location, "artifact redirect did not use the exact two-request contract")
    check("authorization" in requests_seen[0][1] and "authorization" not in requests_seen[1][1] and "cookie" not in requests_seen[1][1], "artifact token or cookie crossed the signed redirect")
    check(tooling.sha256_file(redirected_destination) == handoff_digest, "redirected artifact digest changed")
    counts["handoff"] += 1
    for unsafe_location in (
        "http://objects.example.test/fixture.zip",
        "https://127.0.0.1/fixture.zip",
        "https://user:pass@objects.example.test/fixture.zip",
        "https://objects.example.test/fixture.zip#fragment",
        "file:///tmp/fixture.zip",
    ):
        def unsafe_redirect_opener(*handlers, location=unsafe_location):
            class Opener:
                def open(self, request, timeout):
                    return HandoffResponse(302, request.full_url, headers={"Location": location})
            return Opener()
        tooling.urllib.request.build_opener = unsafe_redirect_opener
        try:
            tooling.download_artifact_archive("fixture-owner/fixture-product", "123", "fixture-github-token", handoff_root / "unsafe-location.zip")
        except tooling.ReleaseError as error:
            check(unsafe_location not in str(error), "unsafe signed location leaked in diagnostics")
            counts["attack"] += 1
        else:
            raise AssertionError("unsafe signed artifact location was accepted: " + unsafe_location)
    def second_redirect_opener(*handlers):
        class Opener:
            def open(self, request, timeout):
                if request.full_url.endswith("/actions/artifacts/123/zip"):
                    return HandoffResponse(302, request.full_url, headers={"Location": signed_location})
                return HandoffResponse(302, request.full_url, headers={"Location": "https://objects.example.test/second.zip"})
        return Opener()
    tooling.urllib.request.build_opener = second_redirect_opener
    try:
        tooling.download_artifact_archive("fixture-owner/fixture-product", "123", "fixture-github-token", handoff_root / "second-redirect.zip")
    except tooling.ReleaseError:
        counts["attack"] += 1
    else:
        raise AssertionError("second artifact redirect was accepted")
    tooling.urllib.request.build_opener = original_build_opener

    def run_sigkill_prepare_case(label):
        case_root = temporary_root / ("sigkill-prepare-" + label)
        case_root.mkdir()
        list_state = case_root / "keychains.json"
        old_list = ["/Users/fixture/Library/Keychains/old-one.keychain-db", "/Library/Keychains/old-two.keychain-db"]
        list_state.write_text(json.dumps(old_list), encoding="utf-8")
        values = {
            "runner_temp": str(case_root), "signing_state": str(case_root / "state.json"),
            "signing_keychain": str(case_root / "release.keychain-db"), "cleanup_plan": str(case_root / "cleanup-plan.json"),
            "application_certificate_base64": base64.b64encode(b"application-p12").decode(),
            "installer_certificate_base64": base64.b64encode(b"installer-p12").decode(),
            "application_certificate_password": "app-pass", "installer_certificate_password": "installer-pass",
            "notary_credentials_base64": base64.b64encode(json.dumps({"appleId":"fixture@example.test","teamId":"FIXTUR1234","password":"notary-pass"}).encode()).decode(),
            "notary_profile": "fixture-profile", "team_id": "FIXTUR1234",
            "application_certificate_path": str(case_root / "app.p12"), "installer_certificate_path": str(case_root / "installer.p12"),
            "signature_private_key_base64": base64.b64encode(b"private").decode(), "signature_public_key_base64": base64.b64encode(b"public").decode(),
            "signature_private_key_path": str(case_root / "private.pem"), "signature_public_key_path": str(case_root / "public.pem"),
            "github_env": str(case_root / "github.env"),
        }
        prepare_code = r'''
import json, os, signal, sys
from pathlib import Path
sys.path.insert(0, os.environ["RELEASE_FIXTURE_SCRIPT_DIR"])
import release
args = release.argparse.Namespace(**json.loads(os.environ["RELEASE_FIXTURE_ARGS"]))
list_path = Path(os.environ["RELEASE_FIXTURE_LIST_STATE"])
boundary = os.environ["RELEASE_FIXTURE_BOUNDARY"]
def tool(argv, cwd=None, timeout=release.MAX_TOOL_SECONDS, env=None, input_bytes=None):
    if argv[:3] == ["security", "list-keychains", "-d"]:
        if "-s" in argv:
            values = argv[argv.index("-s") + 1:]
            list_path.write_text(json.dumps(values), encoding="utf-8")
            if boundary == "list":
                os.kill(os.getpid(), signal.SIGKILL)
            return 0, "", ""
        return 0, "".join('"%s"\n' % value for value in json.loads(list_path.read_text(encoding="utf-8"))), ""
    if argv[:2] == ["security", "create-keychain"]:
        Path(argv[-1]).touch(mode=0o600)
    if argv[:2] == ["xcrun", "notarytool"] and argv[2] == "store-credentials":
        return 0, "", ""
    return 0, "", ""
release.run_tool = tool
if boundary == "env":
    release.write_github_env = lambda values, github_env: os.kill(os.getpid(), signal.SIGKILL)
release.prepare_signing(args)
'''
        prepare_env = dict(os.environ, RELEASE_FIXTURE_SCRIPT_DIR=str(script_dir), RELEASE_FIXTURE_ARGS=json.dumps(values), RELEASE_FIXTURE_LIST_STATE=str(list_state), RELEASE_FIXTURE_BOUNDARY=label)
        child = subprocess.run([sys.executable, "-c", prepare_code], env=prepare_env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        check(child.returncode == -signal.SIGKILL, "prepare did not terminate by SIGKILL at " + label)
        recorded_list = json.loads(list_state.read_text(encoding="utf-8"))
        chain = str(case_root / "release.keychain-db")
        check(recorded_list == old_list + [chain], "prepare replaced prior keychains at " + label)
        for name in ("state.json", "cleanup-plan.json"):
            (case_root / name).unlink(missing_ok=True)
        cleanup_code = r'''
import json, os, sys
from pathlib import Path
sys.path.insert(0, os.environ["RELEASE_FIXTURE_SCRIPT_DIR"])
import release
case_root = Path(os.environ["RELEASE_FIXTURE_CASE_ROOT"])
list_path = case_root / "keychains.json"
def tool(argv, cwd=None, timeout=release.MAX_TOOL_SECONDS, env=None, input_bytes=None):
    if argv[:3] == ["security", "list-keychains", "-d"]:
        if "-s" in argv:
            list_path.write_text(json.dumps(argv[argv.index("-s") + 1:]), encoding="utf-8")
            return 0, "", ""
        return 0, "".join('"%s"\n' % value for value in json.loads(list_path.read_text(encoding="utf-8"))), ""
    if argv[:2] == ["security", "delete-keychain"]:
        Path(argv[-1]).unlink(missing_ok=True)
    return 0, "", ""
release.run_tool = tool
release.cleanup_signing_state(
    case_root / "state.json", case_root / "release.keychain-db", case_root,
    [case_root / item for item in ("app.p12", "installer.p12", "private.pem", "public.pem")],
    None, None, None,
)
'''
        cleanup_env = dict(os.environ, RELEASE_FIXTURE_SCRIPT_DIR=str(script_dir), RELEASE_FIXTURE_CASE_ROOT=str(case_root))
        cleanup = subprocess.run([sys.executable, "-c", cleanup_code], env=cleanup_env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        check(cleanup.returncode != 0 and b"state-missing" in cleanup.stderr, "SIGKILL cleanup did not fail closed at " + label + ": " + cleanup.stderr.decode(errors="replace"))
        check(json.loads(list_state.read_text(encoding="utf-8")) == old_list, "cleanup did not restore prior keychains at " + label)
        check(not any((case_root / name).exists() for name in ("release.keychain-db", "app.p12", "installer.p12", "private.pem", "public.pem")), "SIGKILL cleanup left resources at " + label)
        counts["cleanup"] += 1

    run_sigkill_prepare_case("list")
    run_sigkill_prepare_case("env")

    empty_state_root = temporary_root / "empty-keychain-state"
    empty_state_root.mkdir()
    empty_state = empty_state_root / "state.json"
    write(empty_state, json.dumps({"schemaVersion": 1, "temporaryFiles": [], "oldKeychains": []}), mode=0o600)
    current_keychains = ["/Users/fixture/Library/Keychains/old.keychain-db"]
    tooling.run_tool = stub_run_tool
    tooling.cleanup_signing_state(empty_state, runner_temp=empty_state_root, expected_files=[], allowed_old_keychains=[])
    check(not empty_state.exists() and current_keychains == [], "empty keychain search list was not restored")
    counts["cleanup"] += 1

    mismatch_root = temporary_root / "keychain-readback-mismatch"
    mismatch_root.mkdir()
    mismatch_state = mismatch_root / "state.json"
    write(mismatch_state, json.dumps({"schemaVersion": 1, "temporaryFiles": [], "oldKeychains": []}), mode=0o600)
    original_stub = stub_run_tool

    def mismatched_keychain_readback(argv, cwd=None, timeout=tooling.MAX_TOOL_SECONDS, env=None, input_bytes=None):
        result = original_stub(argv, cwd=cwd, timeout=timeout, env=env, input_bytes=input_bytes)
        if argv[:3] == ["security", "list-keychains", "-d"] and "-s" not in argv:
            return 0, '"/Users/fixture/Library/Keychains/unexpected.keychain-db"\n', ""
        return result

    tooling.run_tool = mismatched_keychain_readback
    try:
        try:
            tooling.cleanup_signing_state(mismatch_state, runner_temp=mismatch_root, expected_files=[], allowed_old_keychains=[])
        except tooling.ReleaseError:
            counts["attack"] += 1
        else:
            raise AssertionError("keychain read-back mismatch was accepted")
    finally:
        tooling.run_tool = original_run_tool

    def expect_cleanup_attack(label, state_value, expected_files=None, state_kind="regular", allowed_old_keychains=None):
        attack_root = temporary_root / ("cleanup-attack-" + label)
        attack_root.mkdir(exist_ok=True)
        state_path = attack_root / "state.json"
        outside = temporary_root / ("outside-sentinel-" + label)
        write(outside, "must survive\n", mode=0o600)
        if state_kind == "symlink":
            os.symlink(outside, state_path)
        elif state_kind == "hardlink":
            source_state = attack_root / "source-state.json"
            write(source_state, json.dumps(state_value), mode=0o600)
            os.link(source_state, state_path)
        else:
            write(state_path, json.dumps(state_value), mode=0o600)
        try:
            tooling.cleanup_signing_state(
                state_path,
                runner_temp=attack_root,
                expected_files=expected_files or [attack_root / "allowed.pem"],
                allowed_old_keychains=allowed_old_keychains,
            )
        except tooling.ReleaseError:
            pass
        else:
            raise AssertionError("tampered cleanup state was accepted: " + label)
        check(outside.exists() and outside.read_text(encoding="utf-8") == "must survive\n", "cleanup attack changed outside sentinel: " + label)
        counts["attack"] += 1

    expect_cleanup_attack("oversized-state", {"schemaVersion": 1, "temporaryFiles": [], "padding": "x" * (tooling.MAX_SIGNING_STATE_BYTES + 1)})

    expect_cleanup_attack(
        "path-escape",
        {"schemaVersion": 1, "temporaryFiles": [str(temporary_root / "outside-sentinel-path-escape")]},
    )
    expect_cleanup_attack(
        "unknown-key",
        {"schemaVersion": 1, "temporaryFiles": [], "unexpected": "reject"},
    )
    expect_cleanup_attack(
        "old-keychain",
        {"schemaVersion": 1, "temporaryFiles": [], "oldKeychains": ["/tmp/arbitrary.keychain-db"]},
    )
    expect_cleanup_attack(
        "old-keychain-substitution",
        {"schemaVersion": 1, "temporaryFiles": [], "oldKeychains": ["/Users/fixture/Library/Keychains/other.keychain-db"]},
        allowed_old_keychains=["/Users/fixture/Library/Keychains/old.keychain-db"],
    )
    expect_cleanup_attack(
        "keychain-escape",
        {"schemaVersion": 1, "temporaryFiles": [], "keychain": str(temporary_root / "outside.keychain-db")},
    )
    directory_target = temporary_root / "cleanup-attack-directory-target" / "target-dir"
    directory_target.mkdir(parents=True)
    expect_cleanup_attack(
        "directory-target",
        {"schemaVersion": 1, "temporaryFiles": [str(directory_target)]},
        expected_files=[directory_target],
    )
    expect_cleanup_attack(
        "symlink-state",
        {"schemaVersion": 1, "temporaryFiles": []},
        state_kind="symlink",
    )
    expect_cleanup_attack(
        "hardlink-state",
        {"schemaVersion": 1, "temporaryFiles": []},
        state_kind="hardlink",
    )

    try:
        redaction_value = "fixture-" + "secret-value"
        redaction_code = "import sys; sys.stderr.write('pass' + 'word=' + " + repr(redaction_value) + " + '\\n'); sys.exit(1)"
        tooling.run_tool([sys.executable, "-c", redaction_code])
    except tooling.ReleaseError as error:
        check(redaction_value not in str(error) and "[REDACTED]" in str(error), "secret was not redacted")
        counts["secret-redaction"] += 1
    else:
        raise AssertionError("secret-redaction case unexpectedly passed")

    os.environ["RELEASE_APPLICATION_CERTIFICATE_PASSWORD"] = "child-must-not-see-app-password"
    os.environ["RELEASE_NOTARY_CREDENTIALS_BASE64"] = "child-must-not-see-notary"
    os.environ["RELEASE_SIGNATURE_PRIVATE_KEY_BASE64"] = "child-must-not-see-key"
    os.environ["GH_TOKEN"] = "child-must-not-see-gh-token"
    tooling.SECRET_VALUES.update(os.environ[key] for key in ("RELEASE_APPLICATION_CERTIFICATE_PASSWORD", "RELEASE_NOTARY_CREDENTIALS_BASE64", "RELEASE_SIGNATURE_PRIVATE_KEY_BASE64", "GH_TOKEN"))
    child_probe = "import os,sys; sys.exit(1 if any(key in os.environ for key in ('RELEASE_APPLICATION_CERTIFICATE_PASSWORD','RELEASE_NOTARY_CREDENTIALS_BASE64','RELEASE_SIGNATURE_PRIVATE_KEY_BASE64','GH_TOKEN')) else 0)"
    tooling.run_tool([sys.executable, "-c", child_probe])
    counts["secret-redaction"] += 1

    check(not marker.exists(), "a forbidden external tool was called")

total = sum(counts.values())
print("fixture release tests passed: " + ", ".join("%s=%d" % (key, counts[key]) for key in counts) + ", total=%d" % total)
if fixture_limits:
    print("fixture limitations: " + "; ".join(fixture_limits))
PY
