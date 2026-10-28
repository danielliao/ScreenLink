import Foundation

public enum LockResult: Equatable {
    case locked, retryable(String), blocked(String), cancelled
    public var note: String {
        switch self {
        case .locked: return "已锁定"
        case .retryable(let note), .blocked(let note): return note
        case .cancelled: return "锁屏请求已取消"
        }
    }
}

/// Main-queue confined. Only lock operations may retry; never password input.
public final class LockRetrier {
    private let state: () -> ScreenState
    private let attempt: (@escaping (LockResult) -> Void) -> Void
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private var generation = UUID()
    private var completion: ((LockResult) -> Void)?
    public var onRetry: ((Int) -> Void)?
    public var isPending: Bool { completion != nil }

    public init(state: @escaping () -> ScreenState,
                attempt: @escaping (@escaping (LockResult) -> Void) -> Void,
                schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
                }) {
        self.state = state; self.attempt = attempt; self.schedule = schedule
    }
    public func request(allowed: @escaping () -> Bool, completion: @escaping (LockResult) -> Void) {
        cancel()
        let id = UUID(); generation = id
        self.completion = completion
        run(id: id, number: 1, allowed: allowed)
    }
    public func cancel() {
        generation = UUID()
        finish(.cancelled)
    }
    public func observeLocked() {
        guard isPending else { return }
        generation = UUID()
        finish(.locked)
    }
    private func finish(_ result: LockResult) {
        let callback = completion; completion = nil
        callback?(result)
    }
    private func run(id: UUID, number: Int, allowed: @escaping () -> Bool) {
        guard generation == id, isPending else { return }
        guard allowed() else { finish(.cancelled); return }
        if state() == .locked { finish(.locked); return }
        attempt { [weak self] result in
            guard let self, self.generation == id, self.isPending else { return }
            if self.state() == .locked { self.finish(.locked); return }
            guard allowed() else { self.finish(.cancelled); return }
            switch result {
            case .retryable(let reason):
                guard number < 3 else {
                    self.finish(.retryable("\(reason)；已达 3 次尝试上限，请手动锁屏")); return
                }
                self.onRetry?(number + 1)
                self.schedule(1) { [weak self] in self?.run(id: id, number: number + 1, allowed: allowed) }
            default: self.finish(result)
            }
        }
    }
}
