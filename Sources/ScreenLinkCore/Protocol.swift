import Foundation
import CryptoKit

public enum ScreenState: String, Codable { case locked, unlocked, unknown }
public enum Command: String, Codable { case status, lock, unlock, presence, reply }

public struct Message: Codable {
    public var version = 1
    public var id: UUID
    public var sender: UUID
    public var command: Command
    public var sentAt: TimeInterval
    public var responseTo: UUID?
    public var state: ScreenState?
    public var note: String?
    public init(sender: UUID, command: Command, now: TimeInterval = Date().timeIntervalSince1970,
                responseTo: UUID? = nil, state: ScreenState? = nil, note: String? = nil) {
        self.id = UUID(); self.sender = sender; self.command = command; self.sentAt = now
        self.responseTo = responseTo; self.state = state; self.note = note
    }
}

public enum ProtocolError: Error, LocalizedError {
    case invalid, authentication, expired, replay, oversized, wrongReply
    public var errorDescription: String? {
        switch self {
        case .invalid: return "无效协议消息"
        case .authentication: return "组密钥不匹配或消息认证失败"
        case .expired: return "消息过期；请检查两台 Mac 的系统时间"
        case .replay: return "重复消息已拒绝"
        case .oversized: return "消息超过大小限制"
        case .wrongReply: return "回复与请求不匹配"
        }
    }
}

public struct Envelope: Codable {
    var payload: Data
    var mac: Data
}

public enum Wire {
    public static let limit = 8192
    public static func encode(_ message: Message, key: Data) throws -> Data {
        guard key.count == 32 else { throw ProtocolError.authentication }
        let payload = try JSONEncoder().encode(message)
        let mac = Data(HMAC<SHA256>.authenticationCode(for: payload, using: SymmetricKey(data: key)))
        let data = try JSONEncoder().encode(Envelope(payload: payload, mac: mac))
        guard data.count <= limit else { throw ProtocolError.oversized }
        return data
    }
    public static func decode(_ data: Data, key: Data, now: TimeInterval = Date().timeIntervalSince1970) throws -> Message {
        guard data.count <= limit else { throw ProtocolError.oversized }
        guard key.count == 32 else { throw ProtocolError.authentication }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard HMAC<SHA256>.isValidAuthenticationCode(envelope.mac, authenticating: envelope.payload,
                                                    using: SymmetricKey(data: key)) else { throw ProtocolError.authentication }
        let message = try JSONDecoder().decode(Message.self, from: envelope.payload)
        guard message.version == 1, message.sentAt.isFinite,
              (message.note?.utf8.count ?? 0) <= 1024 else { throw ProtocolError.invalid }
        guard abs(now - message.sentAt) <= 15 else { throw ProtocolError.expired }
        return message
    }
    public static func validateReply(_ reply: Message, to request: Message) throws {
        guard reply.command == .reply, reply.responseTo == request.id, reply.sender != request.sender else {
            throw ProtocolError.wrongReply
        }
    }
}

// Main-queue confined alongside the network server. Expiration is monotonic.
public final class ReplayGuard {
    private var seen: [UUID: TimeInterval] = [:]
    public init() {}
    public func accept(_ message: Message, uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) throws {
        seen = seen.filter { $0.value > uptime }
        guard seen[message.id] == nil else { throw ProtocolError.replay }
        guard seen.count < 4096 else { throw ProtocolError.oversized }
        seen[message.id] = uptime + 35
    }
}

public struct FrameBuffer {
    private var bytes = Data()
    public init() {}
    public mutating func append(_ data: Data) throws -> Data? {
        bytes.append(data)
        guard bytes.count <= Wire.limit + 1 else { throw ProtocolError.oversized }
        guard let end = bytes.firstIndex(of: 10) else { return nil }
        guard end == bytes.index(before: bytes.endIndex) else { throw ProtocolError.invalid }
        return Data(bytes[..<end])
    }
}

public struct Peer: Codable, Identifiable, Equatable {
    public var id = UUID()
    public var name: String
    public var host: String
    public var port: UInt16 = 45731
    public init(name: String, host: String) { self.name = name; self.host = host }
}

public struct Settings: Codable {
    public var deviceID = UUID()
    public var deviceName = Host.current().localizedName ?? "Mac"
    public var isCoordinator = false
    public var coordinatorID: UUID?
    public var networkEnabled = false
    public var joinEnabled: Bool?
    public var allowsJoining: Bool { isCoordinator && networkEnabled && (joinEnabled ?? true) }
    public var autoLock = false
    // Optional fields preserve decoding of previously installed versions.
    public var unlockOnPhoneConnection: Bool?
    public var phoneUnlockEnabled: Bool { unlockOnPhoneConnection ?? false }
    public var lockRSSIThreshold: Int?
    public var relayManualLock = false
    public var keepAwake = false
    public var allowRemoteUnlock = false
    public var passiveBLE = false
    public var phoneID: UUID?
    public var phoneName = ""
    public var signalTimeout: Double = 30
    public var peers: [Peer] = []
    public init() {}
    public func acceptsPresenceSignal(_ rssi: Int) -> Bool {
        guard (-110 ... -1).contains(rssi) else { return false }
        return lockRSSIThreshold.map { rssi >= $0 } ?? true
    }
    public func acceptsUnlockSignal(_ rssi: Int) -> Bool {
        guard (-110 ... -1).contains(rssi) else { return false }
        return lockRSSIThreshold.map { rssi >= $0 + 5 } ?? true
    }
    public func validate() throws {
        guard signalTimeout.isFinite, (10...180).contains(signalTimeout),
              !deviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              deviceName.count <= 80, peers.count <= 16 else { throw ProtocolError.invalid }
        if let threshold = lockRSSIThreshold, !(-100 ... -40).contains(threshold) { throw ProtocolError.invalid }
        guard !deviceName.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw ProtocolError.invalid }
        for peer in peers {
            guard !peer.host.isEmpty, peer.host.count <= 253, peer.port > 0,
                  peer.host.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:%_").contains($0) }) else {
                throw ProtocolError.invalid
            }
        }
    }
}
