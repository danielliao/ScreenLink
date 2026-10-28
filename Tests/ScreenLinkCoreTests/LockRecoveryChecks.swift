import Foundation
import CoreFoundation
import ScreenLinkCore

func runLockRecoveryChecks() {
    // Real coordinator with only OS input and time replaced; never posts system events.
    var state = ScreenState.unlocked
    var calls = 0
    var tasks: [() -> Void] = []
    var replies: [LockResult] = []
    var permitted = true
    let locker = LockRetrier(state: { state }, attempt: { done in
        calls += 1
        if calls == 2 { state = .locked; done(.locked) }
        else { done(.retryable("fixture failure")) }
    }, schedule: { _, work in tasks.append(work) })
    locker.request(allowed: { permitted }, completion: { replies.append($0) })
    check(calls == 1 && replies.isEmpty, "Failed local lock remains pending for recovery")
    if !tasks.isEmpty { tasks.removeFirst()() }
    check(calls == 2 && replies == [.locked] && !locker.isPending, "Second local attempt confirms lock and completes once")

    state = .unlocked; calls = 0; tasks = []; replies = []
    let failing = LockRetrier(state: { state }, attempt: { done in
        calls += 1; done(.retryable("fixture failure"))
    }, schedule: { _, work in tasks.append(work) })
    failing.request(allowed: { true }, completion: { replies.append($0) })
    while !tasks.isEmpty { if !tasks.isEmpty { tasks.removeFirst()() } }
    check(calls == 3 && replies.count == 1 && !failing.isPending, "Permanent failure stops after three local attempts")

    calls = 0; tasks = []; replies = []
    failing.request(allowed: { permitted }, completion: { replies.append($0) })
    permitted = false
    if !tasks.isEmpty { tasks.removeFirst()() }
    check(calls == 1 && replies == [.cancelled], "Phone return revokes a pending automatic retry")
    permitted = true

    calls = 0; tasks = []; replies = []
    failing.request(allowed: { true }, completion: { replies.append($0) })
    state = .locked; failing.observeLocked(); state = .unlocked
    if !tasks.isEmpty { tasks.removeFirst()() }
    check(calls == 1 && replies == [.locked], "Observed lock ends cycle before manual unlock; stale retry cannot relock")

    calls = 0; tasks = []; replies = []
    failing.request(allowed: { true }, completion: { replies.append($0) })
    failing.cancel(); if !tasks.isEmpty { tasks.removeFirst()() }
    check(calls == 1 && replies == [.cancelled], "Settings or shutdown cancellation prevents queued retry")

    calls = 0; tasks = []; replies = []
    let blocked = LockRetrier(state: { .unlocked }, attempt: { done in
        calls += 1; done(.blocked("permission denied"))
    }, schedule: { _, work in tasks.append(work) })
    blocked.request(allowed: { true }, completion: { replies.append($0) })
    check(calls == 1 && tasks.isEmpty && replies == [.blocked("permission denied")], "Missing permissions do not cause repeated input attempts")

    calls = 0; replies = []; state = .locked
    failing.request(allowed: { true }, completion: { replies.append($0) })
    check(calls == 0 && replies == [.locked], "Already locked needs no additional system input")
    replies = []; state = .unlocked
    failing.request(allowed: { false }, completion: { replies.append($0) })
    check(calls == 0 && replies == [.cancelled], "Revoked request cannot post initial input")

    var deferred: [(LockResult) -> Void] = []
    let late = LockRetrier(state: { .unlocked }, attempt: { deferred.append($0) }, schedule: { _, work in tasks.append(work) })
    replies = []; tasks = []
    late.request(allowed: { true }, completion: { replies.append($0) })
    late.cancel()
    late.request(allowed: { true }, completion: { replies.append($0) })
    deferred[0](.retryable("old"))
    check(tasks.isEmpty && late.isPending, "Late completion cannot schedule work for a replaced request")
    deferred[1](.locked)
    check(replies == [.cancelled, .locked], "Replacement receives only its own completion")

    var sleeping = PresencePolicy(timeout: 30)
    sleeping.signal(at: 10); sleeping.suspend()
    check(!sleeping.isPresent && !sleeping.tick(at: 1000), "Suspended presence grants no lease and emits no departure")
    sleeping.signal(at: 1001)
    sleeping.resume(at: 2000)
    check(!sleeping.isPresent && !sleeping.tick(at: 2029), "Wake does not fabricate presence and allows a fresh grace period")
    check(sleeping.tick(at: 2030) && !sleeping.tick(at: 2040), "Previously seen phone still absent after wake triggers exactly once")
    sleeping.suspend(); sleeping.resume(at: 3000); sleeping.signal(at: 3010)
    check(!sleeping.tick(at: 3030) && sleeping.tick(at: 3040), "Fresh phone signal supersedes wake grace")
    var unseen = PresencePolicy(timeout: 30)
    unseen.suspend(); unseen.resume(at: 100)
    check(!unseen.tick(at: 1000), "Never-seen phone stays unarmed across wake")
    sleeping.suspend(); sleeping.reset(); sleeping.resume(at: 5000)
    check(!sleeping.tick(at: 6000), "Settings reset discards the previous phone's sleep state")

    let mode = CFRunLoopMode(rawValue: "ScreenLinkTestTracking" as CFString)
    CFRunLoopAddCommonMode(CFRunLoopGetCurrent(), mode)
    var ticks = 0
    let timer = CommonModeTimer.schedule(interval: 0.01) { ticks += 1 }
    CFRunLoopRunInMode(mode, 0.12, false)
    timer.invalidate()
    check(ticks > 0, "Production timer continues in a menu-like common run-loop mode")
}
