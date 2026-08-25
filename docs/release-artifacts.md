# Release artifacts

This document defines the release output contract. The release tool accepts the
final product identity and all public release metadata as inputs. The selected
source identity is `Syrinx`, with executable `syrinx`, package identifier
`com.dpaluy.syrinx`, and service label `com.dpaluy.syrinx`. It rejects a
missing source license, unresolved owner or security contact, unapproved model
license review, mutable URLs, unsafe paths, model bytes, and an unverified
source checkout.

## Required source inputs

The source checkout must be clean at `HEAD`, and `HEAD` must equal the target
of an annotated tag whose name is `v<version>`. `Package.resolved` must contain
only full immutable revisions. The release contract also requires:

- product identity, executable name, package identifier, and service label;
- version, exact tag, and source commit;
- Developer ID Application identity, Developer ID Installer identity, Team ID,
  and a notarytool keychain profile name;
- owner, security contact, repository URL, approved source `LICENSE`, complete
  third-party notices and license directory;
- the approved immutable model manifest, compatibility file, support file, and
  changelog.

Every value can be supplied as a `RELEASE_*` environment variable or as the
matching long option. The parser rejects unknown options. Release commands
use argv-only subprocesses, never evaluate release values as shell code, and
bound captured tool output to 64 KiB. Temporary work directories are removed
on every exit path.

## Output inventory

For product identity `PRODUCT` and version `VERSION`, the output directory
contains:

| Asset | Purpose |
|---|---|
| `PRODUCT-VERSION.tar.gz` | deterministic signed executable archive |
| `PRODUCT-VERSION.source.tar.gz` | deterministic exact annotated-tag source archive |
| `PRODUCT-VERSION.pkg` | signed, notarized, stapled installer package |
| `PRODUCT-VERSION.licenses.tar.gz` | source and third-party license and notice bundle |
| `PRODUCT-VERSION.compatibility.md`, `PRODUCT-VERSION.support.md`, `PRODUCT-VERSION.changelog.md` | exact tagged release metadata assets |
| `PRODUCT-VERSION.notary.json` | bounded Accepted notarytool result |
| `PRODUCT-VERSION.spdx.json` | SPDX 2.3 SBOM from `Package.resolved` and payload files |
| `PRODUCT-VERSION.provenance.intoto.jsonl` | SLSA v1-compatible in-toto provenance statement |
| `PRODUCT.rb` | Homebrew formula for the exact signed archive URL and SHA-256 |
| `model-manifest.json` | canonical immutable model manifest, no model bytes |
| `model-manifest.sha256` | digest of the canonical manifest |
| `artifact-inventory.json` | sorted machine-readable artifact names, sizes, and digests |
| `SHA256SUMS` | checksums for every immutable asset and the inventory |
| `SHA256SUMS.sig` | detached signature of `SHA256SUMS` |

The inventory excludes itself to avoid a recursive digest. The checksum file
excludes itself and its detached signature for the same reason. The detached
signature covers the complete checksum file.

The signed package is staged on a temporary APFS volume auto-mounted by
`hdiutil` at a unique `/Volumes/<volume>` path. The release tool copies payload
bytes and modes once with `/bin/cp -X`, enumerates metadata on pinned descriptors, and
fails on every xattr, file flag, ACL, link, or special entry. A singleton
host-added `com.apple.provenance` may be removed only with `fremovexattr` on
the held destination descriptor, followed by an empty descriptor enumeration.
If that exact operation does not remove it, the package path fails closed. No
blanket `xattr -cr` or visible-path fallback is used. `pkgbuild` runs with
`COPYFILE_DISABLE=1`. The normalized `pkgutil --payload-files` listing must
match every expected directory and file. AppleDouble `._` entries are not
allowed.

The source archive is created from `git archive` at the exact annotated tag,
then normalized to sorted entries, zero timestamps, and fixed ownership. The
verification command recreates that archive from the checked-out tag and
compares its digest. The compatibility statement, support matrix, and
changelog are copied from Git-tracked regular files and are independently
compared during verification. Source archive verification checks exact tag
identity, archive structure, safe member names, and model-byte exclusions. It
does not apply product-payload placeholder scans to arbitrary source code.

## Package payload and model boundary

The package installs the executable and metadata below the immutable path:

```text
/Library/Application Support/<product-identity>/versions/<version>/
  <executable>
  metadata/release.json
  metadata/model-manifest.json
  metadata/model-manifest.sha256
  metadata/model-attribution.txt
  licenses/LICENSE
  licenses/THIRD_PARTY_NOTICES.md
  licenses/<third-party-files>
  docs/COMPATIBILITY.md
  docs/SUPPORT.md
  docs/CHANGELOG.md
```

The package does not create a `current` pointer. The release tool provides only
the immutable package source layout above. The service lifecycle copies that
versioned payload into its accepted per-user service version store and owns
per-user version selection and rollback. Release metadata records this
ownership without inventing a filesystem path. Homebrew uses a separate Cellar layout: it
copies the same versioned payload contents into `libexec` and creates a `bin`
symlink. Normal uninstall and retention of model and configuration data
remain outside the package contract.

When the SwiftPM resource bundle is present, its exact regular-file inventory
contains only the approved model manifest. The public manifest, embedded
manifest, and shipped bundle manifest must be byte-identical. Offline archive
verification rejects an extra regular file inside the bundle before handoff
or sign-input verification continues.

The manifest records the immutable model commit, file hashes, attribution,
and an approved license review. It is metadata only. The release tool rejects
Core ML directories, model weights, `.bin`, `.mil`, and other model byte paths.
It also rejects URLs that use mutable refs or do not contain the immutable
model commit.

## Signed verification

Signed verification cryptographically checks `SHA256SUMS.sig` with the
protected public key. It checks the package identity and Team ID, requires a
parsed notarytool result with status `Accepted`, validates the staple and
Gatekeeper result under quarantine, compares the package payload listing, and
repeats executable and nested runtime dylib signature and dependency-closure
checks. Runtime libraries are copied into the unsigned build input with
`xcrun swift-stdlib-tool` when the Swift build path is used. Prohibited Xcode
toolchain rpaths are removed with `install_name_tool`, while `@loader_path`
and the reviewed `/usr/lib/swift` rpath remain, with the payload-relative path
ordered first when a compatibility dylib is bundled. The signing job does not
repeat this preparation. Nested dylibs are signed before the executable.

The closure accepts only the reviewed macOS 14 system dependency contract or
included signed files. The contract includes dyld shared-cache members, so a
filesystem inode is not required for an accepted system library. It rejects
unknown or unproven system names, Homebrew paths, Xcode and
`/Library/Developer` paths, canonicalized loader escapes, unresolved tokens,
prohibited rpaths, and unreferenced bundled dylibs.

The release tool does not claim that `metadata/release.json` is
cryptographically bound to the executable. The current runtime `BuildInfo`
path does not yet provide an embedded exact version and source commit. The
service lifecycle must make the build identity embedded or otherwise signature
bound, then compare it with the candidate metadata before activation. This is
a required cross-stack release gate.

## Dry run

Use `--unsigned-dry-run` with explicit non-placeholder fixture values. The dry
run creates the archive and package-layout archive, then verifies the
inventory, checksums, SBOM, provenance, formula, license bundle, and manifest
digest. It uses a fixture signature marker. It does not call Apple signing,
notarization, stapling, Gatekeeper, package installation, Homebrew, GitHub,
network access, or real artifact publication.
