# Syrinx client architecture

The end-user executable is the `syrinx` target, packaged as `Syrinx.app`.
`ParrotCLI` is a development-only executable target. Both use the shared
`SyrinxClient` library.

## Runtime flow

```text
Syrinx.app
   |
   +--> first-run permission guidance
   |
   +--> HotkeyMonitor --> AudioCapture --> WhisperKitTranscriber --> TextOutputting
   |                         |                    |                      |
   |                         |                    |                CGEvent or paste
   |                         +--> RecordingOverlay
   |                         +--> MenuBarController
   |
   +--> local UserDefaults and WhisperKit model files
```

1. The app explains Microphone and Accessibility access and asks the user to
   set Fn or Globe to Do Nothing.
2. `HotkeyMonitor` observes Fn press and release after Accessibility access is
   granted.
3. `AudioCapture` records 16 kHz mono samples only while Fn is held.
4. `WhisperKitTranscriber` loads the local Whisper model and transcribes the
   completed sample buffer in process.
5. The injected `TextOutputting` boundary sends the sanitized result through
   direct CGEvent typing by default or through explicit clipboard paste mode.
6. Clipboard paste restores all prior item representations only when the
   pasteboard change count still matches Syrinx's write.
7. The overlay and menu bar item show recording and transcription state.

Syrinx does not infer whether an application accepted direct typing. Secure
fields and some Electron applications can reject synthesized text. The last
successful transcript stays in process memory for Copy Last Dictation and is
not stored on disk.

The app does not request Full Disk Access, Screen Recording, Input Monitoring,
or Automation. It does not start a child model service or send audio to a
network endpoint.

## Development-only components

The package retains the Parakeet loopback adapter and the `parrot` CLI for
development and integration tests. The optional native service and Docker
commands belong to the root package. None of these components are used by the
`syrinx` app target or included in its first-run instructions.

## Source layout

```text
Sources/parrot/
  Audio/             Microphone capture and WAV test helpers
  Input/             Fn monitor and cursor text injection
  Models/            Whisper model registry
  Transcription/     In-process WhisperKit path and dev adapters
  UI/                Overlay and menu bar state
  AppContract.swift  Product identity and permission copy
  DictationSession.swift
Sources/SyrinxApp/   App entry point and permission flow
Sources/ParrotCLI/   Development CLI entry point
Resources/SyrinxApp/Info.plist
```
