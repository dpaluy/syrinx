# Parrot development component

Parrot is the push-to-talk client used by the Syrinx Mac application. It
captures audio, uses in-process WhisperKit or the local Syrinx service, and
inserts the transcript at the cursor. This package is for development. End
users install and open the Syrinx application.

## Development

Development requires Xcode 16 or later, or matching Swift 6 command-line
tools. Run these commands from the `parrot` directory:

```sh
swift build
swift test
```

Run the development executable:

```sh
.build/debug/parrot setup
.build/debug/parrot doctor
.build/debug/parrot
```

## How to use

1. **Run it.** Either `parrot install --launch-at-login` (daemonized, runs forever, lives in the menu bar), or `parrot` in any terminal tab.
2. **Click into the text field you want to dictate into**  -  Messages, the address bar, a Slack thread, anywhere a cursor blinks.
3. **Hold the `fn` key, speak, release.** A small pill appears at the bottom of the screen while the mic is hot.
4. **The transcript types itself in at the cursor** when you release.

That's it. There is no record button, no stop button, no "send"  -  `fn` is the whole interface.

> **Note:** on most modern Macs the `fn` key is the bottom-left key. If yours is set to "Change input source" or "Show emoji & symbols," `parrot setup` will tell you how to flip it back to plain `fn`.

## Development CLI

The examples below use `parrot` as shorthand for the development executable.

```sh
parrot                                 # run in the foreground (^C to quit)
parrot setup                           # one-time permission setup
parrot install --launch-at-login       # register a LaunchAgent (background daemon)
parrot install --uninstall             # remove the LaunchAgent
parrot doctor                          # check permissions + fn key setting
parrot models list                     # list available models
parrot models download <id>            # pre-download a model
parrot --model whisper-large-v3-turbo  # bigger, multilingual, slower first-run
parrot run --model parakeet-tdt-0.6b-v3 --syrinx-url http://127.0.0.1:5092
parrot --hotkey right-option           # change the push-to-talk key
parrot --no-overlay                    # disable the bottom-of-screen pill
```

## Parakeet development integration

This integration is not part of the end-user application workflow.
`parakeet-tdt-0.6b-v3` uses a developer-managed local HTTP service. Parrot does
not install the service or its model files. Syrinx is the supported native
development service and keeps the model on the same Mac without Docker:

```sh
syrinx models install --activate
syrinx service install
syrinx service start
curl http://127.0.0.1:5092/health
parrot run --model parakeet-tdt-0.6b-v3 --syrinx-url http://127.0.0.1:5092
```

The compatible upstream Docker service remains available as an alternative:

```sh
docker run -d --rm --name parrot-parakeet -p 127.0.0.1:5092:5092 \
  -e PARAKEET_WORKERS=1 \
  ghcr.io/achetronic/parakeet:0.8.0-int8
curl http://127.0.0.1:5092/health
parrot run --model parakeet-tdt-0.6b-v3 --parakeet-url http://127.0.0.1:5092
```

When finished, run `docker stop parrot-parakeet`; `--rm` removes the stopped
container automatically.

The health endpoint must return `{"status":"ok"}` before Parrot starts.
Only `127.0.0.1`, `localhost`, and `::1` URLs are accepted; use
`--parakeet-url` to select another port or loopback spelling. If the service
uses bearer authentication, set `PARROT_SYRINX_API_KEY` in the environment.
`PARROT_PARAKEET_API_KEY` remains supported for compatibility; do not place
the token on the command line.

The server is [Apache-2.0](https://github.com/achetronic/parakeet) and its
converted NVIDIA Parakeet TDT 0.6B v3 ONNX model is
[CC-BY-4.0](https://huggingface.co/istupakov/parakeet-tdt-0.6b-v3-onnx).

## Stack

- **Swift**  -  single SPM executable target
- **WhisperKit**  -  Whisper inference via CoreML, ANE-accelerated
- **Parakeet service adapter**  -  optional loopback HTTP transcription
- **AVAudioEngine**  -  mic capture
- **CGEventTap**  -  global hotkey
- **CGEvent**  -  text injection at cursor
- **NSWindow** (borderless, click-through)  -  recording-indicator pill

See [docs/architecture.md](docs/architecture.md) for design notes and the root
README for the complete Syrinx project workflow.
