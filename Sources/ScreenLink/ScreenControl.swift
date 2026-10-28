import AppKit
import ApplicationServices
import Carbon
import IOKit.pwr_mgt
import OSLog
import ScreenLinkCore

enum ScreenControl {
    static var state: ScreenState {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              session[kCGSessionOnConsoleKey as String] as? Bool == true,
              (session[kCGSessionUserIDKey as String] as? NSNumber)?.uint32Value == getuid()
        else { return .unknown }
        if let locked = session["CGSSessionScreenIsLocked"] as? Bool { return locked ? .locked : .unlocked }
        // macOS omits the lock flag for an unlocked console session.
        guard session[kCGSessionLoginDoneKey as String] as? Bool == true else { return .unknown }
        return .unlocked
    }
    static var accessibility: Bool { AXIsProcessTrusted() }
    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
    static func lock(completion: @escaping (String) -> Void) {
        lockOnce { completion($0.note) }
    }
    static func lockOnce(completion: @escaping (LockResult) -> Void) {
        if state == .locked { completion(.locked); return }
        guard accessibility else { completion(.blocked("未锁屏：需要辅助功能权限")); return }
        guard CGPreflightPostEventAccess() else {
            completion(.blocked("未锁屏：系统不允许发送输入事件，请重新授权当前 ScreenLink")); return
        }
        guard state == .unlocked else {
            completion(.retryable("未锁屏：暂时无法确认当前控制台会话")); return
        }
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 12, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 12, keyDown: false) else {
            completion(.blocked("未锁屏：无法创建锁屏输入事件")); return
        }
        down.flags = [.maskControl, .maskCommand]
        up.flags = []
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            completion(state == .locked ? .locked : .retryable("已发送锁屏快捷键，但未确认锁定"))
        }
    }

}

final class IdleDisplayGuard {
    private var assertion: IOPMAssertionID = 0
    var active: Bool { assertion != 0 }
    func set(_ enabled: Bool) {
        if enabled && assertion == 0 {
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn), "ScreenLink: phone nearby" as CFString, &id)
            if result == kIOReturnSuccess { assertion = id }
        } else if !enabled && assertion != 0 {
            IOPMAssertionRelease(assertion); assertion = 0
        }
    }
    deinit { set(false) }
}

final class ExperimentalUnlocker {
    var onProgress: ((String) -> Void)?
    private let logger = Logger(subsystem: "local.screenlink.app", category: "unlock")
    private var attempted = false
    private var busy = false
    private var generation = 0
    func cancel() { generation += 1; busy = false }
    func observedUnlocked() { if !busy { attempted = false } }
    private func trace(_ note: String) {
        logger.notice("\(note, privacy: .public)")
        onProgress?(note)
    }

    func attempt(enabled: Bool, authorized: @escaping () -> Bool = { true },
                 completion: @escaping (String) -> Void) {
        guard enabled else { completion("目标设备未启用实验解锁"); return }
        guard authorized() else { completion("解锁授权已失效"); return }
        guard ScreenControl.state == .locked else { completion("未尝试：目标未明确处于锁屏状态"); return }
        guard !attempted, !busy else { completion("本次锁屏已经尝试过；请在目标 Mac 手动解锁"); return }
        guard ScreenControl.accessibility else { completion("未尝试：需要辅助功能权限"); return }
        guard CGPreflightPostEventAccess() else {
            completion("未输入密码：系统不允许发送输入事件，请在辅助功能中重新授权当前 ScreenLink"); return
        }
        // No retries: a changed/incorrect password must never trigger account lockout.
        attempted = true; busy = true
        let generation = self.generation
        var assertion: IOPMAssertionID = 0
        var finished = false
        let finish: (String) -> Void = { [weak self] note in
            guard !finished else { return }
            finished = true
            if assertion != 0 { IOPMAssertionRelease(assertion); assertion = 0 }
            if self?.generation == generation {
                self?.busy = false
                if ScreenControl.state == .unlocked { self?.attempted = false }
            }
            self?.logger.notice("\(note, privacy: .public)")
            completion(note)
        }
        let wakeResult = IOPMAssertionDeclareUserActivity(
            "ScreenLink unlock request" as CFString, kIOPMUserActiveLocal, &assertion)
        guard wakeResult == kIOReturnSuccess else {
            finish("未输入密码：唤醒屏幕失败（\(wakeResult)），请在目标 Mac 手动唤醒")
            return
        }
        trace("唤醒请求已发送，等待输入条件")
        // Wake through the power API only. Escape at the login window can put
        // the display back to sleep; it is not a safe generic screensaver dismissal.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { finish("解锁请求已取消"); return }
            guard self.generation == generation else { finish("解锁请求已取消"); return }
            guard authorized() else { finish("未输入密码：解锁授权已失效"); return }
            guard ScreenControl.state == .locked, IsSecureEventInputEnabled() else {
                finish("未输入密码：锁屏或安全输入状态无法确认"); return
            }
            do {
                guard let data = try Vault.read("login-password"),
                      let password = String(data: data, encoding: .utf8), !password.isEmpty else {
                    finish("未输入密码：本机未保存登录密码"); return
                }
                self.trace("已读取本机凭据，准备发送输入事件")
                PasswordEventSender.send(password, allowed: {
                    self.generation == generation && authorized()
                        && ScreenControl.state == .locked && IsSecureEventInputEnabled()
                }, progress: { phase in
                    switch phase {
                    case .selected: self.trace("已发送全选事件，已清除后续按键的修饰标志")
                    case .textPosted: self.trace("已发送逐字符输入事件（尚未确认系统接收）")
                    case .submitted: self.trace("已发送一次回车，等待实际锁屏状态")
                    }
                }, completion: { result in
                    switch result {
                    case .failure(let error):
                        if case PasswordTypingError.authorizationChanged = error {
                            finish("已中止：输入条件或授权变化；未继续提交")
                        } else {
                            finish("未提交密码：无法构建完整输入事件")
                        }
                    case .success:
                        let deadline = ProcessInfo.processInfo.systemUptime + 3
                        func observeResult() {
                            guard self.generation == generation else { finish("解锁请求已取消"); return }
                            if ScreenControl.state == .unlocked { finish("已解锁"); return }
                            guard ProcessInfo.processInfo.systemUptime < deadline else {
                                finish("已发送输入及回车，但未确认解锁；不会自动重试，请手动登录"); return
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: observeResult)
                        }
                        observeResult()
                    }
                })
            } catch {
                let error = error as NSError
                finish("读取本机钥匙串失败（\(error.domain)，\(error.code)）")
            }
        }
    }
}
