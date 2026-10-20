import AppKit
import Combine
import LocalAuthentication
import Network
import OSLog
import ServiceManagement
import ScreenLinkCore

struct FoundMac: Identifiable {
    let id: String
    let endpoint: NWEndpoint
    let name: String
}

final class AppModel: NSObject, ObservableObject {
    @Published var settings: Settings
    @Published var screen = ScreenState.unknown
    @Published var networkStatus = "网络接收关闭"
    @Published var bluetoothStatus = "尚未开始扫描"
    @Published var nearby: [NearbyPhone] = []
    @Published var discovered: [FoundMac] = []
    @Published var coordinators: [FoundMac] = []
    @Published var joinRequests: [JoinRequestInfo] = []
    @Published var joinListening = false
    @Published var joinServiceStatus = "尚未开放加入"
    @Published var discoveryStatus = "点击查找主控，或直接填写主控 IP"
    @Published var joinStatus = ""
    @Published var joinCode = ""
    @Published var joining = false
    @Published var selectedTab = 0
    var onJoinRequest: (() -> Void)?
    @Published var results: [String: String] = [:]
    @Published var events: [String] = []
    @Published var presenceText = "未检测"
    @Published var isPresent = false
    @Published var awakeActive = false
    @Published var hasKey = false
    @Published var hasPassword = false
    @Published var unlockSetupStatus = ""
    @Published var operationInProgress = false
    @Published var lastSignalText = "尚无有效信号"
    @Published var rssi: Int?
    @Published var accessibilityGranted = ScreenControl.accessibility

    private let bluetooth = BluetoothMonitor()
    private let server = LinkServer()
    private let joinServer = JoinServer()
    private var joinClient: JoinClient?
    private var joinBrowser: NWBrowser?
    private var joinProbes: [String: JoinProbe] = [:]
    private var fixedCoordinators: [FoundMac] = []
    private var bonjourCoordinators: [FoundMac] = []
    private var discoveryGeneration = UUID()
    private var discoveryProblem: String?
    private let idle = IdleDisplayGuard()
    private let unlocker = ExperimentalUnlocker()
    private var browser: NWBrowser?
    private var key: Data?
    private var timer: Timer?
    private var presence = PresencePolicy()
    private var phoneReturn = PhoneReturnPolicy()
    private var returnPhoneID: UUID?
    private var unlockGeneration = UUID()
    private var remotePresenceUntil: TimeInterval = 0
    private var nextLease: TimeInterval = 0
    private var suppressRelayUntil: TimeInterval = 0
    private var observing = false
    private var observers: [NSObjectProtocol] = []
    private var authContext: LAContext?
    private var knownPeerIDs: [String: UUID] = [:]
    var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    override init() {
        var problem: String?
        do { settings = try Configuration.load() }
        catch { settings = Settings(); problem = "配置读取失败，已使用关闭状态：\(error.localizedDescription)" }
        super.init()
        if let problem { record(problem) }
        // Persist the device identity before any network operation.
        do { try Configuration.save(settings) } catch { record("配置保存失败：\(error.localizedDescription)") }
        do { key = try Vault.read("group-key"); hasKey = key?.count == 32 }
        catch { record("无法读取组密钥：\(error.localizedDescription)") }
        // Do not read the login password at startup; only on explicit unlock requests.
        hasPassword = UserDefaults.standard.bool(forKey: "hasLocalPassword")
        screen = ScreenControl.state
        unlocker.onProgress = { [weak self] in self?.record("实验解锁步骤：" + $0) }
        bluetooth.onDevices = { [weak self] in self?.nearby = $0 }
        bluetooth.onStatus = { [weak self] in self?.bluetoothStatus = $0 }
        bluetooth.onSignal = { [weak self] value in
            guard let self else { return }
            self.rssi = value
            if self.settings.acceptsPresenceSignal(value) {
                self.presence.signal(at: self.uptime)
                self.lastSignalText = Date().formatted(date: .omitted, time: .standard)
            }
        }
        bluetooth.onConnectionLost = { [weak self] in self?.phoneReturn.disconnected() }
        bluetooth.onConnectedSignal = { [weak self] value in
            guard let self else { return }
            guard self.settings.isCoordinator, self.settings.phoneUnlockEnabled,
                  !self.settings.passiveBLE, self.settings.acceptsUnlockSignal(value) else {
                self.phoneReturn.disconnected(); return
            }
            if self.phoneReturn.sample(connected: true, at: self.uptime) { self.unlockForPhoneReturn() }
        }
        server.onState = { [weak self] in self?.networkStatus = $0 }
        server.onRejected = { [weak self] in self?.record("拒绝控制消息：" + $0) }
        server.handler = { [weak self] message, reply in self?.handle(message, reply: reply) }
        joinServer.onListening = { [weak self] in self?.joinListening = $0 }
        joinServer.onState = { [weak self] status in
            self?.joinServiceStatus = status; self?.record(status)
        }
        joinServer.onRequests = { [weak self] requests in
            guard let self else { return }
            let added = requests.contains { request in !self.joinRequests.contains { $0.id == request.id } }
            self.joinRequests = requests
            if added {
                self.selectedTab = 3
                if ScreenControl.state == .unlocked { self.onJoinRequest?() }
            }
        }
        joinServer.onJoined = { [weak self] hello, address in
            guard let self else { return false }
            do {
                guard let address else { throw LinkError.unavailable("无法取得跟随端地址，请重新申请") }
                var draft = self.settings
                self.addRoute(to: &draft, id: hello.deviceID, name: hello.name, host: address)
                try Configuration.save(draft)
                self.settings = draft // Keep the join connection alive until its final acknowledgement.
                self.knownPeerIDs[hello.deviceID.uuidString] = hello.deviceID
                self.record("已接受加入：\(hello.name)（\(address)）")
                self.results[hello.deviceID.uuidString] = "已加入，正在检测…"
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.send(.status, to: (hello.deviceID.uuidString, .hostPort(host: NWEndpoint.Host(address), port: 45731)))
                }
                return true
            } catch { self.record("保存跟随端失败：\(error.localizedDescription)"); return false }
        }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            if self.settings.isCoordinator && (self.settings.autoLock || self.settings.relayManualLock) {
                self.broadcast(.lock, reason: "主控即将休眠（发送不保证完成）")
            }
            self.cancelPendingUnlocks(); self.idle.set(false); self.remotePresenceUntil = 0
            self.phoneReturn = PhoneReturnPolicy(timeout: self.settings.signalTimeout)
            self.presence.reset(); self.isPresent = false
            self.joinServer.stop(); self.joinClient?.cancel()
            self.joinServiceStatus = "系统休眠，加入服务暂停"
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.presence.reset(); self?.remotePresenceUntil = 0
            self?.configureJoining()
            self?.record("已唤醒，等待新的手机信号")
        })
        configure()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
    }

    func record(_ message: String) {
        events.insert("\(Date().formatted(date: .omitted, time: .standard))  \(message)", at: 0)
        if events.count > 120 { events.removeLast(events.count - 120) }
    }
    @discardableResult
    func save(_ draft: Settings) -> Bool {
        do {
            var draft = draft
            if draft.isCoordinator { draft.coordinatorID = draft.deviceID }
            if draft.allowRemoteUnlock && !hasPassword { throw LinkError.unavailable("请先在本机保存并验证登录密码") }
            if draft.isCoordinator && draft.phoneUnlockEnabled && (draft.passiveBLE || draft.phoneID == nil) {
                throw LinkError.unavailable("手机连接解锁需要先选择手机，并关闭被动蓝牙扫描")
            }
            if draft.isCoordinator && draft.networkEnabled && !hasKey {
                try persistGroup(try Vault.newKey(), settings: draft)
            } else {
                try Configuration.save(draft)
                settings = draft; configure()
            }
            record("设置已保存")
            return true
        } catch { alert("设置未保存", error.localizedDescription); return false }
    }
    private func persistGroup(_ newKey: Data, settings draft: Settings, keepJoin: Bool = false) throws {
        try draft.validate()
        let oldKey = key, oldSettings = settings
        do {
            try Vault.write(newKey, account: "group-key")
            try Configuration.save(draft)
        } catch {
            do {
                if let oldKey { try Vault.write(oldKey, account: "group-key") }
                else { try Vault.delete("group-key") }
                try Configuration.save(oldSettings)
            } catch { record("恢复旧配置失败，请重新配对：\(error.localizedDescription)") }
            throw error
        }
        key = newKey; hasKey = true; settings = draft
        knownPeerIDs.removeAll(); results.removeAll()
        configure(keepJoin: keepJoin)
    }
    private func configure(keepJoin: Bool = false) {
        if !keepJoin { joinClient?.cancel() }
        configureJoining()
        cancelPendingUnlocks()
        if returnPhoneID != settings.phoneID || !settings.phoneUnlockEnabled {
            phoneReturn = PhoneReturnPolicy(timeout: settings.signalTimeout)
        }
        returnPhoneID = settings.phoneID
        phoneReturn.timeout = settings.signalTimeout
        presence = PresencePolicy(timeout: settings.signalTimeout)
        remotePresenceUntil = 0; idle.set(false); observing = false; isPresent = false
        bluetooth.stop(); rssi = nil
        if settings.isCoordinator, settings.phoneID != nil,
           settings.autoLock || settings.keepAwake || settings.phoneUnlockEnabled { observe(listing: false) }
        server.stop(); browser?.cancel(); browser = nil; discovered = []
        guard settings.networkEnabled, let key, key.count == 32 else {
            networkStatus = settings.networkEnabled ? "缺少组密钥，请先配对" : "网络接收关闭"
            return
        }
        do { try server.start(key: key, deviceID: settings.deviceID) }
        catch { networkStatus = "监听失败：\(error.localizedDescription)"; record(networkStatus) }
        let browser = NWBrowser(for: .bonjour(type: "_screenlink._tcp", domain: nil), using: .tcp)
        self.browser = browser
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            self.discovered = results.compactMap { result in
                guard case let .service(name, _, _, _) = result.endpoint,
                      name != self.settings.deviceID.uuidString,
                      !self.settings.peers.contains(where: { $0.id.uuidString == name }) else { return nil }
                return FoundMac(id: name, endpoint: result.endpoint, name: String(name.prefix(8)))
            }.sorted { $0.id < $1.id }
        }
        browser.start(queue: .main)
    }
    private func configureJoining() {
        joinServer.stop()
        joinServiceStatus = hasKey ? "尚未开放加入" : "点击开启后将自动创建组"
        guard settings.allowsJoining, let key, key.count == 32 else { return }
        do { try joinServer.start(deviceID: settings.deviceID, name: settings.deviceName, key: key) }
        catch { joinServiceStatus = "加入服务启动失败：\(error.localizedDescription)"; record(joinServiceStatus) }
    }
    func openJoining() {
        if hasKey && !settings.isCoordinator {
            guard NativePrompt.show("将这台 Mac 改为主控？",
                detail: "本机会管理当前组。请先关闭原主控的主控角色，其他成员需重新加入本机以更新主控身份。",
                confirm: "设为主控", cancel: "取消") else { return }
        }
        var draft = settings
        draft.isCoordinator = true; draft.networkEnabled = true; draft.joinEnabled = true
        _ = save(draft)
    }
    func retryJoining() { configureJoining() }
    func closeJoining() {
        var draft = settings; draft.joinEnabled = false
        if save(draft) { joinServiceStatus = "已关闭新成员加入；现有组仍可联动" }
    }
    func findCoordinators() {
        let generation = UUID(); discoveryGeneration = generation
        joinBrowser?.cancel(); joinBrowser = nil
        let oldProbes = Array(joinProbes.values); joinProbes.removeAll()
        oldProbes.forEach { $0.cancel() }
        coordinators = []; fixedCoordinators = []; bonjourCoordinators = []; discoveryProblem = nil
        discoveryStatus = "正在通过 Bonjour 和固定地址查找主控…"
        let browser = NWBrowser(for: .bonjour(type: "_screenjoin._tcp", domain: nil), using: .tcp)
        joinBrowser = browser
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            guard let self, self.joinBrowser === browser else { return }
            switch state {
            case .failed(let error), .waiting(let error):
                self.discoveryProblem = "Bonjour 未就绪（\(error.localizedDescription)）"
                self.updateCoordinatorList()
            default: break
            }
        }
        browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
            guard let self, self.joinBrowser === browser else { return }
            self.bonjourCoordinators = results.compactMap { result in
                guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                if self.settings.isCoordinator && name.hasSuffix(String(self.settings.deviceID.uuidString.prefix(8))) { return nil }
                return FoundMac(id: String(describing: result.endpoint), endpoint: result.endpoint, name: name)
            }
            self.updateCoordinatorList()
        }
        browser.start(queue: .main)
        // Only probe addresses explicitly configured by the user.
        // Do not scan the subnet or obtain credentials merely to populate the list.
        let hosts = Set(settings.peers.map(\.host))
        for host in hosts {
            let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: 45732)
            let probe = JoinProbe(endpoint: endpoint, deviceID: settings.deviceID) { [weak self] result in
                guard let self, self.discoveryGeneration == generation else { return }
                self.joinProbes.removeValue(forKey: host)
                if case .success(let name) = result {
                    self.fixedCoordinators.append(FoundMac(id: "ip:" + host, endpoint: endpoint, name: "\(name) · \(host)"))
                }
                self.updateCoordinatorList()
            }
            joinProbes[host] = probe
        }
    }
    private func updateCoordinatorList() {
        coordinators = (fixedCoordinators + bonjourCoordinators).sorted { $0.name < $1.name }
        if !coordinators.isEmpty {
            discoveryStatus = "已找到可申请加入的主控，选择下方设备"
        } else if !joinProbes.isEmpty {
            discoveryStatus = "正在检查已配置的固定地址…"
        } else {
            discoveryStatus = (discoveryProblem.map { $0 + "。" } ?? "") + "未找到主控；请确认主控已开放加入，或直接填写 IP"
        }
    }
    func join(host: String) {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            var draft = Settings(); draft.peers = [Peer(name: "主控", host: host)]
            try draft.validate()
            beginJoin(.hostPort(host: NWEndpoint.Host(host), port: 45732))
        } catch { alert("主控地址无效", "请输入 IP 或主机名，例如 mac-mini.local，不包含 http:// 或端口。") }
    }
    func beginJoin(_ endpoint: NWEndpoint) {
        guard !joining else { return }
        if hasKey {
            guard NativePrompt.show("申请加入这个主控的组？",
                detail: "主控接受后，本机将成为跟随端并替换当前组配置；实验远程解锁会关闭，需在本机重新启用。",
                confirm: "申请加入", cancel: "取消") else { return }
        }
        joining = true; joinStatus = "正在连接主控…"; joinCode = ""
        let client = JoinClient(); joinClient = client
        client.onChallenge = { [weak self] name, code in
            self?.joinCode = code
            self?.joinStatus = "已向“\(name)”申请，请在主控核对相同数字并接受（2 分钟内）"
        }
        client.provision = { [weak self] code, name, address in
            guard let self else { return false }
            do {
                guard let address else { throw LinkError.unavailable("无法取得主控地址") }
                var draft = self.settings
                draft.isCoordinator = false; draft.coordinatorID = code.coordinatorID
                draft.networkEnabled = true; draft.joinEnabled = false; draft.allowRemoteUnlock = false
                if self.key != code.key { draft.peers.removeAll() }
                self.addRoute(to: &draft, id: code.coordinatorID, name: name, host: address)
                try self.persistGroup(code.key, settings: draft, keepJoin: true)
                return true
            } catch { self.record("保存加入配置失败：\(error.localizedDescription)"); return false }
        }
        client.completion = { [weak self] result in
            guard let self else { return }
            self.joining = false; self.joinClient = nil; self.joinCode = ""
            switch result {
            case .success:
                self.joinStatus = "已加入主控的组，网络联动已开启。可到工作台刷新状态。"
                self.joinBrowser?.cancel(); self.joinBrowser = nil
                self.record("已完成加入主控组"); self.refreshPeers()
            case .failure(let error): self.joinStatus = error.localizedDescription; self.record(self.joinStatus)
            }
        }
        do { try client.start(endpoint: endpoint, deviceID: settings.deviceID, name: settings.deviceName) }
        catch { client.cancel(); joinStatus = "无法申请加入：\(error.localizedDescription)" }
    }
    func cancelJoin() { joinClient?.cancel() }
    func acceptJoin(_ request: JoinRequestInfo) {
        guard ScreenControl.state == .unlocked else {
            alert("请先解锁本机", "解锁后核对两端数字再接受加入。"); return
        }
        do {
            // Check capacity and address before releasing the group credential.
            var draft = settings
            addRoute(to: &draft, id: request.deviceID, name: request.name, host: request.address)
            try draft.validate()
            try joinServer.approve(request.id)
            record("已接受申请，等待跟随端确认保存：\(request.name)")
        } catch { alert("暂时无法接受", "申请可能已过期，或设备列表已满。请清理旧设备后重新申请。") }
    }
    func rejectJoin(_ request: JoinRequestInfo) { joinServer.reject(request.id) }
    private func addRoute(to draft: inout Settings, id: UUID, name: String, host: String) {
        draft.peers.removeAll { $0.id == id || $0.host == host }
        var peer = Peer(name: name, host: host); peer.id = id
        draft.peers.append(peer)
    }
    func observe(listing: Bool = true) {
        observing = true
        bluetooth.start(phone: settings.phoneID, passive: settings.passiveBLE, listing: listing)
        record(settings.autoLock ? "开始手机观察；自动锁屏已启用" : "开始手机观察；自动锁屏关闭")
    }
    func stopObserving() {
        if settings.autoLock || settings.keepAwake || settings.phoneUnlockEnabled {
            alert("请先关闭自动策略", "在设置中关闭离开锁屏、手机连接解锁和在场保活后，可以停止观察。")
            return
        }
        observing = false; bluetooth.stop(); presence.reset(); isPresent = false; idle.set(false)
    }
    func selectPhone(_ phone: NearbyPhone) {
        var draft = settings
        draft.phoneID = phone.id; draft.phoneName = phone.name
        save(draft); observe()
        record("选定设备：\(phone.name)；请通过离开/返回测试确认是你的 iPhone")
    }
    private func tick() {
        let trusted = ScreenControl.accessibility
        if accessibilityGranted != trusted { accessibilityGranted = trusted }
        let current = ScreenControl.state
        if current != screen {
            let previous = screen; screen = current
            if current == .locked {
                cancelPendingUnlocks()
                idle.set(false)
                if previous == .unlocked, settings.isCoordinator, settings.relayManualLock, uptime > suppressRelayUntil {
                    broadcast(.lock, reason: "主控系统锁屏联动")
                }
            }
            if current == .unlocked { unlocker.observedUnlocked() }
        }
        if presence.tick(at: uptime), observing {
            record("选定手机持续断连或信号低于阈值，已判定离开")
            if settings.isCoordinator && settings.autoLock { lockAll(reason: "手机离开") }
        }
        if isPresent != presence.isPresent { isPresent = presence.isPresent }
        let text = presence.isPresent ? "手机在场" : (presence.lastSignal == nil ? "等待首次信号" : "手机已离开")
        if presenceText != text { presenceText = text }
        let fresh = settings.isCoordinator ? presence.isPresent : uptime < remotePresenceUntil
        idle.set(settings.keepAwake && fresh && current == .unlocked)
        if awakeActive != idle.active { awakeActive = idle.active }
        if settings.isCoordinator, settings.keepAwake, presence.isPresent, current == .unlocked, uptime >= nextLease {
            nextLease = uptime + 5
            broadcast(.presence, reason: nil)
        }
    }
    private var targets: [(String, NWEndpoint)] {
        var items: [(String, NWEndpoint)] = settings.peers.map { peer in
            (peer.id.uuidString, .hostPort(host: NWEndpoint.Host(peer.host), port: NWEndpoint.Port(rawValue: peer.port)!))
        }
        let registered = Set(settings.peers.map { $0.id.uuidString })
        items += discovered.filter { !registered.contains($0.id) }.map { ($0.id, $0.endpoint) }
        return items
    }
    private func send(_ command: Command, to target: (String, NWEndpoint), completion: ((UUID?) -> Void)? = nil) {
        guard settings.networkEnabled, let key else { completion?(nil); return }
        let message = Message(sender: settings.deviceID, command: command)
        if command != .presence { results[target.0] = "等待响应…" }
        _ = LinkRequest(endpoint: target.1, message: message, key: key) { [weak self] result in
            guard let self else { completion?(nil); return }
            switch result {
            case .success(let reply):
                self.knownPeerIDs[target.0] = reply.sender
                if command != .presence {
                    let state = reply.state.map { Self.label($0) } ?? "状态未知"
                    self.results[target.0] = "\(state) · \(reply.note ?? "")"
                }
                completion?(reply.sender)
            case .failure(let error):
                if command != .presence { self.results[target.0] = "未确认 · \(error.localizedDescription)" }
                completion?(nil)
            }
        }
    }
    func refreshPeers() { broadcast(.status, reason: nil) }
    private func broadcast(_ command: Command, reason: String?) {
        if let reason { record(reason) }
        if !settings.networkEnabled || key == nil {
            if command != .presence { record("未向其他设备发送：网络关闭或未配对") }
            return
        }
        var sentIDs = Set<UUID>()
        for target in targets {
            if let id = knownPeerIDs[target.0], !sentIDs.insert(id).inserted { continue }
            send(command, to: target)
        }
    }
    func lockAll(reason: String = "手动锁定全部") {
        cancelPendingUnlocks()
        suppressRelayUntil = uptime + 5
        broadcast(.lock, reason: reason)
        idle.set(false)
        ScreenControl.lock { [weak self] result in self?.record("本机：\(result)") }
    }
    func unlockOthers() {
        guard !operationInProgress else { return }
        guard ScreenControl.state == .unlocked else {
            alert("请先解锁当前 Mac", "先通过系统密码或 Touch ID 解锁本机，再发起其他设备的解锁请求。")
            return
        }
        guard settings.networkEnabled, hasKey, !targets.isEmpty else {
            alert("尚未连接设备", "请配置组密钥、开启网络接收并添加其他 Mac。")
            return
        }
        let context = LAContext()
        let generation = UUID(); unlockGeneration = generation
        authContext = context; operationInProgress = true
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "向你的其他 Mac 发出解锁请求") { [weak self] success, _ in
            DispatchQueue.main.async {
                guard let self, self.unlockGeneration == generation else { return }
                self.authContext = nil
                guard success, ScreenControl.state == .unlocked else {
                    self.operationInProgress = false; self.record("解锁请求取消或本机会话已锁定"); return
                }
                self.unlockUniqueTargets(authorization: UnlockAuthorization(
                    source: .manual, generation: generation, expires: self.uptime + 15))
            }
        }
    }
    private func cancelPendingUnlocks() {
        unlockGeneration = UUID()
        authContext?.invalidate(); authContext = nil
        operationInProgress = false
        unlocker.cancel()
    }
    private func permits(_ authorization: UnlockAuthorization) -> Bool {
        authorization.permits(at: uptime, generation: unlockGeneration, state: ScreenControl.state,
            phoneReady: settings.isCoordinator && settings.phoneUnlockEnabled && !settings.passiveBLE
                && settings.phoneID != nil && phoneReturn.isFresh(at: uptime))
    }
    private func unlockForPhoneReturn() {
        guard !operationInProgress else { record("手机已连接，已有解锁操作，本次不重复触发"); return }
        let generation = UUID(); unlockGeneration = generation
        let authorization = UnlockAuthorization(source: .phone, generation: generation, expires: uptime + 15)
        guard permits(authorization) else { return }
        operationInProgress = true
        record("手机已连接且信号达标，触发一次全部解锁")
        if ScreenControl.state == .locked {
            unlocker.attempt(enabled: settings.allowRemoteUnlock,
                authorized: { [weak self] in self?.permits(authorization) ?? false }) { [weak self] result in
                self?.record("手机连接解锁本机：\(result)")
            }
        }
        unlockUniqueTargets(authorization: authorization)
    }
    private func unlockUniqueTargets(authorization: UnlockAuthorization) {
        // Fixed IP and Bonjour can refer to the same Mac. Authenticate status first,
        // then send one unlock per verified device identity, never two password attempts.
        guard permits(authorization) else { operationInProgress = false; return }
        guard settings.networkEnabled, hasKey else {
            operationInProgress = false; record("未向其他设备解锁：网络关闭或未配对"); return
        }
        let candidates = targets
        guard !candidates.isEmpty else { operationInProgress = false; return }
        var remaining = candidates.count
        var unique: [UUID: (String, NWEndpoint)] = [:]
        for target in candidates {
            send(.status, to: target) { [weak self] id in
                guard let self, self.unlockGeneration == authorization.generation else { return }
                if let id, id != self.settings.deviceID, unique[id] == nil { unique[id] = target }
                remaining -= 1
                guard remaining == 0 else { return }
                self.operationInProgress = false
                guard self.permits(authorization) else {
                    self.record("解锁请求已取消：授权过期、会话变化或手机连接不再有效"); return
                }
                let reason = authorization.source == .phone ? "手机连接触发" : "本机认证通过"
                self.record("\(reason)，向 \(unique.count) 台已验证设备请求实验解锁")
                for target in unique.values { self.send(.unlock, to: target) }
            }
        }
    }
    private func handle(_ message: Message, reply: @escaping (Message) -> Void) {
        func respond(_ note: String) {
            reply(Message(sender: settings.deviceID, command: .reply, responseTo: message.id,
                          state: ScreenControl.state, note: "\(settings.deviceName)：\(note)"))
        }
        switch message.command {
        case .status: respond("在线")
        case .lock:
            cancelPendingUnlocks()
            suppressRelayUntil = uptime + 5; remotePresenceUntil = 0; idle.set(false)
            ScreenControl.lock { result in self.record("收到组内锁屏：\(result)"); respond(result) }
        case .unlock:
            unlocker.attempt(enabled: settings.allowRemoteUnlock) { result in
                self.record("收到组内解锁：\(result)"); respond(result)
            }
        case .presence:
            guard !settings.isCoordinator, settings.coordinatorID == message.sender else { respond("不是配置的主控，已忽略"); return }
            remotePresenceUntil = uptime + 12
            respond("在场租约已更新")
        case .reply: respond("无效请求")
        }
    }
    static func label(_ state: ScreenState) -> String {
        switch state { case .locked: return "已锁定"; case .unlocked: return "已解锁"; case .unknown: return "状态未知" }
    }
    func createGroup() {
        do {
            var draft = settings
            if draft.isCoordinator { draft.coordinatorID = draft.deviceID }
            try persistGroup(Vault.newKey(), settings: draft)
            record("已生成新的组密钥；其他设备需重新申请加入或导入配对码")
        } catch { alert("生成失败", error.localizedDescription) }
    }
    func exportPairing() {
        guard let key, let coordinator = settings.isCoordinator ? settings.deviceID : settings.coordinatorID else {
            alert("无法复制配对码", "请先设置主控角色并生成组密钥，或从主控导入配对码。")
            return
        }
        do {
            let code = try JSONEncoder().encode(PairingCode(key: key, coordinatorID: coordinator)).base64EncodedString()
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(code, forType: .string)
            record("配对码已复制；它包含组密钥，请只交给自己的 Mac")
            // Clear only if the clipboard still contains our secret.
            DispatchQueue.main.asyncAfter(deadline: .now() + 120) {
                if NSPasteboard.general.string(forType: .string) == code { NSPasteboard.general.clearContents() }
            }
        } catch { alert("复制失败", error.localizedDescription) }
    }
    @discardableResult
    func importPairing(_ string: String) -> Bool {
        do {
            let code = try PairingCode.parse(string)
            var draft = settings; draft.coordinatorID = code.coordinatorID
            draft.isCoordinator = draft.deviceID == code.coordinatorID
            if key != code.key { draft.allowRemoteUnlock = false }
            try persistGroup(code.key, settings: draft)
            record("组配对已导入")
            return true
        } catch { alert("导入失败", error.localizedDescription); return false }
    }
    func promptForPassword() {
        guard let password = NativePrompt.requestPassword(for: NSUserName()) else { return }
        _ = savePassword(password)
    }
    private func savePassword(_ password: String) -> Bool {
        guard !password.isEmpty, password.utf16.count <= 256 else {
            unlockSetupStatus = password.isEmpty
                ? "尚未保存：请先输入这台 Mac 的当前登录密码。"
                : "尚未保存：输入内容过长，请检查是否粘贴了多余文字。"
            alert("密码未保存", unlockSetupStatus); return false
        }
        do {
            try CredentialSetup.perform(verify: {
                try LocalPasswordVerifier.verify(password)
            }, store: {
                try Vault.write(Data(password.utf8), account: "login-password")
            })
            hasPassword = true; UserDefaults.standard.set(true, forKey: "hasLocalPassword")
            unlockSetupStatus = settings.allowRemoteUnlock
                ? "本机密码已验证并更新，远程解锁保持开启。"
                : "本机密码已验证并保存。接下来打开下方的远程解锁开关。"
            record("登录密码已在本机验证并写入本机钥匙串")
            return true
        } catch {
            unlockSetupStatus = (error as? CredentialSetupFailure)?.localizedDescription
                ?? "保存失败：无法确定失败阶段。"
            record(unlockSetupStatus)
            Logger(subsystem: "local.screenlink.app", category: "credential-setup")
                .error("\(self.unlockSetupStatus, privacy: .public)")
            alert("密码未保存", unlockSetupStatus); return false
        }
    }
    func setRemoteUnlock(_ enabled: Bool) {
        guard enabled != settings.allowRemoteUnlock else { return }
        if enabled {
            guard hasPassword else {
                unlockSetupStatus = "尚未开启：请先在第一步输入、验证并保存这台 Mac 的登录密码。"
                alert("先保存本机密码", unlockSetupStatus); return
            }
            guard NativePrompt.show("允许已配对的 Mac 解锁本机？",
                detail: "启用后，持有组密钥的 Mac 可以请求本机通过辅助功能输入已保存的密码。此功能仅适用于已登录后的锁屏，不支持开机 FileVault。密码不会发送到网络，失败不会自动重试。请确认你理解这些限制。",
                confirm: "我理解，允许解锁", cancel: "取消") else {
                unlockSetupStatus = "已取消，远程解锁仍然关闭。"; return
            }
        }
        var draft = settings
        draft.allowRemoteUnlock = enabled
        if save(draft) {
            unlockSetupStatus = enabled
                ? "远程解锁已开启。锁定这台 Mac 后，从另一台已解锁的 Mac 发起认证解锁。"
                : "远程解锁已关闭。"
        } else { unlockSetupStatus = "远程解锁设置未保存，请查看错误提示后重试。" }
    }
    func removePassword() {
        do {
            try Vault.delete("login-password"); hasPassword = false
            UserDefaults.standard.set(false, forKey: "hasLocalPassword")
            var draft = settings; draft.allowRemoteUnlock = false; save(draft)
            unlockSetupStatus = "已删除本机密码，远程解锁已关闭。"
            record("已删除本机保存的登录密码，并关闭实验解锁")
        } catch { alert("删除失败", error.localizedDescription) }
    }
    func setLoginLaunch(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            record("登录启动设置已更新")
        } catch { alert("登录启动设置失败", error.localizedDescription) }
    }
    func shutdown() {
        cancelPendingUnlocks()
        timer?.invalidate(); bluetooth.stop(); server.stop(); browser?.cancel(); idle.set(false)
        joinBrowser?.cancel(); joinServer.stop(); joinClient?.cancel()
        discoveryGeneration = UUID()
        let probes = Array(joinProbes.values); joinProbes.removeAll(); probes.forEach { $0.cancel() }
        authContext?.invalidate()
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    }
    func alert(_ title: String, _ detail: String) {
        NativePrompt.show(title, detail: detail)
    }
    func confirmGroupRotation() {
        guard NativePrompt.show("轮换组密钥？",
            detail: "其他 Mac 需要重新申请加入，或导入新配对码后才能继续联动。",
            confirm: "生成新密钥", cancel: "取消") else { return }
        createGroup()
    }
}
