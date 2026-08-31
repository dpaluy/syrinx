# Syrinx

Syrinx is a macOS menu bar application for private, local speech-to-text.
Hold Fn, speak, and release Fn. Syrinx inserts the transcript at the active
cursor.

Audio and transcription stay on the Mac. Syrinx does not use cloud
transcription.

## Project status

Current version: **1.1.1**. See the [changelog](CHANGELOG.md) for release notes.

Syrinx is pre-release software. A signed and notarized Mac application is not
available until the signing, notarization, and clean-machine gates pass. The
maintainer publishes `Syrinx.app` only after those gates pass on a local Mac.
The native Parakeet service is a development and integration component. It is
not part of the end-user application.

## Requirements

- Apple Silicon Mac
- macOS 14 or later
- No developer tools are required for end users.
- Internet access for the first Whisper model download

## Quick start

1. Download `Syrinx-<version>.zip` from GitHub Releases.
2. Open the archive and move `Syrinx.app` to Applications.
3. Open Syrinx.app.
4. On first launch, set the Fn or Globe key to **Do Nothing** in System
   Settings > Keyboard. Grant Syrinx **Microphone** and **Accessibility**
   access when macOS asks.
5. Click into the text field where you want the transcript, hold Fn, speak,
   and release Fn.

The first launch downloads and loads the recommended Whisper Base English
model. Syrinx runs as a menu bar application and has no Terminal command in
the end-user flow.

## Required macOS permissions

Syrinx needs these permissions:

- **Microphone** to record audio while you hold Fn.
- **Accessibility** to detect the global Fn key and insert the transcript at
  the active cursor.

Syrinx requests both permissions when you first open it. You can also enable
them manually in **System Settings > Privacy & Security**. Quit and reopen
Syrinx after you change Accessibility access.

Syrinx also requires this keyboard setting:

1. Open **System Settings > Keyboard**.
2. Set **Press Fn key to** or **Press Globe key to** to **Do Nothing**.

Syrinx does not require Full Disk Access, Screen Recording, Input Monitoring,
or Automation permission.

## Development

The source checkout contains the reusable client package, the Syrinx.app
target, and a development CLI. The CLI is not the end-user distribution.

Build both development packages:

```sh
swift build
swift build --package-path parrot
```

Run the test suites and repository checks:

```sh
./scripts/test-all.sh
./scripts/clean-source-audit.sh
```

GitHub Actions does not build or test this macOS application. Run all build,
test, signing, and notarization checks on a local Mac.

Build the client app and run its tests:

```sh
swift build --package-path parrot --product syrinx --configuration release
swift test --package-path parrot
```

### Build a release version

From the repository root, run this command and replace `1.1.1` with the
version that you want to build:

```sh
./scripts/release/build-app.sh --swift-build --unsigned-dry-run \
  --skip-source-validation --version 1.1.1 --tag v1.1.1 \
  --output-dir dist/1.1.1
```

The command creates `dist/1.1.1/Syrinx-1.1.1.zip`. The archive contains the
release build of `Syrinx.app`, but it is unsigned. For a signed and notarized
release, follow the [release operations](docs/release-operations.md).

Real-model integration tests require separately managed model and audio
fixtures. Tests that need those fixtures report a skip when they are absent.

The root native Parakeet service is only a development and integration
component. Before installing its model, read the
[model license review](docs/model-license-review.md).

```sh
./.build/release/syrinx models install --activate
./.build/release/syrinx service install
./.build/release/syrinx service start
./parrot/.build/release/parrot run \
  --model parakeet-tdt-0.6b-v3 \
  --syrinx-url http://127.0.0.1:5092
```

The service binds to `127.0.0.1:5092` by default and rejects non-loopback
hosts. Model bytes are not stored in this repository or bundled in a release.

## Repository layout

```text
Sources/SyrinxCore/     Development native service library
Sources/syrinx/         Development native service executable
Tests/                  Native service tests
parrot/Sources/         Reusable dictation client and Syrinx.app source
parrot/Tests/           Dictation client tests
docs/                   Architecture and release documentation
scripts/                Contributor and release verification tools
Packaging/              Installer and package contracts
```

The client and native service are separate Swift packages so WhisperKit and
the optional native service keep independent dependency graphs.

## Documentation

- [Native service development notes](docs/native-service.md)
- [Client architecture](parrot/docs/architecture.md)
- [Compatibility](COMPATIBILITY.md)
- [Changelog](CHANGELOG.md)
- [Security policy](SECURITY.md)
- [Contributing](CONTRIBUTING.md)
- [Release gates](docs/release-gates.md)
- [Third-party notices](THIRD_PARTY_NOTICES.md)

## License

Syrinx source is available under the [MIT License](LICENSE). Dependencies and
models retain their own terms. See [the license inventory](LICENSES/README.md)
and [third-party notices](THIRD_PARTY_NOTICES.md).
