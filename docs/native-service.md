# Syrinx

Syrinx is a native macOS speech service for local Parakeet transcription.

The service runs on macOS 14 or later on Apple Silicon. It provides:

```text
syrinx version [--json]
syrinx doctor [--json]
syrinx transcribe <wav>
syrinx serve
syrinx service <install|start|stop|restart|status|logs|uninstall|purge>
syrinx models <install|list|verify|path|activate|rollback|gc>
```

The HTTP service binds to `127.0.0.1:5092` by default and implements the
loopback contract consumed by Parrot. Authentication is available for local
service requests, and non-loopback binding is rejected.

Model bytes are never bundled. Install the pinned Parakeet model into the
managed per-user model store after completing the model license review.

## Development

```sh
swift build
swift test
.build/debug/syrinx version --json
.build/debug/syrinx doctor --json
.build/debug/syrinx service install
.build/debug/syrinx service start
```

The `SYRINX_` environment variables define the local service configuration.
The default service endpoint is compatible with Parrot's
`parakeet-tdt-0.6b-v3` model adapter.

Version JSON includes `project_version`, `commit`, `build_target`, `build_date`,
`swift_version`, `fluid_audio`, and `reproducible_build_status`.

## Release status

The product identity is `Syrinx`, the executable is `syrinx`, and the source
license is MIT. Public release remains blocked by the model license conflict,
missing owner and security contact metadata, Apple signing and notarization,
and clean-machine verification. See [release-gates.md](release-gates.md)
and [model-license-review.md](model-license-review.md).
