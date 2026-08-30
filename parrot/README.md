# Syrinx client development package

This package contains the reusable push-to-talk client and the `Syrinx.app`
executable target. End users download `Syrinx.app` from GitHub Releases. They
do not run this package, its CLI, or a source build.

## Build and test

Run these commands from this directory:

```sh
swift build --product syrinx --configuration release
swift test
```

Build an unsigned distribution archive from the repository root:

```sh
./scripts/release/build-app.sh --swift-build --unsigned-dry-run \
  --skip-source-validation
```

The archive is local test evidence only. It is not signed, notarized, or
published.

## App behavior

Syrinx runs as a menu bar-only application. On first launch it explains the
required Microphone and Accessibility permissions and the required Fn or
Globe key setting, Do Nothing. It downloads the recommended Whisper Base
English model through WhisperKit and keeps audio and transcription in the
process on the Mac.

After setup, click into any text field, hold Fn, speak, and release Fn. The
transcript is inserted at the active cursor. Direct typing with CGEvent is the
default. Some Electron applications and secure fields can reject direct typing.
Syrinx does not detect this condition automatically.

Users can select Clipboard paste in Settings for an incompatible destination.
Syrinx snapshots all clipboard item representations, pastes the transcript,
and restores the snapshot only if no other process changed the clipboard. The
Copy Last Dictation menu action copies the last nonempty transcript. Syrinx
keeps that transcript only in memory and clears it when the app quits.

Press Escape while recording or transcribing to cancel the current dictation.
Syrinx discards canceled audio and suppresses results that arrive after a
cancel or stop. A recording that reaches 60 seconds stops and transcribes once.

## Development CLI

The `parrot` executable remains for client tests and local diagnostics. It is
not included in the end-user application flow:

```sh
swift run parrot --help
```

The development executable can also be used for local client work:

```sh
parrot                                 # run in the foreground
parrot setup                           # one-time permission setup
parrot install --launch-at-login       # register a LaunchAgent
parrot install --uninstall             # remove the LaunchAgent
parrot doctor                          # check permissions and Fn setting
parrot models list                     # list available models
parrot models download <id>            # pre-download a model
parrot --model whisper-large-v3-turbo  # bigger, multilingual, slower first-run
parrot --hotkey right-option           # change the push-to-talk key
parrot --no-overlay                    # disable the recording overlay
```

## Parakeet development integration

This integration is not part of the end-user application workflow.
`parakeet-tdt-0.6b-v3` uses a developer-managed local HTTP service. Parrot does
not install the service or its model files. Before installing its model, read
the [model license review](../docs/model-license-review.md).

```sh
syrinx models install --activate
syrinx service install
syrinx service start
curl http://127.0.0.1:5092/health
parrot run --model parakeet-tdt-0.6b-v3 --syrinx-url http://127.0.0.1:5092
```

The compatible upstream Docker service remains available as a development
alternative:

```sh
docker run -d --rm --name parrot-parakeet -p 127.0.0.1:5092:5092 \
  -e PARAKEET_WORKERS=1 \
  ghcr.io/achetronic/parakeet:0.8.0-int8
curl http://127.0.0.1:5092/health
parrot run --model parakeet-tdt-0.6b-v3 --parakeet-url http://127.0.0.1:5092
```

When finished, run `docker stop parrot-parakeet`. The container is removed by
the `--rm` option.

The health endpoint must return `{"status":"ok"}` before Parrot starts. Only
`127.0.0.1`, `localhost`, and `::1` URLs are accepted. If the service uses
bearer authentication, set `PARROT_SYRINX_API_KEY` in the environment. Do not
place the token on the command line.

The server is [Apache-2.0](https://github.com/achetronic/parakeet) and its
converted NVIDIA Parakeet TDT 0.6B v3 ONNX model is
[CC-BY-4.0](https://huggingface.co/istupakov/parakeet-tdt-0.6b-v3-onnx).

## Source layout

```text
Sources/parrot/       Shared client behavior
Sources/SyrinxApp/    Syrinx.app entry point and permission flow
Sources/ParrotCLI/    Development-only CLI entry point
Resources/SyrinxApp/  App Info.plist
Tests/parrotTests/    Client and app contract tests
```

## Stack

- **Swift**  -  Swift Package Manager targets
- **WhisperKit**  -  in-process local Whisper inference
- **Parakeet service adapter**  -  optional loopback HTTP development path
- **AVAudioEngine**  -  microphone capture
- **CGEventTap**  -  global hotkey
- **CGEvent**  -  text injection at the cursor
- **NSWindow**  -  recording indicator overlay

See [docs/architecture.md](docs/architecture.md) for design notes and the
root README for the complete Syrinx project workflow.
