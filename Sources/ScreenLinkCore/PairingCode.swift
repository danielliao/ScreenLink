import Foundation

public enum PairingError: Error, LocalizedError {
    case empty, malformed
    public var errorDescription: String? {
        switch self {
        case .empty: return "请先在主控 Mac 创建组并复制配对码，再在这台 Mac 点击“从剪贴板粘贴”。自动发现不会自动填写配对码。"
        case .malformed: return "配对码格式不正确或版本不兼容，请从主控 Mac 重新复制完整配对码。"
        }
    }
}

public struct PairingCode: Codable {
    public var version = 1
    public var key: Data
    public var coordinatorID: UUID
    public init(key: Data, coordinatorID: UUID) { self.key = key; self.coordinatorID = coordinatorID }
    public static func parse(_ text: String) throws -> PairingCode {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PairingError.empty }
        guard trimmed.utf8.count < 2048, let data = Data(base64Encoded: trimmed),
              let code = try? JSONDecoder().decode(PairingCode.self, from: data),
              code.version == 1, code.key.count == 32 else { throw PairingError.malformed }
        return code
    }
}
