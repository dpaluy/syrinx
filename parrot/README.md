# Parrot client

Parrot is the push-to-talk client in the Syrinx repository. It captures audio,
calls the native Syrinx service, and inserts the transcript at the cursor.

## Build from the Syrinx repository

```sh
cd parrot
swift build -c release
swift test
swift run parrot setup
```

Parrot requires macOS 14 or later on Apple Silicon. A binary installer is not
published yet. Use the source build while the unified Syrinx release process
is being completed.

## How to use

1. **Run it.** Either `parrot install --launch-at-login` (daemonized, runs forever, lives in the menu bar), or `parrot` in any terminal tab.
2. **Click into the text field you want to dictate into**  -  Messages, the address bar, a Slack thread, anywhere a cursor blinks.
3. **Hold the `fn` key, speak, release.** A small pill appears at the bottom of the screen while the mic is hot.
4. **The transcript types itself in at the cursor** when you release. Usually within 200-300ms.

That's it. There is no record button, no stop button, no "send"  -  `fn` is the whole interface.

> **Note:** on most modern Macs the `fn` key is the bottom-left key. If yours is set to "Change input source" or "Show emoji & symbols," `parrot setup` will tell you how to flip it back to plain `fn`.

## CLI

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

## Parakeet local service (optional)

WhisperKit remains the recommended default. `parakeet-tdt-0.6b-v3` uses a
user-managed local HTTP service; Parrot does not install the service or its
model files. Syrinx is the supported native service and keeps the model on the
same Mac without Docker:

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

The measured Apple Silicon Docker runtime reached health in about two seconds,
used up to 1.47 GiB on short fixtures (reserve 2 GiB per worker), and had
post-upload p95 latency of 309 ms for five-second clips and 397 ms for
ten-second clips. This is CPU/ONNX Runtime inference, not WhisperKit's
CoreML/ANE path. The runtime evidence does not establish a quality comparison
with WhisperKit.

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
