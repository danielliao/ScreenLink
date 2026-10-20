import Foundation
import CryptoKit

public struct JoinHello: Codable {
    public var session: UUID
    public var deviceID: UUID
    public var name: String
    public var publicKey: Data
    public var nonce: Data
    public func validate() throws {
        guard !name.isEmpty, name.count <= 80, !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              publicKey.count == 32, nonce.count == 32 else { throw ProtocolError.invalid }
    }
}

public struct JoinIdentity {
    let privateKey: Curve25519.KeyAgreement.PrivateKey
    public let hello: JoinHello
    public init(deviceID: UUID, name: String, session: UUID = UUID()) throws {
        privateKey = Curve25519.KeyAgreement.PrivateKey()
        hello = JoinHello(session: session, deviceID: deviceID, name: name,
                          publicKey: privateKey.publicKey.rawRepresentation,
                          nonce: SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
        try hello.validate()
    }
}

public enum JoinCrypto {
    public static func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    public static func commitment(_ hello: JoinHello) throws -> Data {
        try hello.validate()
        return Data(SHA256.hash(data: try encoded(hello)))
    }
    public static func verify(_ commitment: Data, hello: JoinHello) throws {
        guard commitment.count == 32, commitment == (try self.commitment(hello)) else { throw ProtocolError.authentication }
    }
}

public struct JoinSecrets {
    private let key: SymmetricKey
    private let transcript: Data
    public let code: String
    public init(local: JoinIdentity, client: JoinHello, host: JoinHello) throws {
        try client.validate(); try host.validate()
        guard client.session == host.session, client.deviceID != host.deviceID else { throw ProtocolError.invalid }
        let own = local.hello.deviceID == client.deviceID ? client : host
        guard try JoinCrypto.encoded(own) == JoinCrypto.encoded(local.hello) else { throw ProtocolError.invalid }
        let remote = local.hello.deviceID == client.deviceID ? host : client
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: remote.publicKey)
        let shared = try local.privateKey.sharedSecretFromKeyAgreement(with: peer)
        transcript = Data(SHA256.hash(data: try JoinCrypto.encoded(["client": client, "host": host])))
        key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: transcript,
            sharedInfo: Data("ScreenLink join v1 transport".utf8), outputByteCount: 32)
        let digitsKey = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: transcript,
            sharedInfo: Data("ScreenLink join v1 comparison".utf8), outputByteCount: 32)
        let bytes = Array(HMAC<SHA256>.authenticationCode(for: transcript, using: digitsKey))
        let number = bytes.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        code = String(format: "%06u", number % 1_000_000)
    }
    public func seal(_ data: Data, purpose: String) throws -> Data {
        guard let result = try AES.GCM.seal(data, using: key,
            authenticating: transcript + Data(purpose.utf8)).combined else { throw ProtocolError.invalid }
        return result
    }
    public func open(_ data: Data, purpose: String) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key,
                         authenticating: transcript + Data(purpose.utf8))
    }
}

public struct JoinFrames {
    private var bytes = Data()
    public init() {}
    public mutating func append(_ input: Data) throws -> [Data] {
        guard bytes.count + input.count <= Wire.limit * 2 else { throw ProtocolError.oversized }
        bytes.append(input)
        var frames: [Data] = []
        while let end = bytes.firstIndex(of: 10) {
            guard end <= Wire.limit else { throw ProtocolError.oversized }
            frames.append(Data(bytes[..<end])); bytes = Data(bytes.dropFirst(end + 1))
        }
        guard bytes.count <= Wire.limit else { throw ProtocolError.oversized }
        return frames
    }
}
