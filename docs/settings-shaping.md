---
shaping: true
---

# Syrinx settings and status

## Source

> This application works really well, but we need to create some configuration. First, after the centers are stopped, we should create a space. Another definition that we need to add is ability to start at logging the service. Also, we need an option to select the shortcut key. It has to be changed according to user preferences. Also, we should display the current version and the model we are using. When the model is downloaded, we should indicate that.
>
> Remove all tests from .github ci
>
> Let's plan this functionality.

## Confirmed decisions

| ID | Decision |
|---|---|
| D1 | “After the centers are stopped” means that Syrinx adds one ASCII space after each successful, nonempty dictation before it inserts the text. This behavior is an enabled-by-default preference. |
| D2 | The shortcut remains a hold-to-record control. The first release offers Fn or Globe, Right Command, and Right Option. It does not support arbitrary multi-key chords. |
| D3 | “Start at logging” means “launch Syrinx at macOS login.” It applies to the packaged Syrinx app, not the legacy `parrot` CLI LaunchAgent. |
| D4 | “Downloaded” means that WhisperKit resolved the selected model to local files. “Ready” means that the model also loaded successfully. |
| D5 | “Remove all tests from .github ci” means remove the two `swift test` steps from `.github/workflows/ci.yml`. Keep build and audit steps, local test targets, and `.github/workflows/release.yml` unchanged. |

## Problem

Syrinx has no settings surface. The packaged app always uses the recommended Whisper model, always listens for Fn or Globe, and inserts the transcript without a trailing space. Users cannot enable launch at login. The menu shows the model identifier but not the app version or a clear model download state. The main CI workflow runs both native and client test suites.

## Outcome

Users can open one settings window from the menu bar, change dictation spacing, select a supported hold shortcut, and control launch at login. The same window shows the packaged version, active model, and model download or readiness state. The main CI workflow builds and audits without running test commands.

## Requirements

| ID | Requirement | Status |
|---|---|---|
| R0 | Give users one persistent settings surface from the menu-bar app. | Core goal |
| R1 | Let users enable or disable one trailing space after each successful, nonempty dictation. The default is enabled. | Must-have |
| R2 | Let users select Fn or Globe, Right Command, or Right Option as the hold-to-record shortcut. Persist the choice and apply it without an app relaunch. | Must-have |
| R3 | Let users enable or disable launch at login for the packaged Syrinx app. Show approval and failure states without claiming success. | Must-have |
| R4 | Display the packaged app version and the active transcription model. | Must-have |
| R5 | Display whether the model is checking, downloading, downloaded, loading, ready, or failed. | Must-have |
| R6 | Remove test commands from `.github/workflows/ci.yml` while retaining build and source or workflow audit steps. | Must-have |
| R7 | Preserve the current permission flow, local transcription behavior, menu-bar lifecycle, and local test targets. | Must-have |

## CURRENT: Fixed menu-bar app

| Part | Mechanism | Flag |
|---|---|:---:|
| CURRENT1 | `SyrinxAppDelegate` selects `ModelRegistry.recommended()` and creates one `DictationSession`. | |
| CURRENT2 | `DictationSession` creates `HotkeyMonitor()` with the fixed Fn flag and sends raw successful text to `TextInjector.inject(_:)`. | |
| CURRENT3 | `MenuBarController` shows runtime state and the model identifier, then provides only Quit. | |
| CURRENT4 | `WhisperKitTranscriber.prepare()` lets `WhisperKit` download and load in one opaque initialization call. | |
| CURRENT5 | `.github/workflows/ci.yml` runs `swift test` in both the root and `parrot` packages. | |

## A: AppKit settings with persisted runtime preferences

| Part | Mechanism | Flag |
|---|---|:---:|
| A1 | Add `AppPreferences`, backed by `UserDefaults`, with typed keys for trailing space and the selected `HotkeyChoice`. | |
| A2 | Add an AppKit `SettingsWindowController`. Open it from a new “Settings…” menu item and keep the menu-bar-only app lifecycle. | |
| A3 | Add “Add a space after dictation” as a checkbox. Route successful transcripts through a pure text-output policy before `TextInjector.inject(_:)`. | |
| A4 | Add a shortcut popup for Fn or Globe, Right Command, and Right Option. Represent each choice with its Core Graphics key code and modifier flag. Restart the event tap after an idle-state selection change. | |
| A5 | Add a `LoginItemController` around `SMAppService.mainApp`. Read its actual status, register or unregister only after the user changes the checkbox, and show “Needs approval” or an error when applicable. | |
| A6 | Read the version from the packaged bundle. Pass the active `TranscriptionModel` and app version into a shared observable settings state. | |
| A7 | Split Whisper model resolution from loading. Use the pinned WhisperKit 0.18.0 download API and progress callback, then initialize from the resolved local folder with download disabled. Publish checking, downloading, downloaded, loading, ready, and failed states. | |
| A8 | Bind the settings labels and the existing menu status to the shared observable state. Disable the shortcut popup while recording or transcribing. | |
| A9 | Delete only the two `swift test` steps from `.github/workflows/ci.yml`. Keep repository tests and release workflow checks. | |

## Fit check: R x A

| Req | Requirement | Status | A |
|---|---|---|:---:|
| R0 | Give users one persistent settings surface from the menu-bar app. | Core goal | ✅ |
| R1 | Let users enable or disable one trailing space after each successful, nonempty dictation. The default is enabled. | Must-have | ✅ |
| R2 | Let users select Fn or Globe, Right Command, or Right Option as the hold-to-record shortcut. Persist the choice and apply it without an app relaunch. | Must-have | ✅ |
| R3 | Let users enable or disable launch at login for the packaged Syrinx app. Show approval and failure states without claiming success. | Must-have | ✅ |
| R4 | Display the packaged app version and the active transcription model. | Must-have | ✅ |
| R5 | Display whether the model is checking, downloading, downloaded, loading, ready, or failed. | Must-have | ✅ |
| R6 | Remove test commands from `.github/workflows/ci.yml` while retaining build and source or workflow audit steps. | Must-have | ✅ |
| R7 | Preserve the current permission flow, local transcription behavior, menu-bar lifecycle, and local test targets. | Must-have | ✅ |

## Detail A: Breadboard

### Places

| # | Place | Description |
|---|---|---|
| P1 | Menu bar | Existing persistent app control surface. |
| P2 | Settings window | New nonmodal settings and status surface. |
| P3 | Dictation runtime | Hotkey, recording, transcription, and text insertion boundary. |
| P4 | macOS login services | External launch-at-login state managed by ServiceManagement. |
| P5 | Whisper model store | External local model cache and WhisperKit lifecycle. |

### UI affordances

| # | Place | Component | Affordance | Control | Wires Out | Returns To |
|---|---|---|---|---|---|---|
| U1 | P1 | `MenuBarController` | “Settings…” item | click | → P2 | None |
| U2 | P1 | `MenuBarController` | runtime status label | render | None | None |
| U3 | P1 | `MenuBarController` | model label | render | None | None |
| U4 | P2 | `SettingsWindowController` | “Add a space after dictation” checkbox | toggle | → N3 | None |
| U5 | P2 | `SettingsWindowController` | shortcut popup | select | → N4 | None |
| U6 | P2 | `SettingsWindowController` | “Launch at login” checkbox | toggle | → N8 | None |
| U7 | P2 | `SettingsWindowController` | login approval or error text | render | None | None |
| U8 | P2 | `SettingsWindowController` | version label | render | None | None |
| U9 | P2 | `SettingsWindowController` | active model label | render | None | None |
| U10 | P2 | `SettingsWindowController` | model state label and progress indicator | render | None | None |

### Code affordances

| # | Place | Component | Affordance | Control | Wires Out | Returns To |
|---|---|---|---|---|---|---|
| N1 | P2 | `SettingsWindowController` | `showWindow(_:)` | call | → N2, → N7 | → U4, U5, U6, U7, U8, U9, U10 |
| N2 | P2 | `AppPreferences` | load typed preferences | call | None | → N1, N5 |
| N3 | P2 | `AppPreferences` | set trailing-space preference | call | → S1 | → U4 |
| N4 | P2 | `AppPreferences` | set `HotkeyChoice` | call | → S1, → N5 | → U5 |
| N5 | P3 | `DictationSession` | apply selected hotkey while idle | call | → N6 | → U2, U5 |
| N6 | P3 | `HotkeyMonitor` | restart event tap for key code and flags | call | None | → N5 |
| N7 | P4 | `LoginItemController` | read `SMAppService.mainApp.status` | call | None | → U6, U7 |
| N8 | P4 | `LoginItemController` | register or unregister main app | call | → S2, → N7 | → U6, U7 |
| N9 | P3 | `DictationSession` | handle successful transcription | call | → N10, → N11 | None |
| N10 | P3 | `TextOutputPolicy` | format transcript | call | None | → N9 |
| N11 | P3 | `TextInjector` | `inject(_:)` | call | → S4 | None |
| N12 | P5 | `WhisperKitTranscriber` | resolve model with progress callback | call | → S3 | → N13, U10 |
| N13 | P5 | `WhisperKitTranscriber` | load resolved local model | call | → S3 | → U2, U10 |
| N14 | P2 | app metadata | read bundle version and active model | call | None | → U8, U9 |

### Data stores

| # | Place | Store | Description |
|---|---|---|---|
| S1 | P3 | `UserDefaults` preferences | Trailing-space and shortcut values. |
| S2 | P4 | `SMAppService.mainApp` status | System-owned launch-at-login registration and approval state. |
| S3 | P5 | model lifecycle state | Checking, downloading progress, downloaded, loading, ready, or failed. |
| S4 | P3 | active app text field | External cursor destination changed by synthesized keyboard events. |

## Boundaries

- Do not add model selection. Show the model that the current session uses.
- Do not reuse or modify the legacy `com.digimata.parrot` LaunchAgent.
- Do not add arbitrary key chords in this change.
- Do not remove test files, SwiftPM test targets, release checks, or local test commands.
- Do not change microphone, Accessibility, or local-only data behavior.
