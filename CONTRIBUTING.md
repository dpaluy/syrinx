# Contributing

Bug reports and focused pull requests are welcome. For a large behavior or
architecture change, open an issue before implementation so the scope can be
agreed first.

## Development requirements

- Apple Silicon Mac with macOS 14 or later
- Swift 6 toolchain
- No model files, audio fixtures, credentials, or personal data in Git

Keep changes scoped. Add tests for observable behavior. Do not weaken
loopback, authentication, filesystem, size, timeout, cleanup, or redaction
checks.

Before opening a pull request, run:

```sh
./scripts/test-all.sh
./scripts/clean-source-audit.sh
./scripts/release/validate-workflow.sh
```

State which checks passed and which environment-dependent checks were skipped.
Do not claim real-model, signing, notarization, installation, or clean-machine
verification unless you ran that exact check.

By submitting a contribution, you agree that it is licensed under the
repository's MIT License.
