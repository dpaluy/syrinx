import AppKit
import SwiftUI

/// Borderless, click-through pill near the bottom of the active screen.
/// Driven by the daemon's hotkey + transcription lifecycle.
@MainActor
public final class RecordingOverlay {
    public enum State: Equatable {
        case hidden
        case recording
        case transcribing
    }

    private var window: NSPanel?
    private let model = OverlayModel()
    private var pendingHide: DispatchWorkItem?

    public func show(_ state: State) {
        pendingHide?.cancel()
        pendingHide = nil
        ensureWindow()
        guard let window else { return }
        model.state = state
        positionAtBottomCenter(window)
        window.orderFrontRegardless()
    }

    public func hide() {
        pendingHide?.cancel()
        model.state = .hidden
        // Let the SwiftUI scale+fade animation play out before yanking the
        // window. A later show cancels this work item.
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.model.state == .hidden else { return }
            self.window?.orderOut(nil)
            self.pendingHide = nil
        }
        pendingHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    /// Compatibility hook for audio capture. The three-dot animation is fixed.
    public nonisolated func pushLevel(_: Float) {}

    internal var isVisibleForTesting: Bool { window?.isVisible == true }

    internal func hideImmediatelyForTesting() {
        pendingHide?.cancel()
        pendingHide = nil
        model.state = .hidden
        window?.orderOut(nil)
    }

    private func ensureWindow() {
        if window != nil { return }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 96, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false

        let host = NSHostingView(rootView: OverlayPill(model: model))
        host.frame = panel.contentView?.bounds ?? .zero
        host.autoresizingMask = [.width, .height]
        panel.contentView = host

        window = panel
    }

    private func positionAtBottomCenter(_ window: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let frame = window.frame
        let visible = screen.visibleFrame
        let x = visible.midX - frame.width / 2
        let y = visible.minY + 32
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

/// Observable state for the SwiftUI pill.
@MainActor
final class OverlayModel: ObservableObject {
    static let indicatorCount = 3

    @Published var state: RecordingOverlay.State = .hidden
}

private struct OverlayPill: View {
    @ObservedObject var model: OverlayModel

    var body: some View {
        content
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                Capsule()
                    .fill(Color(red: 16/255, green: 18/255, blue: 18/255))
            )
            .scaleEffect(model.state == .hidden ? 0 : 1)
            .animation(
                .timingCurve(0.16, 1, 0.3, 1, duration: 0.3),
                value: model.state
            )
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .hidden, .recording:
            ListeningDots()
                .frame(width: 54, height: 22)
        case .transcribing:
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.8)
                .frame(width: 54, height: 22)
        }
    }
}

private struct ListeningDots: View {
    @State private var animating = false
    private let color = Color(red: 181/255.0, green: 209/255.0, blue: 255/255.0)

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            ForEach(0..<OverlayModel.indicatorCount, id: \.self) { index in
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
                    .scaleEffect(animating ? 1 : 0.55)
                    .opacity(animating ? 1 : 0.45)
                    .animation(
                        .easeInOut(duration: 0.55)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.16),
                        value: animating
                    )
            }
        }
        .onAppear {
            animating = true
        }
    }
}
