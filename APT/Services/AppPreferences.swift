import Foundation
import CryptoKit

/// 偏好设置（外观、各处草稿、设置组的展开状态、历史最高境界……）统一从这里取。
///
/// @AppStorage 读写的是 `.defaultAppStorage` 注入的那一份：APTApp 给主窗口、菜单栏随手记注入，随手记浮窗自己注入；
/// 直接读写偏好的地方（修订草稿、落笔草稿 JournalDraft、月末备注 ReflectionDrafts、热键提示等）也要用 `AppPreferences.defaults`，不要再直接写 `UserDefaults.standard`。
///
/// - 正式使用（没设 APT_STORE_DIR）：就是 `UserDefaults.standard`，和以前完全一样，已有的偏好一个不丢。
/// - 调试实例（设了 APT_STORE_DIR）：改用独立的偏好域 `io.github.orientaldaitou.yunshan.dev.<数据目录路径的哈希>`。
///   调试版和已安装版是同一个 bundle id，用 .standard 会写进同一个 plist：历史最高境界、修订草稿、月末备注、随手记草稿都会串过去。
///   同一个数据目录每次打开都是同一个域（草稿、展开状态照常记得），换一个目录就是另一套。
/// - 离屏渲染（--render-pages）：用 PageRenderer 按进程号命名、渲染完整个清掉的临时域（套件名相同，同一进程里读写的是同一份）。
///
/// 第一次用到时定下，之后整个进程都用这一个（图形界面启动时 APT_STORE_DIR 不会变）。
enum AppPreferences {
    static let defaults: UserDefaults = {
        guard let suite = suiteName else { return .standard }
        // 套件名与应用的 bundle id 不同，系统一定会给出这个独立的偏好域
        return UserDefaults(suiteName: suite)!
    }()

    /// 独立偏好域的套件名；正式使用时为 nil（用 .standard）
    static var suiteName: String? {
        if RenderMode.offscreen { return renderSuiteName }
        guard let directory = DataStore.customDirectory else { return nil }
        return devSuiteName(for: directory)
    }

    /// 调试数据目录对应的套件名。路径先规范化（去掉末尾的 /、. 和 ..），同一个文件夹每次得到同一个名字；
    /// 不用 Swift 的 hashValue（每次启动都不一样）
    static func devSuiteName(for directory: URL) -> String {
        let digest = SHA256.hash(data: Data(directory.standardizedFileURL.path.utf8))
        return "io.github.orientaldaitou.yunshan.dev." + digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// 离屏渲染的临时域（PageRenderer.defaultsSuite 直接用它，渲染完整个清掉）
    static var renderSuiteName: String { "io.github.orientaldaitou.yunshan.render.\(ProcessInfo.processInfo.processIdentifier)" }
}
