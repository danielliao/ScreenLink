import AppKit
import SwiftUI
import ScreenLinkCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel!
    private var statusItem: NSStatusItem!
    private var window: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installEditingMenu()
        model = AppModel()
        model.onJoinRequest = { [weak self] in self?.showWindow() }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "lock.shield", accessibilityDescription: "ScreenLink")
        let menu = NSMenu()
        item("打开 ScreenLink…", action: #selector(showWindow), in: menu)
        menu.addItem(.separator())
        item("锁定全部 Mac", action: #selector(lockAll), in: menu)
        item("认证并解锁其他 Mac…", action: #selector(unlockOthers), in: menu)
        menu.addItem(.separator())
        item("退出 ScreenLink", action: #selector(quit), in: menu)
        statusItem.menu = menu
        if !CommandLine.arguments.contains("--background") { showWindow() }
    }
    private func item(_ title: String, action: Selector, in menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self; menu.addItem(item)
    }
    private func installEditingMenu() {
        // NSHostingView does not install SwiftUI App's default Edit commands.
        let main = NSMenu()
        let application = NSMenuItem()
        let appMenu = NSMenu(title: "ScreenLink")
        let quit = NSMenuItem(title: "退出 ScreenLink", action: #selector(quit), keyEquivalent: "q")
        quit.target = self; appMenu.addItem(quit)
        application.submenu = appMenu; main.addItem(application)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit; main.addItem(editItem)
        NSApp.mainMenu = main
    }
    @objc func showWindow() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 700),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "ScreenLink · 多台 Mac，一起锁屏"
            window.minSize = NSSize(width: 820, height: 650)
            window.contentView = NSHostingView(rootView: MainView(model: model))
            window.isReleasedWhenClosed = false; window.center(); self.window = window
        }
        window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc func lockAll() { model.lockAll() }
    @objc func unlockOthers() { model.unlockOthers() }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) { model?.shutdown() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
}

if CommandLine.arguments.contains("--diagnose") {
    print("ScreenLink \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development")")
    print("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
    print("Screen state (observed): \(ScreenControl.state.rawValue)")
    print("Accessibility: \(ScreenControl.accessibility)")
    print("Post-event access: \(CGPreflightPostEventAccess())")
    print("Configuration: \(Configuration.url.path)")
    exit(0)
}
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
