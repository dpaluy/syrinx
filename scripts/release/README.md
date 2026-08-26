# Release scripts

## Syrinx.app

The end-user release path is `app-release.py`. It creates the menu bar
application archive and verifies its bundle identity, permission declarations,
archive contents, and checksums.

```sh
./scripts/release/build-app.sh --swift-build --unsigned-dry-run \
  --skip-source-validation
./scripts/release/verify-app.sh --skip-source-validation
./scripts/release/validate-workflow.sh
```

The unsigned dry run is local proof only. A protected release runner uses the
same app input, then `sign-input` signs it with Developer ID Application,
submits the app to Apple notarization, staples the ticket, and verifies the
result before publication. The workflow publishes the `.zip`, metadata, notary
result, and checksums.

Release values use the `RELEASE_*` environment contract. The app packager
requires the exact annotated tag and clean checkout for release builds. The
`--skip-source-validation` option is allowed only for local unsigned dry runs.

## Native service development

`release.py`, `build-release.sh`, and `verify-release.sh` retain the existing
native Parakeet service package contract. These scripts are for development and
integration only. They do not build or publish the end-user `Syrinx.app`.
