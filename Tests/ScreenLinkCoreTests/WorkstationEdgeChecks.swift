import Foundation
import ScreenLinkCore

/// Exercises temporal/state boundaries without querying or changing macOS state.
func runWorkstationEdgeChecks() {
    let peer = UUID()
    let saved = PersistedPause(snapshot: PauseSnapshot(issued: 100, until: 1900), deadline: 1850, boot: "boot-a")
    check(saved.remaining(wall: 200, uptime: 1800, boot: "boot-a") == 50, "Restart with clock rollback cannot extend monotonic pause deadline")
    check(saved.remaining(wall: 200, uptime: 20, boot: "boot-b") == 0, "Reboot cannot revive an earlier pause")
    var activity = WorkstationPolicy()
    activity.pendingLock = true
    activity.activity(peer: peer, idle: 9, at: 100)
    check(activity.protected(localIdle: 20, at: 100.999), "Remote input protection includes remaining fraction of ten seconds")
    check(!activity.protected(localIdle: 20, at: 101), "Remote protection expires at exact lease deadline")
    activity.activity(peer: peer, idle: 1, at: 110)
    activity.activity(peer: peer, idle: 86400, at: 111)
    check(!activity.protected(localIdle: 20, at: 111), "Peer locking or becoming idle immediately clears its previous protection")
    activity.activity(peer: peer, idle: 0, at: 120)
    activity.activity(peer: peer, idle: .nan, at: 121)
    check(activity.protected(localIdle: 20, at: 125), "Malformed activity does not erase an existing valid lease")
    check(!activity.protected(localIdle: 20, at: 130), "Malformed activity cannot extend an existing lease")
    activity.activity(peer: peer, idle: 12, at: 140)
    check(!activity.protected(localIdle: 20, at: 140), "A delayed report already beyond ten seconds provides no fresh lease")
    check(!activity.shouldLock(phoneAbsent: false, paused: true, localIdle: 0, at: 141) && !activity.pendingLock,
          "Phone return clears a pending intent even during pause and activity")
    check(!activity.shouldLock(phoneAbsent: true, paused: false, localIdle: 20, at: 151),
          "A canceled departure cannot fire when protection later expires")
    activity.pendingLock = true
    check(!activity.shouldLock(phoneAbsent: true, paused: false, localIdle: .infinity, at: 160) && activity.pendingLock,
          "Unavailable infinite idle value defers without dropping intent")
    check(activity.shouldLock(phoneAbsent: true, paused: false, localIdle: 10, at: 161),
          "Restored valid input observation executes preserved intent")

    var relay = UnlockRelayPolicy()
    _ = relay.observe(.locked, enabled: true)
    relay.markRemoteAttempt()
    check(!relay.observe(.unlocked, enabled: true), "Observed remote unlock suppresses one transition")
    _ = relay.observe(.locked, enabled: true)
    check(relay.observe(.unlocked, enabled: true), "Remote suppression does not leak into next lock cycle")
    _ = relay.observe(.locked, enabled: true)
    check(!relay.observe(.unlocked, enabled: false), "Disabled relay never sends a manual transition")
    check(!relay.observe(.unlocked, enabled: true), "Reenabling relay does not replay previously disabled transition")
    _ = relay.observe(.locked, enabled: true)
    _ = relay.observe(.unknown, enabled: true)
    check(!relay.observe(.unlocked, enabled: true), "Unknown session transition cannot stand in for observed manual unlock")

    check(PauseSnapshot(issued: 100, until: 100).remaining(at: 100) == 0, "Resume snapshot takes effect immediately")
    check(PauseSnapshot(issued: .nan, until: 200).remaining(at: 150) == 0, "Corrupt persisted pause cannot suppress locking")
    check(PauseSnapshot(issued: 100, until: .infinity).remaining(at: 150) == 0, "Infinite persisted pause cannot suppress locking")
    check(PauseSnapshot(issued: 100, until: 7300).remaining(at: 101) == 7199, "Maximum allowed pause has finite decreasing remaining duration")
}
