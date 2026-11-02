import Foundation
import Network
import CryptoKit

private struct SharingMessage: Codable {
    var type: String
    var id: UUID
    var kind: String? = nil
    var name: String? = nil
    var event: String? = nil
    var total: Int64? = nil
    var bytes: Data? = nil
    var digest: Data? = nil
}

/// Configure and call from the main thread. All disk and network work uses a private serial queue.
/// Callbacks and receive policy run on the main queue. One connection carries one transfer.
public final class SharingService {
    public var onReady: ((UInt16) -> Void)?
    public var onListenerFailure: ((String) -> Void)?
    public var onTransferStarted: ((UUID, UUID, String, String) -> Void)?
    public var onProgress: ((UUID, UUID, Int64, Int64) -> Void)?
    public var onCompleted: ((UUID, UUID, URL?) -> Void)?
    public var onFailure: ((UUID, UUID, String) -> Void)?
    public var onClipboard: ((Data, String, String, UUID) -> Void)?
    public var receivePermission: ((String, UUID) -> Bool)?
    public var destinationDirectory: (() -> URL?)?
    private let queue = DispatchQueue(label: "ScreenLink.encrypted-sharing", qos: .utility)
    private var listener: NWListener?
    private let listenerLifecycle: SharingListenerLifecycle
    private var sessions: [UUID: SharingSession] = [:]
    private var groupKey: Data?
    private var deviceID: UUID?
    private var generation = UUID()
    private var mainGeneration = UUID()
    private var accepted: [String: TimeInterval] = [:]
    private let admissionLock = NSLock()
    private var pending: [UUID: Int] = [:]
    public init() { listenerLifecycle = SharingListenerLifecycle(queue: queue) }

    public func start(key: Data, deviceID: UUID, port: UInt16 = 45733, advertise: Bool = true) throws {
        guard key.count == 32, let nwPort = NWEndpoint.Port(rawValue: port) else { throw SharingError.invalid }
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: nwPort)
        mainGeneration = UUID()
        let epoch = mainGeneration
        queue.async { [self] in
            stopInternal()
            generation = epoch
            groupKey = key; self.deviceID = deviceID; self.listener = listener
            let current = generation
            if advertise { listener.service = NWListener.Service(name: deviceID.uuidString, type: "_screenshare._tcp") }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self, self.generation == current, self.sessions.count < 16 else { connection.cancel(); return }
                let session = SharingSession(connection: connection, service: self, queue: self.queue, groupKey: key, localID: deviceID)
                self.sessions[session.token] = session; session.start()
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, self.generation == current else { return }
                if case .ready = state, let value = listener?.port?.rawValue {
                    DispatchQueue.main.async { [weak self] in
                        guard self?.mainGeneration == current else { return }; self?.onReady?(value)
                    }
                } else if case .failed(let error) = state {
                    self.stopInternal()
                    DispatchQueue.main.async { [weak self] in
                        guard self?.mainGeneration == current else { return }
                        self?.onListenerFailure?(error.localizedDescription)
                    }
                }
            }
            listenerLifecycle.replace(with: listener)
        }
    }
    public func stop() { mainGeneration = UUID(); queue.async { [self] in stopInternal() } }
    private func stopInternal() {
        generation = UUID(); listenerLifecycle.stop(); listener = nil
        for session in Array(sessions.values) { session.fail(SharingError.cancelled) }
        sessions.removeAll(); accepted.removeAll(); groupKey = nil; deviceID = nil
    }
    @discardableResult public func sendFile(url: URL, to endpoint: NWEndpoint, expectedPeer: UUID) -> UUID {
        send(endpoint: endpoint, peer: expectedPeer, file: url, data: nil, kind: "file", event: "")
    }
    @discardableResult public func sendData(data: Data, kind: String, event: String, to endpoint: NWEndpoint, expectedPeer: UUID) -> UUID {
        send(endpoint: endpoint, peer: expectedPeer, file: nil, data: data, kind: kind, event: event)
    }
    private func send(endpoint: NWEndpoint, peer: UUID, file: URL?, data: Data?, kind: String, event: String) -> UUID {
        let id = UUID()
        // Do not retain unbounded submitted clipboard data in the transport queue.
        guard kind == "file" || (kind == "text" && (data?.count ?? Int.max) <= 1_048_576) || (kind == "png" && (data?.count ?? Int.max) <= 10_485_760), event.utf8.count <= 128 else {
            DispatchQueue.main.async { [weak self] in self?.onFailure?(id, peer, SharingError.limit.localizedDescription) }; return id
        }
        admissionLock.lock()
        let admitted = pending.values.reduce(0, +) < 16 && (pending[peer] ?? 0) < 2
        if admitted { pending[peer, default: 0] += 1 }
        admissionLock.unlock()
        guard admitted else {
            DispatchQueue.main.async { [weak self] in self?.onFailure?(id, peer, SharingError.limit.localizedDescription) }; return id
        }
        queue.async { [self] in
            admissionLock.lock()
            if pending[peer] == 1 { pending.removeValue(forKey: peer) } else { pending[peer, default: 1] -= 1 }
            admissionLock.unlock()
            guard let groupKey, let deviceID, peer != deviceID, sessions.count < 16, permits(peer: peer) else {
                DispatchQueue.main.async { [weak self] in self?.onFailure?(id, peer, SharingError.limit.localizedDescription) }; return
            }
            let session = SharingSession(connection: NWConnection(to: endpoint, using: .tcp), service: self, queue: queue, groupKey: groupKey, localID: deviceID, peer: peer, transferID: id)
            do { try session.prepare(file: file, data: data, kind: kind, event: event) }
            catch { DispatchQueue.main.async { [weak self] in self?.onFailure?(id, peer, error.localizedDescription) }; return }
            sessions[session.token] = session
            began(id: id, peer: peer, kind: kind, name: file?.lastPathComponent ?? "")
            session.start()
        }
        return id
    }
    public func cancel(id: UUID) { queue.async { [self] in sessions.values.first(where: { $0.transferID == id })?.fail(SharingError.cancelled) } }
    /// Cancels active sessions of a kind after its feature permission is revoked. Files already accepted
    /// may finish while locked; call stop() to revoke all sessions when changing groups.
    public func revoke(kind: String) {
        queue.async { [self] in for session in Array(sessions.values) where session.kind == kind { session.fail(SharingError.cancelled) } }
    }
    fileprivate func permits(peer: UUID, excluding token: UUID? = nil) -> Bool {
        sessions.values.filter { $0.token != token && $0.peer == peer }.count < 2
    }
    fileprivate func remove(_ token: UUID) { sessions.removeValue(forKey: token) }
    fileprivate func reserveHandshake(_ request: Data) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        accepted = accepted.filter { now - $0.value < 600 }
        guard let digest = try? SharingHandshake.requestFingerprint(request) else { return false }
        let fingerprint = "hello:" + digest.base64EncodedString()
        guard accepted.count < 4096, accepted[fingerprint] == nil else { return false }
        accepted[fingerprint] = now
        return true
    }
    fileprivate func reserve(id: UUID, peer: UUID, event: String, clipboard: Bool) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        accepted = accepted.filter { now - $0.value < 600 }
        let ids = ["transfer:\(id)"] + (clipboard ? ["clipboard:\(peer):\(event)"] : [])
        guard !sessions.values.contains(where: { $0.transferID == id }), accepted.count + ids.count <= 4096, ids.allSatisfy({ accepted[$0] == nil }) else { return false }
        for key in ids { accepted[key] = now }
        return true
    }
    fileprivate func authorize(kind: String, peer: UUID, completion: @escaping (Bool, URL?) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let allowed = self.receivePermission?(kind, peer) ?? false
            let destination = allowed && kind == "file" ? self.destinationDirectory?() : nil
            self.queue.async { completion(allowed, destination) }
        }
    }
    fileprivate func began(id: UUID, peer: UUID, kind: String, name: String) {
        DispatchQueue.main.async { [weak self] in self?.onTransferStarted?(id, peer, kind, name) }
    }
    fileprivate func progress(id: UUID, peer: UUID, bytes: Int64, total: Int64) {
        DispatchQueue.main.async { [weak self] in self?.onProgress?(id, peer, bytes, total) }
    }
    fileprivate func complete(id: UUID, peer: UUID, url: URL?) {
        DispatchQueue.main.async { [weak self] in self?.onCompleted?(id, peer, url) }
    }
    fileprivate func failed(id: UUID, peer: UUID, error: Error) {
        DispatchQueue.main.async { [weak self] in self?.onFailure?(id, peer, error.localizedDescription) }
    }
    fileprivate func deliver(data: Data, kind: String, event: String, peer: UUID, completion: @escaping (Bool) -> Void) {
        let epoch = generation
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let allowed = self.mainGeneration == epoch && (self.receivePermission?(kind, peer) ?? false)
            if allowed { self.onClipboard?(data, kind, event, peer) }
            self.queue.async { completion(allowed) }
        }
    }
}

private final class SharingSession {
    let token = UUID()
    private(set) var transferID: UUID?
    private(set) var peer: UUID?
    private(set) var kind = ""
    private let connection: NWConnection
    private weak var service: SharingService?
    private let queue: DispatchQueue
    private let groupKey: Data
    private let localID: UUID
    private let outgoing: Bool
    private var handshake: SharingHandshake?
    private var cipher: SharingCipher?
    private var phase = "hello"
    private var timer: DispatchSourceTimer?
    private let started = ProcessInfo.processInfo.systemUptime
    private var touched = ProcessInfo.processInfo.systemUptime
    private var lastProgress: TimeInterval = 0
    private var source: FileHandle?
    private var sourceData: Data?
    private var sink: SharingFileSink?
    private var receivedData = Data()
    private var offer: SharingMessage?
    private var total: Int64 = 0
    private var count: Int64 = 0
    private var hash = SHA256()
    private var finished = false
    private var committed = false
    init(connection: NWConnection, service: SharingService, queue: DispatchQueue, groupKey: Data, localID: UUID, peer: UUID? = nil, transferID: UUID? = nil) {
        self.connection = connection; self.service = service; self.queue = queue; self.groupKey = groupKey; self.localID = localID
        self.peer = peer; self.transferID = transferID; outgoing = peer != nil
    }
    func prepare(file: URL?, data: Data?, kind: String, event: String) throws {
        guard let transferID else { throw SharingError.invalid }
        self.kind = kind
        var name: String?
        if let file {
            let opened = try sharingSource(file); source = opened.0; total = opened.1; name = file.lastPathComponent
            guard name!.utf8.count <= 200 else { throw SharingError.invalid }
        } else {
            guard let data, (kind == "text" && String(data: data, encoding: .utf8) != nil) || (kind == "png" && data.starts(with: [137,80,78,71,13,10,26,10])), !event.isEmpty else { throw SharingError.invalid }
            sourceData = data; total = Int64(data.count)
        }
        offer = SharingMessage(type: "offer", id: transferID, kind: kind, name: name, event: event, total: total)
    }
    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if now - self.touched > (self.phase == "hello" ? 10 : 30) || now - self.started > 7200 { self.fail(SharingError.timeout) }
        }
        self.timer = timer; timer.resume()
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, !self.finished else { return }
            switch state {
            case .ready:
                if self.outgoing, let peer = self.peer {
                    self.handshake = SharingHandshake(deviceID: self.localID, target: peer, groupKey: self.groupKey)
                    do { try self.sendFrame(self.handshake!.request()) { self.readFrame() } }
                    catch { self.fail(error) }
                } else { self.readFrame() }
            case .failed(let error): self.fail(error)
            case .cancelled: self.fail(SharingError.cancelled)
            default: break
            }
        }
        connection.start(queue: queue)
    }
    private func sendFrame(_ bytes: Data, completion: @escaping () -> Void) throws {
        guard !finished, bytes.count <= 96 * 1024 + 24 else { throw SharingError.limit }
        let size = withUnsafeBytes(of: UInt32(bytes.count).bigEndian) { Data($0) }
        connection.send(content: size + bytes, completion: .contentProcessed { [weak self] error in
            guard let self, !self.finished else { return }
            if let error { self.fail(error) } else { self.touched = ProcessInfo.processInfo.systemUptime; completion() }
        })
    }
    private func send(_ message: SharingMessage, completion: @escaping () -> Void = {}) {
        do {
            guard cipher != nil else { throw SharingError.authentication }
            let bytes = try cipher!.seal(JSONEncoder().encode(message))
            try sendFrame(bytes, completion: completion)
        } catch { fail(error) }
    }
    private func readExact(_ length: Int, accumulated: Data = Data(), completion: @escaping (Data) -> Void) {
        guard !finished else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: length - accumulated.count) { [weak self] data, _, complete, error in
            guard let self, !self.finished else { return }
            if let error { self.fail(error); return }
            var bytes = accumulated
            if let data { bytes.append(data) }
            guard bytes.count <= length else { self.fail(SharingError.limit); return }
            if bytes.count == length { self.touched = ProcessInfo.processInfo.systemUptime; completion(bytes) }
            else if complete || data?.isEmpty != false { self.fail(SharingError.invalid) }
            else { self.readExact(length, accumulated: bytes, completion: completion) }
        }
    }
    private func readFrame() {
        readExact(4) { [weak self] header in
            guard let self else { return }
            let length = header.reduce(0) { ($0 << 8) | Int($1) }
            guard length > 0, length <= (self.phase == "hello" ? 2048 : 96 * 1024 + 24) else { self.fail(SharingError.limit); return }
            self.readExact(length) { [weak self] bytes in self?.handle(bytes) }
        }
    }
    private func handle(_ bytes: Data) {
        do {
            if phase == "hello" {
                if outgoing {
                    guard let handshake, let offer else { throw SharingError.invalid }
                    cipher = try handshake.finish(response: bytes); self.handshake = nil; phase = "accept"
                    send(offer) { self.readFrame() }
                } else {
                    let peer = try SharingHandshake.requester(bytes, groupKey: groupKey, target: localID)
                    guard service?.permits(peer: peer, excluding: token) == true, service?.reserveHandshake(bytes) == true else { throw SharingError.limit }
                    self.peer = peer
                    let handshake = SharingHandshake(deviceID: localID, target: peer, groupKey: groupKey)
                    let response = try handshake.respond(to: bytes)
                    cipher = try handshake.accept(request: bytes, response: response); phase = "offer"
                    try sendFrame(response) { self.readFrame() }
                }
                return
            }
            guard cipher != nil else { throw SharingError.authentication }
            let message = try JSONDecoder().decode(SharingMessage.self, from: cipher!.open(bytes))
            if phase != "offer", message.id != transferID { throw SharingError.authentication }
            if message.type == "reject" { throw SharingError.denied }
            switch phase {
            case "offer": try accept(message)
            case "accept":
                guard message.type == "accept" else { throw SharingError.invalid }
                phase = "sending"; sendNext()
                // Read final acknowledgement concurrently so permission revocation/disconnect interrupts sending.
                readFrame()
            case "sending", "ack":
                guard phase == "ack", message.type == "ack", message.total == total else { throw SharingError.invalid }
                succeed(url: nil)
            case "receiving": try receive(message)
            default: throw SharingError.invalid
            }
        } catch { fail(error) }
    }
    private func accept(_ message: SharingMessage) throws {
        guard message.type == "offer", let peer, let kind = message.kind, let size = message.total, size >= 0,
              (kind == "file" && size <= 2_147_483_648) || (kind == "text" && size <= 1_048_576) || (kind == "png" && size <= 10_485_760),
              (message.event?.utf8.count ?? 0) <= 128,
              kind == "file" || !(message.event ?? "").isEmpty,
              service?.reserve(id: message.id, peer: peer, event: message.event ?? "", clipboard: kind != "file") == true else { throw SharingError.invalid }
        transferID = message.id; self.kind = kind; total = size; offer = message; phase = "permission"
        service?.authorize(kind: kind, peer: peer) { [weak self] allowed, directory in
            guard let self, !self.finished else { return }
            do {
                guard allowed else {
                    self.send(SharingMessage(type: "reject", id: message.id)) { self.fail(SharingError.denied) }; return
                }
                if kind == "file" {
                    guard let directory, let name = message.name else { throw SharingError.filesystem }
                    self.sink = try SharingFileSink(directory: directory, name: name)
                }
                self.phase = "receiving"
                self.service?.began(id: message.id, peer: peer, kind: kind, name: message.name ?? "")
                self.send(SharingMessage(type: "accept", id: message.id)) { self.reportProgress(); self.readFrame() }
            } catch { self.fail(error) }
        }
    }
    private func sendNext() {
        guard !finished, let id = transferID else { return }
        do {
            if count == total {
                if let source, let extra = try source.read(upToCount: 1), !extra.isEmpty { throw SharingError.invalid }
                try? source?.close(); source = nil; sourceData = nil
                phase = "ack"
                send(SharingMessage(type: "end", id: id, total: count, digest: Data(hash.finalize())))
                return
            }
            let length = Int(min(65_536, total - count))
            let bytes: Data
            if let source { bytes = try source.read(upToCount: length) ?? Data() }
            else if let sourceData { bytes = sourceData.subdata(in: Int(count)..<(Int(count) + length)) }
            else { throw SharingError.invalid }
            guard !bytes.isEmpty, bytes.count <= length else { throw SharingError.invalid }
            count += Int64(bytes.count); hash.update(data: bytes)
            send(SharingMessage(type: "chunk", id: id, bytes: bytes)) { self.reportProgress(); self.sendNext() }
        } catch { fail(error) }
    }
    private func receive(_ message: SharingMessage) throws {
        guard let id = transferID, let peer else { throw SharingError.invalid }
        if message.type == "chunk" {
            guard let bytes = message.bytes, !bytes.isEmpty, bytes.count <= 65_536, count + Int64(bytes.count) <= total else { throw SharingError.limit }
            if let sink { try sink.append(bytes) } else { receivedData.append(bytes) }
            hash.update(data: bytes); count += Int64(bytes.count); reportProgress(); readFrame()
        } else if message.type == "end" {
            guard count == total, message.total == total, message.digest == Data(hash.finalize()) else { throw SharingError.authentication }
            phase = "finishing"
            if let sink {
                let url = try sink.finish(); self.sink = nil
                // The receive is already committed. A lost ACK must not erase or report this file as incomplete.
                committed = true
                service?.complete(id: id, peer: peer, url: url)
                send(SharingMessage(type: "ack", id: id, total: total)) { self.close() }
            } else {
                guard (kind == "text" && String(data: receivedData, encoding: .utf8) != nil) || (kind == "png" && receivedData.starts(with: [137,80,78,71,13,10,26,10])) else { throw SharingError.invalid }
                service?.deliver(data: receivedData, kind: kind, event: offer?.event ?? "", peer: peer) { [weak self] allowed in
                    guard let self, !self.finished else { return }
                    guard allowed else { self.fail(SharingError.denied); return }
                    self.committed = true
                    self.service?.complete(id: id, peer: peer, url: nil)
                    self.send(SharingMessage(type: "ack", id: id, total: self.total)) { self.close() }
                }
            }
        } else { throw SharingError.invalid }
    }
    private func reportProgress() {
        guard kind == "file" else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if count == total || now - lastProgress >= 0.1, let id = transferID, let peer {
            lastProgress = now; service?.progress(id: id, peer: peer, bytes: count, total: total)
        }
    }
    private func succeed(url: URL?) {
        guard !finished, let id = transferID, let peer else { return }
        service?.complete(id: id, peer: peer, url: url); close()
    }
    func fail(_ error: Error) {
        guard !finished else { return }
        if !committed, let id = transferID, let peer { service?.failed(id: id, peer: peer, error: error) }
        close()
    }
    private func close() {
        guard !finished else { return }; finished = true
        timer?.cancel(); timer = nil; connection.stateUpdateHandler = nil; connection.cancel()
        try? source?.close(); source = nil; sourceData = nil; sink?.abort(); sink = nil; receivedData = Data(); cipher = nil
        service?.remove(token)
    }
}

/// Cancellation releases a listening endpoint asynchronously. Rebind only after the
/// old listener reports .cancelled, coalescing rapid settings changes to the latest.
private final class SharingListenerLifecycle {
    private let queue: DispatchQueue
    private var active: NWListener?
    private var pending: NWListener?
    private var closing = false
    init(queue: DispatchQueue) { self.queue = queue }
    func replace(with listener: NWListener) {
        discardPending()
        pending = listener
        if active == nil { startPending() } else { cancelActive() }
    }
    func stop() { discardPending(); cancelActive() }
    private func discardPending() {
        pending?.newConnectionHandler = nil; pending?.stateUpdateHandler = nil
        pending?.cancel(); pending = nil
    }
    private func cancelActive() {
        guard let active, !closing else { return }
        closing = true; active.newConnectionHandler = nil; active.cancel()
    }
    private func startPending() {
        guard active == nil, let next = pending else { return }
        pending = nil; active = next; closing = false
        let callback = next.stateUpdateHandler
        next.stateUpdateHandler = { [weak self, weak next] state in
            guard let self, let next, self.active === next else { return }
            if case .cancelled = state {
                self.active = nil; self.closing = false; next.stateUpdateHandler = nil
                self.startPending()
            } else if !self.closing { callback?(state) }
        }
        next.start(queue: queue)
    }
}
