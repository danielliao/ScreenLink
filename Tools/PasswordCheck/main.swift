import Foundation
import Darwin

// Diagnostic only: exactly the application's verifier, without SwiftUI, settings,
// Keychain, Bluetooth or network. Credentials are accepted only from a real TTY.
guard CommandLine.arguments.count == 1 else {
    print("在终端直接运行，不附加密码或其他参数。仅验证一次，不保存密码。")
    exit(2)
}
func checkOnce() -> Int32 {
    guard isatty(STDIN_FILENO) == 1 else {
        print("未执行认证：必须在本机交互式终端中隐藏输入密码。")
        return 2
    }
    print("验证账户：\(NSUserName())；节点：\(LocalPasswordVerifier.nodeName)")
    var buffer = [CChar](repeating: 0, count: 4096)
    defer {
        buffer.withUnsafeMutableBytes { bytes in
            if let pointer = bytes.baseAddress { _ = memset_s(pointer, bytes.count, 0, bytes.count) }
        }
    }
    let read = buffer.withUnsafeMutableBufferPointer {
        readpassphrase("本机登录密码（隐藏输入，仅验证一次）：", $0.baseAddress, $0.count, RPP_REQUIRE_TTY)
    }
    guard read != nil, let password = String(validatingCString: buffer), !password.isEmpty,
          password.utf16.count <= 256 else {
        print("未执行认证：输入取消、为空、编码无效或过长。")
        return 2
    }
    do {
        try LocalPasswordVerifier.verify(password)
        print("验证成功：应用同一段 OpenDirectory 代码通过。未保存密码。")
        return 0
    } catch {
        let error = error as NSError
        print("验证失败：\(error.domain)，\(error.code)。未保存密码，不会重试。")
        return 1
    }
}
exit(checkOnce())
