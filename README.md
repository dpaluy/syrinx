# Syrinx

Syrinx is a macOS project for private, local speech-to-text. It contains:

- **Parrot**, a push-to-talk dictation client that records while you hold the
  Fn key and inserts the transcript at the cursor.
- **Syrinx**, a native Parakeet transcription service that runs on the local
  Mac and provides a loopback HTTP API.

Audio stays on the Mac. Neither component supports cloud transcription.

## Project status

Syrinx is pre-release software. Source builds are available. Signed and
notarized installers are not available yet.

The Parrot client uses WhisperKit with the English Whisper Base model by
default. The optional Syrinx service uses Parakeet. The unresolved Parakeet
model-license metadata blocks a binary release, as documented in
[the model license review](docs/model-license-review.md).

## Requirements

- Apple Silicon Mac
- macOS 14 or later
- Xcode 16 or later, or matching Swift 6 command-line tools
- Internet access for the first Whisper model download

## Quick start

Build the Parrot dictation client from the repository root:

```sh
swift build --package-path parrot --configuration release
```

Grant microphone and Accessibility access to the terminal that will run
Parrot:

```sh
./parrot/.build/release/parrot setup
```

Start dictation:

```sh
./parrot/.build/release/parrot
```

The first launch downloads and loads the recommended Whisper Base English
model. When Parrot reports that it is listening, hold Fn, speak, and release
Fn. Press Control-C in the terminal to stop it.

See [the Parrot guide](parrot/README.md) for model choices, launch-at-login,
permission troubleshooting, and the optional Syrinx service.

## Optional Parakeet service

Build the native Syrinx service:

```sh
swift build --configuration release
./.build/release/syrinx --help
./.build/release/syrinx doctor
```

Before installing the Parakeet model, read the
[model license review](docs/model-license-review.md). Model bytes are
downloaded from the pinned upstream source and are never stored in this
repository or bundled in a release.

```sh
./.build/release/syrinx models install --activate
./.build/release/syrinx service install
./.build/release/syrinx service start
./parrot/.build/release/parrot run \
  --model parakeet-tdt-0.6b-v3 \
  --syrinx-url http://127.0.0.1:5092
```

The service binds to `127.0.0.1:5092` by default and rejects non-loopback
hosts.

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
