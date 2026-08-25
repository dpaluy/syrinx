# Compatibility

Syrinx targets:

- macOS 14 or later;
- Apple Silicon, arm64;
- Swift tools version 6.0;
- one local executable with version, doctor, model, transcription, HTTP, and
  service lifecycle commands;
- Parrot's loopback upload contract on `127.0.0.1:5092`.

Syrinx does not support Linux, Windows, Intel, CUDA, Docker as a runtime
dependency, Go, Python, or ffmpeg.
