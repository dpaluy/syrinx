# Parrot architecture

Parrot is a macOS push-to-talk client. It records only while the configured
hotkey is held, transcribes the completed recording, and inserts the result at
the active text cursor.

## Runtime flow

```text
HotkeyMonitor
      |
      v
AudioCapture --> Transcriber --> TextInjector
                      |
                      +--> WhisperKitTranscriber, in-process Core ML
                      |
                      +--> ParakeetTranscriber
                                  |
                                  +--> ParakeetHTTPAdapter, loopback HTTP

RecordingOverlay and MenuBarController show the current state.
```

1. `HotkeyMonitor` emits pressed and released events for the selected key.
2. `AudioCapture` records 16 kHz mono samples while the key is held.
3. The selected `Transcriber` converts the completed sample buffer to text.
4. `TextInjector` inserts the sanitized transcript at the active cursor.
5. The overlay and menu-bar item report recording and transcription state.

Parrot does not keep a transcript history or send audio to a cloud service.

## Commands

`Parrot.swift` defines the command-line interface:

- `parrot run` starts the dictation process;
- `parrot setup` requests and explains required permissions;
- `parrot doctor` checks microphone, Accessibility, and Fn-key state;
- `parrot models` lists or downloads supported model configurations;
- `parrot install` manages the launch-at-login LaunchAgent.

## Transcription engines

### WhisperKit

`WhisperKitTranscriber` loads an in-process Core ML model. The recommended
model is Whisper Base English. WhisperKit downloads the selected model when it
is not already present.

### Parakeet

`ParakeetTranscriber` delegates service access to `ParakeetHTTPAdapter`. The
adapter accepts only loopback URLs, checks service health, sends an in-memory
WAV multipart request, and decodes the response. Syrinx is the supported native
service. A compatible user-managed loopback service can also be used.

Authentication tokens come from `PARROT_SYRINX_API_KEY` or the compatibility
variable `PARROT_PARAKEET_API_KEY`. Tokens are not accepted as command-line
arguments.

## macOS integration

Parrot uses:

- `CGEventTap` for the global push-to-talk hotkey;
- `AVAudioEngine` for microphone capture;
- `CGEventKeyboardSetUnicodeString` for text insertion;
- a borderless, click-through `NSWindow` for recording state;
- an accessory `NSApplication` and menu-bar controller for process state.

Microphone and Accessibility permissions belong to the terminal or process
that launches Parrot. A launch-at-login installation can require a separate
permission grant because macOS identifies it differently from an interactive
terminal process.

## Source layout

```text
Sources/parrot/
  Adapters/          Loopback service contract
  Audio/             Capture and WAV encoding
  Input/             Hotkey and text insertion
  Models/            Supported transcription models
  Transcription/     Engine protocol and implementations
  UI/                Overlay and menu-bar state
  Doctor.swift       Environment checks
  Install.swift      LaunchAgent management
  Parrot.swift       Command-line interface and runtime composition
  Setup.swift        Permission setup
```

The package is separate from the root Syrinx package so WhisperKit and the
native service keep independent dependency graphs.
