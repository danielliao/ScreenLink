import Foundation
import Network
import CryptoKit
import Darwin
import ScreenLinkCore

// These checks catch unencrypted/replayed frames, unsafe publication, and false delivery acknowledgements.
func runSharingChecks() throws {
    let secret = Data(repeating: 19, count: 32)
    let a = SharingHandshake(deviceID: UUID(), target: UUID(), groupKey: secret)
    let b = SharingHandshake(deviceID: a.target, target: a.deviceID, groupKey: secret)
    let request = try a.request()
    let response = try b.respond(to: request)
    var sending = try a.finish(response: response)
    var receiving = try b.accept(request: request, response: response)
    let plain = Data("private-filename.txt and private content".utf8)
    let sealed = try sending.seal(plain)
    check(sealed.range(of: plain) == nil, "Sharing metadata and content are encrypted")
    check((try? receiving.open(sealed)) == plain, "Sharing peers derive matching directional session keys")
    rejects("Sharing rejects replayed chunks") { _ = try receiving.open(sealed) }
    let next = try sending.seal(plain)
    var corrupt = next; corrupt[corrupt.count - 1] ^= 1
    rejects("Sharing rejects modified ciphertext") { _ = try receiving.open(corrupt) }
    check((try? receiving.open(next)) == plain, "Failed authentication does not advance the receive sequence")
    let wrong = SharingHandshake(deviceID: a.target, target: a.deviceID, groupKey: Data(repeating: 99, count: 32))
    rejects("Sharing rejects peers from a different group") { _ = try wrong.respond(to: request) }
    let fresh = SharingHandshake(deviceID: a.target, target: a.deviceID, groupKey: secret)
    let freshResponse = try fresh.respond(to: request)
    var freshKeys = try fresh.accept(request: request, response: freshResponse)
    rejects("Recorded packets cannot be replayed into a fresh session") { _ = try freshKeys.open(sealed) }

    let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("ScreenLink-sharing-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for name in ["../escape", "/absolute", ".", "..", "a/b", "a\\b", "a\nfile", "a\0file"] {
        rejects("Unsafe received filename is rejected: \(name.debugDescription)") { _ = try SharingFileSink(directory: root, name: name) }
    }
    let existing = root.appendingPathComponent("fixture.txt")
    try Data("keep".utf8).write(to: existing)
    let sink = try SharingFileSink(directory: root, name: "fixture.txt")
    try sink.append(Data("received".utf8))
    let published = try sink.finish()
    check(published.lastPathComponent == "fixture (1).txt", "Sharing uses a non-clobber name on collision")
    check((try? Data(contentsOf: existing)) == Data("keep".utf8), "Sharing never replaces existing file contents")
    check((try? Data(contentsOf: published)) == Data("received".utf8), "Sharing publishes the complete received bytes")
    check(getxattr(published.path, "com.apple.quarantine", nil, 0, 0, 0) > 0, "Published downloads retain the macOS quarantine marker")
    let before = try FileManager.default.contentsOfDirectory(atPath: root.path).count
    do { let partial = try SharingFileSink(directory: root, name: "partial"); try partial.append(Data([1,2,3])) }
    check((try? FileManager.default.contentsOfDirectory(atPath: root.path).count) == before, "Abandoned receives remove temporary files")
    let link = root.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
    rejects("Sharing refuses a symlink destination") { _ = try SharingFileSink(directory: link, name: "escape") }

    let guarded = try SharingFileSink(directory: root, name: "guarded.txt")
    try guarded.append(Data("authenticated bytes".utf8))
    let staging = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix(".screenlink-") }!
    let movedStaging = root.appendingPathComponent("relocated-staging")
    try FileManager.default.moveItem(at: staging, to: movedStaging)
    try FileManager.default.createSymbolicLink(at: staging, withDestinationURL: existing)
    let guardedResult = try guarded.finish()
    let guardedValues = try guardedResult.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
    check(guardedValues.isRegularFile == true && guardedValues.isSymbolicLink != true && (try? Data(contentsOf: guardedResult)) == Data("authenticated bytes".utf8), "Replacing a visible staging entry cannot publish a symlink or substituted bytes")
    try? FileManager.default.removeItem(at: staging)
    try? FileManager.default.removeItem(at: movedStaging)

    let host = SharingService(), client = SharingService()
    defer { host.stop(); client.stop() }
    let hostID = UUID(), clientID = UUID()
    var port: UInt16?, received: [(UUID, URL?)] = [], acknowledged: [UUID] = [], failures: [UUID] = []
    var clipboard: [Data] = []
    host.onReady = { port = $0 }
    host.receivePermission = { _, peer in peer == clientID }
    host.destinationDirectory = { root }
    host.onCompleted = { id, _, url in received.append((id,url)) }
    host.onClipboard = { data, _, _, _ in clipboard.append(data) }
    client.onCompleted = { id, _, _ in acknowledged.append(id) }
    client.onFailure = { id, _, _ in failures.append(id) }
    try host.start(key: secret, deviceID: hostID, port: 0, advertise: false)
    try client.start(key: secret, deviceID: clientID, port: 0, advertise: false)
    pump(until: { port != nil })
    guard let port else { check(false, "Sharing listener starts on loopback"); return }
    let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
    let input = root.appendingPathComponent("large.bin")
    let bytes = Data((0..<180_000).map { UInt8($0 % 251) })
    try bytes.write(to: input)
    let id = client.sendFile(url: input, to: endpoint, expectedPeer: hostID)
    pump(until: { acknowledged.contains(id) || failures.contains(id) })
    check(acknowledged.contains(id), "File sender completes only after authenticated receiver acknowledgement")
    if let file = received.first(where: { $0.0 == id })?.1 { check((try? Data(contentsOf: file)) == bytes, "Real loopback file crosses multiple bounded chunks intact") }
    else { check(false, "Loopback file is published by receiver") }
    let textID = client.sendData(data: Data("fixture clipboard".utf8), kind: "text", event: UUID().uuidString, to: endpoint, expectedPeer: hostID)
    pump(until: { acknowledged.contains(textID) || failures.contains(textID) })
    check(clipboard == [Data("fixture clipboard".utf8)], "Real loopback clipboard delivers only the authenticated payload")
    host.receivePermission = { _, _ in false }
    let denied = client.sendData(data: Data("denied".utf8), kind: "text", event: UUID().uuidString, to: endpoint, expectedPeer: hostID)
    pump(until: { failures.contains(denied) })
    check(failures.contains(denied) && clipboard.count == 1, "Receive permission denies delivery without clipboard mutation")
    let oversized = client.sendData(data: Data(repeating: 0, count: 1_048_577), kind: "text", event: "oversize", to: endpoint, expectedPeer: hostID)
    pump(until: { failures.contains(oversized) })
    check(failures.contains(oversized), "Oversized clipboard payload fails explicitly")
    let symlinkID = client.sendFile(url: link, to: endpoint, expectedPeer: hostID)
    pump(until: { failures.contains(symlinkID) })
    check(failures.contains(symlinkID), "Sender rejects symlinks and directories")
    let nulID = client.sendFile(url: URL(fileURLWithPath: existing.path + "\0suffix"), to: endpoint, expectedPeer: hostID)
    pump(until: { failures.contains(nulID) })
    check(failures.contains(nulID), "NUL in a source URL cannot select a different truncated local path")
    host.receivePermission = { _, _ in true }
    let impostor = client.sendData(data: Data("wrong peer".utf8), kind: "text", event: UUID().uuidString, to: endpoint, expectedPeer: UUID())
    pump(until: { failures.contains(impostor) })
    check(failures.contains(impostor) && clipboard.count == 1, "Sender pins the authenticated receiving device identity")
    let image = Data([137,80,78,71,13,10,26,10]) + Data(repeating: 7, count: 100_000)
    let imageID = client.sendData(data: image, kind: "png", event: UUID().uuidString, to: endpoint, expectedPeer: hostID)
    pump(until: { acknowledged.contains(imageID) || failures.contains(imageID) })
    check(acknowledged.contains(imageID) && clipboard.last == image, "PNG sharing preserves a bounded binary payload across chunks")
    let imageOversize = client.sendData(data: Data(repeating: 0, count: 10_485_761), kind: "png", event: "big-image", to: endpoint, expectedPeer: hostID)
    pump(until: { failures.contains(imageOversize) })
    check(failures.contains(imageOversize), "Oversized PNG is rejected before opening a connection")

    let huge = root.appendingPathComponent("sparse.bin")
    _ = FileManager.default.createFile(atPath: huge.path, contents: nil)
    let sparse = try FileHandle(forWritingTo: huge)
    try sparse.truncate(atOffset: 2_147_483_649); try sparse.close()
    let hugeID = client.sendFile(url: huge, to: endpoint, expectedPeer: hostID)
    pump(until: { failures.contains(hugeID) })
    check(failures.contains(hugeID), "Files beyond 2 GiB are rejected without loading them")
    let fifo = root.appendingPathComponent("fifo")
    check(mkfifo(fifo.path, 0o600) == 0, "Special-file test fixture can be created")
    let fifoID = client.sendFile(url: fifo, to: endpoint, expectedPeer: hostID)
    pump(until: { failures.contains(fifoID) })
    check(failures.contains(fifoID), "FIFO input is rejected without blocking the service")

    let cancelInput = root.appendingPathComponent("cancel.bin")
    _ = FileManager.default.createFile(atPath: cancelInput.path, contents: nil)
    let sparseCancel = try FileHandle(forWritingTo: cancelInput)
    try sparseCancel.truncate(atOffset: 32 * 1_048_576); try sparseCancel.close()
    var cancelID: UUID?, receiverFailures: [UUID] = []
    host.onFailure = { id, _, _ in receiverFailures.append(id) }
    host.onProgress = { id, _, _, _ in if id == cancelID { host.cancel(id: id) } }
    cancelID = client.sendFile(url: cancelInput, to: endpoint, expectedPeer: hostID)
    pump(until: { receiverFailures.contains(cancelID!) && failures.contains(cancelID!) })
    check(receiverFailures.contains(cancelID!) && failures.contains(cancelID!), "Receiver cancellation terminates both transfer ends")
    check(!received.contains(where: { $0.0 == cancelID }), "Cancelled file is never published as complete")
    let remaining = try FileManager.default.contentsOfDirectory(atPath: root.path)
    check(!remaining.contains(where: { $0.hasPrefix(".screenlink-") }), "Cancelled transfer removes its descriptor-owned temporary file")
    host.onProgress = nil

    let clipboardCount = clipboard.count
    var lockID: UUID?
    host.onTransferStarted = { id, _, _, _ in if id == lockID { host.receivePermission = { _, _ in false } } }
    lockID = client.sendData(data: Data(repeating: 65, count: 900_000), kind: "text", event: UUID().uuidString, to: endpoint, expectedPeer: hostID)
    pump(until: { failures.contains(lockID!) || acknowledged.contains(lockID!) })
    check(failures.contains(lockID!) && clipboard.count == clipboardCount, "Lock or permission change during reception prevents clipboard delivery")
    host.onTransferStarted = nil; host.receivePermission = { _, _ in true }

    let ids = (0..<3).map { _ in client.sendData(data: Data("concurrency".utf8), kind: "text", event: UUID().uuidString, to: endpoint, expectedPeer: hostID) }
    pump(until: { ids.allSatisfy { acknowledged.contains($0) || failures.contains($0) } })
    check(ids.filter { acknowledged.contains($0) }.count == 2 && failures.contains(ids[2]), "Per-peer sharing admits two transfers and bounds excess work")

    let duplicateEvent = UUID().uuidString
    let duplicateFirst = client.sendData(data: Data("one event".utf8), kind: "text", event: duplicateEvent, to: endpoint, expectedPeer: hostID)
    pump(until: { acknowledged.contains(duplicateFirst) || failures.contains(duplicateFirst) })
    let deliveredOnce = clipboard.count
    let duplicateSecond = client.sendData(data: Data("one event".utf8), kind: "text", event: duplicateEvent, to: endpoint, expectedPeer: hostID)
    pump(until: { failures.contains(duplicateSecond) })
    check(acknowledged.contains(duplicateFirst) && failures.contains(duplicateSecond) && clipboard.count == deliveredOnce, "Repeated clipboard events cannot be redelivered through fresh sessions")

    let corruptID = UUID()
    let rawIdentity = SharingHandshake(deviceID: clientID, target: hostID, groupKey: secret)
    var rawCipher: SharingCipher?, rawError = false
    let raw = NWConnection(to: endpoint, using: .tcp)
    defer { raw.cancel() }
    raw.stateUpdateHandler = { state in
        guard case .ready = state else { return }
        do {
            sharingWrite(raw, bytes: try rawIdentity.request()) {
                sharingRead(raw) { response in
                    do {
                        guard let response else { rawError = true; return }
                        rawCipher = try rawIdentity.finish(response: response)
                        let offer: [String: Any] = ["type": "offer", "id": corruptID.uuidString, "kind": "file", "name": "bad-digest.bin", "total": 3, "event": ""]
                        sharingWrite(raw, bytes: try rawCipher!.seal(JSONSerialization.data(withJSONObject: offer))) {
                            sharingRead(raw) { accepted in
                                do {
                                    guard let accepted else { rawError = true; return }
                                    _ = try rawCipher!.open(accepted)
                                    let chunk: [String: Any] = ["type": "chunk", "id": corruptID.uuidString, "bytes": Data([1,2,3]).base64EncodedString()]
                                    sharingWrite(raw, bytes: try rawCipher!.seal(JSONSerialization.data(withJSONObject: chunk))) {
                                        do {
                                            let badEnd: [String: Any] = ["type": "end", "id": corruptID.uuidString, "total": 3, "digest": Data(repeating: 0, count: 32).base64EncodedString()]
                                            sharingWrite(raw, bytes: try rawCipher!.seal(JSONSerialization.data(withJSONObject: badEnd))) {}
                                        } catch { rawError = true }
                                    }
                                } catch { rawError = true }
                            }
                        }
                    } catch { rawError = true }
                }
            }
        } catch { rawError = true }
    }
    raw.start(queue: .main)
    pump(until: { rawError || receiverFailures.contains(corruptID) })
    check(!rawError && receiverFailures.contains(corruptID), "A valid encrypted stream with a wrong final digest is rejected")
    check(!FileManager.default.fileExists(atPath: root.appendingPathComponent("bad-digest.bin").path), "Integrity failure never publishes a completed file")
    let afterCorruption = try FileManager.default.contentsOfDirectory(atPath: root.path)
    check(!afterCorruption.contains(where: { $0.hasPrefix(".screenlink-") }), "Integrity failure cleans its partial file")

    var replayFinished = false, replayResponse: Data?
    let replay = NWConnection(to: endpoint, using: .tcp)
    defer { replay.cancel() }
    replay.stateUpdateHandler = { state in
        if case .ready = state, let request = try? rawIdentity.request() {
            sharingWrite(replay, bytes: request) { sharingRead(replay) { replayResponse = $0; replayFinished = true } }
        }
    }
    replay.start(queue: .main)
    pump(until: { replayFinished })
    check(replayFinished && replayResponse == nil, "Replayed authenticated handshakes cannot reserve another receiving session")

    var reformattedDone = false, reformattedResponse: Data?
    let reformatted = NWConnection(to: endpoint, using: .tcp)
    defer { reformatted.cancel() }
    let requestObject = try JSONSerialization.jsonObject(with: rawIdentity.request())
    let prettyRequest = try JSONSerialization.data(withJSONObject: requestObject, options: [.prettyPrinted, .sortedKeys])
    reformatted.stateUpdateHandler = { state in
        if case .ready = state {
            sharingWrite(reformatted, bytes: prettyRequest) { sharingRead(reformatted) { reformattedResponse = $0; reformattedDone = true } }
        }
    }
    reformatted.start(queue: .main)
    pump(until: { reformattedDone })
    check(reformattedDone && reformattedResponse == nil, "JSON whitespace cannot bypass authenticated handshake replay protection")

    var stalledPort: UInt16?, stalledConnections: [NWConnection] = []
    let stalled = try NWListener(using: .tcp, on: .any)
    stalled.stateUpdateHandler = { state in if case .ready = state { stalledPort = stalled.port?.rawValue } }
    stalled.newConnectionHandler = { connection in stalledConnections.append(connection); connection.start(queue: .main) }
    stalled.start(queue: .main)
    defer { stalled.cancel(); stalledConnections.forEach { $0.cancel() } }
    pump(until: { stalledPort != nil })
    if let stalledPort {
        let stalledEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: stalledPort)!)
        let stalledID = client.sendData(data: Data("timeout".utf8), kind: "text", event: UUID().uuidString, to: stalledEndpoint, expectedPeer: hostID)
        pump(until: { failures.contains(stalledID) }, seconds: 13)
        check(failures.contains(stalledID), "An unresponsive peer cannot retain a handshake indefinitely")
    } else { check(false, "Timeout fixture listener starts") }

    var stoppedID: UUID?
    host.onProgress = { id, _, _, _ in if id == stoppedID { host.stop() } }
    stoppedID = client.sendFile(url: cancelInput, to: endpoint, expectedPeer: hostID)
    pump(until: { receiverFailures.contains(stoppedID!) && failures.contains(stoppedID!) })
    check(receiverFailures.contains(stoppedID!) && failures.contains(stoppedID!) && !received.contains(where: { $0.0 == stoppedID }), "Stopping the sharing service aborts both ends of an active copy")
    let afterStop = try FileManager.default.contentsOfDirectory(atPath: root.path)
    check(!afterStop.contains(where: { $0.hasPrefix(".screenlink-") }), "Service stop removes all active file staging directories")
    host.onProgress = nil

    var restartReady = 0, restartFailures: [String] = []
    host.onReady = { value in if value == port { restartReady += 1 } }
    host.onListenerFailure = { restartFailures.append($0) }
    var restartDeliveries = 0
    for attempt in 0..<6 {
        host.stop()
        do { try host.start(key: secret, deviceID: hostID, port: port, advertise: false) }
        catch { restartFailures.append(error.localizedDescription) }
        pump(until: { restartReady > attempt || !restartFailures.isEmpty })
        if !restartFailures.isEmpty || restartReady <= attempt { break }
        let next = client.sendData(data: Data("restart fixture".utf8), kind: "text", event: UUID().uuidString, to: endpoint, expectedPeer: hostID)
        pump(until: { acknowledged.contains(next) || failures.contains(next) })
        if acknowledged.contains(next) { restartDeliveries += 1 }
    }
    check(restartFailures.isEmpty && restartReady == 6 && restartDeliveries == 6, "Fixed-port sharing listener restarts immediately after active TCP sessions")

    let callbacksBeforeBurst = restartReady
    for _ in 0..<8 {
        host.stop()
        do { try host.start(key: secret, deviceID: hostID, port: port, advertise: false) }
        catch { restartFailures.append(error.localizedDescription) }
    }
    pump(until: { restartReady > callbacksBeforeBurst || !restartFailures.isEmpty })
    RunLoop.main.run(until: Date().addingTimeInterval(0.15))
    check(restartFailures.isEmpty && restartReady == callbacksBeforeBurst + 1, "Rapid settings saves expose only the newest listener generation")

}

// Real framed-socket fixtures for deliberately invalid protocol peers.
private func sharingWrite(_ connection: NWConnection, bytes: Data, completion: @escaping () -> Void) {
    let length = withUnsafeBytes(of: UInt32(bytes.count).bigEndian) { Data($0) }
    connection.send(content: length + bytes, completion: .contentProcessed { error in if error == nil { completion() } })
}
private func sharingRead(_ connection: NWConnection, completion: @escaping (Data?) -> Void) {
    sharingReadExactly(connection, count: 4) { header in
        guard let header else { completion(nil); return }
        let size = header.reduce(0) { ($0 << 8) | Int($1) }
        guard size > 0, size <= 100_000 else { completion(nil); return }
        sharingReadExactly(connection, count: size, completion: completion)
    }
}
private func sharingReadExactly(_ connection: NWConnection, count: Int, accumulated: Data = Data(), completion: @escaping (Data?) -> Void) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: count - accumulated.count) { data, _, ended, error in
        var result = accumulated; result.append(data ?? Data())
        if result.count == count { completion(result) }
        else if error != nil || ended || data?.isEmpty != false { completion(nil) }
        else { sharingReadExactly(connection, count: count, accumulated: result, completion: completion) }
    }
}
