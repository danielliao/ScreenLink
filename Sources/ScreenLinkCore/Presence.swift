import Foundation

public struct PresencePolicy {
    public private(set) var isPresent = false
    public private(set) var lastSignal: TimeInterval?
    public var timeout: TimeInterval
    public init(timeout: TimeInterval = 30) { self.timeout = timeout }
    public mutating func signal(at time: TimeInterval) {
        lastSignal = time
        isPresent = true
    }
    public mutating func tick(at time: TimeInterval) -> Bool {
        guard isPresent, let lastSignal, time - lastSignal >= max(5, timeout) else { return false }
        isPresent = false
        return true
    }
    public mutating func reset() { isPresent = false; lastSignal = nil }
}
