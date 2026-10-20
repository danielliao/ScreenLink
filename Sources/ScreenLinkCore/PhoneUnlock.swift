import Foundation

// This policy accepts only a fresh RSSI read on the selected connected peripheral.
// Broadcast discovery and cached "connected" state must not call it as connected.
public struct PhoneReturnPolicy {
    public var timeout: TimeInterval
    private var lastSample: TimeInterval?
    private var connected = false
    public init(timeout: TimeInterval = 30) { self.timeout = timeout }
    public mutating func sample(connected: Bool, at time: TimeInterval) -> Bool {
        guard connected else { return false }
        let arrived = lastSample.map { time - $0 >= max(5, timeout) } ?? true
        lastSample = time
        self.connected = true
        return arrived
    }
    public mutating func disconnected() { connected = false }
    public func isFresh(at time: TimeInterval) -> Bool {
        guard connected, let lastSample else { return false }
        return time >= lastSample && time - lastSample <= 8
    }
}

public struct UnlockAuthorization {
    public enum Source { case manual, phone }
    public let source: Source
    public let generation: UUID
    public let expires: TimeInterval
    public init(source: Source, generation: UUID, expires: TimeInterval) {
        self.source = source; self.generation = generation; self.expires = expires
    }
    public func permits(at time: TimeInterval, generation: UUID,
                        state: ScreenState, phoneReady: Bool) -> Bool {
        guard time < expires, self.generation == generation else { return false }
        switch source {
        case .manual: return state == .unlocked
        case .phone: return state != .unknown && phoneReady
        }
    }
}
