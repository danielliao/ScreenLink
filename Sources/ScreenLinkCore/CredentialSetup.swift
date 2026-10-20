import Foundation

public struct CredentialSetupFailure: Error, LocalizedError {
    public enum Stage { case verification, keychain }
    public let stage: Stage
    public let domain: String
    public let code: Int

    init(stage: Stage, error: Error) {
        let error = error as NSError
        self.stage = stage; domain = error.domain; code = error.code
        // Do not retain the underlying error or its userInfo: diagnostics must
        // never include credentials or arbitrary account-provider messages.
    }
    public var errorDescription: String? {
        let identifier = "（\(domain)，\(code)）"
        switch stage {
        case .verification:
            return "系统目录未通过本机账户认证\(identifier)。未写入钥匙串。若同一密码可以手动解锁，请停止重复尝试，并检查目录认证或应用输入路径。"
        case .keychain:
            return "本机密码验证已通过，但钥匙串保存失败\(identifier)。请在本机处理钥匙串授权提示；若已取消授权，请重新保存。"
        }
    }
}

public enum CredentialSetup {
    public static func perform(verify: () throws -> Void, store: () throws -> Void) throws {
        do { try verify() }
        catch { throw CredentialSetupFailure(stage: .verification, error: error) }
        do { try store() }
        catch { throw CredentialSetupFailure(stage: .keychain, error: error) }
    }
}
