---
shaping: true
---

# Syrinx settings and status slices

Ground truth: `docs/settings-shaping.md`.

## Delivery sequence

| Slice | Demo result | Main scope |
|---|---|---|
| V1 | Open Settings from the menu bar and see the real version, active model, and live model state. | Settings shell, metadata, model lifecycle state. |
| V2 | Change the spacing option, dictate text, and see the selected spacing behavior. | Persisted preferences and output policy. |
| V3 | Select a supported shortcut and use it without restarting Syrinx. | Hotkey choice, idle-state event-tap restart, runtime status. |
| V4 | Toggle launch at login and see the actual macOS registration or approval state. | `SMAppService.mainApp` integration. |

The GitHub Actions removal is a delivery task after V4. It is not a product slice because it has no user-visible app output.

## V1: Settings, app identity, and model state

### Behavior

- Add “Settings…” above Quit in the menu.
- Create one reusable AppKit settings window.
- Show `CFBundleShortVersionString`, the active model display name and identifier, and the live model lifecycle state.
- Refactor WhisperKit preparation into explicit model resolution and model loading so the UI can distinguish downloaded from ready.
- Keep dictation unavailable until the model is ready. Keep the current failure status if resolution or loading fails.

### TDD order

1. Add tests for bundle-version fallback and model-state-to-display mapping.
2. Add tests that cached and newly resolved models both reach downloaded, loading, and ready in order through an injected model loader.
3. Add the settings state and window.
4. Connect `DictationSession.prepare()` and `MenuBarController` to the shared state.
5. Run the `parrotTests` suite and build the packaged app target.

### Acceptance evidence

- A packaged build shows its actual version, not a source constant.
- The model label identifies the `TranscriptionModel` passed to `DictationSession`.
- A clean model location shows downloading, then downloaded, loading, and ready.
- A cached model still shows downloaded before ready.
- A failed resolution or load shows failed and does not start the hotkey monitor.

## V2: Persistent trailing-space behavior

### Behavior

- Add `AppPreferences` with the trailing-space setting defaulted to true.
- Add the checkbox to Settings.
- Add a pure `TextOutputPolicy` between transcription and `TextInjector`.
- If enabled, append one ASCII space to each successful, nonempty sanitized transcript. If disabled, preserve the sanitized transcript exactly.
- Never inject a space for an empty transcript or a failed transcription.

### TDD order

1. Add output-policy tests for text without punctuation, text with sentence punctuation, existing trailing whitespace, empty text, and disabled behavior.
2. Add preference default and persistence tests with an isolated `UserDefaults` suite.
3. Add the policy and checkbox.
4. Route both app and CLI dictation insertion paths through the policy only if both products must share this preference. The packaged app is the required path.
5. Run focused policy and preference tests, then `parrotTests`.

### Acceptance evidence

- The enabled setting inserts exactly one trailing space.
- The disabled setting inserts no added space.
- The setting survives quit and relaunch.
- Empty and failed transcriptions insert nothing.

## V3: Persistent shortcut selection

### Behavior

- Add `HotkeyChoice` values for Fn or Globe, Right Command, and Right Option.
- Persist the selected value, with Fn or Globe as the default.
- Change `HotkeyMonitor` from a fixed modifier mask to a selected key-code and flags policy.
- While idle, stop the existing event tap, register the new choice, and update the status text. If registration fails, restore the prior working choice and show the failure.
- Disable shortcut selection while recording or transcribing.

### TDD order

1. Add edge-detection tests for each supported key, unrelated keys, repeated flag events, and release events.
2. Add tests for preference decoding with an unknown stored value and fallback to Fn or Globe.
3. Add session tests for successful restart and rollback after registration failure by using an injected monitor factory.
4. Add the popup and runtime wiring.
5. Run focused hotkey and session tests, then `parrotTests`.

### Acceptance evidence

- Each listed choice starts on press and stops on release.
- A choice applies without app relaunch when the session is idle.
- A failed change leaves the previous shortcut active.
- The choice survives quit and relaunch.

## V4: Launch at login

### Behavior

- Add a small `LoginItemController` around `SMAppService.mainApp`.
- Initialize the checkbox from the system service status, not from `UserDefaults`.
- Register or unregister only after a user toggle.
- Show enabled, disabled, needs approval, not found, and operation failure states.
- Keep the current app running after unregister.

### TDD order

1. Add status-mapping and toggle-command tests with an injected service adapter. Do not mutate the real login item in unit tests.
2. Add the controller and Settings bindings.
3. Run focused controller tests and `parrotTests`.
4. Build and sign a disposable app bundle.
5. Manually verify enable, relogin launch, disable, and relogin absence with the disposable bundle before release acceptance.

### Acceptance evidence

- The checkbox matches `SMAppService.mainApp.status` each time Settings opens.
- Registration errors do not leave the checkbox in a false enabled state.
- A needs-approval state tells the user to approve Syrinx in System Settings.
- Enable starts Syrinx after a real logout and login. Disable prevents the next login launch.

## GitHub Actions removal

### Change

- Delete `.github/workflows/ci.yml`.
- Delete `.github/workflows/release.yml`.
- Delete the app workflow validator and its wrapper script.
- Keep repository tests and local build, audit, signing, and notarization tools.

### Verification

1. Confirm `.github/workflows` contains no workflow files.
2. Confirm `.github` contains no macOS runner, `swift build`, or `swift test` command.
3. Run local focused tests and the clean-source audit.
4. Confirm the local app release command remains available.

## Final acceptance gate

1. Run the full local `parrotTests` suite.
2. Build the root package and the `parrot` package.
3. Build the packaged app through the release app builder.
4. Confirm the packaged app uses its new artifact and displays the packaged version.
5. Verify model download and cached-model flows with separate disposable model locations.
6. Verify all three shortcuts in the packaged app.
7. Verify launch-at-login enable and disable across real login sessions.
8. Confirm GitHub contains no macOS build or test workflow.
