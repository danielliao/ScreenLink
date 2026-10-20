import Foundation
import ScreenLinkCore

func runPhoneUnlockChecks() throws {
    var policy = PhoneReturnPolicy(timeout: 30)
    check(!policy.sample(connected: false, at: 0), "Advertisements cannot authorize phone unlock")
    check(!policy.isFresh(at: 0), "Advertisements do not establish connected freshness")
    check(policy.sample(connected: true, at: 1), "First connected RSSI triggers once")
    check(!policy.sample(connected: true, at: 4), "Continuous connected samples do not retrigger")
    policy.disconnected()
    check(!policy.isFresh(at: 5), "Disconnect immediately cancels pending phone authorization")
    check(!policy.sample(connected: true, at: 10), "Brief reconnect does not retrigger")
    check(!policy.isFresh(at: 19), "Stale connected sample cannot authorize delayed commands")
    check(policy.sample(connected: true, at: 40), "Return after absence triggers one new attempt")
    check(!policy.sample(connected: true, at: 41), "Failed attempt cannot be retried by next sample")

    let generation = UUID()
    let phone = UnlockAuthorization(source: .phone, generation: generation, expires: 100)
    check(phone.permits(at: 90, generation: generation, state: .locked, phoneReady: true),
          "Phone arrival can unlock a locked coordinator")
    check(!phone.permits(at: 90, generation: generation, state: .locked, phoneReady: false),
          "Disabled, disconnected, or stale phone cannot unlock")
    check(!phone.permits(at: 100, generation: generation, state: .locked, phoneReady: true),
          "Expired phone authorization is rejected")
    check(!phone.permits(at: 90, generation: UUID(), state: .locked, phoneReady: true),
          "Settings change or manual lock cancels pending unlock")
    check(!phone.permits(at: 90, generation: generation, state: .unknown, phoneReady: true),
          "Unknown console session cannot initiate phone unlock")
    let manual = UnlockAuthorization(source: .manual, generation: generation, expires: 100)
    check(!manual.permits(at: 90, generation: generation, state: .locked, phoneReady: true),
          "Manual authorization still requires unlocked local session")
    check(manual.permits(at: 90, generation: generation, state: .unlocked, phoneReady: false),
          "Manual authorization does not depend on phone")

    let original = Settings()
    var data = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
    data.removeValue(forKey: "unlockOnPhoneConnection")
    let legacy = try JSONDecoder().decode(Settings.self, from: JSONSerialization.data(withJSONObject: data))
    check(!legacy.phoneUnlockEnabled, "Older configuration keeps phone unlock off")
    var enabled = original
    enabled.unlockOnPhoneConnection = true
    let decoded = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(enabled))
    check(decoded.phoneUnlockEnabled, "Phone unlock opt-in persists")
    check(legacy.lockRSSIThreshold == nil, "Older configuration keeps RSSI threshold disabled")
    enabled.lockRSSIThreshold = -75
    check(enabled.acceptsPresenceSignal(-75), "Signal at lock threshold renews grace")
    check(!enabled.acceptsPresenceSignal(-76), "Weak signal does not renew grace")
    check(!enabled.acceptsUnlockSignal(-74) && enabled.acceptsUnlockSignal(-70),
          "Return requires 5 dB hysteresis above lock threshold")
    check(!original.acceptsPresenceSignal(127) && !original.acceptsUnlockSignal(-120),
          "Invalid RSSI never grants presence or unlock")
    var weakPresence = PresencePolicy(timeout: 30)
    for (time, rssi) in [(0.0, -60), (10.0, -80), (20.0, -82)] {
        if enabled.acceptsPresenceSignal(rssi) { weakPresence.signal(at: time) }
    }
    check(!weakPresence.tick(at: 29) && weakPresence.tick(at: 30),
          "Continuous weak samples expire after configured grace")
    weakPresence.signal(at: 40)
    if enabled.acceptsPresenceSignal(-65) { weakPresence.signal(at: 65) }
    check(!weakPresence.tick(at: 70), "Strong signal cancels pending weak-signal lock")
    enabled.lockRSSIThreshold = -120
    rejects("Out-of-range signal threshold is rejected") { try enabled.validate() }
}
