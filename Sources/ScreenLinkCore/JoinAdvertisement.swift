import Foundation

// Discovery is optional: publication errors must never tear down the TCP join listener.
public protocol JoinAdvertising: AnyObject {
    func start(name: String, port: UInt16, completion: @escaping (Result<Void, Error>) -> Void)
    func stop()
}

public final class JoinAdvertisement: NSObject, JoinAdvertising, NetServiceDelegate {
    private var service: NetService?
    private var completion: ((Result<Void, Error>) -> Void)?
    public override init() { super.init() }
    public func start(name: String, port: UInt16, completion: @escaping (Result<Void, Error>) -> Void) {
        stop()
        self.completion = completion
        let service = NetService(domain: "local.", type: "_screenjoin._tcp.", name: name, port: Int32(port))
        self.service = service; service.delegate = self
        service.publish()
    }
    public func stop() {
        service?.delegate = nil; service?.stop(); service = nil; completion = nil
    }
    public func netServiceDidPublish(_ sender: NetService) {
        guard service === sender else { return }
        completion?(.success(()))
    }
    public func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        guard service === sender else { return }
        let code = errorDict[NetService.errorCode]?.intValue ?? 0
        completion?(.failure(LinkError.unavailable("Bonjour 错误 \(code)")))
    }
}
