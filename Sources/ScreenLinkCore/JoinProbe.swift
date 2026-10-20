import Foundation
import Network

/// Identifies a coordinator using only its initial challenge, then closes before
/// revealing a client identity. No pending request, approval or group key exchange.
public final class JoinProbe {
    private let client = JoinClient()
    private var completion: ((Result<String, Error>) -> Void)?
    private var finished = false
    public init(endpoint: NWEndpoint, deviceID: UUID, completion: @escaping (Result<String, Error>) -> Void) {
        self.completion = completion
        client.onChallenge = { [weak self] name, _ in self?.finish(.success(name)) }
        client.completion = { [weak self] result in
            if case .failure(let error) = result { self?.finish(.failure(error)) }
        }
        do { try client.start(endpoint: endpoint, deviceID: deviceID, name: "ScreenLink discovery", timeout: 3) }
        catch { finish(.failure(error)) }
    }
    public func cancel() { finish(.failure(LinkError.closed)) }
    private func finish(_ result: Result<String, Error>) {
        guard !finished else { return }; finished = true
        client.cancel()
        let callback = completion; completion = nil; callback?(result)
    }
}
