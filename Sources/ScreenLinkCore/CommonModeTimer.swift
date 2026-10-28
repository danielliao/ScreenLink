import Foundation

public enum CommonModeTimer {
    /// Register on the main loop's common modes so menu tracking does not pause it.
    public static func schedule(interval: TimeInterval, action: @escaping () -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in action() }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}
