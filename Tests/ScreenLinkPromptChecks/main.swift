import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
var failures = 0

func buttons(in view: NSView) -> [NSButton] {
    (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { buttons(in: $0) }
}

func exercise(_ name: String, expected: Bool, cancel: String? = "取消",
              action: @escaping (NSWindow) -> Void) {
    var acted = false
    var timedOut = false
    let actionTimer = Timer(timeInterval: 0.1, repeats: false) { _ in
        guard let window = app.modalWindow else { return }
        acted = true
        action(window)
    }
    let timeout = Timer(timeInterval: 3, repeats: false) { _ in
        timedOut = true
        app.abortModal()
    }
    RunLoop.main.add(actionTimer, forMode: .modalPanel)
    RunLoop.main.add(timeout, forMode: .modalPanel)
    let result = NativePrompt.show("申请加入这个主控的组？",
        detail: "主控接受后，本机将成为跟随端并替换当前组配置；实验远程解锁会关闭，需在本机重新启用。",
        confirm: "申请加入", cancel: cancel)
    actionTimer.invalidate(); timeout.invalidate()
    if result != expected || !acted || timedOut || app.modalWindow != nil {
        failures += 1
        print("FAIL: \(name), result=\(result), acted=\(acted), timeout=\(timedOut)")
    } else { print("PASS: \(name)") }
}

exercise("Explicit confirm authorizes", expected: true) { window in
    buttons(in: window.contentView!).first { $0.title == "申请加入" }?.performClick(nil)
}
exercise("Cancel does not authorize", expected: false) { window in
    buttons(in: window.contentView!).first { $0.title == "取消" }?.performClick(nil)
}
exercise("Window close does not authorize", expected: false) { window in window.performClose(nil) }
exercise("Escape does not authorize", expected: false) { window in
    let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
        charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
    _ = window.performKeyEquivalent(with: event)
}
exercise("Modal abort does not authorize", expected: false) { _ in app.abortModal() }
exercise("Single-button information prompt dismisses", expected: true, cancel: nil) { window in
    buttons(in: window.contentView!).first?.performClick(nil)
}
func secureFields(in view: NSView) -> [NSSecureTextField] {
    (view as? NSSecureTextField).map { [$0] } ?? view.subviews.flatMap { secureFields(in: $0) }
}
func exercisePassword(_ name: String, value: String, expected: String?,
                      action: @escaping (NSWindow) -> Void) {
    var acted = false
    var timedOut = false
    weak var observedField: NSSecureTextField?
    let timer = Timer(timeInterval: 0.1, repeats: false) { _ in
        guard let window = app.modalWindow,
              let field = secureFields(in: window.contentView!).first else { return }
        observedField = field
        window.makeFirstResponder(field)
        guard let editor = field.currentEditor() as? NSTextView else { return }
        editor.insertText(value, replacementRange: editor.selectedRange())
        // Submit while the editor still has focus, without a separate blur.
        acted = true; action(window)
    }
    let timeout = Timer(timeInterval: 3, repeats: false) { _ in
        timedOut = true; app.abortModal()
    }
    RunLoop.main.add(timer, forMode: .modalPanel)
    RunLoop.main.add(timeout, forMode: .modalPanel)
    let result = NativePrompt.requestPassword(for: "synthetic-account")
    timer.invalidate(); timeout.invalidate()
    let matches = result.map { Array($0.utf8) } == expected.map { Array($0.utf8) }
    let cleared = observedField?.stringValue.isEmpty ?? true
    if !matches || !acted || timedOut || app.modalWindow != nil || !cleared {
        failures += 1; print("FAIL: \(name), matched=\(matches), acted=\(acted), timeout=\(timedOut), cleared=\(cleared)")
    } else { print("PASS: \(name)") }
}
let confirmPassword: (NSWindow) -> Void = { window in
    buttons(in: window.contentView!).first { $0.title == "验证并保存" }?.performClick(nil)
}
for (name, value) in [
    ("Native input submits current editor including final character", "Fixture-42!@$"),
    ("Native input preserves spaces and Unicode bytes", "  fixture 空格 é 🔐  "),
    ("Native input preserves decomposed Unicode", "e\u{301}xample"),
    ("Native input leaves empty validation to caller", "")
] {
    exercisePassword(name, value: value, expected: value, action: confirmPassword)
}
exercisePassword("Password cancel discards typed value", value: "fixture", expected: nil) { window in
    buttons(in: window.contentView!).first { $0.title == "取消" }?.performClick(nil)
}
exercisePassword("Password window close discards typed value", value: "fixture", expected: nil) { $0.performClose(nil) }
exercisePassword("Password modal abort discards typed value", value: "fixture", expected: nil) { _ in app.abortModal() }
for (name, key, code, expected) in [("Escape", "\u{1b}", UInt16(53), nil as String?),
                                    ("Return", "\r", UInt16(36), "fixture" as String?)] {
    exercisePassword("Password \(name) key", value: "fixture", expected: expected) { window in
        if name == "Return" {
            (window.firstResponder as? NSTextView)?.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            return
        }
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: key,
            charactersIgnoringModifiers: key, isARepeat: false, keyCode: code)!
        _ = window.performKeyEquivalent(with: event)
    }
}
print("15 prompt checks, \(failures) failures")
exit(failures == 0 ? 0 : 1)
