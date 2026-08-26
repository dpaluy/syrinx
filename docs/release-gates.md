# Release gates

## End-user app

A release may describe a downloadable Syrinx application only when all of
these gates have evidence for the exact tagged commit:

1. The `Syrinx.app` bundle has product name `Syrinx`, executable `syrinx`,
   bundle identifier `com.dpaluy.syrinx`, and minimum macOS 14.0.
2. The app declares Microphone and Accessibility usage descriptions only.
3. The app uses the in-process WhisperKit path and contains no downloaded model
   bytes.
4. The build job passes both client package tests, the clean-source audit, and
   app archive verification.
5. Developer ID Application signing succeeds on the protected arm64 runner.
6. Apple notarization returns `Accepted`, the ticket is stapled, and
   Gatekeeper accepts the app.
7. The signed archive is independently verified before GitHub publication.

The local unsigned dry run proves only the local build, bundle, plist,
archive, and checksum checks. It does not prove signing, notarization,
stapling, Gatekeeper, installation, or publication.

## Public source repository

Keep the repository private until the complete-source audit, both package test
suites, release workflow validation, and release fixture suite pass on the
commit that will become public. Change repository visibility only with
explicit approval, then enable and verify private vulnerability reporting.

## Native service

The root native Parakeet service, model lifecycle, loopback HTTP contract,
Docker integration, and their CLI release tooling are development and
integration components. They are not release gates for the end-user
`Syrinx.app`.
