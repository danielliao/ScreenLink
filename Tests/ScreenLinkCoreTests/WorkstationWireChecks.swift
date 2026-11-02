import Foundation
import CryptoKit
import ScreenLinkCore

func runWorkstationWireChecks() throws {
    let key = Data(repeating: 0x6b, count: 32)
    let sender = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
    let receiver = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
    var pause = PauseSnapshot(issued: 7000, until: 8800)
    pause.revision = 42
    func message(_ value: WorkstationMessage?) -> Message {
        var valueMessage = Message(sender: sender, command: .workstation, now: 7000)
        valueMessage.workstation = value
        return valueMessage
    }
    func roundTrip(_ value: Message) throws -> Message {
        try Wire.decode(Wire.encode(value, key: key), key: key, now: 7000)
    }
    // Re-sign deliberately malformed data so rejection exercises validation,
    // not an incidental authentication failure.
    func modified(_ original: Message, authenticate: Bool = true,
                  _ change: (inout [String: Any]) -> Void) throws -> Data {
        let encoded = try Wire.encode(original, key: key)
        var envelope = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        var payload = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
        change(&payload)
        let bytes = try JSONSerialization.data(withJSONObject: payload, options: .sortedKeys)
        envelope["payload"] = bytes.base64EncodedString()
        if authenticate {
            envelope["mac"] = Data(HMAC<SHA256>.authenticationCode(for: bytes, using: SymmetricKey(data: key))).base64EncodedString()
        }
        return try JSONSerialization.data(withJSONObject: envelope)
    }
    func alteredWorkstation(_ original: Message, _ change: (inout [String: Any]) -> Void) throws -> Data {
        try modified(original) { payload in
            var workstation = payload["workstation"] as! [String: Any]
            change(&workstation)
            payload["workstation"] = workstation
        }
    }

    for value in [WorkstationMessage(.activity, idle: 0), .init(.automaticLock), .init(.cancelAutomatic),
                  .init(.pauseRequest, minutes: 30), .init(.pauseState, pause: pause),
                  .init(.unlockRelay), .init(.relayedUnlock)] {
        let decoded = try roundTrip(message(value))
        check(decoded.workstation?.action == value.action && decoded.workstation?.event == value.event,
              "Authenticated workstation action and event survive wire: \(value.action.rawValue)")
    }
    let signedPause = message(.init(.pauseState, pause: pause))
    let pauseDecoded = try roundTrip(signedPause)
    check(pauseDecoded.workstation?.pause?.revision == 42 && pauseDecoded.workstation?.pause?.until == 8800,
          "Pause revision and deadline survive authenticated wire")
    rejects("Workstation command requires its payload") { _ = try roundTrip(message(nil)) }
    for value in [WorkstationMessage(.activity), .init(.pauseRequest), .init(.pauseState)] {
        rejects("Required payload missing for \(value.action.rawValue)") { _ = try roundTrip(message(value)) }
    }
    for idle in [-1.0, 86401.0] {
        rejects("Wire rejects out of bounds idle \(idle)") { _ = try roundTrip(message(.init(.activity, idle: idle))) }
    }
    for idle in [Double.nan, .infinity, -.infinity] {
        rejects("Activity validator rejects nonfinite idle") { try WorkstationMessage(.activity, idle: idle).validate() }
    }
    for minutes in [-1, 1, 121, Int.max] {
        rejects("Wire rejects invalid pause duration \(minutes)") { _ = try roundTrip(message(.init(.pauseRequest, minutes: minutes))) }
    }
    for malformed in [PauseSnapshot(issued: 7000, until: 6999), .init(issued: 7000, until: 14201)] {
        rejects("Wire rejects reversed or overlong pause") { _ = try roundTrip(message(.init(.pauseState, pause: malformed))) }
    }
    for malformed in [PauseSnapshot(issued: .nan, until: 8000), .init(issued: 7000, until: .infinity)] {
        rejects("Pause validator rejects nonfinite deadlines") { try WorkstationMessage(.pauseState, pause: malformed).validate() }
    }
    let ordinary = message(.init(.activity, idle: 3))
    rejects("Authenticated unknown workstation action rejected") {
        _ = try Wire.decode(alteredWorkstation(ordinary) { $0["action"] = "eraseFiles" }, key: key, now: 7000)
    }
    rejects("Authenticated malformed event identity rejected") {
        _ = try Wire.decode(alteredWorkstation(ordinary) { $0["event"] = "not-a-uuid" }, key: key, now: 7000)
    }
    rejects("Authenticated missing event identity rejected") {
        _ = try Wire.decode(alteredWorkstation(ordinary) { $0.removeValue(forKey: "event") }, key: key, now: 7000)
    }
    rejects("Authenticated wrong numeric type rejected") {
        _ = try Wire.decode(alteredWorkstation(ordinary) { $0["idle"] = "zero" }, key: key, now: 7000)
    }
    for revision: Any in [NSNumber(value: -1), NSNumber(value: Double(UInt64.max) * 2), "42"] {
        rejects("Authenticated invalid pause revision rejected") {
            _ = try Wire.decode(alteredWorkstation(signedPause) {
                var body = $0["pause"] as! [String: Any]; body["revision"] = revision; $0["pause"] = body
            }, key: key, now: 7000)
        }
    }
    rejects("Tampering pause revision fails authentication") {
        _ = try Wire.decode(modified(signedPause, authenticate: false) { payload in
            var body = payload["workstation"] as! [String: Any]
            var value = body["pause"] as! [String: Any]
            value["revision"] = 43; body["pause"] = value; payload["workstation"] = body
        }, key: key, now: 7000)
    }
    var status = Message(sender: sender, command: .reply, now: 7000,
                         responseTo: ordinary.id, state: .unlocked)
    status.capabilities = 1; status.sharingKinds = ["text", "png", "file"]
    status.workstation = .init(.pauseState, pause: pause)
    let statusDecoded = try roundTrip(status)
    check(statusDecoded.capabilities == 1 && statusDecoded.sharingKinds == ["text", "png", "file"],
          "Sharing capability metadata survives authenticated status")
    try Wire.validateReply(statusDecoded, to: Message(sender: receiver, command: .status, now: 7000, responseTo: nil).withID(ordinary.id))
    rejects("Capability metadata tampering fails authentication") {
        _ = try Wire.decode(modified(status, authenticate: false) { $0["sharingKinds"] = ["file"] }, key: key, now: 7000)
    }
    rejects("Wrong group cannot authenticate workstation metadata") {
        _ = try Wire.decode(Wire.encode(status, key: key), key: Data(repeating: 0x6c, count: 32), now: 7000)
    }
    var huge = status; huge.sharingKinds = [String(repeating: "x", count: 8192)]
    rejects("Oversized capability metadata cannot escape the control frame limit") { _ = try Wire.encode(huge, key: key) }
    rejects("Oversized authenticated foreign metadata rejected before decode") {
        _ = try Wire.decode(modified(status) { $0["futureMetadata"] = String(repeating: "x", count: 8192) }, key: key, now: 7000)
    }
    let extended = try Wire.decode(modified(status) { $0["futureMetadata"] = "bounded" }, key: key, now: 7000)
    check(extended.id == status.id, "Bounded unknown metadata remains forward compatible")
    rejects("Stale workstation request rejected") { _ = try Wire.decode(Wire.encode(ordinary, key: key), key: key, now: 7016) }
    rejects("Future workstation request rejected") { _ = try Wire.decode(Wire.encode(ordinary, key: key), key: key, now: 6984) }
    let replay = ReplayGuard()
    try replay.accept(ordinary, uptime: 100)
    rejects("Repeated authenticated workstation envelope rejected") { try replay.accept(ordinary, uptime: 101) }

    var baseline = Settings()
    baseline.deviceName = "Fixture Mac"
    baseline.autoLock = true; baseline.keepAwake = true
    baseline.phoneID = UUID(); baseline.peers = [Peer(name: "Fixture peer", host: "192.0.2.1")]
    var legacyJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(baseline)) as! [String: Any]
    for key in ["relayUnlock", "clipboardSync", "receiveFiles", "receiveDirectory"] { legacyJSON.removeValue(forKey: key) }
    let legacy = try JSONDecoder().decode(Settings.self, from: JSONSerialization.data(withJSONObject: legacyJSON))
    check(legacy.relayUnlock != true && legacy.clipboardSync != true && legacy.receiveFiles != true,
          "Legacy settings keep all new sharing and unlock capabilities off")
    check(legacy.receiveDirectory == nil, "Legacy settings preserve default receiving directory selection")
    check(legacy.autoLock && legacy.keepAwake && legacy.phoneID == baseline.phoneID && legacy.peers == baseline.peers,
          "New optional fields do not alter legacy phone and peer configuration")
    baseline.relayUnlock = true; baseline.clipboardSync = true; baseline.receiveFiles = true
    baseline.receiveDirectory = "/fixture/Downloads/ScreenLink"
    let restored = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(baseline))
    check(restored.relayUnlock == true && restored.clipboardSync == true && restored.receiveFiles == true,
          "Explicit sharing and unlock opt-ins persist")
    check(restored.receiveDirectory == "/fixture/Downloads/ScreenLink" && restored.deviceID == baseline.deviceID,
          "Receiving path and existing device identity persist together")
    try restored.validate()
}

private extension Message {
    func withID(_ id: UUID) -> Message { var copy = self; copy.id = id; return copy }
}
