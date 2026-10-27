import Foundation
import SwiftData
import SQLite3

/// 自动备份：每天第一次打开（以及运行中每 30 分钟检查一次、Mac 唤醒后再查一次）在 `APT-SwiftUI/Backups/` 下留一份完整副本。
///
/// 每份备份是一个文件夹：
/// - `APT.store`       用 SQLite 在线备份接口拷出的一致快照（不受正在写入的 WAL 影响）
/// - `.APT_SUPPORT/`   SwiftData 外置存放的大字段（灵石账簿整本账就在这里）
/// - `APT-完整备份.json` 人能读的完整导出，换电脑或出问题时也能看懂（导出失败时改留一份“JSON导出失败.txt”，不影响数据库快照）
/// - `如何恢复.txt`
///
/// 先写进 `<名字>.partial` 临时文件夹，全部成功后才改成正式名字：中途崩溃只会留下 .partial（不算备份、下次启动清掉），
/// 同一秒内连做两份也会各自得到不同的名字，绝不互相删除。
///
/// 保留最近 14 份每日备份、8 份每周备份、所有手动备份；升级到新版本前自动留的“升级前”备份保留 3 份；
/// 新版本改了数据结构、打开时要迁移数据库之前留的“迁移前”备份不自动删除；
/// 从备份恢复时，恢复前的数据整体移到“恢复前-<时间>”，不自动删除。
/// 恢复：设置 → 数据与备份 → 从备份恢复（应用会在下次启动、打开数据库之前完成替换）。
@MainActor
enum BackupService {
    nonisolated static var root: URL { DataStore.directory.appendingPathComponent("Backups", isDirectory: true) }
    static let dailyKeep = 14
    static let weeklyKeep = 8
    nonisolated static let upgradeKeep = 3

    /// daily / weekly / manual 放在同名子文件夹里；升级前、迁移前、恢复前直接放在 Backups/ 下，文件夹名以中文前缀开头
    enum Kind: String {
        case daily, weekly, manual
        case preUpgrade = "升级前"
        case preMigration = "迁移前"
        case preRestore = "恢复前"

        var label: String {
            switch self {
            case .daily: "每日"
            case .weekly: "每周"
            case .manual: "手动"
            case .preUpgrade: "升级前"
            case .preMigration: "迁移前"
            case .preRestore: "恢复前"
            }
        }

        /// 定期或手动做的、内容就是“当时的数据”的备份（升级前、迁移前、恢复前是特殊时刻留的保险）
        var isRoutine: Bool { self == .daily || self == .weekly || self == .manual }
    }

    struct Info: Identifiable {
        var url: URL
        var date: Date
        var kind: Kind
        var id: String { url.path }
    }

    enum BackupError: LocalizedError {
        case sqlite(String)
        case invalidBackup(String)
        /// 恢复过程中某一步做不下去（说明原样给人看）
        case restoreStep(String)
        var errorDescription: String? {
            switch self {
            case .sqlite(let message): "备份数据库失败：\(message)"
            case .invalidBackup(let message): "这份备份不能用来恢复：\(message)"
            case .restoreStep(let message): message
            }
        }
    }

    /// 数据目录里与数据库一起搬动的文件（恢复时整体移走、整体换上）
    nonisolated static let storeItems = ["APT.store", "APT.store-wal", "APT.store-shm", ".APT_SUPPORT"]

    // MARK: 自动备份

    /// 今天还没有每日备份就做一份；本周（周一到周日）还没有每周备份就再留一份；然后清理过旧的。
    @discardableResult
    /// offsiteDefaults：每周另存读写的偏好域，只有自检会换成临时的。
    static func runIfDue(context: ModelContext, now: Date = Date(), offsiteDefaults: UserDefaults = AppPreferences.defaults) -> URL? {
        // 打开了“每周自动另存一份到…”时：本周还没另存过就往选的文件夹里存一份（没打开、本周已存过时什么都不做）。
        // 放在 defer 里：每日备份出错提前返回时也照样另存——数据所在的盘出问题时，最需要往另一块盘存一份
        defer { OffsiteBackup.runIfDue(context: context, now: now, defaults: offsiteDefaults) }
        let today = LocalDay(date: now)
        var existing = list()
        var made: URL?
        if !existing.contains(where: { $0.kind == .daily && LocalDay(date: $0.date) == today }) {
            do {
                made = try backup(context: context, kind: .daily, now: now)
            } catch {
                NSLog("APT 自动备份失败：\(error)")
                return nil
            }
            existing = list()
        }
        let monday = today.mondayOfWeek
        if !existing.contains(where: { $0.kind == .weekly && LocalDay(date: $0.date).mondayOfWeek == monday }) {
            do { try backup(context: context, kind: .weekly, now: now) } catch { NSLog("APT 每周备份失败：\(error)") }
        }
        prune()
        return made
    }

    /// 做一份备份，返回备份文件夹。
    @discardableResult
    static func backup(context: ModelContext, kind: Kind, now: Date = Date()) throws -> URL {
        if context.hasChanges { DataStore.save(context) }
        let fm = FileManager.default
        let parent = folder(for: kind)
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let prefix = kind.isRoutine ? "" : kind.rawValue + "-"
        let (partial, final) = try reserveFolder(in: parent, base: prefix + stamp(now))
        do {
            try writeContents(into: partial, context: context)
            try fm.moveItem(at: partial, to: final)
        } catch {
            try? fm.removeItem(at: partial)   // 只删本次新建的临时文件夹
            throw error
        }
        return final
    }

    /// 往一个空文件夹里写一份完整备份：数据库快照（失败就抛错）、可读 JSON、恢复说明。
    /// outside：这份存在数据文件夹以外（另存、每周另存），恢复说明改成手动步骤（应用的恢复列表里没有它）。
    private static func writeContents(into folder: URL, context: ModelContext, outside: Bool = false) throws {
        try snapshotStore(into: folder)
        // 可读 JSON 是锦上添花：失败只留说明，不影响已经拷好的数据库快照
        do {
            let json = try DataExporter.fullExport(context: context)
            try json.write(to: folder.appendingPathComponent("APT-完整备份.json"), options: .atomic)
        } catch {
            NSLog("APT 备份里的 JSON 导出失败：\(error)")
            try? "这份备份的数据库快照（APT.store 与 .APT_SUPPORT）完好，只有可读 JSON 没能导出：\n\(error.localizedDescription)\n"
                .write(to: folder.appendingPathComponent("JSON导出失败.txt"), atomically: true, encoding: .utf8)
        }
        writeHowTo(in: folder, outside: outside)
    }

    /// 把数据目录里的数据库拷进一个空文件夹：SQLite 在线备份 + 外置大字段。
    nonisolated static func snapshotStore(from directory: URL = DataStore.directory, into folder: URL) throws {
        let fm = FileManager.default
        try sqliteBackup(from: directory.appendingPathComponent("APT.store"), to: folder.appendingPathComponent("APT.store"))
        let support = directory.appendingPathComponent(".APT_SUPPORT", isDirectory: true)
        if fm.fileExists(atPath: support.path) {
            try fm.copyItem(at: support, to: folder.appendingPathComponent(".APT_SUPPORT", isDirectory: true))
        }
    }

    /// SQLite 在线备份：即使数据库正被应用打开、有未合并的 WAL，也能拷出一致的快照。
    /// 先以只读方式打开源库；WAL 模式的库旁边没有 -wal / -shm 时（例如刚从备份恢复、应用还没打开过）只读打不开，
    /// 这时改用读写方式再试一次（只会在旁边建出空的 -wal / -shm，不改动数据）。
    nonisolated static func sqliteBackup(from source: URL, to target: URL) throws {
        let step = try sqliteBackupOnce(from: source, to: target, flags: SQLITE_OPEN_READONLY)
        if step == SQLITE_DONE { return }
        if step == SQLITE_CANTOPEN, try sqliteBackupOnce(from: source, to: target, flags: SQLITE_OPEN_READWRITE) == SQLITE_DONE { return }
        throw BackupError.sqlite("代码 \(step)")
    }

    nonisolated private static func sqliteBackupOnce(from source: URL, to target: URL, flags: Int32) throws -> Int32 {
        var src: OpaquePointer?, dst: OpaquePointer?
        defer {
            if let src { sqlite3_close(src) }
            if let dst { sqlite3_close(dst) }
        }
        guard sqlite3_open_v2(source.path, &src, flags, nil) == SQLITE_OK, let src else {
            throw BackupError.sqlite("无法打开 \(source.lastPathComponent)")
        }
        guard sqlite3_open_v2(target.path, &dst, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK, let dst else {
            throw BackupError.sqlite("无法创建 \(target.lastPathComponent)")
        }
        guard let backup = sqlite3_backup_init(dst, "main", src, "main") else {
            throw BackupError.sqlite(String(cString: sqlite3_errmsg(dst)))
        }
        let step = sqlite3_backup_step(backup, -1)
        sqlite3_backup_finish(backup)
        return step
    }

    // MARK: 列表与清理

    /// 全部备份，按文件夹的创建时间从新到旧（只读文件系统，DataStore 打开数据库前清理“升级前”时也用它）
    nonisolated static func list() -> [Info] {
        let fm = FileManager.default
        var result: [Info] = []
        func add(_ url: URL, _ kind: Kind) {
            guard url.pathExtension != "partial", fm.fileExists(atPath: url.appendingPathComponent("APT.store").path) else { return }
            let date = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            result.append(Info(url: url, date: date, kind: kind))
        }
        for kind in [Kind.daily, .weekly, .manual] {
            let items = (try? fm.contentsOfDirectory(at: folder(for: kind), includingPropertiesForKeys: [.creationDateKey])) ?? []
            items.forEach { add($0, kind) }
        }
        let flat = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey])) ?? []
        for url in flat {
            let name = url.lastPathComponent
            if name.hasPrefix(Kind.preUpgrade.rawValue + "-") { add(url, .preUpgrade) }
            else if name.hasPrefix(Kind.preMigration.rawValue + "-") { add(url, .preMigration) }
            else if name.hasPrefix(Kind.preRestore.rawValue + "-") { add(url, .preRestore) }
        }
        return result.sorted { $0.date > $1.date }
    }

    /// 只清理每日、每周备份；手动备份、“迁移前”与“恢复前”的数据永不自动删除（“升级前”由 DataStore 按 3 份保留）。
    static func prune() {
        let all = list()
        for (kind, keep) in [(Kind.daily, dailyKeep), (.weekly, weeklyKeep)] {
            for old in all.filter({ $0.kind == kind }).dropFirst(keep) {
                try? FileManager.default.removeItem(at: old.url)
            }
        }
    }

    /// 启动时清掉上次中途崩溃留下的半份备份（.partial）与恢复用的临时文件夹。
    nonisolated static func cleanupLeftovers() {
        let fm = FileManager.default
        var dirs = [root]
        dirs += [Kind.daily, .weekly, .manual].map { root.appendingPathComponent($0.rawValue, isDirectory: true) }
        for dir in dirs {
            for url in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where url.pathExtension == "partial" {
                try? fm.removeItem(at: url)
            }
        }
        for url in (try? fm.contentsOfDirectory(at: DataStore.directory, includingPropertiesForKeys: nil)) ?? []
        where url.lastPathComponent.hasPrefix(".restore-staging-") {
            try? fm.removeItem(at: url)
        }
    }

    // MARK: 另存一份到别处

    /// 把此刻的数据直接备份到别的文件夹（例如 iCloud 云盘、外接硬盘），返回写出的文件夹。
    /// 和自动备份一样先写进目标位置的 `<名字>.partial`，全部成功才改成正式名字；数据文件夹里不多留一份。
    /// 文件夹名是 `<namePrefix><时间>`：手动另存为“云山修习录备份-<时间>”，每周自动另存（OffsiteBackup）只用“<时间>”。
    static func exportCurrent(context: ModelContext, to destination: URL, now: Date = Date(),
                              namePrefix: String = "云山修习录备份-") throws -> URL {
        if context.hasChanges { DataStore.save(context) }
        let fm = FileManager.default
        let (partial, final) = try reserveFolder(in: destination, base: namePrefix + stamp(now))
        do {
            try writeContents(into: partial, context: context, outside: true)
            try fm.moveItem(at: partial, to: final)
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
        return final
    }

    // MARK: 从备份恢复

    /// 待恢复标记：设置里选了“从此备份恢复”后写入；下次启动在打开数据库之前处理
    nonisolated static var restoreRequestURL: URL { DataStore.directory.appendingPathComponent("restore-request.json") }

    struct RestoreOutcome {
        var succeeded: Bool
        var message: String
        /// 恢复没完成、原数据还有一部分留在这个“恢复前”文件夹里没能放回：APTApp 见到它就不打开数据库，
        /// 免得 SwiftData 在原位置新建空库（或打开缺了账簿的库），让人在里面继续记录
        var dataLeftAside: URL? = nil
        /// 选了“放回原数据，取消这次恢复”且原数据已全部放回（弹窗标题写“已放回原数据”，不写“没有完成恢复”）
        var cancelled = false
    }

    /// 启动时处理的结果（APTApp 写入，主窗口或错误页显示一次）
    static var lastRestoreOutcome: RestoreOutcome?

    /// 已安排、尚未执行的恢复：返回那份备份的位置
    static var pendingRestore: URL? {
        guard let data = try? Data(contentsOf: restoreRequestURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = object["backup"] as? String else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// 安排一次恢复：先确认备份能打开，再写下“待恢复”标记。真正的替换在下次启动、打开数据库之前进行。
    /// 上一次恢复做到一半没完成（标记里记着“恢复前”文件夹）时保留这部分记录：换一份备份恢复，原数据也接着移进同一个文件夹。
    /// 选的正是那个存放原数据的“恢复前”文件夹时，下次启动只把原数据放回原处（相当于取消那次恢复）：
    /// 里面可能只剩一部分原数据，不按完整备份检查。
    static func requestRestore(from backup: URL) throws {
        var previous: [String: Any]?
        if let data = try? Data(contentsOf: restoreRequestURL) {
            previous = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
        let puttingBack = (previous?["aside"] as? String).map { sameFolder(URL(fileURLWithPath: $0, isDirectory: true), backup) } ?? false
        if !puttingBack { try validate(backup) }
        try FileManager.default.createDirectory(at: DataStore.directory, withIntermediateDirectories: true)
        var object: [String: Any] = ["backup": backup.path, "requested_at": ISO8601DateFormatter().string(from: Date())]
        if let previous {
            for key in ["aside", "phase"] { if let value = previous[key] { object[key] = value } }
        }
        try writeRestoreMarker(object)
    }

    /// 两个位置是不是同一个文件夹（不计较末尾的 /、符号链接等写法上的差别）
    nonisolated static func sameFolder(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.resolvingSymlinksInPath().path == b.standardizedFileURL.resolvingSymlinksInPath().path
    }

    nonisolated private static func writeRestoreMarker(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])
        try data.write(to: restoreRequestURL, options: .atomic)
    }

    static func cancelRestoreRequest() {
        try? FileManager.default.removeItem(at: restoreRequestURL)
    }

    /// 备份是否完整可用：有 APT.store，且 SQLite 自检通过。
    nonisolated static func validate(_ backup: URL) throws {
        let store = backup.appendingPathComponent("APT.store")
        guard FileManager.default.fileExists(atPath: store.path) else { throw BackupError.invalidBackup("里面没有 APT.store") }
        guard backup.standardizedFileURL.path != DataStore.directory.standardizedFileURL.path else {
            throw BackupError.invalidBackup("不能选数据文件夹本身")
        }
        // immutable=1：只检查主文件本身，不碰、也不需要旁边的 -wal / -shm（备份里通常没有它们，只读方式会打不开）
        var components = URLComponents()
        components.scheme = "file"
        components.path = store.path
        components.queryItems = [URLQueryItem(name: "immutable", value: "1")]
        var db: OpaquePointer?
        defer { if let db { sqlite3_close(db) } }
        guard let uri = components.string,
              sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK, let db else {
            throw BackupError.invalidBackup("APT.store 打不开")
        }
        var statement: OpaquePointer?
        defer { if let statement { sqlite3_finalize(statement) } }
        guard sqlite3_prepare_v2(db, "PRAGMA quick_check", -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW,
              let text = sqlite3_column_text(statement, 0), String(cString: text) == "ok" else {
            throw BackupError.invalidBackup("APT.store 自检没有通过（文件可能已损坏）")
        }
    }

    /// 启动时、打开数据库之前调用：有“待恢复”标记就执行恢复。
    ///
    /// 顺序保证任何一步失败都不丢现有数据：
    /// 1. 先把备份拷进数据目录里的临时文件夹（失败：现有数据完全没动）；
    /// 2. 把现有的 APT.store、-wal、-shm、.APT_SUPPORT 整体移到 `Backups/恢复前-<时间>/`；
    /// 3. 把临时文件夹里的备份移到位。
    /// 第 2、3 步出错时挪开已换上的备份副本、把原数据逐个移回，提示按真实结果说明。
    /// 动手移之前先把“恢复前”文件夹和进行到哪一步写进标记：中途断电、崩溃时标记还在，下次启动接着往同一个文件夹里移，
    /// 原数据不会被拆进两个文件夹。原数据始终只“移动”、从不删除；数据目录里的东西也一样不删
    /// （换上一半的备份副本挪进“恢复前”里的子文件夹，万一认错了也还在）。
    /// 标记里的 phase：moving = 数据目录里的是原数据（还没移完，或正在移回）；placing = 原数据都已移开，数据目录里只可能是备份副本。
    /// 选的备份就是标记里的“恢复前”文件夹（错误页上的“放回原数据”）时不换备份，只把原数据放回原处。
    /// 无论成败都会移走标记，避免每次启动都重试；只有原数据还有一部分留在“恢复前”、没能放回时保留它（下次启动再试），
    /// 并在结果里给出 dataLeftAside，让 APTApp 这次不打开数据库。
    nonisolated static func applyPendingRestoreIfNeeded() -> RestoreOutcome? {
        let fm = FileManager.default
        let marker = restoreRequestURL
        guard let data = try? Data(contentsOf: marker) else { return nil }
        var keepMarker = false
        defer { if !keepMarker { try? fm.removeItem(at: marker) } }
        guard var request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = request["backup"] as? String else {
            return RestoreOutcome(succeeded: false, message: "恢复请求文件已损坏，没有执行恢复；现有数据没有任何改动。")
        }
        let backup = URL(fileURLWithPath: path, isDirectory: true)
        let name = backup.lastPathComponent
        let dir = DataStore.directory
        func exists(_ folder: URL, _ item: String) -> Bool { fm.fileExists(atPath: folder.appendingPathComponent(item).path) }

        // 上次恢复做到一半就中断了（断电、崩溃）：标记里记着当时的“恢复前”文件夹，原数据有一部分或全部已经在里面
        var aside = (request["aside"] as? String).map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let recorded = aside, !fm.fileExists(atPath: recorded.path) { aside = nil }
        /// 已经移进“恢复前”文件夹的原数据
        var moved = aside.map { folder in storeItems.filter { exists(folder, $0) } } ?? []
        /// 原数据已经全部移开（第 2 步做完）：数据目录里的 APT.store 等只可能是换上（一半）的备份副本
        var allAside = aside != nil && request["phase"] as? String == "placing"

        /// 把“恢复前”文件夹和进行到哪一步记进标记
        func record(_ phase: String) throws {
            guard let aside else { return }
            request["aside"] = aside.path
            request["phase"] = phase
            try writeRestoreMarker(request)
        }
        func removeIfEmpty(_ folder: URL) {
            if (try? fm.contentsOfDirectory(atPath: folder.path))?.isEmpty == true { try? fm.removeItem(at: folder) }
        }
        /// 挪开的备份副本放在哪（给人看的说明里提一句）
        var copiesHolder: URL?
        /// 原数据都已移开（placing）时，数据目录里还有的只是上次中断时换上一半的备份副本。
        /// 不删：挪进“恢复前”文件夹里的一个子文件夹，万一认错了（例如有人照着说明把原数据拖回了数据文件夹）也还在。
        /// 返回是否都挪走了。
        func setAsideCopies() -> Bool {
            let copies = storeItems.filter { exists(dir, $0) }
            guard !copies.isEmpty else { return true }
            guard let aside else { return false }
            let holder = uniqueURL(in: aside, base: "中断时换上一半的备份副本")
            do { try fm.createDirectory(at: holder, withIntermediateDirectories: true) } catch { return false }
            var cleared = true
            for item in copies {
                do { try fm.moveItem(at: dir.appendingPathComponent(item), to: holder.appendingPathComponent(item)) } catch { cleared = false }
            }
            removeIfEmpty(holder)
            if fm.fileExists(atPath: holder.path) { copiesHolder = holder }
            return cleared
        }
        /// 挪开过数据目录里的东西时，补在说明后面的一句
        func holderNote() -> String {
            guard let copiesHolder else { return "" }
            return "数据文件夹里还有上次中断时没换完的备份副本，已挪到 Backups/\(copiesHolder.deletingLastPathComponent().lastPathComponent)/\(copiesHolder.lastPathComponent)/（没有删除）；确认用不着后可以自己删掉。"
        }
        /// 没能完成恢复：先挪开已换上的备份副本，再把原数据放回原处；副本挪不走时一样都不放回，免得原数据和副本混在一起。
        /// 返回给人看的说明，以及（还有原数据没能放回时）它们所在的文件夹。
        func putBack() -> (note: String, leftAside: URL?) {
            /// 副本都挪走了、标记也改回了 moving，才能往数据目录里移回原数据
            var mayMoveBack = true
            if allAside { mayMoveBack = setAsideCopies() }
            guard let aside else { return ("现有数据没有任何改动。", nil) }
            guard !moved.isEmpty else {
                removeIfEmpty(aside)
                return ("现有数据没有任何改动。" + holderNote(), nil)
            }
            // 要往数据目录里移回原数据了：先把标记改回 moving（数据目录里的是原数据）。否则移回一半时断电，
            // 下次启动仍按 placing 把已经移回的原数据当成备份副本挪开。标记写不进去就一样都不移回，原数据全留在“恢复前”里
            if allAside && mayMoveBack {
                do {
                    try record("moving")
                    allAside = false
                } catch {
                    mayMoveBack = false
                }
            }
            var stillAside: [String] = []
            for item in moved {
                guard mayMoveBack else { stillAside.append(item); continue }
                do { try fm.moveItem(at: aside.appendingPathComponent(item), to: dir.appendingPathComponent(item)) } catch { stillAside.append(item) }
            }
            // -shm 只是 WAL 的索引缓存，打开数据库时会重建，留在外面不要紧
            let missing = stillAside.filter { $0 != "APT.store-shm" }
            if missing.isEmpty {
                try? fm.removeItem(at: aside.appendingPathComponent("APT.store-shm"))
                removeIfEmpty(aside)
                return ("原数据已全部放回原处。" + holderNote(), nil)
            }
            moved = stillAside
            try? record(allAside ? "placing" : "moving")
            keepMarker = true
            return ("原数据还有一部分（\(missing.joined(separator: "、"))）留在 \(aside.path)，没能放回数据文件夹。为免在不完整的数据里继续记录，这次没有打开数据库；下次打开应用时会再试一次完成这次恢复（原数据仍只移动、不删除）。" + holderNote(), aside)
        }

        // 选的就是存放原数据的这个“恢复前”文件夹（错误页上的“放回原数据”）：不换备份，只把原数据放回原处，相当于取消这次恢复。
        // 不能当普通备份来恢复：里面可能只有一部分原数据（其余已经放回数据目录），换上去的库会缺 .APT_SUPPORT 或 -wal
        if let aside, sameFolder(aside, backup) {
            let back = putBack()
            return RestoreOutcome(succeeded: false, message: "没有换上备份，已取消这次恢复。\(back.note)", dataLeftAside: back.leftAside,
                                  cancelled: back.leftAside == nil)
        }

        do { try validate(backup) } catch {
            let back = putBack()
            return RestoreOutcome(succeeded: false, message: "没有从「\(name)」恢复：\(error.localizedDescription)。\(back.note)", dataLeftAside: back.leftAside)
        }
        // -shm 只是 WAL 的索引缓存，打开时会重建，不必拷；“恢复前”文件夹里的 -wal 要一起拷，里面可能有未合并的数据
        let present = storeItems.filter { $0 != "APT.store-shm" && exists(backup, $0) }

        // 1. 先拷进临时文件夹
        let staging = dir.appendingPathComponent(".restore-staging-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            for item in present {
                try fm.copyItem(at: backup.appendingPathComponent(item), to: staging.appendingPathComponent(item))
            }
        } catch {
            try? fm.removeItem(at: staging)
            let back = putBack()
            return RestoreOutcome(succeeded: false, message: "复制备份「\(name)」失败：\(error.localizedDescription)。\(back.note)", dataLeftAside: back.leftAside)
        }

        // 2. 现有数据整体移开（同一个磁盘上只是改名，瞬间完成）
        if !allAside {
            do {
                if aside == nil {
                    try? fm.createDirectory(at: root, withIntermediateDirectories: true)
                    let base = Kind.preRestore.rawValue + "-" + stamp(Date())
                    let made = (try? reserveFolder(in: root, base: base, partial: false))?.final ?? uniqueURL(in: root, base: base)
                    try fm.createDirectory(at: made, withIntermediateDirectories: true)
                    aside = made
                }
                guard let aside else { throw BackupError.invalidBackup("没能建出“恢复前”文件夹") }
                // 动手之前先记下这个文件夹：万一下面中途断电，下次启动接着往同一个文件夹里移
                try record("moving")
                // 数据目录里的每一项都要移走；同名的已经在“恢复前”里时移动会失败、整体放回，绝不覆盖
                for item in storeItems where exists(dir, item) {
                    try fm.moveItem(at: dir.appendingPathComponent(item), to: aside.appendingPathComponent(item))
                    if !moved.contains(item) { moved.append(item) }
                }
                try record("placing")
                allAside = true
            } catch {
                try? fm.removeItem(at: staging)
                let back = putBack()
                return RestoreOutcome(succeeded: false, message: "移开现有数据时出错（\(error.localizedDescription)），没有执行恢复。\(back.note)", dataLeftAside: back.leftAside)
            }
        }

        // 3. 换上备份（原数据都已移开：数据目录里还有的，只是上次中断时换上一半的备份副本，先挪开）
        do {
            guard setAsideCopies() else { throw BackupError.restoreStep("数据文件夹里上次换上一半的备份副本挪不开") }
            for item in present {
                try fm.moveItem(at: staging.appendingPathComponent(item), to: dir.appendingPathComponent(item))
            }
        } catch {
            try? fm.removeItem(at: staging)
            let back = putBack()
            return RestoreOutcome(succeeded: false, message: "换上备份时出错（\(error.localizedDescription)），没有完成恢复。\(back.note)", dataLeftAside: back.leftAside)
        }
        try? fm.removeItem(at: staging)
        guard let aside else { return RestoreOutcome(succeeded: true, message: "已从备份「\(name)」恢复。") }
        if moved.isEmpty {
            // 原来就没有数据可移：“恢复前”是空的就删掉（里面有挪开的东西时留着，不删）
            removeIfEmpty(aside)
            return RestoreOutcome(succeeded: true, message: "已从备份「\(name)」恢复。" + holderNote())
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy年M月d日 HH:mm"
        try? """
        这是 \(formatter.string(from: Date())) 从备份「\(name)」恢复之前的数据，原样保留（含 APT.store-wal / -shm）。
        如果想退回到恢复之前：设置 → 数据与备份 → 从备份恢复，选这一份（“恢复前”）即可。
        """.write(to: aside.appendingPathComponent("说明.txt"), atomically: true, encoding: .utf8)
        return RestoreOutcome(succeeded: true, message: "已从备份「\(name)」恢复。恢复前的数据完整保留在 Backups/\(aside.lastPathComponent)/，需要时可以再恢复回来。" + holderNote())
    }

    // MARK: 工具

    nonisolated static func folder(for kind: Kind) -> URL {
        switch kind {
        case .daily, .weekly, .manual: root.appendingPathComponent(kind.rawValue, isDirectory: true)
        case .preUpgrade, .preMigration, .preRestore: root
        }
    }

    nonisolated static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        return f.string(from: date)
    }

    /// 在 dir 下找一个没人用过的名字（重名时追加 -2、-3…），并原子地建好（partial 为真时建的是 `<名字>.partial`）。
    /// 返回（实际建好的文件夹，最终名字）。
    nonisolated static func reserveFolder(in dir: URL, base: String, partial: Bool = true) throws -> (created: URL, final: URL) {
        let fm = FileManager.default
        for n in 1...999 {
            let name = n == 1 ? base : "\(base)-\(n)"
            let final = dir.appendingPathComponent(name, isDirectory: true)
            let created = partial ? dir.appendingPathComponent(name + ".partial", isDirectory: true) : final
            guard !fm.fileExists(atPath: final.path), !fm.fileExists(atPath: created.path) else { continue }
            do {
                // withIntermediateDirectories: false —— 已存在时会失败，不会和别的备份共用一个文件夹
                try fm.createDirectory(at: created, withIntermediateDirectories: false)
                return (created, final)
            } catch where fm.fileExists(atPath: created.path) {
                continue
            }
        }
        throw BackupError.sqlite("找不到可用的备份文件夹名")
    }

    nonisolated static func uniqueURL(in dir: URL, base: String) -> URL {
        let fm = FileManager.default
        var url = dir.appendingPathComponent(base, isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base)-\(n)", isDirectory: true)
            n += 1
        }
        return url
    }

    /// 每份备份里的“如何恢复.txt”。outside 为真（另存、每周另存，存在数据文件夹以外）时：
    /// 应用的「从备份恢复」只列数据文件夹里的备份，看不到这一份，所以只写手动步骤，不叫人去列表里找。
    nonisolated static func writeHowTo(in folder: URL, outside: Bool = false) {
        try? (outside ? outsideHowTo : insideHowTo)
            .write(to: folder.appendingPathComponent("如何恢复.txt"), atomically: true, encoding: .utf8)
    }

    nonisolated static let outsideHowTo = """
        云山修习录 · 另存在别处的备份

        这一份存在数据文件夹以外（例如 iCloud 云盘、外接硬盘），应用里「从备份恢复」的列表看不到它。
        要用它恢复，请照下面的步骤手动换上：
        1. 从菜单栏的笔形图标或 ⌘Q 彻底退出应用（只关窗口不算退出）；
        2. 打开数据文件夹：在 Finder 菜单「前往 → 前往文件夹…」里输入 ~/Library/Application Support/APT-SwiftUI 再按回车
           （应用还能打开时，也可以在「洞府设置 → 数据与备份 → 更多 → 在 Finder 中显示」找到它）；
        3. 在 Finder 里按 ⌘⇧. 显示隐藏文件；
        4. 把数据文件夹里的 APT.store、APT.store-wal、APT.store-shm、.APT_SUPPORT 移到别处保存（先别删，万一要放回）；
        5. 把这个文件夹里的 APT.store 和 .APT_SUPPORT（隐藏文件夹）一起复制进数据文件夹；
        6. 重新打开应用。
        """

    nonisolated static let insideHowTo = """
        云山修习录 · 备份

        推荐做法：在应用的「洞府设置 → 数据与备份 → 从备份恢复」里选这一份，应用会自动重启并替换，
        原来的数据会整体移到 Backups/恢复前-<时间>/，不会丢。

        数据库打不开时，打开应用出现的错误页里也有同样的恢复入口。

        如果一定要手动恢复：
        1. 从菜单栏的笔形图标或 ⌘Q 彻底退出应用（只关窗口不算退出）；
        2. 在 Finder 里按 ⌘⇧. 显示隐藏文件；
        3. 把数据文件夹里的 APT.store、APT.store-wal、APT.store-shm、.APT_SUPPORT 移到别处保存；
        4. 把这个文件夹里的 APT.store 和 .APT_SUPPORT（隐藏文件夹）一起复制回数据文件夹。
        """
}
