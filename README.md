# Syrinx

Syrinx is one macOS project for local Parakeet dictation. It contains the
native speech service and the Parrot push-to-talk client in one repository.

## Components

- `syrinx`: native Swift service for Parakeet transcription. It manages the
  model store, loopback HTTP endpoint, and per-user LaunchAgent.
- `parrot`: macOS push-to-talk client. It captures audio, calls Syrinx through
  the loopback adapter, and inserts the transcript at the cursor.

The service listens on `127.0.0.1:5092` by default. Model bytes are not stored
in Git or bundled in a release.

## Quick start

Build and test both components from the repository root:

```sh
./scripts/test-all.sh
```

Install the pinned model and start the native service:

```sh
swift run syrinx models install --activate
swift run syrinx service install
swift run syrinx service start
```

Configure Parrot permissions, then run it with Syrinx:

```sh
cd parrot
swift run parrot setup
swift run parrot run --model parakeet-tdt-0.6b-v3 --syrinx-url http://127.0.0.1:5092
```

The Parrot client also supports WhisperKit models. Docker is not required for
the native Syrinx path.

## Repository layout

```text
Sources/SyrinxCore/     Native service library
Sources/syrinx/         Native service executable
Tests/                  Native service tests
parrot/Package.swift    Parrot client package
parrot/Sources/         Parrot client executable
parrot/Tests/            Parrot client tests
scripts/test-all.sh     One command for both test suites
```

The repository root is the native Swift package. The Parrot client is a
nested Swift package so each executable keeps its own dependency graph while
Git, documentation, CI, and release work stay in one project.

## Development commands

```sh
swift build
swift test
swift run syrinx version --json
swift run syrinx doctor --json
cd parrot && swift build && swift test
```

Syrinx targets macOS 14 or later on Apple Silicon. The source license is MIT.
The model license review, owner and security metadata, Apple signing and
notarization, and clean-machine release verification remain open release
gates. See [docs/release-gates.md](docs/release-gates.md) and
[docs/model-license-review.md](docs/model-license-review.md).
