# Release operations

The protected release workflow builds and publishes `Syrinx.app`. It does not
run a Terminal command, model service, Docker container, or source build for
the end user.

## Jobs

1. `build-verify` checks out the exact annotated tag, confirms an arm64 macOS
   runner, runs the client tests and clean-source audit, validates the workflow,
   and creates an unsigned app archive.
2. `sign-notarize` verifies the uploaded artifact ID and digest before it
   receives signing credentials, imports that exact app input, signs the app
   with Developer ID Application, submits the app to Apple notarization,
   staples the ticket, and verifies the signed app.
3. `publish` checks out the same tag, independently verifies the signed app and
   checksums, attests the output assets, and publishes the app archive to the
   GitHub Release.

The signing environment must provide the protected certificate and
notarytool inputs described by the `RELEASE_*` environment contract. The
workflow scopes certificate, password, notary, and publication values to the
steps that need them. Cleanup runs after signing even when signing fails.

## Local checks

```sh
./scripts/release/build-app.sh --swift-build --unsigned-dry-run \
  --skip-source-validation
./scripts/release/validate-workflow.sh
```

The local build is unsigned. It proves app wrapping, plist identity,
permission declarations, archive contents, and checksums. It does not prove
Developer ID signing, Apple notarization, stapling, Gatekeeper, installation,
or GitHub publication.

## Service tooling

The root `scripts/release/release.py` path remains available for the native
Parakeet service package. It is a separate development and integration path,
and its output must not be presented as the end-user `Syrinx.app` release.
