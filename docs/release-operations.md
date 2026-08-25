# Release operations

T50B prepares trusted release machinery for Syrinx. It does not perform a real
release in local tests.

## Protected runner

The workflow uses the exact GitHub-hosted `macos-15` label. The macOS 15
Apple Silicon image provides Xcode 16 and the Swift 6 toolchain required by
both Swift packages.
The workflow still checks `uname -m` for `arm64` and requires macOS 14 or
later before Swift or signing work starts.

Evidence sources:

- [GitHub supported runners table](https://github.com/github/docs/blob/main/data/reusables/actions/supported-github-runners.md), current Arm64 row and labels.
- [GitHub-hosted runners reference](https://docs.github.com/en/actions/reference/runners/github-hosted-runners), including Arm64 macOS limitations.
- [Raw GitHub runner table](https://raw.githubusercontent.com/github/docs/main/data/reusables/actions/supported-github-runners.md), fetched and checked on 2026-08-15.
- [macOS 15 Arm64 runner image](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-arm64-Readme.md).

Before a real release, recheck the table and move to the current documented
Arm64 label if `macos-15` is removed. Do not replace it with an unverified
label. A protected self-hosted label set such as `self-hosted`, `macOS`,
`ARM64`, `release` is an approved fallback only after the repository
administrators register and protect that runner group.

## Exact-tag procedure

1. Record the selected Syrinx product identity and MIT source license. Approve
   the owner, security contact, model license, and public repository URL.
2. Create a new semantic version and an annotated tag `v<version>`.
3. Protect the release environment and configure base64 protected secrets for
   the Developer ID Application and Installer certificates, their import
   passwords, the notarytool JSON credentials, and the detached signature key
   pair. Do not place credentials in a repository file, workflow argument,
   log, formula, or package metadata.
4. Configure the required `RELEASE_*` repository variables and secrets. After
   checkout, the workflow resolves `HEAD` and the requested annotated tag
   target and exports that checked-out commit. It does not trust `github.sha`
   for a dispatch event.
5. Run the unprivileged `build-verify` job. It resolves dependencies, confirms
   that `Package.resolved` does not change, runs `swift test --disable-sandbox`,
   runs the clean-source audit, and builds an unsigned dry-run input. It has no
   certificate, password, notary, detached-private-key, or GitHub publication
   secret. The Swift runtime tool and `install_name_tool` sanitize the build
   input before upload, so its dynamic closure is complete before signing. The
   upload action exposes an immutable artifact ID and digest. The signing job
   queries the official artifact REST record with a scoped read token, fetches
   the exact `/actions/artifacts/{id}/zip` response without redirects, hashes
   the raw ZIP bytes, and requires exact equality with `sha256:<digest>` before
   any signing secret is prepared.
   This uses GitHub's documented [Download an artifact REST endpoint](https://docs.github.com/en/rest/actions/artifacts#download-an-artifact),
   including its temporary redirect to the signed archive URL.
6. The protected `sign-notarize` job safely extracts that verified ZIP, records
   pinned identities for every extracted file, rejects unsafe ZIP entries, and
   independently verifies the unsigned input. It then
   creates and cleans a temporary keychain, imports both Developer ID
   certificates, sets the key partition list, stores the notarytool profile,
   decodes detached keys with mode 0600, and runs `sign-input`. This signs and
   packages the downloaded input without adding a runtime library, dependency
   resolution, tests, or a Swift rebuild. It compares the pre-sign payload
   inventory and permits only expected Mach-O code-signature changes. It
   verifies the code signature, Team ID, package signature,
   parsed `Accepted` notarization, staple, quarantine Gatekeeper assessment,
   payload paths and modes, dynamic-library closure, checksums, detached
   signature, SBOM, provenance, source archive, notices, and model boundary.
   Its cleanup step always restores keychain state and removes all temporary
   signing material.
7. The separately protected `release-publish` job downloads the signed asset
   artifact, checks out and resolves the exact annotated tag, prepares only the
   detached public verification key, and independently re-verifies every
   expected asset, checksum, detached signature, exact source archive, SBOM,
   provenance, package signature, notarization, staple, Gatekeeper result,
   executable signature, and dynamic closure. It attests all assets, freezes
   size, mode, link count, and SHA-256, rechecks that frozen set immediately
   before `gh`, and includes `artifact-inventory.json` in the release assets.
   The artifact upload API uses `http.client.HTTPSConnection` and sends the
   bearer token only on that exact upload request while streaming the held
   descriptor. The signed artifact download uses `urllib` redirect handlers,
   sends Authorization only on the first GitHub API request, and sends no
   token or cookies on the signed second request. A correction release uses a
   new version.

## Temporary signing material

The protected runner setup creates a temporary keychain with a generated
password, imports certificates from protected base64 input, calls
`security set-key-partition-list`, and stores notarytool credentials in the
temporary keychain. Detached keys are decoded to protected 0600 temporary
files. The initial keychain search list is recorded in a protected cleanup
plan, but the plan and mutable state never select cleanup targets. Cleanup
receives the exact keychain and credential paths from workflow-owned
environment values. It reads the current keychain list, removes only the exact
temporary keychain, preserves every other current entry, and verifies the
read-back list. A missing, corrupt, truncated, symlinked, hard-linked, or
replaced plan/state still permits exact resource cleanup, reports failure, and
leaves unsafe state for retry. The always-run cleanup step deletes the
keychain, profile, certificates, keys, state, and plan only after
descriptor-safe checks. The release script does not print private keys,
passwords, tokens, keychain contents, or notarization credentials.

The installer package is staged on a temporary APFS sparse image. The image is
auto-mounted by `hdiutil` at a unique `/Volumes/<volume>` path, so a
provenance-marked runner temp parent is not used as the mountpoint. The script
copies the validated payload bytes and modes once with `/bin/cp -X`, enumerates
metadata on pinned descriptors, and rejects every xattr, file flag, ACL, link,
or special entry. The only removable host case is a singleton
`com.apple.provenance` attribute on a newly constructed node. It must be
removed with `fremovexattr` on that same descriptor and re-enumerate empty.
For regular files, the held descriptor is hashed before removal, then the
same inode is reopened and hashed again. Bytes and immutable identity must
match; a size and timestamp restoration cannot hide an in-place rewrite. If
Darwin cannot remove it through the held descriptor, staging fails closed. No
blanket `xattr -cr` or visible-path deletion is used. `pkgbuild` receives
`COPYFILE_DISABLE=1`. The package verifier compares the complete normalized
`pkgutil --payload-files` directory/file contract and the expanded package
bytes and modes. AppleDouble `._` entries, missing parents, extra paths,
duplicates, malformed lines, metadata, and type changes fail closed. The
image is detached in cleanup even when package creation fails.

For a real build, the script calls these Apple interfaces through argv-only
subprocesses: `security`, `codesign`, `pkgbuild`, `productsign`, `xcrun
swift-stdlib-tool`, `xcrun notarytool`, `xcrun stapler`, `install_name_tool`,
`pkgutil`, `spctl`, and `otool`. Tool output is bounded and redacted on
failure. Structured files use bounded descriptor-pinned reads with
`O_NOFOLLOW` and before/after device, inode, mode, link-count, size, and
high-resolution timestamp checks. Archive inspection has member-count and
declared-size limits, and extraction scans and writes each member in one pass.
The fixture suite stubs the preparation path and proves cleanup after a
simulated build failure.

## Local checks

The fixture suite is the only local release path. It creates a temporary Git
   repository with an annotated tag, a small executable fixture, matching public
   and embedded approved manifests, and explicit non-placeholder metadata. It
   tests positive, negative, attack, cleanup, timeout, secret-redaction, and
   artifact-handoff cases. It may call
only unsigned local `pkgbuild` and `pkgutil` for the payload-listing probe. It
never calls signing, notarization, stapling, Gatekeeper, package installation,
Homebrew, GitHub, network, or publication commands.

On this Codex macOS host, Python-created filesystem nodes receive a host
`com.apple.provenance` attribute that Darwin does not remove through
`fremovexattr`, including through `/dev/fd/<held-descriptor>`. The fixture
therefore records the real APFS package probe and descriptor-copy positives as
host-limited when that exact condition occurs. This is a fail-closed local
limitation, not an allowlist or a successful signed-package claim.

```text
./scripts/release/test-fixtures.sh
./scripts/release/validate-workflow.sh
```

The fixture suite also runs an unsigned dry-run and records the generated
inventory, hashes, model boundary checks, and package-layout names in the
T50B evidence file.
