import Foundation
import Network
import ScreenLinkCore

var failures = 0
var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ name: String) {
    checks += 1
    if !condition() { failures += 1; print("FAIL: \(name)") }
}

var neverSeen = PresencePolicy(timeout: 30)
check(!neverSeen.tick(at: 1000), "Never lock before observing the phone")
var policy = PresencePolicy(timeout: 30)
try runPhoneUnlockChecks()
policy.signal(at: 100)
check(policy.isPresent, "Fresh signal establishes presence")
check(!policy.tick(at: 129), "Brief disconnect gets grace period")
check(policy.tick(at: 130), "Signal timeout triggers lock")
check(!policy.tick(at: 131), "One lock per departure")
check(!policy.isPresent, "Expired phone no longer grants presence")
policy.signal(at: 200)
policy.signal(at: 225)
check(!policy.tick(at: 240), "Reconnect cancels pending loss")
check(policy.tick(at: 255), "Renewed signal eventually expires")
policy.signal(at: 300)
policy.reset()
check(!policy.tick(at: 400), "Reset requires fresh observation")

func rejects(_ name: String, _ operation: () throws -> Void) {
    checks += 1
    do { try operation(); failures += 1; print("FAIL: \(name)") } catch {}
}
let key = Data(repeating: 0x31, count: 32)
let wrongKey = Data(repeating: 0x32, count: 32)
let sender = UUID()
let request = Message(sender: sender, command: .lock, now: 100)
let encoded = try Wire.encode(request, key: key)
let decoded = try Wire.decode(encoded, key: key, now: 100)
check(decoded.id == request.id && decoded.command == .lock, "Signed request round trip")
rejects("Reject a different group key") { _ = try Wire.decode(encoded, key: wrongKey, now: 100) }
rejects("Reject stale requests") { _ = try Wire.decode(encoded, key: key, now: 116) }
rejects("Reject future requests") { _ = try Wire.decode(encoded, key: key, now: 84) }
var envelope = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
var payload = try JSONSerialization.jsonObject(with: Data(base64Encoded: envelope["payload"] as! String)!) as! [String: Any]
payload["command"] = "unlock"
envelope["payload"] = try JSONSerialization.data(withJSONObject: payload).base64EncodedString()
let tampered = try JSONSerialization.data(withJSONObject: envelope)
rejects("Reject lock-to-unlock payload tampering") { _ = try Wire.decode(tampered, key: key, now: 100) }
rejects("Reject oversized envelope") { _ = try Wire.decode(Data(repeating: 65, count: Wire.limit + 1), key: key) }
rejects("Reject short keys") { _ = try Wire.encode(request, key: Data([1])) }
let replay = ReplayGuard()
try replay.accept(request, uptime: 100)
rejects("Reject replayed request IDs") { try replay.accept(request, uptime: 110) }
let reply = Message(sender: UUID(), command: .reply, now: 100, responseTo: request.id, state: .locked)
try Wire.validateReply(reply, to: request)
check(reply.state == .locked, "Reply carries observed state")
let wrongReply = Message(sender: UUID(), command: .reply, now: 100, responseTo: UUID())
rejects("Reject unrelated replies") { try Wire.validateReply(wrongReply, to: request) }
var buffer = FrameBuffer()
let partial = try buffer.append(Data(encoded.prefix(10)))
check(partial == nil, "Partial frames are buffered")
var tail = Data(encoded.dropFirst(10)); tail.append(10)
let assembled = try buffer.append(tail)
check(assembled == encoded, "Fragmented TCP frame is reconstructed")
var multiple = FrameBuffer()
rejects("Reject two commands in one frame") { _ = try multiple.append(Data("one\ntwo\n".utf8)) }
var huge = FrameBuffer()
rejects("Bound incomplete frames") { _ = try huge.append(Data(repeating: 65, count: Wire.limit + 2)) }
var defaults = Settings()
check(!defaults.autoLock && !defaults.networkEnabled && !defaults.allowRemoteUnlock && !defaults.keepAwake,
      "New installation cannot lock, listen, type passwords, or suppress display sleep")
defaults.peers = [Peer(name: "M1", host: "192.0.2.10"), Peer(name: "M3", host: "MacBook.local")]
try defaults.validate()
defaults.peers.append(Peer(name: "bad", host: "host; touch /tmp/injected"))
rejects("Reject malformed host strings") { try defaults.validate() }

// A real TCP server/client exchange, with no screen/Keychain/Bluetooth side effects.
let server = LinkServer()
let serverID = UUID()
var port: UInt16?
var invocations = 0
var rejectionReasons: [String] = []
server.onRejected = { rejectionReasons.append($0) }
server.onReady = { port = $0 }
server.handler = { message, respond in
    invocations += 1
    respond(Message(sender: serverID, command: .reply, responseTo: message.id, state: .locked, note: "fixture-only"))
}
func pump(until predicate: () -> Bool, seconds: Double = 10) {
    let end = Date().addingTimeInterval(seconds)
    while !predicate() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
}
try server.start(key: key, deviceID: serverID, port: 0, advertise: false)
pump(until: { port != nil })
check(port != nil, "TCP server starts on an ephemeral port")
if let port {
    let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
    var result: Result<Message, Error>?
    let message = Message(sender: sender, command: .status)
    _ = LinkRequest(endpoint: endpoint, message: message, key: key) { result = $0 }
    pump(until: { result != nil })
    if case .success(let reply) = result {
        check(reply.state == .locked && reply.responseTo == message.id, "Real TCP request returns authenticated correlated reply")
    } else { check(false, "Real TCP request returns authenticated correlated reply") }
    check(invocations == 1, "Valid request reaches handler exactly once")
    result = nil
    _ = LinkRequest(endpoint: endpoint, message: message, key: key) { result = $0 }
    pump(until: { result != nil })
    if case .failure = result { check(true, "Replayed network request rejected") }
    else { check(false, "Replayed network request rejected") }
    check(invocations == 1, "Replay never reaches command handler")
    check(rejectionReasons.last == ProtocolError.replay.localizedDescription, "Replay rejection reports its reason without credentials")
    result = nil
    _ = LinkRequest(endpoint: endpoint, message: Message(sender: sender, command: .unlock), key: wrongKey) { result = $0 }
    pump(until: { result != nil })
    if case .failure = result { check(true, "Wrong-key unlock request rejected over TCP") }
    else { check(false, "Wrong-key unlock request rejected over TCP") }
    check(invocations == 1, "Unauthenticated unlock never reaches handler")
    check(rejectionReasons.last == ProtocolError.authentication.localizedDescription, "Authentication rejection reports its reason without credentials")
}
server.stop()

var snapshots: [Int] = []
let updates = ScanUpdates<Int>(interval: 0.03) { snapshots.append($0) }
for value in 1...100 { updates.submit(value) }
check(snapshots.isEmpty, "Discovery must not synchronously reenter the UI")
pump(until: { !snapshots.isEmpty }, seconds: 1)
check(snapshots == [100], "A burst publishes only the newest discovery snapshot")
updates.submit(101)
updates.cancel()
RunLoop.main.run(until: Date().addingTimeInterval(0.06))
check(snapshots == [100], "Stopping a scan cancels its pending UI update")
updates.submit(102)
pump(until: { snapshots.last == 102 }, seconds: 1)
check(snapshots == [100, 102], "Restarting a scan can publish new snapshots")

let pairingCode = PairingCode(key: key, coordinatorID: serverID)
let pairingText = try JSONEncoder().encode(pairingCode).base64EncodedString()
do {
    let parsed = try PairingCode.parse(" \n" + pairingText + "\n ")
    check(parsed.key == key && parsed.coordinatorID == serverID, "Pasted pairing code preserves key and coordinator")
} catch { check(false, "Pasted pairing code preserves key and coordinator") }
do {
    _ = try PairingCode.parse(" \n ")
    check(false, "Empty import explains how to paste a pairing code")
} catch PairingError.empty { check(true, "Empty import explains how to paste a pairing code") }
catch { check(false, "Empty import explains how to paste a pairing code") }
rejects("Random clipboard text cannot become a group key") { _ = try PairingCode.parse("192.0.2.10") }
let shortPairing = try JSONEncoder().encode(PairingCode(key: Data([1]), coordinatorID: serverID)).base64EncodedString()
rejects("Pairing requires a full 256-bit group key") { _ = try PairingCode.parse(shortPairing) }
var futurePairing = pairingCode
futurePairing.version = 2
let futureText = try JSONEncoder().encode(futurePairing).base64EncodedString()
rejects("Unsupported pairing versions are rejected") { _ = try PairingCode.parse(futureText) }

runLockRecoveryChecks()
runCredentialChecks()
try runJoinCryptoChecks()
try runJoinNetworkChecks()
try runJoinTimeoutAndDiscoveryChecks()
try runJoinConfigurationChecks()
try runJoinDiscoveryFailureChecks()
try runFixedAddressDiscoveryChecks()
try runControlRestartChecks()
print("\(checks) checks, \(failures) failures")
exit(failures == 0 ? 0 : 1)
