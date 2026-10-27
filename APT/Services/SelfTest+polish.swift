import Foundation
import SwiftData

// 第 4 轮遗留打磨（polish）的运行时自检：
// 1. 撤销传书的说法：传书笺（RootView 的撤销说明、EffectsCenter 的撤销结果）与修行录左栏同一套（CourierUndoWording），
//    恢复的目标不再说成“删除”，保留的按记录 / 档案字段 / 目标分开数，并接上第一条保留原因；
// 2. 岁月长卷借修为模型读好的习惯与打卡：与镜像自己读的算出同一卷，且不再整读一遍打卡；
// 3. 命令行小抄：应用写出的小抄带 goals 与 archivedHabits，--add 据此拒收找不到的目标（退出码 2）。
// 说法的各种组合、各月消费横轴的抽稀在 Tools/CoreCheck 里测。

extension SelfTest {
    static func polishChecks(_ check: (Bool, String) -> Void) throws {
        try polishUndoWordingChecks(check)
        try polishAnnalsChecks(check)
        try polishRosterChecks(check)
    }

    private static func polishContext() throws -> ModelContext {
        let context = ModelContext(try DataStore.makeContainer(inMemory: true))
        DataStore.settings(in: context)
        DataStore.profile(in: context)
        DataStore.save(context)
        return context
    }

    // MARK: 1. 撤销传书的说法

    private static func polishUndoWordingChecks(_ check: (Bool, String) -> Void) throws {
        let c = try polishContext()
        let today = LocalDay.today(in: CourierService.timeZone)
        func deliver(_ items: [[String: Any]], _ name: String) throws -> CourierDelivery {
            let data = try JSONSerialization.data(withJSONObject: ["from": "自检", "items": items])
            return try CourierService.apply(try CourierParser.parse(data), fileName: name, context: c)
        }
        func goalUpdate(_ title: String, _ progress: Int) -> [String: Any] { ["type": "goal", "action": "update", "title": title, "progress": progress] }
        let thesis = Goal(title: "自检·polish 论文初稿")
        thesis.progress = 60
        c.insert(thesis)
        DataStore.profile(in: c)["main_tasks"] = "旧任务"
        DataStore.save(c)

        // 1a. 只更新目标的传书：传书笺说“将恢复 1 个目标”（以前是一句空话），结果说“已恢复”，不说“删除”
        let d1 = try deliver([goalUpdate(thesis.title, 65)], "polish-goal.json")
        let plan1 = RootView.courierUndoPlan(CourierService.undoPreviewDetail(d1, context: c))
        let panel1 = CourierUndoWording.panelLines(CourierService.undoPreviewDetail(d1, context: c).wording)
        check(plan1 == "将恢复 1 个目标" && panel1 == ["将恢复 1 个目标（换回这封传书之前的内容）。"],
              "传书笺与左栏的撤销说明：目标更新说成恢复（\(plan1)）")
        let effects = EffectsCenter()
        let r1 = CourierService.undo(d1, context: c, refresh: false)
        effects.courierUndoResult(r1)
        check(thesis.progress == 60 && effects.courier?.title == "已撤销此书" && effects.courier?.detail == "恢复 1 个目标"
              && effects.courier?.lines == ["已恢复 1 个目标，回到传书之前的内容"]
              && CourierUndoWording.resultSentence(r1.wording) == "已撤销：恢复 1 个目标。",
              "撤销结果：进度回到 60%，传书笺与左栏都写“恢复 1 个目标”（\(effects.courier?.detail ?? "")）")

        // 1b. 日记 + 档案 + 目标，日记收录后珍藏过（算改过）：删 0 条时不写“删除”，恢复的两类合在一句里，保留的写明是记录
        let d2 = try deliver([["type": "diary", "date": today.key, "body": "polish 自检·混合传书"],
                              ["type": "profile", "fields": ["main_tasks": "新任务"]], goalUpdate(thesis.title, 70)], "polish-mixed.json")
        c.all(JournalEntry.self).first { $0.body == "polish 自检·混合传书" }?.pinned = true
        DataStore.save(c)
        let p2 = CourierService.undoPreviewDetail(d2, context: c)
        let plan2 = RootView.courierUndoPlan(p2)
        let buttons2 = CourierUndoWording.buttons(p2.wording)
        check(plan2 == "将恢复 1 个档案字段和 1 个目标；保留你改过的 1 条记录" && buttons2.keep == "撤销（保留改过的 1 条记录）"
              && CourierUndoWording.panelLines(p2.wording).contains { $0.hasPrefix("保留你改过的 1 条记录；") },
              "混合传书的撤销说明：不写“删除 0 条”，按钮与正文都说“1 条记录”（\(plan2)）")
        let r2 = CourierService.undo(d2, context: c, refresh: false)
        effects.courierUndoResult(r2)
        check(effects.courier?.detail == "恢复 2 项 · 保留 1 条"
              && effects.courier?.lines == ["已恢复 1 个档案字段和 1 个目标，回到传书之前的内容", "保留了你改过的 1 条记录"]
              && DataStore.profile(in: c)["main_tasks"] == "旧任务" && thesis.progress == 60,
              "混合传书的撤销结果：档案与目标都换回原值，日记保留，结果里没有“删除”（\(effects.courier?.detail ?? "")）")

        // 1c. 目标更新收录后用户又改了进度：默认保留，按钮、结果、传书摘要都说“1 个目标”，不说“1 条”
        let d3 = try deliver([goalUpdate(thesis.title, 80)], "polish-goal-edited.json")
        thesis.progress = 85
        thesis.updatedAt = d3.receivedAt.addingTimeInterval(10)
        DataStore.save(c)
        let p3 = CourierService.undoPreviewDetail(d3, context: c)
        let r3 = CourierService.undo(d3, context: c, refresh: false)
        effects.courierUndoResult(r3)
        check(CourierUndoWording.buttons(p3.wording) == ("撤销（保留改过的 1 个目标）", "全部撤销（含改过的 1 个目标）")
              && r3.keptGoals == 1 && thesis.progress == 85 && effects.courier?.lines == ["保留了你改过的 1 个目标"]
              && effects.courier?.detail == "保留 1 项" && d3.summary.hasSuffix("（撤销时保留了收录后改过的 1 个目标）"),
              "改过的目标：保留，按钮、结果、摘要都按“个目标”数（\(effects.courier?.lines ?? [])）")

        // 1d. 新建的习惯下面已有用户自己的打卡：撤销也保留，传书笺接上这条原因
        let d4 = try deliver([["type": "habit", "title": "自检·polish 冥想"]], "polish-habit.json")
        if let habit = c.all(Habit.self).first(where: { $0.title == "自检·polish 冥想" }) {
            let log = HabitLog(dateKey: today.key)
            c.insert(log)
            log.habit = habit
            DataStore.save(c)
        }
        let plan4 = RootView.courierUndoPlan(CourierService.undoPreviewDetail(d4, context: c))
        check(plan4 == "不会删除或恢复任何内容，只把这封标记为已撤销；习惯「自检·polish 冥想」已有 1 条打卡，撤销时保留（要删请到「每日功课」里删）",
              "只剩撤销也保留的习惯：传书笺说明不会删除或恢复，并接上原因（\(plan4)）")
    }

    // MARK: 2. 岁月长卷借修为模型的习惯与打卡

    private static func polishAnnalsChecks(_ check: (Bool, String) -> Void) throws {
        // 主 context：AIDigest.borrowedHabits 只在数据库的主 context 上建 / 借修为模型（与应用里一样）
        let container = try DataStore.makeContainer(inMemory: true)
        let c = container.mainContext
        DataStore.settings(in: c)
        DataStore.profile(in: c)
        let today = LocalDay.today()
        for offset in stride(from: 400, through: 0, by: -3) {
            let entry = JournalEntry(kind: offset % 9 == 0 ? .review : .diary, title: "", body: "polish 长卷自检 \(offset)",
                                     dateKey: today.adding(days: -offset).key)
            entry.mood = 1 + offset % 5
            c.insert(entry)
        }
        let daily = Habit(title: "polish 长卷晨读")
        daily.startDate = today.adding(days: -400).key
        let old = Habit(title: "polish 长卷旧功课")
        old.startDate = today.adding(days: -400).key
        old.archived = true
        old.archivedAt = today.adding(days: -100).key
        old.sortOrder = 1
        c.insert(daily)
        c.insert(old)
        for offset in 0...400 where offset % 2 == 0 {
            let log = HabitLog(dateKey: today.adding(days: -offset).key)
            c.insert(log)
            log.habit = offset > 100 && offset % 4 == 0 ? old : daily
        }
        DataStore.save(c)
        guard let period = AnnalsPeriod.make(.year(today.year), today: today) else { return check(false, "岁月长卷：今年的时段为空") }

        let loads = RecordCollector.mirrorFullLoads.habits
        let borrowed = AnnalsView.makeReport(period, today: today, context: c)
        let didNotRead = RecordCollector.mirrorFullLoads.habits == loads && CultivationModel.existing(for: c) != nil
        // 对照：不借，由镜像自己整读一遍打卡
        let mirrored = AnnalsEngine.report(period, input: RecordCollector.input(context: c, from: period.first, to: period.last, today: today, text: true))
        check(didNotRead && RecordCollector.mirrorFullLoads.habits == loads + 1
              && AnnalsRenderer.markdown(borrowed) == AnnalsRenderer.markdown(mirrored) && borrowed.habits != nil,
              "岁月长卷：借修为模型的习惯与打卡，不再整读打卡；算出的长卷与镜像自己读的逐字相同")
    }

    // MARK: 3. 命令行小抄

    private static func polishRosterChecks(_ check: (Bool, String) -> Void) throws {
        // 要写小抄、收件箱：只在临时数据目录里做
        guard DataStore.customDirectory != nil else { return }
        let fm = FileManager.default
        let c = try polishContext()
        let goal = Goal(title: "自检·polish 小抄目标")
        goal.progress = 40
        c.insert(goal)
        let archived = Habit(title: "自检·polish 已归档")
        archived.archived = true
        c.insert(archived)
        DataStore.save(c)
        let stateURL = CourierService.stateURL
        let savedState = fm.contents(atPath: stateURL.path)
        defer {
            if let savedState { try? savedState.write(to: stateURL) } else { try? fm.removeItem(at: stateURL) }
        }
        CourierService.refreshSnapshot(context: c)
        let state = (try? JSONSerialization.jsonObject(with: fm.contents(atPath: stateURL.path) ?? Data())) as? [String: Any] ?? [:]
        let goals = (state["goals"] as? [[String: Any]]) ?? []
        check(goals.contains { $0["title"] as? String == goal.title && $0["status"] as? String == "active" && ($0["progress"] as? NSNumber)?.intValue == 40 }
              && (state["archivedHabits"] as? [String]) == [archived.title],
              "小抄：应用写出 goals（含状态与进度）与 archivedHabits")

        func inboxNames() -> Set<String> { Set((try? fm.contentsOfDirectory(atPath: CourierService.inbox.path)) ?? []) }
        /// 跑一次 --add（不把它打印的说明混进自检输出），返回退出码与它投进收件箱的文件名（投进去的随即删掉）
        func add(_ json: String) -> (code: Int32, file: String?) {
            let before = inboxNames()
            fflush(stdout)
            let saved = dup(STDOUT_FILENO)
            let null = open("/dev/null", O_WRONLY)
            if null >= 0 { dup2(null, STDOUT_FILENO); close(null) }
            let code = CourierService.commandLineAdd(json)
            fflush(stdout)
            if saved >= 0 { dup2(saved, STDOUT_FILENO); close(saved) }
            let file = inboxNames().subtracting(before).first
            if let file { try? fm.removeItem(at: CourierService.inbox.appendingPathComponent(file)) }
            return (code, file)
        }
        let missing = add(#"{"from":"自检","items":[{"type":"goal","action":"update","title":"自检·polish 没有的目标","progress":30}]}"#)
        let found = add(#"{"from":"自检","items":[{"type":"goal","action":"update","title":"自检·polish 小抄目标","progress":50}]}"#)
        let clash = add(#"{"from":"自检","items":[{"type":"habit","title":"自检·polish 已归档"}]}"#)
        check(missing.code == 2 && missing.file == nil && found.code == 0 && found.file != nil && clash.code == 2 && clash.file == nil,
              "--add 按应用写出的小抄预检：更新找不到的目标、新建与已归档习惯同名，退出码 2 且不投；对得上的照投")
    }
}
