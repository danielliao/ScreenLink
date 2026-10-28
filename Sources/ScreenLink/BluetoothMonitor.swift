import Foundation
import CoreBluetooth
import ScreenLinkCore

struct NearbyPhone: Identifiable {
    let id: UUID
    var name: String
    var rssi: Int
    var lastSeen: Date
}

final class BluetoothMonitor: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var onDevices: (([NearbyPhone]) -> Void)?
    var onSignal: ((Int) -> Void)?
    var onConnectedSignal: ((Int) -> Void)?
    var onConnectionLost: (() -> Void)?
    var onStatus: ((String) -> Void)?
    private var manager: CBCentralManager?
    private var devices: [UUID: NearbyPhone] = [:]
    private var selected: UUID?
    private var peripheral: CBPeripheral?
    private var polling: Timer?
    private var passive = false
    private var wanted = false
    private var listing = false
    private var generation = 0
    private lazy var updates = ScanUpdates<[NearbyPhone]> { [weak self] phones in
        guard let self, self.wanted, self.listing else { return }
        self.onDevices?(phones)
    }

    func start(phone: UUID?, passive: Bool, listing: Bool = false) {
        onConnectionLost?()
        generation += 1
        updates.cancel()
        wanted = true; self.listing = listing; self.passive = passive; self.selected = phone
        if let old = peripheral { manager?.cancelPeripheralConnection(old) }
        peripheral = nil
        polling?.invalidate(); polling = nil
        if manager == nil {
            manager = CBCentralManager(delegate: self, queue: .main)
        } else if manager?.state == .poweredOn { scanAndRetrieve() }
    }
    func stop() {
        onConnectionLost?()
        wanted = false; listing = false; generation += 1
        updates.cancel()
        manager?.stopScan()
        if let peripheral { manager?.cancelPeripheralConnection(peripheral) }
        peripheral = nil; polling?.invalidate(); polling = nil
        onStatus?("蓝牙观察已停止")
    }
    private func scanAndRetrieve() {
        guard wanted, let manager, manager.state == .poweredOn else { return }
        manager.stopScan()
        manager.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        if !passive, let selected, let phone = manager.retrievePeripherals(withIdentifiers: [selected]).first {
            connect(phone)
        }
        onStatus?(selected == nil ? "扫描中，请找到并选择你的 iPhone" : "观察中，等待选定设备的有效信号")
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state != .poweredOn { onConnectionLost?() }
        switch central.state {
        case .poweredOn: scanAndRetrieve()
        case .poweredOff: onStatus?("蓝牙已关闭；已有在场信号将按超时失效")
        case .unauthorized: onStatus?("蓝牙权限未授权，请到系统设置开启")
        case .unsupported: onStatus?("这台 Mac 不支持 CoreBluetooth")
        default: onStatus?("蓝牙状态暂不可用")
        }
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String : Any], rssi RSSI: NSNumber) {
        let rssi = RSSI.intValue
        guard wanted, (-110 ... -1).contains(rssi) else { return }
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? "未命名 BLE 设备"
        devices[peripheral.identifier] = NearbyPhone(id: peripheral.identifier, name: name, rssi: rssi, lastSeen: Date())
        devices = devices.filter { Date().timeIntervalSince($0.value.lastSeen) < 60 }
        if listing {
            // Stable row order: fluctuating RSSI must not move a row under a click.
            updates.submit(devices.values.sorted { $0.id.uuidString < $1.id.uuidString })
        }
        guard peripheral.identifier == selected else { return }
        onSignal?(rssi)
        if !passive { connect(peripheral) }
    }
    private func connect(_ phone: CBPeripheral) {
        guard wanted, !passive, phone.identifier == selected else { return }
        peripheral = phone; phone.delegate = self
        if phone.state == .disconnected { manager?.connect(phone, options: nil) }
        if polling == nil {
            polling = CommonModeTimer.schedule(interval: 3) { [weak self] in
                guard let self, self.wanted, self.peripheral?.state == .connected else { return }
                self.peripheral?.readRSSI()
            }
        }
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard wanted, peripheral.identifier == selected, !passive else {
            central.cancelPeripheralConnection(peripheral); return
        }
        // Connection alone is not fresh presence; wait for a real RSSI sample.
        peripheral.delegate = self; peripheral.readRSSI()
        onStatus?("已连接选定设备，持续读取信号")
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        reconnect(peripheral)
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        reconnect(peripheral)
    }
    private func reconnect(_ phone: CBPeripheral) {
        guard wanted, !passive, phone.identifier == selected else { return }
        onConnectionLost?()
        onStatus?("连接中断，等待恢复；暂不立即锁屏")
        let expectedGeneration = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.generation == expectedGeneration else { return }
            self.connect(phone)
        }
    }
    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard wanted, peripheral.identifier == selected, error == nil, (-110 ... -1).contains(RSSI.intValue) else { return }
        onSignal?(RSSI.intValue)
        if !passive, peripheral.state == .connected { onConnectedSignal?(RSSI.intValue) }
    }
}
