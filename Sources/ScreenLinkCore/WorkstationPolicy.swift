import Foundation

public struct WorkstationPolicy {
    public var pendingLock = false
    private var activityUntil: [UUID: Double] = [:]
    public init() {}
    public mutating func activity(peer: UUID, idle: Double, at: Double) {
        activityUntil = activityUntil.filter { $0.value > at }
        guard idle.isFinite, idle >= 0, at.isFinite, activityUntil.count < 64 || activityUntil[peer] != nil else { return }
        activityUntil[peer] = at + max(0, 10 - idle)
    }
    public func protected(localIdle: Double, at: Double) -> Bool {
        !localIdle.isFinite || localIdle < 10 || activityUntil.values.contains { $0 > at }
    }
    public mutating func shouldLock(phoneAbsent: Bool, paused: Bool, localIdle: Double, at: Double) -> Bool {
        guard phoneAbsent else { pendingLock = false; return false }
        guard pendingLock, !paused, !protected(localIdle: localIdle, at: at) else { return false }
        pendingLock = false
        return true
    }
}
public struct PauseSnapshot: Codable, Equatable {
    public var revision: UInt64 = 0
    public var issued: Double
    public var until: Double
    public init(issued: Double, until: Double) { self.issued = issued; self.until = until }
    public func remaining(at now: Double) -> Double {
        guard issued.isFinite, until.isFinite, now.isFinite, now >= issued - 15,
              until >= issued, until - issued <= 7200 else { return 0 }
        return max(0, min(until - issued, until - now))
    }
}
public struct UnlockRelayPolicy {
    private var previous = ScreenState.unknown
    private var remote = false
    public init() {}
    public mutating func observe(_ state: ScreenState, enabled: Bool) -> Bool {
        let trigger = enabled && previous == .locked && state == .unlocked && !remote
        previous = state
        if state != .locked { remote = false }
        return trigger
    }
    public mutating func markRemoteAttempt() { remote = true }
    public mutating func cancelRemoteAttempt() { remote = false }
}

public struct WorkstationMessage: Codable {
    public enum Action: String, Codable { case activity, automaticLock, cancelAutomatic, pauseRequest, pauseState, unlockRelay, relayedUnlock }
    public var action: Action
    public var event: UUID
    public var idle: Double?
    public var minutes: Int?
    public var pause: PauseSnapshot?
    public init(_ action: Action, event: UUID = UUID(), idle: Double? = nil, minutes: Int? = nil, pause: PauseSnapshot? = nil) {
        self.action = action; self.event = event; self.idle = idle; self.minutes = minutes; self.pause = pause
    }
    public func validate() throws {
        if let idle, !idle.isFinite || !(0...86400).contains(idle) { throw ProtocolError.invalid }
        if let minutes, ![0,15,30,60,120].contains(minutes) { throw ProtocolError.invalid }
        if let pause, !pause.issued.isFinite || !pause.until.isFinite || pause.until < pause.issued || pause.until - pause.issued > 7200 { throw ProtocolError.invalid }
        switch action {
        case .activity: guard idle != nil else { throw ProtocolError.invalid }
        case .pauseRequest: guard minutes != nil else { throw ProtocolError.invalid }
        case .pauseState: guard pause != nil else { throw ProtocolError.invalid }
        default: break
        }
    }
}

public struct PersistedPause: Codable {
    public let snapshot: PauseSnapshot
    public let deadline: Double
    public let boot: String
    public init(snapshot: PauseSnapshot, deadline: Double, boot: String) {
        self.snapshot = snapshot; self.deadline = deadline; self.boot = boot
    }
    public func remaining(wall: Double, uptime: Double, boot: String) -> Double {
        guard !boot.isEmpty, self.boot == boot, deadline.isFinite, uptime.isFinite else { return 0 }
        return max(0, min(snapshot.remaining(at: wall), deadline - uptime))
    }
}
