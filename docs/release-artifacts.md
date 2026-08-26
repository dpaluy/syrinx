# Syrinx.app release artifacts

The end-user release artifact is `Syrinx-<version>.zip`. It contains one
application bundle:

```text
Syrinx.app/
  Contents/
    Info.plist
    MacOS/syrinx
    Resources/
```

The bundle has product name `Syrinx`, executable `syrinx`, bundle identifier
`com.dpaluy.syrinx`, `LSUIElement=true`, and a minimum macOS version of 14.0.
It declares only Microphone and Accessibility usage descriptions. The app
does not request Full Disk Access, Screen Recording, Input Monitoring, or
Automation.

The archive contains no Whisper model bytes. WhisperKit downloads its selected
model on the user's Mac on first launch. Audio is captured and transcribed in
the app process.

## Release outputs

The app workflow publishes these files:

| File | Purpose |
| --- | --- |
| `Syrinx-<version>.zip` | Signed, stapled, notarized `Syrinx.app` |
| `Syrinx-<version>.metadata.json` | Product, source, architecture, and permission contract |
| `Syrinx-<version>.notary.json` | Accepted Apple notarization result |
| `SHA256SUMS` | SHA-256 checksums for the other release files |

The workflow builds on a protected arm64 macOS runner. The build job creates
and verifies an unsigned input, then uploads a manifest-bound artifact. The
signing job verifies that artifact's ID and digest before it receives signing
credentials, imports the exact input, submits it to Apple notarization,
staples the ticket, and runs independent signature and Gatekeeper checks. The
publish job verifies the signed input again before GitHub publication.

## Local verification boundary

Run:

```sh
./scripts/release/build-app.sh --swift-build --unsigned-dry-run \
  --skip-source-validation
```

This proves SwiftPM compilation, app wrapping, plist values, archive safety,
and checksums. It does not prove Developer ID signing, Apple notarization,
stapling, Gatekeeper acceptance, installation, or GitHub publication.

The root `scripts/release/release.py` service contract remains available for
native Parakeet development and integration. It is not the end-user app
release path.
