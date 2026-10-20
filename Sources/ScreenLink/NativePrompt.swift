import AppKit

// NSAlert.init loads an icon-bearing nib. On the affected macOS 15.0.1 host
// that crashes in IconServices/ImageIO before an icon can be replaced.
// Build the entire prompt in code, without NSAlert or image resources.
final class NativePrompt: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private var resolved = false
    private var passwordField: NSSecureTextField?

    private init(title: String, detail: String, confirm: String, cancel: String?, password: Bool = false) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 200),
                        styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        panel.title = "ScreenLink"
        panel.isReleasedWhenClosed = false
        panel.delegate = self

        let heading = NSTextField(wrappingLabelWithString: title)
        heading.font = .boldSystemFont(ofSize: 15)
        let body = NSTextField(wrappingLabelWithString: detail)
        body.font = .systemFont(ofSize: 13)
        body.isSelectable = true
        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 12
        if let cancel {
            let button = NSButton(title: cancel, target: self, action: #selector(cancelAction))
            button.bezelStyle = .rounded
            button.keyEquivalent = "\u{1b}"
            buttons.addArrangedSubview(button)
        }
        let accept = NSButton(title: confirm, target: self, action: #selector(confirmAction))
        accept.bezelStyle = .rounded
        accept.keyEquivalent = "\r"
        buttons.addArrangedSubview(accept)
        panel.defaultButtonCell = accept.cell as? NSButtonCell

        let stack = NSStackView(views: [heading, body, buttons])
        if password {
            let field = NSSecureTextField(frame: .zero)
            field.placeholderString = "本机当前登录密码"
            field.setAccessibilityLabel("本机当前登录密码")
            field.font = .systemFont(ofSize: 14)
            field.bezelStyle = .roundedBezel
            field.isEditable = true
            field.isSelectable = true
            field.target = self
            field.action = #selector(confirmAction)
            field.cell?.wraps = false
            field.cell?.isScrollable = true
            passwordField = field
            stack.insertArrangedSubview(field, at: 2)
            field.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            panel.initialFirstResponder = field
        }
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = panel.contentView!
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24),
            heading.widthAnchor.constraint(equalTo: stack.widthAnchor),
            body.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.trailingAnchor.constraint(equalTo: stack.trailingAnchor)
        ])
        content.layoutSubtreeIfNeeded()
        panel.setContentSize(NSSize(width: 480, height: max(180, stack.fittingSize.height + 48)))
    }

    @discardableResult
    static func show(_ title: String, detail: String, confirm: String = "好", cancel: String? = nil) -> Bool {
        precondition(Thread.isMainThread)
        let prompt = NativePrompt(title: title, detail: detail, confirm: confirm, cancel: cancel)
        prompt.panel.center()
        NSApp.activate(ignoringOtherApps: true)
        defer { prompt.panel.orderOut(nil) }
        // Close/Escape/abort never authorize the operation. Only the confirm
        // button returns .OK; callers retain their existing synchronous guards.
        return NSApp.runModal(for: prompt.panel) == .OK
    }

    static func requestPassword(for account: String) -> String? {
        precondition(Thread.isMainThread)
        let prompt = NativePrompt(title: "保存这台 Mac 的登录密码",
            detail: "本机账户：\(account)\n请在此安全输入框输入当前登录密码。只有本机账户验证通过后才写入本机钥匙串，不会发送给其他设备。",
            confirm: "验证并保存", cancel: "取消", password: true)
        prompt.panel.center()
        NSApp.activate(ignoringOtherApps: true)
        defer {
            prompt.passwordField?.currentEditor()?.string = ""
            prompt.panel.makeFirstResponder(nil)
            prompt.passwordField?.stringValue = ""
            prompt.panel.orderOut(nil)
        }
        guard NSApp.runModal(for: prompt.panel) == .OK else { return nil }
        // Read directly from the committed native control, never a SwiftUI
        // view-state snapshot. Preserve every byte, including spaces.
        return prompt.passwordField?.stringValue
    }

    @objc private func confirmAction() {
        if let passwordField {
            passwordField.validateEditing()
            guard panel.makeFirstResponder(nil) else { return }
        }
        finish(.OK)
    }
    @objc private func cancelAction() { finish(.cancel) }
    private func finish(_ response: NSApplication.ModalResponse) {
        guard !resolved else { return }
        resolved = true
        NSApp.stopModal(withCode: response)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        finish(.cancel)
        return false
    }
}
