import AppKit
import SwiftUI

// Synthetic-only UI fixture. Never instantiates AppModel or accesses credentials.
final class Fixture: ObservableObject {
    @Published var tick = 0
    var read: () -> String = { "" }
}
struct PasswordFixture: View {
    @ObservedObject var fixture: Fixture
    @State private var password = ""
    var body: some View {
        ScrollView {
            Form {
                Section("测试密码输入（虚构数据）") {
                    SecureField("本机当前登录密码", text: $password)
                        .textFieldStyle(.roundedBorder)
                    Text("刷新计数 \(fixture.tick)")
                }
            }.formStyle(.grouped)
        }.onAppear { fixture.read = { password } }
    }
}
func fields(in view: NSView) -> [NSSecureTextField] {
    (view as? NSSecureTextField).map { [$0] } ?? view.subviews.flatMap { fields(in: $0) }
}
func pump(_ seconds: TimeInterval = 0.2) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let fixture = Fixture()
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 260),
                      styleMask: [.titled], backing: .buffered, defer: false)
window.title = "ScreenLink 合成输入检查"
window.contentView = NSHostingView(rootView: PasswordFixture(fixture: fixture))
window.makeKeyAndOrderFront(nil)
pump()
guard let field = fields(in: window.contentView!).first else {
    print("FAIL: synthetic secure field unavailable"); exit(1)
}
var failures = 0
var count = 0
for value in ["Fixture-42!@$", "  fixture 空格 é 🔐  ", "e\u{301}xample"] {
    window.makeFirstResponder(field)
    guard let editor = field.currentEditor() as? NSTextView else {
        print("FAIL: synthetic field editor unavailable"); exit(1)
    }
    editor.selectAll(nil)
    editor.insertText(value, replacementRange: editor.selectedRange())
    pump()
    count += 1
    if Array(fixture.read().utf8) != Array(value.utf8) {
        failures += 1; print("FAIL: secure binding did not preserve UTF-8 bytes")
    }
    fixture.tick += 1
    pump()
    count += 1
    if Array(fixture.read().utf8) != Array(value.utf8) {
        failures += 1; print("FAIL: view refresh changed secure binding")
    }
}
window.orderOut(nil)
print("\(count) synthetic input checks, \(failures) failures; no authentication performed")
exit(failures == 0 ? 0 : 1)
