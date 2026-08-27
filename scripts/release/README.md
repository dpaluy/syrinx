# Release scripts

## Syrinx.app

The end-user release path is `app-release.py`. It creates and verifies the menu
bar application archive on a local Mac. GitHub Actions must not build, test,
sign, notarize, or publish the macOS application.

Run an unsigned local check with:

```sh
./scripts/release/build-app.sh --swift-build --unsigned-dry-run \
  --skip-source-validation
./scripts/release/verify-app.sh --skip-source-validation
```

For a signed release, use a clean checkout at the exact annotated tag, provide
the required `RELEASE_*` values locally, and run:

```sh
./scripts/release/build-app.sh --swift-build --sign
./scripts/release/verify-app.sh --signed
```

The release tool signs the app with Developer ID Application, submits it to
Apple notarization, staples the ticket, and verifies the result. Publish only
the verified output from `dist/`.

## Native service development

`release.py`, `build-release.sh`, and `verify-release.sh` retain the existing
native Parakeet service package contract. These scripts are for development and
integration only. They do not build or publish the end-user `Syrinx.app`.
