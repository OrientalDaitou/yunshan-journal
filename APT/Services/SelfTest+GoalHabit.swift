import Foundation
import SwiftData

// 飞剑传书 goal / habit 的写入、撤销、去重与命令行预检（设计稿 P2 §4.2 第 1–11 条）。
// 解析、预检、摘要行这些纯逻辑在 Tools/CoreCheck 里测；这里只测要碰 SwiftData 与收件箱的部分。

extension SelfTest {
    static func goalHabitChecks(_ check: (Bool, String) -> Void) throws {
        let c = try goalHabitContext()
        let today = LocalDay.today(in: CourierService.timeZone)
        let notePrefix = "\(today.year)年\(today.shortLabel)："
        func deliver(_ items: String) throws -> CourierDelivery {
            try CourierService.apply(try CourierParser.parse(Data(#"{"from":"自检","items":[\#(items)]}"#.utf8)), fileName: "goalhabit.json", context: c)
        }
        func goal(_ title: String) -> Goal? { c.all(Goal.self).first { $0.title == title } }
        func habit(_ title: String) -> Habit? { c.all(Habit.self).first { $0.title == title } }
        func lines(_ d: CourierDelivery) -> [String] { d.summary.split(separator: "\n").map(String.init) }
        func preview(_ d: CourierDelivery) -> CourierUndoPreview { CourierService.undoPreviewDetail(d, context: c) }
        func undo(_ d: CourierDelivery, keepEdited: Bool = true) -> CourierUndoReport {
            CourierService.undo(d, context: c, refresh: false, keepEdited: keepEdited)
        }
        /// 收录后被用户改过：修改时间比收录时刻晚 10 秒
        func touch(_ d: CourierDelivery) -> Date { d.receivedAt.addingTimeInterval(10) }

        // 11. 目录一致：编辑窗能选的图标、目标的状态与优先级，与传书认的完全相同
        check(HabitEditor.symbols == HabitIcons.all, "传书认的 15 个习惯图标与「每日功课」编辑窗里的一致")
        check(Goal.statusLabels == GoalCatalog.statusLabels && Goal.priorityLabels == GoalCatalog.priorityLabels,
              "传书认的目标状态、优先级与修士名帖的一致")

        // 1. 新立目标
        let d1 = try deliver(#"{"type":"goal","title":"自检·读完 24 本书","target_date":"\#(today.adding(days: 60).key)","priority":"must","category":"读书"}"#)
        let g1 = goal("自检·读完 24 本书")
        check(g1?.legacyID?.hasPrefix("courier:") == true && g1?.priority == "must" && g1?.status == "active" && g1?.progress == 0
              && g1?.targetDate == today.adding(days: 60).key && g1?.category == "读书" && d1.itemCount == 1
              && d1.summary.hasPrefix("目标 · 新立「自检·读完 24 本书」（期限\u{A0}") && d1.summary.contains("，必须）"),
              "新立目标：写入名帖、打 courier: 标识、收录 1 条（\(d1.summary)）")
        check(CourierLineDecor.symbol(lines(d1)) == "flag" && CourierLineDecor.page(lines(d1)) == "profile", "只有目标的传书：笺头是旗、“查看”去修士名帖")

        // 5a. 新立的目标没改过：撤销即删除
        let r1 = undo(d1)
        check(r1.removed == 1 && r1.keptEdited == 0 && r1.restoredGoals == 0 && goal("自检·读完 24 本书") == nil, "撤销新立的目标：没改过就删除")

        // 5b. 用户改过说明：默认保留，计入“改过的记录”
        let d2 = try deliver(#"{"type":"goal","title":"自检·学会游泳"}"#)
        goal("自检·学会游泳")?.detail = "用户补的说明"
        goal("自检·学会游泳")?.updatedAt = touch(d2)
        let p2 = preview(d2)
        check(p2.records == 1 && p2.editedRecords == 1 && p2.goals == 0, "新立的目标被用户改过：预览算 1 条改过的记录（\(p2.records)/\(p2.editedRecords)）")
        let r2 = undo(d2)
        check(r2.keptEdited == 1 && r2.removed == 0 && goal("自检·学会游泳") != nil, "撤销时保留用户改过的新目标")

        // 5c. D1 新立、D2 更新（用户没动过）：撤 D1 照样删除；之后撤 D2 什么都不动、也不报错
        let d3 = try deliver(#"{"type":"goal","title":"自检·存应急金"}"#)
        let d4 = try deliver(#"{"type":"goal","action":"update","title":"自检·存应急金","progress":30}"#)
        check(goal("自检·存应急金")?.progress == 30 && d4.itemCount == 1 && d4.summary == "目标 · 自检·存应急金：进度\u{A0}0% →\u{A0}30%",
              "更新刚新立的目标（\(d4.summary)）")
        let p3 = preview(d3)
        check(p3.records == 1 && p3.editedRecords == 0, "之后传书的更新不算用户改过（期望值叠加了后来的写入）")
        let r3 = undo(d3)
        check(r3.removed == 1 && goal("自检·存应急金") == nil, "撤销新立的目标：后来被传书更新过也照样删除")
        let r4 = undo(d4)
        check(r4.failure == nil && r4.removed == 0 && r4.restoredGoals == 0 && d4.undone, "目标已删掉时撤销它的更新：跳过、不报错")

        // 2. 更新用户在应用里建的目标（没有 legacyID）：进度 40 → 50，备注带年份追加，补 apt-goal: 标识，两项合计 1 条
        let thesis = Goal(title: "自检·完成学位论文初稿")
        thesis.progress = 40
        thesis.notes = "原备注"
        c.insert(thesis)
        DataStore.save(c)
        let u1 = try deliver(#"{"type":"goal","action":"update","title":"自检·完成学位论文初稿","progress":50,"notes":"第三章初稿完成"}"#)
        let thesisID = thesis.legacyID
        check(thesis.progress == 50 && thesis.notes == "原备注\n" + notePrefix + "第三章初稿完成" && thesisID?.hasPrefix("apt-goal:") == true
              && u1.itemCount == 1, "更新用户建的目标：进度改写、备注带年份追加、补 apt-goal: 标识、两项计 1 条")
        check(u1.summary == "目标 · 自检·完成学位论文初稿：进度\u{A0}40% →\u{A0}50%；备注 +「第三章初稿完成」"
              && CourierLineDecor.progressMove(lines(u1)[0]) == CourierLineDecor.ProgressMove(title: "自检·完成学位论文初稿", from: 40, to: 50, completed: false),
              "目标更新的摘要行能被传书笺解析出进度 40% → 50%")

        // 7b. 计数分开：只有一条目标更新时，预览只有“目标”一项；撤销后记为恢复目标，不是删除、也不是档案字段
        let pu1 = preview(u1)
        check(pu1.goals == 1 && pu1.editedGoals == 0 && pu1.records == 0 && pu1.fields == 0 && pu1.total == 1,
              "目标更新的撤销预览单列（目标 \(pu1.goals)、记录 \(pu1.records)、档案 \(pu1.fields)）")
        let ru1 = undo(u1)
        check(ru1.restoredGoals == 1 && ru1.restored == 0 && ru1.removed == 1 && thesis.progress == 40 && thesis.notes == "原备注"
              && thesis.legacyID == thesisID, "撤销目标更新：恢复原值（进度、备注），计为恢复 1 个目标；补的标识不清")

        // 3. 用户之后又改了进度：默认保留，“全部撤销”才恢复
        let u2 = try deliver(#"{"type":"goal","action":"update","title":"自检·完成学位论文初稿","progress":60}"#)
        thesis.progress = 61
        thesis.updatedAt = touch(u2)
        check(preview(u2).editedGoals == 1, "目标更新后用户又改过进度：预览算 1 个改过的目标")
        let ru2 = undo(u2)
        check(ru2.keptEdited == 1 && ru2.restoredGoals == 0 && thesis.progress == 61, "撤销目标更新：默认保留用户改过的进度")
        let u3 = try deliver(#"{"type":"goal","action":"update","title":"自检·完成学位论文初稿","progress":70}"#)
        thesis.progress = 72
        let ru3 = undo(u3, keepEdited: false)
        check(ru3.restoredGoals == 1 && ru3.keptEdited == 0 && thesis.progress == 61, "“全部撤销”时连用户改过的进度也恢复成更新前")

        // 值没变：只记一行“已是这个内容，跳过”，不产生引用
        let u4 = try deliver(#"{"type":"goal","action":"update","title":"自检·完成学位论文初稿","progress":61}"#)
        check(u4.itemCount == 0 && u4.summary == "目标 · 自检·完成学位论文初稿（已是这个内容，跳过）", "目标更新的值与现值相同：跳过、收录 0 条")

        // 状态、期限：completed 时进度按 100；期限 “none” 取消；撤销三项一起恢复
        thesis.targetDate = today.adding(days: 30).key
        DataStore.save(c)
        let u5 = try deliver(#"{"type":"goal","action":"update","title":"自检·完成学位论文初稿","status":"已完成","target_date":"none"}"#)
        let move5 = CourierLineDecor.progressMove(lines(u5)[0])
        check(thesis.status == "completed" && thesis.progress == 100 && thesis.targetDate == nil && u5.itemCount == 1
              && u5.summary.contains("进度\u{A0}61% →\u{A0}100%；状态 进行中 → 已完成；期限\u{A0}") && u5.summary.hasSuffix("→\u{A0}无") && move5?.completed == true,
              "目标标记完成：进度记 100、取消期限，传书笺认出“达成”（\(u5.summary)）")
        let ru5 = undo(u5)
        check(ru5.restoredGoals == 1 && thesis.status == "active" && thesis.progress == 61 && thesis.targetDate == today.adding(days: 30).key,
              "撤销“标记完成”：状态、进度、期限一起恢复")

        // 4. 乱序撤销：D1 40 → 50，D2 50 → 60；先撤 D1 进度仍是 60（以后来的为准），D2 的 before 接回 40；再撤 D2 回到 40
        thesis.progress = 40
        DataStore.save(c)
        let o1 = try deliver(#"{"type":"goal","action":"update","title":"自检·完成学位论文初稿","progress":50}"#)
        let o2 = try deliver(#"{"type":"goal","action":"update","title":"自检·完成学位论文初稿","progress":60}"#)
        let po1 = preview(o1)
        check(po1.edited == 0 && po1.goals == 0 && po1.notes.first?.contains("的进度后来又被") == true,
              "乱序撤销预览：被后来的传书改过的一项不算你改过，只说明原因（\(po1.notes.first ?? "无说明")）")
        let ro1 = undo(o1)
        let relinked = CourierService.refs(of: o2).first { $0.t == "goalset" }?.before
        check(thesis.progress == 60 && relinked == "40" && ro1.restoredGoals == 0 && ro1.notes.count == 1,
              "先撤前一封：进度仍是 60，后一封的“改写前”接回 40")
        let ro2 = undo(o2)
        check(ro2.restoredGoals == 1 && thesis.progress == 40, "再撤后一封：进度回到最初的 40")

        // 6. 同封“新建习惯 + 打卡”：两者都写入，打卡数量默认记成目标值；撤销后两者都没了
        let logsBefore = c.all(HabitLog.self).count
        let maxOrder = c.all(Habit.self).map(\.sortOrder).max() ?? 0
        let h1 = try deliver(#"{"type":"habit","title":"自检冥想","target":10,"unit":"分钟"},{"type":"checkin","habit":"自检冥想"}"#)
        let meditation = habit("自检冥想")
        check(meditation?.legacyID?.hasPrefix("courier:") == true && meditation?.log(on: today)?.quantity == 10 && h1.itemCount == 2
              && meditation?.sortOrder == maxOrder + 1 && meditation?.symbol == "brain.head.profile" && meditation?.startDate == today.key
              && lines(h1).first == "功课 · 新立「自检冥想」（每天，每次\u{A0}10分钟，自\u{A0}\(today.shortLabel)\u{A0}起）",
              "同封先建习惯再打卡：都写入、打卡数量记成目标值、排在最后、按名称猜图标（\(lines(h1).first ?? "")）")
        check(CourierLineDecor.symbol(lines(h1)) == "leaf" && CourierLineDecor.page(lines(h1)) == "habits", "只有新习惯和打卡的传书：笺头是叶、“查看”去每日功课")
        let rh1 = undo(h1)
        check(rh1.removed == 2 && habit("自检冥想") == nil && c.all(HabitLog.self).count == logsBefore, "撤销“新建习惯 + 打卡”：两者都删掉")

        // 打卡写在新建习惯之前也能挂上（新习惯在主循环前统一插入）
        let h2 = try deliver(#"{"type":"checkin","habit":"自检拉伸"},{"type":"habit","title":"自检拉伸","frequency":"weekly","times_per_week":3}"#)
        let stretch = habit("自检拉伸")
        check(stretch?.frequencyKind == .weekly && stretch?.targetPerWeek == 3 && stretch?.log(on: today) != nil && h2.itemCount == 2,
              "同封先打卡、后建习惯：打卡也挂到新习惯上")
        check(undo(h2).removed == 2 && habit("自检拉伸") == nil, "撤销后习惯与打卡都删掉")

        // 7. 新建的习惯之后用户自己又打了一天卡：撤销后习惯保留，并说明原因；预览的 total 不计它
        let h3 = try deliver(#"{"type":"habit","title":"自检早睡","start_date":"\#(today.adding(days: -1).key)"}"#)
        if let early = habit("自检早睡") {
            let own = HabitLog(dateKey: today.key)
            c.insert(own)
            own.habit = early
            DataStore.save(c)
        }
        let ph3 = preview(h3)
        check(ph3.total == 0 && ph3.edited == 0 && ph3.notes.first == "习惯「自检早睡」已有 1 条打卡，撤销时保留（要删请到「每日功课」里删）",
              "新习惯已有用户自己的打卡：撤销预览不计它，说明“已有 1 条打卡”")
        let rh3 = undo(h3, keepEdited: false)
        check(habit("自检早睡")?.log(on: today) != nil && rh3.removed == 0 && rh3.keptEdited == 0 && rh3.notes.first?.contains("已有 1 条打卡") == true,
              "有别的打卡的新习惯，“全部撤销”也保留（连同打卡）")

        // 7a. 本封给新习惯打的卡被用户改了数量：默认撤销时习惯与那条打卡都保留；“全部撤销”时两者都删
        let h4 = try deliver(#"{"type":"habit","title":"自检阅读","target":20,"unit":"页"},{"type":"checkin","habit":"自检阅读"}"#)
        if let log = habit("自检阅读")?.log(on: today) {
            log.quantity = 25
            log.updatedAt = touch(h4)
        }
        let ph4 = preview(h4)
        check(ph4.total == 2 && ph4.edited == 2, "本封的打卡被改过：习惯也算改过（共 \(ph4.total) 条、改过 \(ph4.edited) 条，默认一条都不删）")
        let rh4 = undo(h4)
        check(habit("自检阅读")?.log(on: today)?.quantity == 25 && rh4.keptEdited == 2 && rh4.removed == 0, "默认撤销：习惯与改过的打卡都保留")
        let h5 = try deliver(#"{"type":"habit","title":"自检跑步"},{"type":"checkin","habit":"自检跑步"}"#)
        if let log = habit("自检跑步")?.log(on: today) {
            log.completed = false
            log.updatedAt = touch(h5)
        }
        let rh5 = undo(h5, keepEdited: false)
        check(rh5.removed == 2 && habit("自检跑步") == nil && !c.all(HabitLog.self).contains { $0.habit == nil },
              "“全部撤销”：习惯与改过的打卡都删掉，不留孤立的打卡")

        // 用户改过新习惯的设置（换了图标）：算改过，默认保留
        let h6 = try deliver(#"{"type":"habit","title":"自检喝水","icon":"水"}"#)
        habit("自检喝水")?.symbol = "leaf"
        habit("自检喝水")?.updatedAt = touch(h6)
        check(preview(h6).editedRecords == 1 && undo(h6).keptEdited == 1 && habit("自检喝水") != nil, "新习惯的设置被用户改过：默认保留")

        // 新习惯与现有习惯名字互相包含：照收，回执提醒
        let related = try CourierService.applyWithNotices(try CourierParser.parse(Data(#"[{"type":"habit","title":"自检阅读计划"}]"#.utf8)),
                                                          fileName: "related.json", context: c)
        check(related.notices.contains { $0.contains("新习惯「自检阅读计划」和现有习惯「自检阅读」名字互相包含") }, "新习惯名与现有习惯互相包含：照收并提醒")
        _ = undo(related.delivery)

        // 8. 预检不通过：整封不写（含同封的日记）
        func rejected(_ items: String) -> String? {
            let counts = (c.all(JournalEntry.self).count, c.all(Habit.self).count, c.all(Goal.self).count, c.all(CourierDelivery.self).count)
            do {
                _ = try deliver(#"{"type":"diary","body":"预检自检日记"},"# + items)
                return nil
            } catch {
                let after = (c.all(JournalEntry.self).count, c.all(Habit.self).count, c.all(Goal.self).count, c.all(CourierDelivery.self).count)
                return after == counts ? error.localizedDescription : "写进了数据库"
            }
        }
        habit("自检早睡")?.archived = true
        DataStore.save(c)
        let sameHabit = rejected(#"{"type":"habit","title":"自检阅读"}"#)
        check(sameHabit == "第 2 条：已有同名习惯「自检阅读」。要打卡请用 checkin；要改它的设置请让用户在应用「每日功课」里改",
              "新习惯与已有习惯同名：整封拒收，同封的日记也没写（\(sameHabit ?? "收录了")）")
        check(rejected(#"{"type":"habit","title":"自检早睡"}"#)?.contains("已有同名的已归档习惯「自检早睡」") == true, "新习惯与已归档的习惯同名：整封拒收")
        check(rejected(#"{"type":"goal","title":"自检·完成学位论文初稿"}"#) == #"第 2 条：已有同名目标「自检·完成学位论文初稿」（进行中，40%）。要更新它请写 "action": "update""#,
              "新立目标与进行中的目标同名：整封拒收")
        let ambiguous = Goal(title: "自检·投出第一篇期刊论文")
        c.insert(ambiguous)
        DataStore.save(c)
        check(rejected(#"{"type":"goal","action":"update","title":"论文","progress":70}"#)?.contains("「论文」能对上多个目标：") == true,
              "更新时名称能对上多个目标：整封拒收")
        check(rejected(#"{"type":"checkin","habit":"不存在的习惯"}"#)?.hasPrefix("第 2 条：找不到习惯「不存在的习惯」。现有习惯：") == true,
              "打卡对不上习惯：报错原文不变")

        // 9–10. 收件箱与命令行（只在临时数据目录里）
        guard DataStore.customDirectory != nil else { return }
        try goalHabitInboxChecks(check, context: c)
    }

    /// 与 freshContext 相同的干净内存库（freshContext 是 SelfTest.swift 的私有函数）
    private static func goalHabitContext() throws -> ModelContext {
        let context = ModelContext(try DataStore.makeContainer(inMemory: true))
        DataStore.settings(in: context)
        DataStore.profile(in: context)
        DataStore.save(context)
        return context
    }

    /// 9. 经命令行 --add 投进收件箱、应用收录、回执、去重、撤销后重投；10. --add 按小抄预检
    private static func goalHabitInboxChecks(_ check: (Bool, String) -> Void, context c: ModelContext) throws {
        let fm = FileManager.default
        CourierService.prepareFolders()
        let stateURL = CourierService.stateURL
        let savedState = fm.contents(atPath: stateURL.path)
        defer {
            if let savedState { try? savedState.write(to: stateURL) } else { try? fm.removeItem(at: stateURL) }
        }
        func writeState(_ object: [String: Any]) throws {
            var object = object
            object["timeZone"] = CourierService.timeZone.identifier
            try JSONSerialization.data(withJSONObject: object).write(to: stateURL)
        }
        func inboxNames() -> Set<String> { Set((try? fm.contentsOfDirectory(atPath: CourierService.inbox.path)) ?? []) }
        /// 跑一次 --add（不把它打印的说明混进自检输出），返回退出码与它投进收件箱的文件名
        func add(_ json: String) -> (code: Int32, file: String?) {
            let before = inboxNames()
            fflush(stdout)
            let saved = dup(STDOUT_FILENO)
            let null = open("/dev/null", O_WRONLY)
            if null >= 0 { dup2(null, STDOUT_FILENO); close(null) }
            let code = CourierService.commandLineAdd(json)
            fflush(stdout)
            if saved >= 0 { dup2(saved, STDOUT_FILENO); close(saved) }
            return (code, inboxNames().subtracting(before).first)
        }
        /// 让收件箱里的文件“写入已过 5 秒”，再收录一轮
        func collect() -> Int {
            for name in inboxNames() where name.hasSuffix(".json") {
                try? fm.setAttributes([.modificationDate: Date().addingTimeInterval(-5)], ofItemAtPath: CourierService.inbox.appendingPathComponent(name).path)
            }
            return CourierService.processInbox(context: c, effects: nil)
        }
        func receipt(_ file: String?) -> String {
            guard let file else { return "" }
            let suffix = "-" + (file as NSString).deletingPathExtension + ".result.txt"
            let names = (try? fm.contentsOfDirectory(atPath: CourierService.processed.path)) ?? []
            return names.first { $0.hasSuffix(suffix) }.flatMap { try? String(contentsOf: CourierService.processed.appendingPathComponent($0), encoding: .utf8) } ?? ""
        }
        func delivery(_ file: String?) -> CourierDelivery? { c.all(CourierDelivery.self).first { $0.fileName == file && !$0.undone } }

        // 9. 新立目标经 --add 投递两次：第二封“重复投递”；撤销第一封后再投，正常收录
        try writeState(["habits": c.all(Habit.self).filter { !$0.archived }.map(\.title)])
        let goalJSON = #"{"from":"自检","items":[{"type":"goal","title":"自检·收件箱目标","progress":10}]}"#
        let a1 = add(goalJSON)
        let n1 = collect()
        let text1 = receipt(a1.file)
        check(a1.code == 0 && n1 == 1 && c.all(Goal.self).contains { $0.title == "自检·收件箱目标" && $0.progress == 10 }
              && text1.hasPrefix("已收录 1 条（来自 自检；") && text1.contains("\n目标 · 新立「自检·收件箱目标」（进度\u{A0}10%）"),
              "--add 投递的新立目标被收录，回执写明（\(text1.split(separator: "\n").prefix(2).joined(separator: " / "))）")
        let a2 = add(goalJSON)
        let n2 = collect()
        let text2 = receipt(a2.file)
        check(a2.code == 0 && n2 == 0 && text2.hasPrefix("重复投递，已跳过") && text2.contains(#"- 新立目标：这个目标已经建好了，无需重投；要改进度请写 "action": "update""#)
              && c.all(Goal.self).filter { $0.title == "自检·收件箱目标" }.count == 1, "同一个新立目标再投一次：重复投递，已跳过，并给出建议")
        if let first = delivery(a1.file) { CourierService.undo(first, context: c, refresh: false) }
        let a3 = add(goalJSON)
        check(collect() == 1 && c.all(Goal.self).filter { $0.title == "自检·收件箱目标" }.count == 1 && delivery(a3.file) != nil,
              "撤销第一封（目标已删）后再投：正常收录")

        // 目标更新重投：值仍是那封写进去的，判重复
        let updateJSON = #"{"from":"自检","items":[{"type":"goal","action":"update","title":"自检·收件箱目标","progress":20,"notes":"收件箱进展"}]}"#
        let a4 = add(updateJSON)
        _ = collect()
        let a5 = add(updateJSON)
        _ = collect()
        let inboxGoal = c.all(Goal.self).first { $0.title == "自检·收件箱目标" }
        check(receipt(a4.file).contains("目标 · 自检·收件箱目标：进度\u{A0}10% →\u{A0}20%；备注 +「收件箱进展」") && receipt(a5.file).contains("- 更新目标：这些值现在就是这个内容，无需重投")
              && inboxGoal?.progress == 20 && inboxGoal?.notes.components(separatedBy: "收件箱进展").count == 2,
              "同一条目标更新再投：判重复，备注不会追加两遍")

        // 同封“新建习惯 + 打卡”经收件箱：回执两行都在、提醒里有相对日期说明
        let habitJSON = #"{"from":"自检","items":[{"type":"habit","title":"自检收件箱习惯","target":3,"unit":"组"},{"type":"checkin","habit":"自检收件箱习惯"}]}"#
        let a6 = add(habitJSON)
        _ = collect()
        let text6 = receipt(a6.file)
        let inboxHabit = c.all(Habit.self).first { $0.title == "自检收件箱习惯" }
        check(a6.code == 0 && inboxHabit?.logs?.count == 1 && text6.hasPrefix("已收录 2 条") && text6.contains("功课 · 新立「自检收件箱习惯」（每天，每次\u{A0}3组，自\u{A0}")
              && text6.contains("打卡 · ") && text6.contains("条的日期是相对写法"), "--add 投递“新建习惯 + 打卡”：收录 2 条，回执列出两行")
        if let d6 = delivery(a6.file) {
            let r6 = CourierService.undo(d6, context: c, refresh: false)
            check(r6.removed == 2 && !c.all(Habit.self).contains { $0.title == "自检收件箱习惯" }, "撤销经收件箱新建的习惯：习惯与打卡都删掉")
        } else {
            check(false, "经收件箱新建的习惯应有传书记录")
        }

        // 10. --add 按小抄预检：目标找不到 / 能对上多个、习惯重名都报原文、退出码 2；小抄没有 goals 时放行
        try writeState(["habits": ["晨读二十分钟", "喝水"], "archivedHabits": ["跳绳"],
                        "goals": [["title": "完成学位论文初稿", "status": "active", "progress": 65],
                                  ["title": "投出第一篇期刊论文", "status": "active", "progress": 10],
                                  ["title": "旧目标", "status": "cancelled", "progress": 5]]])
        let roster = CourierService.cliRoster()
        check(roster?.habits == ["晨读二十分钟", "喝水"] && roster?.archivedHabits == ["跳绳"] && roster?.goals?.count == 3
              && roster?.goals?.first == CourierRoster.GoalRow(title: "完成学位论文初稿", status: "active", progress: 65), "命令行读小抄构造预检名单")
        func cliError(_ item: String) -> String? {
            do {
                _ = try roster?.resolve(try CourierParser.parse(Data(item.utf8)).items)
                return nil
            } catch { return error.localizedDescription }
        }
        check(cliError(#"{"type":"goal","action":"update","title":"论文","progress":70}"#) == "第 1 条：「论文」能对上多个目标：完成学位论文初稿、投出第一篇期刊论文。请写全称",
              "--add 预检：能对上多个目标，报原文")
        check(cliError(#"{"type":"goal","action":"update","title":"读书","progress":70}"#)
              == "第 1 条：找不到目标「读书」。现有目标：完成学位论文初稿（进行中 65%）、投出第一篇期刊论文（进行中 10%）", "--add 预检：找不到目标，列出现有目标（不含已放弃）")
        check(cliError(#"{"type":"habit","title":"晨读二十分钟"}"#)?.contains("已有同名习惯「晨读二十分钟」") == true
              && cliError(#"{"type":"habit","title":"跳绳"}"#)?.contains("已有同名的已归档习惯「跳绳」") == true, "--add 预检：新习惯重名（含已归档的），报原文")
        check(cliError(#"{"type":"goal","action":"update","title":"旧目标","status":"active"}"#) == nil, "--add 预检：全称能找到已放弃的目标")
        let inboxBefore = inboxNames()
        let codes = [add(#"{"type":"goal","action":"update","title":"论文","progress":70}"#).code, add(#"{"type":"habit","title":"喝水"}"#).code,
                     add(#"{"type":"checkin","habit":"跑步"}"#).code, add(#"{"type":"goal","date":"2026-10-14"}"#).code]
        check(codes == [2, 2, 2, 1] && inboxNames() == inboxBefore, "--add 对不上现有习惯或目标时退出码 2、格式不对时 1，都不投进收件箱（\(codes)）")
        try writeState(["habits": ["晨读二十分钟"]])
        let loose = add(#"{"type":"goal","action":"update","title":"论文","progress":70}"#)
        check(CourierService.cliRoster()?.goals == nil && loose.code == 0 && loose.file != nil, "小抄里没有 goals 时不查目标，--add 放行（由应用收录时再查）")
        if let file = loose.file { try? fm.removeItem(at: CourierService.inbox.appendingPathComponent(file)) }
        check(!inboxNames().contains { $0.hasSuffix(".json") }, "自检用完收件箱已清空")
    }
}
