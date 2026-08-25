# Implementation dependency tree

The implementation stages and dependencies are fixed for this plan:

```text
T00 bootstrap
├── T01 FluidAudio proof
├── T02 model-manifest proof
└── T03 HTTP upload proof

T10 runtime integration       <- T00 + T01
T20 model lifecycle           <- T00 + T02
T30 safe transcription        <- T10 + T20
T40 HTTP service              <- T30 + T03
T50 packaging/release         <- T40
T60 full verification         <- T00 + T01 + T02 + T03 + T10 + T20 + T30 + T40 + T50
```

| Stage | Meaning | Depends on |
|---|---|---|
| T00 | bootstrap | none |
| T01 | FluidAudio proof | none |
| T02 | model-manifest proof | none |
| T03 | HTTP upload proof | none |
| T10 | runtime integration | T00, T01 |
| T20 | model lifecycle | T00, T02 |
| T30 | safe transcription | T10, T20 |
| T40 | HTTP service | T30, T03 |
| T50 | packaging/release | T40 |
| T60 | full verification | T00, T01, T02, T03, T10, T20, T30, T40, T50 |

T00 through T50 are implemented on `cdx/syrinx-finalize`. The available T60
automated checks pass: 430 tests ran with 6 real-model cases skipped because a
managed model revision and audio fixture are not present. Release verification
still requires approved owner and security metadata, model license review,
Apple signing, notarization, and clean-machine evidence.
