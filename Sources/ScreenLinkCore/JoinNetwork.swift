import Foundation
import Network

private struct JoinPacket: Codable {
    enum Kind: String, Codable { case commit, challenge, reveal, grant, receipt, complete, reject }
    var version = 1
    var kind: Kind
    var session: UUID
    var hello: JoinHello?
    var blob: Data?
}

private final class JoinChannel {
    let connection: NWConnection
    var onReady: (() -> Void)?
    var onPacket: ((JoinPacket) -> Void)?
    var onClose: ((String) -> Void)?
    private var frames = JoinFrames()
    private var closed = false
    var remoteHost: String? {
        let endpoint = connection.currentPath?.remoteEndpoint ?? connection.endpoint
        if case let .hostPort(host, _) = endpoint { return "\(host)" }
        return nil
    }
    init(_ connection: NWConnection) { self.connection = connection }
    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: self.onReady?(); self.read()
            case .failed: self.close("连接失败，请检查 IP、网络权限和主控是否开放加入")
            case .cancelled: self.close("连接已关闭")
            default: break
            }
        }
        connection.start(queue: .main)
    }
    func send(_ packet: JoinPacket, sent: (() -> Void)? = nil) {
        guard !closed else { return }
        do {
            var data = try JSONEncoder().encode(packet)
            guard data.count <= Wire.limit else { throw ProtocolError.oversized }
            data.append(10)
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                if error != nil { self?.close("发送失败") } else { sent?() }
            })
        } catch { close("配对消息无效") }
    }
    private func read() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Wire.limit) { [weak self] data, _, done, error in
            guard let self, !self.closed else { return }
            do {
                if let data {
                    for frame in try self.frames.append(data) {
                        let packet = try JSONDecoder().decode(JoinPacket.self, from: frame)
                        guard packet.version == 1 else { throw ProtocolError.invalid }
                        self.onPacket?(packet)
                        if self.closed { return }
                    }
                }
                if done || error != nil { self.close("对方已断开连接"); return }
                self.read()
            } catch { self.close("配对消息无效或已被篡改") }
        }
    }
    func close(_ reason: String) {
        guard !closed else { return }
        closed = true
        let callback = onClose
        onClose = nil; onReady = nil; onPacket = nil
        connection.stateUpdateHandler = nil; connection.cancel()
        callback?(reason)
    }
}

public struct JoinRequestInfo: Identifiable {
    public let id: UUID
    public let name: String
    public let deviceID: UUID
    public let address: String
    public let code: String
}

private final class HostJoin {
    let id = UUID()
    let channel: JoinChannel
    let expires: TimeInterval
    var commitment: Data?
    var host: JoinIdentity?
    var client: JoinHello?
    var secrets: JoinSecrets?
    var approved = false
    var receivedReceipt = false
    init(channel: JoinChannel, timeout: TimeInterval) {
        self.channel = channel; self.expires = ProcessInfo.processInfo.systemUptime + timeout
    }
}

public final class JoinServer {
    public var onRequests: (([JoinRequestInfo]) -> Void)?
    public var onReady: ((UInt16) -> Void)?
    public var onListening: ((Bool) -> Void)?
    public var onState: ((String) -> Void)?
    public var onJoined: ((JoinHello, String?) -> Bool)?
    private var listener: NWListener?
    private let lifecycle = ListenerLifecycle()
    private var sessions: [UUID: HostJoin] = [:]
    private var attempts: [TimeInterval] = []
    private var groupKey: Data?
    private let advertisement: JoinAdvertising
    public init(advertisement: JoinAdvertising = JoinAdvertisement()) { self.advertisement = advertisement }
    public func start(deviceID: UUID, name: String, key: Data, port: UInt16 = 45732,
                      advertise: Bool = true, timeout: TimeInterval = 120) throws {
        stop()
        guard key.count == 32 else { throw ProtocolError.authentication }
        groupKey = key
        let parameters = NWParameters.tcp
        // Reconfiguration can overlap asynchronous cancellation and connections in
        // TIME_WAIT. Permit rebinding our fixed endpoint after stopping the listener.
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: port == 0 ? .any : NWEndpoint.Port(rawValue: port)!)
        self.listener = listener
        // Keep the TCP listener independent of Bonjour. NWListener.service closes
        // its inbox when publication fails (e.g. stale NSBonjourServices -> NoAuth).
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener, self.listener === listener else { return }
            switch state {
            case .ready:
                guard let port = listener.port?.rawValue else { return }
                self.onListening?(true)
                self.onState?("IP 加入已就绪，等待跟随端申请")
                self.onReady?(port)
                if advertise {
                    var label = ""
                    for char in name {
                        guard (label + String(char)).utf8.count <= 42 else { break }
                        label.append(char)
                    }
                    self.advertisement.start(name: "\(label) · \(deviceID.uuidString.prefix(8))", port: port) { [weak self, weak listener] result in
                        guard let self, let listener, self.listener === listener else { return }
                        switch result {
                        case .success: self.onState?("已开放发现与加入，等待跟随端申请")
                        case .failure(let error):
                            self.onState?("自动发现未就绪（\(error.localizedDescription)）；可填写主控 IP 申请加入")
                        }
                    }
                }
            case .failed(let error), .waiting(let error):
                self.onListening?(false)
                self.onState?("加入监听未就绪：\(error.localizedDescription)；检查本地网络权限后重试")
            case .cancelled: self.onListening?(false)
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            let now = ProcessInfo.processInfo.systemUptime
            self.attempts = self.attempts.filter { now - $0 < 60 }
            guard self.sessions.count < 4, self.attempts.count < 20 else { connection.cancel(); return }
            self.attempts.append(now)
            let channel = JoinChannel(connection)
            let session = HostJoin(channel: channel, timeout: timeout)
            self.sessions[session.id] = session
            channel.onPacket = { [weak self, weak session] packet in
                guard let self, let session else { return }
                self.receive(packet, in: session, deviceID: deviceID, name: name)
            }
            channel.onClose = { [weak self] _ in
                self?.sessions.removeValue(forKey: session.id); self?.publishRequests()
            }
            channel.start()
            DispatchQueue.main.asyncAfter(deadline: .now() + min(8, timeout)) { [weak session] in
                if session?.secrets == nil { session?.channel.close("握手超时") }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak session] in
                session?.channel.close("加入申请已过期，请重新申请")
            }
        }
        lifecycle.replace(with: listener)
    }
    public func stop() {
        advertisement.stop(); onListening?(false)
        lifecycle.stop(); listener = nil; groupKey = nil
        let active = Array(sessions.values)
        active.forEach { $0.channel.close("主控已关闭加入服务") }
        sessions.removeAll(); publishRequests()
    }
    public func approve(_ id: UUID) throws {
        guard let session = sessions[id], let host = session.host, let secrets = session.secrets,
              session.client != nil, !session.approved, let groupKey,
              ProcessInfo.processInfo.systemUptime < session.expires else { throw ProtocolError.expired }
        session.approved = true
        let grant = PairingCode(key: groupKey, coordinatorID: host.hello.deviceID)
        let encrypted = try secrets.seal(JoinCrypto.encoded(grant), purpose: "grant")
        session.channel.send(JoinPacket(kind: .grant, session: host.hello.session, blob: encrypted))
        publishRequests()
    }
    public func reject(_ id: UUID) {
        guard let session = sessions[id], let host = session.host else { return }
        session.channel.send(JoinPacket(kind: .reject, session: host.hello.session)) {
            session.channel.close("主控拒绝了申请")
        }
    }
    private func receive(_ packet: JoinPacket, in session: HostJoin, deviceID: UUID, name: String) {
        do {
            guard ProcessInfo.processInfo.systemUptime < session.expires else { throw ProtocolError.expired }
            switch packet.kind {
            case .commit:
                guard session.host == nil, let commitment = packet.blob, commitment.count == 32 else { throw ProtocolError.invalid }
                session.commitment = commitment
                let host = try JoinIdentity(deviceID: deviceID, name: name, session: packet.session)
                session.host = host
                session.channel.send(JoinPacket(kind: .challenge, session: packet.session, hello: host.hello))
            case .reveal:
                guard let host = session.host, host.hello.session == packet.session, session.client == nil,
                      let hello = packet.hello, let commitment = session.commitment else { throw ProtocolError.invalid }
                try JoinCrypto.verify(commitment, hello: hello)
                session.secrets = try JoinSecrets(local: host, client: hello, host: host.hello)
                session.client = hello; publishRequests()
            case .receipt:
                guard session.approved, !session.receivedReceipt, let host = session.host, packet.session == host.hello.session,
                      let client = session.client, let secrets = session.secrets, let blob = packet.blob,
                      try secrets.open(blob, purpose: "receipt") == Data("installed".utf8) else { throw ProtocolError.invalid }
                session.receivedReceipt = true
                guard onJoined?(client, session.channel.remoteHost) ?? true else { throw ProtocolError.invalid }
                let sealed = try secrets.seal(Data("complete".utf8), purpose: "complete")
                session.channel.send(JoinPacket(kind: .complete, session: packet.session, blob: sealed)) {
                    session.channel.close("加入完成")
                }
            default: throw ProtocolError.invalid
            }
        } catch { session.channel.close("加入失败：协议状态或认证不匹配") }
    }
    private func publishRequests() {
        onRequests?(sessions.values.compactMap { session in
            guard let client = session.client, let secrets = session.secrets, !session.approved else { return nil }
            return JoinRequestInfo(id: session.id, name: client.name, deviceID: client.deviceID,
                                   address: session.channel.remoteHost ?? "局域网设备", code: secrets.code)
        }.sorted { $0.name < $1.name })
    }
}

public final class JoinClient {
    public var onChallenge: ((String, String) -> Void)?
    public var provision: ((PairingCode, String, String?) -> Bool)?
    public var completion: ((Result<Void, Error>) -> Void)?
    private var channel: JoinChannel?
    private var identity: JoinIdentity?
    private var host: JoinHello?
    private var secrets: JoinSecrets?
    private var installed = false
    private var finished = false
    private var timeout: DispatchWorkItem?
    public init() {}
    public func start(endpoint: NWEndpoint, deviceID: UUID, name: String, timeout: TimeInterval = 125) throws {
        guard channel == nil, !finished else { throw ProtocolError.invalid }
        let identity = try JoinIdentity(deviceID: deviceID, name: name)
        self.identity = identity
        let channel = JoinChannel(NWConnection(to: endpoint, using: .tcp)); self.channel = channel
        channel.onReady = { [weak self] in
            do {
                let commitment = try JoinCrypto.commitment(identity.hello)
                self?.channel?.send(JoinPacket(kind: .commit, session: identity.hello.session, blob: commitment))
            } catch { self?.finish(.failure(error)) }
        }
        channel.onPacket = { [weak self] packet in self?.receive(packet) }
        channel.onClose = { [weak self] message in
            guard let self else { return }
            self.finish(.failure(LinkError.unavailable(self.installed
                ? "组配置已保存，但未收到主控完成确认；请刷新设备状态验证连接" : message)))
        }
        let work = DispatchWorkItem { [weak self] in self?.finish(.failure(LinkError.unavailable("申请超时，请重新申请并在主控接受"))) }
        self.timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)
        channel.start()
    }
    public func cancel() { finish(.failure(LinkError.unavailable("已取消加入申请"))) }
    private func receive(_ packet: JoinPacket) {
        guard !finished, let identity else { return }
        do {
            guard packet.session == identity.hello.session else { throw ProtocolError.invalid }
            switch packet.kind {
            case .challenge:
                guard host == nil, let host = packet.hello else { throw ProtocolError.invalid }
                let secrets = try JoinSecrets(local: identity, client: identity.hello, host: host)
                self.host = host; self.secrets = secrets
                onChallenge?(host.name, secrets.code)
                channel?.send(JoinPacket(kind: .reveal, session: packet.session, hello: identity.hello))
            case .grant:
                guard !installed, let host, let secrets, let blob = packet.blob else { throw ProtocolError.invalid }
                let plaintext = try secrets.open(blob, purpose: "grant")
                let code = try JSONDecoder().decode(PairingCode.self, from: plaintext)
                guard code.version == 1, code.key.count == 32, code.coordinatorID == host.deviceID else { throw ProtocolError.invalid }
                guard provision?(code, host.name, channel?.remoteHost) == true else {
                    throw LinkError.unavailable("保存组配置失败，未完成加入")
                }
                installed = true
                let sealed = try secrets.seal(Data("installed".utf8), purpose: "receipt")
                channel?.send(JoinPacket(kind: .receipt, session: packet.session, blob: sealed))
            case .complete:
                guard installed, let secrets, let blob = packet.blob,
                      try secrets.open(blob, purpose: "complete") == Data("complete".utf8) else { throw ProtocolError.invalid }
                finish(.success(()))
            case .reject: finish(.failure(LinkError.unavailable("主控拒绝了加入申请")))
            default: throw ProtocolError.invalid
            }
        } catch { finish(.failure(error)) }
    }
    private func finish(_ result: Result<Void, Error>) {
        guard !finished else { return }; finished = true
        timeout?.cancel(); timeout = nil
        let channel = self.channel; self.channel = nil
        channel?.onClose = nil; channel?.close("结束")
        identity = nil; secrets = nil
        let callback = completion; completion = nil; callback?(result)
    }
}
