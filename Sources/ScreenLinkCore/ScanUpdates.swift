import Foundation

/// Keeps Bluetooth discovery bursts out of a view's current layout/callback stack.
/// Main-queue confined. A pending burst publishes only its latest snapshot.
public final class ScanUpdates<Value> {
    private var pending: Value?
    private var work: DispatchWorkItem?
    private let interval: TimeInterval
    private let publish: (Value) -> Void
    public init(interval: TimeInterval = 0.5, publish: @escaping (Value) -> Void) {
        self.interval = interval; self.publish = publish
    }
    public func submit(_ value: Value) {
        pending = value
        guard work == nil else { return }
        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.work = nil
            guard let value = self.pending else { return }
            self.pending = nil
            self.publish(value)
        }
        work = task
        DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: task)
    }
    public func cancel() { work?.cancel(); work = nil; pending = nil }
    deinit { work?.cancel() }
}
