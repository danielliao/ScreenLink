import SwiftUI
import AppKit
import ScreenLinkCore

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var draft = Settings()
    @State private var host = ""
    @State private var name = ""
    var body: some View {
        ScrollView {
            Form {
                Section("设备") {
                    TextField("本机名称", text: $draft.deviceName)
                    Toggle("这台是主控 Mac（建议 M4 Mac mini）", isOn: $draft.isCoordinator)
                    Text("主控 ID：\((draft.isCoordinator ? draft.deviceID : draft.coordinatorID)?.uuidString ?? "请到“配对与解锁”申请加入主控")")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Toggle("开启组内通信与设备发现", isOn: $draft.networkEnabled)
                    if draft.isCoordinator {
                        Toggle("允许跟随端发现主控并申请加入", isOn: Binding(
                            get: { draft.joinEnabled ?? true }, set: { draft.joinEnabled = $0 }
                        )).disabled(!draft.networkEnabled)
                    }
                    Text("主控首次开启时自动创建组。跟随端到“配对与解锁”查找主控或填写 IP，主控接受即可加入。通信 TCP 45731，加入 TCP 45732。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("自动策略") {
                    Toggle("手机离开后锁定全部 Mac", isOn: $draft.autoLock).disabled(!draft.isCoordinator)
                    Toggle("手机连接后解锁全部 Mac（实验）", isOn: Binding(
                        get: { draft.phoneUnlockEnabled }, set: { draft.unlockOnPhoneConnection = $0 }
                    )).disabled(!draft.isCoordinator)
                    Text("选定手机连接并读到新信号时触发一次，包含主控本机。各台需保存本机密码并允许实验解锁。首次有效连接或离开宽限时间后返回会触发；持续在线、短暂断连不重复尝试。需关闭被动扫描，蓝牙连接不等同于 Apple Watch 身份认证。")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("主控手动锁屏时，其他设备跟随", isOn: $draft.relayManualLock).disabled(!draft.isCoordinator)
                    Toggle("使用蓝牙信号强度判断离开", isOn: Binding(
                        get: { draft.lockRSSIThreshold != nil },
                        set: { draft.lockRSSIThreshold = $0 ? -75 : nil }
                    )).disabled(!draft.isCoordinator)
                    if let threshold = draft.lockRSSIThreshold {
                        HStack {
                            Text("锁屏信号阈值")
                            Slider(value: Binding(
                                get: { Double(draft.lockRSSIThreshold ?? -75) },
                                set: { draft.lockRSSIThreshold = Int($0) }
                            ), in: -100 ... -40, step: 1)
                            Text("\(threshold) dBm").monospacedDigit().frame(width: 80)
                        }.disabled(!draft.isCoordinator)
                        Text("当前信号：\(model.rssi.map { "\($0) dBm" } ?? "暂无")。越接近 0 越强；持续低于 \(threshold) dBm 或中断达到下方时长后锁屏。连接解锁需达到 \(threshold + 5) dBm。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("弱信号 / 信号中断时长")
                        Slider(value: $draft.signalTimeout, in: 10...180, step: 5)
                        Text("\(Int(draft.signalTimeout)) 秒").monospacedDigit().frame(width: 60)
                    }
                    Toggle("手机在场时，暂缓本机显示器闲置休眠", isOn: $draft.keepAwake)
                    Text("跟随端使用主控的短期在场信号；信号中断最多 12 秒即恢复系统策略。此项不覆盖独立屏保或企业强制锁屏，也不会解开手动锁屏。")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("被动蓝牙扫描（连接不稳定时尝试）", isOn: $draft.passiveBLE).disabled(!draft.isCoordinator)
                }
                Section("固定地址") {
                    ForEach(draft.peers) { peer in
                        HStack {
                            Text(peer.name); Spacer(); Text(peer.host).foregroundStyle(.secondary)
                            Button("移除") { draft.peers.removeAll { $0.id == peer.id } }
                        }
                    }
                    HStack {
                        TextField("名称，如 M1 Mac mini", text: $name)
                        TextField("IP 或 MacBook.local", text: $host)
                        Button("添加") {
                            let address = host.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !address.isEmpty else { return }
                            draft.peers.append(Peer(name: name.isEmpty ? address : name, host: address))
                            host = ""; name = ""
                        }
                    }
                    Text("填写其他 Mac 的固定 IP 或 .local 主机名；避免把本机地址加入。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("系统权限") {
                    HStack {
                        Text(model.accessibilityGranted ? "辅助功能已授权" : "锁屏与实验解锁需要辅助功能权限")
                        Spacer()
                        Button("打开授权提示") { ScreenControl.requestAccessibility() }
                    }
                    HStack {
                        Button("登录时启动") { model.setLoginLaunch(true) }
                        Button("取消登录启动") { model.setLoginLaunch(false) }
                        Text("先将 App 放入 /Applications，再启用").font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Spacer()
                    Button("还原未保存修改") { draft = model.settings }
                    Button("保存并应用") { model.save(draft) }.buttonStyle(.borderedProminent).tint(.teal)
                }
            }.formStyle(.grouped)
        }.onAppear { draft = model.settings }
        .onChange(of: model.selectedTab) { _, tab in if tab == 2 { draft = model.settings } }
    }
}

struct SecurityView: View {
    @ObservedObject var model: AppModel
    @State private var pairing = ""
    var body: some View {
        ScrollView {
            Form {
                Section("1 · 发现主控并加入组") {
                    JoinView(model: model)
                }
                Section {
                    DisclosureGroup("备用方式：手动配对码与密钥管理") {
                        Text("新版本建议使用上方的申请加入。与旧版本配对时，可手动复制和导入配对码。")
                            .font(.callout).foregroundStyle(.secondary)
                        Text(model.hasKey ? "本机已有组密钥" : "尚未配对").fontWeight(.medium)
                        Text("主控 Mac：创建组 → 复制配对码").font(.caption.weight(.semibold))
                        HStack {
                            Button(model.hasKey ? "轮换组密钥…" : "创建新组") {
                                if model.hasKey { model.confirmGroupRotation() } else { model.createGroup() }
                            }
                            Button("复制配对码") { model.exportPairing() }.disabled(!model.hasKey)
                        }
                        Text("其他 Mac：粘贴主控配对码 → 导入").font(.caption.weight(.semibold))
                        SecureField("配对码", text: $pairing, prompt: Text("点击右下方按钮粘贴，或在这里按 ⌘V"))
                            .textFieldStyle(.roundedBorder)
                        HStack {
                            Button("从剪贴板粘贴") {
                                guard let text = NSPasteboard.general.string(forType: .string),
                                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                                    model.alert("剪贴板没有文字", "请先在主控 Mac 点击“复制配对码”，再将配对码复制到这台 Mac 的剪贴板。"); return
                                }
                                pairing = text
                            }
                            Button("导入配对码") {
                                if model.importPairing(pairing) { pairing = "" }
                            }.buttonStyle(.borderedProminent)
                        }
                        Text(pairing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                             ? "尚未填入配对码。请先粘贴；开启自动发现不会自动填入。"
                             : "已有输入，点击“导入配对码”完成验证和配对。")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("配对码包含控制权限，请只在自己的 Mac 之间传递。剪贴板中的配对码将在 2 分钟后清除（若未被替换）。登录密码不包含在配对码中。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("2 · 可选：本机实验解锁") {
                    Text("在本机钥匙串保存登录密码，通过辅助功能模拟输入。密码不会发送到网络；三台密码相同，也必须分别在本机保存。")
                    Text("仅适用于已登录后的系统锁屏，不支持开机 FileVault、注销或关机。锁屏焦点切换与按键输入之间仍有竞争窗口；系统升级后必须重新验证。失败不会自动重试。")
                        .foregroundStyle(.secondary)
                    Text("第一步 · 保存这台 Mac 的登录密码").font(.headline)
                    Text(model.hasPassword ? "已保存本机密码；需要更新时可重新设置。" : "尚未保存密码。点击下方按钮，在独立安全窗口中输入并验证。")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("设置本机登录密码…") { model.promptForPassword() }
                        if model.hasPassword { Button("删除已保存密码") { model.removePassword() } }
                    }
                    Text("第二步 · 允许其他 Mac 解锁这台设备").font(.headline)
                    Toggle("允许已配对的 Mac 请求解锁本机", isOn: Binding(
                        get: { model.settings.allowRemoteUnlock },
                        set: { model.setRemoteUnlock($0) }
                    ))
                    Text(model.settings.allowRemoteUnlock
                         ? "远程解锁已开启；请从另一台已解锁的 Mac 发起认证解锁。"
                         : "远程解锁未开启。保存密码后打开开关，并在弹窗中确认；保存密码本身不会开启此功能。")
                        .font(.caption).foregroundStyle(.secondary)
                    if !model.unlockSetupStatus.isEmpty {
                        Text(model.unlockSetupStatus).font(.callout).textSelection(.enabled)
                    }
                    if !model.accessibilityGranted {
                        HStack {
                            Text("辅助功能尚未授权，暂时不能执行解锁。")
                            Button("打开授权提示") { ScreenControl.requestAccessibility() }
                        }.font(.caption)
                    }
                    Text("发起端先进行系统认证。组内设备互相信任：持有组密钥的设备具有请求控制的能力，目标无法独立证明发起端是否完成了生物认证。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
        }
    }
}


struct JoinView: View {
    @ObservedObject var model: AppModel
    @State private var host = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.hasKey ? (model.settings.isCoordinator ? "本机是主控，已有组" : "本机已有组配置") : "尚未加入组")
                .font(.headline)
            if model.settings.isCoordinator {
                Text("主控开放加入后，其他 Mac 查找本机或填写本机 IP 申请；你在这里接受即可。")
                HStack {
                    if model.settings.allowsJoining && model.hasKey {
                        Button("关闭新成员加入") { model.closeJoining() }
                    } else {
                        Button("开启发现与加入") { model.openJoining() }.buttonStyle(.borderedProminent)
                    }
                    if model.settings.allowsJoining && model.hasKey {
                        Button("重试加入服务") { model.retryJoining() }
                    }
                }
                HStack(alignment: .top) {
                    Image(systemName: model.joinListening ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .foregroundStyle(model.joinListening ? .green : .orange)
                    Text(model.joinServiceStatus).font(.callout).textSelection(.enabled)
                }
                if model.joinRequests.isEmpty {
                    Text("暂无待接受的申请。跟随端请打开“配对与解锁”→“查找主控”，也可填写主控 IP。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(model.joinRequests) { request in
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("\(request.name) 申请加入").font(.headline)
                            Text(request.address).font(.caption).foregroundStyle(.secondary)
                            Text(request.code).font(.system(size: 28, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                            Text("请核对跟随端显示的 6 位数字；一致后接受，无需输入或复制。")
                                .font(.caption)
                            HStack {
                                Button("数字一致，接受加入") { model.acceptJoin(request) }.buttonStyle(.borderedProminent)
                                Button("拒绝") { model.rejectJoin(request) }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                    }
                }
            } else {
                followerControls
                Divider()
                HStack {
                    Text("希望由这台 Mac 管理其他设备？").font(.caption).foregroundStyle(.secondary)
                    Button("设为主控并开放加入") { model.openJoining() }.disabled(model.joining)
                }
            }
            if model.settings.isCoordinator {
                DisclosureGroup("将本机改为跟随端，加入其他主控") { followerControls }
            }
        }.padding(.vertical, 6)
    }
    private var followerControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("先在主控开启发现与加入。查找会同时检查局域网发现及两台 mini 的固定 IP，也可直接输入主控 IP。")
            HStack {
                Button("查找主控") { model.findCoordinators() }.disabled(model.joining)
                Text(model.discoveryStatus).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(model.coordinators) { mac in
                HStack {
                    Image(systemName: "desktopcomputer")
                    Text(mac.name)
                    Spacer()
                    Button("申请加入") { model.beginJoin(mac.endpoint) }.disabled(model.joining)
                }
            }
            HStack {
                TextField("主控 IP 或主机名，例如 mac-mini.local", text: $host).textFieldStyle(.roundedBorder)
                    .disabled(model.joining)
                Button("通过 IP 申请加入") { model.join(host: host) }
                    .disabled(model.joining || host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if !model.joinCode.isEmpty {
                Text(model.joinCode).font(.system(size: 28, weight: .semibold, design: .monospaced)).textSelection(.enabled)
            }
            if !model.joinStatus.isEmpty {
                Text(model.joinStatus).font(.callout).textSelection(.enabled)
            }
            if model.joining { Button("取消申请") { model.cancelJoin() } }
        }
    }
}
