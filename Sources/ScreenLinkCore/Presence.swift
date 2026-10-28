import Foundation

public struct PresencePolicy {
    public private(set) var isPresent = false
    public private(set) var lastSignal: TimeInterval?
    private var suspended = false
    private var wakeDeadline: TimeInterval?
    public var timeout: TimeInterval
    public init(timeout: TimeInterval = 30) { self.timeout = timeout }
    public mutating func signal(at time: TimeInterval) {
        guard !suspended else { return }
        wakeDeadline = nil
        lastSignal = time
        isPresent = true
    }
    public mutating func tick(at time: TimeInterval) -> Bool {
        guard !suspended else { return false }
        if let deadline = wakeDeadline {
            guard time >= deadline else { return false }
            wakeDeadline = nil
            return true
        }
        guard isPresent, let lastSignal, time - lastSignal >= max(5, timeout) else { return false }
        isPresent = false
        return true
    }
    public mutating func suspend() {
        suspended = true; isPresent = false; wakeDeadline = nil
    }
    public mutating func resume(at time: TimeInterval) {
        guard suspended else { return }
        suspended = false
        // Do not treat old samples as present, but preserve prior arming.
        wakeDeadline = lastSignal == nil ? nil : time + max(5, timeout)
    }
    public mutating func reset() {
        isPresent = false; lastSignal = nil; suspended = false; wakeDeadline = nil
    }
}
