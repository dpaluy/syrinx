# Release operations

Syrinx builds, tests, signs, and notarizes releases on a local maintainer Mac.
GitHub Actions must not build or test the macOS application.

## Local verification

Run the complete local checks before a release:

```sh
./scripts/test-all.sh
./scripts/clean-source-audit.sh
./scripts/release/build-app.sh --swift-build --unsigned-dry-run \
  --skip-source-validation
```

The unsigned dry run proves app wrapping, plist identity, permission
declarations, archive contents, and checksums. It does not prove Developer ID
signing, Apple notarization, stapling, Gatekeeper acceptance, installation, or
publication.

## Signed release

Create the release from a clean checkout at the exact annotated release tag.
Set the required `RELEASE_*` values in the local environment, then run:

```sh
./scripts/release/build-app.sh --swift-build --sign
./scripts/release/verify-app.sh --signed
```

The signing identity and notary profile stay on the maintainer Mac. The release
tool signs `Syrinx.app`, submits it to Apple notarization, staples the ticket,
and verifies the signed output. Publish the verified files from `dist/` to the
matching GitHub Release only after these commands pass.

## Service tooling

The root `scripts/release/release.py` path remains available for the native
Parakeet service package. It is a separate development and integration path,
and its output must not be presented as the end-user `Syrinx.app` release.
