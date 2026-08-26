import AppKit
import Foundation

@MainActor
public final class DictationSession {
    public enum SessionError: Error {
        case alreadyStarted
    }

    private let transcriber: any Transcriber
    private let monitor: HotkeyMonitor
    private let capture: AudioCapture
    private let overlay: RecordingOverlay
    private let menuBar: MenuBarController
    private var started = false

    public init(model: TranscriptionModel) throws {
        self.transcriber = try TranscriberFactory.make(model: model)
        self.monitor = HotkeyMonitor()
        self.capture = AudioCapture()
        self.overlay = RecordingOverlay()
        self.menuBar = MenuBarController(modelID: model.id)

        capture.onLevel = { [weak overlay] level in
            overlay?.pushLevel(level)
        }
    }

    public func prepare() async throws {
        try await transcriber.prepare()
        menuBar.setStatus("ready · hold Fn to dictate")
    }

    public func setStatus(_ status: String) {
        menuBar.setStatus(status)
    }

    public func start() throws {
        guard !started else { throw SessionError.alreadyStarted }
        try monitor.start { [weak self] event in
            self?.handle(event)
        }
        started = true
        menuBar.setStatus("ready · hold Fn to dictate")
    }

    public func stop() {
        guard started else { return }
        monitor.stop()
        _ = capture.stop()
        overlay.hide()
        menuBar.setRecording(false)
        started = false
    }

    private func handle(_ event: HotkeyMonitor.Event) {
        switch event {
        case .pressed:
            do {
                try capture.start()
                overlay.show(.recording)
                menuBar.setRecording(true)
            } catch {
                menuBar.setStatus("microphone unavailable")
            }
        case .released:
            let samples = capture.stop()
            overlay.show(.transcribing)
            menuBar.setTranscribing()
            guard !samples.isEmpty else {
                overlay.hide()
                menuBar.setRecording(false)
                return
            }

            Task { [weak self] in
                guard let self else { return }
                do {
                    let text = try await transcriber.transcribe(samples)
                    TextInjector.inject(text)
                } catch {
                    menuBar.setStatus("transcription failed")
                }
                overlay.hide()
                menuBar.setRecording(false)
            }
        }
    }
}
