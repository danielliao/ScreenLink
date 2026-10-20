# ScreenLink

A native macOS menu bar app for coordinating lock screens across your own Macs, with optional iPhone Bluetooth presence detection. Written in Swift, AppKit and SwiftUI; no third-party package dependencies.

轻量原生多 Mac 联动锁屏工具。选择一台主控，通过局域网管理自己的其他 Mac；可选 iPhone 蓝牙在场检测，无需安装 iPhone App。

**当前版本：0.3.0，实验阶段。** 支持 macOS 14+；当前打包脚本面向 Apple Silicon。界面以中文为主。密码输入式解锁依赖系统权限、钥匙串访问和锁屏状态，尚未完成所有机型与系统版本的验证。

## 功能

- 一键锁定组内 Mac；可选主控手动锁屏时联动。
- Bonjour 发现主控，也可填写 IP / `.local` 主机名申请加入；两端核对数字后接受。
- iPhone BLE 信号离开检测，可设置 RSSI 阈值及中断时长。
- 可选手机在场时暂缓显示器闲置休眠。
- 实验功能：在一台 Mac 完成系统认证后解锁其他 Mac；手机返回并连接后触发全部解锁。

网络接收、自动锁屏、实验解锁和在场保活默认关闭。应用不会改动系统锁屏或 FileVault 设置。

## 构建与安装

需要 macOS、Swift 5.9+，以及 Xcode 或 Command Line Tools。首次使用开发工具需按系统提示完成安装。

```bash
git clone https://github.com/danielliao/ScreenLink.git
cd ScreenLink
bash scripts/check.sh
bash scripts/build-app.sh
```

产物为 `dist/ScreenLink.app` 和 `dist/ScreenLink-0.3.0-arm64.zip`。退出旧版本后，将 App 放入 `/Applications` 再启动。

默认使用 ad-hoc 签名，**没有 Apple 公证**。来自下载的构建可能被 Gatekeeper 拦截；确认来源后，通过“系统设置 → 隐私与安全性 → 仍要打开”处理。请勿将 `codesign --verify` 成功等同于 Apple 公证。正式分发可使用自己的 Developer ID：

```bash
SCREENLINK_SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' bash scripts/build-app.sh
```

此参数仅选择签名身份；脚本不执行公证。更新签名或二进制后，系统可能要求重新授权辅助功能或钥匙串。

## 配对与锁屏

1. 选择一台经常在线的 Mac 作为主控，在“配对与解锁”点击“设为主控并开放加入”。
2. 其他 Mac 点击“查找主控”，选择并申请加入；未发现时填写主控 IP 或主机名，点击“通过 IP 申请加入”。
3. 两端比较显示的 6 位数字，主控接受后，等待双方确认完成。
4. 刷新设备状态，逐台确认在线，再测试“锁定全部”。按系统提示授予 ScreenLink 辅助功能权限。
5. 配好后可关闭新成员加入，已有组继续通信。可在系统权限区域设置登录时启动。

控制使用 TCP 45731 / `_screenlink._tcp`；加入使用 TCP 45732 / `_screenjoin._tcp`。发现仅浏览 Bonjour 和探测用户已配置的地址，不扫描网段，不内置任何私人 IP。设备需位于可互通的可信局域网，系统时间需准确。

## 手机检测与自动策略

在主控选择手机并先观察信号，再开启自动策略。BLE 名称不是设备身份，请通过真实离开/返回验证选中了自己的设备。

- 无有效信号或持续低于阈值超过 **10–180 秒**后判断离开，默认 **30 秒**。
- 可选 RSSI 阈值 **-100 至 -40 dBm**，启用时初值 **-75 dBm**。数值越接近 0，信号越强。
- 实验返回解锁要求主动连接的新 RSSI；启用阈值时须高出锁屏阈值 **5 dB**。被动广播不会触发解锁。
- 首次有效连接或离开宽限时间后返回触发一次；持续在线和短暂掉线不重复触发。应用重启后的首次有效连接也可能触发。

iPhone 后台广播和连接受系统策略影响；没有配套 iPhone App，不能承诺持续可见或可靠连接。蓝牙在场是便利性信号，并非强身份认证。先验证检测稳定性，再开启自动操作。

## 实验解锁

每台接收端分别操作：

1. 在“配对与解锁”点击“设置本机登录密码…”，在原生安全输入窗口验证并保存。
2. 开启“允许已配对的 Mac 请求解锁本机”，完成确认，并授予辅助功能权限。
3. 若系统提示 ScreenLink 访问 `local.screenlink.credentials`，在本机完成授权。需要无人值守读取时选择“始终允许”；仅本次允许可能导致下次锁屏后等待授权。
4. 从另一台已解锁的 Mac 点击“认证并解锁其他 Mac”，观察目标是否真正进入桌面。

密码只保存在各自的本机钥匙串，不通过网络或配对码传输。各台密码相同也不共享保存。手机连接解锁须在主控另行开启，且包含主控本机；无需每次人工认证，因此开启前应理解其授权范围。

**限制：**这是模拟键盘输入，不是 Apple 官方远程认证接口。不支持开机 FileVault、注销登录或关机；睡眠设备不保证可达。每轮锁屏最多尝试一次，失败后手动登录才能恢复。锁屏状态与按键之间存在竞争窗口，安全输入标志不保证密码框焦点。详见 [安全说明](SECURITY.md)。

## 排障

- **已保存密码，但只亮屏：**手动登录目标 Mac，检查是否有钥匙串授权提示；查看“最近事件”的实验解锁阶段。不要反复保存或提交密码。
- **未确认 / 连接关闭：**检查两端网络、配对及自动校时。协议允许 15 秒时间差；端口可达不等于认证成功。
- **需要辅助功能：**在系统设置中授权实际安装的 App。更换构建后可能需要重新授权。
- **没有 Dock 图标：**本项目是菜单栏应用，通过顶部菜单栏打开窗口。
- **启动被拦截：**参见 [Apple 官方说明](https://support.apple.com/en-us/102445)，保留完整提示用于排障。

只读诊断：

```bash
/Applications/ScreenLink.app/Contents/MacOS/ScreenLink --diagnose
```

## 开发与验证

```bash
bash scripts/check.sh          # 核心、网络、输入事件构造、Debug 构建、plist
bash scripts/check-prompts.sh  # 需要交互桌面：原生弹窗与密码输入控件
bash scripts/check-input.sh    # 需要交互桌面：合成 SwiftUI 输入回归
```

测试使用虚构输入，不访问真实钥匙串或向系统锁屏投递按键。[验证范围](docs/VALIDATION.md)区分自动检查与实机验收；[架构](docs/DESIGN.md)说明配对及控制协议。

配置位于 `~/Library/Application Support/ScreenLink/settings.json`；组密钥和可选密码位于本机 Keychain 的 `local.screenlink.credentials` 服务。卸载前可在 App 删除保存密码、关闭登录启动，退出后移除应用；配置和剩余钥匙串项目需自行清理。不要将配置、配对码、日志或凭据上传到公开 Issue。

## 许可证与参考

本项目采用 [MIT License](LICENSE)，版权所有者为 danielliao。

功能设计与部分系统 API 使用参考了 [BLEUnlock](https://github.com/ts1/BLEUnlock)；也调研了 [blueutil](https://github.com/toy/blueutil) 和 Apple OpenDirectory 兼容实现。没有引入其二进制、图标或第三方 Swift 包。具体来源、使用范围与上游许可见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。项目不代表这些上游项目或 Apple。
