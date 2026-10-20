import SwiftUI
import ServiceManagement
import ScreenLinkCore

struct MainView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "lock.shield.fill").font(.system(size: 32)).foregroundStyle(.teal)
                VStack(alignment: .leading, spacing: 4) {
                    Text("ScreenLink").font(.title2.bold())
                    Text("你的工作台，统一守护").foregroundStyle(.secondary)
                }
                Spacer()
                Text(model.settings.isCoordinator ? "主控 Mac" : "跟随 Mac")
                    .font(.callout.weight(.medium)).padding(.horizontal, 12).padding(.vertical, 7)
                    .background(.teal.opacity(0.12), in: Capsule())
            }.padding(24)
            TabView(selection: $model.selectedTab) {
                Dashboard(model: model).tabItem { Label("工作台", systemImage: "desktopcomputer") }.tag(0)
                PhoneView(model: model).tabItem { Label("iPhone 检测", systemImage: "iphone.radiowaves.left.and.right") }.tag(1)
                SettingsView(model: model).tabItem { Label("设备与策略", systemImage: "slider.horizontal.3") }.tag(2)
                SecurityView(model: model).tabItem { Label("配对与解锁", systemImage: "key") }.tag(3)
            }.padding(.horizontal, 20).padding(.bottom, 16)
            HStack {
                Circle().fill(model.settings.networkEnabled && model.hasKey ? .teal : .gray).frame(width: 6, height: 6)
                Text(model.networkStatus)
                Spacer()
                Text("本地运行 · \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发") 试用版")
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.bottom, 14)
        }
    }
}

struct Dashboard: View {
    @ObservedObject var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    tile("本机", value: AppModel.label(model.screen), icon: "desktopcomputer")
                    tile("手机", value: model.settings.isCoordinator ? model.presenceText : "由主控检测", icon: "iphone")
                    tile("自动锁屏", value: model.settings.autoLock && model.settings.isCoordinator ? "已启用" : "未启用", icon: "lock")
                }
                HStack(spacing: 12) {
                    Button { model.lockAll() } label: {
                        Label("锁定全部 Mac", systemImage: "lock.fill").frame(maxWidth: .infinity).padding(8)
                    }.buttonStyle(.borderedProminent).tint(.teal)
                    Button { model.unlockOthers() } label: {
                        Label("认证并解锁其他 Mac", systemImage: "lock.open").frame(maxWidth: .infinity).padding(8)
                    }.buttonStyle(.bordered).disabled(model.operationInProgress)
                }
                Text("解锁其他设备需要先正常解锁本机；每台目标 Mac 单独开启实验解锁。未配置的设备不会收到指令。")
                    .font(.caption).foregroundStyle(.secondary)
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("工作台设备").font(.headline)
                            Spacer()
                            Button("刷新状态") { model.refreshPeers() }.disabled(!model.settings.networkEnabled)
                        }
                        deviceRow(model.settings.deviceName, subtitle: "当前设备", status: AppModel.label(model.screen))
                        ForEach(model.settings.peers) { peer in
                            Divider()
                            deviceRow(peer.name, subtitle: "\(peer.host):\(peer.port)", status: model.results[peer.id.uuidString] ?? "尚未检测")
                        }
                        ForEach(model.discovered.filter { mac in !model.settings.peers.contains { $0.id.uuidString == mac.id } }) { mac in
                            Divider()
                            deviceRow("自动发现 · \(mac.name)", subtitle: "Bonjour 局域网设备", status: model.results[mac.id] ?? "请刷新以验证组密钥")
                        }
                        if model.settings.peers.isEmpty && model.discovered.isEmpty {
                            Text("到“配对与解锁”查找主控或填写 IP，主控接受后自动加入。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(8)
                }
                GroupBox("最近事件") {
                    VStack(alignment: .leading, spacing: 7) {
                        if model.events.isEmpty { Text("准备就绪。先配对，再测试手机检测。").foregroundStyle(.secondary) }
                        ForEach(Array(model.events.prefix(12).enumerated()), id: \.offset) { _, event in
                            Text(event).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
            }.padding(16)
        }
    }
    func tile(_ title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold))
        }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }
    func deviceRow(_ name: String, subtitle: String, status: String) -> some View {
        HStack(alignment: .top) {
            Image(systemName: "desktopcomputer").foregroundStyle(.secondary).frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text(name).fontWeight(.medium)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(status).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing).frame(maxWidth: 360, alignment: .trailing)
        }
    }
}

struct PhoneView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("iPhone 无需安装 App").font(.title3.bold())
            Text("只在主控 Mac 选择手机。名称和信号强度仅用于辨认，必须通过带走手机再返回来验证；蓝牙设备身份可能随系统变化。")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("扫描 / 继续观察") { model.observe() }
                Button("停止观察") { model.stopObserving() }
                Spacer()
                Text(model.settings.autoLock ? "自动锁屏已开启" : "观察模式 · 不自动锁屏").foregroundStyle(.teal)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 7) {
                    Text(model.settings.phoneID == nil ? "尚未选择 iPhone" : "已选：\(model.settings.phoneName)").fontWeight(.semibold)
                    Text(model.bluetoothStatus)
                    Text("最后信号：\(model.lastSignalText)  ·  RSSI：\(model.rssi.map { "\($0) dBm" } ?? "—")")
                        .font(.caption).foregroundStyle(.secondary)
                    if let id = model.settings.phoneID { Text(id.uuidString).font(.caption2.monospaced()).foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            ScrollView {
              LazyVStack(spacing: 10) {
               ForEach(model.nearby) { phone in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(phone.name)
                        Text(phone.id.uuidString).font(.caption2.monospaced()).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(phone.rssi) dBm").monospacedDigit().foregroundStyle(.secondary)
                    Button(model.settings.phoneID == phone.id ? "已选择" : "选择") { model.selectPhone(phone) }
                        .disabled(model.settings.phoneID == phone.id)
                }.padding(10).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
               }
              }.padding(4)
            }.frame(maxWidth: .infinity, maxHeight: .infinity).overlay {
                if model.nearby.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "antenna.radiowaves.left.and.right").font(.largeTitle).foregroundStyle(.secondary)
                        Text("点击扫描，打开 iPhone 蓝牙并靠近主控 Mac").foregroundStyle(.secondary)
                    }.allowsHitTesting(false)
                }
            }
            Text("先测试：手机亮屏 → 锁屏放入口袋 → 离开至少 40 秒 → 返回。无持续可见信号时，先不要开启自动锁屏。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(18)
    }
}
