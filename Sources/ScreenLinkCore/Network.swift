import Foundation
import Network
import OSLog

public enum LinkError: Error, LocalizedError {
    case timeout, closed, disabled, unavailable(String)
    public var errorDescription: String? {
        switch self {
        case .timeout: return "连接超时，设备可能离线或休眠"
        case .closed: return "连接已关闭"
        case .disabled: return "网络接收未启用或没有组密钥"
        case .unavailable(let detail): return detail
        }
    }
}

// Every method/callback runs on the main queue; maximum one frame per connection.
public final class LinkServer {
    public var onState: ((String) -> Void)?
    public var onRejected: ((String) -> Void)?
    private let logger = Logger(subsystem: "local.screenlink.app", category: "control")
    public var onReady: ((UInt16) -> Void)?
    public var handler: ((Message, @escaping (Message) -> Void) -> Void)?
    private var listener: NWListener?
    private let lifecycle = ListenerLifecycle()
    private var connections: [UUID: NWConnection] = [:]
    private let replay = ReplayGuard()
    public init() {}

    public func start(key: Data, deviceID: UUID, port: UInt16 = 45731, advertise: Bool = true) throws {
        stop()
        guard key.count == 32 else { throw ProtocolError.authentication }
        let parameters = NWParameters.tcp
        // Reconfiguration can overlap asynchronous cancellation and connections in
        // TIME_WAIT. Permit rebinding our fixed endpoint after stopping the listener.
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: port == 0 ? .any : NWEndpoint.Port(rawValue: port)!)
        self.listener = listener
        if advertise { listener.service = .init(name: deviceID.uuidString, type: "_screenlink._tcp") }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            switch state {
            case .ready:
                self?.onState?("接收已开启 · TCP \(listener?.port?.rawValue ?? 0)")
                if let port = listener?.port?.rawValue { self?.onReady?(port) }
            case .failed(let error): self?.onState?("接收失败：\(error.localizedDescription)")
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self, self.connections.count < 32 else { connection.cancel(); return }
            let id = UUID()
            self.connections[id] = connection
            connection.start(queue: .main)
            self.read(connection, id: id, buffer: FrameBuffer(), key: key, deviceID: deviceID)
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.close(id) }
        }
        lifecycle.replace(with: listener)
    }

    public func stop() {
        lifecycle.stop(); listener = nil
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
    }
    private func close(_ id: UUID) {
        connections.removeValue(forKey: id)?.cancel()
    }
    private func read(_ connection: NWConnection, id: UUID, buffer: FrameBuffer, key: Data, deviceID: UUID) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Wire.limit + 1) { [weak self] data, _, done, error in
            guard let self, self.connections[id] != nil else { return }
            var buffer = buffer
            do {
                if let data, let frame = try buffer.append(data) {
                    let message = try Wire.decode(frame, key: key)
                    guard message.sender != deviceID, message.command != .reply, message.responseTo == nil else {
                        throw ProtocolError.invalid
                    }
                    try self.replay.accept(message)
                    guard let handler = self.handler else { throw LinkError.disabled }
                    handler(message) { [weak self, weak connection] reply in
                        guard let self, self.connections[id] != nil, let connection else { return }
                        do {
                            var encoded = try Wire.encode(reply, key: key)
                            encoded.append(10)
                            connection.send(content: encoded, completion: .contentProcessed { [weak self] _ in self?.close(id) })
                        } catch { self.close(id) }
                    }
                    return
                }
                if done || error != nil { self.close(id); return }
                self.read(connection, id: id, buffer: buffer, key: key, deviceID: deviceID)
            } catch {
                let reason = error.localizedDescription
                self.logger.error("Control request rejected: \(reason, privacy: .public)")
                self.onRejected?(reason)
                self.close(id)
            }
        }
    }
}

public final class LinkRequest {
    private var connection: NWConnection?
    private var completion: ((Result<Message, Error>) -> Void)?
    private var buffer = FrameBuffer()
    private let request: Message
    private let key: Data
    private var timeout: DispatchWorkItem?

    public init(endpoint: NWEndpoint, message: Message, key: Data,
                completion: @escaping (Result<Message, Error>) -> Void) {
        self.request = message; self.key = key; self.completion = completion
        let connection = NWConnection(to: endpoint, using: .tcp)
        self.connection = connection
        connection.stateUpdateHandler = { [self] state in
            switch state {
            case .ready: send()
            case .failed(let error): finish(.failure(error))
            case .cancelled: finish(.failure(LinkError.closed))
            default: break
            }
        }
        let timeout = DispatchWorkItem { [self] in finish(.failure(LinkError.timeout)) }
        self.timeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: timeout)
        connection.start(queue: .main)
    }

    private func send() {
        do {
            var bytes = try Wire.encode(request, key: key); bytes.append(10)
            connection?.send(content: bytes, completion: .contentProcessed { [self] error in
                if let error { finish(.failure(error)) } else { read() }
            })
        } catch { finish(.failure(error)) }
    }
    private func read() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: Wire.limit + 1) { [self] data, _, done, error in
            guard completion != nil else { return }
            do {
                if let data, let frame = try buffer.append(data) {
                    let reply = try Wire.decode(frame, key: key)
                    try Wire.validateReply(reply, to: request)
                    finish(.success(reply)); return
                }
                if let error { finish(.failure(error)); return }
                if done { finish(.failure(LinkError.closed)); return }
                read()
            } catch { finish(.failure(error)) }
        }
    }
    private func finish(_ result: Result<Message, Error>) {
        guard let callback = completion else { return }
        completion = nil
        timeout?.cancel(); timeout = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel(); connection = nil
        callback(result)
    }
}
