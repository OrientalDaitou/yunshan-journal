import Foundation
import SwiftData

// 每周自动另存一份到选的文件夹（OffsiteBackup）的自检。
// 规则（该不该存、哪些文件夹算自己写的、留哪 8 份）直接测；写一份在自检临时数据目录里另建的子文件夹里做：
// 数据目录与“选的文件夹”都在这个临时目录下，不碰正式数据，也不往偏好设置里写任何东西。

extension SelfTest {
    static func offsiteChecks(_ check: (Bool, String) -> Void) throws {
        offsiteRuleChecks(check)
        try offsiteWriteChecks(check)
    }

    // MARK: 规则

    private static func offsiteRuleChecks(_ check: (Bool, String) -> Void) {
        let monday = LocalDay.today().mondayOfWeek
        let noon = { (day: LocalDay) in day.date(minutes: 12 * 60) }
        let wednesday = noon(monday.adding(days: 2))
        check(OffsiteBackup.isDue(lastSuccess: nil, lastFailure: nil, now: wednesday)
              && !OffsiteBackup.isDue(lastSuccess: noon(monday), lastFailure: nil, now: wednesday)
              && OffsiteBackup.isDue(lastSuccess: noon(monday.adding(days: -1)), lastFailure: nil, now: wednesday),
              "每周另存：本周（周一到周日）存过就不再存，上周日存的不算本周")
        check(!OffsiteBackup.isDue(lastSuccess: nil, lastFailure: wednesday.addingTimeInterval(-3600), now: wednesday)
              && OffsiteBackup.isDue(lastSuccess: nil, lastFailure: wednesday.addingTimeInterval(-4 * 3600), now: wednesday),
              "每周另存：写到一半出错的隔 3 小时再试，不每 30 分钟整份重做")
        check(OffsiteBackup.isOwnFolderName("2026-10-22_093000") && OffsiteBackup.isOwnFolderName("2026-10-22_093000-2")
              && !OffsiteBackup.isOwnFolderName("云山修习录备份-2026-10-22_093000") && !OffsiteBackup.isOwnFolderName("2026-10-22_093000.partial")
              && !OffsiteBackup.isOwnFolderName("我的照片") && !OffsiteBackup.isOwnFolderName("2026-10-22"),
              "每周另存：只认“时间”名字的文件夹是自己写的，手动另存的“云山修习录备份-…”和别的东西不算")
        let names = (1...10).map { String(format: "2026-01-%02d_080000", $0) } + ["2026-01-10_080000-2", "2026-01-10_080000-10", "相册"]   // 自己写的共 12 份：清掉最早的 4 份
        let pruned = OffsiteBackup.namesToPrune(names.shuffled(), keep: 8)
        let newestTwo = Set(names).subtracting(OffsiteBackup.namesToPrune(names, keep: 2)).subtracting(["相册"])
        check(Set(pruned) == Set((1...4).map { String(format: "2026-01-%02d_080000", $0) })
              && newestTwo == ["2026-01-10_080000-2", "2026-01-10_080000-10"],
              "每周另存：只留最近 8 份，同一秒的 -2、-10 也按新旧排（清掉：\(pruned.sorted().joined(separator: "、"))）")
        let data = URL(fileURLWithPath: "/tmp/APT数据", isDirectory: true)
        check(OffsiteBackup.isInsideDataFolder(data, dataFolder: data) && OffsiteBackup.isInsideDataFolder(data.appendingPathComponent("子"), dataFolder: data)
              && !OffsiteBackup.isInsideDataFolder(URL(fileURLWithPath: "/tmp/APT数据2", isDirectory: true), dataFolder: data)
              && !OffsiteBackup.isInsideDataFolder(data.deletingLastPathComponent(), dataFolder: data),
              "每周另存：数据文件夹本身和里面的位置不能选，名字相近的别的文件夹可以")
    }

    // MARK: 真的写一份

    private static func offsiteWriteChecks(_ check: (Bool, String) -> Void) throws {
        guard let base = DataStore.customDirectory, let original = ProcessInfo.processInfo.environment["APT_STORE_DIR"] else { return }
        let fm = FileManager.default
        let tag = UUID().uuidString.prefix(8)
        let dataDir = base.appendingPathComponent("每周另存自检-数据-\(tag)", isDirectory: true)
        let target = base.appendingPathComponent("每周另存自检-选的文件夹-\(tag)", isDirectory: true)
        let readOnly = base.appendingPathComponent("每周另存自检-只读-\(tag)", isDirectory: true)
        try fm.createDirectory(at: dataDir, withIntermediateDirectories: true)
        setenv("APT_STORE_DIR", dataDir.path, 1)
        defer {
            setenv("APT_STORE_DIR", original, 1)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readOnly.path)
            for url in [dataDir, target, readOnly] { try? fm.removeItem(at: url) }
        }
        // 双保险：数据目录确实已经切到这个子文件夹，才往下做
        guard DataStore.directory.standardizedFileURL.path == dataDir.standardizedFileURL.path else {
            check(false, "每周另存自检：临时数据目录没有切过去")
            return
        }

        try autoreleasepool {
            let schema = Schema(APTSchema.models)
            let c = ModelContext(try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: DataStore.storeURL)]))
            c.insert(JournalEntry(kind: .note, title: "每周另存自检", body: "这条应出现在另存的那份里"))
            try c.save()

            // 1. 选的文件夹不在（外接硬盘没接上）：不替人建，只给原因
            let missing = OffsiteBackup.perform(context: c, destination: target)
            if case .unavailable(let reason) = missing {
                check(reason.contains("找不到") && !fm.fileExists(atPath: target.path), "每周另存：文件夹不在时不替人建，只说“找不到”")
            } else {
                check(false, "每周另存：文件夹不在时应给出原因")
            }

            // 2. 旧的：9 份自己写的、一份同名格式但不是备份的、一份手动另存的，看清理只动自己写的
            let container = target.appendingPathComponent(OffsiteBackup.containerName, isDirectory: true)
            try fm.createDirectory(at: container, withIntermediateDirectories: true)
            let olds = (1...9).map { container.appendingPathComponent(String(format: "2020-01-%02d_080000", $0), isDirectory: true) }
            for url in olds {
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
                try Data().write(to: url.appendingPathComponent("APT.store"))
            }
            let notBackup = container.appendingPathComponent("2019-01-01_080000", isDirectory: true)
            let manual = container.appendingPathComponent("云山修习录备份-2019-01-01_080000", isDirectory: true)
            for url in [notBackup, manual] { try fm.createDirectory(at: url, withIntermediateDirectories: true) }
            try Data().write(to: manual.appendingPathComponent("APT.store"))
            try Data("别删我".utf8).write(to: target.appendingPathComponent("我自己的笔记.txt"))

            let before = BackupService.list().count
            let outcome = OffsiteBackup.perform(context: c, destination: target)
            guard case .saved(let made) = outcome else {
                check(false, "每周另存：选的文件夹可写时应存成（\(outcome)）")
                return
            }
            let files = (try? fm.contentsOfDirectory(atPath: made.path)) ?? []
            check(made.deletingLastPathComponent().standardizedFileURL.path == container.standardizedFileURL.path
                  && OffsiteBackup.isOwnFolderName(made.lastPathComponent)
                  && ["APT.store", "APT-完整备份.json", "如何恢复.txt"].allSatisfy(files.contains),
                  "每周另存：写进“\(OffsiteBackup.containerName)/\(made.lastPathComponent)/”，内容与“另存一份到…”相同（\(files.sorted().joined(separator: "、"))）")
            let titles = try autoreleasepool {
                try ModelContext(ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: made.appendingPathComponent("APT.store"))]))
                    .all(JournalEntry.self).map(\.title)
            }
            check(titles.contains("每周另存自检"), "每周另存：存出去的那份能打开，记录都在")
            // 存在数据文件夹以外的这份，应用的“从备份恢复”列表里没有：说明里只写手动步骤，不叫人去列表里选
            let howTo = (try? String(contentsOf: made.appendingPathComponent("如何恢复.txt"), encoding: .utf8)) ?? ""
            check(howTo.contains("列表看不到它") && howTo.contains("前往文件夹") && !howTo.contains("里选这一份"),
                  "每周另存：另存那份的“如何恢复.txt”写手动步骤，不指向应用里的恢复列表")
            check(BackupService.list().count == before, "每周另存：数据文件夹里不多留一份")

            let left = Set((try? fm.contentsOfDirectory(atPath: container.path)) ?? [])
            let own = left.filter(OffsiteBackup.isOwnFolderName).filter { fm.fileExists(atPath: container.appendingPathComponent($0).appendingPathComponent("APT.store").path) }
            check(own.count == OffsiteBackup.keep && own.contains(made.lastPathComponent)
                  && !left.contains("2020-01-01_080000") && !left.contains("2020-01-02_080000") && left.contains("2020-01-03_080000"),
                  "每周另存：只留最近 \(OffsiteBackup.keep) 份（新存的这份 + 7 份较新的旧备份）")
            check(left.contains(notBackup.lastPathComponent) && left.contains(manual.lastPathComponent)
                  && fm.fileExists(atPath: target.appendingPathComponent("我自己的笔记.txt").path),
                  "每周另存：名字像但不是备份的、手动另存的、选的文件夹里别的东西一概不碰")

            // 3. 不能写的文件夹：只给原因，不抛错
            try fm.createDirectory(at: readOnly, withIntermediateDirectories: true)
            try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readOnly.path)
            if case .unavailable(let reason) = OffsiteBackup.perform(context: c, destination: readOnly) {
                check(reason.contains("不能写入") && !fm.fileExists(atPath: readOnly.appendingPathComponent(OffsiteBackup.containerName).path),
                      "每周另存：文件夹不能写时只说原因，什么都不留")
            } else {
                check(false, "每周另存：只读文件夹应给出“不能写入”")
            }

            // 4. 选到数据文件夹里面：不写
            let inside = dataDir.appendingPathComponent("里面", isDirectory: true)
            try fm.createDirectory(at: inside, withIntermediateDirectories: true)
            if case .unavailable = OffsiteBackup.perform(context: c, destination: inside) {
                check(!fm.fileExists(atPath: inside.appendingPathComponent(OffsiteBackup.containerName).path), "每周另存：选到数据文件夹里面时不写")
            } else {
                check(false, "每周另存：选到数据文件夹里面时应拒绝")
            }

            // 5. 每日备份出错（Backups/ 不能写）时，每周另存照样存：数据所在的盘出问题时最需要另一份。
            //    开关和位置写进一个用完即删的临时偏好域，不碰自检实例自己的偏好
            let suiteName = "io.github.orientaldaitou.yunshan.selftest.offsite.\(tag)"
            if let suite = UserDefaults(suiteName: suiteName) {
                defer { suite.removePersistentDomain(forName: suiteName) }
                suite.set(true, forKey: OffsiteBackup.enabledKey)
                suite.set(target.path, forKey: OffsiteBackup.pathKey)
                let backupsDir = BackupService.root
                try fm.createDirectory(at: backupsDir, withIntermediateDirectories: true)
                try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: backupsDir.path)
                let ownBefore = Set(((try? fm.contentsOfDirectory(atPath: container.path)) ?? []).filter(OffsiteBackup.isOwnFolderName))
                let dailyMade = BackupService.runIfDue(context: c, offsiteDefaults: suite)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: backupsDir.path)
                let ownAfter = Set(((try? fm.contentsOfDirectory(atPath: container.path)) ?? []).filter(OffsiteBackup.isOwnFolderName))
                check(dailyMade == nil && suite.double(forKey: OffsiteBackup.lastSuccessKey) > 0 && !ownAfter.subtracting(ownBefore).isEmpty,
                      "每日备份出错时，每周另存不跟着跳过，照样存进选的文件夹")
            } else {
                check(false, "每周另存自检：临时偏好域建不起来")
            }

            // 6. 没打开每周另存（自检的偏好域里没有这一项）：每日 / 每周备份照旧，选的文件夹里不多一份
            let countBefore = (try? fm.contentsOfDirectory(atPath: container.path))?.count ?? -1
            let daily = BackupService.runIfDue(context: c)
            check(daily != nil && BackupService.list().contains { $0.kind == .weekly }
                  && ((try? fm.contentsOfDirectory(atPath: container.path))?.count ?? -2) == countBefore,
                  "每周另存没打开时：每日、每周备份照旧，别处什么都不写")
            let dailyHowTo = daily.flatMap { try? String(contentsOf: $0.appendingPathComponent("如何恢复.txt"), encoding: .utf8) } ?? ""
            check(dailyHowTo.contains("从备份恢复」里选这一份"), "数据文件夹里的备份：“如何恢复.txt”照旧叫人在应用的恢复列表里选")
        }
    }
}
