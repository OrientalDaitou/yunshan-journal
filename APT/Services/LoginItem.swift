import AppKit
import ServiceManagement

/// 登录时自动打开（登录项）：用系统的 SMAppService.mainApp 登记 / 取消。登录时照常打开主窗口，之后关窗仍留在菜单栏。
///
/// 调试实例（设了 APT_STORE_DIR，或是从 Xcode 构建目录里跑的这一份）绝不调用 SMAppService：
/// 它和已安装的正式应用是同一个 bundle id，登记了就会把调试版的路径塞进你的登录项，取消又会把正式应用的登录项撤掉。
/// 这时开关照样能点，只记在调试实例自己的偏好里（AppPreferences），并提示“调试实例不登记登录项”。
@MainActor
enum LoginItem {
    enum Status: Equatable {
        /// 已登记：登录 Mac 时会自动打开
        case on
        /// 已登记，但要你在 系统设置 → 通用 → 登录项 里允许
        case needsApproval
        /// 没登记
        case off
        /// 登记不成（系统给的说明）
        case failed(String)

        /// 开关显示成“开”：已登记（含等你允许的）
        var isOn: Bool { self == .on || self == .needsApproval }
    }

    /// 调试实例只记开关用的偏好键
    static let debugKey = "loginItem.debug"
    static let debugNote = "调试实例不登记登录项"
    static let approvalNote = "需要在 系统设置 → 通用 → 登录项 里允许“云山修习录”"

    /// 不碰系统登录项的实例：设了调试数据目录、离屏渲染，或者这一份应用就在 Xcode 的构建目录里
    static var isDebugInstance: Bool {
        DataStore.customDirectory != nil || RenderMode.offscreen || Bundle.main.bundlePath.contains("/Build/Products/")
    }

    /// 现在的状态（调试实例读自己偏好里记的开关）
    static var status: Status {
        if isDebugInstance {
            // 离屏渲染看“要你允许”那一行：APT_RENDER_DEFAULTS="loginItem.debug=needsApproval"
            if AppPreferences.defaults.string(forKey: debugKey) == "needsApproval" { return .needsApproval }
            return AppPreferences.defaults.bool(forKey: debugKey) ? .on : .off
        }
        switch SMAppService.mainApp.status {
        case .enabled: return .on
        case .requiresApproval: return .needsApproval
        case .notRegistered, .notFound: return .off
        @unknown default: return .off
        }
    }

    /// 打开或关闭；返回之后的状态。登记失败时状态是 .failed（附系统的说明），开关应当回到关
    @discardableResult
    static func setEnabled(_ on: Bool) -> Status {
        if isDebugInstance {
            AppPreferences.defaults.set(on, forKey: debugKey)
            return on ? .on : .off
        }
        let service = SMAppService.mainApp
        do {
            if on {
                // 已经登记过（含等你允许的）不再重复登记
                if service.status != .enabled && service.status != .requiresApproval { try service.register() }
            } else if service.status == .enabled || service.status == .requiresApproval {
                try service.unregister()
            }
        } catch {
            let now = status
            // 有的系统登记成功也会抛“需要允许”：这时状态已是 needsApproval，照实返回
            if on && now.isOn { return now }
            if !on && now == .off { return now }
            return .failed(error.localizedDescription)
        }
        return status
    }

    /// 打开 系统设置 → 通用 → 登录项（调试实例不调 SMAppService，改用系统设置的链接）
    static func openSettings() {
        if isDebugInstance {
            if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") { NSWorkspace.shared.open(url) }
            return
        }
        SMAppService.openSystemSettingsLoginItems()
    }
}
