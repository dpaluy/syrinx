import Foundation
import ServiceManagement

public enum LoginItemStatus: Equatable, Sendable {
    case enabled
    case disabled
    case requiresApproval
    case notFound
    case operationError(String)

    public var displayText: String {
        switch self {
        case .enabled:
            return "Enabled"
        case .disabled:
            return "Disabled"
        case .requiresApproval:
            return "Needs approval"
        case .notFound:
            return "Not found"
        case .operationError(let message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Operation failed" : "Error: \(trimmed)"
        }
    }
}

public protocol LoginItemServiceAdapter: AnyObject {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
}

public final class SystemLoginItemServiceAdapter: LoginItemServiceAdapter {
    private let service: SMAppService

    public init(service: SMAppService = .mainApp) {
        self.service = service
    }

    public var status: LoginItemStatus {
        switch service.status {
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return .notFound
        case .notRegistered:
            return .disabled
        @unknown default:
            return .notFound
        }
    }

    public func register() throws {
        try service.register()
    }

    public func unregister() throws {
        try service.unregister()
    }
}

@MainActor
public final class LoginItemController {
    public typealias Status = LoginItemStatus

    private let service: any LoginItemServiceAdapter
    public private(set) var status: LoginItemStatus
    public private(set) var operationError: String?

    public init(service: any LoginItemServiceAdapter = SystemLoginItemServiceAdapter()) {
        self.service = service
        self.status = service.status
        self.operationError = nil
    }

    public var checkboxIsOn: Bool {
        switch status {
        case .enabled, .requiresApproval:
            return true
        case .disabled, .notFound, .operationError:
            return false
        }
    }

    public var isEnabled: Bool { checkboxIsOn }

    public var statusMessage: String {
        guard let operationError else { return status.displayText }
        return "\(status.displayText). Error: \(operationError)"
    }

    @discardableResult
    public func refresh() -> LoginItemStatus {
        status = service.status
        operationError = nil
        return status
    }

    @discardableResult
    public func setEnabled(_ enabled: Bool) -> LoginItemStatus {
        operationError = nil
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
            return refresh()
        } catch {
            status = service.status
            operationError = Self.errorMessage(error)
            return status
        }
    }

    private static func errorMessage(_ error: Error) -> String {
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "Operation failed" : message
    }
}
