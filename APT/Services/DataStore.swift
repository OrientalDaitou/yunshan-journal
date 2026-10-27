import Foundation
import SwiftData
import CoreData

enum DataStore {
    /// 调试 / 自检用的数据目录：环境变量 APT_STORE_DIR，没设时为 nil。
    /// 每次都现读：自检与离屏渲染会在运行中把它指到临时目录（见 SelfTest.isolateDataDirectory）。
    static var customDirectory: URL? {
        guard let path = ProcessInfo.processInfo.environment["APT_STORE_DIR"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// 新版数据位置：~/Library/Application Support/APT-SwiftUI/APT.store
    /// 调试时可用环境变量 APT_STORE_DIR 指向别的文件夹，不碰正式数据。
    static var directory: URL {
        if let custom = customDirectory { return custom }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("APT-SwiftUI", isDirectory: true)
    }

    static var storeURL: URL { directory.appendingPathComponent("APT.store") }

    /// 打开数据库。打开正式库（非内存）之前先留保险副本（见 backupBeforeUpgradeIfNeeded）：
    /// 模型改了字段时，SwiftData 会在打开的那一刻原地迁移，迁移前必须有一份当场的副本。
    static func makeContainer(inMemory: Bool = false, backupBeforeUpgrade: Bool = true) throws -> ModelContainer {
        let schema = Schema(APTSchema.models)
        let configuration: ModelConfiguration
        if inMemory {
            configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        } else {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if backupBeforeUpgrade { backupBeforeUpgradeIfNeeded() }
            configuration = ModelConfiguration(schema: schema, url: storeURL)
        }
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    // MARK: 升级前备份

    /// 上次打开数据库的应用构建，记在数据目录里的一个小文件
    static var buildStampURL: URL { directory.appendingPathComponent(".last-opened-build") }

    /// 本次运行的应用构建：版本号 + 构建号 + 可执行文件的修改时间（每次重新编译都会变）
    static var currentBuildStamp: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = "\(info["CFBundleShortVersionString"] ?? "?") (\(info["CFBundleVersion"] ?? "?"))"
        var built = "?"
        if let executable = Bundle.main.executableURL,
           let date = (try? executable.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
            built = String(Int(date.timeIntervalSince1970))
        }
        return "\(version) \(built)"
    }

    /// 上一次做“迁移前”备份时的应用构建：同一构建只做一次（例如迁移失败、反复重开时不会每次都多留一份）
    static var migrationBackupStampURL: URL { directory.appendingPathComponent(".last-migration-backup") }

    /// 现有数据库是否要迁移才能用这一版的模型打开：Core Data 自带的兼容性检查（比较库里记下的各实体结构哈希），
    /// 比按构建判断准——重新编译不会误报，旧版应用把库降回旧结构后再用新版打开也认得出来。
    /// 还没有数据库、或读不出库的结构信息时返回 nil（不知道）。
    static func storeNeedsMigration(at url: URL = storeURL) -> Bool? {
        guard FileManager.default.fileExists(atPath: url.path),
              let model = NSManagedObjectModel.makeManagedObjectModel(for: APTSchema.models) else { return nil }
        do {
            let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(type: .sqlite, at: url)
            return !model.isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata)
        } catch {
            NSLog("APT 读不出数据库的结构信息：\(error)")
            return nil
        }
    }

    /// 打开数据库之前的保险副本，成功后才记下新构建；备份失败时照常打开，下次启动再试。
    /// - 这一版的模型和库里的结构对不上（打开时会原地迁移）：留一份“迁移前-<时间>”，不参与轮换、不自动删除，
    ///   免得之后几次重新编译、换着打开就把唯一一份旧结构的副本挤掉；同一构建只留一次。
    /// - 只是应用构建变了（版本号、重新编译）：留一份“升级前-<时间>”，只保留最近 3 份。
    /// needsMigration 为 nil 时自己检查（自检里可以直接指定）。
    @discardableResult
    static func backupBeforeUpgradeIfNeeded(stamp: String = currentBuildStamp, now: Date = Date(), needsMigration: Bool? = nil) -> URL? {
        let fm = FileManager.default
        func read(_ url: URL) -> String? { (try? String(contentsOf: url, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) }
        let previous = read(buildStampURL)
        let migrating = (needsMigration ?? storeNeedsMigration() ?? false) && read(migrationBackupStampURL) != stamp
        guard migrating || previous != stamp else { return nil }
        var made: URL?
        if fm.fileExists(atPath: storeURL.path) {
            let kind: BackupService.Kind = migrating ? .preMigration : .preUpgrade
            var reserved: (created: URL, final: URL)?
            do {
                try fm.createDirectory(at: BackupService.root, withIntermediateDirectories: true)
                let slot = try BackupService.reserveFolder(in: BackupService.root, base: kind.rawValue + "-" + BackupService.stamp(now))
                reserved = slot
                try BackupService.snapshotStore(into: slot.created)
                let note = migrating ? """
                这一版（\(stamp)）的数据结构和库里的不同，数据库会在打开的那一刻原地迁移；这是迁移之前的原样副本。
                上次打开数据库的版本：\(previous ?? "未知")。万一迁移出了问题，可以从这一份恢复。
                “迁移前”备份不会自动删除；确认新版本一切正常后，可以自己删掉较早的几份。
                """ : """
                打开新版本（\(stamp)）之前自动留的数据库副本；上次打开数据库的版本：\(previous ?? "未知")。
                万一新版本用起来出了问题，可以从这一份恢复。“升级前”备份只保留最近 \(BackupService.upgradeKeep) 份。
                """
                try? note.write(to: slot.created.appendingPathComponent("说明.txt"), atomically: true, encoding: .utf8)
                BackupService.writeHowTo(in: slot.created)
                try fm.moveItem(at: slot.created, to: slot.final)
                made = slot.final
            } catch {
                if let reserved { try? fm.removeItem(at: reserved.created) }
                NSLog("APT \(kind.label)备份失败：\(error)")
                return nil
            }
            if migrating {
                try? (stamp + "\n").write(to: migrationBackupStampURL, atomically: true, encoding: .utf8)
            } else {
                pruneUpgradeBackups(keeping: made)
            }
        }
        try? (stamp + "\n").write(to: buildStampURL, atomically: true, encoding: .utf8)
        return made
    }

    /// “升级前”备份只保留最近 3 份（“迁移前”不在其中，不会被挤掉）。
    /// 按文件夹的创建时间排（BackupService.list() 已排好），不按名字：名字里是本地时间，改了时区、夏令时回拨后，
    /// 新做的那份名字反而“小”，会被当成最旧的当场删掉。刚做好的那份（keeping）无论如何都留下：
    /// 系统时钟被往回拨过时，它的创建时间也可能比旧的早。
    static func pruneUpgradeBackups(keeping newest: URL? = nil) {
        let others = BackupService.list().filter { info in
            info.kind == .preUpgrade && !(newest.map { BackupService.sameFolder($0, info.url) } ?? false)
        }
        let keep = BackupService.upgradeKeep - (newest == nil ? 0 : 1)
        for old in others.dropFirst(max(keep, 0)) { try? FileManager.default.removeItem(at: old.url) }
    }

    // MARK: 错误说明

    /// 数据库打不开时给人看的原因：除了笼统的 localizedDescription，再展开底层错误（例如迁移失败的 134110 / 134140）。
    static func describe(_ error: Error) -> String {
        var lines = [error.localizedDescription]
        var current: NSError? = error as NSError
        var depth = 0
        while let ns = current, depth < 4 {
            let summary = "\(ns.domain) \(ns.code)"
            if !lines.contains(where: { $0.contains(summary) }) {
                var line = summary
                if let reason = ns.userInfo[NSLocalizedFailureReasonErrorKey] as? String { line += "：\(reason)" }
                else if let reason = ns.userInfo["reason"] as? String { line += "：\(reason)" }
                lines.append(line)
            }
            current = ns.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        let detail = String(describing: error)
        if !lines.contains(detail), detail.count < 600 { lines.append(detail) }
        return lines.joined(separator: "\n")
    }

    @discardableResult
    static func settings(in context: ModelContext) -> AppSettings {
        if let existing = try? context.fetch(FetchDescriptor<AppSettings>()).first { return existing }
        let created = AppSettings()
        context.insert(created)
        return created
    }

    @discardableResult
    static func profile(in context: ModelContext) -> Profile {
        let descriptor = FetchDescriptor<Profile>(sortBy: [SortDescriptor(\.createdAt)])
        if let existing = try? context.fetch(descriptor).first { return existing }
        let created = Profile()
        context.insert(created)
        return created
    }

    static func save(_ context: ModelContext) {
        do { try context.save() } catch { NSLog("APT 保存失败：\(error)") }
    }
}

extension ModelContext {
    func all<T: PersistentModel>(_ type: T.Type) -> [T] { (try? fetch(FetchDescriptor<T>())) ?? [] }

    /// 全部习惯：与 `all(Habit.self)` 是同样的对象、同样的次序，但只取 ID、再从 context 里拿已登记的对象，
    /// 不把习惯本身重新取一遍。SwiftData 里重新取一次习惯（all / fetch / @Query）会让这些习惯的打卡关系变“冷”，
    /// 之后再读 `habit.logs` 要把打卡逐条从库里补回来（5 年数据全部习惯约 1.3 秒）；只取 ID 不会（见 CultivationModel 的说明）。
    /// 有未保存的改动时照原来整取：未保存的新增在两种取法里排的位置不同（按名称匹配习惯时次序有影响）。取 ID 出错时同样整取。
    func allHabits() -> [Habit] {
        guard !hasChanges, let ids = try? fetchIdentifiers(FetchDescriptor<Habit>()) else { return all(Habit.self) }
        return ids.compactMap { model(for: $0) as? Habit }
    }
}
