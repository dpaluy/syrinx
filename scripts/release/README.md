# Release scripts

The release entry point is `release.py`. The shell wrappers only locate that
file and pass literal arguments to Python. Release values are never evaluated
as shell code.

The common contract is supplied by `RELEASE_*` environment variables or the
matching long option. The required identity, source, license, manifest,
compatibility, support, changelog, signing, and notary values must be present
for every command. Unknown options are rejected by `argparse`.

## Commands

```text
./scripts/release/validate-source.sh
./scripts/release/build-release.sh --unsigned-dry-run
./scripts/release/verify-release.sh --unsigned-dry-run
./scripts/release/validate-workflow.sh
```

The protected workflow also runs `release.py resolve-source` after checkout,
`release.py prepare-signing` before the signed build, and
`release.py cleanup-signing` in an always-run step. The publish job uses
`prepare-verification`, `verify`, and the same cleanup command. Preparation
decodes base64 protected inputs to 0600 temporary files, creates a temporary
keychain, imports both Developer ID certificates, sets the key partition list,
and stores the notarytool profile in that keychain. Cleanup restores the
keychain search list and deletes all temporary signing material.

`--unsigned-dry-run` is the only local fixture mode. It creates a deterministic
archive, an exact-tag source archive, a package-layout archive instead of a
macOS installer package, a fixture signature marker instead of a cryptographic
signature, checksums, an SPDX 2.3 SBOM, SLSA-compatible in-toto provenance,
notices, a model manifest, exact compatibility, support, and changelog assets,
and a Homebrew formula. It does not call `codesign`, `productsign`,
`notarytool`, `stapler`, `spctl`, `pkgutil`, `installer`, Homebrew, GitHub, or
the network.

Normal builds require macOS and `--sign`. They call `codesign` with Hardened
Runtime and a timestamp, `pkgbuild`, `productsign`, `xcrun swift-stdlib-tool`,
`xcrun notarytool`, `xcrun stapler`, `install_name_tool`, `spctl`, `pkgutil`,
`otool`, and `security`-managed signing identities as described in the
operations document. Detached SHA-256 signing uses protected temporary key
files. Independent signed verification repeats the package, notarization,
staple, Gatekeeper, signature, and runtime-closure checks.

Every release output directory must be new or empty. Correction releases use
a new semantic version and annotated tag. Existing assets are never replaced.
