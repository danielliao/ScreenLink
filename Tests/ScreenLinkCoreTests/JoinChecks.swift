import Foundation
import Network
import ScreenLinkCore

func runJoinCryptoChecks() throws {
    let client = try JoinIdentity(deviceID: UUID(), name: "Follower")
    let host = try JoinIdentity(deviceID: UUID(), name: "Coordinator", session: client.hello.session)
    let commitment = try JoinCrypto.commitment(client.hello)
    check(commitment.count == 32, "Join uses a full commitment before host challenge")
    var altered = client.hello; altered.name = "Impersonator"
    rejects("Committed join identity cannot be replaced") { try JoinCrypto.verify(commitment, hello: altered) }
    var wrongSession = host.hello; wrongSession.session = UUID()
    rejects("Different handshake sessions cannot share a grant") {
        _ = try JoinSecrets(local: client, client: client.hello, host: wrongSession)
    }
    rejects("Local identity must match the comparison transcript") {
        _ = try JoinSecrets(local: client, client: altered, host: host.hello)
    }
    let a = try JoinSecrets(local: client, client: client.hello, host: host.hello)
    let b = try JoinSecrets(local: host, client: client.hello, host: host.hello)
    check(a.code == b.code && a.code.count == 6, "Both ends display the same comparison digits")
    let fixture = Data(repeating: 42, count: 32)
    let sealed = try b.seal(fixture, purpose: "grant")
    let opened = try a.open(sealed, purpose: "grant")
    check(opened == fixture && sealed != fixture, "Group key crosses the pairing channel encrypted")
    rejects("Grant cannot be reflected as a receipt") { _ = try a.open(sealed, purpose: "receipt") }
    var corrupted = sealed; corrupted[corrupted.count - 1] ^= 1
    rejects("Tampered pairing grant is rejected") { _ = try a.open(corrupted, purpose: "grant") }
    let stranger = try JoinIdentity(deviceID: UUID(), name: "Stranger", session: client.hello.session)
    let other = try JoinSecrets(local: stranger, client: stranger.hello, host: host.hello)
    rejects("Other sessions cannot decrypt an approved group key") { _ = try other.open(sealed, purpose: "grant") }
    var frames = JoinFrames()
    let both = try frames.append(Data("first\nsecond\npart".utf8))
    check(both == [Data("first".utf8), Data("second".utf8)], "Pairing accepts coalesced TCP frames")
    let last = try frames.append(Data("ial\n".utf8))
    check(last == [Data("partial".utf8)], "Pairing preserves fragmented trailing frames")
}

func runJoinNetworkChecks() throws {
    let server = JoinServer()
    let hostID = UUID(), clientID = UUID()
    let key = Data(repeating: 77, count: 32)
    var port: UInt16?
    var pending: [JoinRequestInfo] = []
    var joined = 0, provisions = 0
    var hostAddress: String?, followerAddress: String?
    server.onReady = { port = $0 }
    server.onRequests = { pending = $0 }
    server.onJoined = { hello, address in
        joined += 1; followerAddress = address
        check(hello.deviceID == clientID, "Host registers the approved follower identity")
        return true
    }
    try server.start(deviceID: hostID, name: "Fixture host", key: key, port: 0, advertise: false)
    pump(until: { port != nil })
    guard let port else { check(false, "Join server starts"); return }
    let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
    let client = JoinClient()
    var digits = "", result: Result<Void, Error>?
    client.onChallenge = { _, code in digits = code }
    client.provision = { code, _, address in
        provisions += 1; hostAddress = address
        check(code.key == key && code.coordinatorID == hostID, "Approved grant preserves group identity and key")
        return true
    }
    client.completion = { result = $0 }
    try client.start(endpoint: endpoint, deviceID: clientID, name: "Fixture follower")
    pump(until: { !pending.isEmpty })
    check(pending.count == 1 && !digits.isEmpty && pending.first?.code == digits, "Live TCP pairing displays matching comparison digits")
    check(provisions == 0 && joined == 0, "No key provision or group membership before host acceptance")
    if let request = pending.first {
        try server.approve(request.id)
        rejects("Duplicate acceptance cannot send a second grant") { try server.approve(request.id) }
    }
    pump(until: { result != nil })
    if case .success = result { check(true, "Join completes after follower persists and host acknowledges") }
    else { check(false, "Join completes after follower persists and host acknowledges") }
    check(provisions == 1 && joined == 1 && pending.isEmpty, "Join is recorded exactly once and pending request disappears")
    check(hostAddress == "127.0.0.1" && followerAddress == "127.0.0.1", "Routes are learned from the connected socket")

    let denied = JoinClient()
    result = nil
    denied.provision = { _, _, _ in provisions += 1; return true }
    denied.completion = { result = $0 }
    try denied.start(endpoint: endpoint, deviceID: clientID, name: "Denied")
    pump(until: { !pending.isEmpty })
    if let request = pending.first { server.reject(request.id) }
    pump(until: { result != nil && pending.isEmpty })
    if case .failure = result { check(true, "Host rejection is reported to follower") }
    else { check(false, "Host rejection is reported to follower") }
    check(provisions == 1 && joined == 1, "Rejected requests never receive a group key")

    let failedSave = JoinClient()
    result = nil
    failedSave.provision = { _, _, _ in false }
    failedSave.completion = { result = $0 }
    try failedSave.start(endpoint: endpoint, deviceID: clientID, name: "Cannot save")
    pump(until: { !pending.isEmpty })
    if let request = pending.first { try server.approve(request.id) }
    pump(until: { result != nil && pending.isEmpty })
    check(joined == 1, "A failed follower save never becomes a confirmed host membership")
    if case .failure = result { check(true, "Failed local save is not shown as joined") }
    else { check(false, "Failed local save is not shown as joined") }

    let cancelled = JoinClient()
    result = nil
    cancelled.provision = { _, _, _ in provisions += 1; return true }
    cancelled.completion = { result = $0 }
    try cancelled.start(endpoint: endpoint, deviceID: clientID, name: "Cancelled")
    pump(until: { !pending.isEmpty })
    cancelled.cancel()
    pump(until: { pending.isEmpty })
    check(pending.isEmpty && provisions == 1, "Follower cancellation removes pending request without granting key")

    let stopped = JoinClient()
    result = nil
    stopped.provision = { _, _, _ in provisions += 1; return true }
    stopped.completion = { result = $0 }
    try stopped.start(endpoint: endpoint, deviceID: clientID, name: "Stopped")
    pump(until: { !pending.isEmpty })
    let staleID = pending.first?.id
    server.stop()
    pump(until: { result != nil })
    check(pending.isEmpty && provisions == 1, "Closing discovery cancels all pending grants")
    if let staleID { rejects("Closed requests cannot later be accepted") { try server.approve(staleID) } }

}


func runJoinTimeoutAndDiscoveryChecks() throws {
    let server = JoinServer(), hostID = UUID()
    var port: UInt16?, requests: [JoinRequestInfo] = []
    var result: Result<Void, Error>?, provisions = 0
    server.onReady = { port = $0 }; server.onRequests = { requests = $0 }
    try server.start(deviceID: hostID, name: "Fixture", key: Data(repeating: 91, count: 32),
                     port: 0, advertise: false, timeout: 0.3)
    pump(until: { port != nil })
    if let port {
        let client = JoinClient()
        client.provision = { _, _, _ in provisions += 1; return true }
        client.completion = { result = $0 }
        try client.start(endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!),
                         deviceID: UUID(), name: "Expires")
        pump(until: { !requests.isEmpty })
        let expired = requests.first?.id
        pump(until: { result != nil })
        check(result != nil && requests.isEmpty && provisions == 0, "Timed-out join removes the request and never provisions a key")
        if let expired { rejects("Expired request cannot be accepted") { try server.approve(expired) } }
    } else { check(false, "Timeout fixture server starts") }
    server.stop()

    // Browse a real Bonjour announcement with no client group key.
    var found: NWEndpoint?
    let browser = NWBrowser(for: .bonjour(type: "_screenjoin._tcp", domain: nil), using: .tcp)
    browser.browseResultsChangedHandler = { results, _ in
        found = results.first { result in
            if case let .service(name, _, _, _) = result.endpoint {
                return name.hasSuffix(String(hostID.uuidString.prefix(8)))
            }
            return false
        }?.endpoint
    }
    browser.start(queue: .main)
    try server.start(deviceID: hostID, name: "Discovery fixture", key: Data(repeating: 91, count: 32),
                     port: 0, advertise: true)
    pump(until: { found != nil }, seconds: 5)
    check(found != nil, "Unpaired client discovers the host via real Bonjour without a group key")
    if let found {
        let client = JoinClient()
        result = nil
        client.completion = { result = $0 }
        try client.start(endpoint: found, deviceID: UUID(), name: "Bonjour follower")
        pump(until: { !requests.isEmpty }, seconds: 5)
        check(!requests.isEmpty, "Discovered Bonjour endpoint accepts an unpaired join request")
        client.cancel()
    }
    browser.cancel(); server.stop()
}

func runJoinConfigurationChecks() throws {
    let defaults = Settings()
    check(!defaults.allowsJoining, "Fresh installation does not advertise joining")
    var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(defaults)) as! [String: Any]
    old.removeValue(forKey: "joinEnabled")
    old["isCoordinator"] = true; old["networkEnabled"] = true
    let migrated = try JSONDecoder().decode(Settings.self, from: JSONSerialization.data(withJSONObject: old))
    check(migrated.allowsJoining, "Existing coordinator discovery settings remain compatible")
    var closed = migrated; closed.joinEnabled = false
    let reloaded = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(closed))
    check(!reloaded.allowsJoining && reloaded.networkEnabled, "Closing joining persists without disabling group communication")
    closed.peers = [Peer(name: "IPv6", host: "fe80::1234%en0")]
    try closed.validate()
    check(true, "Socket-derived scoped IPv6 addresses are accepted")
}


private final class RejectedJoinAdvertisement: JoinAdvertising {
    func start(name: String, port: UInt16, completion: @escaping (Result<Void, Error>) -> Void) {
        completion(.failure(LinkError.unavailable("fixture NoAuth")))
    }
    func stop() {}
}

func runJoinDiscoveryFailureChecks() throws {
    let server = JoinServer(advertisement: RejectedJoinAdvertisement())
    var port: UInt16?, requests: [JoinRequestInfo] = [], status = ""
    server.onReady = { port = $0 }; server.onRequests = { requests = $0 }
    server.onState = { status = $0 }
    try server.start(deviceID: UUID(), name: "Fixture", key: Data(repeating: 61, count: 32), port: 0)
    pump(until: { port != nil })
    check(status.contains("fixture NoAuth") && status.contains("IP"), "Discovery failure explicitly offers IP joining")
    if let port {
        let client = JoinClient()
        try client.start(endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!),
                         deviceID: UUID(), name: "IP follower")
        pump(until: { !requests.isEmpty })
        check(requests.count == 1, "Rejected Bonjour registration does not disable IP joining or host requests")
        client.cancel()
    } else { check(false, "Join listener survives discovery failure") }
    server.stop()
}

func runFixedAddressDiscoveryChecks() throws {
    let server = JoinServer()
    var port: UInt16?, requests: [JoinRequestInfo] = [], joined = 0
    server.onReady = { port = $0 }; server.onRequests = { requests = $0 }
    server.onJoined = { _, _ in joined += 1; return true }
    try server.start(deviceID: UUID(), name: "Fixed IP coordinator", key: Data(repeating: 57, count: 32), port: 0, advertise: false)
    pump(until: { port != nil })
    if let port {
        var result: Result<String, Error>?
        let probe = JoinProbe(endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!),
                              deviceID: UUID()) { result = $0 }
        pump(until: { result != nil })
        if case .success(let name) = result { check(name == "Fixed IP coordinator", "Fixed address discovery identifies coordinator without Bonjour") }
        else { check(false, "Fixed address discovery identifies coordinator without Bonjour") }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        check(requests.isEmpty && joined == 0, "Discovery probe creates no pending join and receives no group credential")
        withExtendedLifetime(probe) {}
    } else { check(false, "Fixed address discovery fixture starts") }
    server.stop()
}

func runControlRestartChecks() throws {
    let server = LinkServer(), id = UUID(), key = Data(repeating: 74, count: 32)
    var port: UInt16?, failed = false
    server.onReady = { port = $0 }; server.onState = { if $0.contains("失败") { failed = true } }
    server.handler = { request, reply in reply(Message(sender: id, command: .reply, responseTo: request.id, state: .unlocked)) }
    try server.start(key: key, deviceID: id, port: 0, advertise: false)
    pump(until: { port != nil })
    guard let fixedPort = port else { check(false, "Restart fixture starts"); return }
    let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: fixedPort)!)
    for attempt in 0..<3 {
        var reply: Result<Message, Error>?
        _ = LinkRequest(endpoint: endpoint, message: Message(sender: UUID(), command: .status), key: key) { reply = $0 }
        pump(until: { reply != nil })
        port = nil; failed = false
        try server.start(key: key, deviceID: id, port: fixedPort, advertise: false)
        pump(until: { port != nil || failed }, seconds: 2)
        check(port == fixedPort && !failed, "Control port survives reconfiguration after real traffic (\(attempt))")
        if failed { break }
    }
    server.stop()
}
