import Foundation
import ScreenLinkCore

func runWorkstationChecks() {
    var p = WorkstationPolicy()
    p.pendingLock = true
    check(!p.shouldLock(phoneAbsent: true, paused: false, localIdle: 9.99, at: 20), "Typing or mouse movement defers automatic lock")
    check(p.pendingLock, "Activity does not discard departure intent")
    check(p.shouldLock(phoneAbsent: true, paused: false, localIdle: 10, at: 20), "Idle boundary executes pending departure")
    check(!p.pendingLock, "Completed departure is not repeated every tick")
    p.pendingLock = true
    p.activity(peer: UUID(), idle: 1, at: 20)
    check(!p.shouldLock(phoneAbsent: true, paused: false, localIdle: 20, at: 21), "Follower activity protects the whole group")
    check(p.shouldLock(phoneAbsent: true, paused: false, localIdle: 20, at: 29), "Lost peer cannot retain an indefinite activity lease")
    p.pendingLock = true
    check(!p.shouldLock(phoneAbsent: true, paused: true, localIdle: 20, at: 30), "Pause defers an otherwise eligible lock")
    check(p.shouldLock(phoneAbsent: true, paused: false, localIdle: 20, at: 31), "Pause expiry resumes pending lock")
    p.pendingLock = true
    _ = p.shouldLock(phoneAbsent: false, paused: false, localIdle: 20, at: 40)
    check(!p.pendingLock, "Phone return cancels deferred departure")
    check(p.protected(localIdle: .nan, at: 40), "Unavailable input observation does not lock an active user")
    check(PauseSnapshot(issued: 100, until: 1900).remaining(at: 200) == 1700, "Pause survives restart without extending deadline")
    check(PauseSnapshot(issued: 100, until: 1900).remaining(at: 1900) == 0, "Pause expires at deadline")
    check(PauseSnapshot(issued: 100, until: 1900).remaining(at: 80) == 0, "Large clock rollback invalidates a pause")
    check(PauseSnapshot(issued: 100, until: 10000).remaining(at: 100) == 0, "Reject unbounded pause lease")
    check(PauseSnapshot(issued: 100, until: 1900).remaining(at: 99.9) == 1800, "Small peer clock skew does not disable a new pause or extend its duration")
    var relay = UnlockRelayPolicy()
    check(!relay.observe(.unlocked, enabled: true), "App startup unlocked must not fan out unlock")
    _ = relay.observe(.locked, enabled: true)
    check(relay.observe(.unlocked, enabled: true), "Manual unlock produces one relay")
    check(!relay.observe(.unlocked, enabled: true), "Continuous unlocked observations do not relay")
    _ = relay.observe(.locked, enabled: true); relay.markRemoteAttempt()
    check(!relay.observe(.unlocked, enabled: true), "Remote unlock does not create a broadcast loop")
    _ = relay.observe(.locked, enabled: true); _ = relay.observe(.unknown, enabled: true)
    check(!relay.observe(.unlocked, enabled: true), "User switching or unknown state cannot authorize relay")
}
