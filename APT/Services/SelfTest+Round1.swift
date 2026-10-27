import Foundation
import SwiftData

// MARK: - 第 1 轮（性能 + bug 修复）的回归检查
//
// 第 1 轮几位实现者在报告里建议补上的自检用例：飞剑传书的档案撤销（乱序、同封重复、旧版记法）、摘要换行、重复回执、
// 快照里的修为；调试实例的偏好隔离、恢复中途断电的两种情形、“升级前”按创建时间清理。
// 文件操作全部在自检的临时数据目录（APT_STORE_DIR）里做，备份与恢复的用例各自再建一个子文件夹，用完删掉，不碰正式数据。

extension SelfTest {
    /// 19–20. 第 1 轮修复的回归检查（SelfTest.run 末尾调用）
    static func round1Checks(_ check: (Bool, String) -> Void) throws {
        try round1CourierChecks(check)
        try round1BackupChecks(check)
    }

    // MARK: 工具

    /// 一个干净的内存库（与 freshContext 相同；那个是 SelfTest.swift 里的 private）
    private static func round1Context() throws -> ModelContext {
        let context = ModelContext(try DataStore.makeContainer(inMemory: true))
        DataStore.settings(in: context)
        DataStore.profile(in: context)
        DataStore.save(context)
        return context
    }

    /// 收录一封传书。items 用字典写、交给 JSONSerialization 编码，免得手拼 JSON 时换行、引号转义出错
    private static func round1Deliver(_ items: [[String: Any]], _ fileName: String, _ c: ModelContext) throws -> CourierDelivery {
        let data = try JSONSerialization.data(withJSONObject: ["from": "自检", "items": items])
        return try CourierService.apply(try CourierParser.parse(data), fileName: fileName, context: c)
    }

    private static func round1Profile(_ fields: [String: String]) -> [String: Any] { ["type": "profile", "fields": fields] }

    /// 传书里记下的档案引用（撤销前一封时，后一封的“改写前”可能被接回更早的内容）
    private static func round1ProfileRefs(_ d: CourierDelivery) -> [CourierService.Ref] {
        ((try? JSONDecoder().decode([CourierService.Ref].self, from: Data(d.refsJSON.utf8))) ?? []).filter { $0.t == "profile" }
    }

    /// 把几封传书的收录时刻排开（每封差 30 秒）：撤销时按收录先后判断“之后又有传书改写过同一字段”
    private static func round1Order(_ deliveries: [CourierDelivery], _ c: ModelContext) {
        let base = Date().addingTimeInterval(-Double(deliveries.count + 1) * 30)
        for (i, d) in deliveries.enumerated() { d.receivedAt = base.addingTimeInterval(Double(i) * 30) }
        DataStore.save(c)
    }

    // MARK: 19. 飞剑传书

    static func round1CourierChecks(_ check: (Bool, String) -> Void) throws {
        // 19a. 两封先后改同一字段（X → A → B），先撤前一封：字段仍是 B，不算“你改过的”，后一封的“改写前”接回 X；再撤后一封回到 X
        do {
            let c = try round1Context()
            let profile = DataStore.profile(in: c)
            profile["main_tasks"] = "X"
            DataStore.save(c)
            let d1 = try round1Deliver([round1Profile(["main_tasks": "A"])], "r1-chain-1.json", c)
            let d2 = try round1Deliver([round1Profile(["main_tasks": "B"])], "r1-chain-2.json", c)
            round1Order([d1, d2], c)
            let p1 = CourierService.undoPreviewDetail(d1, context: c)
            let r1 = CourierService.undo(d1, context: c, refresh: false)
            check(p1.superseded == 1 && p1.fields == 0 && p1.edited == 0 && r1.superseded == 1 && r1.restored == 0 && r1.keptEdited == 0
                  && profile["main_tasks"] == "B" && round1ProfileRefs(d2).first?.before == "X",
                  "档案撤销乱序（X→A→B，先撤前一封）：字段仍是 B、不算你改过的，后一封的“改写前”接回 X")
            let r2 = CourierService.undo(d2, context: c, refresh: false)
            check(r2.restored == 1 && r2.keptEdited == 0 && profile["main_tasks"] == "X", "再撤后一封：字段回到最初的 X")
        }

        // 19b. 前一封写 A、你改成 Y、后一封又写 A：先撤前一封，字段仍是后一封写的 A；再撤后一封，回到你写的 Y
        do {
            let c = try round1Context()
            let profile = DataStore.profile(in: c)
            profile["career_goals"] = "X"
            DataStore.save(c)
            let d1 = try round1Deliver([round1Profile(["career_goals": "A"])], "r1-user-1.json", c)
            profile["career_goals"] = "Y"
            DataStore.save(c)
            let d2 = try round1Deliver([round1Profile(["career_goals": "A"])], "r1-user-2.json", c)
            round1Order([d1, d2], c)
            let r1 = CourierService.undo(d1, context: c, refresh: false)
            check(r1.superseded == 1 && r1.restored == 0 && profile["career_goals"] == "A" && round1ProfileRefs(d2).first?.before == "Y",
                  "档案撤销乱序（中间你改成 Y，先撤前一封）：字段仍是后一封写的 A，后一封的“改写前”仍是 Y")
            let r2 = CourierService.undo(d2, context: c, refresh: false)
            check(r2.restored == 1 && profile["career_goals"] == "Y", "再撤后一封：回到你写的 Y，不会退回更早的 X")
        }

        // 19c. 同一封 [main_tasks:A, note, main_tasks:B]：档案合并成一项，共 2 条；预览 1 个字段 + 1 条记录，撤销后回到原内容
        do {
            let c = try round1Context()
            let profile = DataStore.profile(in: c)
            profile["main_tasks"] = "原任务"
            DataStore.save(c)
            let d = try round1Deliver([round1Profile(["main_tasks": "A"]), ["type": "note", "body": "第1轮自检·同封灵感"],
                                       round1Profile(["main_tasks": "B"])], "r1-same.json", c)
            let p = CourierService.undoPreviewDetail(d, context: c)
            check(d.itemCount == 2 && round1ProfileRefs(d).count == 1 && d.summary.split(separator: "\n").count == 2
                  && p.fields == 1 && p.records == 1 && p.edited == 0 && profile["main_tasks"] == "B",
                  "同一封里两条改同一字段：合并成一项（共 \(d.itemCount) 条），撤销预览 \(p.fields) 个档案字段、\(p.records) 条记录")
            let r = CourierService.undo(d, context: c, refresh: false)
            check(r.restored == 1 && r.removed == 2 && profile["main_tasks"] == "原任务" && !c.all(JournalEntry.self).contains { $0.body == "第1轮自检·同封灵感" },
                  "撤销这封：档案回到收录前的原内容，灵感一并撤回")
        }

        // 19d. 同一封先写原内容（跳过）再写 B：只记一项、摘要只有一行
        do {
            let c = try round1Context()
            let profile = DataStore.profile(in: c)
            profile["main_tasks"] = "原值"
            DataStore.save(c)
            let d = try round1Deliver([round1Profile(["main_tasks": "原值"]), round1Profile(["main_tasks": "B"])], "r1-same-orig.json", c)
            let lines = d.summary.split(separator: "\n")
            check(d.itemCount == 1 && round1ProfileRefs(d).count == 1 && round1ProfileRefs(d).first?.before == "原值"
                  && lines.count == 1 && lines.first?.contains("跳过") == false && profile["main_tasks"] == "B",
                  "同一封先写原内容再写 B：只记一项、摘要一行（\(lines.first ?? "")）")
        }

        // 19e. 旧版收录的同封两项（X→A、A→B 各记一项）：按字段合并，预览 1 个字段、没改过，撤销后回到最初的 X
        do {
            let c = try round1Context()
            let profile = DataStore.profile(in: c)
            profile["main_tasks"] = "B"
            let legacy = CourierDelivery(fileName: "旧版同封两项.json", from: "自检", note: "")
            let refs = [CourierService.Ref(t: "profile", r: "main_tasks", before: "X", after: "A"),
                        CourierService.Ref(t: "profile", r: "main_tasks", before: "A", after: "B")]
            legacy.refsJSON = String(data: try JSONEncoder().encode(refs), encoding: .utf8) ?? "[]"
            legacy.itemCount = 2
            legacy.summary = "档案 · 主要任务：A\n档案 · 主要任务：B"
            c.insert(legacy)
            DataStore.save(c)
            let p = CourierService.undoPreviewDetail(legacy, context: c)
            check(p.fields == 1 && p.editedFields == 0 && p.edited == 0 && p.total == 1, "旧版同封两项：撤销预览按字段合并（\(p.fields) 个字段，改过 \(p.edited) 个）")
            let r = CourierService.undo(legacy, context: c, refresh: false)
            check(r.restored == 1 && r.keptEdited == 0 && profile["main_tasks"] == "X", "旧版同封两项：撤销后回到最初的 X")
        }

        // 19f. 多行档案：摘要压成一行“写论文；健身；找工作”，档案里仍保留换行；撤销说明与结果说“恢复”，不说“删除”
        do {
            let c = try round1Context()
            let profile = DataStore.profile(in: c)
            profile["main_tasks"] = "旧任务"
            DataStore.save(c)
            let d = try round1Deliver([round1Profile(["main_tasks": "写论文\n健身\n找工作"])], "r1-multiline.json", c)
            check(!d.summary.contains("\n") && d.summary.contains("写论文；健身；找工作") && profile["main_tasks"] == "写论文\n健身\n找工作",
                  "多行档案：传书摘要只占一行（\(d.summary)），档案里仍保留换行")
            let plan = RootView.courierUndoPlan(CourierService.undoPreviewDetail(d, context: c))
            check(plan == "将恢复 1 个档案字段", "传书笺的撤销说明：档案字段说成恢复，不说删除（\(plan)）")
            let r = CourierService.undo(d, context: c, refresh: false)
            let effects = EffectsCenter()
            effects.courierUndoResult(removed: r.removed, keptEdited: r.keptEdited, failure: r.failure, restored: r.restored, superseded: r.superseded)
            let notice = effects.courier
            check(profile["main_tasks"] == "旧任务" && notice?.detail == "恢复 1 个档案字段"
                  && notice?.lines == ["已恢复 1 个档案字段，回到传书之前的内容"],
                  "撤销结果的传书笺：写“恢复 1 个档案字段”，不写“删除”")
        }

        // 19g. 撤销说明的几种组合（与修行录里飞剑传书卡同一套说法 CourierUndoWording；目标与保留原因见 SelfTest+polish）
        let plans: [(CourierUndoPreview, String)] = [
            (CourierUndoPreview(records: 3), "将删除 3 条记录。删除后无法找回。"),
            (CourierUndoPreview(records: 3, editedRecords: 1), "将删除 2 条记录；保留你改过的 1 条记录。删除后无法找回。"),
            (CourierUndoPreview(records: 1, fields: 2, superseded: 1), "将删除 1 条记录，恢复 2 个档案字段；另有 1 个档案字段以之后的传书为准，不动。删除后无法找回。"),
            (CourierUndoPreview(records: 2, editedRecords: 1, fields: 2, editedFields: 1),
             "将删除 1 条记录，恢复 1 个档案字段；保留你改过的 1 条记录和 1 个档案字段。删除后无法找回。"),
            (CourierUndoPreview(fields: 1, editedFields: 1), "不会删除或恢复任何内容，只把这封标记为已撤销；保留你改过的 1 个档案字段"),
        ]
        let wrongPlans = plans.filter { RootView.courierUndoPlan($0.0) != $0.1 }.map { RootView.courierUndoPlan($0.0) }
        check(wrongPlans.isEmpty, "传书笺撤销说明：删除与恢复分开说" + (wrongPlans.isEmpty ? "" : "，不符：\(wrongPlans)"))
        let mixed = EffectsCenter()
        mixed.courierUndoResult(removed: 3, keptEdited: 1, failure: nil, restored: 2, superseded: 1)
        check(mixed.courier?.detail == "删除 1 条 · 恢复 2 个档案字段 · 保留 1 条" && mixed.courier?.lines.first == "已删除这封传书写入的 1 条记录"
              && mixed.courier?.lines.contains("另有 1 个档案字段以之后的传书为准，没有动") == true,
              "撤销结果：删除 1 条、恢复 2 个档案字段分开写（\(mixed.courier?.detail ?? "")）")

        // 下面两项要写收件箱与快照文件：只在临时数据目录里做
        guard DataStore.customDirectory != nil else { return }

        // 19h. 重复投递被跳过、而档案字段收录后已被改过：回执如实写“现在不是这封里的内容”，不说“现在就是这个内容”
        do {
            let c = try round1Context()
            CourierService.prepareFolders()
            let today = LocalDay.today(in: CourierService.timeZone)
            let data = try JSONSerialization.data(withJSONObject: ["from": "自检", "items": [
                ["type": "diary", "date": today.key, "body": "第1轮自检·重复投递"], round1Profile(["career_goals": "成为作家"]),
            ]])
            let first = CourierService.inbox.appendingPathComponent("round1-dup-first.json")
            let again = CourierService.inbox.appendingPathComponent("round1-dup-again.json")
            try data.write(to: first)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-5)], ofItemAtPath: first.path)
            let received = CourierService.processInbox(context: c, effects: nil)
            DataStore.profile(in: c)["career_goals"] = "改主意了"
            DataStore.save(c)
            try data.write(to: again)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-5)], ofItemAtPath: again.path)
            let receivedAgain = CourierService.processInbox(context: c, effects: nil)
            let receipts = ((try? FileManager.default.contentsOfDirectory(at: CourierService.processed, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.lastPathComponent.hasSuffix("round1-dup-again.result.txt") }
                .map { (try? String(contentsOf: $0, encoding: .utf8)) ?? "" }
            check(received == 1 && receivedAgain == 0 && receipts.count == 1
                  && receipts.allSatisfy { $0.contains("重复投递，已跳过") && $0.contains("career_goals") && $0.contains("现在不是这封里的内容") && !$0.contains("现在就是这个内容") }
                  && DataStore.profile(in: c)["career_goals"] == "改主意了",
                  "重复投递时档案字段已被改过：回执写明“现在不是这封里的内容”，档案不被改回")
        }

        // 19i. 快照概览的“累计修为”：改修行录、打卡、改境界设置之后，都与 CultivationService 算的相同（快照把两部分结果记下来沿用）
        do {
            let c = try round1Context()
            let today = LocalDay.today(in: CourierService.timeZone)
            let habit = Habit(title: "第1轮快照自检")
            habit.startDate = today.adding(days: -5).key
            c.insert(habit)
            for offset in 1...3 {
                let log = HabitLog(dateKey: today.adding(days: -offset).key, completed: true, quantity: nil)
                c.insert(log)
                log.habit = habit
            }
            let diary = JournalEntry(kind: .diary, title: "", body: "第1轮快照自检", dateKey: today.key)
            c.insert(diary)
            c.insert(JournalEntry(kind: .note, title: "", body: "第1轮快照自检·灵感", dateKey: today.adding(days: -1).key))
            DataStore.save(c)
            var shown: [Int] = [], actual: [Int] = []
            func step() {
                CourierService.refreshSnapshot(context: c)
                let text = (try? String(contentsOf: CourierService.snapshotURL, encoding: .utf8)) ?? ""
                let number = text.range(of: #"累计修为 \d+"#, options: .regularExpression).flatMap { Int(text[$0].dropFirst("累计修为 ".count)) }
                shown.append(number ?? -1)
                actual.append(CultivationService.state(context: c, today: today).totalXP)
            }
            step()
            // 改修行录：日记改成复盘（与修订保存一样更新修改时间）
            diary.kind = JournalKind.review.rawValue
            diary.updatedAt = Date()
            DataStore.save(c)
            step()
            // 打卡：今天补上
            HabitActions.toggle(habit, on: today, context: c, effects: EffectsCenter(), allHabits: c.all(Habit.self),
                                config: DataStore.settings(in: c).cultivation)
            DataStore.save(c)
            step()
            // 改设置：每日上限调低（境界设置没有修改时间，快照每次照读）
            DataStore.settings(in: c).dailyCap = 12
            DataStore.save(c)
            step()
            let changedEachTime = zip(actual, actual.dropFirst()).allSatisfy { $0 != $1 }
            check(shown == actual && changedEachTime,
                  "快照概览的累计修为：改修行录、打卡、改设置后都与实际相同（快照 \(shown.map(String.init).joined(separator: " → "))，实际 \(actual.map(String.init).joined(separator: " → "))）")
        }
    }

    // MARK: 20. 偏好隔离、恢复中断、升级前清理

    /// 在自检临时数据目录下另建一个子文件夹，把 APT_STORE_DIR 临时指过去做一项；做完指回原处、删掉子文件夹
    private static func round1InDataDirectory(_ name: String, _ body: (URL) throws -> Void) throws {
        guard let base = DataStore.customDirectory, let original = ProcessInfo.processInfo.environment["APT_STORE_DIR"] else { return }
        let dir = base.appendingPathComponent("第1轮自检-\(name)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("APT_STORE_DIR", dir.path, 1)
        defer {
            setenv("APT_STORE_DIR", original, 1)
            try? FileManager.default.removeItem(at: dir)
        }
        // 双保险：数据目录确实已经是这个子文件夹，才往下做
        guard DataStore.directory.standardizedFileURL.path == dir.standardizedFileURL.path else {
            throw BackupService.BackupError.restoreStep("自检：临时数据目录没有切过去")
        }
        try body(dir)
    }

    private static func round1OpenStore(_ url: URL) throws -> ModelContext {
        let schema = Schema(APTSchema.models)
        return ModelContext(try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url)]))
    }

    /// 在当前数据目录里建一个真正的磁盘数据库（不经 DataStore.makeContainer，免得顺带做“升级前”备份），
    /// 写一篇标题为 title 的灵感；backup 为真时再做一份手动备份并返回它
    @discardableResult
    private static func round1MakeStore(_ title: String, backup: Bool) throws -> URL? {
        var folder: URL?
        try autoreleasepool {
            let c = try round1OpenStore(DataStore.storeURL)
            c.insert(JournalEntry(kind: .note, title: title, body: "x"))
            try c.save()
            if backup { folder = try BackupService.backup(context: c, kind: .manual) }
        }
        return folder
    }

    /// 改写待恢复标记里的“恢复前”文件夹与进行到哪一步（模拟恢复做到一半断电）
    private static func round1SetMarker(_ object: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: object).write(to: BackupService.restoreRequestURL)
    }

    static func round1BackupChecks(_ check: (Bool, String) -> Void) throws {
        guard let base = DataStore.customDirectory else { return }
        let fm = FileManager.default

        // 20a. 调试实例（设了 APT_STORE_DIR）用独立的偏好域；只看名字与对象，不往这个域里写任何东西（连 removeObject 都会留下 plist）
        let suite = AppPreferences.suiteName
        let sameFolderVariants = [URL(fileURLWithPath: base.path + "/", isDirectory: true), base.appendingPathComponent(".", isDirectory: true)]
        check(suite?.hasPrefix("io.github.orientaldaitou.yunshan.dev.") == true && suite == AppPreferences.devSuiteName(for: base)
              && sameFolderVariants.allSatisfy { AppPreferences.devSuiteName(for: $0) == suite }
              && AppPreferences.devSuiteName(for: base.deletingLastPathComponent()) != suite
              && AppPreferences.defaults !== UserDefaults.standard,
              "调试实例的偏好单独存放（\(suite ?? "没有独立的域")），同一个数据目录每次同名，不是正式应用的那一份")

        // 20b. “升级前”按创建时间清理：已有 3 份名字里时间更晚的，凌晨 1 点再做一份（名字最“小”）：新做的留下，删掉创建最早的
        try round1InDataDirectory("升级前清理") { _ in
            try round1MakeStore("第1轮自检·升级前", backup: false)
            try fm.createDirectory(at: BackupService.root, withIntermediateDirectories: true)
            var older: [URL] = []
            for (i, time) in ["100000", "110000", "120000"].enumerated() {
                let url = BackupService.root.appendingPathComponent("升级前-2099-01-01_\(time)", isDirectory: true)
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
                try Data("占位".utf8).write(to: url.appendingPathComponent("APT.store"))
                try fm.setAttributes([.creationDate: Date().addingTimeInterval(Double(i - 3) * 600)], ofItemAtPath: url.path)
                older.append(url)
            }
            let oneAM = Calendar.current.startOfDay(for: Date()).addingTimeInterval(3600)
            let fresh = DataStore.backupBeforeUpgradeIfNeeded(stamp: "第1轮自检构建", now: oneAM, needsMigration: false)
            let kept = BackupService.list().filter { $0.kind == .preUpgrade }
            check(fresh?.lastPathComponent.hasSuffix("_010000") == true && fresh.map { fm.fileExists(atPath: $0.appendingPathComponent("APT.store").path) } == true
                  && !fm.fileExists(atPath: older[0].path) && fm.fileExists(atPath: older[1].path) && fm.fileExists(atPath: older[2].path)
                  && kept.count == BackupService.upgradeKeep,
                  "“升级前”按创建时间清理：凌晨 1 点新做的 \(fresh?.lastPathComponent ?? "（没做出来）") 留下，删掉的是创建最早的那份")
        }

        // 20c. 恢复中断在 placing（原数据都已移开）之后，原主库又回到了数据目录（例如照说明手动拖回）：
        // 执行恢复时它被当作“换上一半的备份副本”挪进“恢复前”的子文件夹，不删除
        try round1InDataDirectory("恢复中断placing") { dir in
            guard let snapshot = try round1MakeStore("第1轮自检·备份里的", backup: true) else { return check(false, "placing：没能做出备份") }
            for item in BackupService.storeItems { try? fm.removeItem(at: dir.appendingPathComponent(item)) }
            let original = Data("第1轮自检·原数据主库".utf8)
            try original.write(to: DataStore.storeURL)
            let aside = BackupService.root.appendingPathComponent("恢复前-第1轮自检placing", isDirectory: true)
            try fm.createDirectory(at: aside.appendingPathComponent(".APT_SUPPORT", isDirectory: true), withIntermediateDirectories: true)
            try Data("原外置".utf8).write(to: aside.appendingPathComponent(".APT_SUPPORT/原外置.bin"))
            try BackupService.requestRestore(from: snapshot)
            try round1SetMarker(["backup": snapshot.path, "aside": aside.path, "phase": "placing"])
            let outcome = BackupService.applyPendingRestoreIfNeeded()
            let holders = ((try? fm.contentsOfDirectory(at: aside, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.lastPathComponent.hasPrefix("中断时换上一半的备份副本") }
            let originalKept = holders.contains { (try? Data(contentsOf: $0.appendingPathComponent("APT.store"))) == original }
            var titles: Set<String> = []
            try autoreleasepool { titles = Set(try round1OpenStore(DataStore.storeURL).all(JournalEntry.self).map(\.title)) }
            check(outcome?.succeeded == true && originalKept && fm.fileExists(atPath: aside.appendingPathComponent(".APT_SUPPORT/原外置.bin").path)
                  && titles.contains("第1轮自检·备份里的") && BackupService.pendingRestore == nil,
                  "恢复中断在 placing、原主库又在数据目录里：恢复后原 APT.store 仍在“恢复前”的子文件夹里（\(holders.first?.lastPathComponent ?? "没有")）")
        }

        // 20d. 恢复中断在 moving：数据目录里已有 -wal 和 .APT_SUPPORT，“恢复前”X 里只剩 APT.store。
        // 选 X 恢复（错误页上的“放回原数据”）：只把原数据放回原处，数据目录三项齐全，标记删除，不再留着原数据
        try round1InDataDirectory("恢复中断moving") { dir in
            let aside = BackupService.root.appendingPathComponent("恢复前-第1轮自检moving", isDirectory: true)
            try fm.createDirectory(at: aside, withIntermediateDirectories: true)
            // X 里的主库是一个完好的数据库：当成普通备份也能通过检查，这样“按普通恢复处理”的写法在这里会被认出来
            try round1MakeStore("第1轮自检·原数据", backup: false)
            try fm.moveItem(at: DataStore.storeURL, to: aside.appendingPathComponent("APT.store"))
            for item in ["APT.store-wal", "APT.store-shm"] { try? fm.removeItem(at: dir.appendingPathComponent(item)) }
            let original = try Data(contentsOf: aside.appendingPathComponent("APT.store"))
            try Data("原 wal".utf8).write(to: dir.appendingPathComponent("APT.store-wal"))
            try fm.createDirectory(at: dir.appendingPathComponent(".APT_SUPPORT", isDirectory: true), withIntermediateDirectories: true)
            try Data("原外置".utf8).write(to: dir.appendingPathComponent(".APT_SUPPORT/原外置.bin"))
            // 上次恢复中断时留下的标记：记着 X 和 moving（那次要换上的备份已经不重要了）
            try round1SetMarker(["backup": dir.appendingPathComponent("那次要换上的备份").path, "aside": aside.path, "phase": "moving"])
            try BackupService.requestRestore(from: aside)
            let outcome = BackupService.applyPendingRestoreIfNeeded()
            let allBack = ["APT.store", "APT.store-wal", ".APT_SUPPORT/原外置.bin"].allSatisfy { fm.fileExists(atPath: dir.appendingPathComponent($0).path) }
            check(outcome?.dataLeftAside == nil && outcome?.message.contains("原数据已全部放回原处") == true && allBack
                  && (try? Data(contentsOf: DataStore.storeURL)) == original
                  && !fm.fileExists(atPath: BackupService.restoreRequestURL.path) && BackupService.pendingRestore == nil,
                  "恢复中断在 moving、选“恢复前”放回原数据：数据目录三项齐全，标记已删除，没有原数据留在外面")
        }
    }
}
