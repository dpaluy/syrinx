# Third-party notices

## FluidAudio

- Project: [FluidAudio](https://github.com/FluidInference/FluidAudio)
- Version: `v0.15.5`
- Revision: `19600a485baa4998812e4654b70d2bab8f2c9949`
- License: Apache License 2.0
- Bundled license: [LICENSES/FluidAudio-LICENSE.txt](LICENSES/FluidAudio-LICENSE.txt)
- License source: [FluidAudio LICENSE](https://github.com/FluidInference/FluidAudio/blob/19600a485baa4998812e4654b70d2bab8f2c9949/LICENSE)

Syrinx uses FluidAudio only through its public ASR API. Model files are not
included. Model staging and attribution are handled separately.

## Hummingbird

- Project: [Hummingbird](https://github.com/hummingbird-project/hummingbird)
- Version: `2.26.0`
- Revision: `55bc9025a4825ee2a234b1f82b51b87be6ef74e4`
- License: Apache License 2.0
- Bundled license: [LICENSES/Hummingbird-LICENSE.txt](LICENSES/Hummingbird-LICENSE.txt)
- License source: [Hummingbird LICENSE](https://github.com/hummingbird-project/hummingbird/blob/55bc9025a4825ee2a234b1f82b51b87be6ef74e4/LICENSE.txt)

Hummingbird provides the HTTP/1 server, routing, request body stream, header
limits, loopback bind, idle timeout, and service lifecycle integration.

## swift-service-lifecycle

- Project: [swift-service-lifecycle](https://github.com/swift-server/swift-service-lifecycle)
- Version: `2.11.0`
- Revision: `9829955b385e5bb88128b73f1b8389e9b9c3191a`
- License: Apache License 2.0
- Bundled license: [LICENSES/swift-service-lifecycle-LICENSE.txt](LICENSES/swift-service-lifecycle-LICENSE.txt)
- License source: [swift-service-lifecycle LICENSE](https://github.com/swift-server/swift-service-lifecycle/blob/9829955b385e5bb88128b73f1b8389e9b9c3191a/LICENSE.txt)

swift-service-lifecycle supplies the graceful shutdown coordination used by
Hummingbird and transport lifecycle tests.

## Parrot client dependencies

The nested `parrot` package has its own pinned dependency graph in
`parrot/Package.resolved`. Direct dependencies are:

- [Swift Argument Parser](https://github.com/apple/swift-argument-parser),
  Apache License 2.0, revision `626b5b7b2f45e1b0b1c6f4a309296d1d21d7311b`.
- [WhisperKit](https://github.com/argmaxinc/WhisperKit), MIT License,
  revision `e2adabbe7d98dc4d0ab9a5b75424ecc42a9cdbef`.

The Parrot component retains its original MIT notice in
`parrot/LICENSE`. License texts for the Parrot dependency graph are copied
under `LICENSES/`.

The model manifest records Core ML model attribution and the unresolved
license conflict. No model bytes are present in this repository.

## Parakeet TDT 0.6B v3 Core ML model

- Publisher: FluidInference
- Immutable source: [FluidInference/parakeet-tdt-0.6b-v3-coreml](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml/tree/aed02740059203c4a87495924f685de3722ae9ce)
- Base model: `nvidia/parakeet-tdt-0.6b-v3`
- Declared metadata license: CC BY 4.0
- Rendered model-card license section: Apache 2.0
- Included model bytes: none

The immutable model card contains conflicting license declarations. This
repository records the conflict and does not claim that the model is approved
for redistribution. Release packaging must remain blocked until FluidInference
confirms the applicable license in writing.

MacParakeet and achetronic/parakeet are research references only. No source,
assets, package identity, branding, history, or binary files from either
project are included here.
