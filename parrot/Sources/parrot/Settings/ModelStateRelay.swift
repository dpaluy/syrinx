import Foundation

/// Assigns ordered sequence numbers before model updates cross actors.
final class ModelStateRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var nextValue: UInt64 = 0

    func nextSequence() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        nextValue &+= 1
        return nextValue
    }
}
