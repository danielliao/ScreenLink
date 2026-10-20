import Network

/// Serializes listener replacement on the main queue. cancel() is asynchronous;
/// starting the next fixed-port listener before .cancelled can fail with EADDRINUSE.
final class ListenerLifecycle {
    private var active: NWListener?
    private var pending: NWListener?
    private var closing = false

    func replace(with listener: NWListener) {
        pending = listener
        if active == nil { startPending() } else { cancelActive() }
    }
    func stop() {
        pending?.newConnectionHandler = nil; pending?.stateUpdateHandler = nil; pending = nil
        cancelActive()
    }
    private func cancelActive() {
        guard let active, !closing else { return }
        closing = true
        active.newConnectionHandler = nil
        active.cancel()
    }
    private func startPending() {
        guard active == nil, let next = pending else { return }
        pending = nil; active = next; closing = false
        let callback = next.stateUpdateHandler
        next.stateUpdateHandler = { [weak self, weak next] state in
            guard let self, let next, self.active === next else { return }
            if case .cancelled = state {
                self.active = nil; self.closing = false
                next.stateUpdateHandler = nil
                self.startPending()
            } else if !self.closing {
                callback?(state)
            }
        }
        next.start(queue: .main)
    }
}
