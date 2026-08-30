import Foundation

public enum ModelLifecycleState: Equatable, Sendable {
    case checking
    case downloading(progress: Double?)
    case downloaded
    case loading
    case ready
    case failed(String)

    public var displayText: String {
        switch self {
        case .checking:
            return "Checking for model"
        case .downloading(let progress):
            guard let progress else { return "Downloading model" }
            return "Downloading model (\(Self.percent(progress))%)"
        case .downloaded:
            return "Model downloaded"
        case .loading:
            return "Loading model"
        case .ready:
            return "Model ready"
        case .failed(let message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Model failed" : "Model failed: \(trimmed)"
        }
    }

    public var progressFraction: Double? {
        guard case .downloading(let progress) = self else { return nil }
        return progress
    }

    private static func percent(_ value: Double) -> Int {
        Int((max(0, min(1, value)) * 100).rounded())
    }
}

@MainActor
public final class SettingsState {
    public private(set) var model: TranscriptionModel
    public let selectableModels: [TranscriptionModel]
    public let appVersion: String
    public let preferences: AppPreferences

    public private(set) var modelState: ModelLifecycleState
    public private(set) var loginItemStatus: LoginItemStatus
    public private(set) var loginItemOperationError: String?
    public private(set) var hotkeyChoice: HotkeyChoice
    public private(set) var hotkeyChangeAllowed = true
    public private(set) var modelChangeAllowed = true
    public private(set) var shortcutError: String?

    private var observers: [() -> Void] = []

    public init(
        model: TranscriptionModel,
        selectableModels: [TranscriptionModel] = ModelRegistry.inProcessWhisperKitModels,
        appVersion: String = AppVersion.current(),
        preferences: AppPreferences = AppPreferences(),
        modelState: ModelLifecycleState = .checking,
        loginItemStatus: LoginItemStatus = .disabled,
        loginItemOperationError: String? = nil
    ) {
        self.model = model
        self.selectableModels = selectableModels
        self.appVersion = appVersion
        self.preferences = preferences
        self.modelState = modelState
        self.loginItemStatus = loginItemStatus
        self.loginItemOperationError = loginItemOperationError
        self.hotkeyChoice = preferences.hotkeyChoice
    }

    public func addObserver(_ observer: @escaping () -> Void) {
        observers.append(observer)
        observer()
    }

    private var lastModelStateSequence: UInt64 = 0

    public func setModelState(_ state: ModelLifecycleState, sequence: UInt64? = nil) {
        let nextSequence = sequence ?? lastModelStateSequence &+ 1
        guard nextSequence > lastModelStateSequence else { return }
        lastModelStateSequence = nextSequence
        guard modelState != state else { return }
        modelState = state
        notifyObservers()
    }

    public func setModel(_ model: TranscriptionModel) {
        guard self.model.id != model.id else { return }
        self.model = model
        notifyObservers()
    }

    public func setHotkeyChoice(_ choice: HotkeyChoice) {
        guard hotkeyChoice != choice else { return }
        hotkeyChoice = choice
        notifyObservers()
    }

    public func setLoginItemStatus(
        _ status: LoginItemStatus,
        operationError: String? = nil
    ) {
        guard loginItemStatus != status || loginItemOperationError != operationError else { return }
        loginItemStatus = status
        loginItemOperationError = operationError
        notifyObservers()
    }

    public func setHotkeyChangeAllowed(_ allowed: Bool) {
        guard hotkeyChangeAllowed != allowed else { return }
        hotkeyChangeAllowed = allowed
        notifyObservers()
    }

    public func setModelChangeAllowed(_ allowed: Bool) {
        guard modelChangeAllowed != allowed else { return }
        modelChangeAllowed = allowed
        notifyObservers()
    }

    public func setShortcutError(_ message: String?) {
        guard shortcutError != message else { return }
        shortcutError = message
        notifyObservers()
    }

    public func refreshPreferences() {
        let choice = preferences.hotkeyChoice
        guard hotkeyChoice != choice else { return }
        hotkeyChoice = choice
        notifyObservers()
    }

    private func notifyObservers() {
        observers.forEach { $0() }
    }
}
