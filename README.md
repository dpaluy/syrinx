# Syrinx

Syrinx is a private, local speech-to-text application for macOS. Hold the Fn
key, speak, and release it. Syrinx inserts the transcript at the active cursor.
Audio and transcription stay on the Mac.

## Project status

Syrinx is pre-release software. A signed and notarized Mac application is not
available yet. When the first release is published, the Quick Start below will
be the supported installation path.

## Requirements

- Apple Silicon Mac
- macOS 14 or later
- Internet access for the first Whisper model download

## Quick start

1. Open the [latest Syrinx release](https://github.com/dpaluy/syrinx/releases/latest).
2. Download and install the Mac application.
3. Open Syrinx from the Applications folder.
4. Approve the macOS permissions described below.

The first launch downloads and loads the recommended Whisper Base English
model. When Syrinx is ready, place the cursor in any text field. Hold Fn,
speak, and release Fn.

## Required macOS permissions

Syrinx needs these permissions:

- **Microphone** to record audio while you hold Fn.
- **Accessibility** to detect the global Fn key and insert the transcript at
  the active cursor.

Syrinx requests both permissions when you first open it. You can also enable
them manually:

1. Open **System Settings > Privacy & Security > Microphone** and enable
   **Syrinx**.
2. Open **System Settings > Privacy & Security > Accessibility** and enable
   **Syrinx**.
3. Quit and reopen Syrinx after you change Accessibility access.

Syrinx also requires this keyboard setting:

1. Open **System Settings > Keyboard**.
2. Set **Press Fn key to** or **Press Globe key to** to **Do Nothing**.

Syrinx does not require Full Disk Access, Screen Recording, Input Monitoring,
or Automation permission.

## Repository layout

```text
Sources/SyrinxCore/     Native service library
Sources/syrinx/         Native service executable
Tests/                  Native service tests
parrot/Sources/         Push-to-talk client source
parrot/Tests/           Push-to-talk client tests
docs/                   Architecture and release documentation
scripts/                Contributor and release verification tools
Packaging/              Installer and package contracts
```

Syrinx and Parrot are separate Swift packages so each executable has an
independent dependency graph.

## Development

Development requires Xcode 16 or later, or matching Swift 6 command-line
tools. The source tree contains a Parrot push-to-talk client and a Syrinx
Parakeet transcription service. End users do not run these components or their
scripts separately.

Build both packages:

```sh
swift build
swift build --package-path parrot
```

Run the test suites and repository checks:

```sh
./scripts/test-all.sh
./scripts/clean-source-audit.sh
./scripts/release/validate-workflow.sh
```

Real-model integration tests require separately managed model and audio
fixtures. Tests that need those fixtures report a skip when they are absent.

The native Parakeet service is only a development and integration component.
It is not part of the end-user application workflow. Before installing its
model, read the
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

## Documentation

- [Native service](docs/native-service.md)
- [Parrot architecture](parrot/docs/architecture.md)
- [Compatibility](COMPATIBILITY.md)
- [Security policy](SECURITY.md)
- [Contributing](CONTRIBUTING.md)
- [Release gates](docs/release-gates.md)
- [Third-party notices](THIRD_PARTY_NOTICES.md)

## License

Syrinx source is available under the [MIT License](LICENSE). Dependencies and
models retain their own terms. See [the license inventory](LICENSES/README.md)
and [third-party notices](THIRD_PARTY_NOTICES.md).
