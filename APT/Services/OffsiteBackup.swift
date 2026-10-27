import Foundation
import SwiftData

/// 每周自动另存一份到别处：洞府设置 → 数据与备份里打开、选一个文件夹（例如 iCloud 云盘、外接硬盘）。
///
/// - 时机：沿用 `BackupService.runIfDue` 的检查（启动后片刻、运行中每 30 分钟、Mac 唤醒后）。本周（周一到周日）还没另存成功，就存一份。
/// - 内容：和“另存一份到…”完全相同（`BackupService.exportCurrent`）：数据库一致快照、.APT_SUPPORT、可读 JSON、如何恢复.txt。
/// - 位置：`<选的文件夹>/云山修习录备份/<时间>/`，只保留最近 8 份。只删自己写的：名字是“时间”格式、里面有 APT.store 的文件夹，
///   同一文件夹里手动另存的“云山修习录备份-<时间>”和别的东西一概不碰。
/// - 选的文件夹不在、不能写（外接硬盘没接上、改了名）时不弹窗打扰，只在设置那一行写“上次另存失败：原因”，下次检查再试；
///   写到一半出错的，隔 3 小时再试，免得每 30 分钟整份重做一次。
/// - 位置、上次结果都记在偏好设置里（`AppPreferences.defaults`）：调试实例（设了 APT_STORE_DIR）用自己的偏好域，
///   只会写到在调试实例里选的那个文件夹，碰不到正式应用选的位置。
@MainActor
enum OffsiteBackup {
    static let enabledKey = "backup.offsite.enabled"
    /// 选的文件夹（完整路径）
    static let pathKey = "backup.offsite.path"
    /// 上次另存成功的时刻（秒，1970 起；0 = 还没有）
    static let lastSuccessKey = "backup.offsite.lastSuccess"
    /// 上次写到一半出错的时刻（找不到文件夹这种一查就知道的不记，下次检查照常再试）
    static let lastFailureKey = "backup.offsite.lastFailure"
    /// 上次另存失败的原因；成功后清空
    static let lastErrorKey = "backup.offsite.lastError"

    nonisolated static let keep = 8
    nonisolated static let containerName = "云山修习录备份"
    /// 写到一半出错后，隔多久再整份重做
    nonisolated static let retryGap: TimeInterval = 3 * 3600

    // MARK: 纯规则

    /// 该不该存：本周还没成功过；上次写到一半出错的，隔够 retryGap 再试
    nonisolated static func isDue(lastSuccess: Date?, lastFailure: Date?, now: Date) -> Bool {
        let week = LocalDay(date: now).mondayOfWeek
        if let lastSuccess, LocalDay(date: lastSuccess).mondayOfWeek == week { return false }
        if let lastFailure, now.timeIntervalSince(lastFailure) < retryGap, now >= lastFailure { return false }
        return true
    }

    /// 是不是自己写的文件夹名：`yyyy-MM-dd_HHmmss`，同一秒重名时带 `-2`、`-3`…（与 BackupService.stamp、reserveFolder 一致）
    nonisolated static func isOwnFolderName(_ name: String) -> Bool {
        name.range(of: #"^\d{4}-\d{2}-\d{2}_\d{6}(-\d{1,3})?$"#, options: .regularExpression) != nil
    }

    /// 要清掉的：自己写的那些按名字（就是时间）从新到旧排，留最近 keep 份，其余的
    nonisolated static func namesToPrune(_ names: [String], keep: Int = keep) -> [String] {
        let own = names.filter(isOwnFolderName).sorted { order($0) > order($1) }
        return Array(own.dropFirst(keep))
    }

    /// 排序用：时间相同时 -2 比不带后缀的新，-10 比 -9 新
    nonisolated private static func order(_ name: String) -> String {
        let parts = name.split(separator: "-")
        guard parts.count == 4, let n = Int(parts[3]) else { return name + "-000" }
        return parts[0...2].joined(separator: "-") + String(format: "-%03d", n)
    }

    /// 数据文件夹本身或它里面的位置不行：数据文件夹出问题时会一起丢
    nonisolated static func isInsideDataFolder(_ url: URL, dataFolder: URL = DataStore.directory) -> Bool {
        let a = url.standardizedFileURL.resolvingSymlinksInPath().path
        let d = dataFolder.standardizedFileURL.resolvingSymlinksInPath().path
        return a == d || a.hasPrefix(d.hasSuffix("/") ? d : d + "/")
    }

    /// 设置里显示的名字：iCloud 云盘显示“iCloud 云盘”，不显示 com~apple~CloudDocs
    nonisolated static func displayName(_ path: String) -> String {
        FileManager.default.displayName(atPath: path)
    }

    // MARK: 写一份

    enum Outcome {
        case saved(URL)
        /// 一查就知道的（文件夹不在、不能写、在数据文件夹里）：不记失败时刻，下次检查照常再试
        case unavailable(String)
        /// 写到一半出错
        case failed(String)
    }

    /// 往选的文件夹里写一份：`<destination>/云山修习录备份/<时间>/`，然后清理只留最近 keep 份。
    /// 选的文件夹本身不存在时不替人建（多半是外接硬盘没接上），只建里面的“云山修习录备份”。
    static func perform(context: ModelContext, destination: URL, now: Date = Date()) -> Outcome {
        let fm = FileManager.default
        let name = displayName(destination.path)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: destination.path, isDirectory: &isDir), isDir.boolValue else {
            return .unavailable("找不到「\(name)」（外接硬盘没接上，或文件夹被移走、改了名）")
        }
        guard !isInsideDataFolder(destination) else {
            return .unavailable("「\(name)」在数据文件夹里，请换一个数据文件夹以外的位置")
        }
        let container = destination.appendingPathComponent(containerName, isDirectory: true)
        guard fm.isWritableFile(atPath: fm.fileExists(atPath: container.path) ? container.path : destination.path) else {
            return .unavailable("「\(name)」不能写入（没有权限，或是只读的）")
        }
        do {
            if !fm.fileExists(atPath: container.path) {
                try fm.createDirectory(at: container, withIntermediateDirectories: false)
            }
            let made = try BackupService.exportCurrent(context: context, to: container, now: now, namePrefix: "")
            prune(container)
            return .saved(made)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// 只删自己写的、名字匹配、里面有 APT.store 的文件夹；中途崩溃留下的自己的 .partial 过了一天也清掉
    nonisolated static func prune(_ container: URL) {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: container, includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey])) ?? []
        func isBackupFolder(_ url: URL) -> Bool {
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                && fm.fileExists(atPath: url.appendingPathComponent("APT.store").path)
        }
        let finished = items.filter { isOwnFolderName($0.lastPathComponent) && isBackupFolder($0) }
        let doomed = Set(namesToPrune(finished.map(\.lastPathComponent)))
        for url in finished where doomed.contains(url.lastPathComponent) {
            try? fm.removeItem(at: url)
        }
        let dayAgo = Date().addingTimeInterval(-86_400)
        for url in items where url.pathExtension == "partial" && isOwnFolderName(url.deletingPathExtension().lastPathComponent) {
            if let created = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate, created < dayAgo {
                try? fm.removeItem(at: url)
            }
        }
    }

    // MARK: 定时检查

    /// BackupService.runIfDue 每次检查时顺带调用：开着、选过文件夹、本周还没存过，才存一份，结果记进偏好设置
    static func runIfDue(context: ModelContext, now: Date = Date(), defaults: UserDefaults = AppPreferences.defaults) {
        guard !RenderMode.offscreen, defaults.bool(forKey: enabledKey),
              let path = defaults.string(forKey: pathKey), !path.isEmpty else { return }
        let lastSuccess = date(defaults.double(forKey: lastSuccessKey))
        let lastFailure = date(defaults.double(forKey: lastFailureKey))
        guard isDue(lastSuccess: lastSuccess, lastFailure: lastFailure, now: now) else { return }
        record(perform(context: context, destination: URL(fileURLWithPath: path, isDirectory: true), now: now), now: now, defaults: defaults)
    }

    /// 记下这次的结果：成功记时刻、清掉失败说明；失败只写原因（写到一半出错的另记时刻，隔一阵再试）
    static func record(_ outcome: Outcome, now: Date = Date(), defaults: UserDefaults = AppPreferences.defaults) {
        switch outcome {
        case .saved:
            defaults.set(now.timeIntervalSince1970, forKey: lastSuccessKey)
            defaults.removeObject(forKey: lastFailureKey)
            defaults.removeObject(forKey: lastErrorKey)
        case .unavailable(let reason):
            defaults.set(reason, forKey: lastErrorKey)
        case .failed(let reason):
            defaults.set(now.timeIntervalSince1970, forKey: lastFailureKey)
            defaults.set(reason, forKey: lastErrorKey)
        }
        if case .saved = outcome {} else { NSLog("APT 每周另存没有完成：\(defaults.string(forKey: lastErrorKey) ?? "")") }
    }

    nonisolated private static func date(_ seconds: Double) -> Date? {
        seconds > 0 ? Date(timeIntervalSince1970: seconds) : nil
    }
}
