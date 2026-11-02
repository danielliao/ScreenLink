import AppKit
import ApplicationServices
import Carbon

/// Observes timestamps only; never retains keys, coordinates, or input content.
final class InputActivity {
    private var global: Any?
    private var local: Any?
    private var last = ProcessInfo.processInfo.systemUptime
    var idle: Double {
        guard !IsSecureEventInputEnabled(), AXIsProcessTrusted(), global != nil, local != nil else { last = ProcessInfo.processInfo.systemUptime; return .nan }
        return max(0, ProcessInfo.processInfo.systemUptime - last)
    }
    func start() {
        stop(); last = ProcessInfo.processInfo.systemUptime
        let mask: NSEvent.EventTypeMask = [.keyDown, .keyUp, .flagsChanged, .mouseMoved,
            .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseDragged, .rightMouseDragged,
            .otherMouseDragged, .scrollWheel, .magnify, .rotate, .swipe]
        global = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] in self?.observe($0) }
        local = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in self?.observe(event); return event }
    }
    private func observe(_ event: NSEvent) {
        if let cg = event.cgEvent, cg.getIntegerValueField(.eventSourceUnixProcessID) == Int64(getpid()) { return }
        last = ProcessInfo.processInfo.systemUptime
    }
    func stop() {
        if let global { NSEvent.removeMonitor(global) }; if let local { NSEvent.removeMonitor(local) }
        global = nil; local = nil
    }
    deinit { stop() }
}

enum BootSession {
    static var id: String {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 1, size < 1024 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else { return "" }
        return String(cString: buffer)
    }
}
