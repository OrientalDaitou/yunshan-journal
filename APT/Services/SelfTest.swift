import Foundation
import SwiftData
import CoreData

/// 运行时自检：`APT.app/Contents/MacOS/APT --self-test [旧版数据库路径]`
/// 使用内存数据库；收件箱、快照、备份等文件操作全部放在临时数据目录里（没设 APT_STORE_DIR 时自动建一个），
/// 不读写正式数据；输出结果后退出（全部通过返回 0）。
@MainActor
enum SelfTest {
    static func runIfRequested() {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--render-pages"), args.count > index + 1 {
            let legacy = args.count > index + 2 ? args[index + 2] : LegacyReader.defaultDatabaseURL.path
            let scratch = isolateDataDirectory()
            PageRenderer.render(to: URL(fileURLWithPath: args[index + 1]), legacyPath: legacy)
            finish(0, scratch: scratch)
        }
        #if DEBUG
        // 演示数据（只在调试版里有）：必须设 APT_STORE_DIR 指向一个还没有数据库的文件夹，见 DemoSeeder.commandLine
        if let index = args.firstIndex(of: "--seed-demo") {
            exit(DemoSeeder.commandLine(args.count > index + 1 ? args[index + 1] : nil))
        }
        #endif
        if args.contains("--check-store") {
            exit(checkStore(inPlace: args.contains("--in-place")))
        }
        if let index = args.firstIndex(of: "--add") {
            exit(CourierService.commandLineAdd(args.count > index + 1 ? args[index + 1] : "-"))
        }
        guard let index = args.firstIndex(of: "--self-test") else { return }
        let path = args.count > index + 1 ? args[index + 1] : LegacyReader.defaultDatabaseURL.path
        let scratch = isolateDataDirectory()
        finish(run(legacyPath: path) ? 0 : 1, scratch: scratch)
    }

    /// 离屏渲染与自检：没指定 APT_STORE_DIR 时改用一个临时数据目录。DataStore.directory 每次都读环境变量，
    /// 所以收件箱、快照、备份、恢复标记都会落到临时目录，以后新增的后台任务也碰不到正式数据。返回自动建的目录（用完删掉）。
    private static func isolateDataDirectory() -> URL? {
        if DataStore.customDirectory != nil { return nil }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("APT-scratch-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("APT_STORE_DIR", dir.path, 1)
        return dir
    }

    private static func finish(_ code: Int32, scratch: URL?) -> Never {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
        exit(code)
    }

    /// `APT --check-store`：用新版代码打开数据库并列出各类条数，确认迁移无误。
    /// 默认先把数据库（连同 .APT_SUPPORT）拷到临时目录，只打开副本：新代码改过模型时，迁移只发生在副本上。
    /// `--check-store --in-place` 才直接打开数据文件夹里的库（应用正在运行时拒绝；构建变化时会先做“升级前”备份）。
    static func checkStore(inPlace: Bool = false) -> Int32 {
        setvbuf(stdout, nil, _IONBF, 0)
        let source = DataStore.directory
        var copy: URL?
        defer { if let copy { try? FileManager.default.removeItem(at: copy) } }
        do {
            let container: ModelContainer
            if inPlace {
                // 正在运行的应用（没设 APT_STORE_DIR）用的是正式数据目录：这时不许原地打开正式库
                if AppHost.otherInstanceRunning, DataStore.customDirectory == nil {
                    print("应用正在运行，为免两个进程同时迁移同一个数据库，--in-place 已取消。请先从菜单栏彻底退出应用，或去掉 --in-place 检查副本。")
                    return 2
                }
                container = try DataStore.makeContainer()
                print("数据库（原地打开）：\(DataStore.storeURL.path)")
            } else {
                guard FileManager.default.fileExists(atPath: DataStore.storeURL.path) else {
                    print("没有找到数据库：\(DataStore.storeURL.path)")
                    return 1
                }
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("APT-check-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                copy = dir
                try BackupService.snapshotStore(from: source, into: dir)
                setenv("APT_STORE_DIR", dir.path, 1)
                container = try DataStore.makeContainer(backupBeforeUpgrade: false)
                print("数据库：\(source.appendingPathComponent("APT.store").path)")
                print("（检查的是临时副本，正式数据库没有被打开；要原地打开请加 --in-place）")
            }
            let c = ModelContext(container)
            print("档案 \(c.all(Profile.self).count)，日程 \(c.all(ScheduleEvent.self).count)，作息 \(c.all(RoutineBlock.self).count)，习惯 \(c.all(Habit.self).count)，打卡 \(c.all(HabitLog.self).count)")
            print("修行录 \(c.all(JournalEntry.self).count)，传书 \(c.all(CourierDelivery.self).count)，旧版存档 \(c.all(LegacyRecord.self).count)")
            print("账簿交易 \((try? FinanceService.load(c).transactions.count) ?? -1)")
            return 0
        } catch {
            print("打开失败：\(DataStore.describe(error))")
            return 1
        }
    }

    static func run(legacyPath: String) -> Bool {
        var failures = 0
        func check(_ ok: Bool, _ message: String) {
            print(ok ? "✓ \(message)" : "✗ \(message)")
            if !ok { failures += 1 }
        }
        do {
            let container = try DataStore.makeContainer(inMemory: true)
            let context = ModelContext(container)
            DataStore.settings(in: context)
            DataStore.profile(in: context)
            DataStore.save(context)

            // 1. 旧版导入
            if FileManager.default.fileExists(atPath: legacyPath) {
                let snapshot = try LegacyReader.read(url: URL(fileURLWithPath: legacyPath))
                let expectedArchive = snapshot.recordCount + snapshot.settings.count + snapshot.extras.values.reduce(0) { $0 + $1.count }
                let preview = LegacyImporter.run(snapshot, context: context, dryRun: true)
                check(context.all(LegacyRecord.self).isEmpty && context.all(ScheduleEvent.self).isEmpty, "预览不写入数据")
                let report = LegacyImporter.run(snapshot, context: context, dryRun: false)
                check(report.archived == preview.archived && report.events == preview.events, "预览与实际导入一致")
                check(context.all(LegacyRecord.self).count == expectedArchive, "原样存档 \(context.all(LegacyRecord.self).count)/\(expectedArchive) 条")
                check(context.all(ScheduleEvent.self).count == (snapshot.collections["calendar"] ?? []).count, "日程 \(context.all(ScheduleEvent.self).count) 条")
                let profiles = context.all(Profile.self)
                check(profiles.count == 1, "档案只有一份（补全而不是重复新建）")
                check(report.profileFieldsFilled > 0 || (snapshot.collections["profile"] ?? []).isEmpty, "档案补全 \(report.profileFieldsFilled) 个字段")
                let again = LegacyImporter.run(snapshot, context: context, dryRun: false)
                check(again.archived == 0 && again.events == 0 && again.profileFieldsFilled == 0, "重复导入不产生重复数据")
                check(context.all(ImportReceipt.self).count == 2, "生成导入记录")
                // 在新版里删掉的导入内容、清空的档案字段，重复导入时不会复活 / 被填回
                if let imported = context.all(ScheduleEvent.self).first(where: { $0.legacyID != nil }), let profile = profiles.first,
                   !profile["city"].isEmpty {
                    let eventCount = context.all(ScheduleEvent.self).count
                    context.delete(imported)
                    profile["city"] = ""
                    DataStore.save(context)
                    let third = LegacyImporter.run(snapshot, context: context, dryRun: false)
                    check(third.deletedSkipped >= 1 && third.events == 0 && context.all(ScheduleEvent.self).count == eventCount - 1,
                          "在新版里删掉的日程，重复导入不会复活（跳过 \(third.deletedSkipped) 条）")
                    check(profile["city"].isEmpty, "清空的档案字段，重复导入不会被填回")
                }
                let ledger = try FinanceService.load(context)
                if snapshot.settings["finance_ledger_v1"] != nil {
                    check(!ledger.transactions.isEmpty && report.financeTransactions == ledger.transactions.count, "灵石账簿并入 \(ledger.transactions.count) 笔交易、\(ledger.monthlyReports.count) 份月报")
                    check(again.financeTransactions == 0, "重复导入不会重复记账")
                    let month = FinanceEngine.defaultMonth(ledger)
                    let saved = try FinanceService.mutate(context) { _ = FinanceEngine.saveReport(in: &$0, month: month, reflection: "自检") }
                    check(saved.monthlyReports.count == ledger.monthlyReports.count + 1, "保存月报（\(month)）")
                    check(try FinanceService.load(context).monthlyReports.count == saved.monthlyReports.count, "账本落盘后可重新读取")
                }
                let week = LocalDay.today().mondayOfWeek
                let items = Occurrences.list(events: context.all(ScheduleEvent.self), from: week, to: week.adding(days: 6))
                print("  本周日程：" + items.map { "\($0.day.weekdayName) \($0.title)" }.joined(separator: "，"))
            } else {
                print("（未找到旧版数据库，跳过导入检查）")
            }

            // 2. 习惯打卡与修为
            let effects = EffectsCenter()
            let habit = Habit(title: "自检习惯")
            habit.startDate = LocalDay.today().adding(days: -10).key
            context.insert(habit)
            DataStore.save(context)
            let config = CultivationConfig()
            for offset in 1...3 {
                HabitActions.toggle(habit, on: LocalDay.today().adding(days: -offset), context: context, effects: effects,
                                    allHabits: context.all(Habit.self), config: config)
            }
            check((habit.logs ?? []).count == 3, "打卡记录 \((habit.logs ?? []).count) 条")
            check(habit.stats().streak.count == 3, "连续 \(habit.stats().streak.count) 天")
            let state = CultivationService.state(context: context)
            check(state.totalXP == 90, "修为 \(state.totalXP)（3 天 × (10 + 圆满 20)）")
            HabitActions.toggle(habit, on: LocalDay.today().adding(days: -1), context: context, effects: effects,
                                allHabits: context.all(Habit.self), config: config)
            check((habit.logs ?? []).count == 2 && context.all(HabitLog.self).count == 2, "取消打卡会删除记录")
            check(CultivationService.state(context: context).totalXP == 60, "取消打卡同步扣回修为")

            // 3. 摘要与导出
            let summary = SummaryCollector.build(context: context, options: .init())
            let markdown = SummaryRenderer.markdown(summary, preamble: SummaryRenderer.defaultPreamble)
            check(markdown.contains("自检习惯") && !summary.profile.keys.contains("name"), "AI 摘要包含习惯、隐去姓名")
            let export = try DataExporter.fullExport(context: context)
            let parsed = try JSONSerialization.jsonObject(with: export) as? [String: Any]
            check((parsed?["habits"] as? [Any])?.count == 1, "完整导出 JSON 可解析（\(export.count) 字节）")
            check(parsed?["journal"] != nil && parsed?["finance_ledger"] != nil && parsed?["courier_deliveries"] != nil, "完整导出包含修行录、灵石账簿与传书记录")
            check(parsed?["format_version"] as? Int == DataExporter.formatVersion && parsed?["import_receipts"] != nil
                  && ((parsed?["habits"] as? [[String: Any]])?.first?["sort_order"] != nil), "完整导出补齐了排序、导入记录等字段")
            // 数量是无穷大 / NaN 时导出不崩溃（JSONSerialization 遇到会抛 ObjC 异常，do/catch 接不住），改写成 null
            let weird = HabitLog(dateKey: "2020-01-01")
            weird.quantity = .infinity
            context.insert(weird)
            weird.habit = habit
            let weirdExport = try DataExporter.fullExport(context: context)
            let weirdLogs = ((try JSONSerialization.jsonObject(with: weirdExport) as? [String: Any])?["habits"] as? [[String: Any]])?
                .flatMap { ($0["logs"] as? [[String: Any]]) ?? [] } ?? []
            check(weirdLogs.contains { $0["date"] as? String == "2020-01-01" && $0["quantity"] is NSNull }, "导出时无穷大的数量写成 null，不会崩溃")
            context.delete(weird)
            DataStore.save(context)

            // 4. 落盘后重新打开：数组、字典、关系都能读回
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("APT-selftest-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("test.store")
            do {
                let disk = try ModelContainer(for: Schema(APTSchema.models), configurations: [ModelConfiguration(schema: Schema(APTSchema.models), url: url)])
                let c = ModelContext(disk)
                let e = ScheduleEvent(title: "落盘测试", dateKey: "2026-10-12")
                e.recurrenceKind = .custom
                e.weekdays = [0, 2, 4]
                e.excludedDates = ["2026-10-14"]
                c.insert(e)
                c.insert(Profile(fields: ["city": "悉尼", "major": "EE"]))
                let h = Habit(title: "落盘习惯")
                c.insert(h)
                let log = HabitLog(dateKey: "2026-10-12")
                c.insert(log)
                log.habit = h
                let s = AppSettings()
                s.realms = ["一", "二"]
                s.thresholds = [0, 10]
                c.insert(s)
                try c.save()
            }
            do {
                let disk = try ModelContainer(for: Schema(APTSchema.models), configurations: [ModelConfiguration(schema: Schema(APTSchema.models), url: url)])
                let c = ModelContext(disk)
                let e = c.all(ScheduleEvent.self).first
                check(e?.weekdays == [0, 2, 4] && e?.excludedDates == ["2026-10-14"], "重开后数组字段完整：\(e?.weekdays ?? []) \(e?.excludedDates ?? [])")
                check(c.all(Profile.self).first?.fields == ["city": "悉尼", "major": "EE"], "重开后档案字典完整")
                check(c.all(Habit.self).first?.logs?.count == 1, "重开后习惯与打卡关系完整")
                check(c.all(AppSettings.self).first?.thresholds == [0, 10], "重开后设置数组完整")
            }

            // 5. 修行录与飞剑传书（只在内存库里写，不碰收件箱与快照）
            let xpBefore = CultivationService.state(context: context).totalXP
            JournalActions.save(JournalEntry(kind: .diary, title: "", body: "自检日记"), context: context, effects: effects)
            check(CultivationService.state(context: context).totalXP == xpBefore + JournalKind.diary.xp, "落笔日记 +\(JournalKind.diary.xp) 修为")
            let ledgerBefore = (try? FinanceService.load(context).transactions.count) ?? 0
            let json = """
            {"from":"自检","items":[
              {"type":"diary","body":"今天写完了第三章","mood":4,"tags":["论文","写作"]},
              {"type":"review","period":"week","title":"周复盘","body":"【所得】……"},
              {"type":"expense","amount":18.5,"category":"餐饮与外卖","description":"午饭 拉面"},
              {"type":"event","date":"tomorrow","start":"14:00","end":"15:30","title":"传书日程"},
              {"type":"checkin","habit":"自检","date":"today"}
            ]}
            """
            let payload = try CourierParser.parse(Data(json.utf8))
            let delivery = try CourierService.apply(payload, fileName: "selftest.json", context: context)
            check(delivery.itemCount == 5, "传书收录 \(delivery.itemCount)/5 条")
            check(context.all(JournalEntry.self).filter(\.isFromCourier).count == 2, "传书写入日记与复盘")
            check(context.all(ScheduleEvent.self).contains { $0.title == "传书日程" }, "传书写入日程")
            check(habit.log(on: .today()) != nil, "传书打卡（按名称模糊匹配习惯）")
            check(((try? FinanceService.load(context).transactions.count) ?? 0) == ledgerBefore + 1, "传书记账进入灵石账簿")
            // 修行录导出：Markdown 与 PDF
            let exportItems = JournalExport.items(context.all(JournalEntry.self))
            let md = JournalExport.markdown(exportItems, title: "自检导出")
            check(md.contains("今天写完了第三章") && md.contains("## "), "修行录导出 Markdown（\(exportItems.count) 篇）")
            let pdfURL = FileManager.default.temporaryDirectory.appendingPathComponent("APT-selftest-\(UUID().uuidString).pdf")
            defer { try? FileManager.default.removeItem(at: pdfURL) }
            try JournalExport.writePDF(html: JournalExport.html(exportItems, title: "自检导出"), to: pdfURL)
            let pdfSize = (try? FileManager.default.attributesOfItem(atPath: pdfURL.path)[.size] as? Int) ?? 0
            check(pdfSize > 1000, "修行录导出 PDF（\(pdfSize / 1024) KB）")
            let journalSummary = SummaryCollector.build(context: context, options: .init())
            check(SummaryRenderer.markdown(journalSummary, preamble: "").contains("今天写完了第三章"), "AI 摘要包含修行录")
            do {
                _ = try CourierService.apply(try CourierParser.parse(Data(#"{"items":[{"type":"note","body":"x"},{"type":"checkin","habit":"不存在的习惯"}]}"#.utf8)),
                                             fileName: "bad.json", context: context)
                check(false, "找不到习惯时应拒收")
            } catch {
                check(!context.all(JournalEntry.self).contains { $0.body == "x" }, "整份校验失败时一条都不写入")
            }
            for bad in [#"{"type":"diary"}"#, #"{"type":"expense","amount":-3,"description":"a"}"#, #"{"type":"event","title":"a","start":"25:00"}"#, #"{"type":"oops"}"#] {
                check((try? CourierParser.parse(Data(bad.utf8))) == nil, "拒收不合法条目：\(bad)")
            }
            CourierService.undo(delivery, context: context, refresh: false)
            check(context.all(JournalEntry.self).filter(\.isFromCourier).isEmpty && !context.all(ScheduleEvent.self).contains { $0.title == "传书日程" }
                  && habit.log(on: .today()) == nil && ((try? FinanceService.load(context).transactions.count) ?? 0) == ledgerBefore,
                  "撤销传书：日记、日程、打卡、账目全部撤回")

            // 6. 收件箱全流程：只在临时数据目录里运行（runIfRequested 已确保设置了 APT_STORE_DIR），不碰正式的收件箱
            if DataStore.customDirectory != nil {
                CourierService.prepareFolders()
                let good = CourierService.inbox.appendingPathComponent("selftest-good.json")
                let bad = CourierService.inbox.appendingPathComponent("selftest-bad.json")
                try Data(#"{"from":"自检","items":[{"type":"note","body":"收件箱自检灵感"}]}"#.utf8).write(to: good)
                try Data(#"{"items":[{"type":"expense","amount":0}]}"#.utf8).write(to: bad)
                let past = Date().addingTimeInterval(-5)
                for url in [good, bad] { try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: url.path) }
                // 用户正在编辑、尚未保存的内容，不能因为收件箱里有坏文件而被撤回
                let editing = JournalEntry(kind: .note, title: "", body: "编辑中")
                context.insert(editing)
                DataStore.save(context)
                editing.title = "尚未保存的修改"
                let delivered = CourierService.processInbox(context: context, effects: nil)
                check(editing.title == "尚未保存的修改", "坏文件不会冲掉用户未保存的修改")
                check(delivered == 1 && context.all(JournalEntry.self).contains { $0.body == "收件箱自检灵感" }, "收件箱收录合法文件")
                let processedFiles = (try? FileManager.default.contentsOfDirectory(atPath: CourierService.processed.path)) ?? []
                let failedFiles = (try? FileManager.default.contentsOfDirectory(atPath: CourierService.failed.path)) ?? []
                check(processedFiles.contains { $0.hasSuffix("selftest-good.result.txt") }, "原件移入 processed/ 并附回执")
                check(failedFiles.contains { $0.hasSuffix("selftest-bad.error.txt") }, "坏文件移入 failed/ 并附原因")
                check(CourierService.pendingFiles().isEmpty, "收件箱已清空")
                CourierService.refreshSnapshot(context: context)
                let snapshot = (try? String(contentsOf: CourierService.snapshotURL, encoding: .utf8)) ?? ""
                check(snapshot.contains("收件箱自检灵感") && FileManager.default.fileExists(atPath: CourierService.readmeURL.path), "快照与投递说明已写出")
            }

            // 7. 自动备份：在临时数据文件夹里建一个真正的磁盘数据库，备份后从备份打开核对
            if let dir = DataStore.customDirectory?.path {
                let disk = try DataStore.makeContainer()
                let dc = disk.mainContext
                dc.insert(JournalEntry(kind: .note, title: "备份自检", body: "这条应出现在备份里"))
                _ = try FinanceService.mutate(dc) { $0.transactions.append(ManualExpense.transaction(day: .today(), cents: 1234, category: "餐饮与外卖", description: "备份自检", note: "", reason: "自检")) }
                try dc.save()
                let folder = try BackupService.backup(context: dc, kind: .manual)
                let restoredDir = FileManager.default.temporaryDirectory.appendingPathComponent("APT-restore-\(UUID().uuidString)")
                try FileManager.default.copyItem(at: folder, to: restoredDir)
                defer { try? FileManager.default.removeItem(at: restoredDir) }
                let schema = Schema(APTSchema.models)
                let restored = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: restoredDir.appendingPathComponent("APT.store"))])
                let rc = ModelContext(restored)
                check(rc.all(JournalEntry.self).contains { $0.title == "备份自检" }, "备份可以打开，修行录完整")
                check(((try? FinanceService.load(rc).transactions.contains { $0.description == "备份自检" }) ?? false), "备份里的灵石账簿完整")
                check(FileManager.default.fileExists(atPath: folder.appendingPathComponent("APT-完整备份.json").path), "备份附带可读的 JSON")
                check(BackupService.runIfDue(context: dc) != nil && BackupService.runIfDue(context: dc) == nil, "每天只自动备份一次")
                check(BackupService.list().contains { $0.kind == .weekly }, "本周还没有每周备份时顺带留一份")

                // 7b. 备份是原子的：同一秒连做两份手动备份各自保留、互不删除；中途崩溃留下的 .partial 不算备份
                let now = Date()
                let first = try BackupService.backup(context: dc, kind: .manual, now: now)
                let second = try BackupService.backup(context: dc, kind: .manual, now: now)
                check(first != second && [first, second].allSatisfy { FileManager.default.fileExists(atPath: $0.appendingPathComponent("APT.store").path) },
                      "同一秒两次手动备份各自保留（\(first.lastPathComponent) / \(second.lastPathComponent)）")
                let half = BackupService.folder(for: .manual).appendingPathComponent("半份.partial", isDirectory: true)
                try FileManager.default.createDirectory(at: half, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: first.appendingPathComponent("APT.store"), to: half.appendingPathComponent("APT.store"))
                check(!BackupService.list().contains { $0.url.pathExtension == "partial" }, "未完成的 .partial 不算备份")
                BackupService.cleanupLeftovers()
                check(!FileManager.default.fileExists(atPath: half.path), "启动时清掉残留的 .partial")

                // 7c. 升级前备份：构建变了才在打开数据库前备份一次，只留最近 3 份
                let upgradeA = DataStore.backupBeforeUpgradeIfNeeded(stamp: "自检构建 A")
                let upgradeAgain = DataStore.backupBeforeUpgradeIfNeeded(stamp: "自检构建 A")
                check(upgradeA.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("APT.store").path) } == true && upgradeAgain == nil,
                      "构建变化时先做升级前备份，同一构建不重复")
                for (offset, name) in ["B", "C", "D"].enumerated() {
                    DataStore.backupBeforeUpgradeIfNeeded(stamp: "自检构建 \(name)", now: now.addingTimeInterval(Double(offset + 2)))
                }
                check(BackupService.list().filter { $0.kind == .preUpgrade }.count == BackupService.upgradeKeep, "升级前备份只留最近 \(BackupService.upgradeKeep) 份")

                // 7c'. 要迁移时（库的结构和这一版模型不同）留“迁移前”备份：不参与 3 份轮换，同一构建只留一次。
                // 用这一版模型建的库不能被误认为要迁移，否则每次启动都会多留一份不自动删除的备份
                check(DataStore.storeNeedsMigration() == false, "用这一版模型建的库不需要迁移")
                check((try? oldStructureNeedsMigration()) == true, "少了字段的旧结构库会被认出要迁移")
                let migrationA = DataStore.backupBeforeUpgradeIfNeeded(stamp: "自检构建 M", now: now.addingTimeInterval(10), needsMigration: true)
                let migrationAgain = DataStore.backupBeforeUpgradeIfNeeded(stamp: "自检构建 M", now: now.addingTimeInterval(11), needsMigration: true)
                for (offset, name) in ["N", "O", "P", "Q"].enumerated() {
                    DataStore.backupBeforeUpgradeIfNeeded(stamp: "自检构建 \(name)", now: now.addingTimeInterval(Double(offset + 12)))
                }
                let kept = BackupService.list()
                check(migrationA?.lastPathComponent.hasPrefix("迁移前-") == true && migrationAgain == nil
                      && kept.contains { $0.kind == .preMigration && $0.url.lastPathComponent == migrationA?.lastPathComponent }
                      && kept.filter { $0.kind == .preUpgrade }.count == BackupService.upgradeKeep,
                      "要迁移时先留“迁移前”备份，同一构建只留一次，不被“升级前”轮换挤掉")
                // “另存一份到…”写的是此刻的数据，直接写到目标位置，数据文件夹里不多留一份
                let elsewhere = FileManager.default.temporaryDirectory.appendingPathComponent("APT-elsewhere-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: elsewhere) }
                dc.insert(JournalEntry(kind: .note, title: "另存自检·此刻才写", body: "w"))
                let countBefore = BackupService.list().count
                let exported = try BackupService.exportCurrent(context: dc, to: elsewhere)
                let exportedTitles = Set(try ModelContext(ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: exported.appendingPathComponent("APT.store"))]))
                    .all(JournalEntry.self).map(\.title))
                check(exportedTitles.contains("另存自检·此刻才写") && BackupService.list().count == countBefore
                      && !((try? FileManager.default.contentsOfDirectory(atPath: elsewhere.path)) ?? []).contains { $0.hasSuffix(".partial") },
                      "另存一份：存出去的是此刻的数据，数据文件夹里不多留备份")
                // 单实例的兜底检查：能认出哪个进程正打开着数据库（这里是自检进程自己开着的临时库）
                var storeStat = stat()
                check(stat(DataStore.storeURL.path, &storeStat) == 0 && InstanceLock.process(getpid(), hasOpen: storeStat)
                      && !InstanceLock.storeOpenByAnotherInstance(waitingUpTo: 0),
                      "能认出打开着数据库的进程；没有别的云山修习录开着这份临时数据")

                // 7d. 从备份恢复：在另一个临时数据目录里做，现有数据先整体移到“恢复前”，再换上备份
                let restoreRoot = FileManager.default.temporaryDirectory.appendingPathComponent("APT-restore-test-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: restoreRoot, withIntermediateDirectories: true)
                setenv("APT_STORE_DIR", restoreRoot.path, 1)
                defer {
                    setenv("APT_STORE_DIR", dir, 1)
                    try? FileManager.default.removeItem(at: restoreRoot)
                }
                func openStore(_ url: URL) throws -> ModelContext {
                    ModelContext(try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url)]))
                }
                try autoreleasepool {
                    let c1 = try openStore(DataStore.storeURL)
                    c1.insert(JournalEntry(kind: .note, title: "恢复自检·备份时就有", body: "x"))
                    try c1.save()
                    let snapshot = try BackupService.backup(context: c1, kind: .manual)
                    c1.insert(JournalEntry(kind: .note, title: "恢复自检·备份之后才写", body: "y"))
                    try c1.save()
                    try BackupService.requestRestore(from: snapshot)
                }
                check(BackupService.pendingRestore != nil, "已记下待恢复的备份")
                let outcome = BackupService.applyPendingRestoreIfNeeded()
                check(outcome?.succeeded == true && BackupService.pendingRestore == nil, "启动时执行恢复：\(outcome?.message ?? "没有执行")")
                let titles = Set(try openStore(DataStore.storeURL).all(JournalEntry.self).map(\.title))
                check(titles.contains("恢复自检·备份时就有") && !titles.contains("恢复自检·备份之后才写"), "恢复后是备份时的数据")
                if let aside = BackupService.list().first(where: { $0.kind == .preRestore }) {
                    let old = try openStore(aside.url.appendingPathComponent("APT.store"))
                    check(old.all(JournalEntry.self).contains { $0.title == "恢复自检·备份之后才写" }, "恢复前的数据完整移到 \(aside.url.lastPathComponent)")
                } else {
                    check(false, "恢复前的数据应移到 Backups/恢复前-…")
                }
                try Data("不是 JSON".utf8).write(to: BackupService.restoreRequestURL)
                let badMarker = BackupService.applyPendingRestoreIfNeeded()
                check(badMarker?.succeeded == false && FileManager.default.fileExists(atPath: DataStore.storeURL.path)
                      && BackupService.list().filter { $0.kind == .preRestore }.count == 1, "恢复标记损坏时不动现有数据")
                let broken = restoreRoot.appendingPathComponent("坏备份", isDirectory: true)
                try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
                try Data(repeating: 7, count: 4096).write(to: broken.appendingPathComponent("APT.store"))
                check((try? BackupService.requestRestore(from: broken)) == nil, "损坏的备份不能用来恢复")

                // 7e. 恢复在第 2 步中途中断（只把 APT.store 移进“恢复前”就断电）：下次启动接着往同一个文件夹里移，
                // 原数据（连同 -wal、.APT_SUPPORT）不会被拆进两个文件夹
                let fm = FileManager.default
                func extendMarker(aside: URL, phase: String) throws {
                    var object = (try JSONSerialization.jsonObject(with: Data(contentsOf: BackupService.restoreRequestURL)) as? [String: Any]) ?? [:]
                    object["aside"] = aside.path
                    object["phase"] = phase
                    try JSONSerialization.data(withJSONObject: object).write(to: BackupService.restoreRequestURL)
                }
                var snapshot2: URL?
                try autoreleasepool {
                    let c2 = try openStore(DataStore.storeURL)
                    c2.insert(JournalEntry(kind: .note, title: "恢复自检·中断前写的", body: "z"))
                    try c2.save()
                    snapshot2 = try BackupService.backup(context: c2, kind: .manual)
                }
                if let snapshot2 {
                    try BackupService.requestRestore(from: snapshot2)
                    let dirItems = BackupService.storeItems.filter { fm.fileExists(atPath: DataStore.directory.appendingPathComponent($0).path) }
                    let interrupted = BackupService.root.appendingPathComponent("恢复前-中断自检", isDirectory: true)
                    try fm.createDirectory(at: interrupted, withIntermediateDirectories: true)
                    try extendMarker(aside: interrupted, phase: "moving")
                    try fm.moveItem(at: DataStore.storeURL, to: interrupted.appendingPathComponent("APT.store"))
                    let foldersBefore = BackupService.list().filter { $0.kind == .preRestore }.count
                    let resumed = BackupService.applyPendingRestoreIfNeeded()
                    let together = dirItems.allSatisfy { fm.fileExists(atPath: interrupted.appendingPathComponent($0).path) }
                    check(resumed?.succeeded == true && resumed?.message.contains("恢复前-中断自检/") == true && together
                          && BackupService.list().filter { $0.kind == .preRestore }.count == foldersBefore
                          && fm.fileExists(atPath: DataStore.storeURL.path) && BackupService.pendingRestore == nil,
                          "恢复中途断电后再启动：原数据（\(dirItems.joined(separator: "、"))）接着移进同一个“恢复前”文件夹")

                    // 中断后那份备份不见了：把已经移开的原数据放回原处
                    let gone = restoreRoot.appendingPathComponent("会被删掉的备份", isDirectory: true)
                    try fm.copyItem(at: snapshot2, to: gone)
                    try BackupService.requestRestore(from: gone)
                    let interrupted2 = BackupService.root.appendingPathComponent("恢复前-中断自检2", isDirectory: true)
                    try fm.createDirectory(at: interrupted2, withIntermediateDirectories: true)
                    try extendMarker(aside: interrupted2, phase: "moving")
                    try fm.moveItem(at: DataStore.storeURL, to: interrupted2.appendingPathComponent("APT.store"))
                    try fm.removeItem(at: gone)
                    let rolledBack = BackupService.applyPendingRestoreIfNeeded()
                    check(rolledBack?.succeeded == false && rolledBack?.dataLeftAside == nil && rolledBack?.message.contains("原数据已全部放回原处") == true
                          && fm.fileExists(atPath: DataStore.storeURL.path) && !fm.fileExists(atPath: interrupted2.path) && BackupService.pendingRestore == nil,
                          "中断后备份不见了：已移开的原数据放回原处")

                    // 原数据没能放回（这里用数据目录里另有一个同名文件来模拟）：给出位置、保留恢复标记，APTApp 据此不打开数据库
                    let gone3 = restoreRoot.appendingPathComponent("又会被删掉的备份", isDirectory: true)
                    try fm.copyItem(at: snapshot2, to: gone3)
                    try BackupService.requestRestore(from: gone3)
                    let stuck = BackupService.root.appendingPathComponent("恢复前-中断自检3", isDirectory: true)
                    try fm.createDirectory(at: stuck, withIntermediateDirectories: true)
                    try fm.copyItem(at: DataStore.storeURL, to: stuck.appendingPathComponent("APT.store"))
                    try extendMarker(aside: stuck, phase: "moving")
                    try fm.removeItem(at: gone3)
                    let stuckOutcome = BackupService.applyPendingRestoreIfNeeded()
                    check(stuckOutcome?.succeeded == false && stuckOutcome?.dataLeftAside?.lastPathComponent == "恢复前-中断自检3"
                          && BackupService.pendingRestore != nil && fm.fileExists(atPath: stuck.appendingPathComponent("APT.store").path),
                          "原数据没能放回时说明位置、保留恢复标记（这次不打开数据库）")
                    BackupService.cancelRestoreRequest()
                    try? fm.removeItem(at: stuck)
                }
            }

            // 8. 删除习惯级联删除打卡
            context.delete(habit)
            DataStore.save(context)
            check(context.all(HabitLog.self).isEmpty, "删除习惯时一并删除打卡")

            // 9–14. 这一轮修复新增的行为（各用一个干净的内存库）
            try courierChecks(check)
            try goalHabitChecks(check)
            try habitHistoryChecks(check)
            try ledgerChecks(check)
            try miscChecks(check)
            seriesSplitChecks(check)
            try legacyReimportChecks(check)
            // 17–18. 性能改动的对照：修为模型、当日修为差、按窗口取日程与摘要
            try cultivationChecks(check)
            try occurrenceWindowChecks(check)
            // 19–20. 第 1 轮修复的回归检查：传书档案撤销与回执、快照修为、偏好隔离、恢复中断、升级前清理（SelfTest+Round1.swift）
            try round1Checks(check)
            try coldLogsChecks(check)
            try annalsChecks(check)
            try insightChecks(check)   // 卷中洞见、问道灵枢长期趋势与隐去姓名（SelfTest+Insights）
            try snapshotDigestChecks(check)
            try ritualChecks(check)
            try polishChecks(check)   // 遗留打磨：撤销传书的说法、长卷借打卡、小抄预检（SelfTest+polish）
            try keysChecks(check)   // 快捷键一览：底本、换算、各页真的挂上了（SelfTest+keys）
            try emptyStateChecks(check)   // 空状态：小物对得上侧栏、各页留白等高、离屏“全空”（SelfTest+Empty）
            try fixAnnalsChecks(check)   // 岁月长卷：连续落笔三处同一个数、卷首灵石格的“部分”与对比句（SelfTest+fix-annals）
            try fixCourierChecks(check)   // 撤销目标更新按整个目标算：部分改过整个保留，预览、按钮、结果一致（SelfTest+fix-courier）
            r7KeysChecks(check)   // 渡劫画面盖着主窗口时页面按键不接（SelfTest+r7-keys）
            try storeIdentityChecks(check)   // 按数据库缓存的钥匙：反复新建、丢弃内存库后各缓存不串库（SelfTest+StoreIdentity）
            try quickParseChecks(check)   // 随手记随心：五类各记一条再撤销，修为、数量、备注、账、日程都还原（SelfTest+QuickParse）
            try reminderChecks(check)   // 落笔时辰 / 功课时辰 / 登录项：通知回复入卷、按库取数、调试实例不碰系统（SelfTest+Reminder）
            try promptsChecks(check)   // 首页落笔卡：问心签、晨课一愿、晚课三省、类型不再沿用（SelfTest+Prompts）
            try dashboardChecks(check)   // 首页结构：数量型 +1、旧笔新读取数、两栏不再强行等高（SelfTest+Dashboard）
            try menuBarChecks(check)   // 菜单栏小窗：功课签与 +1、今日已落、下一项、收起只收自己那扇窗（SelfTest+MenuBar）
            try habitTemplateChecks(check)   // #7 功法谱一键立好、＋1 累计、打破纪录的那一下（SelfTest+HabitTemplates）
            try bannerChecks(check)   // #22 横幅：窄窗口降一档、各档排得下、按钮行按量出的高度、柔光软件渲染、预热降优先级（SelfTest+Banner）
            try dialogsChecks(check)   // #24 弹窗与控件：底部渐隐、作息图小规矩、功课页 +1 用首页规则、弹窗放得下（SelfTest+Dialogs）
            try misc2Checks(check)   // #25 杂项：撤销说明的警示句、传书笺排版、账头不写两遍、渡劫暗晕、随手记 ⌘↩ 的说法（SelfTest+Misc2）
            try onboardingChecks(check)   // #8 筑基三关取数、老用户不出、本月落笔、所向只取进行中的（SelfTest+Onboarding）
            try courierToleranceChecks(check)   // #9 传书容错：同类说法、打卡对不上只退这一条、单位换算、回执首行、--add（SelfTest+CourierTolerance）
            try askAIChecks(check)   // #10 技能那一条命令：从 --add 输出取路径、按原名找回执；可以这样跟 AI 说（SelfTest+AskAI）
            try weeklyChecks(check)   // #11 七日小卷：两周取数、存为周复盘草稿（替换 / 接在后面）、小卷挂进窗口（SelfTest+Weekly）
            try reviewLoopChecks(check)   // #12 复盘闭环：上次的下一步取哪篇、参悟决定、本期花费、入卷清掉回访（SelfTest+ReviewLoop）
            try r2AnnalsChecks(check)   // #13 回看口径：长卷默认时段按最早一条记录、卷首格持平与稳在（SelfTest+r2-annals）
            try milestoneChecks(check)   // #16 印谱：第一次运行静默补记、一天最多庆一枚、次日补庆、集齐后不再取数（SelfTest+Milestones）
            try quickCapture2Checks(check)   // #19 随手记日期签按那天记、类别不沿用、小窗不重复快捷键提示、日程弹窗（SelfTest+QuickCapture2）
            try scheduleChecks(check)   // #23 时辰卷周视图：真日程按周展开后错位叠放、空周 08–20 点、每周一、四、5 年逐周翻（SelfTest+Schedule）
            try reminder2Checks(check)   // #17 提醒扩展：日程开始前、那年今日、周复盘本周实数，按库取数、点开去向、调试实例只记开关（SelfTest+Reminder2）
            try energyChecks(check)   // #20 能耗：没人看时动效视为关、一动即恢复，金光呼吸改 Core Animation（SelfTest+Energy）
            try energy2Checks(check)   // #21 能耗（后台）：传书门铃当场响、约 1–1.5 秒收录、60 秒兜底的觉可叫醒、作息指纹不整表取（SelfTest+Energy2）
            try hooksChecks(check)   // #14 首页回看入口：小卷“上次许下的下一步”取哪篇、出关按库取最近一条、纸笺只取那一周、通栏一格（SelfTest+Hooks）
            try moodCalendarChecks(check)   // #15 心境月历：借修行录摘要取数、改心境跟着变、点一格走“只看某一天”、5 年逐月翻、卡片画得出（SelfTest+MoodCalendar）
            try templatesChecks(check)   // #18 落笔模板：自存的存取、两个小弹窗放得下、带着模板的落笔框排得出来（SelfTest+Templates）
            try courierUIChecks(check)   // 传书界面接线：部分收录的笺“1 条未收”、退回行警示色、多封注明、撤销框不列、不换行空格、回执不催绝对日期（SelfTest+CourierUI）
            try tailsChecks(check)   // 收尾：小窗 +1 用首页规则、点打卡圈弹数量框也不自动收起、日程 / 目标弹窗加高、长卷“未导全”（SelfTest+Tails）
            try polish2Checks(check)   // 收尾小轮：纸笺到点出现 / 收起放过渡、删光那天后去掉“只看这天”、⌥⌘J 没注册上时三关改说菜单栏（SelfTest+Polish2）
            try offsiteChecks(check)   // 每周自动另存一份到选的文件夹：本周存过不再存、写进“云山修习录备份/<时间>/”、只留 8 份只删自己的、不在 / 不能写只记原因（SelfTest+Offsite）
        } catch {
            check(false, "异常：\(error)")
        }
        print(failures == 0 ? "运行时自检全部通过" : "\(failures) 项失败")
        return failures == 0
    }
}

// MARK: - 本轮修复的回归检查

extension SelfTest {
    /// 在临时文件夹里用“Habit 少一个 archivedAt 字段”的旧结构建一个库，看 storeNeedsMigration 能不能认出它要迁移
    static func oldStructureNeedsMigration() throws -> Bool {
        guard let model = NSManagedObjectModel.makeManagedObjectModel(for: APTSchema.models),
              let old = model.copy() as? NSManagedObjectModel,
              let habit = old.entitiesByName["Habit"] else { return false }
        habit.properties = habit.properties.filter { $0.name != "archivedAt" }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("APT-migration-check-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("旧结构.store")
        try autoreleasepool {
            let coordinator = NSPersistentStoreCoordinator(managedObjectModel: old)
            let store = try coordinator.addPersistentStore(type: .sqlite, at: url)
            try coordinator.remove(store)
        }
        return DataStore.storeNeedsMigration(at: url) == true
    }

    private static func freshContext() throws -> ModelContext {
        let context = ModelContext(try DataStore.makeContainer(inMemory: true))
        DataStore.settings(in: context)
        DataStore.profile(in: context)
        DataStore.save(context)
        return context
    }

    /// 9–10. 飞剑传书：撤销保留收录后改过的条目、账本出错时什么都不删；收件箱按写入时刻换算相对日期、重复投递去重
    static func courierChecks(_ check: (Bool, String) -> Void) throws {
        let c = try freshContext()
        let today = LocalDay.today()
        let h = Habit(title: "撤销自检习惯")
        h.startDate = today.adding(days: -10).key
        c.insert(h)
        DataStore.save(c)
        func deliver(_ body: String) throws -> CourierDelivery {
            let json = """
            {"from":"自检","items":[
              {"type":"diary","date":"\(today.key)","body":"\(body)"},
              {"type":"event","date":"\(today.key)","start":"09:00","end":"10:00","title":"\(body)·日程"},
              {"type":"checkin","date":"\(today.key)","habit":"撤销自检习惯"}
            ]}
            """
            return try CourierService.apply(try CourierParser.parse(Data(json.utf8)), fileName: "\(body).json", context: c)
        }

        // 9a. 默认保留收录后改过的（这里改过日记）
        let d1 = try deliver("撤销自检一")
        let diary = c.all(JournalEntry.self).first { $0.body == "撤销自检一" }
        diary?.updatedAt = d1.receivedAt.addingTimeInterval(10)
        let preview = CourierService.undoPreview(d1, context: c)
        check(preview.total == 3 && preview.edited == 1, "撤销前预览：共 \(preview.total) 条，其中 \(preview.edited) 条收录后改过")
        let r1 = CourierService.undo(d1, context: c, refresh: false)
        check(r1.removed == 2 && r1.keptEdited == 1 && r1.failure == nil && d1.undone && d1.summary.contains("保留了 1 条"),
              "撤销传书默认保留改过的条目（删 \(r1.removed)、留 \(r1.keptEdited)）")
        check(c.all(JournalEntry.self).contains { $0.body == "撤销自检一" } && !c.all(ScheduleEvent.self).contains { $0.title == "撤销自检一·日程" }
              && h.log(on: today) == nil, "改过的日记还在，没改过的日程与打卡已撤回")
        check(CourierService.undo(d1, context: c, refresh: false).failure != nil, "同一封传书不能撤销两次")

        // 9b. 珍藏也算改过；选“全部撤销”时一并删掉
        let d2 = try deliver("撤销自检二")
        c.all(JournalEntry.self).first { $0.body == "撤销自检二" }?.pinned = true
        check(CourierService.undoPreview(d2, context: c).edited == 1, "珍藏过的日记算作改过")
        let r2 = CourierService.undo(d2, context: c, refresh: false, keepEdited: false)
        check(r2.removed == 3 && r2.keptEdited == 0 && !c.all(JournalEntry.self).contains { $0.body == "撤销自检二" }, "全部撤销（含改过的）")

        // 9c. 账本读不出来时什么都不删，传书保持未撤销；账本恢复后可以再撤
        let expenseJSON = #"{"from":"自检","items":[{"type":"note","body":"撤销自检三"},{"type":"expense","amount":12.5,"description":"撤销自检三·账"}]}"#
        let d3 = try CourierService.apply(try CourierParser.parse(Data(expenseJSON.utf8)), fileName: "three.json", context: c)
        if let store = try FinanceService.fetchStore(c) {
            let original = store.data
            store.data = Data("x".utf8)
            store.updatedAt = Date()
            let broken = CourierService.undo(d3, context: c, refresh: false)
            check(broken.failure != nil && broken.removed == 0 && !d3.undone && c.all(JournalEntry.self).contains { $0.body == "撤销自检三" },
                  "账本出错时撤销不删任何记录：\(broken.failure ?? "")")
            store.data = original
            store.updatedAt = Date()
            let fixed = CourierService.undo(d3, context: c, refresh: false)
            check(fixed.failure == nil && fixed.removed == 2 && d3.undone, "账本恢复后可以正常撤销")
        } else {
            check(false, "传书记账后应有账本")
        }

        // 9d. 在账簿里确认过类别的账目算作改过，默认保留
        let d4 = try CourierService.apply(try CourierParser.parse(Data(#"{"items":[{"type":"expense","amount":7,"description":"撤销自检四·账"}]}"#.utf8)),
                                          fileName: "four.json", context: c)
        if let row = try FinanceService.load(c).transactions.first(where: { $0.description == "撤销自检四·账" }) {
            _ = try FinanceService.mutate(c) { try FinanceEngine.updateTransaction(in: &$0, id: row.id, category: "购物", note: "", remember: false) }
            check(CourierService.undoPreview(d4, context: c).edited == 1, "在账簿里确认过的传书账目算作改过")
            CourierService.undo(d4, context: c, refresh: false)
            check(try FinanceService.load(c).transactions.contains { $0.id == row.id }, "撤销时保留确认过的账目")
        } else {
            check(false, "传书账目应写进账簿")
        }

        // 9e. 档案：只改写到的字段（认中文名，不看 date）；撤销时恢复原内容，收录后被用户改过的字段默认保留
        let profile = DataStore.profile(in: c)
        profile["city"] = "悉尼"
        profile["main_tasks"] = "旧任务"
        DataStore.save(c)
        let profileJSON = #"{"from":"自检","items":[{"type":"profile","date":"2020-01-01","fields":{"main_tasks":"新任务","职业目标":"自检职业","work_style":"","preferred_work_time":"上午\n晚上","city":"悉尼"}}]}"#
        let profilePayload = try CourierParser.parse(Data(profileJSON.utf8))
        check(profilePayload.relativeDates == 0 && profilePayload.warnings.contains { $0.contains("当作 career_goals") }
              && profilePayload.warnings.contains { $0.contains("不用 date") }, "档案传书认中文字段名、不看日期")
        let d5 = try CourierService.apply(profilePayload, fileName: "five.json", context: c)
        check(profile["main_tasks"] == "新任务" && profile["career_goals"] == "自检职业" && profile["preferred_work_time"] == "上午；晚上"
              && profile["work_style"].isEmpty && d5.itemCount == 3 && d5.summary.contains("所在城市（已是这个内容，跳过）"),
              "档案传书只改写到的字段（\(d5.itemCount) 项），空白不清掉、相同内容跳过")
        profile["career_goals"] = "用户改过"
        let p5 = CourierService.undoPreview(d5, context: c)
        check(p5.total == 3 && p5.edited == 1, "档案撤销预览：共 \(p5.total) 项，其中 \(p5.edited) 项收录后改过")
        let r5 = CourierService.undo(d5, context: c, refresh: false)
        check(r5.removed == 2 && r5.keptEdited == 1 && profile["main_tasks"] == "旧任务" && profile["career_goals"] == "用户改过"
              && profile["preferred_work_time"].isEmpty && profile["city"] == "悉尼", "撤销档案传书恢复原内容，保留用户改过的字段")
        for bad in [#"{"type":"profile","fields":{"不存在的字段":"x"}}"#, #"{"type":"profile","fields":{"main_tasks":"  "}}"#,
                    #"{"type":"profile","fields":"main_tasks"}"#, #"{"type":"profile","fields":{"main_tasks":["a"]}}"#,
                    #"{"type":"profile","fields":{"main_tasks":"a","主要任务":"b"}}"#] {
            check((try? CourierParser.parse(Data(bad.utf8))) == nil, "拒收不合法的档案传书：\(bad)")
        }

        // 10. 收件箱（只在临时数据目录里）
        guard DataStore.customDirectory != nil else { return }
        CourierService.prepareFolders()
        let inbox = CourierService.inbox
        let yesterday = today.adding(days: -1)
        let relative = inbox.appendingPathComponent("selftest-relative.json")
        let dupA = inbox.appendingPathComponent("selftest-dup-a.json")
        let dupB = inbox.appendingPathComponent("selftest-dup-b.json")
        let huge = inbox.appendingPathComponent("selftest-huge.json")
        try Data(#"{"from":"自检","items":[{"type":"note","body":"自检·昨晚写的"}]}"#.utf8).write(to: relative)
        try Data(#"{"items":[{"type":"note","body":"自检·重复测试","date":"\#(today.key)"}]}"#.utf8).write(to: dupA)
        try Data(#"[{"date":"\#(today.key)","body":"自检·重复测试  ","type":"note"}]"#.utf8).write(to: dupB)
        try Data(repeating: 32, count: CourierService.maxFileSize + 10).write(to: huge)
        // 昨晚 23:00 写进收件箱、今天才收录：“省略日期”应记在昨天
        try FileManager.default.setAttributes([.modificationDate: yesterday.date(minutes: 23 * 60)], ofItemAtPath: relative.path)
        for url in [dupA, dupB, huge] {
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-5)], ofItemAtPath: url.path)
        }
        let received = CourierService.processInbox(context: c, effects: nil)
        let lateEntry = c.all(JournalEntry.self).first { $0.body == "自检·昨晚写的" }
        check(lateEntry?.dateKey == yesterday.key, "相对日期按文件写入时刻换算（\(lateEntry?.dateKey ?? "没收录")）")
        let lateDelivery = c.all(CourierDelivery.self).first { $0.fileName == "selftest-relative.json" }
        check(lateDelivery?.summary.contains("相对日期按写入那天") == true, "隔天收录时传书摘要注明按写入那天换算")
        check(received == 2 && c.all(JournalEntry.self).filter { $0.body.hasPrefix("自检·重复测试") }.count == 1,
              "同样内容（字段顺序、空白不同）重复投递只收录一次")
        let processedFiles = (try? FileManager.default.contentsOfDirectory(at: CourierService.processed, includingPropertiesForKeys: nil)) ?? []
        let skipped = processedFiles.filter { $0.lastPathComponent.hasSuffix("selftest-dup-b.result.txt") }
            .contains { ((try? String(contentsOf: $0, encoding: .utf8)) ?? "").contains("重复投递，已跳过") }
        check(skipped, "重复投递的回执写明“重复投递，已跳过”")
        let relativeReceipt = processedFiles.filter { $0.lastPathComponent.hasSuffix("selftest-relative.result.txt") }
            .contains { ((try? String(contentsOf: $0, encoding: .utf8)) ?? "").contains("文件写入时刻") }
        check(relativeReceipt, "回执说明相对日期按文件写入时刻换算")
        let failedFiles = (try? FileManager.default.contentsOfDirectory(at: CourierService.failed, includingPropertiesForKeys: nil)) ?? []
        let tooBig = failedFiles.filter { $0.lastPathComponent.hasSuffix("selftest-huge.error.txt") }
            .contains { ((try? String(contentsOf: $0, encoding: .utf8)) ?? "").contains("文件太大") }
        check(tooBig, "超过 1 MB 的投递不读取，移到 failed/ 并说明")
        CourierService.refreshSnapshot(context: c)
        let firstWrite = (try? FileManager.default.attributesOfItem(atPath: CourierService.snapshotURL.path)[.modificationDate] as? Date) ?? nil
        Thread.sleep(forTimeInterval: 1.1)
        CourierService.refreshSnapshot(context: c)
        let secondWrite = (try? FileManager.default.attributesOfItem(atPath: CourierService.snapshotURL.path)[.modificationDate] as? Date) ?? nil
        check(firstWrite != nil && firstWrite == secondWrite, "数据没变时快照不重写")
    }

    /// 11. 习惯：归档、改数量目标不改写历史修为；未达标的真实数量不会被打卡改写
    static func habitHistoryChecks(_ check: (Bool, String) -> Void) throws {
        let today = LocalDay.today()
        let config = CultivationConfig()
        let effects = EffectsCenter()

        // 11a. 改数量目标：改之前把旧打卡记成当时的目标，历史修为与连续天数不变
        let c = try freshContext()
        let q = Habit(title: "数量自检")
        q.targetValue = 30
        q.unit = "分钟"
        q.startDate = today.adding(days: -10).key
        q.createdAt = Date().addingTimeInterval(-20 * 86400)
        c.insert(q)
        for offset in 1...6 {
            let log = HabitLog(dateKey: today.adding(days: -offset).key, completed: true, quantity: 30)
            c.insert(log)
            log.habit = q
        }
        DataStore.save(c)
        let before = CultivationService.state(context: c).totalXP
        let streakBefore = q.stats().streak.count
        let filled = HabitQuantity.recordTargetsBeforeChange(q, to: 45)
        q.targetValue = 45
        DataStore.save(c)
        check(filled == 6 && before == 180 && CultivationService.state(context: c).totalXP == before && q.stats().streak.count == streakBefore,
              "数量目标 30 → 45 不改写历史（修为 \(before)、连续 \(streakBefore) 天）")
        check(HabitQuantity.recordTargetsBeforeChange(q, to: 45) == 0, "目标没变时不再补记")

        // 11a'. 新目标从改的当天起生效：今天已有的打卡不补记旧目标，显示、达标判定都按新目标
        let ct = try freshContext()
        let t = Habit(title: "改目标当天自检")
        t.targetValue = 30
        t.startDate = today.adding(days: -10).key
        t.createdAt = Date().addingTimeInterval(-20 * 86400)
        ct.insert(t)
        var dayLogs: [HabitLog] = []
        for offset in [1, 0] {
            let log = HabitLog(dateKey: today.adding(days: -offset).key, completed: true, quantity: 30)
            ct.insert(log)
            log.habit = t
            dayLogs.append(log)
        }
        DataStore.save(ct)
        let filledToday = HabitQuantity.recordTargetsBeforeChange(t, to: 45)
        t.targetValue = 45
        DataStore.save(ct)
        check(filledToday == 1 && dayLogs[0].targetAtLog == 30 && dayLogs[1].targetAtLog == nil
              && HabitQuantity.target(t, on: today) == 45 && HabitQuantity.target(t, on: today.adding(days: -1)) == 30
              && !t.stats().isAchieved(today) && t.stats().isAchieved(today.adding(days: -1)) && HabitQuantity.needsInput(t, on: today),
              "改数量目标当天：昨天仍按 30 达标，今天已记的 30 按新目标 45 判定未达标")

        // 11b. 未达标的真实数量：打卡圈不把它改写成目标值
        let partial = HabitLog(dateKey: today.key, completed: true, quantity: 15)
        c.insert(partial)
        partial.habit = q
        DataStore.save(c)
        let result = HabitActions.toggle(q, on: today, context: c, effects: effects, allHabits: c.all(Habit.self), config: config)
        check(result == .needsQuantity && partial.quantity == 15 && q.log(on: today) === partial, "未达标的真实数量不会被打卡改写成目标值")
        check(HabitQuantity.needsInput(q, on: today) && !HabitQuantity.needsInput(q, on: today.adding(days: -1)), "只有未达标的那天需要填数量")

        // 11c. 归档：归档日之前的“功课圆满”照常计入，取消归档后与从未归档相同
        let c2 = try freshContext()
        let a = Habit(title: "归档自检甲"), b = Habit(title: "归档自检乙")
        for habit in [a, b] {
            habit.startDate = today.adding(days: -20).key
            habit.createdAt = Date().addingTimeInterval(-21 * 86400)
            c2.insert(habit)
        }
        for offset in 1...20 {
            let day = today.adding(days: -offset)
            let la = HabitLog(dateKey: day.key)
            c2.insert(la)
            la.habit = a
            if offset % 2 == 0 {
                let lb = HabitLog(dateKey: day.key)
                c2.insert(lb)
                lb.habit = b
            }
        }
        DataStore.save(c2)
        let original = CultivationService.state(context: c2)
        b.archived = true
        b.archivedAt = today.key
        DataStore.save(c2)
        let archived = CultivationService.state(context: c2)
        let pastSame = (1...20).allSatisfy { archived.perDay[today.adding(days: -$0)] == original.perDay[today.adding(days: -$0)] }
        check(pastSame, "归档不改写归档日之前每一天的修为（总修为 \(original.totalXP) → \(archived.totalXP)）")
        b.archived = false
        b.archivedAt = nil
        DataStore.save(c2)
        check(CultivationService.state(context: c2).totalXP == original.totalXP, "取消归档后与从未归档相同")
    }

    /// 12. 灵石账簿：手记可改可删、银行流水可设为不计入统计
    static func ledgerChecks(_ check: (Bool, String) -> Void) throws {
        let c = try freshContext()
        let today = LocalDay.today()
        let row = ManualExpense.transaction(day: today, cents: 1234, category: "餐饮与外卖", description: "手记自检", note: "", reason: "自检")
        _ = try FinanceService.mutate(c) { $0.transactions.append(row) }
        _ = try FinanceService.mutate(c) {
            try FinanceEngine.editManual(in: &$0, id: row.id, date: today.adding(days: -1).key, cents: 1800, description: "手记自检·改过")
        }
        let edited = try FinanceService.load(c).transactions.first { $0.id == row.id }
        check(edited?.amountCents == -1800 && edited?.date == today.adding(days: -1).key && edited?.description == "手记自检·改过" && edited?.kind == "消费",
              "手记可以改金额、日期、说明")
        _ = try FinanceService.mutate(c) { try FinanceEngine.deleteTransaction(in: &$0, id: row.id) }
        let gone = try !FinanceService.load(c).transactions.contains { $0.id == row.id }
        check(gone, "手记可以删除")

        let month = String(today.key.prefix(7))
        let (y, m) = (Int(month.prefix(4))!, Int(month.suffix(2))!)
        let csv = String(format: "01/%02d/%04d,-20.00,COLES,100.00\n02/%02d/%04d,-5.00,WOOLWORTHS,95.00\n", m, y, m, y)
        _ = try FinanceService.mutate(c) { $0.transactions += try FinanceEngine.parseCSV(csv, account: "自检账户") }
        let bank = try FinanceService.load(c).transactions.first { $0.description == "COLES" }!
        let spendBefore = FinanceEngine.monthFacts(try FinanceService.load(c), month: month).spendCents
        let refused = (try? FinanceService.mutate(c) { try FinanceEngine.deleteTransaction(in: &$0, id: bank.id) }) == nil
        let stillThere = try FinanceService.load(c).transactions.contains { $0.id == bank.id }
        check(refused && stillThere, "银行导入的交易不能单删")
        _ = try FinanceService.mutate(c) { try FinanceEngine.setIgnored(in: &$0, id: bank.id, ignored: true) }
        let spendIgnored = FinanceEngine.monthFacts(try FinanceService.load(c), month: month).spendCents
        check(spendIgnored == spendBefore - 2000, "设为“不计入统计”后不再算进消费（\(spendBefore) → \(spendIgnored) 分）")
        let restored = try FinanceService.mutate(c) { try FinanceEngine.setIgnored(in: &$0, id: bank.id, ignored: false) }
        let json = String(decoding: try restored.encoded(), as: UTF8.self)
        check(FinanceEngine.monthFacts(restored, month: month).spendCents == spendBefore && !json.contains("\"ignored\""),
              "改回计入后数值恢复，账本 JSON 与旧版格式一致")

        // 传书补记的消费与账上已有的银行流水金额相同、日期相近：照常收录，回执里提醒 AI 向用户确认
        let first = String(format: "%04d-%02d-01", y, m)
        let body = #"{"from":"自检","items":[{"type":"expense","date":"\#(first)","amount":20,"description":"超市"},"#
            + #"{"type":"expense","date":"\#(first)","amount":7.77,"description":"别的"}]}"#
        let payload = try CourierParser.parse(Data(body.utf8), relativeTo: today, latest: today)
        let (delivery, notices) = try CourierService.applyWithNotices(payload, fileName: "selftest-bank-match.json", context: c)
        check(delivery.itemCount == 2 && notices.count == 1 && notices[0].hasPrefix("第 1 条 expense") && notices[0].contains("COLES")
              && notices[0].contains("可能重复"), "传书记账与已导入的银行流水疑似重复：照常收录，回执提醒确认")
    }

    /// 13–14. 修行录删除可撤销、单次改期、输入解析、导出清洗、后台服务不在命令行模式启动、单实例锁
    static func miscChecks(_ check: (Bool, String) -> Void) throws {
        let c = try freshContext()
        let today = LocalDay.today()

        // 13a. 删除一篇可以原样找回（uid、来源、珍藏、时间都不变，修为恢复）
        let entry = JournalEntry(kind: .diary, title: "删除自检", body: "原样找回")
        entry.tags = ["自检"]
        entry.mood = 4
        entry.minute = 600
        entry.pinned = true
        entry.source = "courier"
        entry.deliveryID = "selftest-delivery"
        entry.sourceNote = "自检"
        c.insert(entry)
        DataStore.save(c)
        let uid = entry.uid, created = entry.createdAt, updated = entry.updatedAt
        let xp = CultivationService.state(context: c).totalXP
        let snapshot = JournalActions.delete(entry, context: c, effects: nil)
        check(!c.all(JournalEntry.self).contains { $0.uid == uid } && CultivationService.state(context: c).totalXP < xp, "删除一篇并扣回修为")
        JournalActions.restore(snapshot, context: c, effects: nil)
        let back = c.all(JournalEntry.self).first { $0.uid == uid }
        check(back?.tags == ["自检"] && back?.mood == 4 && back?.minute == 600 && back?.pinned == true && back?.source == "courier"
              && back?.deliveryID == "selftest-delivery" && back?.createdAt == created && back?.updatedAt == updated
              && CultivationService.state(context: c).totalXP == xp, "撤销删除：原样找回、修为恢复")

        // 13b. 重复日程“仅修改这一次”：只改那一次，保留旧版改期里不认识的字段
        let monday = today.mondayOfWeek
        let event = ScheduleEvent(title: "改期自检", dateKey: monday.key)
        event.recurrenceKind = .weekly
        event.startMinute = 600
        event.endMinute = 660
        event.overridesJSON = #"{"\#(monday.key)":{"legacy_extra":1,"location":"旧"}}"#
        c.insert(event)
        let next = monday.adding(days: 7)
        let wrote = OccurrenceOverrides.write(OccurrencePatch(title: "改", start_time: "14:00", end_time: "15:00"), for: next.key, on: event)
        let items = Occurrences.list(events: [event], from: monday, to: monday.adding(days: 20))
        let changed = items.first { $0.sourceDay == next }
        check(wrote && changed?.title == "改" && changed?.startMinute == 840 && changed?.isOverride == true
              && items.first { $0.sourceDay == monday.adding(days: 14) }?.title == "改期自检" && event.overridesJSON.contains("legacy_extra"),
              "仅修改这一次：只改那一次，旧版改期字段原样保留")
        OccurrenceOverrides.write(nil, for: next.key, on: event)
        check(!event.overridesJSON.contains(next.key) && event.overridesJSON.contains("旧"), "恢复为系列设置")
        let garbled = ScheduleEvent(title: "坏改期", dateKey: monday.key)
        garbled.overridesJSON = "not json"
        check(!OccurrenceOverrides.write(OccurrencePatch(title: "x"), for: next.key, on: garbled) && garbled.overridesJSON == "not json",
              "改期数据无法解析时拒写，原文不动")

        // 13c. 输入解析（金额解析是纯 Core，用例在 Tools/CoreCheck 里）
        let quantities: [(String, Double?)] = [("8,500", 8500), ("8，500", 8500), ("1,234,567.5", 1_234_567.5), ("1,5", 1.5), ("0,500", 0.5),
                                               ("abc", nil), ("", nil), ("1e30", nil), ("inf", nil)]
        let badQuantities = quantities.filter { HabitQuantity.parse($0.0) != $0.1 }.map(\.0)
        check(badQuantities.isEmpty, "功课数量解析（千分位、小数逗号，拒收 inf）" + (badQuantities.isEmpty ? "" : "，不符：\(badQuantities)"))

        // 13d. 导出时把无穷大 / NaN 换成 null，布尔值不受影响
        let cleaned = DataExporter.sanitized(["b": true, "n": Double.nan, "a": [1, Double.infinity]] as [String: Any]) as? [String: Any]
        check(cleaned?["b"] as? Bool == true && cleaned?["n"] is NSNull && ((cleaned?["a"] as? [Any])?.last is NSNull), "导出清洗：非有限数换成 null")

        // 13e. 撤销传书的结果提示
        let effects = EffectsCenter()
        effects.courierUndoResult(removed: 3, keptEdited: 1, failure: nil)
        check(effects.courier?.title == "已撤销此书" && effects.courier?.flies == false && effects.courier?.deliveryID == nil, "撤销结果提示（不放飞剑）")
        effects.courierUndoResult(removed: 0, keptEdited: 0, failure: "账本写入失败")
        check(effects.courier?.failed == true && effects.courier?.lines.contains("账本写入失败") == true, "撤销失败时显示原因")
        // 重复投递被跳过的原件在 AI/processed/，传书笺不能说成“原件在 AI/failed/”
        let skip = "重复投递，已跳过：与 10月14日 09:00 收录的传书内容相同，这次没有写入（原件在 AI/processed/）。"
        effects.courierFailed(file: "a.json", message: skip)
        check(effects.courier?.title == "传书已跳过" && effects.courier?.failed == false
              && effects.courier?.lines.contains { $0.contains("AI/failed/") } == false, "重复投递：传书笺写“已跳过”，不指向 AI/failed/")
        effects.courierBatch(deliveries: [], failures: [("a.json", skip), ("b.json", "第 1 条：缺少 body")])
        check(effects.courier?.title == "传书未能收录" && effects.courier?.detail.contains("1 封未收录（原件在 AI/failed/）") == true
              && effects.courier?.detail.contains("1 封重复已跳过") == true, "一轮里有重复也有出错：分开计数")

        // 14. 命令行 / 离屏模式绝不启动后台服务；同一份数据只允许一个进程打开
        check(!AppHost.isInteractiveLaunch && !AppHost.shared.isRunning, "自检模式下不启动传书巡查、自动备份")
        if DataStore.customDirectory != nil {
            check(InstanceLock.acquire() && InstanceLock.acquire(), "拿到数据目录的单实例锁（重复调用不冲突）")
            let other = open(InstanceLock.lockURL.path, O_RDWR)
            let blocked = other >= 0 && flock(other, LOCK_EX | LOCK_NB) != 0
            if other >= 0 { close(other) }
            check(blocked, "另一个进程再要这份数据的锁会被拒绝")
        }
    }

    /// 15. 重复日程“从这次起修改”：原系列在拆分日之前停止、只留之前的跳过与改期；新系列从拆分日开始、带上其余的；
    /// 两段合起来与拆分前完全一致、没有重复（与 ScheduleEditor.save 的拆分做法相同）
    static func seriesSplitChecks(_ check: (Bool, String) -> Void) {
        // 每 2 周的周二、周四，从几周前的周二开始；从第 3 个有课的周（第 4 周）的周四拆分
        let start = LocalDay.today().mondayOfWeek.adding(days: -35 + 1)
        let split = start.adding(days: 30)
        let rule0 = RecurrenceRule(start: start, kind: .custom, interval: 2, weekdays: [1, 3])
        var rule = rule0
        let excluded = [start.adding(days: 2), start.adding(days: 28), start.adding(days: 44)].map(\.key)
        let overrides: [String: Any] = [
            start.adding(days: 14).key: ["title": "改", "legacy_x": 1] as [String: Any],
            split.key: ["date": start.adding(days: 31).key, "legacy_y": "keep"],
            start.adding(days: 42).key: ["date": start.adding(days: 27).key],     // 拆分日之后的一次挪到了拆分日之前
            "bad-key": ["notes": "认不出的键留在原系列"],
        ]
        let json = (try? JSONSerialization.data(withJSONObject: overrides, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? ""
        rule.excluded = Set(excluded)
        rule.overrides = OccurrencePatch.decodeMap(json)
        let lo = start.adding(days: -7), hi = start.adding(days: 140)
        let before = rule.occurrences(from: lo, to: hi)
        guard let parts = SeriesSplit.partitionOverrides(json, at: split) else {
            check(false, "从这次起修改：单次改期切分失败")
            return
        }
        var original = rule
        original.excluded = Set(excluded.filter { !SeriesSplit.movesToNew($0, from: split) })
        original.overrides = OccurrencePatch.decodeMap(parts.before)
        original.stopBefore = split
        var fresh = RecurrenceRule(start: split, kind: rule0.kind, interval: rule0.interval, weekdays: rule0.weekdays)
        fresh.excluded = Set(excluded.filter { SeriesSplit.movesToNew($0, from: split) })
        fresh.overrides = OccurrencePatch.decodeMap(parts.after)
        let a = original.occurrences(from: lo, to: hi), b = fresh.occurrences(from: lo, to: hi)
        let union = Set(a).union(b)
        check(before.count > 10 && a.count + b.count == union.count && union == Set(before)
              && b.contains { $0.sourceDay == split } && !a.contains { $0.sourceDay >= split },
              "从这次起修改：两段合起来与拆分前完全一致（\(before.count) 次）、没有重复")
        check(parts.before.contains("legacy_x") && parts.before.contains("bad-key") && !parts.before.contains(split.key)
              && parts.after.contains("legacy_y") && parts.after.contains(start.adding(days: 42).key) && !parts.after.contains("legacy_x"),
              "从这次起修改：旧版不认识的改期字段留在对应的那一半")
        check(SeriesSplit.partitionOverrides("not json", at: split) == nil, "从这次起修改：改期数据无法解析时拒绝拆分")
    }

    /// 16. 重复导入旧版：这一天已有你手动打的卡（槽位已占）、或打卡找不到对应习惯而没建成的行，
    /// 下次再导入时不能被当成“已在新版中删除”（不依赖旧版数据库文件）
    static func legacyReimportChecks(_ check: (Bool, String) -> Void) throws {
        let c = try freshContext()
        func snapshot(_ tag: String, logs: [(id: String, habit: String, date: String)]) -> LegacySnapshot {
            var s = LegacySnapshot(source: .json, path: "", sha256: "selftest-" + tag, schemaVersion: 3)
            s.collections["habits"] = [LegacyRow(id: "h1", createdAt: "2026-09-01T00:00:00+00:00", updatedAt: "2026-09-01T00:00:00+00:00",
                                                 json: #"{"frequency":"daily","start_date":"2026-09-01","title":"导入自检晨读"}"#)]
            s.collections["habit_logs"] = logs.map { log in
                LegacyRow(id: log.id, createdAt: "2026-09-02T00:00:00+00:00", updatedAt: log.date + "T00:00:00+00:00",
                          json: #"{"completed":true,"date":"\#(log.date)","habit_id":"\#(log.habit)"}"#)
            }
            return s
        }
        _ = LegacyImporter.run(snapshot("v1", logs: [("l1", "h1", "2026-09-02")]), context: c, dryRun: false)
        DataStore.save(c)
        guard let h1 = c.all(Habit.self).first(where: { $0.legacyID == "h1" }) else {
            check(false, "导入自检：习惯 h1 没有建成")
            return
        }
        let mine = HabitLog(dateKey: "2026-09-04", completed: true, quantity: nil)
        c.insert(mine)
        mine.habit = h1
        DataStore.save(c)
        let v2 = snapshot("v2", logs: [("l1", "h1", "2026-09-02"), ("l4", "h1", "2026-09-04"), ("l9", "hX", "2026-09-03")])
        let first = LegacyImporter.run(v2, context: c, dryRun: false)
        DataStore.save(c)
        let second = LegacyImporter.run(v2, context: c, dryRun: false)
        DataStore.save(c)
        let logs = c.all(HabitLog.self).filter { $0.habit?.legacyID == "h1" }
        check(first.deletedSkipped == 0 && second.deletedSkipped == 0 && second.warnings.contains { $0.contains("找不到对应习惯") }
              && logs.filter { $0.dateKey == "2026-09-04" }.count == 1 && logs.contains { $0 === mine },
              "重复导入：手动打过卡的那天、找不到习惯的打卡，都不算“已在新版中删除”（第二次 \(second.deletedSkipped) 条）")
    }
}

// MARK: - 修为模型、当日修为差、按窗口取日程（性能改动的对照检查）

extension SelfTest {
    /// 自检用的固定种子随机数（splitmix64）：每次跑的数据相同，出了问题能复现
    private struct SeededRandom: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// 17. 修为模型（侧栏、今日洞府共用）与落笔的“当日差值”：随机造数据，再随机落笔 / 删除 / 撤销 / 改日期 / 打卡 / 改数量 /
    /// 归档 / 改设置 / 传书 / 删习惯，每一步都与全量计算对照——修为差与“前后全量相减”相同，模型与全量计算相同
    static func cultivationChecks(_ check: (Bool, String) -> Void) throws {
        let c = try freshContext()
        let today = LocalDay.today()
        var rng = SeededRandom(state: 20261020)
        func int(_ range: ClosedRange<Int>) -> Int { Int.random(in: range, using: &rng) }
        func chance(_ p: Double) -> Bool { Double.random(in: 0..<1, using: &rng) < p }
        func pick<T>(_ items: [T]) -> T { items[int(0...(items.count - 1))] }

        let settings = DataStore.settings(in: c)
        settings.dailyCap = 60   // 上限小一些，落笔多的日子会顶到上限
        let frequencies: [HabitFrequency] = [.daily, .daily, .weekdays, .weekly, .daily, .weekdays, .daily]
        for (index, frequency) in frequencies.enumerated() {
            let habit = Habit(title: "修为自检\(index)")
            habit.frequencyKind = frequency
            habit.weekdays = frequency == .weekdays ? [0, 2, 4, 5] : []
            habit.targetPerWeek = 3
            habit.targetValue = index % 3 == 1 ? 30 : nil
            habit.startDate = today.adding(days: -int(10...30)).key
            habit.createdAt = today.adding(days: -int(0...35)).date()
            habit.sortOrder = index
            if index == 5 { habit.archived = true; habit.archivedAt = today.adding(days: -6).key }
            if index == 6 { habit.archived = true }   // 旧数据：归档了但没有归档日
            c.insert(habit)
            for offset in 0...32 where chance(0.6) {
                let log = HabitLog(dateKey: today.adding(days: -offset).key, completed: chance(0.9), quantity: pick([nil, 20, 30, 50]))
                log.targetAtLog = pick([nil, nil, 0, 30, 45])
                c.insert(log)
                log.habit = habit
            }
        }
        let kinds = JournalKind.allCases
        for _ in 0..<45 {
            c.insert(JournalEntry(kind: pick(kinds), body: "修为自检", dateKey: today.adding(days: int(-20...1)).key))
        }
        DataStore.save(c)

        // 与界面一样登记为这个库的那一份：落笔算当天修为差时借它的习惯列表（快路径也一并对照）
        let model = CultivationModel.shared(for: c)
        let effects = EffectsCenter()
        var modelMismatch = 0, gainMismatch = 0, journalSteps = 0
        var notes: [String] = []
        func full() -> CultivationState { CultivationService.fullState(context: c) }
        /// 模型看一眼后，修为、今日圆满、功课卡的每一行都与全量计算相同
        func verify(_ label: String) {
            model.refresh()
            let habits = c.all(Habit.self).sorted { $0.sortOrder < $1.sortOrder }
            let config = c.all(AppSettings.self).first?.cultivation ?? CultivationConfig()
            let inputs = habits.map { (spec: $0.spec, logs: $0.logValues, archived: $0.archived) }
            let perfect = config.enabled && CultivationEngine.isPerfectDay(today, habits: inputs)
            func row(_ habit: Habit, _ stats: HabitStats) -> String {
                "\(habit.title)|\(stats.isDueToday)|\(stats.isAchieved(today))|\(stats.streak.count)|\(stats.logs[today]?.quantity ?? -1)"
            }
            let expectedRows = zip(habits, inputs).filter { !$0.0.archived }.map { row($0, HabitStats(spec: $1.spec, logs: $1.logs, today: today)) }
            let ok = model.state == full() && model.perfectToday == perfect && model.config == config
                && model.rows.map { row($0.habit, $0.stats) } == expectedRows && model.habits.map(\.title) == habits.map(\.title)
            if !ok {
                modelMismatch += 1
                if notes.count < 3 { notes.append("\(label)：模型 \(model.state.totalXP) / 全量 \(full().totalXP)") }
            }
        }
        /// 落笔类操作：飘出来的修为差与“前后全量相减”相同
        func journalStep(_ label: String, _ action: () -> Void) {
            let before = full().totalXP
            let toasts = effects.toasts.count
            action()
            let shown = effects.toasts.count > toasts
                ? Int((effects.toasts.last?.text ?? "").replacingOccurrences(of: " 修为", with: "").replacingOccurrences(of: "+", with: "")) ?? .min
                : 0
            journalSteps += 1
            if shown != full().totalXP - before {
                gainMismatch += 1
                if notes.count < 3 { notes.append("\(label)：飘字 \(shown) / 实际 \(full().totalXP - before)") }
            }
        }

        verify("初建")
        var deleted: [JournalSnapshot] = []
        for step in 0..<160 {
            let habits = c.all(Habit.self)
            let entries = c.all(JournalEntry.self)
            switch int(0...12) {
            case 0, 1:
                // 落笔：多半写在少数几天，顶到递减与上限；也有补记过去、写到明天的
                let day = today.adding(days: chance(0.6) ? int(-2...0) : int(-20...1))
                journalStep("落笔") {
                    JournalActions.save(JournalEntry(kind: pick(kinds), body: "第 \(step) 步", dateKey: day.key), context: c, effects: effects)
                }
            case 2, 3:
                guard let entry = entries.randomElement(using: &rng) else { continue }
                journalStep("删除") { deleted.append(JournalActions.delete(entry, context: c, effects: effects)) }
            case 4:
                guard !deleted.isEmpty else { continue }
                let snapshot = deleted.remove(at: int(0...(deleted.count - 1)))
                journalStep("撤销删除") { JournalActions.restore(snapshot, context: c, effects: effects) }
            case 5:
                // 修订：改日期或类型（与 JournalEditSheet.save 相同的写法）
                guard let entry = entries.randomElement(using: &rng) else { continue }
                if chance(0.5) { entry.dateKey = today.adding(days: int(-20...0)).key } else { entry.kindValue = pick(kinds) }
                entry.updatedAt = Date()
                DataStore.save(c)
            case 6:
                // 只改标题、珍藏：修为不变
                guard let entry = entries.randomElement(using: &rng) else { continue }
                entry.title = "改标题 \(step)"
                entry.pinned.toggle()
                entry.updatedAt = Date()
                DataStore.save(c)
            case 7, 8:
                guard let habit = habits.randomElement(using: &rng) else { continue }
                HabitActions.toggle(habit, on: today.adding(days: -int(0...20)), context: c, effects: effects,
                                    allHabits: habits, config: settings.cultivation)
            case 9:
                guard let habit = habits.filter({ ($0.targetValue ?? 0) > 0 }).randomElement(using: &rng) else { continue }
                HabitActions.setQuantity(habit, on: today.adding(days: -int(0...20)), quantity: pick([nil, 10, 30, 60]), context: c,
                                         effects: effects, allHabits: habits, config: settings.cultivation)
            case 10:
                // 归档 / 取消归档（与 HabitDetail.setArchived 相同的写法）
                guard let habit = habits.randomElement(using: &rng) else { continue }
                habit.archived.toggle()
                habit.archivedAt = habit.archived ? today.adding(days: -int(0...10)).key : nil
                habit.updatedAt = Date()
                DataStore.save(c)
            case 11:
                if chance(0.8) { settings.dailyCap = pick([40, 60, 100, 150]) } else { settings.cultivationEnabled.toggle() }
                DataStore.save(c)
            default:
                // 飞剑传书：一封里有日记也有打卡
                let json = """
                {"from":"修为自检","items":[
                  {"type":"diary","date":"\(today.adding(days: -int(0...3)).key)","body":"传书第 \(step) 步"},
                  {"type":"checkin","date":"\(today.adding(days: -int(0...5)).key)","habit":"修为自检\(int(0...4))"}
                ]}
                """
                _ = try? CourierService.apply(try CourierParser.parse(Data(json.utf8)), fileName: "修为自检\(step).json", context: c)
            }
            verify("第 \(step) 步")
        }
        // 随机步里偶尔会把习惯全归档（取决于数据库返回的先后）：留至少两项在用，
        // 后面的“删一个习惯”“打卡只重读一个习惯”“AI 摘要的习惯一节”才有得测，不会偶发失败
        let inUse = c.all(Habit.self).filter { !$0.archived }.count
        for habit in c.all(Habit.self).filter(\.archived).prefix(max(0, 2 - inUse)) {
            habit.archived = false
            habit.archivedAt = nil
            habit.updatedAt = Date()
        }
        DataStore.save(c)
        verify("留两项在用的习惯")
        // 删掉一个习惯（连同打卡）、改了时区之外的一切之后再对一次
        if let habit = c.all(Habit.self).first(where: { !$0.archived }) {
            c.delete(habit)
            DataStore.save(c)
            verify("删习惯")
        }
        check(gainMismatch == 0 && journalSteps > 30,
              "落笔 / 删除 / 撤销删除只算当天的修为差，与前后全量相减相同（\(journalSteps) 次）" + (notes.isEmpty ? "" : "：\(notes)"))
        let loopWork = model.work
        check(modelMismatch == 0, "修为模型（侧栏、今日洞府共用）随机增删改 160 步后逐次与全量计算相同" + (notes.isEmpty ? "" : "：\(notes)"))
        // 这 160 步里几乎都走增量：整表重建只在建模型时、删习惯连带删打卡等说不清的时候
        check(loopWork.journalRebuilds <= 3 && loopWork.logRebuilds <= 3 && loopWork.habitFetches <= 2,
              "修为模型随机增删改时按 ID 增量更新，很少整表重建（修行录 \(loopWork.journalRebuilds) 次、打卡 \(loopWork.logRebuilds) 次、重取习惯 \(loopWork.habitFetches) 次）")

        // 只做必要的活：与修为无关的保存（名帖）什么都不算；只改标题不重算修为；
        // 落笔不整表重建修行录、不重读打卡；打一次卡只重读那一个习惯
        model.refresh()
        var work = model.work
        DataStore.profile(in: c)["city"] = "自检城"
        DataStore.save(c)
        model.refresh()
        let idle = model.work == work
        if let entry = c.all(JournalEntry.self).first {
            entry.title = "只改标题"
            entry.updatedAt = Date()
            DataStore.save(c)
        }
        model.refresh()
        let titleOnly = model.work.computes == work.computes && model.work.journalRebuilds == work.journalRebuilds
        work = model.work
        JournalActions.save(JournalEntry(kind: .note, body: "增量自检"), context: c, effects: effects)
        model.refresh()
        let journalIncremental = model.work.journalRebuilds == work.journalRebuilds && model.work.habitRereads == work.habitRereads
            && model.work.logRebuilds == work.logRebuilds && model.work.computes == work.computes + 1
        work = model.work
        if let habit = c.all(Habit.self).first(where: { !$0.archived }) {
            HabitActions.toggle(habit, on: today, context: c, effects: effects, allHabits: c.all(Habit.self), config: settings.cultivation)
        }
        model.refresh()
        let oneHabit = model.work.habitRereads == work.habitRereads + 1 && model.work.journalRebuilds == work.journalRebuilds
            && model.work.logRebuilds == work.logRebuilds && model.work.habitFetches == work.habitFetches
        check(idle && titleOnly && journalIncremental && oneHabit && model.state == full(),
              "修为模型只做必要的活：无关保存不算（\(idle)）、只改标题不重算（\(titleOnly)）、落笔不整表重建（\(journalIncremental)）、打卡只重读一个习惯（\(oneHabit)）")

        // AI 摘要 / 传书快照的习惯一节借修为模型的统计：与原来逐个习惯重新算的结果相同；
        // 修为（CultivationService.state）借模型时与全量计算相同
        func habitLines(_ habits: [PlannerSummary.Habit]) -> [String] {
            habits.map { "\($0.title)|\($0.schedule)|\($0.completion7d ?? -1)|\($0.completion30d ?? -1)|\($0.streak)|\($0.weeklyTrend)|\($0.recent)" }
        }
        let viaModel = SummaryCollector.build(context: c, options: .init(), today: today)
        let recentDays = LocalDay.range(today.adding(days: -6), today)
        let expectedHabits = c.all(Habit.self).filter { !$0.archived }.sorted { $0.sortOrder < $1.sortOrder }.map { habit -> String in
            let stats = habit.stats(today: today)
            let target = habit.targetValue.map { $0 > 0 ? "，每次 \($0.rounded() == $0 ? String(Int($0)) : String($0))\(habit.unit)" : "" } ?? ""
            let recent = recentDays.map { day -> String in
                let state = stats.state(on: day)
                if state == .done { return "✓" }
                if state == .partial { return "◐" }
                if state == .missed { return "✗" }
                if state == .rest, day == today, stats.spec.frequency == .weekly || stats.spec.isScheduled(day) { return "○" }
                return "–"
            }
            return "\(habit.title)|\(habit.spec.scheduleSummary + target)|\(stats.completionRate(days: 7).map { Int(($0 * 100).rounded()) } ?? -1)|"
                + "\(stats.completionRate(days: 30).map { Int(($0 * 100).rounded()) } ?? -1)|\(stats.streak.count) \(stats.streak.unit)|"
                + "\(stats.weeklyTrend(weeks: 8).map { $0.rate.map { Int(($0 * 100).rounded()) } })|\(recent)"
        }
        check(CultivationModel.existing(for: c) === model && habitLines(viaModel.habits) == expectedHabits && !expectedHabits.isEmpty
              && viaModel.cultivation?.totalXP == full().totalXP && CultivationService.state(context: c) == full(),
              "AI 摘要的习惯一节与修为借修为模型：与逐个习惯重新算、全量计算的结果相同（\(expectedHabits.count) 个习惯）")

        // 删除后约 8 秒内不换日（换日整页重建会把“撤销删除”提示与快照一起丢掉）
        if let entry = c.all(JournalEntry.self).first {
            let snapshot = JournalActions.delete(entry, context: c, effects: nil)
            let held = JournalActions.undoWindowOpen
            JournalActions.restore(snapshot, context: c, effects: nil)
            check(held && !JournalActions.undoWindowOpen, "删除一篇后撤销提示还在的这段时间里先不换日，撤销后恢复")
        }
    }

    /// 18. 只取可能落在窗口里的日程（今日洞府、AI 摘要）：展开结果与全部日程展开完全相同；
    /// 摘要里的日程、回看、修行录与改动前的取法（全部取出再过滤）相同
    static func occurrenceWindowChecks(_ check: (Bool, String) -> Void) throws {
        let c = try freshContext()
        let today = LocalDay.today()
        var rng = SeededRandom(state: 1014)
        func int(_ range: ClosedRange<Int>) -> Int { Int.random(in: range, using: &rng) }
        func chance(_ p: Double) -> Bool { Double.random(in: 0..<1, using: &rng) < p }
        var serial = 0
        func event(_ day: LocalDay, _ kind: RecurrenceKind) -> ScheduleEvent {
            serial += 1
            let e = ScheduleEvent(title: "窗口自检\(serial)", dateKey: day.key)
            e.recurrenceKind = kind
            e.startMinute = chance(0.2) ? nil : int(6...20) * 60
            e.endMinute = e.startMinute.map { $0 + 60 }
            e.location = chance(0.3) ? "教室" : ""
            c.insert(e)
            return e
        }
        // 单次日程散在前后 120 天
        for _ in 0..<120 { _ = event(today.adding(days: int(-120...120)), .none) }
        // 单次日程被单次改期从很远的日子挪进近期、或从近期挪走
        for _ in 0..<12 {
            let far = event(today.adding(days: int(-200...200)), .none)
            far.overridesJSON = OccurrenceOverrides.write(OccurrencePatch(title: "挪来", date: today.adding(days: int(-10...30)).key),
                                                          for: far.dateKey, into: "") ?? ""
            let near = event(today.adding(days: int(-5...5)), .none)
            near.overridesJSON = OccurrenceOverrides.write(OccurrencePatch(date: today.adding(days: int(60...90)).key), for: near.dateKey, into: "") ?? ""
        }
        // 重复日程：每天 / 每周 / 指定星期，带截止、停止、跳过与改期；还有一个认不出的重复类型（按不重复展开）
        for kind in [RecurrenceKind.daily, .weekly, .custom, .weekly, .daily, .custom] {
            let start = today.adding(days: int(-90...20))
            let e = event(start, kind)
            e.interval = int(1...3)
            e.weekdays = kind == .custom ? [0, 2, 4] : []
            if chance(0.4) { e.repeatUntil = today.adding(days: int(-30...60)).key }
            if chance(0.3) { e.stopBefore = today.adding(days: int(-10...40)).key }
            e.excludedDates = (0..<3).map { _ in start.adding(days: int(0...120)).key }
            var json = ""
            for _ in 0..<4 {
                json = OccurrenceOverrides.write(OccurrencePatch(title: "改一次", date: chance(0.5) ? today.adding(days: int(-20...40)).key : nil,
                                                                 start_time: "13:00"), for: start.adding(days: int(0...100)).key, into: json) ?? json
            }
            e.overridesJSON = json
        }
        let odd = event(today.adding(days: -400), .none)
        odd.recurrence = "yearly"
        DataStore.save(c)

        func signature(_ items: [OccurrenceItem]) -> [String] {
            items.map { "\($0.event.title)|\($0.sourceDay.key)|\($0.day.key)|\($0.title)|\($0.startMinute ?? -1)|\($0.location)|\($0.isOverride)" }
        }
        let all = c.all(ScheduleEvent.self)
        var mismatch = 0, windows = 0, nonEmpty = 0
        var ranges: [(LocalDay, LocalDay)] = [(today, today.adding(days: 3)), (today.adding(days: -7), today.adding(days: 27))]
        for _ in 0..<40 {
            let first = today.adding(days: int(-60...60))
            ranges.append((first, first.adding(days: int(0...35))))
        }
        for (first, last) in ranges {
            let expected = signature(Occurrences.list(events: all, from: first, to: last))
            let got = signature(Occurrences.list(events: Occurrences.events(in: c, from: first, to: last), from: first, to: last))
            windows += 1
            if !expected.isEmpty { nonEmpty += 1 }
            // 同一天、同一时刻、同名的几次先后不定（原来也是），按集合比较
            if expected.sorted() != got.sorted() { mismatch += 1 }
        }
        check(mismatch == 0 && nonEmpty > 20, "只取窗口里可能出现的日程（含单次改期挪进挪出、重复规则）：\(windows) 个窗口展开结果与全部日程相同")

        // AI 摘要 / 快照：日程只取一次、只展开一次，修行录只取需要的天数，与改动前的取法相同
        for offset in 0..<200 where chance(0.7) {
            let entry = JournalEntry(kind: chance(0.5) ? .diary : .note, body: "摘要自检\(offset)", dateKey: today.adding(days: -offset).key)
            entry.minute = chance(0.5) ? int(0...1439) : nil
            c.insert(entry)
        }
        c.insert(JournalEntry(kind: .diary, body: "明天的", dateKey: today.adding(days: 1).key))
        DataStore.save(c)
        var options = SummaryCollector.Options()
        options.journalDays = 120
        options.upcomingDays = 14
        options.pastDays = 7
        let summary = SummaryCollector.build(context: c, options: options, today: today)
        let since = today.adding(days: -(options.journalDays - 1)).key
        let expectedJournal = c.all(JournalEntry.self).filter { $0.dateKey >= since && $0.dateKey <= today.key }
            .sorted { ($0.dateKey, $0.minute ?? -1, $0.createdAt) < ($1.dateKey, $1.minute ?? -1, $1.createdAt) }.map(\.body)
        let last = today.adding(days: options.upcomingDays - 1)
        let hoursLast = today.adding(days: SummaryCollector.hoursWindowDays - 1)
        let future = Occurrences.list(events: all, from: today, to: max(last, hoursLast))
        func lines(_ items: [OccurrenceItem]) -> [String] { items.map { "\($0.day.key)|\(ClockTime.range($0.startMinute, $0.endMinute))|\($0.title)" }.sorted() }
        func lines(_ items: [PlannerSummary.Occurrence]) -> [String] { items.map { "\($0.date)|\($0.time)|\($0.title)" }.sorted() }
        let expectedPast = Occurrences.list(events: all, from: today.adding(days: -options.pastDays), to: today.adding(days: -1))
        let expectedHours = ScheduleHours.weeklyAverage(future.filter { $0.day <= hoursLast }.map { ($0.category, $0.startMinute, $0.endMinute) },
                                                        days: SummaryCollector.hoursWindowDays)
        let expectedRecurring = all.filter { event in
            let rule = event.rule
            let ended = (rule.repeatUntil.map { $0 < today } ?? false) || (rule.stopBefore.map { $0 <= today } ?? false)
            return event.recurrenceKind != .none && !ended
        }.map(\.title).sorted()
        check(summary.journal.map(\.body) == expectedJournal && !expectedJournal.isEmpty
              && lines(summary.upcoming) == lines(future.filter { $0.day <= last }) && lines(summary.past) == lines(expectedPast)
              && summary.scheduleHoursByCategory.map { "\($0.category)|\($0.hoursPerWeek)" } == expectedHours.map { "\($0.category)|\($0.hoursPerWeek)" }
              && summary.recurringEvents.map(\.title).sorted() == expectedRecurring && !summary.upcoming.isEmpty && !summary.past.isEmpty,
              "AI 摘要：修行录只取 \(options.journalDays) 天（\(expectedJournal.count) 篇）、日程只取一次只展开一次，与原来的取法相同")
    }
}
