import Foundation
import CryptoKit

public enum SharingError: Error, LocalizedError {
    case invalid, authentication, limit, denied, cancelled, timeout, filesystem
    public var errorDescription: String? {
        switch self {
        case .invalid: return "共享数据格式无效"
        case .authentication: return "共享设备认证失败"
        case .limit: return "共享大小或并发数量超过限制"
        case .denied: return "对方未允许接收或当前已锁屏"
        case .cancelled: return "共享已取消"
        case .timeout: return "共享连接超时"
        case .filesystem: return "无法安全读取或保存文件"
        }
    }
}

private struct SharingHello: Codable {
    var version = 1
    var device: UUID
    var target: UUID
    var publicKey: Data
    var nonce: Data
    var requestHash: Data
    var proof: Data
    func unsigned() throws -> Data {
        var copy = self; copy.proof = Data()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(copy)
    }
    func encoded() throws -> Data { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(self) }
    func verify(key: SymmetricKey) throws {
        guard version == 1, device != target, publicKey.count == 32, nonce.count == 32,
              requestHash.isEmpty || requestHash.count == 32,
              HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: Data("ScreenLink sharing handshake v1".utf8) + (try unsigned()), using: key)
        else { throw SharingError.authentication }
    }
}

/// Fresh ephemeral key agreement authenticated with the existing paired-group authority.
/// Possession of a group key grants group authority; device UUIDs are not hardware attestations.
public struct SharingHandshake {
    public let deviceID: UUID
    public let target: UUID
    private let key: SymmetricKey
    private let privateKey = Curve25519.KeyAgreement.PrivateKey()
    private let nonce = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    public init(deviceID: UUID, target: UUID, groupKey: Data) {
        self.deviceID = deviceID; self.target = target; key = SymmetricKey(data: groupKey)
    }
    private func hello(hash: Data) throws -> SharingHello {
        var hello = SharingHello(device: deviceID, target: target, publicKey: privateKey.publicKey.rawRepresentation, nonce: nonce, requestHash: hash, proof: Data())
        hello.proof = Data(HMAC<SHA256>.authenticationCode(for: Data("ScreenLink sharing handshake v1".utf8) + (try hello.unsigned()), using: key))
        return hello
    }
    public func request() throws -> Data { try hello(hash: Data()).encoded() }
    /// Used to route the authenticated request before allocating a receiving transfer.
    public static func requester(_ data: Data, groupKey: Data, target: UUID) throws -> UUID {
        guard data.count <= 2048 else { throw SharingError.limit }
        let hello = try JSONDecoder().decode(SharingHello.self, from: data)
        try hello.verify(key: SymmetricKey(data: groupKey))
        guard hello.target == target, hello.requestHash.isEmpty else { throw SharingError.authentication }
        return hello.device
    }
    // Canonical authenticated fields, rather than JSON formatting, identify a hello replay.
    static func requestFingerprint(_ data: Data) throws -> Data {
        let hello = try JSONDecoder().decode(SharingHello.self, from: data)
        return Data(SHA256.hash(data: try hello.unsigned()))
    }
    public func respond(to request: Data) throws -> Data {
        let peer = try Self.requester(request, groupKey: key.withUnsafeBytes { Data($0) }, target: deviceID)
        guard peer == target else { throw SharingError.authentication }
        return try hello(hash: Data(SHA256.hash(data: request))).encoded()
    }
    public func finish(response: Data) throws -> SharingCipher {
        try derive(request: request(), response: response, initiator: true)
    }
    public func accept(request: Data, response: Data) throws -> SharingCipher {
        try derive(request: request, response: response, initiator: false)
    }
    private func derive(request: Data, response: Data, initiator: Bool) throws -> SharingCipher {
        guard request.count <= 2048, response.count <= 2048 else { throw SharingError.limit }
        let a = try JSONDecoder().decode(SharingHello.self, from: request)
        let b = try JSONDecoder().decode(SharingHello.self, from: response)
        try a.verify(key: key); try b.verify(key: key)
        guard a.requestHash.isEmpty, b.requestHash == Data(SHA256.hash(data: request)), a.target == b.device, b.target == a.device else { throw SharingError.authentication }
        let own = initiator ? a : b, remote = initiator ? b : a
        guard own.device == deviceID, remote.device == target, own.publicKey == privateKey.publicKey.rawRepresentation, own.nonce == nonce else { throw SharingError.authentication }
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: remote.publicKey))
        let transcript = Data(SHA256.hash(data: request + response))
        let forward = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: transcript, sharedInfo: Data("ScreenLink sharing v1 client to server".utf8), outputByteCount: 32)
        let backward = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: transcript, sharedInfo: Data("ScreenLink sharing v1 server to client".utf8), outputByteCount: 32)
        return SharingCipher(sendKey: initiator ? forward : backward, receiveKey: initiator ? backward : forward, transcript: transcript)
    }
}

/// Exact, directional sequence numbers bind frames to one authenticated ephemeral session.
public struct SharingCipher {
    private let sendKey: SymmetricKey, receiveKey: SymmetricKey
    private let transcript: Data
    private var sent: UInt64 = 0, received: UInt64 = 0
    fileprivate init(sendKey: SymmetricKey, receiveKey: SymmetricKey, transcript: Data) {
        self.sendKey = sendKey; self.receiveKey = receiveKey; self.transcript = transcript
    }
    private func number(_ value: UInt64) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
    public mutating func seal(_ bytes: Data) throws -> Data {
        guard bytes.count <= 96 * 1024, sent < UInt64.max else { throw SharingError.limit }
        let sequence = number(sent)
        let nonce = try AES.GCM.Nonce(data: Data(repeating: 0, count: 4) + sequence)
        let box = try AES.GCM.seal(bytes, using: sendKey, nonce: nonce, authenticating: transcript + sequence)
        sent += 1
        return sequence + box.ciphertext + box.tag
    }
    public mutating func open(_ bytes: Data) throws -> Data {
        guard bytes.count >= 24, bytes.count <= 96 * 1024 + 24, received < UInt64.max,
              bytes.prefix(8) == number(received) else { throw SharingError.authentication }
        let sequence = Data(bytes.prefix(8))
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: Data(repeating: 0, count: 4) + sequence), ciphertext: bytes.dropFirst(8).dropLast(16), tag: bytes.suffix(16))
        let clear = try AES.GCM.open(box, using: receiveKey, authenticating: transcript + sequence)
        received += 1
        return clear
    }
}
